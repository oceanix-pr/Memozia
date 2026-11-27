import AppKit
import AVFoundation
import Foundation
import ImageIO
import SwiftData
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Memozia

@MainActor @Suite(.serialized)
struct ProcessingReliabilityTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Processing-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private final class Entry: TodoEntry {
        let id = UUID()
        var folderName: String { folderURL.lastPathComponent }
        let folderURL: URL
        init(_ url: URL) { folderURL = url }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_EPHEMERAL_TEST_ENCRYPTION"] == "1"))
    func editsUseTheTargetFileEvenWhileItsLoadIsPending() async throws {
        let a = Entry(try directory()), b = Entry(try directory())
        defer { try? FileManager.default.removeItem(at: a.folderURL); try? FileManager.default.removeItem(at: b.folderURL) }
        for (entry, name) in [(a, "A"), (b, "B")] {
            try TodoDocument(source: "manual", model: "test", items: [TodoItem(title: name)]).save(to: entry.folderURL)
        }
        let vm = RecordingViewModel()
        vm.loadTodoDocument(for: a)
        for _ in 0..<300 where !vm.todoEditor.ready { try await Task.sleep(for: .milliseconds(2)) }
        #expect(vm.currentTodoDocument(for: a)?.items.first?.title == "A")
        vm.loadTodoDocument(for: b)
        #expect(vm.currentTodoDocument(for: b) == nil)
        vm.addTodoItem(TodoItem(title: "new"), for: b)
        #expect(try TodoDocument.read(from: b.folderURL)?.items.map(\.title) == ["B", "new"])
        #expect(try vm.currentTodoDocument(for: b) == TodoDocument.read(from: b.folderURL))
        #expect(try TodoDocument.read(from: a.folderURL)?.items.map(\.title) == ["A"])
        let draft = try #require(vm.currentTodoDocument(for: b))
        var newer = draft
        newer.items[0].title = "user edit"
        try newer.save(to: b.folderURL)
        #expect(throws: (any Error).self) { try vm.saveExtracted(draft, for: b, replacing: draft) }
        #expect(try TodoDocument.read(from: b.folderURL)?.items.first?.title == "user edit")
        vm.persistence = .readOnlyTransient
        vm.clearTodos(for: b)
        vm.addTodoItem(TodoItem(title: "blocked"), for: b)
        #expect(vm.currentTodoDocument(for: b)?.items.count == 2)
        let file = b.folderURL.appendingPathComponent(TodoDocument.fileName)
        try Data("damaged".utf8).write(to: file)
        vm.persistence = .readWrite
        vm.addTodoItem(TodoItem(title: "blocked"), for: b)
        #expect(try String(contentsOf: file, encoding: .utf8) == "damaged")
        #expect(vm.showError)
    }

