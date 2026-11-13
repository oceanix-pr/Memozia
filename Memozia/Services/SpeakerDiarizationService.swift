import Foundation
@preconcurrency import AVFoundation
// sherpa-onnx-shared 动态产品的 Swift 模块名，API 与静态产品完全一致
import SherpaOnnxShared

/// 说话人分离模型文件夹默认路径
enum DiarizationModelFolder {
    /// 模型文件夹路径的持久化键（设置页写入；引导页等非 MainActor 场景读同一键）
    static let defaultsKey = "diarization_model_path"

    /// 默认模型文件夹路径：macOS 为 ~/Documents/Memozia/DiarizationModel，
    /// iOS 为沙盒 Documents/Memozia/DiarizationModel（与 WhisperModelFolder 同规则）
    static var defaultPath: String {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        */
        #endif
        return base
            .appendingPathComponent("Memozia")
            .appendingPathComponent("DiarizationModel")
            .path
    }

    /// 当前生效路径：设置覆盖优先（空串视为未设置），否则默认目录
    static var resolvedPath: String {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty else {
            return defaultPath
        }
        return stored
    }
}

/// 说话人分离推理可用的 CPU 核心数设置（专业模式暴露给用户）。
///
/// 取值范围：下限固定 2；上限为「逻辑核心数 - 1」（给系统与其他进程留一个核），
/// 当机器核心很少（≤3）时上限收敛为 2，保证区间始终有效（2...2）。
/// 读写走 UserDefaults，非 MainActor 的分离服务可直接解析生效值。
enum DiarizationThreads {
    /// 持久化键（设置页写入；分离服务读同一键）
    static let defaultsKey = "diarization_thread_count"

    /// 允许的下限核心数
    static let minAllowed = 2

