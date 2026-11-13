import Foundation
import SwiftData
#if os(macOS)
import AppKit
#endif
import os.log

/// 快捷笔记 ViewModel：创建笔记、AI 拆解待办、写入提醒事项
@MainActor
@Observable
final class QuickNoteViewModel {

    /// 当前选中的快捷笔记
    var selectedQuickNote: QuickNote? {
        didSet {
            if selectedQuickNote?.id != oldValue?.id {
                // 切换笔记时按新笔记恢复「进行中态 + 流式内容」
                syncSummaryDisplayForSelection()
            }
        }
    }

    // 待办相关状态
    var isExtractingTodos = false
    private var todoExtractionProgress: [UUID: TodoExtractionService.Progress] = [:]
    var todoExtractionProgressText: String {
        selectedQuickNote.flatMap { todoExtractionProgress[$0.id] }?.text ?? String(localized: "AI 拆解中...")
    }
    var currentTodoDocument: TodoDocument?
    var isWritingTodos = false

    // 总结相关状态
    var isGeneratingSummary = false
    var summaryText = ""
    /// 流式「思考过程」（推理型模型的 reasoning_content）：仅供生成期间展示与诊断，
    /// 不写入总结、不入库；为空表示当前模型/服务端没有回传思考内容
    var summaryReasoningText = ""

    // 错误处理
    var errorMessage: String?
    var showError = false

    /// 临时模式只读门控：由 RootView 在启动时注入；默认 readWrite（单测/未注入路径保持可写）
    @ObservationIgnored
    var persistence: PersistenceGuard = .readWrite

    /// 临时模式门控：只读时给出统一提示并返回 true（调用方应立即 return）
    private func rejectWriteIfReadOnly(_ operation: PersistenceOperation) -> Bool {
        guard let blocked = persistence.rejection(for: operation) else { return false }
        showErrorMessage(blocked.message)
        return true
    }

    private let logger = Logger(subsystem: "app.memozia", category: "QuickNoteVM")

    // 按笔记 UUID 分字典管理执行句柄：不同笔记的同类任务互相独立，
    // 新任务只取消「同一笔记」的上一次任务，不会误伤其它笔记正在跑的任务。
    @ObservationIgnored private var summaryTasks: [UUID: Task<StepOutcome, Never>] = [:]
    @ObservationIgnored private var titleTasks: [UUID: Task<StepOutcome, Never>] = [:]
    @ObservationIgnored private var todoExtractionTasks: [UUID: Task<StepOutcome, Never>] = [:]
    /// 每个笔记的总结执行上下文（令牌 + 文件夹，供取消时出队埋点）
    private struct SummaryRun { let token: UUID; let folderName: String }
    @ObservationIgnored private var summaryRuns: [UUID: SummaryRun] = [:]
    /// 每个笔记的流式总结缓冲：按笔记隔离，只有当前展示笔记才写入共享 UI 状态
    @ObservationIgnored private var noteSummaryBuffers: [UUID: String] = [:]
    /// 每个笔记的流式展示节流时间（CFAbsoluteTime）：与录音总结的上屏节流口径一致。
    /// 合批回调本身约每 50ms 一次，这里再限制整体上屏频率，避免长总结持续占用主线程
    @ObservationIgnored private var noteSummaryFlushTimes: [UUID: CFAbsoluteTime] = [:]
    /// 每个笔记的流式「思考过程」缓冲（与正文分开累积，口径与录音总结一致）
    @ObservationIgnored private var noteSummaryReasoningBuffers: [UUID: String] = [:]
    @ObservationIgnored private var noteSummaryReasoningFlushTimes: [UUID: CFAbsoluteTime] = [:]
    /// 每个笔记本次执行的脱敏映射：正文与思考文本的流式缓冲存的都是含占位符的原始
    /// token，展示时按映射全量还原（与录音总结同一口径）。图片笔记/本地模型无映射
    @ObservationIgnored private var noteSummaryScrubMappings: [UUID: PIIScrubMapping] = [:]
    /// 正在生成总结的笔记集合（供切笔记时恢复「进行中」态）
    @ObservationIgnored private var generatingSummaryIDs: Set<UUID> = []
    /// 正在拆解待办的笔记集合（供切笔记时恢复「进行中」态）
    @ObservationIgnored private var extractingTodoIDs: Set<UUID> = []
    @ObservationIgnored private var titleExecutions: [UUID: UUID] = [:]
    @ObservationIgnored private var todoExtractionExecutions: [UUID: UUID] = [:]

    // MARK: - 创建快捷笔记

    /// 从文字创建快捷笔记
    /// - Parameters:
    ///   - text: 文字内容
    ///   - context: SwiftData 上下文
    /// - Returns: 创建的 QuickNote
    @discardableResult
    func createQuickNote(from text: String, context: ModelContext) -> QuickNote? {
        guard !rejectWriteIfReadOnly(.createEntry) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showErrorMessage(String(localized: "文字内容为空"))
            return nil
        }

        let now = Date()
        // 原子创建独占文件夹名：并发新建同一秒不会共用目录、互相覆盖 source.txt/source.png
        guard let folderName = AudioRecording.createUniqueFolder(from: now) else {
            showErrorMessage(String(localized: "创建笔记文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。"))
            return nil
        }
        let folderURL = AudioRecording.resolveFolderURL(forFolderName: folderName)

        // G-1: 写入 source.txt（加密存储，与数据库加密一致）
        do {
            try EncryptionService.encryptAndWrite(trimmed, to: folderURL.appendingPathComponent("source.txt"))
        } catch {
            try? FileManager.default.removeItem(at: folderURL)
            showErrorMessage(String(localized: "写入文件失败：\(error.localizedDescription)"))
            return nil
        }

