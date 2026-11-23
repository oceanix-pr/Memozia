#if os(macOS)
import AVFoundation
import CoreAudio
import CoreMedia
import os

/// One private process tap and its input-only aggregate device. HAL handles are owned by
/// controlQueue. Core Audio lends its input memory only for the duration of the I/O callback.
final class SystemAudioTap: Sendable {
    struct Output: Sendable {
        let queue: DispatchQueue
        let receive: @Sendable (SystemAudioTap, AVAudioPCMBuffer, CMTime) -> Void
        let dropped: @Sendable (SystemAudioTap) -> Void
        let interrupted: @Sendable (SystemAudioTap, any Error) -> Void
    }

    private static let logger = Logger(subsystem: "app.memozia", category: "SystemAudioTap")
    private let controlQueue = DispatchQueue(label: "app.memozia.systemaudio.hal")
    private let ioQueue = DispatchQueue(label: "app.memozia.systemaudio.io", qos: .userInteractive)
    private let pendingWrites = DispatchSemaphore(value: 32)
    private let closed = CancellationFlag()
    private let startup = OneShotBox<Result<Void, any Error>>()
    private let lastPacket = LockedBox<ContinuousClock.Instant?>(nil)
    private let output: Output

    // All mutations, including partial-start rollback, run on controlQueue.
    private final class Hardware: @unchecked Sendable {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var device = AudioObjectID(kAudioObjectUnknown)
        var proc: AudioDeviceIOProcID?
        var started = false
        var monitor: DispatchSourceTimer?
        var formatListener: AudioObjectPropertyListenerBlock?
    }
    private let hardware = Hardware()

    init(output: Output) { self.output = output }

    /// AudioDeviceStart may wait on the system consent dialog. Let the caller leave immediately
    /// on cancellation/timeout. Late HAL returns clean up only this tap, on its control queue.
    func start() async throws {
        try Task.checkCancellation()
        controlQueue.async {
            do {
                try self.install()
                self.startup.deliver(.success(()))
            }
            catch {
                self.startup.deliver(.failure(error))
                self.destroyHardware()
            }
        }
        let result = LockedBox<Result<Void, any Error>?>(nil)
        let finished = await RacingWatchdog.race(name: "系统录音启动", timeout: 60,
                                                onTimeout: { self.invalidate() },
                                                onCancel: { self.invalidate() }) {
            result.value = await withCheckedContinuation { done in
                if let early = self.startup.attach(done) { done.resume(returning: early) }
            }
        }
        try Task.checkCancellation()
        guard finished, let outcome = result.value else { throw SystemAudioError.startTimedOut }
        try outcome.get()
    }

    func invalidate() {
        closed.cancel()
        startup.deliver(.failure(CancellationError()))
        controlQueue.async { self.destroyHardware() }
    }

    func stop() async {
        invalidate()
        // A device or a pending consent dialog may hold up a HAL call. The queue still owns
        // teardown if the caller has to finish its WAV before HAL responds.
        _ = await RacingWatchdog.race(name: "停止系统音频设备", timeout: 5) {
            await withCheckedContinuation { done in self.controlQueue.async { done.resume() } }
        }
    }

    private func checkOpen() throws {
        if closed.isCancelled { throw CancellationError() }
    }

