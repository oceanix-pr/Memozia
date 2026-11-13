import SwiftUI
import AVKit
import SwiftData
import os.log
#if os(macOS)
import AppKit
#endif

/// AVPlayer 的 Observable 包装器，驱动 SwiftUI 更新
@MainActor
@Observable
final class AudioPlayerState {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    private let player: AVPlayer
    private var timeObserver: Any?
    /// 限定区间播放的结束秒数（`playRange` 写入，播到即自动暂停）；nil 表示不限
    private var playRangeEnd: TimeInterval?

    init(player: AVPlayer) {
        self.player = player
        setupObservers()
    }

    /// 显式清理资源，避免 deinit 中访问 @MainActor 隔离属性
    func invalidate() {
        if let timeObserver = timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.pause()
        isPlaying = false
    }

    private func setupObservers() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // queue 为 .main；用 assumeOnMainThread 而非 assumeIsolated，
            // 避免 macOS 26 上无 Task 上下文时 executor 断言的崩溃隐患
            MainActor.assumeOnMainThread {
                self?.currentTime = CMTimeGetSeconds(time)
                self?.isPlaying = self?.player.timeControlStatus == .playing
                self?.pauseIfReachedPlayRangeEnd()
            }
        }

        Task { @MainActor [weak self] in
            if let item = self?.player.currentItem {
                let dur = try? await item.asset.load(.duration)
                self?.duration = dur.map(CMTimeGetSeconds) ?? 0
            }
        }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { player.play() }
    }

    func pause() {
        playRangeEnd = nil
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// 精确定位到指定秒并立即播放（点击转写时间行时调用）。
    /// 容差为零保证从片段起始处播放，本地音频的精确 seek 开销可忽略
    func seekAndPlay(to seconds: TimeInterval) {
        // 用户手动跳到别处，之前设定的试听区间不应再约束播放
        playRangeEnd = nil
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
    }

    /// 限定区间播放（声纹标记页「试听某说话人最早一段」）：从 start 精确起播，
    /// 播到 end 自动暂停，避免一路播到会议结束。
    /// 边界检测挂在 0.5s 周期观察者上，最多多播 0.5s（用于辨人足够）
    func playRange(from start: TimeInterval, to end: TimeInterval) {
        playRangeEnd = end
        player.seek(
            to: CMTime(seconds: start, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
    }

    /// 试听区间播完即暂停（由周期观察者每次回调检查）
    private func pauseIfReachedPlayRangeEnd() {
        guard let end = playRangeEnd, currentTime >= end else { return }
        playRangeEnd = nil
        player.pause()
        isPlaying = false
    }
}

/// 录音详情视图
struct RecordingDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let recording: AudioRecording
    @Bindable var viewModel: RecordingViewModel
    let settingsVM: SettingsViewModel
    let llmConfigs: [LLMConfig]
    var experience: AppExperience = .pro
    /// 转写控制（从侧边栏工具栏迁入，透传给 TranscriptView）
    var onTranscribe: (() -> Void)? = nil
    var onCancelTranscription: (() -> Void)? = nil
    /// 一键处理（转写 → 画面分析 → 总结 → 拆解待办），由宿主投递到处理队列
    var onOneClick: (() -> Void)? = nil
    var onCleanupAudio: (() -> Void)? = nil

    @State private var captureReport: RecordingCaptureReport?
    @State private var captureReportReadFailed = false
    @State private var captureReportExpanded = false
    @State private var selectedTab: DetailTab = .transcript
    @State private var selectedLLMConfig: LLMConfig?
    @State private var playerState: AudioPlayerState?
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// 音频原件是否存在：`fileExists` 曾在 body 内每次求值都做同步 stat，
    /// 而播放进度每 0.5s 触发一次 body 重算；改为切换录音时算一次并缓存
    @State private var audioFileExistsCache = false
    /// 当前录音的声波包络；nil 表示分析中或无法读取音频，由完成标记区分
    @State private var waveform: AudioWaveform?
    @State private var waveformAnalysisFinished = false
    /// 「一键处理」按钮实测宽度：标题行为它留出等宽空白，使播放控制落在状态正上方
    @State private var oneClickButtonWidth: CGFloat = 0
    @FocusState private var titleFieldFocused: Bool

    private struct PlaybackSource: Equatable {
        let fileURL: URL
        let audioRemovedAt: Date?
    }

    /// 临时模式（不落盘）：禁用全部编辑/分析入口，只保留浏览、播放、复制、导出
    private var isReadOnly: Bool { viewModel.persistence.capability.isTransient }

    /// 标题行右侧需要为「一键处理」预留的空白：按钮实测宽度 + 状态行的行列间距（8），
    /// 让播放控制与状态右对齐、落在状态正上方，而不是落到「一键处理」上方
    private var oneClickButtonReserve: CGFloat {
        oneClickButtonWidth > 0 ? oneClickButtonWidth + 8 : 0
    }

    /// 页签顺序即视频条目的处理链路：转写 → 画面（抽帧/判定/画面要点）→ 总结；
    /// 声明顺序与 availableTabs 保持一致
    enum DetailTab: String, CaseIterable {
        case transcript = "转写"
        case visual = "画面"
        case summary = "总结"

        /// 页签显示文案：`rawValue` 只作稳定标识，本地化走 LocalizedStringKey，
        /// 否则非中文界面下分段控件恒为中文
        var localizedTitle: LocalizedStringKey {
            switch self {
            case .transcript: return "转写"
            case .visual: return "画面"
            case .summary: return "总结"
            }
        }
    }

    /// 只有视频导入条目才展示画面页签。原始视频被「清理视频」删掉或在 Finder 里被移走时，
    /// 只要关键帧或画面要点还在就保留页签（产物才是这一页的内容）
    private var hasVideoAttachment: Bool {
        recording.videoFileName?.isEmpty == false || recording.hasVisualArtifacts
    }

    private var availableTabs: [DetailTab] {
        Self.availableTabs(experience: experience, hasVideoAttachment: hasVideoAttachment)
    }

    /// 页签可见性规则：画面页（抽帧 / 会议判定 / 画面要点）是专业模式能力，
    /// 普通模式**不展示该页签**，即使条目里留有历史画面产物（与 `allowsAnalysis`
    /// 的 `.videoUnderstanding` 判定同口径：普通模式本就不能发起画面对应动作）。
    /// 提取为静态方法以便回归测试，避免这条规则被后续改动悄悄放宽。
    nonisolated static func availableTabs(
        experience: AppExperience,
        hasVideoAttachment: Bool
    ) -> [DetailTab] {
        experience == .pro && hasVideoAttachment
            ? [.transcript, .visual, .summary]
            : [.transcript, .summary]
    }

    private var voiceprintHandler: (@MainActor (String, String) async throws -> Void)? {
        guard FeaturePolicy(experience: experience).allows(.voiceprintLibrary) else { return nil }
        return { speaker, name in
            try await viewModel.markVoiceprint(
                recording: recording,
                speaker: speaker,
                name: name,
                modelPath: settingsVM.diarizationModelPath,
                context: modelContext
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            captureReportSection
            Divider()

            tabPicker

            Divider()

            // 共享模型选择条：仅消耗 LLM 的页签（总结/画面）显示，转写用 STT 配置不展示。
            // 此前总结/画面各自画了一份同状态选择条（观感上“两个下拉框”），
            // 现统一为详情页一份；系统菜单指示器与自绘 ⌄ 重叠的观感由 menuIndicator(.hidden) 消除
            if selectedTab != .transcript && FeaturePolicy(experience: experience).allows(.modelSelection) {
                LLMModelSelectorBar(
                    llmConfigs: llmConfigs,
                    selectedLLMConfig: $selectedLLMConfig,
                    showsVisionBadge: selectedTab == .visual
                )

                Divider()
            }

            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        #if os(macOS)
        .navigationSubtitle("")
        #endif
        .task(id: PlaybackSource(fileURL: recording.fileURL, audioRemovedAt: recording.audioRemovedAt)) {
            prepareForRecordingSwitch()
            await loadWaveform()
        }
        .onChange(of: SourceNavigation.shared.request) { consumeSourceRequest() }
        .onChange(of: viewModel.captureReportRequestedFolder) { _, folder in
            if folder == recording.folderName { captureReportExpanded = true }
        }
        .onChange(of: experience) { _, _ in
            normalizeSelectedTab()
        }
        .onChange(of: selectedTab) { _, tab in
            handleTabChange(tab)
        }
        .onChange(of: selectedLLMConfig) { _, config in
            // 详情页选中的模型写回全局「活动大模型配置」并持久化（与笔记详情页同一语义）：
            // 总结/画面/拆解待办与一键处理都按这里的配置执行，重开条目或重启应用后保持一致。
            // 旧实现只在切换条目时读一次全局配置，页内改选只影响当前会话。
            guard let config, config.id != settingsVM.activeLLMConfigID else { return }
            settingsVM.setActiveLLMConfig(config)
        }
        .onDisappear {
            // 仅在 View 被销毁时暂停，不销毁 playerState（保留播放位置）
            playerState?.pause()
        }
    }

    /// 关闭短暂横幅后仍可查看，内容随录音目录保存，不参与标题元数据重写。
    @ViewBuilder
    private var captureReportSection: some View {
        if let report = captureReport, !report.isEmpty {
            DisclosureGroup(isExpanded: $captureReportExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(report.interruptions) { interruption in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(interruption.message)
                                HStack(spacing: 4) {
                                    Text(interruption.observedStart, style: .time)
                                    if let end = interruption.observedEnd {
                                        Text(verbatim: "–")
                                        Text(end, style: .time)
                                    }
                                }
                                .foregroundStyle(.secondary)
                                if let last = interruption.lastSuccessfulWriteAt {
                                    HStack {
                                        Text("最近成功写入")
                                        Text(last, style: .time)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                            Text(issue.message)
                        }
                        if let last = report.microphoneLastSuccessfulWriteAt {
                            HStack {
                                Text("最近成功写入")
                                Text(last, style: .time)
                            }
                        }
                        if let skipped = report.skippedSegments, !skipped.isEmpty {
                            Text("已跳过的音频分片")
                            ForEach(skipped, id: \.self) { Text(verbatim: $0).textSelection(.enabled) }
                        }
                        if let repaired = report.repairedSegments, !repaired.isEmpty {
                            Text("音频分片已自动修复并合入录音。")
                        }
                        if report.retainedOriginals == true {
                            Text("应用已自动合并可用分片，原始音频分片同时保留。")
                        }
                        Text("以下时间是观察到的采集中断区间，不代表精确的声音缺失时长。")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .frame(maxHeight: 180)
            } label: {
                Label("录音采集详情", systemImage: report.hasWarning ? "exclamationmark.triangle" : "info.circle")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        } else if captureReportReadFailed {
            Label("录音采集详情读取失败，请检查存储位置。", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }

    // MARK: - 生命周期动作

    /// 切换录音：替换播放器、补默认模型、校正页签。
    /// 提到方法里是为了让 `body` 的修饰器链只保留一行调用——
    /// 这些闭包原先与 VStack 同属一个巨型表达式，是类型检查超时的一部分
    private func prepareForRecordingSwitch() {
        captureReport = nil
        captureReportReadFailed = false
        captureReportExpanded = viewModel.captureReportRequestedFolder == recording.folderName
        do { captureReport = try RecordingCaptureReportStore.load(in: recording.folderURL) }
        catch {
            captureReportReadFailed = true
            Logger(subsystem: "app.memozia", category: "CaptureReport")
                .error("读取采集详情失败：\(error.localizedDescription, privacy: .private)")
        }
        // 切换录音时直接替换播放器，避免播放栏闪烁
        playerState?.invalidate()
        waveform = nil
        waveformAnalysisFinished = false
        let url = recording.fileURL
        let exists = FileManager.default.fileExists(atPath: url.path)
        audioFileExistsCache = exists
        if exists {
            playerState = AudioPlayerState(player: AVPlayer(url: url))
        } else {
            playerState = nil
        }
        if selectedLLMConfig == nil {
            selectedLLMConfig = settingsVM.getActiveLLMConfig(from: llmConfigs)
        }
        normalizeSelectedTab()
        consumeSourceRequest()
    }

    private func consumeSourceRequest() {
        guard let request = SourceNavigation.shared.request, request.recordingID == recording.id else { return }
        selectedTab = .transcript
        // Preserve the request until this recording's player has been prepared.
        guard playerState != nil || !FileManager.default.fileExists(atPath: recording.fileURL.path) else { return }
        playerState?.seekAndPlay(to: request.seconds)
        SourceNavigation.shared.request = nil
    }

    // MARK: - 声波图

    /// 加载当前录音的声波包络（播放条下方声波图）。
    ///
    /// 解码在后台执行，完成的结果经 `WaveformCache` 复用；切换条目时取消当前分析。
    /// 录音文件被清理或替换后 `fileExists` 为 false，直接跳过。
    private func loadWaveform() async {
        let url = recording.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            waveform = nil
            waveformAnalysisFinished = true
            return
        }

        let result = await WaveformCache.shared.waveform(for: url)
        guard !Task.isCancelled else { return }
        waveform = result
        waveformAnalysisFinished = true
    }

    /// 页签可见性可能随专业模式变化：当前页签不再可用时回到「转写」
    private func normalizeSelectedTab() {
        if !availableTabs.contains(selectedTab) {
            selectedTab = .transcript
        }
    }

    /// 进入「画面」页签时暂停播放（抽帧与画面要点会占用 GPU/磁盘，且用户此时在看画面）
    private func handleTabChange(_ tab: DetailTab) {
        if tab == .visual {
            playerState?.pause()
        }
    }

    // MARK: - 页签

    /// 分段控件单独成属性。`body` 曾把「分段控件 + 条件模型选择条 + 三路页签 switch」
    /// 挤在同一个表达式里，触发编译器
    /// `unable to type-check this expression in reasonable time`；拆成小表达式后逐块推断
    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(availableTabs, id: \.self) { tab in
                Text(tab.localizedTitle).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    /// 页签内容只做分支选择，各页视图各自独立推断（同因：避免三个大初始化器聚在一个表达式）
    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .transcript: transcriptTab
        case .summary: summaryTab
        case .visual: visualTab
        }
    }

    private var transcriptTab: some View {
        TranscriptView(
            recording: recording,
            // 转写与说话人区分合并为一根进度条：折算规则在 ViewModel（可离线单测）
            transcriptionProgress: viewModel.mergedTranscriptionProgress,
            processingStage: viewModel.mergedTranscriptionStage,
            canUndo: viewModel.canUndo,
            onSegmentEdit: { segment, newText in
                viewModel.updateSegmentText(segment, newText: newText, context: modelContext)
            },
            onUndo: {
                viewModel.undoLastEdit(context: modelContext)
            },
            onMarkdownEdit: { newMarkdown in
                viewModel.updateTranscriptMarkdown(recording, newMarkdown: newMarkdown, context: modelContext)
            },
            allowsEditing: FeaturePolicy(experience: experience).allows(.advancedTranscriptEditing) && !isReadOnly,
            onTranscribe: onTranscribe,
            onCancelTranscription: onCancelTranscription,
            onMarkVoiceprint: voiceprintHandler,
            transcriptVersion: viewModel.transcriptVersion,
            onSeek: { seconds in
                // 录音文件已删除时 playerState 为 nil，静默忽略点击
                playerState?.seekAndPlay(to: seconds)
            },
            onPlayRange: { start, end in
                // 声纹标记弹窗的「试听」：从片段起点播放，播到片段结束自动暂停
                playerState?.playRange(from: start, to: end)
            }
        )
    }

    private var summaryTab: some View {
        SummaryView(
            recording: recording,
            viewModel: viewModel,
            selectedLLMConfig: $selectedLLMConfig,
            defaultReminderListID: settingsVM.defaultReminderListID,
            isProMode: experience == .pro,
            isReadOnly: isReadOnly
        )
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme?.lowercased() == "memozia" else { return .systemAction }
            guard let seconds = SourceNavigation.seconds(from: url),
                  recording.segments.contains(where: { abs($0.startTime - seconds) < 0.01 }) else { return .discarded }
            selectedTab = .transcript
            playerState?.seekAndPlay(to: seconds)
            return .handled
        })
    }

    private var visualTab: some View {
        VideoUnderstandingView(
            recording: recording,
            viewModel: viewModel,
            selectedLLMConfig: $selectedLLMConfig,
            allowsAnalysis: FeaturePolicy(experience: experience).allows(.videoUnderstanding),
            isReadOnly: isReadOnly
        )
    }

    // MARK: - 顶部播放器栏
    @ViewBuilder
    private var headerBar: some View {
        VStack(spacing: 6) {
            // 标题行 + 播放控制合并为一行
            HStack(spacing: 12) {
                // 可编辑标题
                if isEditingTitle {
                    TextField("标题", text: $titleDraft, onCommit: commitTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.headline)
                        .focused($titleFieldFocused)
                        .onAppear { titleFieldFocused = true }
                } else {
                    HStack(spacing: 4) {
                        Text(recording.fileName)
                            .font(.headline)
                            .lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        #if os(macOS)
                        // 视频导入而来的录音：音轨可转写，原始视频同文件夹留存，一键交给系统播放器
                        if let videoURL = recording.videoFileURL,
                           FileManager.default.fileExists(atPath: videoURL.path) {
                            Button {
                                NSWorkspace.shared.open(videoURL)
                            } label: {
                                Image(systemName: "play.tv")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("打开原始视频")
                            // .help 只提供鼠标 tooltip；纯图标按钮需补语义标签
                            .accessibilityLabel(Text("打开原始视频"))
                        }
                        #endif
                    }
                    .onTapGesture {
                        startEditingTitle()
                    }
                }

                Spacer()

                if experience == .pro, fileExists, !recording.folderName.isEmpty, let onCleanupAudio {
                    Button(role: .destructive, action: onCleanupAudio) {
                        Label("清理录音", systemImage: "trash.slash")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isReadOnly || MediaCleanupService.shared.isRunning)
                }

                // 播放控制（右侧）
                if fileExists, let state = playerState {
                    Button { state.togglePlayPause() } label: {
                        Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.isPlaying ? "暂停" : "播放")

                    // 时间文本抽成独立子视图：currentTime 每 0.5s 变化，若在本视图 body
                    // 直接读取，会让整个详情树（转写/画面/总结）2 次/秒重建
                    PlaybackTimeLabel(state: state)
                        // 状态行末尾是「一键处理」按钮；此处留出等宽空白，
                        // 让播放控制与状态右对齐、落在状态正上方
                        .padding(.trailing, oneClickButtonReserve)
                }
            }

            // 进度条 + 状态（合并为一行），下方接声波图
            if fileExists {
                VStack(spacing: 4) {
                    HStack(spacing: 8) {
                        if let state = playerState, state.duration > 0 {
                            // 进度条同样抽成子视图，隔离 currentTime 依赖
                            PlaybackProgressSlider(state: state)
                        }

                        // 状态指示（紧凑）
                        HStack(spacing: 4) {
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text(statusText).font(.caption2).foregroundStyle(.tertiary)
                        }
                        // 「一键处理」置于状态（转写中...）右侧：转写（若有）→ 画面分析（录屏）→ 总结 → 拆解待办
                        if let onOneClick {
                            Button {
                                onOneClick()
                            } label: {
                                Label("一键处理", systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .help("一键处理：转写 → 画面分析 → 总结 → 拆解待办")
                            .disabled(isReadOnly)
                            // 实测按钮宽度，回传给标题行做对齐留白（见 oneClickButtonReserve）
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { oneClickButtonWidth = $0 }
                        }
                    }

                    // 声波图：直接挂在播放进度条下方，一眼看出哪里有声、哪里静音；
                    // 点击/拖动即跳转。数据源是离线解码的峰值包络（见 WaveformAnalyzer）
                    if let state = playerState {
                        WaveformStrip(state: state, waveform: waveform, isLoading: !waveformAnalysisFinished)
                            .padding(.top, 2)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("录音文件已删除")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(statusText).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// 录音文件是否仍然存在于磁盘
    private var fileExists: Bool {
        audioFileExistsCache
    }

    // MARK: - 标题编辑

    private func startEditingTitle() {
        guard !isReadOnly else { return }
        titleDraft = recording.fileName
        isEditingTitle = true
    }

    private func commitTitle() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != recording.fileName {
            viewModel.updateRecordingTitle(recording, newTitle: trimmed, context: modelContext)
        }
        isEditingTitle = false
        titleFieldFocused = false
    }

    private var statusColor: Color {
        switch recording.transcriptionStatus {
        case .pending:    return .secondary
        case .processing: return .blue
        case .completed:  return .green
        case .failed:     return .red
        }
    }

    private var statusText: String {
        switch recording.transcriptionStatus {
        case .pending:    return String(localized: "等待转写")
        case .processing: return String(localized: "转写中...")
        case .completed:  return String(localized: "已完成")
        case .failed:     return String(localized: "转写失败")
        }
    }
}

// MARK: - 共享 LLM 模型选择条（详情页总结/画面页签顶部一份）

/// 录音/视频详情页的模型选择器：原为 SummaryView 与 VideoUnderstandingView 各自
/// 实现一份（绑定同一选中状态，视觉上被误读为“两个下拉框”），现统一到页签栏下方。
/// Menu 显式隐藏系统展开指示器，只保留 label 内自绘 ⌄，避免双箭头观感。
/// 图片/文字笔记（QuickNote）的选择条不在本次范围，维持原样。
struct LLMModelSelectorBar: View {
    let llmConfigs: [LLMConfig]
    @Binding var selectedLLMConfig: LLMConfig?
    /// 「画面」页签附加能力徽标：视觉模型直发帧图，非视觉模型降级本地 OCR
    var showsVisionBadge: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Label("模型", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)

            if llmConfigs.isEmpty {
                Text("未配置 LLM")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .italic()
            } else {
                Picker(selection: $selectedLLMConfig) {
                    ForEach(llmConfigs) { config in
                        Text(config.name).tag(config as LLMConfig?)
                    }
                } label: {
                    // ✅ 关键：label 留空，不写任何内容
                    EmptyView()
                }
                .pickerStyle(.menu)
                .menuIndicator(.hidden)
                // 自定义外观直接加在 Picker 上
                .frame(width: 180) // 可选：限制宽度避免空白占位
            }

            Spacer()

            if let config = selectedLLMConfig {
                HStack(spacing: 6) {
                    if showsVisionBadge {
                        Label(config.supportsVision ? "图片理解" : "本地 OCR",
                              systemImage: config.supportsVision ? "eye" : "text.viewfinder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 4) {
                        Image(systemName: config.isLocal ? "house" : "cloud")
                            .font(.caption2)
                        Text(config.isLocal ? "本地" : "云端")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.3))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

// MARK: - 播放进度子视图（隔离 0.5s 的高频刷新）

/// 播放时间文本。`AudioPlayerState.currentTime` 每 0.5s 变化；把读取放在独立子视图里，
/// 使 @Observable 的失效范围收敛到这一小块，而不是整个 RecordingDetailView 树。
private struct PlaybackTimeLabel: View {
    let state: AudioPlayerState

    var body: some View {
        Text(state.currentTime.formattedAsDuration())
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(minWidth: 50, alignment: .trailing)
    }
}

/// 播放进度条（同样隔离 currentTime 依赖）
private struct PlaybackProgressSlider: View {
    let state: AudioPlayerState

    var body: some View {
        Slider(
            value: Binding(
                get: { state.currentTime },
                set: { state.seek(to: $0) }
            ),
            in: 0...state.duration
        )
        .controlSize(.mini)
        .accessibilityLabel("播放进度")
    }
}
