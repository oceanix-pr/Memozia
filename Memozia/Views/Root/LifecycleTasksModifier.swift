import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 生命周期任务修饰符（拆分以避免类型检查超时）
struct LifecycleTasksModifier: ViewModifier {
    let modelContext: ModelContext
    let viewModel: RecordingViewModel
    /// 用户是否已同意隐私政策：未同意前不执行磁盘扫描/加密迁移/模型加载，
    /// 同意后（值翻转）通过 task(id:) 自动补跑
    let privacyAccepted: Bool
    /// 启动时的 STT 配置快照：本地模式下预热用户配置的模型
    let sttConfig: STTConfig
    /// 是否以临时（内存）模式运行：此时数据库不落盘，兜底续跑会把任务的出队记录写到内存库，
    /// 而磁盘队列是权威源 → 必须跳过续跑，把任务留给下次持久化启动
    let isTransientMode: Bool
    /// 启动磁盘同步结果回调（RootView 据此展示反馈横幅/失败弹窗）
    let onSyncResult: @MainActor (FileSyncService.SyncResult) -> Void

    func body(content: Content) -> some View {
        content
            .disabled(AppUpdateService.shared.isPreparingToInstall || RecordingMergeActivity.shared.isRunning)
            .task(id: privacyAccepted) {
                guard !AppRuntime.isRunningTests else { return }
                guard privacyAccepted else { await MCPServerController.shared.suspend(); return }
                if !isTransientMode { await UpdatePermissionRepair.shared.prepareIfNeeded() }
                // 单一启动协调器：以下步骤共用同一个 ModelContext，必须严格串行执行
                // （加密迁移 → 崩溃残留状态复位 → 磁盘对账 → 后台队列续跑）。
                // 旧实现把「录音导入 / 快捷笔记导入 / 模型预热」拆成并列的 task 并行跑：
                // 导入会先建文件夹、后插数据库，磁盘对账却已取好旧的文件夹集合快照，
                // 于是把导入刚建的文件夹当成「需要恢复的条目」重复插入（同一条目两份记录）。
                // AGENTS.md 也要求共享 ModelContext 的启动任务串行并受隐私同意门控
                do {
                    try await EncryptionService.migrateEncryption(context: modelContext)
                } catch {
                    viewModel.errorMessage = String(localized: "数据加密迁移失败，部分数据可能未加密存储。请重启应用重试。")
                    viewModel.showError = true
                }
                // B-6: 重置上次崩溃遗留的 .processing 状态
                viewModel.resetStaleProcessingStates(context: modelContext)
                // 说明：曾尝试把深度修复（镜像补写、旧条目时长/类型校正）延后到首屏之后，
                // 但实测**反而更差**：首屏阻塞主因是关键路径本身（全表物化 + 插入），
                // 且拆分会多一次全表 fetch（1000 条目：首屏 ≥50ms 阻塞 9 → 12 次、总耗时 +16%）。
                // 该实验已回退，维持完整对账；详见 docs/TECH_DEBT.md。
                let result = await FileSyncService.syncFromDisk(
                    context: modelContext,
                    excludeFolderNames: MeetingRecorderService.shared.activeRecordingFolderNames
                )
                onSyncResult(result)
                if result.saveFailed {
                    viewModel.errorMessage = String(localized: "数据同步完成但保存到数据库失败，重启应用后可能需要重新加载。请检查磁盘空间后重启应用。")
                    viewModel.showError = true
                }
                if !result.saveFailed, !Task.isCancelled {
                    await MCPServerController.shared.install(context: modelContext, isTransient: isTransientMode)
                }
                // 兜底续跑：队列有残留且守护进程不在运行（worker 崩溃/让位/握手超时）时，
                // 主应用直接续跑同一套出队逻辑，保证用户发起的任务不因 worker 异常而丢失。
                // 临时模式（不落盘）下必须跳过：出队记录会写进内存库并在退出时消失，
                // 磁盘队列被提前删空等于丢任务
                if !isTransientMode,
                   BackgroundTaskQueue.hasEntries(),
                   !BackgroundWorker.isWorkerRunning() {
                    await BackgroundWorker.drainQueue(context: modelContext)
                }
                guard !isTransientMode, !Task.isCancelled, !result.saveFailed else { return }
                AppUpdateService.shared.start(context: modelContext, hasActiveFileOperation: { viewModel.isImporting })
            }
            .task(id: privacyAccepted) {
                guard !AppRuntime.isRunningTests else { return }
                guard privacyAccepted else { return }
                // 模型预热不碰 ModelContext，只读模型文件，故可脱离上面的关键路径并行执行
                // （放到关键路径里会让磁盘对账先等模型加载完，大库启动明显变慢）
                guard sttConfig.mode == .local else { return }
                // 加载用户配置模型文件夹中的模型。
                // 文件夹不存在/内容不完整时 loadModel 会抛错，try? 静默即可（转写时会再提示）
                let whisperService = WhisperLocalService.shared
                if !whisperService.isModelLoadedFor(path: sttConfig.modelPath) {
                    try? await whisperService.loadModel(fromPath: sttConfig.modelPath)
                }
            }
    }
}
