import Foundation
import SwiftData
import Testing
@testable import Memozia

@Suite(.serialized)
@MainActor
struct MediaCleanupTests {
    private func withSandbox(_ operation: (URL, ModelContext) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoziaMediaCleanup-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        AudioRecording.setRuntimeStorageOverride(root)
        defer {
            AudioRecording.setRuntimeStorageOverride(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let container = try ModelContainer(for: AudioRecording.self, TranscriptSegment.self, QuickNote.self,
                                          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try await operation(root, ModelContext(container))
    }

    private func recording(_ context: ModelContext, folder: String = "20261102120000", video: Bool = false) throws -> AudioRecording {
        let url = AudioRecording.createFolder(named: folder)
        let recording = AudioRecording(fileName: "会议", fileExtension: "m4a", duration: 42,
                                       storedFileName: "audio.m4a", folderName: folder,
                                       videoFileName: video ? "audio_video.mp4" : nil)
        context.insert(recording)
        try Data(repeating: 7, count: 4096).write(to: recording.fileURL)
        if let video = recording.videoFileURL { try Data(repeating: 8, count: 8192).write(to: video) }
        try Data("todos".utf8).write(to: url.appendingPathComponent("todos.json"))
        try context.save()
        return recording
    }

    private func imageNote(_ context: ModelContext, folder: String = "20261102120001") throws -> QuickNote {
        _ = QuickNote.createFolder(named: folder)
        let note = QuickNote(title: "截图", textContent: "附注", sourceImageFileName: "source.png", ocrText: "识别文字", folderName: folder)
        note.summaryText = "图片总结"
        context.insert(note)
        try Data(repeating: 9, count: 2048).write(to: #require(note.sourceImageURL))
        try context.save()
        return note
    }

    @Test func audioCleanupKeepsTextAndRebuildsFromDiskWithoutAudio() async throws {
        try await withSandbox { _, context in
            let recording = try recording(context)
            let segment = TranscriptSegment(startTime: 0, endTime: 42, text: "原转写")
            segment.recording = recording
            recording.segments = [segment]
            context.insert(segment)
            recording.summary = "原总结"
            recording.transcriptionStatus = .completed
            // 额外文字文件不能让明确的录音条目在清理音频后被误路由为快捷笔记。
            try Data("附带文字".utf8).write(to: recording.folderURL.appendingPathComponent("source.txt"))
            let id = recording.id
            let request = try #require(MediaCleanupRequest(kind: .audio, items: [.recording(recording)]))
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 1 && result.freedBytes == 4096 && result.failures.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: recording.fileURL.path))
            #expect(recording.fullTranscript == "原转写" && recording.decryptedSummary == "原总结")
            #expect(recording.audioRemovedAt != nil)
            #expect(FileManager.default.fileExists(atPath: recording.folderURL.appendingPathComponent("todos.json").path))
            // 用空索引从权威文件重建，不能依赖仍在内存中的原模型。
            let restoredContext = ModelContext(context.container)
            context.delete(recording)
            try context.save()
            let sync = await FileSyncService.syncFromDisk(context: restoredContext)
            #expect(sync.newCount == 1)
            let restored = try #require(restoredContext.fetch(FetchDescriptor<AudioRecording>()).first)
            #expect(restored.id == id && restored.duration == 42)
            #expect(restored.fullTranscript == "原转写" && restored.decryptedSummary == "原总结")
            #expect(restored.audioRemovedAt != nil && !restored.isVideoRecording)
            #expect(try restoredContext.fetch(FetchDescriptor<QuickNote>()).isEmpty)
        }
    }

    @Test func imageCleanupPreservesIdentityOCRSummaryAndRebuildsEmptyImageNotes() async throws {
        try await withSandbox { _, context in
            let note = try imageNote(context)
            let empty = try imageNote(context, folder: "20261102120002")
            empty.textContent = nil
            empty.ocrText = nil
            empty.summaryText = nil
            let id = note.id
            let source = try #require(note.sourceImageURL)
            let request = try #require(MediaCleanupRequest(kind: .image, items: [.quickNote(note), .quickNote(empty)]))
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 2 && result.freedBytes == 4096 && result.failures.isEmpty)
            #expect(note.sourceImageFileName == nil && !note.hasImage && note.isImageNote)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(note.decryptedOcrText == "识别文字" && note.decryptedSummaryText == "图片总结")
            context.delete(note)
            context.delete(empty)
            try context.save()
            let restoredContext = ModelContext(context.container)
            let sync = await FileSyncService.syncFromDisk(context: restoredContext)
            #expect(sync.newCount == 2)
            let notes = try restoredContext.fetch(FetchDescriptor<QuickNote>())
            #expect(notes.count == 2 && notes.allSatisfy { $0.isImageNote && !$0.hasImage })
            let restored = try #require(notes.first { $0.id == id })
            #expect(restored.decryptedTextContent == "附注" && restored.decryptedOcrText == "识别文字")
            #expect(restored.decryptedSummaryText == "图片总结")
        }
    }

    @Test func mixedSelectionFiltersByMediaAndKeepsConfirmationTargets() async throws {
        try await withSandbox { _, context in
            let audio = try recording(context)
            let video = try recording(context, folder: "20261102120003", video: true)
            let note = try imageNote(context)
            let text = QuickNote(title: "文字", folderName: "20261102120004")
            let selection: Set<ListItem> = [.recording(audio), .recording(video), .quickNote(note), .quickNote(text)]
            let audioRequest = try #require(MediaCleanupRequest(kind: .audio, items: selection))
            let imageRequest = try #require(MediaCleanupRequest(kind: .image, items: selection))
            #expect(audioRequest.targets.count == 2 && audioRequest.estimatedBytes == 8192)
            #expect(imageRequest.targets.count == 1 && imageRequest.targets.first?.item == .quickNote(note))
            #expect(MediaCleanupRequest(kind: .video, items: selection)?.targets.count == 1)
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(audioRequest, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 2)
            #expect(FileManager.default.fileExists(atPath: try #require(video.videoFileURL).path))
            #expect(FileManager.default.fileExists(atPath: try #require(note.sourceImageURL).path))
            #expect(video.isVideoRecording)
        }
    }

    @Test func readOnlyAndBusyModesRejectWithoutDeleting() async throws {
        try await withSandbox { _, context in
            let recording = try recording(context)
            let request = try #require(MediaCleanupRequest(kind: .audio, items: [.recording(recording)]))
            await #expect(throws: PersistenceBlockedError.self) {
                _ = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readOnlyTransient)
            }
            await #expect(throws: MediaCleanupService.CleanupError.self) {
                _ = try await MediaCleanupService(isBusy: { true }).cleanup(request, context: context, persistence: .readWrite)
            }
            #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
            #expect(recording.audioRemovedAt == nil)
        }
    }

    @Test func metadataFailureKeepsOriginalAndModel() async throws {
        try await withSandbox { _, context in
            let recording = try recording(context)
            try Data("broken".utf8).write(to: recording.metaFileURL)
            let request = try #require(MediaCleanupRequest(kind: .audio, items: [.recording(recording)]))
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 0 && result.failures.count == 1)
            #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
            #expect(recording.audioRemovedAt == nil)
        }
    }

    @Test func batchContinuesAfterOneMissingFileAndReportsPartialResult() async throws {
        try await withSandbox { _, context in
            let first = try recording(context)
            let second = try recording(context, folder: "20261102120005")
            let request = try #require(MediaCleanupRequest(kind: .audio, items: [.recording(first), .recording(second)]))
            try FileManager.default.removeItem(at: first.fileURL)
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 1 && result.failures.count == 1 && result.freedBytes == 4096)
            #expect(first.audioRemovedAt == nil && second.audioRemovedAt != nil)
            #expect(try context.fetch(FetchDescriptor<AudioRecording>()).count == 2)
        }
    }

    @Test func refusesDirectoriesSymlinksAndPathsOutsideEntry() async throws {
        try await withSandbox { root, context in
            let recording = try recording(context)
            let url = recording.fileURL
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            let child = url.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: child)
            await #expect(throws: CocoaError.self) {
                _ = try await MediaCleanupService.removeOriginalFile(at: url, in: recording.folderURL)
            }
            #expect(FileManager.default.fileExists(atPath: child.path))
            let outside = root.appendingPathComponent("outside.m4a")
            try Data("keep".utf8).write(to: outside)
            let link = recording.folderURL.appendingPathComponent("link.m4a")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            await #expect(throws: CocoaError.self) {
                _ = try await MediaCleanupService.removeOriginalFile(at: link, in: recording.folderURL)
            }
            await #expect(throws: CocoaError.self) {
                _ = try await MediaCleanupService.removeOriginalFile(at: outside, in: recording.folderURL)
            }
            #expect(FileManager.default.fileExists(atPath: outside.path))
        }
    }

    @Test func batchVideoCleanupRetainsCachePrecondition() async throws {
        try await withSandbox { _, context in
            let recording = try recording(context, video: true)
            let video = try #require(recording.videoFileURL)
            let request = try #require(MediaCleanupRequest(kind: .video, items: [.recording(recording)]))
            let service = MediaCleanupService(isBusy: { false })
            let refused = try await service.cleanup(request, context: context, persistence: .readWrite)
            #expect(refused.cleanedCount == 0 && refused.failures.count == 1)
            #expect(FileManager.default.fileExists(atPath: video.path) && recording.videoFileName != nil)
            try FileManager.default.createDirectory(at: recording.framesDirectoryURL, withIntermediateDirectories: true)
            let frame = recording.framesDirectoryURL.appendingPathComponent(AudioRecording.frameFileName(index: 1, time: 1))
            try Data([1, 2, 3]).write(to: frame)
            try VideoUnderstandingService.framesCacheVersion.write(
                to: recording.framesDirectoryURL.appendingPathComponent(VideoUnderstandingService.framesCacheVersionFileName),
                atomically: true, encoding: .utf8)
            let cleaned = try await service.cleanup(request, context: context, persistence: .readWrite)
            #expect(cleaned.cleanedCount == 1 && cleaned.failures.isEmpty)
            #expect(recording.videoFileName == nil && recording.isVideoRecording)
            #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
            #expect(FileManager.default.fileExists(atPath: frame.path))
        }
    }

    @Test func fortySelectedImagesSurvivePartialContextMenuAndClearEveryOriginal() async throws {
        try await withSandbox { _, context in
            var notes: [QuickNote] = []
            for index in 0..<40 {
                let folder = index < 20 ? String(format: "2026110301%02d", index)
                    : String(format: "202611030100%02d-%d", index, index)
                let note = try imageNote(context, folder: folder)
                note.title = "image-\(index)"
                notes.append(note)
            }
            // 覆盖旧索引没有图片引用，以及引用指向已不存在文件的情况。
            notes[0].sourceImageFileName = nil
            notes[1].sourceImageFileName = "missing.png"
            let selection = Set(notes.map { ListItem.quickNote($0) })
            let contextItems: Set<ListItem> = [.quickNote(notes[10]), .quickNote(notes[11])]
            let resolved = MediaCleanupRequest.contextSelection(items: contextItems, selection: selection)
            #expect(resolved.count == 40)
            let request = try #require(MediaCleanupRequest(kind: .originals, items: resolved))
            #expect(request.selectedItemCount == 40 && request.targets.count == 40)
            #expect(request.estimatedBytes == 40 * 2048 && request.skippedEntryCount == 0)
            // 展示提示和固定载荷本身不能删除任何东西，确认后才调用 cleanup。
            #expect(notes.allSatisfy { FileManager.default.fileExists(atPath: $0.folderURL.appendingPathComponent("source.png").path) })
            let service = MediaCleanupService(isBusy: { false })
            let result = try await service.cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 40 && result.failures.isEmpty)
            #expect(result.freedBytes == 40 * 2048)
            #expect(service.completedTargetCount == 40 && service.targetCount == 40)
            #expect(notes.allSatisfy { !FileManager.default.fileExists(atPath: $0.folderURL.appendingPathComponent("source.png").path) })
            #expect(notes.allSatisfy { $0.sourceImageFileName == nil && $0.isImageNote })
            #expect(notes.allSatisfy { $0.decryptedOcrText == "识别文字" && $0.decryptedSummaryText == "图片总结" })
            #expect(try context.fetchCount(FetchDescriptor<QuickNote>()) == 40)
        }
    }

    @Test func rightClickOutsideSelectionNeverCleansPreviousSelection() async throws {
        try await withSandbox { _, context in
            let first = try imageNote(context)
            let second = try imageNote(context, folder: "20261103120002")
            let clicked = try imageNote(context, folder: "20261103120003")
            let selection: Set<ListItem> = [.quickNote(first), .quickNote(second)]
            let resolved = MediaCleanupRequest.contextSelection(items: [.quickNote(clicked)], selection: selection)
            #expect(resolved == [.quickNote(clicked)])
            #expect(MediaCleanupRequest.contextSelection(items: [], selection: selection).isEmpty)
            let request = try #require(MediaCleanupRequest(kind: .originals, items: resolved))
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 1 && result.failures.isEmpty)
            #expect(FileManager.default.fileExists(atPath: try #require(first.sourceImageURL).path))
            #expect(FileManager.default.fileExists(atPath: try #require(second.sourceImageURL).path))
        }
    }

    @Test func unifiedCleanupIncludesAudioImageAndVideoAndReportsEntriesWithoutSources() async throws {
        try await withSandbox { _, context in
            let audio = try recording(context)
            let video = try recording(context, folder: "20261103120004", video: true)
            let note = try imageNote(context)
            let text = QuickNote(title: "文字", textContent: "正文", folderName: "20261103120005")
            context.insert(text)
            try FileManager.default.createDirectory(at: video.framesDirectoryURL, withIntermediateDirectories: true)
            let frame = video.framesDirectoryURL.appendingPathComponent(AudioRecording.frameFileName(index: 1, time: 1))
            try Data([1, 2, 3]).write(to: frame)
            try VideoUnderstandingService.framesCacheVersion.write(
                to: video.framesDirectoryURL.appendingPathComponent(VideoUnderstandingService.framesCacheVersionFileName),
                atomically: true, encoding: .utf8)
            let sourceURLs = [audio.fileURL, video.fileURL, try #require(video.videoFileURL), try #require(note.sourceImageURL)]
            let request = try #require(MediaCleanupRequest(kind: .originals, items: [.recording(audio), .recording(video), .quickNote(note), .quickNote(text)]))
            #expect(request.selectedItemCount == 4 && request.targets.count == 4 && request.skippedEntryCount == 1)
            #expect(request.targets.filter { $0.kind == .audio }.count == 2)
            #expect(request.targets.filter { $0.kind == .video }.count == 1)
            #expect(request.targets.filter { $0.kind == .image }.count == 1)
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 4 && result.failures.isEmpty && result.skippedEntryCount == 1)
            #expect(sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(FileManager.default.fileExists(atPath: frame.path))
            #expect(video.isVideoRecording && video.audioRemovedAt != nil && video.videoFileName == nil)
            #expect(note.decryptedTextContent == "附注" && text.decryptedTextContent == "正文")
        }
    }

    @Test func batchResultListsEveryFailedOriginalAndContinuesTheRest() async throws {
        try await withSandbox { _, context in
            let first = try imageNote(context, folder: "20261103120010")
            let second = try imageNote(context, folder: "20261103120011")
            let third = try imageNote(context, folder: "20261103120012")
            first.title = "missing-image-A"
            second.title = "missing-image-B"
            let request = try #require(MediaCleanupRequest(kind: .originals, items: [.quickNote(first), .quickNote(second), .quickNote(third)]))
            try FileManager.default.removeItem(at: try #require(first.sourceImageURL))
            try FileManager.default.removeItem(at: try #require(second.sourceImageURL))
            let result = try await MediaCleanupService(isBusy: { false }).cleanup(request, context: context, persistence: .readWrite)
            #expect(result.cleanedCount == 1 && result.failures.count == 2)
            #expect(result.message.contains(first.title) && result.message.contains(second.title))
            #expect(third.sourceImageFileName == nil)
            #expect(first.sourceImageFileName != nil && second.sourceImageFileName != nil)
        }
    }
}
