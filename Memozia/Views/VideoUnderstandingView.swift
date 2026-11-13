import SwiftUI
import AVKit
import SwiftData
import AppKit

/// AppKit `AVPlayerView` 的 SwiftUI 包装。
///
/// 背景（BUG.txt 的 getSuperclassMetadata abort）：SwiftUI `VideoPlayer` 的实现位于
/// `_AVKit_SwiftUI` 垫片框架，其表示类型的 ObjC 父类在 AVKit；macOS 27 SDK 起仅
/// `import AVKit` 不再自动加载 AVKit.framework，而链接器的 `-dead_strip_dylibs`
/// 又会把 `-framework AVKit` 的加载命令裁掉（实测：单独 `-framework` 被裁，
/// 只有真实符号引用或 `-needed_framework` 能保留），于是首帧构建 VideoPlayer 时
/// 运行时解析不到父类而 abort。
///
/// 直接用 AppKit 的 `AVPlayerView` 包一层：既绕开 `_AVKit_SwiftUI` 这条崩溃面，
/// 又让应用二进制真实引用 AVKit 符号，加载命令不再被裁剪。
private struct AVPlayerContainer: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// 视频条目的画面理解页：播放器、关键帧时间轴与视觉纪要集中在同一处。
struct VideoUnderstandingView: View {
    let recording: AudioRecording
    let viewModel: RecordingViewModel
    @Binding var selectedLLMConfig: LLMConfig?
    var allowsAnalysis: Bool = true
    /// 临时模式（不落盘）：禁用抽帧/分析/画面要点编辑，仅保留浏览与复制
    var isReadOnly: Bool = false

    @Environment(\.modelContext) private var modelContext
    @State private var player: AVPlayer?
    @State private var storedFrames: [StoredVideoFrame] = []
    /// 两步式画面分析：第一步本地抽帧完成后的帧数与“是否继续分析”确认态
    @State private var extractedFrameCount = 0
    @State private var showAnalyzePrompt = false
    /// 画面要点编辑态与草稿（与总结编辑同模式：编辑→保存/取消）
    @State private var isEditingVisualNotes = false
    @State private var visualNotesDraft = ""
    /// 「清理视频」确认态与待释放体积（点按钮时取一次，删完就取不到了）
    @State private var showCleanupConfirm = false
    @State private var pendingCleanupBytes: Int64 = 0

    private struct StoredVideoFrame: Identifiable {
        let url: URL
        let time: TimeInterval
        var id: String { url.path }
    }

    private var videoURL: URL? {
        guard let url = recording.videoFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    var body: some View {
        // 原件不在也不能把整页换成错误占位：关键帧与画面要点是已落盘的产物，
        // 清理视频后用户仍要能看时间轴、继续或重新分析
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let videoURL {
                    videoPlayer(url: videoURL)
                } else {
                    missingVideoNotice
                }
                analysisHeader
                analysisContent
                keyframeTimeline
            }
            .padding()
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .task(id: recording.id) {
            configurePlayer()
            reloadStoredFrames()
            // 切换条目时丢弃上一条的编辑草稿，避免误存到别的条目
            isEditingVisualNotes = false
            visualNotesDraft = ""
        }
        .onChange(of: viewModel.isGeneratingVisualNotes(for: recording)) { wasGenerating, isGenerating in
            if wasGenerating && !isGenerating {
                reloadStoredFrames()
            }
            if isGenerating {
                // 重新分析开始时退出编辑态：生成完成后不应再用旧草稿覆盖新结果
                isEditingVisualNotes = false
                visualNotesDraft = ""
            }
        }
        .onDisappear {
            teardownPlayer()
        }
        .alert("关键帧抽取完成", isPresented: $showAnalyzePrompt) {
            Button("分析画面") { startAnalysis() }
            Button("暂不分析", role: .cancel) { }
        } message: {
            let batchSize = LLMService.maxFramesPerVisualRequest
            let batchCount = (extractedFrameCount + batchSize - 1) / batchSize
            Text(String(
                format: String(localized: "共抽取 %1$d 个关键帧（已存入条目文件夹，可重复使用），将分约 %2$d 批分析。是否继续？关键帧将上传当前模型。"),
                extractedFrameCount,
                batchCount
            ))
        }
        .alert("清理原始视频", isPresented: $showCleanupConfirm) {
            Button("取消", role: .cancel) { }
            Button("清理视频", role: .destructive) {
                viewModel.cleanupVideo(recording: recording, context: modelContext)
            }
        } message: {
            Text(String(
                format: String(localized: "只删除原始视频文件（约 %@），释放空间。关键帧 %d 张、画面要点、转写与总结全部保留。清理后无法重新抽取关键帧。"),
                ByteCountFormatter.string(fromByteCount: pendingCleanupBytes, countStyle: .file),
                storedFrames.count
            ))
        }
    }