        // 加密文字内容存入数据库
        var encryptedText: String?
        do {
            encryptedText = try EncryptionService.encrypt(trimmed)
        } catch {
            EncryptionService.reportEncryptionFailure(error, context: "快捷笔记文字")
            encryptedText = trimmed
        }

        let title = makeDefaultTitle(text: trimmed, date: now)
        let note = QuickNote(
            title: title,
            textContent: encryptedText,
            sourceImageFileName: nil,
            ocrText: nil,
            folderName: folderName
        )
        note.createdAt = now
        context.insert(note)
        guard note.saveMetaToFolder() else {
            context.delete(note)
            try? FileManager.default.removeItem(at: folderURL)
            showErrorMessage(String(localized: "保存笔记元数据失败"))
            return nil
        }

        do {
            try context.save()
            logger.info("创建文字快捷笔记：\(folderName)")
            return note
        } catch {
            context.delete(note)
            try? FileManager.default.removeItem(at: folderURL)
            showErrorMessage(String(localized: "保存失败：\(error.localizedDescription)"))
            return nil
        }
    }

    /// 从图片创建快捷笔记
    /// - Parameters:
    ///   - imageData: PNG 图片数据
    ///   - context: SwiftData 上下文
    /// - Returns: 创建的 QuickNote
    @discardableResult
    func createQuickNote(fromImage imageData: Data, context: ModelContext) -> QuickNote? {
        guard !rejectWriteIfReadOnly(.createEntry) else { return nil }
        let now = Date()
        // 原子创建独占文件夹名：并发新建同一秒不会共用目录、互相覆盖 source.png
        guard let folderName = AudioRecording.createUniqueFolder(from: now) else {
            showErrorMessage(String(localized: "创建笔记文件夹失败，请检查存储目录是否可写、磁盘空间是否充足后重试。"))
            return nil
        }
        let folderURL = AudioRecording.resolveFolderURL(forFolderName: folderName)

        // 保存图片为 source.png
        let imageFileName = "source.png"
        do {
            try imageData.write(to: folderURL.appendingPathComponent(imageFileName))
        } catch {
            try? FileManager.default.removeItem(at: folderURL)
            showErrorMessage(String(localized: "保存图片失败：\(error.localizedDescription)"))
            return nil
        }

        let title = String(format: String(localized: "图片笔记 %@"), now.formatted(date: .abbreviated, time: .shortened))
        let note = QuickNote(
            title: title,
            textContent: nil,
            sourceImageFileName: imageFileName,
            ocrText: nil,
            folderName: folderName
        )
        note.createdAt = now
        context.insert(note)
        guard note.saveMetaToFolder() else {
            context.delete(note)
            try? FileManager.default.removeItem(at: folderURL)
            showErrorMessage(String(localized: "保存笔记元数据失败"))
            return nil
        }

        do {
            try context.save()
            logger.info("创建图片快捷笔记：\(folderName)")
            return note
        } catch {
            context.delete(note)
            try? FileManager.default.removeItem(at: folderURL)
            showErrorMessage(String(localized: "保存失败：\(error.localizedDescription)"))
            return nil
        }
    }

    /// 从剪贴板创建快捷笔记（自动识别文字/图片）
    @discardableResult
    func createQuickNoteFromClipboard(context: ModelContext) -> QuickNote? {
        guard !rejectWriteIfReadOnly(.createEntry) else { return nil }
        #if os(macOS)
        let pasteboard = NSPasteboard.general

        // 优先检查图片
        if let tiffData = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiffData),
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            return createQuickNote(fromImage: pngData, context: context)
        }
        if let pngData = pasteboard.data(forType: .png) {
            return createQuickNote(fromImage: pngData, context: context)
        }

        // 其次检查文字
        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return createQuickNote(from: text, context: context)
        }

        showErrorMessage(String(localized: "剪贴板中没有可识别的文字或图片"))
        return nil
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        showErrorMessage(String(localized: "此功能仅在 macOS 上可用"))
        return nil
        */
        #endif
    }

    // MARK: - AI 总结

    /// 为快捷笔记生成 AI 总结
    /// - 图片笔记：走多模态图片直发（视觉模型）或 Vision OCR 降级（非视觉模型）
    /// - 文字笔记：走文本总结（概要模板，非会议格式）
    /// - Returns: 任务结果强类型化：`.succeeded` 仅当本次确实产出总结并已落库/落盘
    @discardableResult
    func generateSummary(
        for note: QuickNote,
        llmConfig: LLMConfig,
        context: ModelContext,
        experience: AppExperience? = nil
    ) -> Task<StepOutcome, Never> {
        guard !rejectWriteIfReadOnly(.startProcessing) else { return Task { .cancelled } }
        let noteID = note.id
        let folderName = note.folderName
        // 只取消「同一笔记」的上一次总结：不同笔记各自持有独立句柄，互不干扰
        summaryTasks[noteID]?.cancel()
        let executionToken = UUID()
        summaryRuns[noteID] = SummaryRun(token: executionToken, folderName: folderName)

        let taskExperience = experience ?? AppExperiencePreference.resolved()
        // 后台任务队列埋点：用户发起总结时入队（幂等），守护进程据此续跑
        if !BackgroundTaskQueue.enqueue(BackgroundTaskEntry(
            kind: .quicknoteSummary,
            folderName: folderName,
            llmConfigID: llmConfig.id,
            experience: taskExperience
        )) {
            showErrorMessage(String(localized: "任务已在前台开始，但未能写入后台续跑队列；请保持应用开启完成本次任务，退出后需重新发起。"))
        }

        noteSummaryBuffers[noteID] = ""
        noteSummaryReasoningBuffers[noteID] = ""
        noteSummaryScrubMappings[noteID] = nil
        generatingSummaryIDs.insert(noteID)
        if isSelectedNote(noteID) {
            isGeneratingSummary = true
            summaryText = ""
            summaryReasoningText = ""
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return StepOutcome.cancelled }
            defer { self.finishNoteSummary(noteID: noteID, executionToken: executionToken) }
            do {
                try SummaryHistory.preserve(note.summaryText, in: note.folderURL)
                let snapshot = try LLMConfigSnapshot(config: llmConfig)
                let result: String
                if note.hasImage, let imageURL = note.sourceImageURL,
                   let imageData = try? Data(contentsOf: imageURL) {
                    // 图片笔记走流式：逐 token 写入本条目的缓冲（视图已有流式渲染分支）
                    result = try await LLMService.generateSummaryFromImage(
                        imageData: imageData,
                        config: snapshot,
                        onToken: { token in
                            Task { @MainActor in
                                self.appendNoteSummaryToken(
                                    token, noteID: noteID, executionToken: executionToken
                                )
                            }
                        },
                        onReasoning: { token in
                            // 思考内容与正文分开展示：仅生成期间可见，用于解释「正文为空」
                            Task { @MainActor in
                                self.appendNoteSummaryReasoningToken(
                                    token, noteID: noteID, executionToken: executionToken
                                )
                            }
                        },
                        onAttemptStart: {
                            // 重试前清空本次流式缓冲，避免新旧 token 重复拼接
                            Task { @MainActor in
                                self.resetNoteSummaryBuffer(noteID: noteID, executionToken: executionToken)
                            }
                        }
                    )
                } else {
                    let text = note.combinedTextForExtraction
                    guard !text.isEmpty else {
                        self.showErrorMessage(String(localized: "笔记内容为空，无法生成总结"))
                        return .failed
                    }
                    // 普通模式始终开启云端文本脱敏，并使用任务入队时的模式快照；
                    // 避免用户在请求执行期间切换模式改变隐私语义。
                    let savedPIIValue = UserDefaults.standard.object(forKey: "enable_pii_scrub") as? Bool ?? true
                    let piiEnabled = EffectiveSettingsResolver.piiScrubEnabled(
                        savedValue: savedPIIValue,
                        experience: taskExperience
                    )
                    let scrubbed = (piiEnabled && snapshot.shouldScrubText)
                        ? PIIScrubService.scrub(text) : nil
                    // 记下本次执行的映射：流式正文/思考文本在展示时逐次全量还原，
                    // 与最终落库用的还原口径一致
                    self.noteSummaryScrubMappings[noteID] = scrubbed?.mapping
                    // 文字笔记天然非会议：跳过会议判定，直接走概要总结模板
                    let generated = try await LLMService.generateSummary(
                        transcript: scrubbed?.scrubbed ?? text,
                        config: snapshot,
                        forceOverview: true,
                        onToken: { token in
                            Task { @MainActor in
                                self.appendNoteSummaryToken(
                                    token, noteID: noteID, executionToken: executionToken
                                )
                            }
                        },
                        onReasoning: { token in
                            Task { @MainActor in
                                self.appendNoteSummaryReasoningToken(
                                    token, noteID: noteID, executionToken: executionToken
                                )
                            }
                        },
                        onAttemptStart: {
                            Task { @MainActor in
                                self.resetNoteSummaryBuffer(noteID: noteID, executionToken: executionToken)
                            }
                        }
                    )
                    result = scrubbed.map {
                        PIIScrubService.restore(generated, mapping: $0.mapping)
                    } ?? generated
                }

                guard !result.isEmpty else {
                    self.showErrorMessage(String(localized: "总结生成失败：LLM 返回了空内容。请检查模型配置或稍后重试。"))
                    return .failed
                }

                let encrypted = try EncryptionService.encrypt(result)
                note.summaryText = encrypted
                note.summaryGeneratedAt = Date()
                self.saveSummaryToFolder(result, for: note)
                let saved = PersistenceReporting.saveOrReport { try context.save() }
                // 只有当前展示笔记才写入共享 UI 状态，避免并发串数据
                if self.isSelectedNote(noteID) { self.summaryText = result }
                // 总结完成后自动生成标题并更新列表标题（与录音/截图总结后行为一致）；
                // 仅默认标题时生效，失败仅日志，不影响总结本身
                await self.autoAssignNoteTitle(
                    note,
                    from: result,
                    config: snapshot,
                    context: context,
                    experience: taskExperience
                )
                return saved ? .succeeded : .failed
            } catch is CancellationError {
                return .cancelled
            } catch {
                if self.isSelectedNote(noteID) {
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
                return .failed
            }
        }
        summaryTasks[noteID] = task
        return task
    }

    /// 取消指定笔记的总结（队列「取消」入口，只影响该笔记的句柄）
    func cancelSummary(noteID: UUID) {
        summaryTasks[noteID]?.cancel()
        summaryTasks[noteID] = nil
        if let run = summaryRuns[noteID] {
            BackgroundTaskQueue.dequeue(kind: .quicknoteSummary, folderName: run.folderName)
        }
        summaryRuns[noteID] = nil
        noteSummaryBuffers[noteID] = nil
        noteSummaryFlushTimes[noteID] = nil
        noteSummaryReasoningBuffers[noteID] = nil
        noteSummaryReasoningFlushTimes[noteID] = nil
        noteSummaryScrubMappings[noteID] = nil
        generatingSummaryIDs.remove(noteID)
        if isSelectedNote(noteID) {
            isGeneratingSummary = false
            summaryReasoningText = ""
        }
    }

    /// 兼容旧入口：取消当前展示笔记的总结
    func cancelSummary() {
        guard let id = selectedQuickNote?.id else { return }
        cancelSummary(noteID: id)
    }

    /// 总结收尾：仅当仍是本次执行时才清理句柄与出队，避免旧执行误清新执行的状态
    private func finishNoteSummary(noteID: UUID, executionToken: UUID) {
        guard summaryRuns[noteID]?.token == executionToken else { return }
        let folderName = summaryRuns[noteID]?.folderName ?? ""
        summaryRuns[noteID] = nil
        summaryTasks[noteID] = nil
        noteSummaryBuffers[noteID] = nil
        noteSummaryFlushTimes[noteID] = nil
        noteSummaryReasoningBuffers[noteID] = nil
        noteSummaryReasoningFlushTimes[noteID] = nil
        noteSummaryScrubMappings[noteID] = nil
        generatingSummaryIDs.remove(noteID)
        if isSelectedNote(noteID) {
            isGeneratingSummary = false
            // 思考过程仅生成期间可见：收尾即清空，正文与已保存总结不受影响
            summaryReasoningText = ""
        }
        BackgroundTaskQueue.dequeue(kind: .quicknoteSummary, folderName: folderName)
    }

    /// 流式 token 追加到「本次执行」的缓冲；只有当前展示笔记才写入共享 UI 状态。
    ///
    /// `executionToken` 校验是必需的：`onToken` 回调经 `Task { @MainActor }` 跳到主线程，
    /// 取消/重试后仍可能有已在途的尾块到达。旧实现只判 `summaryRuns[noteID] != nil`，
    /// 无法区分执行代次——新请求一旦开始，旧请求的迟到 token 就会被拼进新缓冲（内容错乱）。
    private func appendNoteSummaryToken(_ token: String, noteID: UUID, executionToken: UUID) {
        guard summaryRuns[noteID]?.token == executionToken else { return }
        let buffer = (noteSummaryBuffers[noteID] ?? "") + token
        noteSummaryBuffers[noteID] = buffer
        guard isSelectedNote(noteID) else { return }
        // 上屏节流：与录音总结一致，减少长总结对主线程的持续占用
        let now = CFAbsoluteTimeGetCurrent()
        guard now - (noteSummaryFlushTimes[noteID] ?? 0) >= 0.1 else { return }
        noteSummaryFlushTimes[noteID] = now
        summaryText = restoredNoteSummaryText(buffer, noteID: noteID)
    }

    /// 重试前清空本次执行的流式缓冲；同样校验执行代次，避免清掉新请求已积累的内容
    private func resetNoteSummaryBuffer(noteID: UUID, executionToken: UUID) {
        guard summaryRuns[noteID]?.token == executionToken else { return }
        noteSummaryBuffers[noteID] = ""
        noteSummaryFlushTimes[noteID] = CFAbsoluteTimeGetCurrent()
        noteSummaryReasoningBuffers[noteID] = ""
        noteSummaryReasoningFlushTimes[noteID] = CFAbsoluteTimeGetCurrent()
        if isSelectedNote(noteID) {
            summaryText = ""
            summaryReasoningText = ""
        }
    }

    /// 流式「思考过程」缓冲：与正文分开累积，0.3s 节流上屏（与录音总结同一口径）。
    /// 执行令牌校验同正文：取消/重试后仍可能有在途尾块，必须按代次丢弃。
    private func appendNoteSummaryReasoningToken(
        _ token: String,
        noteID: UUID,
        executionToken: UUID
    ) {
        guard summaryRuns[noteID]?.token == executionToken else { return }
        let buffer = (noteSummaryReasoningBuffers[noteID] ?? "") + token
        noteSummaryReasoningBuffers[noteID] = buffer
        guard isSelectedNote(noteID) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - (noteSummaryReasoningFlushTimes[noteID] ?? 0) >= 0.3 else { return }
        noteSummaryReasoningFlushTimes[noteID] = now
        summaryReasoningText = restoredNoteSummaryText(buffer, noteID: noteID)
    }

    /// 按本次执行的脱敏映射还原占位符：每次对完整缓冲全量还原，可正确处理占位符
    /// 被流式 token 切断的情况（如 "[人名" 与 "1]" 分片到达）；无映射时原样返回
    private func restoredNoteSummaryText(_ raw: String, noteID: UUID) -> String {
        guard let mapping = noteSummaryScrubMappings[noteID], !mapping.isEmpty else { return raw }
        return PIIScrubService.restore(raw, mapping: mapping)
    }

    private func isSelectedNote(_ noteID: UUID) -> Bool {
        selectedQuickNote?.id == noteID
    }

    /// 切换选中笔记时同步总结/待办相关的共享 UI 态：
    /// 正在后台跑的另一笔记不得把它的进行中态与流式内容显示到当前笔记上。
    private func syncSummaryDisplayForSelection() {
        let id = selectedQuickNote?.id
        isGeneratingSummary = id.map { generatingSummaryIDs.contains($0) } ?? false
        isExtractingTodos = id.map { extractingTodoIDs.contains($0) } ?? false
        if let id, generatingSummaryIDs.contains(id) {
            summaryText = restoredNoteSummaryText(noteSummaryBuffers[id] ?? "", noteID: id)
            summaryReasoningText = restoredNoteSummaryText(
                noteSummaryReasoningBuffers[id] ?? "", noteID: id)
        } else {
            // 思考过程仅生成期间可见：非生成中的笔记不残留上一条目的思考内容
            summaryReasoningText = ""
        }
    }

    /// 更新总结内容（手动编辑后保存）
    /// - Returns: 是否保存成功。加密失败不再把原值改成 nil；任一步失败都返回 false，
    ///   调用方据此保留编辑草稿、维持编辑态
    @discardableResult
    func updateSummary(_ text: String, for note: QuickNote, context: ModelContext) -> Bool {
        guard !rejectWriteIfReadOnly(.editSummary) else { return false }
        // 先生成加密结果，成功后才修改模型：旧实现把 `try? encrypt` 直接赋给字段，
        // 加密失败会把已保存的总结清成 nil（内容凭空丢失）
        let encrypted: String
        do {
            try SummaryHistory.preserve(note.summaryText, in: note.folderURL)
            encrypted = try EncryptionService.encrypt(text)
        } catch {
            logger.error("总结加密失败，保留原内容: \(error.localizedDescription)")
            return false
        }
        note.summaryText = encrypted
        note.summaryGeneratedAt = Date()
        summaryText = text
        saveSummaryToFolder(text, for: note)
        // 磁盘镜像（summary.md）是权威源：即使数据库保存失败，下次对账也能补写
        let saved = PersistenceReporting.saveOrReport { try context.save() }
        guard saved else {
            logger.error("总结更新保存到数据库失败，保留文件与草稿待下次对账补写")
            return false
        }
        return true
    }

    /// 加载已有总结到 summaryText。
    /// 正在生成总结时不覆盖流式内容，改为展示本条目的流式缓冲，避免丢失正在上屏的文本。
    func loadSummary(for note: QuickNote) {
        let noteID = note.id
        if generatingSummaryIDs.contains(noteID) {
            if let buffer = noteSummaryBuffers[noteID] {
                summaryText = restoredNoteSummaryText(buffer, noteID: noteID)
            } else {
                summaryText = note.decryptedSummaryText
            }
            summaryReasoningText = restoredNoteSummaryText(
                noteSummaryReasoningBuffers[noteID] ?? "", noteID: noteID)
        } else {
            summaryText = note.decryptedSummaryText
            summaryReasoningText = ""
        }
    }

    /// 更新文字笔记正文（手动重新编辑后保存）。
    /// 与创建逻辑保持一致：数据库 textContent 加密 + 磁盘 source.txt 加密 + meta 预览刷新。
    /// - Returns: 是否保存成功。加密或磁盘写入失败都返回 false（不修改模型、保留草稿）
    @discardableResult
    func updateTextContent(_ text: String, for note: QuickNote, context: ModelContext) -> Bool {
        guard !rejectWriteIfReadOnly(.editTextContent) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // 先生成加密结果，成功后才修改模型：旧实现把 `try? encrypt` 直接赋给字段，
        // 加密失败会把正文清成 nil（数据库内容凭空丢失）
        let encrypted: String
        do {
            encrypted = try EncryptionService.encrypt(trimmed)
        } catch {
            logger.error("文字内容加密失败，保留原内容: \(error.localizedDescription)")
            return false
        }
        // 磁盘文件（source.txt）是权威源：写入失败就不动数据库，避免「数据库有、磁盘无」的不一致
        do {
            try EncryptionService.encryptAndWrite(trimmed, to: note.folderURL.appendingPathComponent("source.txt"))
        } catch {
            logger.error("文字内容磁盘写入失败，保留原内容: \(error.localizedDescription)")
            return false
        }
        note.textContent = encrypted
        note.saveMetaToFolder()
        // 文件已写入（权威源）而数据库保存失败：登记失败，下次对账可从 source.txt 补写
        let saved = PersistenceReporting.saveOrReport { try context.save() }
        guard saved else {
            logger.error("文字内容更新保存到数据库失败，保留文件与草稿待下次对账补写")
            return false
        }
        return true
    }

    private func saveSummaryToFolder(_ text: String, for note: QuickNote) {
        guard !rejectWriteIfReadOnly(.writeMirror) else { return }
        guard !note.folderName.isEmpty else { return }
        // 与录音侧同入口：合并连续写入 + 退出前 flush + 写失败经 PersistenceReporting 上报。
        // 旧实现在 MainActor 上同步做加密与文件写入、并用 try? 吞掉失败
        EntryMirrorStore.shared.submit(
            text,
            kind: .summary,
            folderName: note.folderName,
            to: note.summaryFileURL
        )
    }

    // MARK: - 待办拆解

    /// 待办文档加载代次：丢弃过期的后台读结果（快速切换笔记时避免旧内容覆盖新内容）
    @ObservationIgnored
    private var todoDocumentLoadToken = 0

    /// 加载快捷笔记的待办文档
    func loadTodoDocument(for note: QuickNote) {
        todoDocumentLoadToken += 1
        guard !note.folderName.isEmpty else {
            currentTodoDocument = nil
            return
        }
        // 与 RecordingViewModel 同策略：磁盘读 + 解密移出主线程，代次守卫丢弃过期结果
        let token = todoDocumentLoadToken
        let folderURL = note.folderURL
        Task { [weak self] in
            let document = await Task.detached(priority: .userInitiated) {
                TodoDocument.load(from: folderURL)
            }.value
            guard let self, self.todoDocumentLoadToken == token else { return }
            self.currentTodoDocument = document
        }
    }

    /// AI 拆解快捷笔记为待办事项
    /// - Returns: 任务结果强类型化：`.succeeded` 仅当本次确实拆出待办并已落盘
    @discardableResult
    func extractTodos(from note: QuickNote, llmConfig: LLMConfig, context: ModelContext) -> Task<StepOutcome, Never> {
        guard !rejectWriteIfReadOnly(.startProcessing) else { return Task { .cancelled } }
        let noteID = note.id
        // 只取消「同一笔记」的上一次拆解
        todoExtractionTasks[noteID]?.cancel()
        let executionToken = UUID()
        todoExtractionExecutions[noteID] = executionToken
        todoExtractionProgress[noteID] = nil
        extractingTodoIDs.insert(noteID)
        if isSelectedNote(noteID) { isExtractingTodos = true }
        let taskExperience = AppExperiencePreference.resolved()

        let task = Task { @MainActor [weak self] in
            guard let self else { return StepOutcome.cancelled }
            defer {
                if self.todoExtractionExecutions[noteID] == executionToken {
                    self.todoExtractionExecutions[noteID] = nil
                    self.todoExtractionTasks[noteID] = nil
                    self.extractingTodoIDs.remove(noteID)
                    self.todoExtractionProgress[noteID] = nil
                    if self.isSelectedNote(noteID) { self.isExtractingTodos = false }
                }
            }

            do {
                let snapshot = try LLMConfigSnapshot(config: llmConfig)
                let onProgress: @Sendable (TodoExtractionService.Progress) -> Void = { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.todoExtractionExecutions[noteID] == executionToken else { return }
                        self.todoExtractionProgress[noteID] = progress
                    }
                }
                var document: TodoDocument

                // 优先用文字内容拆解
                let textContent = note.decryptedTextContent
                if !textContent.isEmpty {
                    // PII 去标识化：仅云端模型且开关开启时生效（图片直发无法脱敏，不做处理）；
                    // 开关与 SettingsViewModel.Keys.enablePIIScrub 同源（本 VM 未持有 settingsVM，直读 UserDefaults）
                    let savedPIIValue = UserDefaults.standard.object(forKey: "enable_pii_scrub") as? Bool ?? true
                    let piiEnabled = EffectiveSettingsResolver.piiScrubEnabled(
                        savedValue: savedPIIValue,
                        experience: taskExperience
                    )
                    let scrubbed = (piiEnabled && snapshot.shouldScrubText)
                        ? PIIScrubService.scrub(textContent) : nil
                    document = try await TodoExtractionService.extract(
                        from: scrubbed?.scrubbed ?? textContent,
                        config: snapshot,
                        source: "quicknote",
                        piiScrubbed: scrubbed != nil,
                        onProgress: onProgress
                    )
                    if let mapping = scrubbed?.mapping {
                        document = PIIScrubService.restore(document, mapping: mapping)
                    }
                } else if let imageURL = note.sourceImageURL,
                          let imageData = try? Data(contentsOf: imageURL) {
                    // 无文字但有图片：走多模态/OCR
                    document = try await TodoExtractionService.extractFromImage(
                        imageData: imageData,
                        config: snapshot,
                        source: "quicknote",
                        onProgress: onProgress
                    )
                } else {
                    self.showErrorMessage(String(localized: "快捷笔记内容为空"))
                    return .failed
                }

                // 只有当前展示笔记才更新共享的待办文档 UI；持久化始终按本笔记文件夹写入
                try Task.checkCancellation()
                guard self.todoExtractionExecutions[noteID] == executionToken else { throw CancellationError() }
                if self.isSelectedNote(noteID) { self.currentTodoDocument = document }
                let saved = self.saveTodosToFolder(document, for: note)
                // 成功仅当本次确实拆出非空待办并已落盘；空结果不算成功
                let outcome: StepOutcome = (!document.items.isEmpty && saved) ? .succeeded : .failed

                // 拆解完成后自动生成标题并更新列表标题（失败仅日志，不影响待办本身）；
                // 文字笔记用原文，图片笔记无文字时用待办标题作为标题源
                let titleSource = !textContent.isEmpty
                    ? textContent
                    : document.items.map(\.title).joined(separator: "；")
                await self.autoAssignNoteTitle(
                    note,
                    from: titleSource,
                    config: snapshot,
                    context: context,
                    experience: taskExperience
                )
                return outcome
            } catch is CancellationError {
                // 用户取消
                return .cancelled
            } catch {
                self.showErrorMessage(String(localized: "待办拆解失败：\(error.localizedDescription)"))
                return .failed
            }
        }
        todoExtractionTasks[noteID] = task
        return task
    }

    /// 取消指定笔记的待办拆解（队列「取消」入口，只影响该笔记的句柄）
    func cancelTodoExtraction(noteID: UUID) {
        todoExtractionTasks[noteID]?.cancel()
        todoExtractionTasks[noteID] = nil
        todoExtractionExecutions[noteID] = nil
        todoExtractionProgress[noteID] = nil
        extractingTodoIDs.remove(noteID)
        if isSelectedNote(noteID) { isExtractingTodos = false }
    }

    /// 兼容旧入口：取消当前展示笔记的待办拆解
    func cancelTodoExtraction() {
        guard let id = selectedQuickNote?.id else { return }
        cancelTodoExtraction(noteID: id)
    }

    /// 从内容自动生成标题并更新列表标题，格式“年月日时分 标题”。
    /// 仅当标题仍为默认“图片笔记/文字笔记/快捷笔记 xxx”时生效，避免覆盖用户手动重命名；
    /// 写入后同步 meta.json 与数据库，自动保存
    private func autoAssignNoteTitle(
        _ note: QuickNote,
        from content: String,
        config: LLMConfigSnapshot,
        context: ModelContext,
        experience: AppExperience
    ) async {
        let defaultPrefixes = [
            String(localized: "图片笔记"),
            String(localized: "文字笔记"),
            String(localized: "快捷笔记")
        ]
        guard defaultPrefixes.contains(where: note.title.hasPrefix) else { return }

        // 失败时记录真实错误原因（try? 吞错会导致失败零感知无法定位）
        let title: String
        do {
            title = try await generatePrivacySafeTitle(
                from: content,
                config: config,
                experience: experience
            )
        } catch {
            FileSyncService.logWarning(
                "自动标题生成失败，保留原标题 (\(note.folderName)): \(error.localizedDescription)")
            return
        }
        guard !title.isEmpty else { return }

        note.title = "\(note.createdAt.formatted(date: .abbreviated, time: .shortened)) \(title)"
        note.saveMetaToFolder()
        do {
            try context.save()
        } catch {
            FileSyncService.logWarning("自动标题保存失败: \(error.localizedDescription)")
        }
    }

    /// 润色标题（右键入口）：用大模型从笔记内容与待办事项提取不超过 10 字的主旨，
    /// 更新列表标题为“年月日时分 主旨”。用户显式操作，直接覆盖当前标题（含手动命名）
    /// - Returns: 任务结果强类型化：`.succeeded` 仅当生成了非空标题并已落库
    @discardableResult
    func polishNoteTitle(_ note: QuickNote, llmConfig: LLMConfig, context: ModelContext) -> Task<StepOutcome, Never> {
        guard !rejectWriteIfReadOnly(.startProcessing) else { return Task { .cancelled } }
        let noteID = note.id
        // 只取消「同一笔记」的上一次标题润色
        titleTasks[noteID]?.cancel()
        let executionToken = UUID()
        titleExecutions[noteID] = executionToken
        let taskExperience = AppExperiencePreference.resolved()
        let task = Task { @MainActor [weak self] in
            guard let self else { return StepOutcome.cancelled }
            defer {
                if self.titleExecutions[noteID] == executionToken {
                    self.titleExecutions[noteID] = nil
                    self.titleTasks[noteID] = nil
                }
            }
            do {
                let snapshot = try LLMConfigSnapshot(config: llmConfig)
                var sources: [String] = []
                let text = note.combinedTextForExtraction
                if !text.isEmpty { sources.append(text) }
                let todoTitles = TodoDocument.load(from: note.folderURL)?
                    .items.map(\.title).joined(separator: "\n") ?? ""
                if !todoTitles.isEmpty { sources.append(todoTitles) }
                guard !sources.isEmpty else {
                    self.showErrorMessage(String(localized: "笔记内容为空，无法润色标题。"))
                    return .failed
                }

                let title = try await self.generatePrivacySafeTitle(
                    from: sources.joined(separator: "\n\n"),
                    config: snapshot,
                    experience: taskExperience
                )
                guard !title.isEmpty else {
                    self.showErrorMessage("润色标题失败：大模型返回了空内容，请重试。")
                    return .failed
                }

                note.title = "\(note.createdAt.formatted(date: .abbreviated, time: .shortened)) \(title)"
                note.saveMetaToFolder()
                try context.save()
                return .succeeded
            } catch is CancellationError {
                // 用户取消，静默处理
                return .cancelled
            } catch {
                self.showErrorMessage(String(localized: "润色标题失败：\(error.localizedDescription)"))
                return .failed
            }
        }
        titleTasks[noteID] = task
        return task
    }

    /// 取消指定笔记的标题润色（队列「取消」入口，只影响该笔记的句柄）
    func cancelTitle(noteID: UUID) {
        titleTasks[noteID]?.cancel()
        titleTasks[noteID] = nil
        titleExecutions[noteID] = nil
    }

    /// 兼容旧入口：取消当前展示笔记的标题润色
    func cancelTitle() {
        guard let id = selectedQuickNote?.id else { return }
        cancelTitle(noteID: id)
    }

    private func generatePrivacySafeTitle(
        from content: String,
        config: LLMConfigSnapshot,
        experience: AppExperience
    ) async throws -> String {
        let savedPIIValue = UserDefaults.standard.object(forKey: "enable_pii_scrub") as? Bool ?? true
        let piiEnabled = EffectiveSettingsResolver.piiScrubEnabled(
            savedValue: savedPIIValue,
            experience: experience
        )
        let scrubbed = (piiEnabled && config.shouldScrubText)
            ? PIIScrubService.scrub(content) : nil
        let title = try await LLMService.generateTitle(
            from: scrubbed?.scrubbed ?? content,
            config: config
        )
        return scrubbed.map {
            PIIScrubService.restore(title, mapping: $0.mapping)
        } ?? title
    }

    /// 写入提醒事项
    func writeTodosToReminders(note: QuickNote, defaultListID: String) async {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        guard let document = currentTodoDocument else { return }
        guard !document.items.isEmpty else {
            showErrorMessage("待办列表为空，无需写入")
            return
        }

        // 显式授权检查：未授权时先请求，仍无授权则给出明确引导
        if !RemindersService.shared.isAuthorized {
            let granted = await RemindersService.shared.requestAccess()
            if !granted {
                showErrorMessage("未授权提醒事项访问，无法写入待办。\n请到「系统设置 → 隐私与安全性 → 提醒事项」中开启 Memozia，或在「应用设置 → 待办」中点击「请求授权」后重试。")
                return
            }
        }

        isWritingTodos = true
        defer { isWritingTodos = false }

        let result = await RemindersService.shared.writeReminders(
            items: document.items,
            to: defaultListID
        )

        var updatedDocument = document
        updatedDocument.items = result.updatedItems
        currentTodoDocument = updatedDocument
        saveTodosToFolder(updatedDocument, for: note)

        if result.failed > 0 {
            // 进一步判断失败是否因授权丢失
            if !RemindersService.shared.isAuthorized {
                showErrorMessage("待办写入失败：提醒事项授权已失效。\n请到「系统设置 → 隐私与安全性 → 提醒事项」中重新开启 Memozia 后重试。")
            } else {
                showErrorMessage(String(localized: "部分待办写入失败：成功 \(result.success) 个，失败 \(result.failed) 个"))
            }
        }
    }

    /// 清除待办
    func clearTodos(for note: QuickNote) {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        guard let document = currentTodoDocument else { return }
        var hasDeleteFailure = false
        for item in document.items where item.status == .exported {
            if let identifier = item.reminderIdentifier {
                if !RemindersService.shared.deleteReminder(identifier: identifier) {
                    hasDeleteFailure = true
                }
            }
        }
        TodoDocument.remove(from: note.folderURL)
        currentTodoDocument = nil
        if hasDeleteFailure {
            showErrorMessage("部分提醒事项删除失败，系统「提醒事项」中可能仍有残留。请手动打开提醒事项 App 删除。")
        }
    }

    // MARK: - 手动增删改单个待办

    /// 手动新增一个待办
    func addTodoItem(_ item: TodoItem, for note: QuickNote) {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        var document = currentTodoDocument ?? TodoDocument(
            source: "manual",
            model: String(localized: "手动添加"),
            generatedAt: Date(),
            items: []
        )
        document.items.append(item)
        currentTodoDocument = document
        saveTodosToFolder(document, for: note)
    }

    /// 手动修改一个待办（已写入提醒事项的同步更新）
    func updateTodoItem(_ updatedItem: TodoItem, for note: QuickNote) {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        guard var document = currentTodoDocument,
              let index = document.items.firstIndex(where: { $0.id == updatedItem.id }) else { return }

        document.items[index] = updatedItem
        currentTodoDocument = document
        saveTodosToFolder(document, for: note)

        if updatedItem.status == .exported, let identifier = updatedItem.reminderIdentifier {
            Task {
                let ok = await RemindersService.shared.updateReminder(identifier: identifier, with: updatedItem)
                if !ok {
                    await MainActor.run {
                        var doc = self.currentTodoDocument
                        if let i = doc?.items.firstIndex(where: { $0.id == updatedItem.id }) {
                            doc?.items[i].status = .failed
                            self.currentTodoDocument = doc
                            if let d = doc { self.saveTodosToFolder(d, for: note) }
                        }
                        self.showErrorMessage("提醒事项同步更新失败，本地已保存。可重新点击「写入提醒事项」重试。")
                    }
                }
            }
        }
    }

    /// 手动删除一个待办（已写入提醒事项的同步删除）
    func deleteTodoItem(_ item: TodoItem, for note: QuickNote) {
        guard !rejectWriteIfReadOnly(.editTodo) else { return }
        guard var document = currentTodoDocument,
              let index = document.items.firstIndex(where: { $0.id == item.id }) else { return }

        document.items.remove(at: index)
        currentTodoDocument = document
        saveTodosToFolder(document, for: note)

        if item.status == .exported, let identifier = item.reminderIdentifier {
            if !RemindersService.shared.deleteReminder(identifier: identifier) {
                showErrorMessage("提醒事项删除失败，系统「提醒事项」中可能仍有残留。请手动打开提醒事项 App 删除。")
            }
        }

        if document.items.isEmpty {
            TodoDocument.remove(from: note.folderURL)
            currentTodoDocument = nil
        }
    }

    // MARK: - 标题更新

    func updateTitle(_ note: QuickNote, newTitle: String, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.editTitle) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        note.title = trimmed
        note.saveMetaToFolder()
        do {
            try context.save()
        } catch {
            showErrorMessage(String(localized: "保存标题失败：\(error.localizedDescription)"))
        }
    }

    // MARK: - 删除

    func deleteQuickNote(_ note: QuickNote, context: ModelContext) {
        guard !rejectWriteIfReadOnly(.deleteEntry) else { return }
        // 按笔记 id 取消该笔记上正在跑的总结/待办/标题：无论是否当前展示笔记，
        // 都要停掉它会继续落盘到「即将删除文件夹」的任务
        cancelSummary(noteID: note.id)
        cancelTodoExtraction(noteID: note.id)
        cancelTitle(noteID: note.id)
        // 必须在删除文件夹之前加载待办文档，否则无法清理已写入提醒事项的条目
        let todoDocument = TodoDocument.load(from: note.folderURL)
        // P3-9: 先删除磁盘文件——若失败则保留数据库记录，防止下次 syncFromDisk 数据复活
        if !note.folderName.isEmpty {
            let folderURL = note.folderURL
            if FileManager.default.fileExists(atPath: folderURL.path) {
                do {
                    try FileManager.default.removeItem(at: folderURL)
                } catch {
                    showErrorMessage(String(localized: "快捷笔记文件夹删除失败：\(error.localizedDescription)。数据库记录已保留以防止数据复活，请手动删除文件夹后重试。"))
                    return
                }
            }
        }
        // 删除已写入的提醒事项
        var hasReminderDeleteFailure = false
        if let document = todoDocument {
            for item in document.items where item.status == .exported {
                if let identifier = item.reminderIdentifier {
                    if !RemindersService.shared.deleteReminder(identifier: identifier) {
                        hasReminderDeleteFailure = true
                    }
                }
            }
        }
        context.delete(note)
        do {
            try context.save()
        } catch {
            showErrorMessage(String(localized: "删除失败：\(error.localizedDescription)"))
        }
        if selectedQuickNote?.id == note.id {
            selectedQuickNote = nil
            currentTodoDocument = nil
        }
        if hasReminderDeleteFailure {
            showErrorMessage("部分提醒事项删除失败，系统「提醒事项」中可能仍有残留。请手动打开提醒事项 App 删除。")
        }
    }

    // MARK: - 私有方法

    @discardableResult
    private func saveTodosToFolder(_ document: TodoDocument, for note: QuickNote) -> Bool {
        guard !rejectWriteIfReadOnly(.editTodo) else { return false }
        guard !note.folderName.isEmpty else { return false }
        do {
            try document.save(to: note.folderURL)
            return true
        } catch {
            FileSyncService.logWarning("待办文件写入失败：\(error.localizedDescription)")
            showErrorMessage(String(localized: "待办文件写入失败：\(error.localizedDescription)"))
            return false
        }
    }

    private func makeDefaultTitle(text: String, date: Date) -> String {
        // 取第一行作为标题，截断到 30 字符
        let firstLine = text.split(separator: "\n").first ?? Substring(text)
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(format: String(localized: "文字笔记 %@"), date.formatted(date: .abbreviated, time: .shortened))
        }
        return trimmed.count > 30 ? String(trimmed.prefix(30)) + "…" : trimmed
    }

    private func showErrorMessage(_ message: LocalizedStringResource) {
        errorMessage = String(localized: message)
        showError = true
    }

    /// 纯文本版本：已本地化或不可本地化的动态字符串
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
