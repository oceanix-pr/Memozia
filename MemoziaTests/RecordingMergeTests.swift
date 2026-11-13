import AVFoundation
import Foundation
import SwiftData
import Testing
@testable import Memozia

@Suite(.serialized) @MainActor
struct RecordingMergeTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingMergeTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func tone(at url: URL, frequency: Double, rate: Double = 24_000) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate / 2)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(0.35 * sin(Double(index) * 2 * .pi * frequency / rate))
        }
        try file.write(from: buffer)
    }

    private func input(in root: URL, name: String, frequency: Double, rate: Double = 24_000) throws -> RecordingMergeService.Input {
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("audio.wav")
        try tone(at: audio, frequency: frequency, rate: rate)
        try "{\"title\":\"\(name)\"}".write(to: folder.appendingPathComponent("meta.json"), atomically: true, encoding: .utf8)
        return RecordingMergeService.Input(id: UUID(), folderName: name, folderURL: folder, audioURL: audio,
            title: name, segments: [.init(startTime: 0.1, endTime: 0.4, speaker: name,
                                         rawText: try EncryptionService.encrypt("转写 \(name)"))],
            summary: try EncryptionService.encrypt("总结 \(name)"))
    }

    private func frequency(of url: URL, at seconds: Double) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        file.framePosition = AVAudioFramePosition(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(rate / 10)))
        try file.read(into: buffer)
        let samples = try #require(buffer.floatChannelData)[0]
        var crossings = 0
        for index in 1..<Int(buffer.frameLength) where samples[index - 1] < 0 && samples[index] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(buffer.frameLength) / rate)
    }

    @Test func audioContentOrderOffsetsAndAtomicCommit() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let early = try input(in: root, name: "early", frequency: 400)
        let middle = try input(in: root, name: "middle", frequency: 900, rate: 48_000)
        let latest = try input(in: root, name: "latest", frequency: 1500)
        let firstTodo = TodoItem(title: "早期待办", reminderIdentifier: "existing-reminder", status: .exported)
        try TodoDocument(source: "summary", model: "test", items: [firstTodo]).save(to: early.folderURL)
        try TodoDocument(source: "summary", model: "test", items: [TodoItem(title: "最新待办")]).save(to: latest.folderURL)
        let original = try Data(contentsOf: latest.audioURL)
        let prepared = try await RecordingMergeService().prepare([early, middle, latest])
        #expect(try Data(contentsOf: latest.audioURL) == original, "准备阶段不改原件")
        #expect(abs(prepared.duration - 1.5) < 0.05)
        #expect(abs(prepared.segments[1].startTime - 0.6) < 0.01)
        #expect(abs(prepared.segments[2].startTime - 1.1) < 0.01)
        #expect(prepared.segments.map(\.speaker) == ["early", "middle", "latest"])
        let merged = prepared.stagingURL.appendingPathComponent(prepared.audioName)
        #expect(abs(try frequency(of: merged, at: 0.15) - 400) < 35)
        #expect(abs(try frequency(of: merged, at: 0.65) - 900) < 35)
        #expect(abs(try frequency(of: merged, at: 1.15) - 1500) < 35)
        let summary = try EncryptionService.decrypt(try #require(prepared.encryptedSummary))
        #expect(summary.range(of: "总结 early")!.lowerBound < summary.range(of: "总结 latest")!.lowerBound)
        let document = try #require(TodoDocument.load(from: prepared.stagingURL))
        #expect(document.items.count == 2)
        #expect(document.items[0] == firstTodo)
        let transcript = try #require(EncryptionService.decryptFileOrPlaintext(at: prepared.stagingURL.appendingPathComponent("transcript.json")))
        let restored = try JSONDecoder().decode([TranscriptMirrorItem].self, from: Data(transcript.utf8))
        #expect(restored.map(\.text) == ["转写 early", "转写 middle", "转写 latest"])
        try RecordingMergeService.swap(prepared)
        #expect(FileManager.default.fileExists(atPath: latest.folderURL.appendingPathComponent(prepared.audioName).path))
        #expect(!FileManager.default.fileExists(atPath: latest.audioURL.path))
        #expect(try Data(contentsOf: prepared.stagingURL.appendingPathComponent("audio.wav")) == original)
        try RecordingMergeService.swap(prepared) // 数据库保存失败时的原子回滚。
        #expect(try Data(contentsOf: latest.audioURL) == original)
        RecordingMergeService.removeStaging(prepared.stagingURL)
    }

    @Test func missingAudioAndCorruptTodosKeepAllOriginals() async throws {
        for corruptTodo in [false, true] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let early = try input(in: root, name: "early", frequency: 400)
            let latest = try input(in: root, name: "latest", frequency: 900)
            let original = try Data(contentsOf: latest.audioURL)
            if corruptTodo {
                try "broken document".write(to: early.folderURL.appendingPathComponent(TodoDocument.fileName), atomically: true, encoding: .utf8)
            } else {
                try FileManager.default.removeItem(at: early.audioURL)
            }
            await #expect(throws: (any Error).self) { try await RecordingMergeService().prepare([early, latest]) }
            #expect(try Data(contentsOf: latest.audioURL) == original)
            #expect(FileManager.default.fileExists(atPath: early.folderURL.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["early", "latest"])
        }
    }

    @Test func duplicateSourceHistoryPreventsDoubleAppend() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let early = try input(in: root, name: "early", frequency: 400)
        let latest = try input(in: root, name: "latest", frequency: 900)
        try JSONEncoder().encode([early.id]).write(to: latest.folderURL.appendingPathComponent(RecordingMergeService.historyName))
        await #expect(throws: RecordingMergeService.MergeError.self) {
            try await RecordingMergeService().prepare([early, latest])
        }
        #expect(FileManager.default.fileExists(atPath: early.audioURL.path))
    }

    @Test func selectionSortVideoAndTransientGuards() async throws {
        let early = AudioRecording(fileName: "early", fileExtension: "wav", storedFileName: "early.wav")
        let latest = AudioRecording(fileName: "latest", fileExtension: "wav", storedFileName: "latest.wav")
        early.createdAt = Date(timeIntervalSince1970: 100)
        latest.createdAt = Date(timeIntervalSince1970: 200)
        #expect(RecordingViewModel.orderedMergeCandidates([latest, early])?.map(\.id) == [early.id, latest.id])
        #expect(RecordingViewModel.orderedMergeCandidates([early]) == nil)
        #expect(RecordingViewModel.orderedMergeCandidates([early, early]) == nil)
        latest.hasVideoSource = true
        #expect(RecordingViewModel.orderedMergeCandidates([early, latest]) == nil)
        latest.hasVideoSource = false
        latest.videoFileName = "old-video.mp4"
        #expect(RecordingViewModel.orderedMergeCandidates([early, latest]) == nil)
        latest.videoFileName = nil
        latest.createdAt = early.createdAt
        #expect(RecordingViewModel.orderedMergeCandidates([early, latest])?.map(\.id)
            == RecordingViewModel.orderedMergeCandidates([latest, early])?.map(\.id))
        let container = try ModelContainer(for: AudioRecording.self, TranscriptSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        context.insert(early)
        context.insert(latest)
        let vm = RecordingViewModel()
        vm.persistence = .readOnlyTransient
        #expect(await vm.mergeRecordings([latest, early], context: context) == nil)
        #expect(vm.showError)
        #expect(try context.fetchCount(FetchDescriptor<AudioRecording>()) == 2)
        #expect(!RecordingMergeActivity.shared.isRunning)
    }

    /// 单独运行此用例：异步期间覆盖进程存储根，不能与其他使用存储根的 suite 并跑。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_RECORDING_MERGE"] == "1"), arguments: [false, true])
    func endToEndLatestIdentityAndSourceDeletion(legacy: Bool) async throws {
        let root = try directory()
        AudioRecording.setRuntimeStorageOverride(root)
        defer {
            AudioRecording.setRuntimeStorageOverride(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let container = try ModelContainer(for: AudioRecording.self, TranscriptSegment.self, QuickNote.self, LLMConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        var recordings: [AudioRecording] = []
        let sentinel = root.appendingPathComponent("unrelated.txt")
        try "keep".write(to: sentinel, atomically: true, encoding: .utf8)
        for index in 0..<3 {
            let name = "2026102701000\(index)"
            let source = try input(in: root, name: name, frequency: Double(400 + index * 500))
            let storedName = legacy ? "legacy-\(index).wav" : "audio.wav"
            if legacy {
                try FileManager.default.moveItem(at: source.audioURL, to: root.appendingPathComponent(storedName))
                try FileManager.default.removeItem(at: source.folderURL)
            }
            let recording = AudioRecording(fileName: "标题 \(index)", fileExtension: "wav", duration: 99,
                                           storedFileName: storedName, folderName: legacy ? "" : name)
            recording.createdAt = Date(timeIntervalSince1970: Double(index + 1))
            recording.transcriptionStatus = .completed
            recording.summary = source.summary
            let segment = try #require(source.segments.first)
            recording.segments = [TranscriptSegment(startTime: segment.startTime, endTime: segment.endTime,
                                                    speaker: segment.speaker, text: segment.rawText)]
            context.insert(recording)
            recordings.append(recording)
        }
        let target = try #require(recordings.last)
        let targetID = target.id
        let targetDate = target.createdAt
        let oldPaths = recordings.map { legacy ? $0.fileURL : $0.folderURL }
        let todo = TodoItem(title: "保留待办", reminderIdentifier: "reminder-to-preserve", status: .exported)
        if !legacy {
            try TodoDocument(source: "summary", model: "test", items: [todo]).save(to: recordings[0].folderURL)
        }
        try context.save()
        let vm = RecordingViewModel()
        vm.selectedRecording = target
        let merged = try #require(await vm.mergeRecordings([recordings[1], target, recordings[0]], context: context))
        #expect(merged.id == targetID)
        #expect(merged.fileName == "标题 2")
        #expect(merged.createdAt == targetDate)
        #expect(try context.fetchCount(FetchDescriptor<AudioRecording>()) == 1)
        #expect(oldPaths.dropLast().allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        #expect(FileManager.default.fileExists(atPath: sentinel.path))
        #expect(!merged.folderName.isEmpty)
        if legacy { #expect(!FileManager.default.fileExists(atPath: oldPaths.last!.path)) }
        #expect(abs(merged.duration - 1.5) < 0.05)
        #expect(merged.segments.count == 3)
        #expect(merged.transcriptionStatus == .completed)
        if !legacy { #expect(TodoDocument.load(from: merged.folderURL)?.items == [todo]) }
        #expect(vm.selectedRecording?.id == targetID)
        #expect(!vm.showError)
        #expect(!RecordingMergeActivity.shared.isRunning)
        let committedName = merged.storedFileName
        // 模拟目录交换后、索引提交前崩溃留下的旧音频指针。
        merged.storedFileName = "missing-old-audio.wav"
        merged.fileExtension = "wav"
        merged.duration = 99
        for segment in merged.segments { context.delete(segment) }
        merged.segments = [TranscriptSegment(startTime: 0.1, endTime: 0.4,
                                             text: try EncryptionService.encrypt("旧索引中的最新一笔转写"))]
        merged.transcriptModifiedAt = Date()
        merged.summary = try EncryptionService.encrypt("旧索引中的最新一笔总结")
        merged.summaryGeneratedAt = Date()
        try context.save()
        _ = await FileSyncService.syncFromDisk(context: context)
        #expect(merged.storedFileName == committedName)
        #expect(merged.fileExtension == "m4a")
        #expect(abs(merged.duration - 1.5) < 0.05)
        #expect(merged.segments.count == 3, "完整提交的转写必须覆盖旧索引，不受 1 秒时间容差影响")
        #expect(merged.decryptedSummary.contains("总结 20261027010000"))
        #expect(try context.fetchCount(FetchDescriptor<AudioRecording>()) == 1, "磁盘对账不应复活较早录音")
        #expect(abs(try frequency(of: merged.fileURL, at: 0.15) - 400) < 35)
        #expect(abs(try frequency(of: merged.fileURL, at: 1.15) - 1400) < 35)
    }
}
