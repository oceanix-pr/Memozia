import Foundation
import SwiftData
import AVFoundation
import Testing
@testable import Memozia

@Suite(.serialized)
@MainActor
struct RecordingCaptureReportTests {
    private func writeAudio(to url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let settings = try #require(MicCaptureService.fileSettings(for: format))
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                  commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        buffer.floatChannelData?[0].update(repeating: 0, count: 128)
        try file.write(from: buffer)
    }

    private func recoveredReport() -> RecordingCaptureReport {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        let start = Date(timeIntervalSince1970: 1_000)
        health.handle(.microphoneRecovering, sessionID: session, at: start)
        health.handle(.microphoneUnavailable, sessionID: session, at: start.addingTimeInterval(1),
                      lastSuccessfulWriteAt: start.addingTimeInterval(-1))
        health.handle(.microphoneRecovered, sessionID: session, at: start.addingTimeInterval(2))
        health.finish(at: start.addingTimeInterval(3))
        return health.report
    }

    @Test func nominalSwitchDoesNotInventMissingSpeech() {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        health.handle(.microphoneRecovering, sessionID: session)
        health.handle(.microphoneRecovered, sessionID: session)
        health.finish()
        #expect(health.report.isEmpty)
    }

    @Test func muteEvidenceCoversEntireInterruption() throws {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        health.microphoneMuteChanged(true)
        health.handle(.microphoneRecovering, sessionID: session)
        health.handle(.microphoneUnavailable, sessionID: session)
        health.microphoneMuteChanged(false)
        health.microphoneMuteChanged(true)
        health.handle(.microphoneRecovered, sessionID: session)
        #expect(!(try #require(health.report.interruptions.first)).mutedThroughout,
                "当前静音不能掩盖区间内曾经解除静音")