    private func install() throws {
        try checkOpen()
        var pid = getpid()
        var process = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout.size(ofValue: process))
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        try Self.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                  UInt32(MemoryLayout.size(ofValue: pid)), &pid, &size, &process))
        guard process != kAudioObjectUnknown else { throw SystemAudioError.deviceUnavailable }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process])
        description.name = "Memozia"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        Self.logger.debug("正在创建系统录音 tap")
        try Self.check(AudioHardwareCreateProcessTap(description, &hardware.tap))
        try checkOpen()

        // A tap is the only input. Adding the physical output device here could also expose its mic.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Memozia",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]]
        ]
        try Self.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &hardware.device))

        let format = LockedBox<AVAudioFormat?>(try readFormat())
        var formatAddress = Self.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.closed.isCancelled else { return }
            do { format.value = try self.readFormat() }
            catch {
                format.value = nil
                self.reportInterruption(error)
            }
        }
        try Self.check(AudioObjectAddPropertyListenerBlock(hardware.device, &formatAddress, controlQueue, listener))
        hardware.formatListener = listener

        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&hardware.proc, hardware.device, ioQueue) {
            [weak self] now, input, inputTime, _, _ in
            guard let self, !self.closed.isCancelled, let format = format.value else { return }
            let time = inputTime.pointee
            let host = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : now.pointee.mHostTime
            self.consume(input, hostTime: host, format: format)
        })
        try checkOpen()
        guard let proc = hardware.proc else { throw SystemAudioError.deviceUnavailable }
        Self.logger.debug("正在启动系统录音设备")
        try Self.check(AudioDeviceStart(hardware.device, proc))
        hardware.started = true
        Self.logger.info("系统录音设备已启动")
        try checkOpen()

        // A tap-only device may produce no I/O while no other app is playing. Only a HAL
        // device failure, or a device which has actually stopped, is an interruption.
        let monitor = DispatchSource.makeTimerSource(queue: controlQueue)
        monitor.schedule(deadline: .now() + 5, repeating: 2)
        monitor.setEventHandler { [weak self] in
            guard let self, !self.closed.isCancelled else { return }
            if let last = self.lastPacket.value, last.duration(to: .now) < .seconds(5) { return }
            do {
                for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyDeviceIsRunning] {
                    var flag: UInt32 = 0
                    var size = UInt32(MemoryLayout.size(ofValue: flag))
                    var address = Self.address(selector)
                    try Self.check(AudioObjectGetPropertyData(self.hardware.device, &address, 0, nil, &size, &flag))
                    if flag == 0 { throw SystemAudioError.deviceUnavailable }
                }
            } catch { self.reportInterruption(error) }
        }
        hardware.monitor = monitor
        monitor.resume()
    }

    private func readFormat() throws -> AVAudioFormat {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        var address = Self.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
        try Self.check(AudioObjectGetPropertyData(hardware.device, &address, 0, nil, &size, &asbd))
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0,
              asbd.mChannelsPerFrame > 0, asbd.mSampleRate > 0 else { throw SystemAudioError.invalidFormat }
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw SystemAudioError.invalidFormat }
        return format
    }

    /// Called on the serial I/O queue. Only an owned copy may outlive this callback.
    func consume(_ input: UnsafePointer<AudioBufferList>, hostTime: UInt64, format: AVAudioFormat) {
        guard !closed.isCancelled else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        // Disabled HAL streams can advertise a byte count but provide no data.
        guard let first = buffers.first, first.mDataByteSize > 0,
              buffers.allSatisfy({ $0.mData != nil }) else { return }
        let bytesPerFrame = format.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { reportInterruption(SystemAudioError.invalidFormat); return }
        let frames = first.mDataByteSize / bytesPerFrame
        guard frames > 0 else { return }
        lastPacket.value = .now
        guard pendingWrites.wait(timeout: .now()) == .success else { output.dropped(self); return }
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            pendingWrites.signal()
            reportInterruption(SystemAudioError.invalidFormat)
            return
        }
        pcm.frameLength = frames
        let owned = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        guard owned.count == buffers.count else {
            pendingWrites.signal()
            reportInterruption(SystemAudioError.invalidFormat)
            return
        }
        for (source, destination) in zip(buffers, owned) {
            guard source.mNumberChannels == destination.mNumberChannels,
                  source.mDataByteSize == destination.mDataByteSize,
                  let from = source.mData, let to = destination.mData else {
                pendingWrites.signal()
                reportInterruption(SystemAudioError.invalidFormat)
                return
            }
            memcpy(to, from, Int(source.mDataByteSize))
        }
        // The PCM buffer owns every plane. After this handoff only the serial writer uses it.
        nonisolated(unsafe) let transferred = pcm
        output.queue.async {
            defer { self.pendingWrites.signal() }
            if !self.closed.isCancelled {
                self.output.receive(self, transferred, CMClockMakeHostTimeFromSystemUnits(hostTime))
            }
        }
    }

    private func reportInterruption(_ error: any Error) {
        startup.deliver(.failure(error))
        output.interrupted(self, error)
    }

    private func destroyHardware() {
        hardware.monitor?.cancel()
        hardware.monitor = nil
        if let listener = hardware.formatListener {
            var address = Self.address(kAudioDevicePropertyStreamFormat, scope: kAudioObjectPropertyScopeInput)
            Self.logCleanup(AudioObjectRemovePropertyListenerBlock(hardware.device, &address, controlQueue, listener))
            hardware.formatListener = nil
        }
        if let proc = hardware.proc {
            if hardware.started { Self.logCleanup(AudioDeviceStop(hardware.device, proc)) }
            Self.logCleanup(AudioDeviceDestroyIOProcID(hardware.device, proc))
            hardware.proc = nil
            hardware.started = false
        }
        if hardware.device != kAudioObjectUnknown {
            Self.logCleanup(AudioHardwareDestroyAggregateDevice(hardware.device))
            hardware.device = AudioObjectID(kAudioObjectUnknown)
        }
        if hardware.tap != kAudioObjectUnknown {
            Self.logCleanup(AudioHardwareDestroyProcessTap(hardware.tap))
            hardware.tap = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func logCleanup(_ status: OSStatus) {
        if status != noErr { logger.error("Core Audio 资源释放失败 OSStatus=\(status)") }
    }

    static func check(_ status: OSStatus) throws {
        guard status != noErr else { return }
        switch status {
        case kAudioDevicePermissionsError, kAudioUnitErr_Unauthorized, kAudioComponentErr_NotPermitted:
            throw SystemAudioError.permissionNotGranted
        default:
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
#endif
