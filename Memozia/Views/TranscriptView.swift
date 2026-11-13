import SwiftUI

/// 转写展示视图（Markdown 渲染 + 可编辑）
struct TranscriptView: View {
    let recording: AudioRecording
    var transcriptionProgress: Float = 0
    /// 转写当前阶段文案（如“正在区分说话人…”），为空时显示默认文案
    var processingStage: String = ""
    var canUndo: Bool = false
    var onSegmentEdit: ((TranscriptSegment, String) -> Void)?
    var onUndo: (() -> Void)?
    var onMarkdownEdit: ((String) -> Void)?
    var allowsEditing: Bool = true
    /// 转写控制（从侧边栏工具栏迁入）：未提供时隐藏转写按钮
    var onTranscribe: (() -> Void)?
    var onCancelTranscription: (() -> Void)?
    /// 声纹标记回调：(说话人标注, 姓名)，未提供时隐藏标记按钮
    var onMarkVoiceprint: (@MainActor (String, String) async throws -> Void)?
    /// 转写内容版本号：任何片段变更由 ViewModel 递增，驱动缓存重建
    var transcriptVersion: Int = 0
    /// 点击时间行播放对应录音段回调（参数为片段起始秒数），未提供时链接走系统行为
    var onSeek: ((TimeInterval) -> Void)? = nil
    /// 试听指定时间区间回调（声纹标记弹窗的播放按钮），未提供或音频缺失时隐藏该按钮
    var onPlayRange: ((TimeInterval, TimeInterval) -> Void)? = nil

    @State private var searchText = ""
    /// 搜索当前定位的匹配段序号（在 matchedSegments 中循环）
    @State private var currentMatchIndex = 0
    @State private var isEditing = false
    @State private var editDraft = ""
    @State private var showVoiceprintSheet = false
    /// 预解析的转写块（缓存命中或后台构建完成后上屏）
    @State private var transcriptBlocks: [TranscriptBlock]?
    /// 后台构建的 Markdown 原文（供编辑入口使用，避免再次全量解密）
    @State private var transcriptMarkdownText = ""
    @State private var isBuildingTranscript = false

    /// 渲染记忆（引用类型 + @State：跨 body 求值存活，内部不参与 Observation）。
    ///
    /// 旧写法这些结果都是无记忆的计算属性：一次 body 至少访问 `sortedSegments`
    /// 5 次、`matchedSegments` 4 次，每次都重排整篇片段并对每段做
    /// `decryptedText` + `localizedCaseInsensitiveContains`；搜索框又没有防抖，
    /// 每敲一个字符就把整篇转写重排+重解密+全量扫描一遍。
    @State private var memo = TranscriptRenderMemo()

    /// 防抖后的搜索词（真正参与匹配；输入框仍即时回显 searchText）
    @State private var debouncedSearchText = ""

    /// 录音的音频文件是否存在（不存在时禁用转写）。
    /// 旧实现是 body 里的 `FileManager.fileExists`（还会在 folderURL 内再 stat 一次），
    /// 现由 `.task(id:)` 查一次写入状态。
    @State private var audioFileExists = true

    private var sortKey: String { "\(recording.id)-v\(transcriptVersion)" }

    private var sortedSegments: [TranscriptSegment] {
        memo.sortedSegments(segments: recording.segments, key: sortKey)
    }

    /// 搜索命中的片段（正文或发言人匹配，大小写不敏感；结果按 key 记忆）
    private var matchedSegments: [TranscriptSegment] {
        memo.matchedSegments(
            segments: sortedSegments,
            search: debouncedSearchText,
            key: "\(sortKey)-#\(debouncedSearchText)"
        )
    }

    /// 录音中已标注的不同说话人（去重，保持首次出现顺序；结果按 key 记忆）
    private var distinctSpeakers: [String] {
        memo.distinctSpeakers(segments: sortedSegments, key: sortKey)
    }