    /// 允许的上限核心数：核心数 - 1，但不低于下限
    static var maxAllowed: Int {
        max(minAllowed, ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    /// 把任意取值夹到允许区间
    static func clamp(_ value: Int) -> Int {
        min(max(value, minAllowed), maxAllowed)
    }

    /// 默认核心数：沿用历史启发式（核心数 - 2，封顶 6），再夹到允许区间
    static var defaultThreads: Int {
        clamp(min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    /// 当前生效核心数：有保存值则夹到区间后使用，否则用默认值
    static var resolved: Int {
        guard let stored = UserDefaults.standard.object(forKey: defaultsKey) as? Int else {
            return defaultThreads
        }
        return clamp(stored)
    }
}

/// 说话人区分「精细度」档位（专业模式暴露给用户）。
///
/// 单一轴：**边界与分段精度 ↔ CPU / 内存开销**。中间档 `.standard` 严格等于历史默认值
/// （30min / 256MB / 8min / 30s / ratio 0.25），因此默认档不改变既有行为。
///
/// 两类参数**刻意不随档位变化**：
/// - 嵌入选段上限 `maxSegmentsPerSpeaker`：注册（`voiceprintRanges`）与识别
///   （`embeddingSegmentsBySpeaker`）共用它，随档变化会让「按旧档注册的声纹」与
///   「按新档比对的质心」落在两个构造上，重新引入注册/识别错位；
/// - 三个聚类与跨段合并阈值（0.60 / 0.50 / 0.55）：由 `DiarizationCalibrator` 在真实录音上
///   联合校准得出，脱离校准改数值会把「同人拆簇」变成「两人合并」，风险高于收益。
///
/// ## 为什么整段门槛对所有档位都不超过 30 分钟（实测依据）
///
/// 峰值内存由**单次 `process()` 的音频长度**主导（ONNX Runtime 的中间张量），
/// 而不是解码后的采样数组；`maxDirectMemoryBytes` 只约束后者，真正生效的是
/// `maxDirectDuration` 与 `segmentDuration`。
///
/// 2026-09-24 用 143 分钟 16k 单声道录音（4 线程）实测：
/// - 分段（12 分钟/段）→ 峰值 **1.68 GB**，12 分 30 秒完成；
/// - 整段（143 分钟一次 `process`）→ 峰值 **8.3 GB**，14 分 20 秒仍未完成（被终止）。
///
/// 因此提高 `maxDirectDuration` 是**危险**的：档位越高越不允许整段，精细度只能通过
/// 「分段粒度 + 窗口重叠」体现。`segmentDuration` 上限取 20 分钟（按上述斜率外推约 2 GB 量级）。
enum DiarizationPrecision: Int, CaseIterable, Sendable {
    case fastest = 1
    case fast = 2
    case standard = 3
    case fine = 4
    case finest = 5

    /// 持久化键（设置页写入；分离服务读同一键）
    static let defaultsKey = "diarization_precision"

    /// 默认档（中间档 = 历史默认行为）
    static let defaultValue: DiarizationPrecision = .standard

    /// 当前生效档位：无保存值或越界时回落到默认档
    static var resolved: DiarizationPrecision {
        guard let raw = UserDefaults.standard.object(forKey: defaultsKey) as? Int,
              let value = DiarizationPrecision(rawValue: raw)
        else {
            return defaultValue
        }
        return value
    }

    static func set(_ value: DiarizationPrecision, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: defaultsKey)
    }

    /// 分段策略（何时分段 / 每段多长 / 重叠多少）
    ///
    /// `maxDirectDuration` 在所有档位都不超过 30 分钟（见类型注释的实测依据）：
    /// 档位越高越不依赖「整段」，靠更长的分段与更密的窗口换精度。
    var policy: DiarizationSegmentationPlanner.Policy {
        switch self {
        case .fastest:
            return DiarizationSegmentationPlanner.Policy(
                maxDirectDuration: 10 * 60,
                maxDirectMemoryBytes: 96 * 1024 * 1024,
                segmentDuration: 5 * 60,
                segmentOverlap: 15
            )
        case .fast:
            return DiarizationSegmentationPlanner.Policy(
                maxDirectDuration: 20 * 60,
                maxDirectMemoryBytes: 160 * 1024 * 1024,
                segmentDuration: 6 * 60,
                segmentOverlap: 20
            )
        case .standard:
            return .default
        case .fine:
            return DiarizationSegmentationPlanner.Policy(
                maxDirectDuration: 30 * 60,
                maxDirectMemoryBytes: 256 * 1024 * 1024,
                segmentDuration: 15 * 60,
                segmentOverlap: 45
            )
        case .finest:
            return DiarizationSegmentationPlanner.Policy(
                maxDirectDuration: 30 * 60,
                maxDirectMemoryBytes: 256 * 1024 * 1024,
                segmentDuration: 20 * 60,
                segmentOverlap: 60
            )
        }
    }

    /// 分段模型滑窗步长（占窗口比例）：越小重叠越多、说话人边界越细，CPU 越高。
    /// 0.10 为 sherpa 默认（90% 重叠），0.25 为历史值。
    var windowShiftRatio: Float {
        switch self {
        case .fastest: return 0.40
        case .fast: return 0.325
        case .standard: return 0.25
        case .fine: return 0.175
        case .finest: return 0.10
        }
    }

    /// 档位显示名（设置页用）
    var localizedName: String {
        switch self {
        case .fastest: return String(localized: "最快")
        case .fast: return String(localized: "较快")
        case .standard: return String(localized: "标准")
        case .fine: return String(localized: "精细")
        case .finest: return String(localized: "最精细")
        }
    }
}

/// 说话人分离结果片段
struct DiarizationSegment: Sendable {
    let start: TimeInterval
    let end: TimeInterval
    /// 说话人编号（0 起）
    let speaker: Int
}

/// 说话人分析结果：只携带可跨并发域传递的值。
///
/// 音频采样、质心嵌入等大体积中间量（`diarizeWithSamples` 返回的 `[Float]`）
/// 始终留在服务内部，算完即释放，不返回给调用方，避免调用方持有整段采样。
struct SpeakerAnalysis: Sendable {
    /// 精修后、按时间排序的说话人片段
    let segments: [DiarizationSegment]
    /// 声纹命中的标签映射（“说话人 N” → 注册姓名）；未开启或不命中时为空
    let recognizedNames: [String: String]

    /// 空结果：未开启说话人分离、模型未就绪或分析失败时的降级值
    static let empty = SpeakerAnalysis(segments: [], recognizedNames: [:])
}

/// 说话人分离服务（pyannote segmentation 3.0 的 ONNX 导出 + 3D-Speaker 声纹嵌入，CPU 推理）
///
/// 使用 sherpa-onnx 的离线说话人日志管线：
/// 分段模型自动检测语音活动与说话人切换点，声纹嵌入模型提取每段声纹后聚类，
/// 按时间轴输出 SPEAKER_0 / SPEAKER_1 / ...。说话人数量不固定时由聚类自动估计。
/// 类自身无共享可变状态，推理/下载由内部串行门保护，可跨并发域安全调用。
final class SpeakerDiarizationService: @unchecked Sendable {

    static let shared = SpeakerDiarizationService()

    /// 模型文件名（存放在模型文件夹根目录）
    static let segmentationFileName = "segmentation.onnx"
    static let embeddingFileName = "embedding.onnx"

    /// 模型下载地址（GitHub Releases，免 HuggingFace token）
    /// 分段模型是 tar.bz2 包（内含 model.onnx），嵌入模型是单个 onnx 文件
    private static let segmentationDownloadURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2")!
    private static let embeddingDownloadURL = URL(string:
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx")!

    /// 下载串行门：避免设置页与转写流程并发触发重复下载
    private static let downloadGate = CancellableGate()
    /// 推理串行门：CPU 推理开销大，批量转写时串行执行避免多路并发拖垮机器；
    /// 用可取消门（`RacingWatchdog.swift`）——旧版本地实现排队不响应取消，
    /// 持锁者挂起时后续分离/声纹会一起永久悬挂
    private static let inferenceGate = CancellableGate()
    /// CPU 推理线程数：专业模式可在设置页调整（`DiarizationThreads`），
    /// 区间强制为 2 ~（逻辑核心数 - 1），默认沿用历史启发式（核心数-2，封顶 6）。
    /// 单条转写已改为「先转写后分离」串行，分离阶段不再与 WhisperKit 争抢 CPU，
    /// 多给线程能更快吃满算力
    private static var inferenceThreads: Int { DiarizationThreads.resolved }

    private init() {}

    // MARK: - 模型状态

    /// 检查模型文件夹是否包含完整模型文件
    nonisolated static func isModelReady(modelPath: String) -> Bool {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: modelPath)
        return fm.fileExists(atPath: folder.appendingPathComponent(segmentationFileName).path)
            && fm.fileExists(atPath: folder.appendingPathComponent(embeddingFileName).path)
    }

    /// 下载说话人分离模型（分段模型约 6MB + 嵌入模型约 27MB）
    /// - Parameter onProgress: 总体进度回调（0.0~1.0）
    nonisolated func downloadModels(
        modelPath: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        try await Self.downloadGate.run {
            let folder = URL(fileURLWithPath: modelPath)
            let fm = FileManager.default
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

            // 两个模型按大小加权分配进度：分段包约 6MB，嵌入模型约 27MB
            let segWeight = 6.0, embWeight = 27.0
            let total = segWeight + embWeight

            // 1. 嵌入模型：单个 onnx 文件，直接下载重命名
            let embeddingDest = folder.appendingPathComponent(Self.embeddingFileName)
            if !fm.fileExists(atPath: embeddingDest.path) {
                _ = try await Self.downloadFile(
                    from: Self.embeddingDownloadURL,
                    to: folder.appendingPathComponent("embedding.download"),
                    moveAfterDownload: embeddingDest
                ) { done in
                    onProgress?(done * (embWeight / total))
                }
            }

            // 2. 分段模型：tar.bz2 包，下载后解压提取 model.onnx
            let segDest = folder.appendingPathComponent(Self.segmentationFileName)
            if !fm.fileExists(atPath: segDest.path) {
                let tempDir = folder.appendingPathComponent(UUID().uuidString)
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: tempDir) }

                let archive = tempDir.appendingPathComponent("segmentation.tar.bz2")
                _ = try await Self.downloadFile(
                    from: Self.segmentationDownloadURL,
                    to: archive,
                    moveAfterDownload: nil
                ) { done in
                    onProgress?((embWeight + done * segWeight) / total)
                }

                try await Self.extractArchive(archive, to: tempDir)
                guard let onnx = Self.firstFile(
                    named: "model.onnx", in: tempDir, allowSubdirectory: true
                ) else {
                    throw DiarizationError.downloadFailed("分段模型包中未找到 model.onnx")
                }
                try? fm.removeItem(at: segDest)
                try fm.moveItem(at: onnx, to: segDest)
            }

            onProgress?(1.0)
        }
    }

    /// 首次使用时按需准备分离模型：已就绪则零开销返回，缺失则自动下载。
    ///
    /// 供转写流程在真正需要分离之前调用。**调用方必须把失败降级为「本次不做说话人分离」**，
    /// 不能让模型准备失败阻断转写本身；下载失败的错误原样抛出，由调用方决定如何提示。
    /// - Returns: 模型是否可用
    @discardableResult
    nonisolated func ensureModelsReady(
        modelPath: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Bool {
        if Self.isModelReady(modelPath: modelPath) { return true }
        try await downloadModels(modelPath: modelPath, onProgress: onProgress)
        return Self.isModelReady(modelPath: modelPath)
    }

    /// 带进度下载文件（进度 0.0~1.0），完成后可选移动到目标路径
    ///
    /// 流式落盘：旧实现用 `for try await byte in bytes` 把整包读进内存 `Data`，
    /// 并**逐字节**调一次 `onProgress`——遢入模型约 27MB 即 2700 万次
    /// `Data.append`（含指数扩容拷贝）+ 2700 万个调用方发出的 `Task { @MainActor }`，
    /// 主队列被进度刷新淹没，下载期间 UI 完全不可用。现改为 URLSession 直接写临时文件，
    /// 进度按网络分块上报（每块一次），内存峰值与文件体积无关。
    private nonisolated static func downloadFile(
        from url: URL,
        to destination: URL,
        moveAfterDownload finalURL: URL?,
        onProgress: @escaping (@Sendable (Double) -> Void)
    ) async throws -> Int {
        // 断点续传：与 Whisper 模型下载统一为「取消保留、重下续传」。
        // 取消时把 URLSession 的 resumeData 落盘，下次从断点继续。
        let resumeURL = destination.appendingPathExtension("resume")
        let delegate = StreamingDownloadDelegate(
            destination: destination,
            finalURL: finalURL,
            resumeURL: resumeURL,
            onProgress: onProgress
        )
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let task: URLSessionDownloadTask
        if let resumeData = try? Data(contentsOf: resumeURL) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
        }
        delegate.attach(task)
        do {
            let written = try await delegate.waitStarted(task)
            session.finishTasksAndInvalidate()
            try? FileManager.default.removeItem(at: resumeURL)
            return written
        } catch {
            session.invalidateAndCancel()
            throw error
        }
    }

    /// 解压 tar.bz2（非沙盒环境直接调用系统 tar）
    private nonisolated static func extractArchive(_ archive: URL, to directory: URL) async throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archive.path, "-C", directory.path]
        let completion = OneShotThrowingBox<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion.attach(continuation)
                process.terminationHandler = { finished in
                    if finished.terminationStatus == 0 {
                        completion.succeed(())
                    } else {
                        completion.fail(DiarizationError.downloadFailed(
                            "分段模型解压失败（tar 退出码 \(finished.terminationStatus)）"
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    completion.fail(error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        // iOS 沙盒内无 Process 与系统 tar，不能自动解压模型包
        throw DiarizationError.downloadFailed("iOS 暂不支持自动下载说话人分离模型，请使用 macOS 端下载")
        */
        #endif
    }

    /// 在目录（含子目录）中查找指定文件名
    private nonisolated static func firstFile(
        named fileName: String,
        in directory: URL,
        allowSubdirectory: Bool
    ) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        for case let url as URL in enumerator {
            if url.lastPathComponent == fileName { return url }
            if !allowSubdirectory { break }
        }
        return nil
    }

    // MARK: - 说话人分离推理

    /// 对音频执行说话人分离（CPU 推理），返回按时间排序的说话人片段
    nonisolated func diarize(
        audioURL: URL,
        modelPath: String
    ) async throws -> [DiarizationSegment] {
        let (segments, _) = try await diarizeWithSamples(audioURL: audioURL, modelPath: modelPath)
        return segments
    }

    /// 执行说话人分离（含簇后处理精修），返回各最终说话人的质心嵌入（供声纹识别复用，
    /// 避免重复提取嵌入）。
    ///
    /// 不再把整段 16kHz Float32 采样随返回值交出：既没有调用方使用它（长会议可达数百 MB），
    /// 误用还会让大数组在调用方生命周期内常驻。采样只在函数内为 `process`/`refineClusters`
    /// 服务，函数返回即释放。
    /// - Parameter onStage: 分段模式下的阶段回调（文案 + 建议进度）；
    ///   阈值以内的整段处理不回调，保持既有行为不变
    nonisolated func diarizeWithSamples(
        audioURL: URL,
        modelPath: String,
        onStage: (@Sendable (String, Float) -> Void)? = nil
    ) async throws -> (segments: [DiarizationSegment], centroids: [Int: [Float]]) {
        try await Self.inferenceGate.run {
            try Task.checkCancellation()

            guard Self.isModelReady(modelPath: modelPath) else {
                throw DiarizationError.modelFilesMissing(modelPath)
            }

            // 读时长 → 估算内存 → 判定是否需分段。阈值以内走原整段路径，
            // 行为与结果完全不变；仅在超过时长/内存阈值时才进入分段模式。
            //
            // 精细度档位在本次推理开始时解析**一次**并向下传递，避免同一次分离里
            // 「模式判定」与「实际切分」读到两个不同的档位。
            let precision = DiarizationPrecision.resolved
            let policy = precision.policy
            let duration = try Self.audioDuration(at: audioURL)
            let mode = DiarizationSegmentationPlanner.mode(
                duration: duration,
                sampleRate: Self.embeddingSampleRate,
                policy: policy
            )
            switch mode {
            case .direct:
                return try Self.diarizeWhole(
                    audioURL: audioURL,
                    modelPath: modelPath,
                    windowShiftRatio: precision.windowShiftRatio
                )
            case .segmented:
                FileSyncService.logWarning(String(
                    format: "说话人分离：音频 %.1f 分钟超过阈值，改用分段处理（每段 %.0f 分钟，重叠 %.0f 秒，精细度 %d/%d）",
                    duration / 60, policy.segmentDuration / 60, policy.segmentOverlap,
                    precision.rawValue, DiarizationPrecision.finest.rawValue
                ))
                return try Self.diarizeSegmented(
                    audioURL: audioURL,
                    modelPath: modelPath,
                    duration: duration,
                    policy: policy,
                    windowShiftRatio: precision.windowShiftRatio,
                    onStage: onStage
                )
            }
        }
    }

    /// 跨段说话人身份合并的余弦相似度阈值（低于簇内合并阈值，容忍分段边界处的嵌入噪声）。
    /// 刻意**不随精细度档位变化**：它由校准器标定，脱离校准调低会把「同人跨段」变成
    /// 「两人合并」、调高会把同人拆成两个全局说话人，两个方向都会比现状更差。
    private static let chunkIdentityMergeThreshold: Float = 0.55

    /// 构建离线说话人日志管线：numClusters -1 = 聚类自动估计说话人数量，provider 默认 CPU。
    /// 直接返回包装器（配置结构体的 Swift 类型名未对上层暴露，配置以局部变量传入即可）
    /// - Parameter windowShiftRatio: 分段模型滑窗步长占窗口比例，来自当前精细度档位
    ///   （窗口秒数由模型元数据决定，pyannote segmentation-3.0 为 5s；步长 = ratio × 窗口）
    private nonisolated static func makeDiarization(
        modelPath: String,
        windowShiftRatio: Float
    ) -> SherpaOnnxOfflineSpeakerDiarizationWrapper {
        let folder = URL(fileURLWithPath: modelPath)
        var config = sherpaOnnxOfflineSpeakerDiarizationConfig(
            segmentation: sherpaOnnxOfflineSpeakerSegmentationModelConfig(
                pyannote: sherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig(
                    model: folder.appendingPathComponent(Self.segmentationFileName).path,
                    windowShiftRatio: windowShiftRatio
                ),
                numThreads: Self.inferenceThreads
            ),
            embedding: sherpaOnnxSpeakerEmbeddingExtractorConfig(
                model: folder.appendingPathComponent(Self.embeddingFileName).path,
                numThreads: Self.inferenceThreads
            ),
            clustering: sherpaOnnxFastClusteringConfig(numClusters: -1)
        )
        return SherpaOnnxOfflineSpeakerDiarizationWrapper(config: &config)
    }

    /// 读取音频时长（秒）。用于分段前的内存估算与阈值判定。
    private nonisolated static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else {
            throw DiarizationError.audioLoadFailed("音频采样率无效")
        }
        return Double(max(Int64(0), file.length)) / sampleRate
    }

    /// 整段处理路径（阈值以内）：除分段窗口步长来自精细度档位外，与历史实现逐行一致
    private nonisolated static func diarizeWhole(
        audioURL: URL,
        modelPath: String,
        windowShiftRatio: Float
    ) throws -> (segments: [DiarizationSegment], centroids: [Int: [Float]]) {
        let diarization = Self.makeDiarization(
            modelPath: modelPath, windowShiftRatio: windowShiftRatio
        )

        let samples = try Self.loadMonoSamples(audioURL: audioURL, sampleRate: diarization.sampleRate)
        try Task.checkCancellation()

        let result = diarization.process(samples: samples)
        // sherpa-onnx 的单次 native process 无法中途协作取消；返回后立即截断后处理，
        // 避免用户已经取消却继续做第二遍嵌入提取与聚类精修。
        try Task.checkCancellation()
        let segments = result.map { DiarizationSegment(
            start: TimeInterval($0.start),
            end: TimeInterval($0.end),
            speaker: Int($0.speaker)
        ) }

        // 簇后处理：修复快速聚类的过度分裂（同人拆簇合并 + 碎片簇吸收）；
        // 失败时回退原始聚类结果，不影响主流程
        let refined: [DiarizationSegment]
        let centroids: [Int: [Float]]
        do {
            (refined, centroids) = try Self.refineClusters(
                segments: segments, samples: samples, modelPath: modelPath
            )
        } catch {
            FileSyncService.logWarning("分离簇后处理失败，使用原始聚类结果: \(error.localizedDescription)")
            refined = segments
            centroids = [:]
        }
        return (refined, centroids)
    }

    /// 分段处理路径：按约 5–10 分钟切分（相邻段少量重叠），每段单独推理并在段末释放样本缓冲，
    /// 用段质心做跨段说话人身份合并，最后对重叠区时间戳/标签去重。
    ///
    /// 取消语义：在「读取每段音频」「每段重采样」「每段推理返回后」之间检查取消。
    /// 单段内的 `process` 是单次 native 调用、**无法即时中断**——UI 只能展示当前段进度与
    /// 「取消将在当前段结束后生效」，不能宣称点取消立刻停。
    private nonisolated static func diarizeSegmented(
        audioURL: URL,
        modelPath: String,
        duration: TimeInterval,
        policy: DiarizationSegmentationPlanner.Policy,
        windowShiftRatio: Float,
        onStage: (@Sendable (String, Float) -> Void)?
    ) throws -> (segments: [DiarizationSegment], centroids: [Int: [Float]]) {
        let ranges = DiarizationSegmentationPlanner.segmentRanges(
            totalDuration: duration,
            segmentDuration: policy.segmentDuration,
            overlap: policy.segmentOverlap
        )
        guard !ranges.isEmpty else { return ([], [:]) }

        let diarization = Self.makeDiarization(
            modelPath: modelPath, windowShiftRatio: windowShiftRatio
        )
        // 嵌入提取器只建一次：跨段身份合并与逐段簇精修复用同一实例，避免每段重复加载模型
        let extractor = try Self.makeEmbeddingExtractor(modelPath: modelPath)

        var chunkCentroids: [[Int: [Float]]] = []
        var chunkSegments: [[DiarizationSegment]] = []
        chunkCentroids.reserveCapacity(ranges.count)
        chunkSegments.reserveCapacity(ranges.count)

        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            onStage?(
                String(format: String(localized: "正在区分说话人（第 %d/%d 段，共 %d 段）…"),
                       index + 1, ranges.count, ranges.count),
                Float(index) / Float(ranges.count)
            )
            // 只读取本段区间的源码流并重采样；段末作用域结束即释放缓冲，不保留整段采样
            let samples = try Self.loadMonoSamples(
                audioURL: audioURL,
                sampleRate: diarization.sampleRate,
                from: range.lowerBound,
                to: range.upperBound
            )
            try Task.checkCancellation()
            let (segments, centroids) = try Self.diarizeChunk(
                samples: samples, diarization: diarization, extractor: extractor
            )
            chunkSegments.append(segments)
            chunkCentroids.append(centroids)
        }
        // 全部段处理完：整段采样从未同时驻留，峰值 ≈ 单段采样量

        var mappings = DiarizationSegmentationPlanner.globalSpeakerMapping(
            chunkCentroids: chunkCentroids,
            matchThreshold: Self.chunkIdentityMergeThreshold
        )
        // 补齐：某段中缺少质心的局部说话人（全部片段过短、嵌入为空）未进入映射，
        // 单独分配全局编号，避免回退到局部编号与其它段碰撞而被错误合并
        var nextGlobal = (mappings.flatMap { $0.values }.max() ?? -1) + 1
        for chunkIndex in chunkSegments.indices {
            var mapping = mappings[chunkIndex]
            for speaker in Set(chunkSegments[chunkIndex].map(\.speaker)) where mapping[speaker] == nil {
                mapping[speaker] = nextGlobal
                nextGlobal += 1
            }
            mappings[chunkIndex] = mapping
        }

        var assembled: [DiarizationSegment] = []
        for (chunkIndex, range) in ranges.enumerated() {
            let offset = range.lowerBound
            let mapping = mappings[chunkIndex]
            for segment in chunkSegments[chunkIndex] {
                let global = mapping[segment.speaker] ?? segment.speaker
                assembled.append(DiarizationSegment(
                    start: segment.start + offset,
                    end: segment.end + offset,
                    speaker: global
                ))
            }
        }
        guard !assembled.isEmpty else { return ([], [:]) }

        let deduped = DiarizationSegmentationPlanner.mergeOverlapping(assembled)
        let (renumbered, _) = DiarizationSegmentationPlanner.renumberByTotalDuration(deduped)

        // 全局质心：在整段录音上按「每个全局说话人取时长最长的 maxSegmentsPerSpeaker 段、
        // 按时长加权」重新提取一次，与整段路径 `refineClusters` 的构造**完全同源**。
        //
        // 旧实现对逐段局部质心做等权算术平均（`averageL2`），有两个缺陷：
        // 1) 权重错配——某段只讲 20 秒的噪声质心与讲 5 分钟的稳定质心同权，
        //    且合并结果与段顺序相关；
        // 2) 平均的是「已归一化质心」，信息被反复稀释，长会议下同人质心被拉偏，
        //    表现为大段发言被标成「说话人 N」（实测 143 分钟录音有 29 分钟发言未命中）。
        //
        // 逐区间读取，峰值内存 = 单个片段采样，不回退到「整段常驻」。
        var globalCentroids: [Int: [Float]] = [:]
        for (speaker, chosen) in Self.embeddingSegmentsBySpeaker(renumbered) {
            try Task.checkCancellation()
            let (centroid, count) = Self.weightedCentroid(
                audioURL: audioURL,
                ranges: chosen.map { (start: $0.start, end: $0.end) },
                extractor: extractor
            )
            guard count > 0, !centroid.isEmpty else {
                FileSyncService.logWarning(
                    "说话人分离：全局说话人 \(speaker + 1) 未能提取到质心，本次不参与声纹识别")
                continue
            }
            globalCentroids[speaker] = centroid
        }

        FileSyncService.logWarning(
            "说话人分离：分段处理完成，\(ranges.count) 段 → \(Set(renumbered.map(\.speaker)).count) 个说话人"
        )
        return (renumbered, globalCentroids)
    }

    /// 单段推理 + 段内簇精修。取消在推理返回后立刻向上传播（不再继续无意义的后处理）
    private nonisolated static func diarizeChunk(
        samples: [Float],
        diarization: SherpaOnnxOfflineSpeakerDiarizationWrapper,
        extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper
    ) throws -> (segments: [DiarizationSegment], centroids: [Int: [Float]]) {
        let result = diarization.process(samples: samples)
        try Task.checkCancellation()
        let segments = result.map { DiarizationSegment(
            start: TimeInterval($0.start),
            end: TimeInterval($0.end),
            speaker: Int($0.speaker)
        ) }
        guard !segments.isEmpty else { return ([], [:]) }
        do {
            return try Self.refineClusters(segments: segments, samples: samples, extractor: extractor)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            FileSyncService.logWarning("分段分离簇后处理失败，使用原始聚类结果: \(error.localizedDescription)")
            return (segments, [:])
        }
    }

    /// 只执行说话人分析：分段聚类 → 簇精修 → 可选声纹识别。
    ///
    /// **不依赖任何转写结果**，可独立执行；当前单条转写的编排是「先转写后分离」串行
    /// （见 `RecordingViewModel.startTranscription`），避免 CoreML 转写与 ONNX CPU 推理
    /// 同时跑互相争抢资源。音频文件是两者共享的只读输入。
    /// - Parameter enableVoiceprintRecognition: 完成后是否与声纹库比对，
    ///   命中的说话人映射为注册姓名（未命中保留“说话人 N”）
    /// - Parameter onStage: 阶段回调（阶段文案 + 建议进度值），供 UI 展示当前所处环节
    nonisolated func analyzeSpeakers(
        audioURL: URL,
        modelPath: String,
        enableVoiceprintRecognition: Bool = false,
        onStage: (@Sendable (String, Float) -> Void)? = nil
    ) async throws -> SpeakerAnalysis {
        onStage?(String(localized: "正在区分说话人…"), 0.8)
        // 分离与后续声纹识别共用同一份质心嵌入，避免重复提取
        // （分段模式下 onStage 会被进一步用于逐段进度展示）
        let (diarization, centroids) = try await diarizeWithSamples(
            audioURL: audioURL, modelPath: modelPath, onStage: onStage
        )
        guard !diarization.isEmpty else {
            // 0 片段同样会表现为“转写正常但没有任何说话人”，不留日志就只能靠猜
            FileSyncService.logWarning("说话人分离未产出任何片段，本次不标注说话人：\(audioURL.lastPathComponent)")
            return .empty
        }
        var names: [String: String] = [:]
        // 声纹属敏感个人信息：即使旧配置或队列快照仍写着 true，
        // 单独同意被撤回后也不得再比对声纹库。
        if enableVoiceprintRecognition, MemoziaPrivacyPolicy.voiceprintConsentGranted() {
            onStage?(String(localized: "正在比对声纹…"), 0.85)
            names = identifySpeakersFromCentroids(centroids)
        }
        return SpeakerAnalysis(segments: diarization, recognizedNames: names)
    }

    /// 把说话人分析结果按时间重叠最大原则贴到已完成的转写片段上（纯计算，无 IO）。
    ///
    /// 与 `analyzeSpeakers` 配对使用：分析可提前并行完成，此处只做最后汇合。
    nonisolated func applySpeakerAnalysis(
        _ analysis: SpeakerAnalysis,
        to results: [TranscriptionResult]
    ) -> [TranscriptionResult] {
        guard !results.isEmpty, !analysis.segments.isEmpty else { return results }
        var output = results
        for index in output.indices {
            let label = Self.dominantSpeaker(
                of: (output[index].startTime, output[index].endTime),
                in: analysis.segments
            )
            output[index].speaker = label
        }
        // 声纹识别：用精修后的说话人质心与声纹库比对（无需重复提取嵌入），
        // 命中的“说话人 N”替换为注册姓名（失败仅保留原标签）
        if !analysis.recognizedNames.isEmpty {
            for index in output.indices {
                if let label = output[index].speaker, let name = analysis.recognizedNames[label] {
                    output[index].speaker = name
                }
            }
        }
        return output
    }

    /// 为转写片段标注说话人（按时间重叠最大原则）。
    ///
    /// 语义等价于「先 `analyzeSpeakers` 再 `applySpeakerAnalysis`」，保留给无需拆分并行的
    /// 调用方（批量转写等）。失败时仅记录日志并原样返回，不阻塞转写主流程。
    /// - Parameter enableVoiceprintRecognition: 分离完成后是否与声纹库比对，
    ///   命中的说话人直接标注为注册姓名（未命中保留“说话人 N”）
    /// - Parameter onStage: 阶段回调（阶段文案 + 建议进度值），供 UI 展示当前所处环节
    nonisolated func applySpeakers(
        to results: [TranscriptionResult],
        audioURL: URL,
        modelPath: String,
        enableVoiceprintRecognition: Bool = false,
        onStage: (@Sendable (String, Float) -> Void)? = nil
    ) async -> [TranscriptionResult] {
        guard !results.isEmpty else { return results }
        do {
            let analysis = try await analyzeSpeakers(
                audioURL: audioURL,
                modelPath: modelPath,
                enableVoiceprintRecognition: enableVoiceprintRecognition,
                onStage: onStage
            )
            return applySpeakerAnalysis(analysis, to: results)
        } catch is CancellationError {
            return results
        } catch {
            FileSyncService.logWarning("说话人分离失败（已跳过，不影响转写）: \(error.localizedDescription)")
            return results
        }
    }

    // MARK: - 声纹识别与提取

    /// 声纹提取采样率（嵌入模型为 16kHz）
    private static let embeddingSampleRate = 16000
    /// 参与声纹聚合的最短片段时长（过短片段嵌入不可靠）
    private static let minSegmentDuration: TimeInterval = 1.5
    /// 每个说话人最多采样的片段数（精修二遍提取与注册路径共用同一上限，控制 CPU 开销）
    private static let maxSegmentsPerSpeaker = 30

    /// 精修嵌入的选段（纯函数，便于单测钉住截断行为）：
    /// 过滤 ≥ minSegmentDuration 后按说话人分组，每组取**时长最长的 maxSegmentsPerSpeaker 段**
    /// （长片段信息量更高，截断后质心质量与全量提取等价）；
    /// 确定性输出：说话人升序、组内时长降序
    static func embeddingSegmentsBySpeaker(
        _ segments: [DiarizationSegment]
    ) -> [(speaker: Int, segments: [DiarizationSegment])] {
        let valid = segments.filter { $0.end - $0.start >= minSegmentDuration }
        let grouped = Dictionary(grouping: valid, by: \.speaker)
        var result: [(speaker: Int, segments: [DiarizationSegment])] = []
        result.reserveCapacity(grouped.count)
        for speaker in grouped.keys.sorted() {
            let chosen = (grouped[speaker] ?? [])
                .sorted { ($0.end - $0.start) > ($1.end - $1.start) }
                .prefix(maxSegmentsPerSpeaker)
            result.append((speaker: speaker, segments: Array(chosen)))
        }
        return result
    }

    /// 注册侧选段：与识别侧 `embeddingSegmentsBySpeaker` **同源**——同样过滤
    /// ≥ minSegmentDuration、同样取时长最长的 maxSegmentsPerSpeaker 段。
    ///
    /// 旧实现取「时间最早的 30 段」且等权平均，与识别侧的「最长 30 段 + 时长加权」错位：
    /// 注册向量与后续比对质心分别落在两个不同的构造上，长会议下偏差被放大，命中率下降。
    /// 这里刻意复用同一函数，使两侧的选段规则不可能再各自演化。
    /// 纯函数，便于单测钉住一致性。
    static func voiceprintRanges(
        _ ranges: [(start: TimeInterval, end: TimeInterval)]
    ) -> [(start: TimeInterval, end: TimeInterval)] {
        embeddingSegmentsBySpeaker(
            ranges.map { DiarizationSegment(start: $0.start, end: $0.end, speaker: 0) }
        ).first?.segments.map { (start: $0.start, end: $0.end) } ?? []
    }

    // MARK: - 簇后处理（修复快速聚类的过度分裂）

    /// 同人拆簇合并阈值：簇间相似度超过该值即迭代合并。
    /// 基于双人录音（20260818090240）实测校准：同人被拆开的两簇相似度 0.903，
    /// 不同人簇间相似度 ≤ 0.68，取 0.60 位于两者中间安全区间
    private static let clusterMergeThreshold: Float = 0.60
    /// 小簇间合并的放宽阈值（小簇嵌入噪声大，需低于主阈值才能聚拢同一人的碎片）。
    /// 校准实测：取 0.50 时目标双人录音得到 2 人（相似度 0.487 的两个碎片簇不独立成簇，
    /// 而是被高相似大簇吸收）；取 0.45 会多出第三个噪声说话人
    private static let smallClusterMergeThreshold: Float = 0.50
    /// 碎片簇时长下限（秒）：低于 max(该值, 总时长×占比) 的簇视为碎片簇
    private static let tinyClusterMinDuration: TimeInterval = 3.0
    /// 碎片簇占总时长比例上限
    private static let tinyClusterRatio: Double = 0.05

    /// 簇后处理：
    /// 1. 高相似同人拆簇迭代合并（≥ clusterMergeThreshold）；
    /// 2. 碎片簇之间以放宽阈值聚拢（≥ smallClusterMergeThreshold），把同一人的碎片聚成簇；
    /// 3. 仍低于碎片下限的簇并入最相似的其他簇；
    /// 4. 最终说话人按时长降序重编号（说话人 1 = 说得最多）。
    /// 返回精修后的片段与各说话人的时长加权质心嵌入（供声纹识别复用）。
    private nonisolated static func refineClusters(
        segments: [DiarizationSegment],
        samples: [Float],
        modelPath: String
    ) throws -> (segments: [DiarizationSegment], centroids: [Int: [Float]]) {
        let extractor = try makeEmbeddingExtractor(modelPath: modelPath)
        return try refineClusters(segments: segments, samples: samples, extractor: extractor)
    }

    /// 复用已建好的嵌入提取器的簇后处理变体：分段模式逐段调用时避免重复加载嵌入模型
    private nonisolated static func refineClusters(
        segments: [DiarizationSegment],
        samples: [Float],
        extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper
    ) throws -> (segments: [DiarizationSegment], centroids: [Int: [Float]]) {
        guard !segments.isEmpty else { return (segments, [:]) }

        // 逐说话人：时长统计（全片段，供簇重编号）+ 嵌入提取（每说话人取时长最长的
        // maxSegmentsPerSpeaker 段；此前对全部有效段二遍全量重提，是本阶段持续 CPU 满载的主要来源）
        var vectorsBySpeaker: [Int: [(embedding: [Float], weight: Double)]] = [:]
        var durationBySpeaker: [Int: TimeInterval] = [:]
        for seg in segments {
            try Task.checkCancellation()
            durationBySpeaker[seg.speaker, default: 0] += seg.end - seg.start
        }
        for (speaker, chosen) in Self.embeddingSegmentsBySpeaker(segments) {
            for seg in chosen {
                try Task.checkCancellation()
                let slice = sliceSamples(samples, from: seg.start, to: seg.end)
                guard !slice.isEmpty else { continue }
                let embedding = computeEmbedding(of: slice, extractor: extractor)
                guard !embedding.isEmpty else { continue }
                vectorsBySpeaker[speaker, default: []]
                    .append((VoiceprintStore.l2Normalize(embedding), seg.end - seg.start))
            }
        }

        struct Cluster {
            var speakers: [Int]
            var vectors: [(embedding: [Float], weight: Double)]
            var duration: TimeInterval
        }
        func centroid(of cluster: Cluster) -> [Float] {
            var sum: [Float] = []
            var totalWeight = 0.0
            for item in cluster.vectors {
                if sum.isEmpty {
                    sum = item.embedding.map { $0 * Float(item.weight) }
                } else {
                    for i in sum.indices { sum[i] += item.embedding[i] * Float(item.weight) }
                }
                totalWeight += item.weight
            }
            guard totalWeight > 0 else { return [] }
            return VoiceprintStore.l2Normalize(sum.map { $0 / Float(totalWeight) })
        }

        var clusters: [Cluster] = vectorsBySpeaker.keys.sorted().map {
            Cluster(speakers: [$0], vectors: vectorsBySpeaker[$0]!, duration: durationBySpeaker[$0] ?? 0)
        }
        // 无有效嵌入的说话人：独立成簇，不参与相似度合并，仅参与时长统计与吸收
        for speaker in Set(durationBySpeaker.keys).subtracting(vectorsBySpeaker.keys).sorted() {
            clusters.append(Cluster(speakers: [speaker], vectors: [], duration: durationBySpeaker[speaker] ?? 0))
        }
        guard clusters.count > 1 else {
            let c = centroid(of: clusters[0])
            return (segments, c.isEmpty ? [:] : [0: c])
        }

        /// 迭代合并相似度 ≥ threshold 的最相似簇对；
        /// scope 每轮动态重算（合并会导致索引偏移，不能固定捕获）
        func agglomerate(threshold: Float, scope: (Int) -> Bool) {
            while true {
                let indices = clusters.indices.filter(scope)
                guard indices.count > 1 else { return }
                var centroids: [Int: [Float]] = [:]
                for idx in indices { centroids[idx] = centroid(of: clusters[idx]) }
                var bestPair: (Int, Int)?
                var bestScore = threshold
                for i in indices where !(centroids[i] ?? []).isEmpty {
                    for j in indices where j > i && !(centroids[j] ?? []).isEmpty {
                        let score = VoiceprintStore.cosineSimilarity(centroids[i]!, centroids[j]!)
                        if score > bestScore {
                            bestScore = score
                            bestPair = (i, j)
                        }
                    }
                }
                guard let (i, j) = bestPair else { return }
                FileSyncService.logWarning(String(
                    format: "说话人分离：合并过度分裂的簇（相似度 %.3f，合并后时长 %.1fs）",
                    bestScore, clusters[i].duration + clusters[j].duration))
                clusters[i].speakers.append(contentsOf: clusters[j].speakers)
                clusters[i].vectors.append(contentsOf: clusters[j].vectors)
                clusters[i].duration += clusters[j].duration
                clusters.remove(at: j)
            }
        }

        // 阶段 1：全局高相似合并（修复同人拆簇）
        agglomerate(threshold: clusterMergeThreshold, scope: { _ in true })

        // 阶段 2/3：碎片簇处理
        let totalDuration = segments.reduce(TimeInterval(0)) { $0 + ($1.end - $1.start) }
        let tinyLimit = max(tinyClusterMinDuration, totalDuration * tinyClusterRatio)
        // 阶段 2：碎片簇之间以放宽阈值聚拢（作用域每轮重算）
        agglomerate(threshold: smallClusterMergeThreshold, scope: { clusters[$0].duration < tinyLimit })
        // 阶段 3：仍为碎片的簇并入最相似的其他簇（无相似度下限，避免残留噪声说话人）
        var speakerCluster: [Int: Int] = [:]
        for (idx, cluster) in clusters.enumerated() {
            for s in cluster.speakers { speakerCluster[s] = idx }
        }
        let bigIndices = clusters.indices.filter { clusters[$0].duration >= tinyLimit }
        if !bigIndices.isEmpty {
            let centroids = clusters.map { centroid(of: $0) }
            let fallback = bigIndices.max(by: { clusters[$0].duration < clusters[$1].duration })!
            for idx in clusters.indices where clusters[idx].duration < tinyLimit {
                var target = fallback
                var bestScore: Float = -1
                if !centroids[idx].isEmpty {
                    for b in bigIndices where !centroids[b].isEmpty {
                        let score = VoiceprintStore.cosineSimilarity(centroids[idx], centroids[b])
                        if score > bestScore {
                            bestScore = score
                            target = b
                        }
                    }
                }
                FileSyncService.logWarning(String(
                    format: "说话人分离：碎片簇（%.1fs）并入最近簇（相似度 %.3f）",
                    clusters[idx].duration, bestScore))
                for s in clusters[idx].speakers { speakerCluster[s] = target }
            }
        } else {
            // 无大簇（极端情况）：全部碎片并入最大簇，避免输出几十个噪声说话人
            let fallback = clusters.indices.max(by: { clusters[$0].duration < clusters[$1].duration })!
            for idx in clusters.indices where idx != fallback {
                for s in clusters[idx].speakers { speakerCluster[s] = fallback }
            }
        }

        // 阶段 4：按最终时长降序重编号（说话人 1 = 说得最多）
        var finalDuration: [Int: TimeInterval] = [:]
        for seg in segments {
            let c = speakerCluster[seg.speaker] ?? seg.speaker
            finalDuration[c, default: 0] += seg.end - seg.start
        }
        let ordered = finalDuration.sorted { $0.value > $1.value }.map(\.key)
        var renumber: [Int: Int] = [:]
        for (newIdx, c) in ordered.enumerated() { renumber[c] = newIdx }

        let refined = segments.map { seg -> DiarizationSegment in
            let c = speakerCluster[seg.speaker] ?? seg.speaker
            return DiarizationSegment(start: seg.start, end: seg.end, speaker: renumber[c] ?? 0)
        }

        var resultCentroids: [Int: [Float]] = [:]
        for (idx, cluster) in clusters.enumerated() {
            guard let newIdx = renumber[idx] else { continue }
            let c = centroid(of: cluster)
            if !c.isEmpty { resultCentroids[newIdx] = c }
        }
        FileSyncService.logWarning("说话人分离：簇后处理完成，\(clusters.count) 簇 → \(ordered.count) 个说话人")
        return (refined, resultCentroids)
    }

    /// 用精修后的说话人质心与声纹库比对，返回“说话人 N” → 注册姓名的映射。
    /// 全局唯一性约束：每个注册声纹最多分配给一个说话人（最大权重匹配），
    /// 防止两个不同说话人被同时标成同一姓名；声纹库为空或无质心时返回空映射。
    nonisolated func identifySpeakersFromCentroids(_ centroids: [Int: [Float]]) -> [String: String] {
        // 只比对当前嵌入模型生成的声纹（模型不同向量空间不兼容）
        let loaded = VoiceprintStore.loadAll()
            .filter { $0.modelId == VoiceprintStore.modelId }
        // 同名多条目必须先合并为单条：同人跨场次注册相似度达不到查重阈值时会并存，
        // 若不合并，同一姓名会同时占据 top1/top2，把领先幅度压到 matchMargin 以下，
        // 使该人**永远无法被识别**（实测「何锋」两条记录相似度 0.570 即此情形）。
        // 全局唯一性本就按姓名去重，重复条目不可能被同时分配，对识别只会有害。
        let voiceprints = VoiceprintStore.collapsingSameName(loaded)
        guard !voiceprints.isEmpty, !centroids.isEmpty else { return [:] }

        // 候选：每个说话人全库打分，保留同时满足阈值与领先幅度的候选（可多个）
        struct Candidate {
            let name: String
            let score: Float
        }
        var candidatesBySpeaker: [(speakerIndex: Int, candidates: [Candidate])] = []
        for (speakerIndex, embedding) in centroids.sorted(by: { $0.key < $1.key }) {
            let label = String(format: String(localized: "说话人 %d"), speakerIndex + 1)
            let scored = voiceprints.map {
                Candidate(
                    name: $0.name,
                    score: VoiceprintStore.cosineSimilarity($0.embedding, embedding)
                )
            }.sorted { $0.score > $1.score }
            guard let top = scored.first, top.score >= VoiceprintStore.matchThreshold else {
                FileSyncService.logWarning("声纹识别未命中（\(label)，最高 \(String(format: "%.3f", scored.first?.score ?? 0))）")
                continue
            }
            let secondScore = scored.dropFirst().first?.score ?? 0
            let margin = top.score - secondScore
            if margin < VoiceprintStore.matchMargin {
                FileSyncService.logWarning(String(
                    format: "声纹识别歧义（%@：%@ %.3f vs %@ %.3f，领先 %.3f < %.2f）",
                    label, top.name, top.score,
                    scored.dropFirst().first?.name ?? "?", secondScore,
                    margin, VoiceprintStore.matchMargin))
                continue
            }
            // 只保留 top 3 候选：回溯分支数受限，避免声纹库极大时组合爆炸
            candidatesBySpeaker.append((speakerIndex, Array(scored.prefix(3))))
        }
        guard !candidatesBySpeaker.isEmpty else { return [:] }

        // 最大权重匹配：每个声纹最多分配给一个说话人，总相似度最大。
        //
        // 分支数受说话人数 S 影响约为 4^S（不分配 + top3 候选）。旧实现直接依赖
        // "说话人数很少"这一未验证假设：`numClusters: -1` 自动估计数不设上限，
        // 过聚类的长会议（15~20 簇）会让回溯跑到 1e9~1e12 次递归，而它全程
        // 持有 inferenceGate → 后续分离/声纹一起挂死，表现为"应用卡住不动"。
        // 现在 S 超过阈值时退化为按分数降序的贪心一对一分配（多项式时间，
        // 结果与最优解在实际分数分布下几乎一致）。
        let exactMatchSpeakerLimit = 8
        if candidatesBySpeaker.count > exactMatchSpeakerLimit {
            FileSyncService.logWarning(
                "声纹匹配说话人数 \(candidatesBySpeaker.count) > \(exactMatchSpeakerLimit)，改用贪心分配以避免指数回溯"
            )
            var mapping: [String: String] = [:]
            var usedNames = Set<String>()
            // 所有 (说话人, 候选) 组合按相似度降序逐对占用
            let allPairs = candidatesBySpeaker.flatMap { item in
                item.candidates.map { (speakerIndex: item.speakerIndex, candidate: $0) }
            }
            .sorted { $0.candidate.score > $1.candidate.score }
            var assignedSpeakers = Set<Int>()
            for pair in allPairs where !assignedSpeakers.contains(pair.speakerIndex)
                && !usedNames.contains(pair.candidate.name) {
                usedNames.insert(pair.candidate.name)
                assignedSpeakers.insert(pair.speakerIndex)
                mapping[String(format: String(localized: "说话人 %d"), pair.speakerIndex + 1)] = pair.candidate.name
            }
            let unassigned = candidatesBySpeaker.count - assignedSpeakers.count
            if unassigned > 0 {
                FileSyncService.logWarning("贪心分配后仍有 \(unassigned) 个说话人保留「说话人 N」标签")
            }
            return mapping
        }

        var bestAssignment: [Int: Candidate] = [:]
        var bestTotal: Float = -1
        var currentAssignment: [Int: Candidate] = [:]
        var usedNames = Set<String>()

        func backtrack(_ idx: Int, total: Float) {
            if idx == candidatesBySpeaker.count {
                if total > bestTotal {
                    bestTotal = total
                    bestAssignment = currentAssignment
                }
                return
            }
            let item = candidatesBySpeaker[idx]
            // 分支 1：该说话人不分配（保留“说话人 N”）
            backtrack(idx + 1, total: total)
            // 分支 2：分配给某个尚未占用的达标声纹
            for candidate in item.candidates where !usedNames.contains(candidate.name)
                && candidate.score >= VoiceprintStore.matchThreshold {
                usedNames.insert(candidate.name)
                currentAssignment[item.speakerIndex] = candidate
                backtrack(idx + 1, total: total + candidate.score)
                currentAssignment[item.speakerIndex] = nil
                usedNames.remove(candidate.name)
            }
        }
        backtrack(0, total: 0)

        var mapping: [String: String] = [:]
        for (speakerIndex, candidate) in bestAssignment {
            let label = String(format: String(localized: "说话人 %d"), speakerIndex + 1)
            mapping[label] = candidate.name
            FileSyncService.logWarning("声纹识别命中：\(label) → \(candidate.name)（\(String(format: "%.3f", candidate.score))）")
        }
        return mapping
    }

    /// 从指定时间区间提取声纹向量（手动标记入口，流程 A）
    /// - Returns: 归一化嵌入与有效片段数；有效片段不足时抛出 insufficientAudio
    nonisolated func extractVoiceprint(
        audioURL: URL,
        modelPath: String,
        ranges: [(start: TimeInterval, end: TimeInterval)]
    ) async throws -> (embedding: [Float], sampleCount: Int) {
        try await Self.inferenceGate.run {
            try Task.checkCancellation()
            // 选段与识别侧同源（过滤 ≥ minSegmentDuration + 取最长 maxSegmentsPerSpeaker 段），
            // 加权方式也与识别侧质心一致（时长加权），保证「注册的向量」与「比对用的质心」
            // 是同一个构造，不再系统性错位。
            let selected = Self.voiceprintRanges(ranges)
            guard !selected.isEmpty else { throw VoiceprintError.insufficientAudio }

            try Task.checkCancellation()
            let extractor = try Self.makeEmbeddingExtractor(modelPath: modelPath)
            // 只读取所选区间：旧实现把整段录音读进内存（2 小时 ≈ 550MB）却只用其中几十段
            let (embedding, count) = Self.weightedCentroid(
                audioURL: audioURL, ranges: selected, extractor: extractor
            )
            guard count > 0, !embedding.isEmpty else { throw VoiceprintError.insufficientAudio }
            return (embedding, count)
        }
    }

    /// 创建声纹嵌入提取器（复用分离管线的 embedding.onnx）
    /// internal：供 DiarizationCalibrator 校准工具复用
    nonisolated static func makeEmbeddingExtractor(
        modelPath: String
    ) throws -> SherpaOnnxSpeakerEmbeddingExtractorWrapper {
        let modelFile = URL(fileURLWithPath: modelPath)
            .appendingPathComponent(embeddingFileName)
        guard FileManager.default.fileExists(atPath: modelFile.path) else {
            throw DiarizationError.modelFilesMissing(modelPath)
        }
        var config = sherpaOnnxSpeakerEmbeddingExtractorConfig(
            model: modelFile.path,
            numThreads: inferenceThreads
        )
        return SherpaOnnxSpeakerEmbeddingExtractorWrapper(config: &config)
    }

    /// 对单段采样计算嵌入向量
    /// internal：供 DiarizationCalibrator 校准工具复用
    nonisolated static func computeEmbedding(
        of samples: [Float],
        extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper
    ) -> [Float] {
        let stream = extractor.createStream()
        stream.acceptWaveform(samples: samples, sampleRate: embeddingSampleRate)
        stream.inputFinished()
        return extractor.compute(stream: stream)
    }

    /// 按时间区间从全量采样中切片
    private nonisolated static func sliceSamples(
        _ samples: [Float],
        from start: TimeInterval,
        to end: TimeInterval
    ) -> [Float] {
        let startIdx = max(0, Int(start * Double(embeddingSampleRate)))
        let endIdx = min(samples.count, Int(end * Double(embeddingSampleRate)))
        guard startIdx < endIdx else { return [] }
        return Array(samples[startIdx..<endIdx])
    }

    /// 按时间区间列表提取嵌入并做**时长加权**平均，返回归一化质心与有效片段数。
    ///
    /// 逐区间读取（`loadMonoSamples` 带 `timeRange`），**峰值内存 = 单个片段采样**：
    /// 不把整段录音读进内存（2 小时 16k 单声道 Float32 ≈ 550MB）。加权方式与
    /// `refineClusters` 内 `centroid(of:)` 一致（权重 = 片段时长），保证注册路径、
    /// 分段路径的全局质心与整段路径的质心**构造同源**。
    ///
    /// 单个区间加载失败只跳过该区间并留日志：一个坏区间不应让整次分离/注册失败
    /// （服务既有约定是逐级回退）。全部区间都不成时返回空，由调用方判定。
    private nonisolated static func weightedCentroid(
        audioURL: URL,
        ranges: [(start: TimeInterval, end: TimeInterval)],
        extractor: SherpaOnnxSpeakerEmbeddingExtractorWrapper
    ) -> (embedding: [Float], sampleCount: Int) {
        var sum: [Float] = []
        var totalWeight = 0.0
        var count = 0
        for range in ranges {
            if Task.isCancelled { break }
            let duration = range.end - range.start
            guard duration >= minSegmentDuration else { continue }
            let samples: [Float]
            do {
                samples = try loadMonoSamples(
                    audioURL: audioURL,
                    sampleRate: embeddingSampleRate,
                    from: range.start,
                    to: range.end
                )
            } catch {
                FileSyncService.logWarning(String(
                    format: "声纹嵌入：跳过无法读取的片段 %.1f–%.1fs（%@）",
                    range.start, range.end, error.localizedDescription
                ))
                continue
            }
            guard !samples.isEmpty else { continue }
            let embedding = computeEmbedding(of: samples, extractor: extractor)
            guard !embedding.isEmpty else { continue }
            let normalized = VoiceprintStore.l2Normalize(embedding)
            // 维度不一致（损坏/换模型）无法相加，跳过而不是污染累积和
            guard sum.isEmpty || sum.count == normalized.count else {
                FileSyncService.logWarning("声纹嵌入：维度不一致（\(sum.count) vs \(normalized.count)），跳过该片段")
                continue
            }
            if sum.isEmpty {
                sum = normalized.map { $0 * Float(duration) }
            } else {
                for i in sum.indices { sum[i] += normalized[i] * Float(duration) }
            }
            totalWeight += duration
            count += 1
        }
        guard totalWeight > 0, !sum.isEmpty else { return ([], 0) }
        return (VoiceprintStore.l2Normalize(sum.map { $0 / Float(totalWeight) }), count)
    }

    /// 找出与转写片段时间重叠最大的说话人标签（如“说话人 1”）
    private nonisolated static func dominantSpeaker(
        of range: (start: TimeInterval, end: TimeInterval),
        in diarization: [DiarizationSegment]
    ) -> String? {
        var bestSpeaker: Int?
        var bestOverlap: TimeInterval = 0
        for segment in diarization {
            let overlap = min(range.end, segment.end) - max(range.start, segment.start)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = segment.speaker
            }
        }
        guard let speaker = bestSpeaker else { return nil }
        return String(format: String(localized: "说话人 %d"), speaker + 1)
    }

