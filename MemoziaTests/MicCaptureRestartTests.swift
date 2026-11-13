import Foundation
import AVFoundation
import CoreAudio
import Testing
@testable import Memozia

@Suite(.serialized)
struct MicCaptureRestartTests {
    private static var bluetoothRouteAvailable: Bool {
        if let input = MicrophoneDeviceRegistry.resolvedDeviceID(), isBluetooth(input) { return true }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var output: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr else { return false }
        return output != 0 && isBluetooth(output)
    }

    private static func isBluetooth(_ device: UInt32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func format(_ rate: Double) throws -> AVAudioFormat {
        try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    }

    @Test func onlyEngineFormatNegotiationCanRetryWithoutInterruptionWarning() {
        for stage: MicCaptureDiagnostics.Stage in [.bindDevice, .readFormat, .openSegmentFile, .installTap,
                                                   .startEngine, .writeBuffer, .recoveryBudget, .captureStalled] {
            let diagnostics = MicCaptureDiagnostics(stage: stage, generation: 1, attempt: 1,
                deviceBound: true, oldSampleRate: 24_000, newSampleRate: 96_000,
                oldChannelCount: 1, newChannelCount: 1,
                errorDomain: "com.apple.coreaudio.avfaudio", errorCode: -10868, detail: nil)
            #expect(diagnostics.isFormatNegotiationFailure == (stage == .startEngine || stage == .installTap))
        }
    }

    /// 模拟日志中的 -10868：同一设备协商重试成功不产生警告，预算耗尽仍须报告。
    /// 只在显式启用、已有权限时运行，全部写入均为静音且位于临时目录。
    @MainActor
    @Test(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_AUDIO_CAPTURE"] == "1"
                   && AVAudioApplication.shared.recordPermission == .granted), arguments: [false, true])
    func realFormatNegotiationRecoversInternally(exhaustRetries: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicNegotiation-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var activeEngine: AVAudioEngine?
        var starts = 0
        let capture = MicCaptureService(makeEngine: {
            let engine = AVAudioEngine()
            activeEngine = engine
            return engine
        }, startEngine: { engine in
            starts += 1
            if starts == 2 || (exhaustRetries && starts > 2) {
                throw NSError(domain: "com.apple.coreaudio.avfaudio", code: -10868)
            }
            engine.prepare()
            try engine.start()
        })
        defer { capture.stop() }
        var index = 1
        capture.nextSegmentForFormatChange = {
            index += 1
            return directory.appendingPathComponent("sample_mic_tmp_\(index).caf")
        }
        let health = LockedBox(RecordingCaptureHealth(usesMicrophone: true))
        let session = try #require(health.value.sessionID)
        let recovered = LockedBox(false)
        let failed = LockedBox(false)
        capture.onEvent = { event in
            var state = health.value
            switch event {
            case .deviceUnavailable: state.handle(.microphoneUnavailable, sessionID: session)
            case .recoveryStarted: state.handle(.microphoneRecovering, sessionID: session)
            case .recovered:
                state.handle(.microphoneRecovered, sessionID: session)
                recovered.value = true
            case .recoveryFailed, .writeFailed:
                state.handle(.microphoneRecoveryFailed, sessionID: session)
                failed.value = true
            }
            health.value = state
        }
        let first = directory.appendingPathComponent("sample_mic_tmp_1.caf")
        let timeline = RecordingSegmentTimelineStore()
        try await capture.start(to: first, initiallyMuted: true, timeline: timeline)
        let before = capture.writtenFrames
        let engine = try #require(activeEngine)
        engine.stop()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        let deadline = ContinuousClock.now.advanced(by: .seconds(16))
        while !recovered.value, !failed.value, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(starts >= 3, "格式协商失败必须由应用重试")
        if exhaustRetries {
            #expect(failed.value)
            #expect(!recovered.value)
            #expect(health.value.report.hasWarning, "重试耗尽不能被格式协商分类掩盖")
        } else {
            #expect(recovered.value)
            #expect(!failed.value)
            #expect(capture.writtenFrames > before)
            #expect(health.value.report.isEmpty, "已成功消化的格式协商不得成为用户的修复任务")
        }
        capture.stop()
        #expect(try AVAudioFile(forReading: first).length > 0, "重试不得覆盖先前音频")
        timeline.finish()
        try timeline.save(in: directory)
        if !exhaustRetries {
            #expect(try RecordingSegmentTimeline.load(in: directory)?.starts.count ?? 0 >= 2)
        }
    }

