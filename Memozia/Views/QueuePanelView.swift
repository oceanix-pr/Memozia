import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 队列工具栏按钮

/// 右上角「处理队列」按钮：点击弹出队列面板。
///
/// 外观完全交给系统工具栏（原生的玻璃底、悬停/按压高亮与尺寸），
/// 不自绘任何背景，也不隐藏系统共享背景——避免叠加成双层背景。
struct QueueToolbarButton: View {
    @State private var showPopover = false
    private let center = TaskCenter.shared

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            Label {
                Text("处理队列")
            } icon: {
                Image(systemName: iconName)
            }
        }
        .controlSize(.large)
        .help("查看处理队列（下载模型 / 转写 / 总结 / 润色标题 / 画面分析 / 拆解待办）")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            QueuePanelView()
        }
        // 任务入队后的「查看队列」横幅入口：面板在工具栏上，必须由这里响应才打得开
        .onReceive(NotificationCenter.default.publisher(for: .openTaskQueuePanel)) { _ in
            showPopover = true
        }
    }

    /// 图标语义：有失败任务优先显示警示（收起状态也能看出「有东西失败了」），否则按是否有在跑的任务区分
    private var iconName: String {
        if !center.failedJobs.isEmpty { return "exclamationmark.triangle.fill" }
        return center.hasActiveWork ? "square.stack.fill" : "square.stack"
    }
}

// MARK: - 队列面板

/// 队列面板：分区展示「处理中」（可暂停/取消）、「排队中」（可取消）与「最近失败」（可重试/定位）。
struct QueuePanelView: View {
    private let center = TaskCenter.shared
    @Environment(\.modelContext) private var modelContext

    /// 持久账本快照：关应用后仍会由后台进程续跑的任务与失败区（NX-1）。
    /// 队列文件很小，面板打开期间按固定间隔读取即可，不需要额外持久化层。
    @State private var durableTasks: [BackgroundTaskEntry] = []
    @State private var failedTasks: [BackgroundTaskEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if center.runningJobs.isEmpty && center.queuedJobs.isEmpty && center.failedJobs.isEmpty
                && visibleDurableTasks.isEmpty && failedTasks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !center.runningJobs.isEmpty {
                            section(title: String(localized: "处理中"), jobs: center.runningJobs, showsControls: true)
                        }
                        if !center.queuedJobs.isEmpty {
                            section(title: String(localized: "排队中"), jobs: center.queuedJobs, showsControls: false)
                        }
                        if !center.failedJobs.isEmpty {
                            failureSection(center.failedJobs)
                        }
                        if !visibleDurableTasks.isEmpty {
                            durableSection
                        }
                        if !failedTasks.isEmpty {
                            durableFailedSection
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 400, height: 440)
        .task { await refreshLoop() }
    }

    // MARK: 持久账本

    /// 面板打开期间轮询持久账本（文件小、间隔足够）
    private func refreshLoop() async {
        while !Task.isCancelled {
            refreshDurable()
            try? await Task.sleep(for: .milliseconds(1500))
        }
    }

    private func refreshDurable() {
        let data = BackgroundTaskQueue.loadFromDisk()
        durableTasks = data.tasks.sorted { $0.enqueuedAt < $1.enqueuedAt }
        failedTasks = data.failedEntries
    }

    /// 账本条目要等任务结束（完成/失败/取消）才出队，而用户发起任务时就会入队，
    /// 因此「前台正在跑/排队」的这段时间里，同一份任务必然同时存在于内存 Job 与账本两处。
    /// 面板按分区渲染就会把同一目标画成两行，这里把已被前台 Job 接管的条目滤掉。
    private var visibleDurableTasks: [BackgroundTaskEntry] {
        let foreground = center.runningJobs + center.queuedJobs
        return durableTasks.filter { !isHandledByForegroundJob($0, in: foreground) }
    }

    /// 账本条目是否已有对应的前台 Job 步骤（快捷笔记总结只在笔记内展示，不建前台 Job）
    private func isHandledByForegroundJob(
        _ entry: BackgroundTaskEntry,
        in jobs: [TaskCenter.Job]
    ) -> Bool {
        let stepKind: TaskKind?
        switch entry.kind {
        case .transcription:    stepKind = .transcription
        case .summary:          stepKind = .summary
        case .quicknoteSummary: stepKind = nil
        }
        guard let stepKind else { return false }
        return jobs.contains { job in
            job.folderName == entry.folderName && job.steps.contains { $0.kind == stepKind }
        }
    }