    /// 流式读取的源块大小（帧数，≈1 秒 @48kHz）
    private nonisolated static let sourceChunkFrames: AVAudioFrameCount = 48_000

    /// Mac 传统错误码 `eofErr`（end of data）。`AVAudioFile.read(into:)` 在
    /// macOS 27 beta (26A428) 上读到文件末尾会抛这个码，而不是像旧系统那样返回 0 帧。
    private nonisolated static let eofOSStatus = -39

    /// 判定“读到了文件末尾”。只认 `NSOSStatusErrorDomain` 的 `eofErr`：
    /// 解码失败、权限受限、格式不支持等错误必须继续向上抛，
    /// 不能一并当成 EOF 静默降级（那会把“读坏了”伪装成“读完了”）。
    private nonisolated static func isEndOfFileRead(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSOSStatusErrorDomain && nsError.code == eofOSStatus
    }

    /// 读取音频并转换为管线要求的单声道 Float32 采样（默认 16kHz）
    /// internal：供 DiarizationCalibrator 校准工具复用
    ///
    /// 内存设计：旧实现按整段时长一次分配源 `AVAudioPCMBuffer`（`AVAudioFrameCount(file.length)`），
    /// 2 小时 48kHz 立体声 Float32 源缓冲就要 ≈2.7GB，再叠加转换输出与数组拷贝，
    /// 峰值近 4GB，长会议开启说话人分离会被系统直接杀掉且无任何日志。
    /// 现改为逐块读取 + 逐块转换，峰值只剩最终必需的单声道采样本身。
    nonisolated static func loadMonoSamples(
        audioURL: URL,
        sampleRate: Int
    ) throws -> [Float] {
        try loadMonoSamples(audioURL: audioURL, sampleRate: sampleRate, timeRange: nil)
    }

