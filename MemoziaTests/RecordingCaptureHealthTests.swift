import Foundation
import AVFoundation
import Testing
@testable import Memozia

struct RecordingCaptureHealthTests {
    /// 显式启用真机采集时运行。首次使用由 macOS 请求系统录音权限。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_AUDIO_CAPTURE"] == "1"))
    func systemCaptureReconnectAndStopFinalizeWithoutStaleInterruption() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Memozia-capture-verification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("system.wav")
        let capture = SystemAudioCaptureService()
        let unexpectedInterruption = LockedBox(false)
        let recovered = LockedBox(false)
        capture.onEvent = { event in
            switch event.kind {
            case .interrupted, .writerFailed: unexpectedInterruption.value = true
            case .recovered: recovered.value = true
            case .samplesDropped: break
            }
        }
        try await capture.start(to: output)
        try? await Task.sleep(for: .seconds(1))
        let oldCaptureID = capture.captureID
        let oldEvent = SystemAudioCaptureService.Event(captureID: oldCaptureID, kind: .samplesDropped(25))
        let resumed = await capture.resumeAfterWake(expectedCaptureID: oldCaptureID)
        try? await Task.sleep(for: .seconds(1))
        let result = await capture.stop()
        // 让正常 stop 的迟到 delegate 回调也有机会执行。
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!unexpectedInterruption.value)
        #expect(resumed)
        #expect(recovered.value, "重连后必须真实写入样本才能确认恢复")
        #expect(!capture.isCurrentEvent(oldEvent))
        #expect(!capture.capturing)
        #expect(!result.writerFailed)
        let audio = try AVAudioFile(forReading: output)
        #expect(audio.length > 0)
    }

    /// Exercise HAL and the system audio permission. Trigger an output cycle in another process
    /// at zero volume, count PCM frames, and discard them all without opening a recording file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_AUDIO_TAP_ACCESS"] == "1"))
    func realAudioTapStartsWithoutCreatingRecording() async throws {
        let received = LockedBox(false)
        let tap = SystemAudioTap(output: .init(queue: DispatchQueue(label: "test.audio-tap"),
            receive: { _, pcm, _ in if pcm.frameLength > 0 { received.value = true } },
            dropped: { _ in }, interrupted: { _, error in Issue.record(error) }))
        defer { tap.invalidate() }
        try await tap.start()
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0", "/System/Library/Sounds/Glass.aiff"]
        try player.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !received.value, .now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if player.isRunning { player.terminate() }
        await tap.stop()
        #expect(received.value)
    }

    @Test("旧授权请求迟到失败不能释放新录音的启动预约")
    func stoppedAuthorizationCannotClearNextStart() async throws {
        let requests = LockedBox<[CheckedContinuation<Void, any Error>]>([])
        let capture = SystemAudioCaptureService(startTap: { _ in
            try await withCheckedThrowingContinuation { continuation in
                var pending = requests.value
                pending.append(continuation)
                requests.value = pending
            }
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Authorization-\(UUID()).wav")
        let old = Task { try await capture.start(to: url) }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.value.count < 1, ContinuousClock.now < firstDeadline { await Task.yield() }
        try #require(requests.value.count == 1)
        _ = await capture.stop()
        let next = Task { try await capture.start(to: url) }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.value.count < 2, ContinuousClock.now < secondDeadline { await Task.yield() }
        try #require(requests.value.count == 2)
        requests.value[0].resume(throwing: CocoaError(.userCancelled))
        do { try await old.value; Issue.record("旧请求不应启动采集") } catch {}
        #expect(capture.hasResourcesPreventingUpdate, "新一轮仍在等待授权，旧请求不得释放其资源状态")
        requests.value[1].resume(throwing: CocoaError(.userCancelled))
        do { try await next.value; Issue.record("失败请求不应启动采集") } catch {}
        #expect(!capture.hasResourcesPreventingUpdate)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Exercise the same borrowed HAL buffer → owned Core Media sample → WAV path as live capture,
    /// using a stereo test signal. No permission or audio device is needed.
    @Test("系统音频复制借用的 PCM、对齐首包时间、轮转分片并在唤醒后继续写入", arguments: [false, true])
    func syntheticTapRecording(interleaved: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tapBox = LockedBox<SystemAudioTap?>(nil)
        let recovered = LockedBox(false)
        let capture = SystemAudioCaptureService(startTap: { tapBox.value = $0 })
        capture.onEvent = { event in
            if case .recovered = event.kind { recovered.value = true }
        }
        let timeline = RecordingSegmentTimelineStore()
        let first = folder.appendingPathComponent("first.wav")
        let second = folder.appendingPathComponent("second.wav")
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                channels: 2, interleaved: interleaved))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441))
        pcm.frameLength = 441
        let base = mach_absolute_time()
        func send(_ index: Int, to tap: SystemAudioTap, pcm: AVAudioPCMBuffer, level: Float) {
            let buffers = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
            for (channel, plane) in buffers.enumerated() {
                let count = Int(plane.mDataByteSize) / MemoryLayout<Float>.size
                let samples = plane.mData!.assumingMemoryBound(to: Float.self)
                for n in 0..<count {
                    let left = pcm.format.isInterleaved ? n.isMultiple(of: 2) : channel == 0
                    samples[n] = left ? level : -level / 2
                }
            }
            let host = base + AVAudioTime.hostTime(forSeconds: Double(index) / 100)
            tap.consume(pcm.audioBufferList, hostTime: host, format: pcm.format)
            // HAL may overwrite or free the buffer immediately on return.
            for plane in buffers { if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) } }
        }
        try await capture.start(to: first, timeline: timeline)
        let original = try #require(tapBox.value)
        for index in 0..<10 { send(index, to: original, pcm: pcm, level: 0.25) }
        #expect(await capture.rotateWriter(to: second))
        for index in 10..<14 { send(index, to: original, pcm: pcm, level: -0.25) }
        let origin = capture.captureID
        #expect(await capture.resumeAfterWake(expectedCaptureID: origin))
        let replacement = try #require(tapBox.value)
        #expect(replacement !== original)
        let newFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                   channels: 2, interleaved: !interleaved))
        let newPCM = try #require(AVAudioPCMBuffer(pcmFormat: newFormat, frameCapacity: 480))
        newPCM.frameLength = 480
        for index in 14..<20 {
            send(index, to: original, pcm: pcm, level: 0.75)
            send(index, to: replacement, pcm: newPCM, level: -0.25)
        }
        let stopped = await capture.stop()
        #expect(!stopped.writerFailed && !stopped.wasInterrupted)
        #expect(recovered.value)
        #expect(!capture.hasResourcesPreventingUpdate)

        for (url, level) in [(first, Float(0.25)), (second, Float(-0.25))] {
            let file = try AVAudioFile(forReading: url)
            #expect(file.fileFormat.sampleRate == 48_000)
            #expect(file.fileFormat.channelCount == 2)
            #expect(abs(Double(file.length) / 48_000 - 0.1) < 0.002)
            let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(max(1, file.length))))
            try file.read(into: read)
            let samples = try #require(read.floatChannelData)
            let middle = Int(read.frameLength) / 2
            #expect(abs(samples[0][middle] - level) < 0.02)
            #expect(abs(samples[1][middle] + level / 2) < 0.02)
        }
        try await timeline.save(in: folder)
        let stored = try #require(try RecordingSegmentTimeline.load(in: folder))
        #expect(abs((try stored.offset(for: second)) - 0.1) < 0.01)
    }

    @Test func normalStopHasNoWarning() {
        var health = RecordingCaptureHealth(usesSystemAudio: true)
        health.finish()
        #expect(health.summary == nil)
    }

    @Test func successfulRecoveryKeepsInterruptionHistory() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesSystemAudio: true, sessionID: session)
        health.handle(.interrupted(), sessionID: session)
        let interruptedSummary = health.summary
        health.handle(.beginRecovery, sessionID: session)
        #expect(health.systemAudio == .recovering)
        #expect(health.summary == interruptedSummary, "启动新流尚不能确认声音已恢复")
        health.handle(.recovered, sessionID: session)
        #expect(health.systemAudio == .active)
        #expect(health.hadSystemAudioInterruption)
        #expect(health.summary != nil)
        #expect(health.summary != interruptedSummary)
    }

    @Test func failedRecoveryRemainsInterrupted() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesSystemAudio: true, sessionID: session)
        health.handle(.sleep, sessionID: session)
        health.handle(.beginRecovery, sessionID: session)
        health.handle(.interrupted(), sessionID: session)
        #expect(health.systemAudio == .interrupted)
        #expect(health.hadSleep)
        #expect(health.summary != nil)
    }

    @Test func lateRecoveryAfterStopCannotRewriteFinalResult() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesSystemAudio: true, sessionID: session)
        health.handle(.sleep, sessionID: session)
        health.handle(.beginRecovery, sessionID: session)
        health.finish()
        let finalSummary = health.summary
        let accepted = health.handle(.recovered, sessionID: session)
        #expect(!accepted)
        #expect(health.systemAudio == .recovering)
        #expect(health.summary == finalSummary)
    }

    @Test func oldSessionCannotPolluteNewRecording() {
        let previous = UUID()
        let current = UUID()
        var health = RecordingCaptureHealth(usesSystemAudio: true, sessionID: current)
        let acceptedFailure = health.handle(.interrupted(writerFailure: true), sessionID: previous)
        let acceptedDrop = health.handle(.samplesDropped, sessionID: previous)
        #expect(!acceptedFailure)
        #expect(!acceptedDrop)
        #expect(health.summary == nil)
        #expect(health.systemAudio == .active)
    }

    @Test func recoveryDoesNotEraseWriterFailureOrDroppedSamples() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesSystemAudio: true, sessionID: session)
        health.handle(.interrupted(writerFailure: true), sessionID: session)
        health.handle(.samplesDropped, sessionID: session)
        health.handle(.sleep, sessionID: session)
        health.handle(.beginRecovery, sessionID: session)
        health.handle(.recovered, sessionID: session)
        #expect(health.systemAudio == .active)
        #expect(health.hadWriterFailure)
        #expect(health.hadDroppedSamples)
        #expect(health.hadSleep)
        #expect(health.summary?.components(separatedBy: "\n").count == 4)
    }

    @Test func microphoneOnlySleepDoesNotInventSystemAudioFailure() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesSystemAudio: false, sessionID: session)
        health.handle(.sleep, sessionID: session)
        health.handle(.beginRecovery, sessionID: session)
        health.handle(.recovered, sessionID: session)
        #expect(health.systemAudio == .unused)
        #expect(!health.hadSystemAudioInterruption)
        #expect(health.hadSleep)
    }

    // MARK: - 麦克风设备切换 / 恢复

    @Test func microphoneInterruptionAndRecoveryKeepGapHistory() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        #expect(health.microphone == .active)

        health.handle(.microphoneUnavailable, sessionID: session)
        health.handle(.microphoneRecovering, sessionID: session)
        #expect(health.microphone == .recovering)
        let recoveringSummary = health.summary

        health.handle(.microphoneRecovered, sessionID: session)
        #expect(health.microphone == .active)
        // 恢复成功只更新「当前状态」，不得抹掉曾经断开的事实
        #expect(health.hadMicrophoneInterruption)
        #expect(health.summary != nil)
        #expect(health.summary != recoveringSummary, "恢复后不应继续显示「未确认恢复」的过期文案")
    }

    @Test func microphoneRecoveryFailureStaysUnavailable() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        health.handle(.microphoneUnavailable, sessionID: session)
        health.handle(.microphoneRecovering, sessionID: session)
        health.handle(.microphoneRecoveryFailed, sessionID: session)
        #expect(health.microphone == .unavailable)
        #expect(health.hadMicrophoneInterruption)
        #expect(health.summary != nil)
    }

    @Test func microphoneOnlySessionIgnoresSystemAudioEvents() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        health.handle(.interrupted(), sessionID: session)
        #expect(health.systemAudio == .unused)
        #expect(!health.hadSystemAudioInterruption)
        #expect(health.summary == nil)
    }

    @Test func lateMicrophoneRecoveryCannotRewriteFrozenSummary() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        health.handle(.microphoneUnavailable, sessionID: session)
        health.finish()
        let frozen = health.summary
        let accepted = health.handle(.microphoneRecovered, sessionID: session)
        #expect(!accepted)
        #expect(health.microphone == .unavailable)
        #expect(health.summary == frozen)
    }

    @Test func microphoneEngineRestartWithoutGapIsNotReported() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        // 设备始终在场、仅引擎重启（首次尝试即恢复）：不应留下缺口记录
        health.handle(.microphoneRecovered, sessionID: session)
        #expect(health.microphone == .active)
        #expect(!health.hadMicrophoneInterruption)
        #expect(health.summary == nil)
    }

    @Test func micCaptureEventCarriesSessionGeneration() {
        let diagnostics = MicCaptureDiagnostics(
            stage: .startEngine,
            generation: 7,
            attempt: 3,
            deviceBound: false,
            oldSampleRate: 44_100,
            newSampleRate: 48_000,
            oldChannelCount: 1,
            newChannelCount: 2,
            errorDomain: "com.apple.coreaudio.avfaudio",
            errorCode: -10868,
            detail: nil
        )
        #expect(MicCaptureEvent.deviceUnavailable(diagnostics).generation == 7)
        #expect(MicCaptureEvent.recoveryFailed(diagnostics).generation == 7)
        #expect(MicCaptureEvent.writeFailed(userSummary: "写盘失败", diagnostics: diagnostics).generation == 7)
        #expect(MicCaptureEvent.recoveryStarted(attempt: 3, maxAttempts: 5, generation: 7).generation == 7)
        #expect(MicCaptureEvent.recovered(generation: 7).generation == 7)
    }

    /// 会话代次是「旧通知/旧事件不得操作新会话」的判据：停止后旧代次立即失效。
    @MainActor
    @Test func sessionGenerationInvalidatesLateEventsAcrossSessions() {
        let service = MicCaptureService()
        let firstSession = service.generation
        #expect(service.isCurrentGeneration(firstSession))
        service.stop()
        #expect(!service.isCurrentGeneration(firstSession))
        #expect(service.generation != firstSession)
    }

    /// AirPods 断开时 tap 写入会抛错，这类失败是设备切换的症状，不能报成「写入失败……建议停止后重新录制」。
    @Test func writeFailureDuringDeviceTransitionIsNotReportedAsDiskFailure() {
        // 引擎已停（设备刚消失）
        #expect(MicCaptureService.writeFailureIsDeviceTransition(
            engineRunning: false, secondsSinceConfigurationChange: nil,
            recordedSampleRate: 48_000, recordedChannelCount: 1,
            currentSampleRate: 48_000, currentChannelCount: 1
        ))
        // 刚处理过配置变化：设备路由尚未稳定
        #expect(MicCaptureService.writeFailureIsDeviceTransition(
            engineRunning: true, secondsSinceConfigurationChange: 1,
            recordedSampleRate: 48_000, recordedChannelCount: 1,
            currentSampleRate: 48_000, currentChannelCount: 1
        ))
        // 输入节点格式已与正在写入的分片不一致
        #expect(MicCaptureService.writeFailureIsDeviceTransition(
            engineRunning: true, secondsSinceConfigurationChange: 60,
            recordedSampleRate: 48_000, recordedChannelCount: 2,
            currentSampleRate: 44_100, currentChannelCount: 1
        ))
        // 尚未建立写入格式：按设备事件处理，不误报磁盘故障
        #expect(MicCaptureService.writeFailureIsDeviceTransition(
            engineRunning: true, secondsSinceConfigurationChange: nil,
            recordedSampleRate: nil, recordedChannelCount: nil,
            currentSampleRate: 0, currentChannelCount: 0
        ))
    }

    /// 磁盘满/IO 故障不被误判成设备切换（否则用户永远看不到真实的写入失败告警）。
    @Test func ordinaryWriteFailureStillReportsAsDiskFailure() {
        #expect(!MicCaptureService.writeFailureIsDeviceTransition(
            engineRunning: true, secondsSinceConfigurationChange: 600,
            recordedSampleRate: 48_000, recordedChannelCount: 1,
            currentSampleRate: 48_000, currentChannelCount: 1
        ))
    }
}