    /// 原件不在（已清理或在 Finder 里被移走）：说清还留着什么、还能做什么，
    /// 不把已经生成的产物一并藏起来
    private var missingVideoNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "video.slash")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("原始视频不在本机")
                    .font(.callout.weight(.medium))
                Text(storedFrames.isEmpty
                     ? String(localized: "重新导入视频后才能抽取关键帧；已生成的画面要点仍会保留。")
                     : String(localized: "关键帧与画面要点已保留，仍可继续分析或重新分析；只是无法重新抽取关键帧。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 画面分析第一步：本地抽帧（不上云）。完成后刷新关键帧时间轴，
    /// 并弹框询问用户是否进入第二步；取消或失败不弹窗（错误已在 ViewModel 内提示）
    private func startExtraction() {
        Task {
            if let count = await viewModel.extractVisualFrames(recording: recording).value, count > 0 {
                extractedFrameCount = count
                reloadStoredFrames()
                showAnalyzePrompt = true
            }
        }
    }

    /// 第二步：把缓存帧送当前模型生成画面要点
    private func startAnalysis() {
        guard let config = selectedLLMConfig else { return }
        _ = viewModel.generateVisualNotes(
            recording: recording,
            llmConfig: config,
            context: modelContext
        )
    }

    /// 保存画面要点编辑（加密入库 + 同步文件夹），空内容不允许保存
    private func saveVisualNotesEdit() {
        viewModel.updateRecordingVisualSummary(
            recording,
            newVisualSummary: visualNotesDraft,
            context: modelContext
        )
        isEditingVisualNotes = false
        visualNotesDraft = ""
    }

    /// 复制文本到系统剪贴板（与其余视图的 copyToClipboard 保持一致）
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

    private func videoPlayer(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AVPlayerContainer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(minHeight: 240)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Label(url.lastPathComponent, systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                #if os(macOS)
                Button("用系统播放器打开") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.link)
                .font(.caption)
                #endif
                // 清理入口只放在原件确实存在时；删完自然改由 `missingVideoNotice` 说明状态
                if allowsAnalysis {
                    Button {
                        pendingCleanupBytes = Self.fileSize(of: url)
                        showCleanupConfirm = true
                    } label: {
                        Label("清理视频", systemImage: "trash.slash")
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(viewModel.isCleaningUpVideo)
                    .help("只删除原始视频文件，关键帧与画面要点保留")
                }
            }
        }
    }

    private var analysisHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("画面要点")
                        .font(.headline)
                    Text("抽取代表性画面，按视频时间轴记录幻灯片、文档、代码和共享界面；重新分析会复用关键帧。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if !allowsAnalysis {
                    Label("开启专业模式可分析或重新分析画面", systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.isGeneratingVisualNotes(for: recording) {
                    Button {
                        viewModel.cancelVisualNotes()
                    } label: {
                        Label("停止", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else if storedFrames.isEmpty {
                    // 第一步：仅本地抽帧不上云；完成后弹确认是否进入画面分析
                    Button {
                        startExtraction()
                    } label: {
                        Label("抽取关键帧", systemImage: "film.stack")
                    }
                    .buttonStyle(.borderedProminent)
                    // 原件已清理且无缓存时抽不出任何东西，不把必然失败的按钮交给用户
                    .disabled(viewModel.isSummarizing || videoURL == nil || isReadOnly)
                } else {
                    // 第二步：帧已就绪（命中磁盘缓存），点击即已确认上传
                    Button {
                        startAnalysis()
                    } label: {
                        Label(
                            recording.decryptedVisualSummary.isEmpty ? "分析画面" : "重新分析",
                            systemImage: recording.decryptedVisualSummary.isEmpty ? "sparkles" : "arrow.clockwise"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedLLMConfig == nil || viewModel.isSummarizing || isReadOnly)
                }
            }

            if let config = selectedLLMConfig {
                Text(privacyDescription(for: config))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var analysisContent: some View {
        if viewModel.isGeneratingVisualNotes(for: recording) {
            // 单独成视图：流式正文与进度都只在这层 body 里读取，
            // @Observable 的失效因此只落在这一块，不会连带整页重算
            VisualNotesProgressPanel(viewModel: viewModel)
        } else {
            let notes = recording.decryptedVisualSummary
            if notes.isEmpty {
                ContentUnavailableView(
                    "尚未分析画面",
                    systemImage: "rectangle.stack.badge.play",
                    description: Text("选择模型并点击“分析画面”，生成带时间标记的视觉纪要。")
                )
                .frame(minHeight: 150,alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        if let generatedAt = recording.visualSummaryGeneratedAt {
                            Label(
                                "生成于 \(generatedAt, format: .dateTime.year().month().day().hour().minute())",
                                systemImage: "clock"
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if isEditingVisualNotes {
                            // 取消在保存左侧，二者一起居右（与总结/快记编辑态一致）
                            Button("取消") {
                                isEditingVisualNotes = false
                                visualNotesDraft = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("保存") {
                                saveVisualNotesEdit()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(visualNotesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            // 一键复制画面要点：Markdown 按块渲染后拖选无法跨块，整段复制改走按钮
                            Button {
                                copyToClipboard(notes)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("复制画面要点")
                            .accessibilityLabel(Text("复制画面要点"))

                            if allowsAnalysis {
                                Button {
                                    visualNotesDraft = notes
                                    isEditingVisualNotes = true
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("编辑画面要点")
                                .accessibilityLabel(Text("编辑画面要点"))
                                .disabled(isReadOnly)
                            }
                        }
                    }

                    if isEditingVisualNotes {
                        TextEditor(text: $visualNotesDraft)
                            .font(.body)
                            // 固定高度：页面为整体滚动结构，框内自行滚动
                            .frame(height: 240)
                            .padding(8)
                            .background(.quaternary.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            // 编辑模式查找（⌘F）/替换（⌘R）支持
                            .textFindReplace(text: $visualNotesDraft)
                    } else {
                        MarkdownView(markdown: notes)
                    }
                }
                .padding()
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))

                // 画面要点由多模态模型生成：提示放在卡片下方，与总结/待办口径一致
                AIContentDisclaimer()
            }
        }
    }

    @ViewBuilder
    private var keyframeTimeline: some View {
        if !storedFrames.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("关键帧时间轴")
                        .font(.headline)
                    Text("\(storedFrames.count) 帧")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    #if os(macOS)
                    Button("打开目录") {
                        NSWorkspace.shared.open(recording.framesDirectoryURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    #endif
                }

                ScrollView(.horizontal) {
                    // Lazy：帧最多 1024 张，普通 HStack 会对全部帧同步解码
                    // NSImage(contentsOf:)，一次布局即阻塞主线程（见 use 帧缓存页）
                    LazyHStack(spacing: 12) {
                        ForEach(storedFrames) { frame in
                            Button {
                                seekAndPlay(to: frame.time)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    frameThumbnail(frame)
                                        .frame(width: 168, height: 96)
                                        .clipped()
                                        .background(.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 7))
                                    Text(frame.time.formattedAsDuration())
                                        .font(.caption.monospacedDigit().weight(.medium))
                                    // 原件已清理时没有可跳转的播放器，不给出做不到的承诺
                                    if videoURL != nil {
                                        Text("点击跳转到此画面")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(videoURL == nil)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    @ViewBuilder
    private func frameThumbnail(_ frame: StoredVideoFrame) -> some View {
        // 走带缓存的降采样加载：时间轴每次 body 重算都会渲染可见帧，
        // 旧的 `NSImage(contentsOf:)` 会按原始分辨率重复解码（帧最多 1024 张）
        if let image = keyframeThumbnail(at: frame.url) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func configurePlayer() {
        teardownPlayer()
        player = videoURL.map(AVPlayer.init(url:))
    }

    /// 释放播放器：`pause()` 只停播放，不释放 AVURLAsset 持有的文件句柄与解码资源。
    /// 主动清空当前条目再置 nil，避免「清理视频」删除原件后播放器仍指向已 unlink 的 URL
    ///（界面表现为黑屏而非明确的“原件已清理”）
    private func teardownPlayer() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func seekAndPlay(to seconds: TimeInterval) {
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player?.play()
    }

    private func reloadStoredFrames() {
        let directory = recording.framesDirectoryURL
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        storedFrames = urls
            .filter { $0.pathExtension.lowercased() == "jpg" }
            .compactMap { url in
                guard let time = Self.frameTime(from: url) else { return nil }
                return StoredVideoFrame(url: url, time: time)
            }
            .sorted { $0.time < $1.time }
    }

    private static func frameTime(from url: URL) -> TimeInterval? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let component = stem.split(separator: "_").last,
              component.hasSuffix("s"),
              let seconds = Double(component.dropLast()) else { return nil }
        return seconds
    }

    /// 确认弹框里的“约 xx MB”：取不到属性时按 0 显示，不编造体积
    private static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int64) ?? 0
    }

    private func privacyDescription(for config: LLMConfig) -> String {
        // 走 String(localized:)：该文案经 Text(String) 渲染，裸中文会永久不本地化
        if !config.supportsVision {
            return String(localized: "关键帧先在本机 OCR，模型只接收带时间标记的文字。")
        }
        return config.isLocal
            ? String(localized: "关键帧将发送给本地视觉模型。")
            : String(localized: "关键帧将发送给所选云端视觉模型。")
    }
}

// MARK: - 画面分析进行中面板

/// 画面分析的进行中面板：进度条 + 默认折叠的流式正文。
///
/// 抽成独立视图是有意为之：`visualNotesText` / `visualNotesProgress` / 段号计数
/// 都只在这层 body 里读取，@Observable 的失效因此只落在这一块。若把这些读取留在
/// `VideoUnderstandingView` 的 body 里，每 0.3s 一次的流式刷新会让整页（含
/// 158 帧的关键帧时间轴）跟着重算，分析期间明显掉帧。
private struct VisualNotesProgressPanel: View {
    let viewModel: RecordingViewModel
    /// 展开态：折叠时 SwiftUI 不布局折叠内容，长文本增长几乎零成本。
    /// 面板只在「进行中」存在，重新分析时以折叠态重建，不需要额外复位
    @State private var isStreamDetailExpanded = false
    /// 「思考过程」折叠态：与正文分开，默认折叠
    @State private var isReasoningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: min(max(viewModel.visualNotesProgress, 0), 1))
            Text(viewModel.visualNotesProgress < 0.5
                 ? "正在抽取并筛选关键帧…"
                 : "正在请模型读取画面…")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 推理型模型的思考过程：仅生成期间可见（本地视觉路径关闭思考，通常为空）
            ReasoningDisclosureView(
                text: viewModel.visualNotesReasoningText,
                isExpanded: $isReasoningExpanded
            )

            if !viewModel.visualNotesText.isEmpty {
                DisclosureGroup(isExpanded: $isStreamDetailExpanded) {
                    Text(viewModel.visualNotesText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                } label: {
                    // 图标用 eye：这里展开的是模型产出的画面要点，不是思考过程
                    Label(streamDetailTitle, systemImage: "eye")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if !viewModel.visualNotesText.isEmpty || !viewModel.visualNotesReasoningText.isEmpty {
                AIContentDisclaimer()
            }
        }
        .padding()
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 折叠标题只带段号与字数，不参与正文渲染；字数让「跑了很久」这件事有可核对的进度
    private var streamDetailTitle: String {
        String(
            format: String(localized: "画面读取过程（第 %1$d/%2$d 段，已收到 %3$d 字）"),
            viewModel.visualNotesSegmentIndex,
            viewModel.visualNotesSegmentTotal,
            viewModel.visualNotesText.count
        )
    }
}

// MARK: - 关键帧缩略图加载

/// 关键帧缩略图缓存。按 URL 缓存降采样后的位图，NSCache 在内存压力下自动驱逐。
/// 与 `QuickNoteDetailView` 的笔记图片缓存同一思路：视图 body 会因播放进度、
/// 选中态等频繁重算，没有缓存时每个可见帧都会重新解码一次。
private final class FrameThumbnailCacheBox: @unchecked Sendable {
    let cache = NSCache<NSURL, NSImage>()
    init() {
        // 缩略图尺寸小（512px 长边），128MB 足够放下上千张
        cache.totalCostLimit = 128 * 1024 * 1024
    }
}

private let frameThumbnailCacheBox = FrameThumbnailCacheBox()

/// 时间轴缩略图显示尺寸为 168×96，2x Retina 约需 336px，取 512 留余量
private let frameThumbnailMaxPixelSize: CGFloat = 512

private func keyframeThumbnail(at url: URL) -> NSImage? {
    if let cached = frameThumbnailCacheBox.cache.object(forKey: url as NSURL) {
        return cached
    }
    guard let image = downsampledKeyframe(at: url, maxPixelSize: frameThumbnailMaxPixelSize)
        ?? NSImage(contentsOf: url) else { return nil }
    let cost = Int(image.size.width * image.size.height) * 4
    frameThumbnailCacheBox.cache.setObject(image, forKey: url as NSURL, cost: cost)
    return image
}

/// CGImageSource 降采样：只解码目标尺寸，内存占用与 maxPixelSize 挂钩而非原图分辨率
private func downsampledKeyframe(at url: URL, maxPixelSize: CGFloat) -> NSImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
