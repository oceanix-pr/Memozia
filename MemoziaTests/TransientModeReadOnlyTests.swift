import Foundation
import Testing
import SwiftData

@testable import Memozia

/// BK-1：临时模式（不落盘）端到端只读。
///
/// 背景：临时模式下界面声称「不会保存任何改动」，但门控此前只在 `RootView` 的少数按钮上，
/// 重命名、隐藏、编辑转写/总结、改待办等入口仍可能直接写文件或只写内存库。本文件钉住
/// 新的唯一事实来源 `PersistenceCapability` 与三层边界（视图 / ViewModel / 服务）：
///
/// 1. 只有 `readWrite` 允许内容修改，`readOnlyTransient` 一律拒绝，且拒绝时给出提示；
/// 2. 被拒绝时不产生任何持久化副作用（模型不变、不写文件、不入队）；
/// 3. 未注入能力的默认路径仍是 `readWrite`，正常模式行为不变（防过度拦截）。
@Suite(.serialized)
@MainActor
struct TransientModeReadOnlyTests {

    // MARK: - 工具

    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            AudioRecording.self,
            TranscriptSegment.self,
            LLMConfig.self,
            QuickNote.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
        )
        return ModelContext(container)
    }

    /// 空 folderName 的录音：所有 `*ToFolder` 落盘 helper 会直接返回，测试因此完全不碰磁盘
    private func makeRecording(title: String = "原标题") -> AudioRecording {
        AudioRecording(
            fileName: title,
            fileExtension: "m4a",
            storedFileName: "test.m4a",
            folderName: ""
        )
    }

    private func recordingCount(_ context: ModelContext) throws -> Int {
        try context.fetch(FetchDescriptor<AudioRecording>()).count
    }

    // MARK: - PersistenceGuard 纯语义

    @Test("只有 readWrite 允许内容修改，只读拒绝时携带操作类型")
    func testCapabilitySemantics() {
        #expect(PersistenceGuard.readWrite.capability.allowsContentMutation)
        #expect(PersistenceGuard.readWrite.rejection(for: .editSummary) == nil)

        #expect(PersistenceGuard.readOnlyTransient.capability.isTransient)
        #expect(PersistenceGuard.readOnlyTransient.allows(.editSummary) == false)
        #expect(PersistenceGuard.readOnlyTransient.rejection(for: .editSummary)?.operation == .editSummary)
        #expect(PersistenceGuard.readOnlyTransient.rejection(for: .createEntry) != nil)
        #expect(PersistenceGuard.readOnlyTransient.rejection(for: .createEntry)?.message.isEmpty == false)
    }

    // MARK: - RecordingViewModel

    @Test("临时模式下标题/隐藏/转写/删除全部被拒绝，模型不变并给出提示")
    func testRecordingMutationsBlockedInTransient() throws {
        let context = try makeContext()
        let recording = makeRecording()
        context.insert(recording)

        let vm = RecordingViewModel()
        vm.persistence = .readOnlyTransient

        vm.updateRecordingTitle(recording, newTitle: "新标题", context: context)
        #expect(recording.fileName == "原标题", "临时模式不得改标题")

        vm.toggleRecordingHidden(recording, context: context)
        #expect(recording.isHidden == false, "临时模式不得隐藏条目")

        vm.updateTranscriptMarkdown(recording, newMarkdown: "编辑后的转写", context: context)
        #expect(recording.segments.isEmpty, "临时模式不得改写转写片段")

        vm.deleteRecording(recording, context: context)
        #expect(try recordingCount(context) == 1, "临时模式不得删除条目")

        #expect(vm.showError, "被拒绝时必须给出提示，而不是静默失败")
        #expect(vm.errorMessage?.isEmpty == false)
    }

    @Test("正常（readWrite）模式下同样的操作照常生效——防过度拦截")
    func testRecordingMutationsAllowedInReadWrite() throws {
        let context = try makeContext()
        let recording = makeRecording()
        context.insert(recording)

        let vm = RecordingViewModel()
        vm.persistence = .readWrite

        vm.updateRecordingTitle(recording, newTitle: "改后的标题", context: context)
        #expect(recording.fileName == "改后的标题")

        vm.toggleRecordingHidden(recording, context: context)
        #expect(recording.isHidden)

        vm.deleteRecording(recording, context: context)
        #expect(try recordingCount(context) == 0)
    }

    // MARK: - QuickNoteViewModel

    @Test("临时模式下快捷笔记标题/总结/删除被拒绝，模型不变")
    func testQuickNoteMutationsBlockedInTransient() throws {
        let context = try makeContext()
        let note = QuickNote(title: "原标题", folderName: "20260923120000")
        context.insert(note)

        let vm = QuickNoteViewModel()
        vm.persistence = .readOnlyTransient

        vm.updateTitle(note, newTitle: "新标题", context: context)
        #expect(note.title == "原标题", "临时模式不得改标题")

        let saved = vm.updateSummary("新的总结", for: note, context: context)
        #expect(saved == false, "临时模式不得写总结")

        vm.deleteQuickNote(note, context: context)
        let remaining = try context.fetch(FetchDescriptor<QuickNote>()).count
        #expect(remaining == 1, "临时模式不得删除快捷笔记")
        #expect(vm.showError)
    }

    // MARK: - 服务边界

    @Test("临时模式下镜像写入器不写任何文件")
    func testEntryMirrorStoreBlockedInTransient() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaReadOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let wrote = LockedBox(false)
        let store = EntryMirrorStore { _, _ in wrote.value = true }
        store.capability = .readOnlyTransient

        let url = dir.appendingPathComponent("summary.md")
        store.submit("总结", kind: .summary, folderName: "20260923120000", to: url)
        store.submitTranscript([], folderName: "20260923120000", to: dir.appendingPathComponent("transcript.json"))

        let saved = await store.writeNow(
            "画面要点", kind: .visual, folderName: "20260923120000",
            to: dir.appendingPathComponent("visual.md")
        )
        #expect(saved == false, "临时模式 writeNow 必须返回 false")

        _ = await store.flush(timeout: .seconds(1))
        #expect(wrote.value == false, "临时模式不得触发任何镜像写入")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("临时模式下后台任务队列入队失败")
    func testBackgroundTaskQueueBlockedInTransient() {
        BackgroundTaskQueue.installCapability(.readOnlyTransient)
        defer { BackgroundTaskQueue.installCapability(.readWrite) }

        #expect(BackgroundTaskQueue.capability.isTransient)

        let enqueued = BackgroundTaskQueue.enqueue(
            BackgroundTaskEntry(kind: .transcription, folderName: "20260923120000")
        )
        #expect(enqueued == false, "临时模式不得写入磁盘队列")
    }

    @Test("未注入能力的默认路径仍是 readWrite")
    func testDefaultCapabilityIsReadWrite() {
        #expect(EntryMirrorStore().capability == .readWrite)
        #expect(BackgroundTaskQueue.capability == .readWrite)
    }
}