    var body: some View {
        Group {
            switch recording.transcriptionStatus {
            case .pending:
                ContentUnavailableView {
                    Label("尚未转写", systemImage: "waveform")
                } description: {
                    Text("点击下方按钮开始语音识别")
                } actions: {
                    transcribeActionButton
                }
            case .processing:
                processingView
            case .completed:
                if sortedSegments.isEmpty {
                    ContentUnavailableView(
                        "转写为空",
                        systemImage: "text.bubble",
                        description: Text("未能识别到有效内容，请检查音频质量")
                    )
                } else {
                    transcriptContent
                }
            case .failed:
                ContentUnavailableView {
                    Label("转写失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(recording.errorMessage ?? String(localized: "未知错误，请重试"))
                } actions: {
                    transcribeActionButton
                }
            }
        }
        .sheet(isPresented: $showVoiceprintSheet) {
            VoiceprintMarkingSheet(
                recording: recording,
                onMark: { speaker, name in
                    guard let onMarkVoiceprint else { return }
                    try await onMarkVoiceprint(speaker, name)
                },
                // 音频原件不在时不给播放回调，弹窗里对应按钮自动禁用
                onPlayRange: audioFileExists ? onPlayRange : nil
            )
        }
        // 拦截时间行链接（Memozia://seek/<秒>），定位播放器到片段起始处；
        // 其余链接交回系统默认行为
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "Memozia",
                  url.host == "seek",
                  let seconds = Double(url.lastPathComponent) else {
                return .systemAction
            }
            onSeek?(seconds)
            return .handled
        })
    }

    // MARK: - 转写按钮

    /// 转写操作按钮（随状态切换：已完成后“重转” / 其他“转写”）
    /// 注：模型下载/准备已收敛进 TaskCenter 队列步骤（进度在队列面板展示），
    /// 原先基于传参的「加载模型」转圈是永不触发的死状态，已移除
    @ViewBuilder
    private var transcribeActionButton: some View {
        Button {
            onTranscribe?()
        } label: {
            Label(recording.transcriptionStatus == .completed ? "重转" : "转写",
                  systemImage: "square.text.square")
        }
        .buttonStyle(.bordered)
        .disabled(!audioFileExists)
        .help(audioFileExists
              ? (recording.transcriptionStatus == .completed ? "重新转写" : "开始转写")
              : "录音文件已删除，无法转写")
    }

    /// 转写进行中的取消按钮
    private var cancelTranscriptionButton: some View {
        Button {
            onCancelTranscription?()
        } label: {
            Label("取消转写", systemImage: "xmark.circle")
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .help("取消当前转写")
    }

    // MARK: - 转写内容

    private var transcriptContent: some View {
        VStack(spacing: 0) {
            // 内容区域：编辑态不用 ScrollView 包裹——TextEditor 自带内建滚动，
            // 外层再套会把编辑框撑到内容高度无限下延；阅读态保持 ScrollView 懒加载
            if isEditing {
                editingContentView
                    .padding()
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity) // 填满可用高度，编辑框自适应父容器
            } else {
                ScrollView {
                    markdownContentView
                        .padding()
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()

            // 底部操作栏（与 SummaryView 一致）
            bottomActionBar
        }
        // 切换录音/片段变更时重建转写块：缓存命中即显，未命中后台解密+解析
        .task(id: "\(recording.id)-v\(transcriptVersion)") {
            transcriptBlocks = nil
            transcriptMarkdownText = ""
            audioFileExists = FileManager.default.fileExists(atPath: recording.fileURL.path)
            await loadTranscriptBlocks()
        }
        .onChange(of: recording.audioRemovedAt) { _, _ in
            audioFileExists = FileManager.default.fileExists(atPath: recording.fileURL.path)
        }
        // 搜索防抖：与列表页一致的 300ms 窗口，避免逐字符触发整篇匹配扫描
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            debouncedSearchText = searchText
        }
    }

    /// 加载转写块：优先读缓存，未命中时主线程快照后后台解密构建
    private func loadTranscriptBlocks() async {
        if let entry = await TranscriptCache.entry(for: recording.id) {
            transcriptBlocks = entry.blocks
            transcriptMarkdownText = entry.markdown
            return
        }
        isBuildingTranscript = true
        defer { isBuildingTranscript = false }
        // 主线程快照（SwiftData 模型只在主 Actor 触碰），重活丢到后台
        let datas: [TranscriptMarkdownBuilder.SegmentData] = sortedSegments.map {
            TranscriptMarkdownBuilder.SegmentData(
                timeRange: $0.formattedTimeRange,
                startTime: $0.startTime,
                speaker: $0.speaker,
                encryptedText: $0.text
            )
        }
        guard !datas.isEmpty else {
            transcriptBlocks = []
            return
        }
        let recordingID = recording.id
        let built = await Task.detached(priority: .userInitiated) {
            TranscriptMarkdownBuilder.build(from: datas)
        }.value
        await TranscriptCache.insert(
            entry: TranscriptCacheEntry(markdown: built.markdown, blocks: built.blocks),
            for: recordingID
        )
        transcriptBlocks = built.blocks
        transcriptMarkdownText = built.markdown
    }

    // MARK: - Markdown 显示

    private var markdownContentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 段数信息
            HStack(spacing: 8) {
                Text("共 \(sortedSegments.count) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !debouncedSearchText.isEmpty {
                    Text("· 搜索：\(debouncedSearchText)")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }

            Label("转写可能有误，请核对重要内容。", systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 搜索时高亮匹配内容，仍用 Markdown 渲染
            // 分支条件用防抖词：与 matchedSegments 的输入保持一致，
            // 否则防抖窗口内会出现"搜索词非空但匹配结果为空"的假"无匹配"闪烁
            if debouncedSearchText.isEmpty {
                if let blocks = transcriptBlocks {
                    MarkdownView(markdown: "", blocks: blocks)
                } else if isBuildingTranscript {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在加载转写内容…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            } else if matchedSegments.isEmpty {
                Text("未找到匹配内容")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                // 搜索结果：逐段渲染 + 匹配字符高亮 + 可滚动定位到当前匹配段
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(matchedSegments.enumerated()), id: \.offset) { index, segment in
                            MarkdownView(
                                markdown: matchMarkdown(for: segment),
                                highlightText: searchText,
                                // 当前定位段用橙色区分，其余匹配为黄色
                                highlightColor: index == currentMatchIndex ? .orange : .yellow
                            )
                            .id("match-\(index)")
                        }
                    }
                    .onChange(of: currentMatchIndex) { _, newValue in
                        withAnimation {
                            proxy.scrollTo("match-\(newValue)", anchor: .center)
                        }
                    }
                    .onChange(of: searchText) { _, _ in
                        // 注意：不要把 debouncedSearchText 在这里同步赋值，那等于取消防抖；
                        // 防抖词只由 .task(id: searchText) 在 300ms 窗口后写入
                        // 搜索词变化：重置定位并滚回首个匹配
                        currentMatchIndex = 0
                        withAnimation {
                            proxy.scrollTo("match-0", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    /// 搜索结果中单个匹配段的 Markdown（时间行带点击播放链接，与主渲染路径一致）
    private func matchMarkdown(for segment: TranscriptSegment) -> String {
        var line = "[**\(segment.formattedTimeRange)**](Memozia://seek/\(segment.startTime))"
        if let speaker = segment.speaker, !speaker.isEmpty {
            line += " · **\(speaker)**"
        }
        line += "\n\n\(segment.decryptedText)"
        return line
    }

    // MARK: - 编辑模式

    private var editingContentView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .font(.caption2)
                Text("编辑模式（支持 Markdown）")
                    .font(.caption)
            }
            .foregroundStyle(.tint)

            // 编辑框自适应父容器高度：VStack 撑满后 TextEditor 拿到剩余空间，
            // 内容超出走内建滚动，不再随内容无限下延
            TextEditor(text: $editDraft)
                .font(.body)
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.tint.opacity(0.5), lineWidth: 1)
                )
                // 编辑模式查找（⌘F）/替换（⌘R）支持
                .textFindReplace(text: $editDraft)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 底部操作栏（与 SummaryView 风格一致）

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            // 搜索框（左侧）：仅非编辑状态显示——编辑模式下的查找走 ⌘F（textFindReplace）
            if !isEditing {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("搜索转写内容...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchText.isEmpty {
                        // 匹配计数 + 下一个匹配导航
                        if !matchedSegments.isEmpty {
                            Text("\(min(currentMatchIndex + 1, matchedSegments.count))/\(matchedSegments.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)

                            Button {
                                currentMatchIndex = (currentMatchIndex + 1) % matchedSegments.count
                            } label: {
                                Label("下一个", systemImage: "chevron.down")
                            }
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                            .help("定位到下一个匹配的段落")
                        }
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("清除搜索")
                        // 纯图标按钮：与列表搜索框同一口径补语义标签
                        .accessibilityLabel(Text("清除搜索"))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Spacer()

            if isEditing {
                Button {
                    isEditing = false
                    editDraft = ""
                } label: {
                    Label("取消", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Button {
                    saveEdit()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text("保存")
                    }
                    .fontWeight(.medium)
                }
                .buttonStyle(.borderedProminent)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                // 转写按钮固定在复制/编辑之前；编辑模式下复制/编辑切换为取消/保存，
                // 转写按钮同步隐藏，避免编辑中误触重转丢失草稿
                transcribeActionButton

                // 声纹标记：仅在有说话人标注且提供了回调时显示
                if onMarkVoiceprint != nil && !distinctSpeakers.isEmpty {
                    Button {
                        showVoiceprintSheet = true
                    } label: {
                        Label("声纹", systemImage: "person.wave.2")
                    }
                    .buttonStyle(.bordered)
                    .help("把说话人标记为真实姓名，下次转写自动识别")
                }

                Button {
                    // 与编辑按钮一致：复制带说话人与时间段的 Markdown（优先用已构建结果，
                    // 避免点击时再次全量解密）
                    copyToClipboard(transcriptMarkdownText.isEmpty
                        ? recording.transcriptMarkdown
                        : transcriptMarkdownText)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                if allowsEditing {
                    Button {
                        // 优先用已构建的 Markdown，避免点击时再次全量解密
                        editDraft = transcriptMarkdownText.isEmpty
                            ? recording.transcriptMarkdown
                            : transcriptMarkdownText
                        isEditing = true
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .disabled(transcriptBlocks == nil && isBuildingTranscript)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 处理中视图

    private var processingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView(value: transcriptionProgress, total: 1.0) {
                Text(processingStage.isEmpty ? String(localized: "正在转写中...") : processingStage)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            } currentValueLabel: {
                // 百分比用 FormatStyle 格式化，避免字符串拼接 "%%" 触发本地化警告
                Text(transcriptionProgress.formatted(.percent.precision(.fractionLength(0))))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 300)
            Text("这可能需要几分钟时间，取决于音频长度")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            cancelTranscriptionButton
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 操作

    private func saveEdit() {
        let trimmed = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onMarkdownEdit?(trimmed)
        isEditing = false
        editDraft = ""
    }

    private func copyToClipboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        UIPasteboard.general.string = text
        */
        #endif
    }
}

// MARK: - 声纹标记弹窗

/// 声纹标记弹窗：为录音中的每个说话人填写真实姓名并注册声纹。
/// 说话人列表从录音实时计算：标记成功后该标注自动替换为姓名。
struct VoiceprintMarkingSheet: View {
    let recording: AudioRecording
    let onMark: @MainActor (String, String) async throws -> Void
    /// 试听该说话人最早一段的回调（start, end）；nil 时播放按钮禁用（如音频原件已删除）
    var onPlayRange: ((TimeInterval, TimeInterval) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var names: [String: String] = [:]
    @State private var busySpeaker: String?
    @State private var errorMessage = ""

    /// 录音中的说话人（去重，保持首次出现顺序）
    private var speakers: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for segment in recording.segments.sorted(by: { $0.startTime < $1.startTime }) {
            if let speaker = segment.speaker, !speaker.isEmpty, seen.insert(speaker).inserted {
                result.append(speaker)
            }
        }
        return result
    }

    private func segmentCount(of speaker: String) -> Int {
        recording.segments.filter { $0.speaker == speaker }.count
    }

    /// 该说话人**最早**出现的片段：试听它最能代表这个人的音色，
    /// 且靠近会议开头，通常也最容易分辨（后段可能混入更多重叠/环境声）
    private func earliestSegment(of speaker: String) -> TranscriptSegment? {
        recording.segments
            .filter { $0.speaker == speaker }
            .min(by: { $0.startTime < $1.startTime })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("声纹标记")
                .font(.headline)
            Text("填写真实姓名后标记：声纹将保存到声纹库，下次转写录到同一人时自动标注为该姓名。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if speakers.isEmpty {
                Text("当前录音没有说话人标注，请先在设置中开启说话人分离并重新转写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(speakers, id: \.self) { speaker in
                HStack(spacing: 10) {
                    // 试听该说话人最早一段：帮助下决心填谁的名字
                    Button {
                        guard let segment = earliestSegment(of: speaker) else { return }
                        onPlayRange?(segment.startTime, segment.endTime)
                    } label: {
                        Image(systemName: "play.circle")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .disabled(onPlayRange == nil || earliestSegment(of: speaker) == nil)
                    .help("试听该说话人最早的一段，便于判断是谁")

                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker)
                            .fontWeight(.medium)
                        Text("\(segmentCount(of: speaker)) 个片段")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 110, alignment: .leading)

                    TextField("姓名", text: binding(for: speaker))
                        .textFieldStyle(.roundedBorder)

                    Button {
                        mark(speaker)
                    } label: {
                        if busySpeaker == speaker {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("标记")
                        }
                    }
                    .disabled(busySpeaker != nil
                              || (names[speaker] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
            }
        }
        .padding(20)
        // 最小宽度而非固定宽度：长说话人名 / 大字号下允许自适应增长
        .frame(minWidth: 460)
    }

    private func binding(for speaker: String) -> Binding<String> {
        Binding(
            get: { names[speaker] ?? "" },
            set: { names[speaker] = $0 }
        )
    }

    private func mark(_ speaker: String) {
        guard let name = names[speaker]?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty
        else { return }
        busySpeaker = speaker
        errorMessage = ""
        Task {
            do {
                try await onMark(speaker, name)
                names[speaker] = ""
            } catch {
                errorMessage = error.localizedDescription
            }
            busySpeaker = nil
        }
    }
}
// MARK: - 转写渲染记忆

/// `TranscriptView` 的渲染期记忆：排序结果、搜索结果与说话人去重各按 key 缓存一份，
/// 同一次 body 求值内多次访问只算一次。
///
/// 只在主线程使用（内部持有 SwiftData 托管对象），因此标注 @MainActor。
/// key 由「录音 id + 内容版本号 + 搜索词」构成：写路径递增版本号即自动失效。
@MainActor
final class TranscriptRenderMemo {
    private var sortedKey = ""
    private var sorted: [TranscriptSegment] = []
    private var matchKey = ""
    private var matched: [TranscriptSegment] = []
    private var speakersKey = ""
    private var speakers: [String] = []

    func sortedSegments(segments: [TranscriptSegment], key: String) -> [TranscriptSegment] {
        if key == sortedKey { return sorted }
        sorted = segments.sorted { $0.startTime < $1.startTime }
        sortedKey = key
        return sorted
    }

    func matchedSegments(segments: [TranscriptSegment], search: String, key: String) -> [TranscriptSegment] {
        guard !search.isEmpty else { return [] }
        if key == matchKey { return matched }
        matched = segments.filter { segment in
            segment.decryptedText.localizedCaseInsensitiveContains(search) ||
            (segment.speaker?.localizedCaseInsensitiveContains(search) ?? false)
        }
        matchKey = key
        return matched
    }

    func distinctSpeakers(segments: [TranscriptSegment], key: String) -> [String] {
        if key == speakersKey { return speakers }
        var seen = Set<String>()
        var result: [String] = []
        for segment in segments {
            if let speaker = segment.speaker, !speaker.isEmpty, seen.insert(speaker).inserted {
                result.append(speaker)
            }
        }
        speakers = result
        speakersKey = key
        return result
    }
}
