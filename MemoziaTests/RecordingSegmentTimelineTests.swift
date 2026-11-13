import AVFoundation
import Foundation
import Testing
@testable import Memozia

@Suite(.serialized)
@MainActor
struct RecordingSegmentTimelineTests {
    /// 显式开启时只写静音；停止真实引擎但不发送配置通知，验证周期兜底能重建并确认首包。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_AUDIO_CAPTURE"] == "1"
                   && AVAudioApplication.shared.recordPermission == .granted))
    func stoppedRealEngineRecoversWithoutConfigurationNotification() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var engines: [AVAudioEngine] = []
        let mic = MicCaptureService(makeEngine: {
            let engine = AVAudioEngine()
            engines.append(engine)
            return engine
        })
        defer { mic.stop() }
        var opened: [URL] = []
        var index = 1
        mic.nextSegmentForFormatChange = {
            index += 1
            return dir.appendingPathComponent("sample_mic_tmp_\(index).caf")
        }
        mic.onFormatChangeSegmentOpened = { opened.append($0) }
        let first = dir.appendingPathComponent("sample_mic_tmp_1.caf")
        let timeline = RecordingSegmentTimelineStore()
        try await mic.start(to: first, initiallyMuted: true, timeline: timeline)
        let before = mic.writtenFrames
        try #require(engines.last).stop()
        mic.checkCaptureHealth()
        let deadline = ContinuousClock.now.advanced(by: .seconds(16))
        while mic.writtenFrames <= before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(mic.writtenFrames > before)
        #expect(!opened.isEmpty, "同格式恢复也必须开新片，不能把中断时间压缩进旧片")
        mic.stop()
        #expect(try AVAudioFile(forReading: first).length > 0)
        if let last = opened.last {
            let file = try AVAudioFile(forReading: last)
            #expect(file.length > 0)
            #expect(try energy(file, at: 0) == 0, "恢复保持用户静音")
        }
        timeline.finish()
        try timeline.save(in: dir)
        #expect(try RecordingSegmentTimeline.load(in: dir)?.starts.count ?? 0 >= 2)
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTimeline-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tone(_ url: URL, rate: Double = 24_000, seconds: Double = 0.4) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: #require(MicCaptureService.fileSettings(for: format)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate * seconds)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0.3 * sin(Float(index) * 2 * .pi * 700 / Float(rate)) }
        try file.write(from: buffer)
    }

    private func saveTimeline(_ starts: [String: Double], end: Double = 3, in folder: URL) throws {
        let timeline = RecordingSegmentTimeline(starts: starts, end: end)
        try JSONEncoder().encode(timeline).write(to: folder.appendingPathComponent(RecordingSegmentTimeline.fileName), options: .atomic)
    }

    private func energy(_ file: AVAudioFile, at seconds: Double) throws -> Float {
        file.framePosition = Int64(seconds * file.processingFormat.sampleRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        return (0..<Int(buffer.frameLength)).reduce(Float(0)) { $0 + abs(samples[$1]) } / Float(max(1, buffer.frameLength))
    }

    @Test func stoppedCallbacksDespiteRunningEngineTriggerOneBoundedRecovery() {
        var health = MicCaptureLiveness()
        let start = ContinuousClock.now
        health.wrote(at: start)
        #expect({ !health.shouldRecover(engineRunning: true, recoveryActive: false, now: start.advanced(by: .seconds(2))) }())
        #expect({ health.shouldRecover(engineRunning: true, recoveryActive: false, now: start.advanced(by: .seconds(3))) }())
        #expect({ !health.shouldRecover(engineRunning: true, recoveryActive: false, now: start.advanced(by: .seconds(30))) }(),
                "失败后的下一秒不能启动新一轮恢复并刷新预算")
        health.wrote(at: start.advanced(by: .seconds(31))) // 静音零缓冲与普通缓冲共用成功写入入口。
        health.recovered()
        #expect({ !health.shouldRecover(engineRunning: true, recoveryActive: false, now: start.advanced(by: .seconds(32))) }())
        #expect({ health.shouldRecover(engineRunning: false, recoveryActive: false, now: start.advanced(by: .seconds(32))) }())
    }

    @Test func routeRecoveryAndSilentWritesDoNotRestartWatchdogBudget() {
        var health = MicCaptureLiveness()
        let start = ContinuousClock.now
        health.wrote(at: start)
        health.recoveryBegan()
        #expect({ !health.shouldRecover(engineRunning: false, recoveryActive: true, now: start.advanced(by: .seconds(4))) }())
        #expect({ !health.shouldRecover(engineRunning: false, recoveryActive: false, now: start.advanced(by: .seconds(40))) }())
        health.recovered()
        for second in 1...10 {
            health.wrote(at: start.advanced(by: .seconds(second)))
            #expect({ !health.shouldRecover(engineRunning: true, recoveryActive: false, now: start.advanced(by: .seconds(second))) }())
        }
    }

    @Test func missingMiddleSegmentKeepsGapTrailingSilenceAndOriginals() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("sample_mic_tmp_0001.caf")
        let unreadable = dir.appendingPathComponent("sample_mic_tmp_0002.caf")
        let recovered = dir.appendingPathComponent("sample_mic_tmp_0003.caf")
        try tone(first)
        try Data(repeating: 1, count: 8_193).write(to: unreadable)
        try tone(recovered, rate: 48_000)
        try saveTimeline([first.lastPathComponent: 0, unreadable.lastPathComponent: 1, recovered.lastPathComponent: 2], in: dir)
        let recorder = MeetingRecorderService()
        let output = dir.appendingPathComponent("sample.m4a")
        let result = await recorder.mergeCapturedSegments(CapturedSegments(micURLs: [first, unreadable, recovered],
            sysURLs: [], finalURL: output, micFormatChanged: true))
        #expect(result == output)
        let file = try AVAudioFile(forReading: output)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3) < 0.1)
        #expect(try energy(file, at: 0.1) > 0.05)
        #expect(try energy(file, at: 1.1) < 0.005)
        #expect(try energy(file, at: 2.1) > 0.05, "恢复后的发言必须留在原时间，不能前移到 0.4 秒")
        #expect(try energy(file, at: 2.8) < 0.005)
        #expect([first, unreadable, recovered].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(recorder.recordingCaptureReport.skippedSegments == [unreadable.lastPathComponent])
        #expect(recorder.recordingCaptureReport.retainedOriginals == true)
    }

    @Test(arguments: ["caf", "wav"])
    func stoppedMergeRepairsContainerBeforeSkippingAndKeepsOriginal(ext: String) async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("sample_mic_tmp_0001.\(ext)")
        let later = dir.appendingPathComponent("sample_mic_tmp_0002.caf")
        try tone(broken)
        try tone(later)
        var bytes = try Data(contentsOf: broken)
        let data = try #require(bytes.range(of: Data("data".utf8)))
        if ext == "caf" {
            bytes.replaceSubrange(data.upperBound..<(data.upperBound + 8), with: repeatElement(UInt8(0), count: 8))
        } else {
            bytes.replaceSubrange(data.upperBound..<(data.upperBound + 4), with: repeatElement(UInt8(0), count: 4))
            bytes.replaceSubrange(4..<8, with: repeatElement(UInt8(0), count: 4))
        }
        try bytes.write(to: broken, options: .atomic)
        let brokenDuration = try? await AVURLAsset(url: broken).load(.duration)
        #expect(brokenDuration.map { !$0.seconds.isFinite || $0.seconds <= 0 } ?? true, "复现未 finalize 的容器")
        try saveTimeline([broken.lastPathComponent: 0, later.lastPathComponent: 2], in: dir)
        let output = dir.appendingPathComponent("sample.m4a")
        let recorder = MeetingRecorderService()
        let result = await recorder.mergeCapturedSegments(CapturedSegments(micURLs: [broken, later],
            sysURLs: [], finalURL: output, micFormatChanged: true))
        #expect(result == output)
        let file = try AVAudioFile(forReading: output)
        #expect(try energy(file, at: 0.1) > 0.05, "修复后的声音必须被合入")
        #expect(try energy(file, at: 1.1) < 0.005, "未采集到的声音不能被伪造或压缩")
        #expect(try energy(file, at: 2.1) > 0.05)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 3) < 0.1)
        #expect(try Data(contentsOf: broken) == bytes, "修复仅操作副本，不改写原始证据")
        #expect(FileManager.default.fileExists(atPath: later.path))
        let report = recorder.recordingCaptureReport
        #expect(report.repairedSegments == [broken.lastPathComponent])
        #expect(report.skippedSegments == nil)
        #expect(report.retainedOriginals == true)
        #expect(!report.isEmpty)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(!remaining.contains { $0.lastPathComponent.hasPrefix(".capture_repaired_") })
    }

    @Test func failedRepairDoesNotClaimSuccessOrLeaveCopies() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let unknown = dir.appendingPathComponent("unknown.caf")
        let bytes = Data(repeating: 1, count: 8_193)
        try bytes.write(to: unknown)
        #expect(await FileSyncService.repairedPCMContainerCopy(at: unknown) == nil)
        #expect(try Data(contentsOf: unknown) == bytes)
        let remaining = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(remaining.map(\.lastPathComponent) == [unknown.lastPathComponent])
    }

    @Test func crashRecoveryUsesSameTimelineAndPreservesUnreadableSegments() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("sample_mic_tmp_0001.caf")
        let second = dir.appendingPathComponent("sample_mic_tmp_0003.caf")
        let unknown = dir.appendingPathComponent("sample_mic_tmp_0002.caf")
        try tone(first)
        try tone(second)
        try Data(repeating: 1, count: 8_193).write(to: unknown)
        try saveTimeline([first.lastPathComponent: 0, second.lastPathComponent: 2], in: dir)
        let outcome = await FileSyncService.recoverCrashedRecording(from: dir,
            files: [first, unknown, second], skipFreshnessCheck: true)
        let result = try #require(outcome.recoveredURL)
        let file = try AVAudioFile(forReading: result)
        #expect(try energy(file, at: 1.1) < 0.005)
        #expect(try energy(file, at: 2.1) > 0.05)
        #expect([first, unknown, second].allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let report = try #require(try RecordingCaptureReportStore.load(in: dir))
        #expect(report.skippedSegments == [unknown.lastPathComponent])
        #expect(report.retainedOriginals == true)
    }

    @Test func missingOrCorruptTimingEvidenceDoesNotSilentlyCompactNewRecording() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("sample_mic_tmp_0001.caf")
        try tone(audio)
        let output = dir.appendingPathComponent("sample.m4a")
        let captured = CapturedSegments(micURLs: [audio], sysURLs: [], finalURL: output, micFormatChanged: false)
        try saveTimeline([:], in: dir)
        #expect(await MeetingRecorderService().mergeCapturedSegments(captured) == nil)
        try Data("broken".utf8).write(to: dir.appendingPathComponent(RecordingSegmentTimeline.fileName))
        #expect(await MeetingRecorderService().mergeCapturedSegments(captured) == nil)
        #expect(FileManager.default.fileExists(atPath: audio.path))
        #expect(throws: (any Error).self) { try RecordingSegmentTimeline.load(in: dir) }
    }

    @Test func echoReductionRequiresMatchingTimesAndDurations() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mic = dir.appendingPathComponent("mic.caf")
        let sys = dir.appendingPathComponent("sys.caf")
        try tone(mic)
        try tone(sys)
        var timeline = RecordingSegmentTimeline(starts: ["mic.caf": 0, "sys.caf": 0])
        #expect(await RecordingSegmentTimeline.canReduceEcho(mic: [mic], system: [sys], timeline: timeline))
        timeline.starts["sys.caf"] = 1
        #expect(!(await RecordingSegmentTimeline.canReduceEcho(mic: [mic], system: [sys], timeline: timeline)))
        #expect(!(await RecordingSegmentTimeline.canReduceEcho(mic: [mic], system: [sys, sys], timeline: timeline)))
        #expect(!(await RecordingSegmentTimeline.canReduceEcho(mic: [mic], system: [sys], timeline: nil)))
    }

    @Test func sidecarWritesOnlySuccessfulNonemptyFirstPacketAndKeepsLegacyReportsReadable() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RecordingSegmentTimelineStore()
        let url = dir.appendingPathComponent("mic.caf")
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        store.noteWrite(to: url, hostTime: now, frames: 0)
        try store.save(in: dir)
        #expect(try RecordingSegmentTimeline.load(in: dir)?.starts.isEmpty == true)
        store.noteWrite(to: url, hostTime: now, frames: 240)
        store.noteWrite(to: url, hostTime: now + 1, frames: 240)
        store.finish()
        try store.save(in: dir)
        #expect(try RecordingSegmentTimeline.load(in: dir)?.offset(for: url) == 0)
        let old = try JSONDecoder().decode(RecordingCaptureReport.self,
            from: Data(#"{"version":1,"interruptions":[],"issues":["audioDegraded"]}"#.utf8))
        #expect(old.retainedOriginals == nil)
        #expect(old.repairedSegments == nil)
        #expect(old.hasWarning)
    }
}
