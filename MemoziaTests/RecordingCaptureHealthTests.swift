import Foundation
import AVFoundation
import Testing
@testable import Memozia

struct RecordingCaptureHealthTests {
    /// 显式启用且已有采集权限才运行；不弹授权框、不修改权限或用户录音。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_AUDIO_CAPTURE"] == "1"
                   && SystemAudioCaptureService.preflightPermission()))
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