    /// 只读取 [from, to) 秒区间并重采样（分段模式用），避免把整段采样读进内存。
    /// 区间会被夹到 [0, 文件时长]；空区间报错。
    nonisolated static func loadMonoSamples(
        audioURL: URL,
        sampleRate: Int,
        from startSeconds: TimeInterval,
        to endSeconds: TimeInterval
    ) throws -> [Float] {
        try loadMonoSamples(
            audioURL: audioURL,
            sampleRate: sampleRate,
            timeRange: startSeconds..<endSeconds
        )
    }

    private nonisolated static func loadMonoSamples(
        audioURL: URL,
        sampleRate: Int,
        timeRange: Range<TimeInterval>?
    ) throws -> [Float] {
        let file = try AVAudioFile(forReading: audioURL)
        let srcFormat = file.processingFormat
        guard srcFormat.sampleRate > 0 else {
            throw DiarizationError.audioLoadFailed("音频采样率无效")
        }

        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw DiarizationError.audioLoadFailed("无法创建音频转换格式")
        }

        let fileFrames = max(Int64(0), file.length)
        guard fileFrames > 0 else {
            throw DiarizationError.audioLoadFailed("音频内容为空")
        }
        // 读取起点：整段为 0；分段模式按秒换算成源帧并把读取位置前移
        let startFrame: AVAudioFramePosition
        let endFrame: AVAudioFramePosition
        if let timeRange {
            let lower = max(0, min(Double(fileFrames), timeRange.lowerBound * srcFormat.sampleRate))
            let upper = max(lower, min(Double(fileFrames), timeRange.upperBound * srcFormat.sampleRate))
            startFrame = AVAudioFramePosition(lower)
            endFrame = AVAudioFramePosition(upper)
            file.framePosition = startFrame
        } else {
            startFrame = 0
            endFrame = AVAudioFramePosition(fileFrames)
        }
        let totalSourceFrames = AVAudioFrameCount(endFrame - startFrame)
        guard totalSourceFrames > 0 else {
            throw DiarizationError.audioLoadFailed("音频区间为空")
        }