        health.handle(.microphoneRecovering, sessionID: session)
        health.handle(.microphoneUnavailable, sessionID: session)
        health.handle(.microphoneRecovered, sessionID: session)
        #expect(try #require(health.report.interruptions.last).mutedThroughout)
    }

    @Test func stopDuringUnconfirmedRecoveryPreservesUnknownState() throws {
        let session = UUID()
        var health = RecordingCaptureHealth(usesMicrophone: true, sessionID: session)
        health.handle(.microphoneRecovering, sessionID: session)
        health.finish()
        #expect(!(try #require(health.report.interruptions.first)).recovered)
        let frozen = health.report
        let accepted = health.handle(.microphoneRecovered, sessionID: session)
        #expect(!accepted)
        #expect(health.report == frozen)
    }

    @Test func reportRoundTripAndCorruptionAreDistinctFromLegacyAbsence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try RecordingCaptureReportStore.load(in: folder) == nil)
        let report = recoveredReport()
        try RecordingCaptureReportStore.save(report, in: folder)
        #expect(try RecordingCaptureReportStore.load(in: folder) == report)
        let interval = try #require(report.interruptions.first)
        #expect(interval.lastSuccessfulWriteAt == Date(timeIntervalSince1970: 999))
        #expect(interval.observedStart == Date(timeIntervalSince1970: 1_000))
        #expect(interval.observedEnd == Date(timeIntervalSince1970: 1_002))
        try Data("corrupt".utf8).write(to: folder.appendingPathComponent(RecordingCaptureReportStore.fileName))
        #expect(throws: (any Error).self) { try RecordingCaptureReportStore.load(in: folder) }
    }

    @Test func repairedContainersAreInformationalButDoNotEraseCaptureGaps() throws {
        var report = RecordingCaptureReport(repairedSegments: ["sample_mic_tmp_0001.caf"])
        #expect(!report.isEmpty)
        #expect(!report.hasWarning)
        #expect(report.summary == String(localized: "音频分片已自动修复并合入录音。"))
        #expect(try JSONDecoder().decode(RecordingCaptureReport.self, from: JSONEncoder().encode(report)) == report)
        report.interruptions = recoveredReport().interruptions
        #expect(report.hasWarning, "修好容器不等于补回中断期间没有采集到的声音")
        #expect(report.summary?.contains(try #require(report.interruptions.first).message) == true)
    }

    @Test func crashRebuildKeepsOriginalsPreviouslyRetainedAfterAutomaticRepair() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("sample_mic_tmp_0001.caf")
        try writeAudio(to: original)
        let report = RecordingCaptureReport(repairedSegments: [original.lastPathComponent], retainedOriginals: true)
        try RecordingCaptureReportStore.save(report, in: folder)
        #expect(!report.hasWarning, "自动修复信息本身不是故障")
        let result = await FileSyncService.recoverCrashedRecording(from: folder, files: [original], skipFreshnessCheck: true)
        #expect(result.recoveredURL != nil)
        #expect(FileManager.default.fileExists(atPath: original.path), "后续恢复必须尊重已有的原片保留标记")
        #expect(try RecordingCaptureReportStore.load(in: folder) == report)
    }

    @Test func recoveredStopUsesFeedbackAndReportSurvivesTitleEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AudioRecording.setRuntimeStorageOverride(root)
        defer {
            AudioRecording.setRuntimeStorageOverride(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let folderName = try #require(AudioRecording.createUniqueFolder(from: Date()))
        let schema = Schema([AudioRecording.self, TranscriptSegment.self, LLMConfig.self, QuickNote.self])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let recording = AudioRecording(fileName: "Test", fileExtension: "m4a",
            storedFileName: "test.caf", folderName: folderName)
        try writeAudio(to: recording.fileURL)
        let vm = RecordingViewModel()
        let report = recoveredReport()
        await vm.finishRecordingSave(recording: recording, report: report, context: context)
        #expect(!vm.showError, "已恢复的历史中断不能进入错误弹窗")
        #expect(vm.recordingFeedback?.folderName == folderName)
        #expect(vm.recordingFeedback?.isWarning == true)
        #expect(try context.fetchCount(FetchDescriptor<AudioRecording>()) == 1)
        #expect(try RecordingCaptureReportStore.load(in: recording.folderURL) == report)
        recording.fileName = "Renamed"
        #expect(recording.saveMetaToFolder())
        #expect(try RecordingCaptureReportStore.load(in: recording.folderURL) == report)
        vm.recordingFeedback = nil
        #expect(try RecordingCaptureReportStore.load(in: recording.folderURL) == report,
                "关闭横幅不会删除采集记录")
    }

    @Test func failedDetailSaveNeverPublishesSavedFeedback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AudioRecording.setRuntimeStorageOverride(root)
        defer {
            AudioRecording.setRuntimeStorageOverride(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let schema = Schema([AudioRecording.self, TranscriptSegment.self, LLMConfig.self, QuickNote.self])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let folderName = try #require(AudioRecording.createUniqueFolder(from: Date()))
        let recording = AudioRecording(fileName: "Report write failure", fileExtension: "caf",
            storedFileName: "test.caf", folderName: folderName)
        try writeAudio(to: recording.fileURL)
        try FileManager.default.createDirectory(
            at: recording.folderURL.appendingPathComponent(RecordingCaptureReportStore.fileName),
            withIntermediateDirectories: false
        )
        let vm = RecordingViewModel()
        await vm.finishRecordingSave(recording: recording, report: recoveredReport(), context: ModelContext(container))
        #expect(vm.recordingFeedback == nil)
    }

    @Test func recoveryPreservesExistingEvidenceAndUnreadableSmallFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let report = recoveredReport()
        try RecordingCaptureReportStore.save(report, in: folder)
        let shell = folder.appendingPathComponent("sample_mic_tmp_0001.caf")
        try Data(repeating: 0, count: 16).write(to: shell)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        _ = await FileSyncService.recoverCrashedRecording(from: folder, files: files, skipFreshnessCheck: true)
        let updated = try #require(try RecordingCaptureReportStore.load(in: folder))
        #expect(updated.interruptions == report.interruptions, "恢复不能改写已有采集中断证据")
        #expect(updated.retainedOriginals == true)
        #expect(FileManager.default.fileExists(atPath: shell.path), "小且不可读的文件不能当成零帧空壳删除")
    }
}