    /// 显式启用且已有权限才运行；不弹授权框，只在临时目录写全零音频。
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_AUDIO_CAPTURE"] == "1"
                   && AVAudioApplication.shared.recordPermission == .granted))
    func realMicrophoneCanRestartMutedWithFreshEngine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicLive-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = MicCaptureService()
        defer { capture.stop() }
        for index in 0..<3 {
            let url = directory.appendingPathComponent("muted-\(index).caf")
            try await capture.start(to: url, initiallyMuted: true)
            #expect(capture.isCapturing)
            capture.stop()
            let audio = try AVAudioFile(forReading: url)
            #expect(audio.length > 0)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 128))
            try audio.read(into: buffer)
            let samples = try #require(buffer.floatChannelData)
            let pointerCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
            let sampleCount = Int(buffer.frameLength) * (buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1)
            for channel in 0..<pointerCount {
                #expect(UnsafeBufferPointer(start: samples[channel], count: sampleCount).allSatisfy { $0 == 0 })
            }
        }
    }

    /// 复现停录后蓝牙退出采集模式、空闲 45 秒再启动；仅显式开启、蓝牙音频路由且权限齐全时运行。
    @MainActor
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_BLUETOOTH_RESTART"] == "1"
                   && AVAudioApplication.shared.recordPermission == .granted
                   && SystemAudioCaptureService.preflightPermission() && bluetoothRouteAvailable))
    func bluetoothMixedCaptureRestartsAfterIdle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicBluetooth-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = MicCaptureService()
        let system = SystemAudioCaptureService()
        defer { microphone.stop() }
        do {
            for index in 0..<2 {
                let url = directory.appendingPathComponent("muted-\(index).caf")
                try await microphone.start(to: url, initiallyMuted: true)
                try await system.start(to: directory.appendingPathComponent("system-\(index).wav"))
                try await Task.sleep(for: .seconds(3))
                #expect(microphone.isCapturing)
                microphone.stop()
                let result = await system.stop()
                #expect(!result.writerFailed)
                #expect(try AVAudioFile(forReading: url).length > 0)
                if index == 0 { try await Task.sleep(for: .seconds(45)) }
            }
        } catch {
            microphone.stop()
            _ = await system.stop()
            throw error
        }
    }

    @Test func muteBuffersClearInterleavedStereoAndReuseSafely() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000, channels: 2, interleaved: true))
        let pool = MicCaptureZeroBufferBox()
        let first = try #require(pool.zeroBuffer(matching: format, frameLength: 32))
        let samples = try #require(first.floatChannelData)[0]
        samples.update(repeating: 1, count: 64)
        let reused = try #require(pool.zeroBuffer(matching: format, frameLength: 16))
        #expect(reused === first)
        #expect(UnsafeBufferPointer(start: samples, count: 32).allSatisfy { $0 == 0 })
    }

    @Test func staleClientFormatUsesHardwareRateAndWritesPlayableCAF() throws {
        let hardware = try format(24_000)
        let staleClient = try format(48_000)
        let capture = try MicCaptureService.captureFormat(hardware: hardware, client: staleClient)
        #expect(capture.sampleRate == 24_000)
        #expect(MicCaptureService.requiresNewSegment(from: staleClient, to: capture))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicHardware-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = MicCaptureFileStore()
        store.file = try AVAudioFile(forWriting: url,
            settings: #require(MicCaptureService.fileSettings(for: capture)),
            commonFormat: capture.commonFormat, interleaved: capture.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: capture, frameCapacity: 240))
        buffer.frameLength = 240
        buffer.floatChannelData?[0].update(repeating: 0, count: 240)
        let tap = UUID()
        store.activate(tap)
        #expect(try store.write(tap: tap) { try $0.write(from: buffer) })
        store.invalidateTap()
        store.file = nil
        let saved = try AVAudioFile(forReading: url)
        #expect(saved.fileFormat.sampleRate == 24_000)
        #expect(saved.length == 240)
    }

    @Test func liveDeviceRateOverridesTwoStaleNodeFormats() throws {
        let staleHardware = try format(48_000)
        let staleClient = try format(48_000)
        let capture = try MicCaptureService.captureFormat(
            hardware: staleHardware, client: staleClient, deviceSampleRate: 24_000
        )
        #expect(capture.sampleRate == 24_000)
        #expect(MicCaptureService.needsFormatReconfiguration(
            hardware: staleHardware, client: staleClient, capture: staleClient, deviceSampleRate: 24_000
        ))
        #expect(!MicCaptureService.needsFormatReconfiguration(
            hardware: staleHardware, client: capture, capture: capture, deviceSampleRate: 24_000
        ), "同一已对齐格式的重复通知不需要再次重装 tap")
        #expect(try MicCaptureService.captureFormat(
            hardware: staleHardware, client: staleClient, deviceSampleRate: 0
        ).sampleRate == 48_000)
    }

    @Test func postStartHardwareChangeInvalidatesPreparedTap() throws {
        let prepared = try format(48_000)
        let negotiated = try format(24_000)
        #expect(MicCaptureService.needsFormatReconfiguration(
            hardware: negotiated, client: prepared, capture: prepared
        ))
        #expect(!MicCaptureService.needsFormatReconfiguration(
            hardware: negotiated, client: negotiated, capture: negotiated
        ))
        let integerClient = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: false
        ))
        #expect(MicCaptureService.needsFormatReconfiguration(
            hardware: negotiated, client: integerClient, capture: negotiated
        ))
    }

    @Test func oldTapCannotWriteToRotatedOrNewSessionFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicTap-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try format(48_000)
        let settings = try #require(MicCaptureService.fileSettings(for: format))
        let store = MicCaptureFileStore()
        let oldTap = UUID()
        store.activate(oldTap)
        store.file = try AVAudioFile(forWriting: directory.appendingPathComponent("first.caf"),
            settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        buffer.floatChannelData?[0].update(repeating: 0, count: 128)
        #expect(try store.write(tap: oldTap) { try $0.write(from: buffer) })
        // 正常分片轮转不撤销当前 tap。
        store.file = try AVAudioFile(forWriting: directory.appendingPathComponent("rotated.caf"),
            settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        #expect(try store.write(tap: oldTap) { try $0.write(from: buffer) })
        store.invalidateTap()
        let newTap = UUID()
        store.file = try AVAudioFile(forWriting: directory.appendingPathComponent("new.caf"),
            settings: settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        store.activate(newTap)
        var staleCallbackRan = false
        #expect(!store.write(tap: oldTap) { _ in staleCallbackRan = true })
        #expect(!staleCallbackRan)
        #expect(store.file?.length == 0)
        #expect(try store.write(tap: newTap) { try $0.write(from: buffer) })
        #expect(store.file?.length == 128)
        store.invalidateTap()
        #expect(!store.write(tap: newTap) { _ in staleCallbackRan = true })
        store.file = nil
    }

    @MainActor
    @Test func startupCleanupPreservesAudioAndUnreadableFilesButNotEmptyCAF() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MicRollback-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.caf")
        #expect(!MeetingRecorderService.hasCapturedFrames(in: [url]))
        let format = try format(24_000)
        let store = MicCaptureFileStore()
        store.file = try AVAudioFile(forWriting: url,
            settings: #require(MicCaptureService.fileSettings(for: format)),
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        store.file = nil
        #expect(!MeetingRecorderService.hasCapturedFrames(in: [url]))
        store.file = try AVAudioFile(forWriting: url,
            settings: #require(MicCaptureService.fileSettings(for: format)),
            commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        buffer.frameLength = 240
        buffer.floatChannelData?[0].update(repeating: 0, count: 240)
        try store.write { try $0.write(from: buffer) }
        store.file = nil
        #expect(MeetingRecorderService.hasCapturedFrames(in: [url]))
        let unreadable = directory.appendingPathComponent("unknown.caf")
        try Data("unreadable audio".utf8).write(to: unreadable)
        #expect(MeetingRecorderService.hasCapturedFrames(in: [unreadable]))
    }

    @MainActor
    @Test func bindingFailureRollsBackAndNextStartCreatesNewEngines() async throws {
        var engines: [AVAudioEngine] = []
        let capture = MicCaptureService(
            permissionCheck: { true },
            bindInput: { _ in throw MicCaptureError.inputDeviceLost },
            makeEngine: { let engine = AVAudioEngine(); engines.append(engine); return engine }
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicBind-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        for expectedCount in [5, 10] {
            await #expect(throws: MicCaptureError.self) { try await capture.start(to: url) }
            #expect(engines.count == expectedCount)
            #expect(!capture.isCapturing)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        #expect(Set(engines.map { ObjectIdentifier($0) }).count == 10)
        capture.stop()
        capture.stop()
    }

    @MainActor
    @Test(arguments: [true, false])
    func stoppedPermissionRequestCannotCreateEngineInNextSession(granted: Bool) async throws {
        let gate = AsyncStream<Bool>.makeStream()
        let permissionEntered = LockedBox(false)
        var engineCount = 0
        let capture = MicCaptureService(permissionCheck: {
            if permissionEntered.value { return false }
            permissionEntered.value = true
            for await value in gate.stream { return value }
            return false
        }, makeEngine: { engineCount += 1; return AVAudioEngine() })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MicPermission-\(UUID()).caf")
        let oldStart = Task { try await capture.start(to: url) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !permissionEntered.value, ContinuousClock.now < deadline { await Task.yield() }
        #expect(permissionEntered.value)
        capture.stop()
        await #expect(throws: MicCaptureError.self) { try await capture.start(to: url) }
        gate.continuation.yield(granted)
        gate.continuation.finish()
        do {
            try await oldStart.value
            Issue.record("停止后的权限结果不能继续启动")
        } catch { #expect(error is CancellationError) }
        #expect(engineCount == 0)
    }
}

@MainActor
struct MicCaptureStartupWaitTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

    @Test func startupWaitsForCurrentPacketAndCancelInvalidatesLatePacket() async throws {
        var tokens: [MicCaptureRecovery.Attempt] = []
        var recovered = 0
        let recovery = MicCaptureRecovery(backoff: [], packetTimeout: .seconds(1),
            attempt: { tokens.append($0); return true }, onStarted: { _ in },
            onPacketTimeout: { _ in }, onFailed: { _ in }, onRecovered: { recovered += 1 })
        let first = Task { try await recovery.startAndWait() }
        try await waitUntil { tokens.count == 1 }
        #expect(recovery.isActive)
        first.cancel()
        do { try await first.value; Issue.record("应响应取消") }
        catch { #expect(error is CancellationError) }
        let second = Task { try await recovery.startAndWait() }
        try await waitUntil { tokens.count == 2 }
        recovery.confirmWrite(tokens[0])
        #expect(!recovery.isConfirmed)
        recovery.confirmWrite(tokens[1])
        try await second.value
        #expect(recovered == 1)
        #expect(!recovery.isActive)
    }

    @Test func nonRetryableFailureAndPacketTimeoutBothSettleStartup() async throws {
        for retryable in [false, true] {
            var attempts = 0
            var failures = 0
            let recovery = MicCaptureRecovery(backoff: [.milliseconds(1)], packetTimeout: .milliseconds(10),
                attempt: { _ in attempts += 1; return retryable }, onStarted: { _ in },
                onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 }, onRecovered: {},
                shouldRetry: { retryable })
            await #expect(throws: MicCaptureRecovery.Failure.self) { try await recovery.startAndWait() }
            #expect(attempts == (retryable ? 2 : 1))
            #expect(failures == 1)
            #expect(!recovery.isActive)
        }
    }

    @Test func fatalWriteFailureSettlesWaiterAndRejectsLateWrite() async throws {
        var token: MicCaptureRecovery.Attempt?
        var recovered = 0
        var failures = 0
        let recovery = MicCaptureRecovery(attempt: { token = $0; return true },
            onStarted: { _ in }, onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 },
            onRecovered: { recovered += 1 })
        let startup = Task { try await recovery.startAndWait() }
        try await waitUntil { token != nil }
        recovery.fail()
        await #expect(throws: MicCaptureRecovery.Failure.self) { try await startup.value }
        recovery.confirmWrite(try #require(token))
        #expect(recovered == 0)
        #expect(failures == 1)
        #expect(!recovery.isActive)
    }
}