        let ratio = dstFormat.sampleRate / srcFormat.sampleRate
        // 预留最终输出量级：分块 append 不预留会反复二次方扩容
        var output: [Float] = []
        output.reserveCapacity(Int(Double(totalSourceFrames) * ratio) + 8_192)

        let chunkFrames = min(Self.sourceChunkFrames, totalSourceFrames)
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: chunkFrames) else {
            throw DiarizationError.audioLoadFailed("无法创建音频读取缓冲")
        }

        // 源已是目标格式（16k 单声道 Float32）：逐块读取直接拼接，同样不分配整段缓冲
        if srcFormat == dstFormat {
            // 以帧预算驱动循环，不再依赖“EOF 一定返回 0 帧”：
            // macOS 27 beta 上末尾那次 read 直接抛 eofErr，旧写法会把它当解码失败抛出，
            // 导致“整段音频已全部读完”却仍报失败，并被上游 catch 吞成静默无标注
            var framesRead: AVAudioFrameCount = 0
            while framesRead < totalSourceFrames {
                try Task.checkCancellation()
                srcBuffer.frameLength = 0
                do {
                    try file.read(into: srcBuffer)
                } catch {
                    guard framesRead >= totalSourceFrames || Self.isEndOfFileRead(error) else {
                        throw DiarizationError.audioLoadFailed("音频读取失败：\(error.localizedDescription)")
                    }
                    break
                }
                // 旧系统行为：EOF 返回 0 帧
                guard srcBuffer.frameLength > 0 else { break }
                framesRead += srcBuffer.frameLength
                output.append(contentsOf: Self.floatSamples(of: srcBuffer))
            }
            guard !output.isEmpty else {
                throw DiarizationError.audioLoadFailed("音频内容为空")
            }
            return output
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw DiarizationError.audioLoadFailed("无法创建音频转换器")
        }
        // 单块输出容量 = 本块全部输出 + 滤波器余量：足够宽则不会出现
        // “输出填满而输入只被部分消费”的情况（那会丢弃未消费的源帧）
        let outputCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 4_096
        var fedAnyChunk = false
        // 同上：按帧预算读到最后一块就收，避免多读一次 EOF；抛错时只接受 eofErr 作为收尾
        var framesRead: AVAudioFrameCount = 0
        while framesRead < totalSourceFrames {
            try Task.checkCancellation()
            srcBuffer.frameLength = 0
            do {
                try file.read(into: srcBuffer)
            } catch {
                guard framesRead >= totalSourceFrames || Self.isEndOfFileRead(error) else {
                    throw DiarizationError.audioLoadFailed("音频读取失败：\(error.localizedDescription)")
                }
                break
            }
            guard srcBuffer.frameLength > 0 else { break }
            fedAnyChunk = true
            framesRead += srcBuffer.frameLength
            try Self.convertChunk(
                srcBuffer,
                converter: converter,
                to: dstFormat,
                outputCapacity: outputCapacity,
                into: &output
            )
        }
        // 收尾：告知转换器输入已结束，冲掉重采样滤波器尾部样本，不丢时间轴尾帧
        if fedAnyChunk {
            try Self.flushConverter(converter, to: dstFormat, outputCapacity: outputCapacity, into: &output)
        }
        guard !output.isEmpty else {
            throw DiarizationError.audioLoadFailed("音频内容为空")
        }
        return output
    }

    /// 把一块源数据喂给转换器并把结果追加到 output。
    /// 回调在 `convert` 同步执行期间才会被调用，无实际并发；
    /// 用 `nonisolated(unsafe)` 显式声明安全性，消除 Swift 6 严格并发告警
    private nonisolated static func convertChunk(
        _ source: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        to dstFormat: AVAudioFormat,
        outputCapacity: AVAudioFrameCount,
        into output: inout [Float]
    ) throws {
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputCapacity) else {
            throw DiarizationError.audioLoadFailed("无法创建音频输出缓冲")
        }
        nonisolated(unsafe) var delivered = false
        nonisolated(unsafe) let inputBuffer = source
        var outError: NSError?
        let status = converter.convert(
            to: out,
            error: &outError,
            withInputFrom: { _, inputStatus in
                if delivered {
                    // 本块已交入：转换器若仍需输入会以 .inputRanOut 返回，由外层读下一块
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                delivered = true
                inputStatus.pointee = .haveData
                return inputBuffer
            }
        )
        if let outError {
            throw DiarizationError.audioLoadFailed(outError.localizedDescription)
        }
        // .error 状态才视为失败；.haveData/.endOfStream/.inputRanOut 均可使用已转换数据
        if status == .error {
            throw DiarizationError.audioLoadFailed("音频格式转换失败")
        }
        output.append(contentsOf: Self.floatSamples(of: out))
    }

    /// 冲掉转换器内部残留（重采样滤波器尾），保证输出与源音频时长一致
    private nonisolated static func flushConverter(
        _ converter: AVAudioConverter,
        to dstFormat: AVAudioFormat,
        outputCapacity: AVAudioFrameCount,
        into output: inout [Float]
    ) throws {
        guard let out = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputCapacity) else { return }
        var outError: NSError?
        let status = converter.convert(
            to: out,
            error: &outError,
            withInputFrom: { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
        )
        if status == .error, let outError {
            throw DiarizationError.audioLoadFailed(outError.localizedDescription)
        }
        output.append(contentsOf: Self.floatSamples(of: out))
    }

    /// 提取 PCM 缓冲的 Float 数组（单声道）
    private nonisolated static func floatSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