    @Test func mirrorFlushIncludesPreparationAndClearsRecoveredFailure() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcript.json")
        let reject = LockedBox(true)
        let store = EntryMirrorStore { text, target in
            if reject.value { throw CocoaError(.fileWriteUnknown) }
            try Data(text.utf8).write(to: target, options: .atomic)
        }
        let snapshot = [AudioRecording.TranscriptSnapshotItem(startTime: 0, endTime: 1, speaker: "A", rawText: "text")]
        store.submitStoredTranscript(snapshot, folderName: "a", to: url)
        #expect(!(await store.flush()).isComplete)
        reject.value = false
        store.submitStoredTranscript(snapshot, folderName: "a", to: url)
        let flush = await store.flush()
        #expect(flush.isComplete && flush.failed == 1 && flush.errors.isEmpty)
        #expect(try JSONDecoder().decode([TranscriptMirrorItem].self, from: Data(contentsOf: url)).first?.text == "text")
    }

    private final class ReminderExport: TodoReminderExporting {
        var duringExport: () throws -> Void = {}
        var removed: [String] = []
        var isAuthorized: Bool { true }
        func requestAccess() async -> Bool { true }
        func writeReminders(items: [TodoItem], to list: String) async -> (updatedItems: [TodoItem], success: Int, failed: Int) {
            do { try duringExport() } catch { Issue.record(error) }
            let saved = items.map { item in
                var item = item
                item.reminderIdentifier = "test-" + item.id
                item.status = .exported
                return item
            }
            return (saved, saved.count, 0)
        }
        func deleteReminder(identifier: String) -> Bool { removed.append(identifier); return true }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_EPHEMERAL_TEST_ENCRYPTION"] == "1"))
    func reminderReceiptsFollowTheOriginalEntryAndKeepConcurrentEdits() async throws {
        let a = Entry(try directory()), b = Entry(try directory())
        defer { try? FileManager.default.removeItem(at: a.folderURL); try? FileManager.default.removeItem(at: b.folderURL) }
        let first = TodoItem(title: "Keep"), second = TodoItem(title: "Remove")
        let original = try TodoDocument(source: "manual", model: "", items: [first, second]).save(to: a.folderURL)
        let other = try TodoDocument(source: "manual", model: "", items: [TodoItem(title: "Other")]).save(to: b.folderURL)
        let vm = QuickNoteViewModel()
        vm.loadTodoDocument(for: a)
        for _ in 0..<300 where !vm.todoEditor.ready { try await Task.sleep(for: .milliseconds(2)) }
        let service = ReminderExport()
        service.duringExport = {
            vm.loadTodoDocument(for: b)
            var edited = original
            edited.items.removeLast()
            edited.items[0].title = "Updated"
            try edited.save(to: a.folderURL)
        }
        await vm.writeTodosToReminders(for: a, defaultListID: "", using: service)
        let onDisk = try TodoDocument.read(from: a.folderURL)
        let saved = try #require(onDisk)
        #expect(saved.items.count == 1 && saved.items[0].title == "Updated")
        #expect(saved.items[0].reminderIdentifier == "test-" + first.id && saved.items[0].status == .failed)
        #expect(service.removed == ["test-" + second.id])
        #expect(try TodoDocument.read(from: b.folderURL) == other)
    }

    @Test func thumbnailsTrackAtomicReplacementAndRequestedPixels() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("image.png")
        func write(red: CGFloat, blue: CGFloat) throws {
            let ctx = try #require(CGContext(data: nil, width: 1000, height: 500, bitsPerComponent: 8, bytesPerRow: 4000,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(red: red, green: 0, blue: blue, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 500))
            let data = NSMutableData()
            let dest = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
            #expect(CGImageDestinationFinalize(dest))
            try (data as Data).write(to: url, options: .atomic)
        }
        let loader = NoteImageLoader()
        try write(red: 1, blue: 0)
        let red = try await loader.load(url, pixels: 100)
        #expect(red.width == 100 && red.height == 50)
        #expect(try await loader.load(url, pixels: 100) === red)
        try write(red: 0, blue: 1)
        let blue = try await loader.load(url, pixels: 100)
        #expect(blue !== red)
        #expect(try await loader.load(url, pixels: 300).width == 300)
    }

    @Test func slowMicrophoneWriterDoesNotBlockTheCallbackAndDrainsBeforeRotation() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let url = dir.appendingPathComponent("a.caf")
        let store = MicCaptureFileStore(maxPending: 1)
        store.file = try AVAudioFile(forWriting: url, settings: format.settings)
        let id = UUID()
        store.activate(id)
        let blocked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let failures = LockedBox(0)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        input.frameLength = 1024
        input.floatChannelData![0].update(repeating: 0.25, count: 1024)
        let pool = MicBufferPool(format: format)
        #expect(store.enqueue(tap: id, frames: 1024) {
            guard let owned = pool.copy(input.audioBufferList, frames: 1024, muted: false) else { return nil }
            return { file in
                blocked.signal()
                _ = release.wait(timeout: .now() + 3)
                do { try file.write(from: owned.buffer) } catch { failures.value += 1 }
                pool.recycle(owned)
            }
        } == .accepted)
        #expect(blocked.wait(timeout: .now() + 1) == .success)
        input.floatChannelData![0].update(repeating: 0, count: 1024)
        #expect(store.enqueue(tap: id, frames: 1024) { nil } == .full)
        #expect(store.statistics.droppedFrames == 1024)
        release.signal()
        let second = dir.appendingPathComponent("b.caf")
        store.file = try AVAudioFile(forWriting: second, settings: format.settings)
        store.invalidateTap()
        #expect(store.enqueue(tap: id, frames: 1024) { nil } == .retired)
        store.file = nil
        #expect(failures.value == 0)
        let saved = try AVAudioFile(forReading: url)
        #expect(saved.length == 1024)
        let check = try #require(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: 1024))
        try saved.read(into: check)
        #expect(check.floatChannelData?[0][0] == 0.25)
        #expect(try AVAudioFile(forReading: second).length == 0)
    }

    @Test func failedEntryStepDoesNotKeepItsWindowOrContextAlive() async throws {
        let container = StartupModelContainerFactory.makeTransient()
        let center = TaskCenter()
        weak var previousVM: RecordingViewModel?
        weak var previousContext: ModelContext?
        do {
            let vm = RecordingViewModel()
            let context = ModelContext(container)
            previousVM = vm
            previousContext = context
            let factory = EntryProcessingSteps(context: context, container: container, recordings: vm, notes: nil,
                                               experience: .standard, persistence: .readWrite, languages: .success(EntryLanguageOptions()))
            let step = factory.processing(.recording(UUID()), .summary(asMeeting: nil), approved: .builtInQwen)
            _ = center.enqueue(TaskCenter.Job(folderName: "absent", title: "", steps: [step], isDurable: true))
        }
        for _ in 0..<300 where center.failedJobs.isEmpty { try await Task.sleep(for: .milliseconds(2)) }
        #expect(center.failedJobs.count == 1)
        #expect(previousVM == nil && previousContext == nil)
    }

    @Test func deletingTheSelectedRecordingPreservesAnotherRecordingsTranscription() async throws {
        let container = StartupModelContainerFactory.makeTransient()
        let context = ModelContext(container)
        func recording() -> AudioRecording {
            AudioRecording(fileName: "fixture", fileExtension: "wav", storedFileName: "missing.wav", folderName: UUID().uuidString)
        }
        let running = recording(), selected = recording()
        context.insert(running)
        context.insert(selected)
        try context.save()
        let vm = RecordingViewModel()
        vm.selectedRecording = selected
        let task = vm.startTranscription(recording: running, sttConfig: STTConfig(enableSpeakerDiarization: false),
                                         context: context, origin: .worker)
        vm.deleteRecording(selected, context: context, deleteFile: false)
        #expect(await task.value == .failed)
        #expect(running.transcriptionStatus == .failed)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_EPHEMERAL_TEST_ENCRYPTION"] == "1"))
    func searchRefreshesCachedTextAndPreservesSeekTime() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let container = try StartupModelContainerFactory.makePersistent(at: dir.appendingPathComponent("search.store"))
        let context = ModelContext(container)
        let r = AudioRecording(fileName: "example", fileExtension: "wav", storedFileName: "sample.wav", folderName: UUID().uuidString)
        let n = QuickNote(title: "example", textContent: try EncryptionService.encrypt("Meeting notes"), folderName: UUID().uuidString)
        let segment = TranscriptSegment(startTime: 42, endTime: 45, text: "Meeting transcript")
        r.segments = [segment]
        context.insert(r)
        context.insert(n)
        try context.save()
        let index = FullTextSearch.Index()
        let initial = try await index.search("meeting", in: container, includeHidden: false)
        #expect(initial.hits[r.folderName]?.seconds == 42)
        #expect(initial.hits[n.folderName]?.snippet == "Meeting notes")
        n.isHidden = true
        segment.text = try EncryptionService.encrypt("Changed")
        r.transcriptModifiedAt = Date()
        try context.save()
        #expect(try await index.search("meeting", in: container, includeHidden: false).hits.isEmpty)
        #expect(try await index.search("meeting", in: container, includeHidden: true).hits.count == 1)
        #expect(try await index.search("changed", in: container, includeHidden: false).hits[r.folderName]?.seconds == 42)
    }

    @Test func nativeSidebarKeepsTheListAndSelectionWhenAMonthChanges() async throws {
        let container = StartupModelContainerFactory.makeTransient()
        let first = QuickNote(title: "First", folderName: UUID().uuidString)
        let second = QuickNote(title: "Second", folderName: UUID().uuidString)
        let earlier = QuickNote(title: "Earlier", folderName: UUID().uuidString)
        earlier.createdAt = try #require(Calendar.current.date(byAdding: .month, value: -1, to: Date()))
        for note in [first, second, earlier] { container.mainContext.insert(note) }
        try container.mainContext.save()
        var selected: Set<ListItem> = [.quickNote(first)]
        func view(_ notes: [QuickNote]) -> some View {
            RecordingListView(recordings: [], quickNotes: notes,
                selectedListItems: Binding(get: { selected }, set: { selected = $0 }),
                onDeleteRecording: { _ in }, onRecordingTitleChange: { _, _ in }, editingItemID: .constant(nil))
                .modelContainer(container)
        }
        let host = NSHostingView(rootView: view([first, earlier]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        func table(in node: NSView) -> NSTableView? {
            if let table = node as? NSTableView { return table }
            return node.subviews.lazy.compactMap { table(in: $0) }.first
        }
        func rows(_ expected: Int) async throws -> NSTableView {
            for _ in 0..<150 {
                window.contentView?.layoutSubtreeIfNeeded()
                if let list = table(in: host), list.numberOfRows == expected { return list }
                try await Task.sleep(for: .milliseconds(10))
            }
            let list = try #require(table(in: host))
            try #require(list.numberOfRows == expected)
            return list
        }
        let original = try await rows(3)
        host.rootView = view([first, second, earlier])
        #expect(try await rows(4) === original)
        host.rootView = view([first, earlier])
        #expect(try await rows(3) === original)
        #expect(selected == [.quickNote(first)])
    }

    // The worker resolves its queue relative to the process-wide storage root. Run alone, as for RecordingMergeTests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_RECOVERY"] == "1"))
    func workerPersistsTheFailureOfTheClaimedEntry() async throws {
        let dir = try directory()
        AudioRecording.setRuntimeStorageOverride(dir)
        defer { AudioRecording.setRuntimeStorageOverride(nil); try? FileManager.default.removeItem(at: dir) }
        let container = StartupModelContainerFactory.makeTransient()
        let context = ModelContext(container)
        let r = AudioRecording(fileName: "test", fileExtension: "wav", storedFileName: "test.wav", folderName: "20260101090000")
        context.insert(r)
        try context.save()
        let entry = BackgroundTaskEntry(kind: .summary, folderName: r.folderName, llmConfigID: BuiltInQwenModel.id, experience: .standard)
        #expect(BackgroundTaskQueue.enqueue(entry))
        let live = BackgroundTaskEntry(kind: .transcription, folderName: "live")
        let foreground = try #require(TaskExecutionOrigin.foreground.register(live) { _ in })
        await BackgroundWorker.drainQueue(context: context)
        #expect(BackgroundTaskQueue.loadFromDisk().tasks.contains { $0.id == live.id && $0.attempt == nil })
        foreground.finish(.cancelled)
        let data = BackgroundTaskQueue.loadFromDisk()
        #expect(data.tasks.count == 1 && data.tasks.first?.id == entry.id)
        #expect(data.tasks.first?.attempt == 1 && data.tasks.first?.nextRetryAt != nil)
        #expect(data.inProgressID == nil && data.failedEntries.isEmpty)
        #expect(!BackgroundTaskQueue.recordRetryableFailure(id: UUID(), code: .processingFailed))
    }
}