    /// 手动重试后立刻续跑（与启动兜底同一入口；worker 正在运行时让位给它）
    private func triggerDrainIfIdle() {
        guard !BackgroundWorker.isWorkerRunning() else { return }
        Task { await BackgroundWorker.drainQueue(context: modelContext) }
    }

    /// 失败任务的诊断串（稳定标识 + 失败码，非本地化，供粘贴到反馈）
    private func diagnosticText(for entry: BackgroundTaskEntry) -> String {
        var parts = ["kind=\(entry.kind.rawValue)", "folder=\(entry.folderName)", "id=\(entry.id.uuidString)"]
        if let code = entry.lastFailureCode { parts.append("code=\(code.rawValue)") }
        if let attempt = entry.attempt { parts.append("attempt=\(attempt)") }
        return parts.joined(separator: " ")
    }

    private var durableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("待续跑的任务")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(visibleDurableTasks) { entry in
                durableRow(entry)
            }
        }
    }

    private func durableRow(_ entry: BackgroundTaskEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text(entry.kind.displayName)
                    .font(.callout)
                Spacer()
                if let attempt = entry.attempt, attempt > 0 {
                    Text("重试").font(.caption2).foregroundStyle(.orange)
                        + Text(verbatim: " \(attempt)").font(.caption2).foregroundStyle(.orange)
                } else {
                    Text("等待后台继续")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(entry.folderName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let code = entry.lastFailureCode {
                Text(code.localizedSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var durableFailedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("失败任务")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(failedTasks) { entry in
                durableFailedRow(entry)
            }
        }
    }

    private func durableFailedRow(_ entry: BackgroundTaskEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .font(.caption)
                Text(entry.kind.displayName)
                    .font(.callout)
                Spacer()
            }
            Text(entry.folderName)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let code = entry.lastFailureCode {
                Text(code.localizedSummary)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Button(String(localized: "重试")) {
                    if BackgroundTaskQueue.retryFailedEntry(id: entry.id) {
                        refreshDurable()
                        triggerDrainIfIdle()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(String(localized: "丢弃")) {
                    if BackgroundTaskQueue.discardFailedEntry(id: entry.id) {
                        refreshDurable()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // 复制诊断信息：粘进反馈/工单时含稳定的任务标识与失败码（非本地化，便于定位）
                Button(String(localized: "复制诊断信息")) {
                    #if os(macOS)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(diagnosticText(for: entry), forType: .string)
                    #endif
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 头部

    private var header: some View {
        HStack {
            Text("处理队列")
                .font(.headline)
            Spacer()
            Text("最多 \(TaskCenter.maxConcurrentJobs) 个并行")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("当前没有处理中的任务")
                .foregroundStyle(.secondary)
            Text("转写、总结、拆解待办等任务会在这里排队")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 分区

    @ViewBuilder
    private func section(title: String, jobs: [TaskCenter.Job], showsControls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(jobs) { job in
                jobRow(job, showsControls: showsControls)
            }
        }
    }

    private func jobRow(_ job: TaskCenter.Job, showsControls: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(job.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if job.state == .paused {
                    Text("已暂停")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // 完整步骤清单：转写 → 画面分析 → 总结 → 拆解待办
            // （父 Job 内含多个子步骤，逐项标注 已完成 / 进行中 / 排队 / 失败）
            stepList(job)

            HStack(spacing: 6) {
                Spacer()
                if showsControls {
                    controls(for: job, kind: currentStepKind(job))
                } else {
                    Button(String(localized: "取消")) {
                        center.cancel(jobID: job.id)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: 失败步骤

    @ViewBuilder
    private func failureSection(_ jobs: [TaskCenter.Job]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近失败")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(jobs) { job in
                failureRow(job)
            }
        }
    }

    private func failureRow(_ job: TaskCenter.Job) -> some View {
        let stepIndex = center.failedStepIndex(jobID: job.id)
        let failedStep = stepIndex.map { job.steps[$0] }
        let code = failedStep?.errorCode
        return VStack(alignment: .leading, spacing: 8) {
            stepList(job)

            // 失败详情：本地化摘要 + 失败时间 + 是否可重试（文案全部由稳定错误码映射，不落英文原串）
            VStack(alignment: .leading, spacing: 4) {
                Text(code?.localizedSummary ?? TaskErrorCode.unknown.localizedSummary)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    if let finishedAt = failedStep?.finishedAt {
                        Text("失败时间：\(finishedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text((code?.isRetryable ?? true)
                         ? String(localized: "可重试")
                         : String(localized: "不可重试"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            failureActions(job: job, code: code)
        }
        .padding(10)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func failureActions(job: TaskCenter.Job, code: TaskErrorCode?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if code?.isRetryable ?? true {
                    Button(String(localized: "重试此步骤")) {
                        center.retryStep(jobID: job.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                Button(String(localized: "重新执行整个任务")) {
                    center.retryJob(jobID: job.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 10) {
                Button(String(localized: "打开设置")) {
                    NotificationCenter.default.post(name: .menuBarOpenSettings, object: nil)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("打开应用设置（模型 / 大模型配置等）")

                if let folderURL = existingFolderURL(for: job) {
                    #if os(macOS)
                    Button(String(localized: "在Finder中显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("在 Finder 中显示该条目文件夹")
                    #endif
                }

                if let recovery = code?.recovery, case .systemSettings(let urlString) = recovery {
                    #if os(macOS)
                    Button(String(localized: "打开系统设置")) {
                        if let url = URL(string: urlString) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("打开系统设置中相关的权限面板")
                    #endif
                }
            }
        }
    }

    /// 失败任务对应的条目文件夹（模型下载等无实体文件夹的任务返回 nil，不展示定位入口）
    private func existingFolderURL(for job: TaskCenter.Job) -> URL? {
        guard !job.folderName.isEmpty, !job.folderName.hasPrefix("model:") else { return nil }
        let url = AudioRecording.resolveFolderURL(forFolderName: job.folderName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: 步骤清单

    @ViewBuilder
    private func stepList(_ job: TaskCenter.Job) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(job.steps.enumerated()), id: \.element.id) { index, step in
                stepRow(step, isCurrent: index == job.currentStep)
            }
        }
    }

    /// 单步行：状态图标 + 步骤名（进行中的下载额外显示百分比）
    @ViewBuilder
    private func stepRow(_ step: TaskCenter.Step, isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            stepIcon(step.state)
            Text(step.kind.displayName)
                .font(.caption)
                .foregroundStyle(step.state == .done ? .secondary : .primary)
            Spacer()
            if isCurrent, step.state == .running, step.progress > 0 {
                Text(step.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    /// 步骤状态图标（图标本身即状态语义，需补无障碍标签，否则 VoiceOver 只读出步骤名）
    @ViewBuilder
    private func stepIcon(_ state: TaskCenter.JobState) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                .accessibilityLabel("已完成")
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
                .accessibilityLabel("失败")
        case .paused:
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange).font(.caption)
                .accessibilityLabel("已暂停")
        case .cancelled:
            Image(systemName: "xmark.circle").foregroundStyle(.secondary).font(.caption)
                .accessibilityLabel("已取消")
        case .running:
            ProgressView().controlSize(.mini)
                .accessibilityLabel(Text("处理中"))
        case .queued:
            Image(systemName: "circle").foregroundStyle(.tertiary).font(.caption)
                .accessibilityLabel("排队中")
        }
    }

    @ViewBuilder
    private func controls(for job: TaskCenter.Job, kind: TaskKind?) -> some View {
        // 仅下载支持真正的暂停/续传；其余任务没有续传游标，只提供取消
        if kind?.canPause == true {
            if job.state == .paused {
                Button(String(localized: "继续")) {
                    center.resume(jobID: job.id)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            } else {
                Button(String(localized: "暂停")) {
                    center.pause(jobID: job.id)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        Button(String(localized: "取消")) {
            center.cancel(jobID: job.id)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: 辅助

    private func currentStepKind(_ job: TaskCenter.Job) -> TaskKind? {
        guard job.currentStep < job.steps.count else { return nil }
        return job.steps[job.currentStep].kind
    }
}