// MARK: - 流式下载代理

/// 模型下载代理：URLSession 把响应直接写至系统临时文件，回调按网络分块触发。
///
/// 只做三件事：分块进度、文件就位、一次性结算续体（`settled` 保证
/// 无论“完成/失败/取消”哪条路径先到，续体只会被 resume 一次）。
/// 对 `task` 用弱引用：session 强持有 delegate、task 强持有 session，
/// 若 delegate 再强持有 task 就形成环，每次下载会漏一组对象。
private final class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let finalURL: URL?
    /// 断点续传数据落盘路径（取消时写入，下载成功后清理）
    private let resumeURL: URL?
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<Int, any Error>?
    private weak var task: URLSessionDownloadTask?
    private var settled = false

    init(
        destination: URL,
        finalURL: URL?,
        resumeURL: URL?,
        onProgress: @escaping @Sendable (Double) -> Void
    ) {
        self.destination = destination
        self.finalURL = finalURL
        self.resumeURL = resumeURL
        self.onProgress = onProgress
    }

    /// 落盘 / 清理续传数据（取消路径调用）
    func persistResumeData(_ data: Data?) {
        guard let resumeURL else { return }
        if let data {
            try? data.write(to: resumeURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: resumeURL)
        }
    }

    func attach(_ task: URLSessionDownloadTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// 挂上续体后才启动请求，保证回调不会早于登记；支持协作取消
    func waitStarted(_ task: URLSessionDownloadTask) async throws -> Int {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int, any Error>) in
                lock.lock()
                guard !settled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            // 协作取消：让 URLSession 产出 resumeData 以便下次续传
            let delegate = self
            task.cancel(byProducingResumeData: { data in
                delegate.persistResumeData(data)
            })
        }
    }

    /// 结算：首次调用恢复等待方，后续调用直接丢弃（绝不二次 resume）
    private func settle(_ outcome: Result<Int, any Error>) {
        lock.lock()
        guard !settled else { lock.unlock(); return }
        settled = true
        let waiting = continuation
        continuation = nil
        lock.unlock()
        guard let waiting else { return }
        switch outcome {
        case .success(let count): waiting.resume(returning: count)
        case .failure(let error): waiting.resume(throwing: error)
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 系统临时文件在本回调返回后即被删除，必须在此搬走
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: location, to: destination)
        } catch {
            settle(.failure(DiarizationError.downloadFailed("下载文件落盘失败：\(error.localizedDescription)")))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            settle(.failure(
                (error as? URLError)?.code == .cancelled
                    ? CancellationError()
                    : DiarizationError.downloadFailed(error.localizedDescription)
            ))
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            settle(.failure(DiarizationError.downloadFailed("模型下载无响应头")))
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            settle(.failure(DiarizationError.downloadFailed("模型下载失败（服务端返回 \(http.statusCode)）")))
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            settle(.failure(DiarizationError.downloadFailed("模型下载结果为空文件")))
            return
        }
        if let finalURL {
            do {
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: destination, to: finalURL)
            } catch {
                settle(.failure(DiarizationError.downloadFailed("模型文件就位失败：\(error.localizedDescription)")))
                return
            }
        }
        settle(.success(Int(size)))
    }
}

// MARK: - 错误定义

enum DiarizationError: LocalizedError {
    case modelFilesMissing(String)
    case downloadFailed(String)
    case audioLoadFailed(String)
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelFilesMissing(let path):
            return String(format: String(localized: "说话人分离模型不完整：%@。请在「设置 → 语音转写」下载模型，或手动将 segmentation.onnx 与 embedding.onnx 放入该文件夹"), path)
        case .downloadFailed(let detail):
            return String(localized: "说话人分离模型下载失败：\(detail)。请检查网络后重试，或参考设置页说明手动下载放入模型文件夹")
        case .audioLoadFailed(let detail):
            return String(localized: "音频读取失败：\(detail)")
        case .inferenceFailed(let detail):
            return String(localized: "说话人分离推理失败：\(detail)")
        }
    }
}

// MARK: - 分段处理规划（纯函数）

/// 长录音分段分离的纯计算：时长/内存估算、阈值判定、切分（含重叠）、重叠区去重、
/// 跨段说话人身份合并、按总时长重编号。
///
/// 全部与音频 IO、native 推理解耦，输入相同即输出相同，可在单测中用合成数据钉住行为，
/// 不依赖真实模型或真机音频。
enum DiarizationSegmentationPlanner {

    /// Float32 单样本字节数
    static let bytesPerSample = MemoryLayout<Float>.size

    /// 分段策略：阈值以内（时长与内存都不超）走整段处理，行为不变；超过才分段
    struct Policy: Sendable, Equatable {
        /// 可直接整段处理的最大时长（秒）
        let maxDirectDuration: TimeInterval
        /// 可直接整段处理的最大采样常驻内存（字节）
        let maxDirectMemoryBytes: Int
        /// 分段模式下每段的目标时长（秒）
        let segmentDuration: TimeInterval
        /// 相邻段的重叠时长（秒）
        let segmentOverlap: TimeInterval

        /// 默认策略：30 分钟 / 256MB 以内整段；超过则按 8 分钟一段、重叠 30 秒
        static let `default` = Policy(
            maxDirectDuration: 30 * 60,
            maxDirectMemoryBytes: 256 * 1024 * 1024,
            segmentDuration: 8 * 60,
            segmentOverlap: 30
        )
    }

    /// 处理模式
    enum Mode: Equatable, Sendable {
        case direct
        case segmented
    }

    /// 估算整段单声道 Float32 采样的常驻字节数（≤0 时返回 0）
    static func estimatedSampleBytes(duration: TimeInterval, sampleRate: Int) -> Int {
        guard duration > 0, sampleRate > 0 else { return 0 }
        return Int((duration * Double(sampleRate)).rounded()) * bytesPerSample
    }

    /// 阈值判定：时长或估算内存任一超过阈值即进入分段模式
    static func mode(
        duration: TimeInterval,
        sampleRate: Int,
        policy: Policy = .default
    ) -> Mode {
        guard duration > 0 else { return .direct }
        if duration > policy.maxDirectDuration { return .segmented }
        if estimatedSampleBytes(duration: duration, sampleRate: sampleRate) > policy.maxDirectMemoryBytes {
            return .segmented
        }
        return .direct
    }

    /// 切分为若干 [start, end) 区间：相邻段重叠 overlap 秒；末段被夹到总时长。
    /// 时长不超过单段时只返回一个完整区间。overlap 被夹到 [0, segmentDuration/2]，
    /// 保证步长恒为正、不出现零长度或反序区间。
    static func segmentRanges(
        totalDuration: TimeInterval,
        segmentDuration: TimeInterval,
        overlap: TimeInterval
    ) -> [Range<Double>] {
        guard totalDuration > 0, segmentDuration > 0 else { return [] }
        let overlap = max(0, min(overlap, segmentDuration / 2))
        let step = segmentDuration - overlap
        var ranges: [Range<Double>] = []
        var start = 0.0
        while start < totalDuration {
            let end = min(start + segmentDuration, totalDuration)
            ranges.append(start..<end)
            if end >= totalDuration { break }
            start += step
        }
        return ranges
    }

    /// 重叠区去重：按时间排序后，
    /// - 后段被前段完全覆盖 → 丢弃；
    /// - 后段与前段部分重叠 → 裁掉重叠部分（**前段标签优先**，保证时间戳不重复）；
    /// - 相邻且说话人相同 → 合并为一段。
    /// 输入通常来自「分段结果偏移到全局时间轴后」的拼接。
    static func mergeOverlapping(_ segments: [DiarizationSegment]) -> [DiarizationSegment] {
        guard segments.count > 1 else { return segments }
        let sorted = segments.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end
        }
        var result: [DiarizationSegment] = []
        result.reserveCapacity(sorted.count)
        for segment in sorted {
            guard let last = result.last else {
                result.append(segment)
                continue
            }
            if segment.start < last.end {
                // 重叠：完全被前段覆盖则丢弃
                if segment.end <= last.end { continue }
                let trimmed = DiarizationSegment(
                    start: last.end, end: segment.end, speaker: segment.speaker
                )
                if trimmed.speaker == last.speaker {
                    result[result.count - 1] = DiarizationSegment(
                        start: last.start, end: trimmed.end, speaker: last.speaker
                    )
                } else {
                    result.append(trimmed)
                }
            } else if segment.start == last.end, segment.speaker == last.speaker {
                result[result.count - 1] = DiarizationSegment(
                    start: last.start, end: segment.end, speaker: last.speaker
                )
            } else {
                result.append(segment)
            }
        }
        return result
    }

    /// 跨段说话人身份合并：按段顺序把每段的局部说话人编号映射为全局编号。
    /// 依据段质心与已建立全局质心的余弦相似度（≥ matchThreshold 视为同一人，取最相似者；
    /// 平手时取先建立者，保证确定性）。空质心无法比对，单独占一个新全局编号。
    /// - Returns: 与输入等长的数组，第 i 个字典把该段局部编号映射为全局编号
    static func globalSpeakerMapping(
        chunkCentroids: [[Int: [Float]]],
        matchThreshold: Float
    ) -> [[Int: Int]] {
        var globalCentroids: [[Float]] = []
        var mappings: [[Int: Int]] = []
        mappings.reserveCapacity(chunkCentroids.count)
        for centroids in chunkCentroids {
            var mapping: [Int: Int] = [:]
            for local in centroids.keys.sorted() {
                guard let embedding = centroids[local] else { continue }
                if embedding.isEmpty {
                    mapping[local] = globalCentroids.count
                    globalCentroids.append([])
                    continue
                }
                let normalized = VoiceprintStore.l2Normalize(embedding)
                var bestIndex: Int?
                var bestScore = matchThreshold
                for (index, global) in globalCentroids.enumerated() where !global.isEmpty {
                    let score = VoiceprintStore.cosineSimilarity(normalized, global)
                    if score >= bestScore {
                        bestScore = score
                        bestIndex = index
                    }
                }
                if let index = bestIndex {
                    mapping[local] = index
                    globalCentroids[index] = averageL2(globalCentroids[index], normalized)
                } else {
                    mapping[local] = globalCentroids.count
                    globalCentroids.append(normalized)
                }
            }
            mappings.append(mapping)
        }
        return mappings
    }

    /// 按总时长降序给说话人重编号（编号 0 = 说得最多）；时长相同按原编号升序，保证确定性
    /// - Returns: 重编号后的片段与 原编号 → 新编号 映射
    static func renumberByTotalDuration(
        _ segments: [DiarizationSegment]
    ) -> (segments: [DiarizationSegment], mapping: [Int: Int]) {
        var durations: [Int: TimeInterval] = [:]
        for segment in segments {
            durations[segment.speaker, default: 0] += segment.end - segment.start
        }
        let ordered = durations.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.map(\.key)
        var mapping: [Int: Int] = [:]
        for (index, speaker) in ordered.enumerated() { mapping[speaker] = index }
        let renumbered = segments.map {
            DiarizationSegment(
                start: $0.start,
                end: $0.end,
                speaker: mapping[$0.speaker] ?? $0.speaker
            )
        }
        return (renumbered, mapping)
    }

    /// 两个维度一致的嵌入做逐元素均值后再 L2 归一化；维度不一致时保留原值
    private static func averageL2(_ a: [Float], _ b: [Float]) -> [Float] {
        guard a.count == b.count, !a.isEmpty else { return a }
        return VoiceprintStore.l2Normalize(
            a.indices.map { (a[$0] + b[$0]) / 2 }
        )
    }
}

// MARK: - 异步串行门

/// 串行门实现已统一收敛到 `RacingWatchdog.swift` 的 `CancellableGate`：
/// 旧版本地实现用不响应取消的 `withCheckedContinuation` 排队，持锁任务永久挂起时
/// 所有排队者一起悬挂；且与 WhisperLocalService 内的同名实现重复，缺陷会各自演化。
