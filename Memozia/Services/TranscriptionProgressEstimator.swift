import Foundation
import os

// MARK: - 耗时基线（RTF）

/// RTF 基线表：`rtf` = 处理 1 秒音频所需的墙钟秒数。
///
/// 为什么要把基线做成可更新的：RTF 主要取决于机器（CPU/ANE 档位）、模型大小、语种与音频内容，
/// 事前猜一个常数必然偏。因此这里的默认值只作为**首次运行的起点**：
/// 第一个样本直接采用实测值（bootstrap），之后按 EMA 平滑，几轮之后即收敛到本机真实速度。
struct TranscriptionRTFTable: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var rtf: Double
        var sampleCount: Int

        /// EMA 系数：新样本占比。取 0.3 兼顾「跟得上机器变化」与「不被单次异常带偏」
        private static let smoothing: Double = 0.3

        mutating func record(observed: Double) {
            rtf = sampleCount == 0 ? observed : rtf * (1 - Self.smoothing) + observed * Self.smoothing
            sampleCount += 1
        }
    }

    /// 转录按「模式 + 本地模型目录名」分桶：档位之间 RTF 可差数倍，混在一起会互相污染
    var transcription: [String: Sample] = [:]
    /// 分离模型与转录模式无关（同一份 pyannote ONNX），全局一项
    var diarization = Sample(
        rtf: TranscriptionRTFTable.uncalibratedDiarizationRTF,
        sampleCount: 0
    )

    /// 未标定的起点：**故意高估**。宁可进度条走得慢，也不要提前走到头停住
    /// （走到头停住会被当成卡死）。这两个数是待标定的占位，不是实测结果。
    static let uncalibratedTranscriptionRTF: Double = 0.6
    static let uncalibratedDiarizationRTF: Double = 0.15

    func profile(for key: String) -> TranscriptionRTFProfile {
        let sample = transcription[key]
        return TranscriptionRTFProfile(
            transcriptionRTF: sample?.rtf ?? Self.uncalibratedTranscriptionRTF,
            diarizationRTF: diarization.rtf,
            isCalibrated: (sample?.sampleCount ?? 0) >= TranscriptionRTFProfile.calibratedSampleCount
        )
    }

    /// 记录一次真实运行。分离未参与（未开启/被跳过/失败）时传 nil，避免污染分离基线
    mutating func record(
        key: String,
        transcriptionSeconds: Double,
        diarizationSeconds: Double?,
        audioSeconds: Double
    ) {
        guard audioSeconds > 0, transcriptionSeconds > 0 else { return }
        var sample = transcription[key]
            ?? Sample(rtf: Self.uncalibratedTranscriptionRTF, sampleCount: 0)
        sample.record(observed: transcriptionSeconds / audioSeconds)
        transcription[key] = sample

        if let diarizationSeconds, diarizationSeconds > 0 {
            diarization.record(observed: diarizationSeconds / audioSeconds)
        }
    }
}

/// 估计器需要的基线快照（值语义，便于注入与单测）
struct TranscriptionRTFProfile: Equatable, Sendable {
    var transcriptionRTF: Double
    var diarizationRTF: Double
    var isCalibrated: Bool

    /// 达到该样本数后视为已标定
    static let calibratedSampleCount = 3

    static let uncalibrated = TranscriptionRTFProfile(
        transcriptionRTF: TranscriptionRTFTable.uncalibratedTranscriptionRTF,
        diarizationRTF: TranscriptionRTFTable.uncalibratedDiarizationRTF,
        isCalibrated: false
    )
}

// MARK: - 基线的持久化

/// 基线表的读写。数据不含密钥与用户内容（只有耗时比例与模型目录名），落 UserDefaults。
///
/// 用锁保护读-改-写：批量转写会并发上报样本，两个任务各自「读全表 → 改一行 → 写回」
/// 会互相覆盖（与后台任务队列那条同类的丢更新问题）。
final class TranscriptionRTFStore: @unchecked Sendable {
    static let shared = TranscriptionRTFStore()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let storageKey = "transcription_rtf_table_v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func table() -> TranscriptionRTFTable {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func profile(for key: String) -> TranscriptionRTFProfile {
        table().profile(for: key)
    }

    /// 并发安全地记入一条样本，返回更新后的整表（供日志使用）
    @discardableResult
    func record(
        key: String,
        transcriptionSeconds: Double,
        diarizationSeconds: Double?,
        audioSeconds: Double
    ) -> TranscriptionRTFTable {
        lock.lock()
        defer { lock.unlock() }
        var table = loadLocked()
        table.record(
            key: key,
            transcriptionSeconds: transcriptionSeconds,
            diarizationSeconds: diarizationSeconds,
            audioSeconds: audioSeconds
        )
        if let data = try? JSONEncoder().encode(table) {
            defaults.set(data, forKey: storageKey)
        }
        return table
    }

    /// 分桶键：本地按模型目录名分（档位间 RTF 可差数倍），云端/系统各自一桶
    static func transcriptionKey(mode: STTMode, modelPath: String) -> String {
        switch mode {
        case .local:
            return "local:\(URL(fileURLWithPath: modelPath).lastPathComponent)"
        case .cloud:
            return "cloud"
        case .system:
            return "system"
        }
    }

    private func loadLocked() -> TranscriptionRTFTable {
        guard let data = defaults.data(forKey: storageKey),
              let table = try? JSONDecoder().decode(TranscriptionRTFTable.self, from: data) else {
            return TranscriptionRTFTable()
        }
        return table
    }
}

// MARK: - 合并进度估计

/// 把「转写 + 说话人区分」两条**串行**流水线折算成一条进度条的 0...1 比例。
///
/// 折算规则（B 档：事前估算 + 运行期反推 + 实测标定）：
/// 1. 事前按时长估算两段耗时（RTF × 音频时长），得到各段在总时长中的占比；
/// 2. 段内优先用**真实信号**：转写有窗口进度回调，直接采用；没有回调的段（分离核心推理、
///    云端上传）用**时间蠕动**：估计值以内按比例线性，超出后减速并渐近 97%——
///    既不静止，也永不提前到 100%；
/// 3. 段边界 **snap**：某段一结束就把进度钉到该段末尾，把估算误差截断在单段内部；
/// 4. **运行期反推**：转写跑到 10% 以上后，用实测速率修正转写总耗时的估算；为避免进度回退
///    该修正只允许上调，猜得偏高的那一次由基线表在下一次运行修正（首个样本即采用实测值）。
struct TranscriptionProgressEstimator: Sendable {
    enum Stage: Equatable, Sendable {
        case transcription
        case diarization
    }

    /// 蠕动的渐近上限：永远留一点余量，避免“显示 100% 了还在跑”
    static let creepCeiling: Double = 0.97
    /// 估计值以内的线性比例上限（超出后转入减速段）
    static let linearCeiling: Double = 0.9
    /// 运行期反推的下限：进度太小时 `elapsed / fraction` 噪声极大，先不采信
    static let minimumFractionForLiveEstimate: Double = 0.1
    /// 实测 / 初始估算 的钳制区间：防止一次异常运行把估算拉飞
    static let liveEstimateRange: ClosedRange<Double> = 0.25...4.0
    /// 运行期反推的平滑系数：实测占七成，保留三成初始估算以抑制抖动
    static let liveEstimateWeight: Double = 0.7

    private let audioSeconds: Double
    private let diarizationEnabled: Bool
    private let profile: TranscriptionRTFProfile
    private let now: @Sendable () -> Date

    private var transcriptionStart: Date?
    private var transcriptionEnd: Date?
    private var diarizationStart: Date?
    private var diarizationEnd: Date?
    private var transcriptionFraction: Double?
    private var diarizationSettled = false
    /// 运行期反推得到的转写总耗时估算；只增不减，避免进度回退
    private var liveTranscriptionEstimate: TimeInterval?

    init(
        audioSeconds: Double,
        diarizationEnabled: Bool,
        profile: TranscriptionRTFProfile,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioSeconds = max(audioSeconds, 0)
        self.diarizationEnabled = diarizationEnabled
        self.profile = profile
        self.now = now
    }

    // MARK: 事件

    /// 某个阶段真正开始。应在**跳过准备/下载/加载**之后调用：
    /// 那些耗时与音频时长无关，计进去会污染 RTF 基线与蠕动刻度
    mutating func begin(_ stage: Stage) {
        switch stage {
        case .transcription:
            transcriptionStart = now()
            transcriptionEnd = nil
        case .diarization:
            diarizationStart = now()
            diarizationEnd = nil
        }
    }

    /// 段内真实进度（0...1）。只有转写有窗口回调，没有回调的段不要调用
    mutating func reportFraction(_ fraction: Double) {
        guard transcriptionEnd == nil else { return }
        let clamped = min(max(fraction, 0), 1)
        transcriptionFraction = clamped
        updateLiveEstimate(fraction: clamped)
    }

    /// 某阶段完成
    mutating func finish(_ stage: Stage) {
        switch stage {
        case .transcription:
            transcriptionEnd = now()
            transcriptionFraction = 1
        case .diarization:
            diarizationEnd = now()
            diarizationSettled = true
        }
    }

    /// 某阶段被跳过/失败/取消：本次运行不再有该阶段的后续，进度据此收口
    mutating func abort(_ stage: Stage) {
        guard stage == .diarization else { return }
        diarizationSettled = true
    }

    // MARK: 结果

    /// 当前合并进度（0...1）
    func progress() -> Double {
        let plan = estimatedDurations()
        let total = plan.transcription + plan.diarization
        guard total > 0 else { return 0 }
        // 分离未参与：转写独占整条进度，不会“走到一半就结束”
        guard plan.diarization > 0 else { return clamp(transcriptionFill()) }
        // 分离已收口（完成/跳过/失败）：本次处理走到尽头，后面只剩合并保存
        if diarizationSettled { return 1 }
        guard transcriptionEnd != nil else {
            return clamp(transcriptionFill() * plan.transcription / total)
        }
        // 转写已完成：先钉在转写段末尾，分离段按时间蠕动
        let creep = Self.creepFill(ratio: diarizationElapsed / plan.diarization)
        return clamp((plan.transcription + creep * plan.diarization) / total)
    }

    /// 两段各自的估算耗时（秒）：分离段在运行期反推后随转写估算一起变化
    func estimatedDurations() -> (transcription: TimeInterval, diarization: TimeInterval) {
        let base = profile.transcriptionRTF * audioSeconds
        let transcription = max(base, liveTranscriptionEstimate ?? 0)
        guard diarizationEnabled else { return (transcription, 0) }
        return (transcription, profile.diarizationRTF * audioSeconds)
    }

    /// 本次运行的实测耗时，供 RTF 标定与日志使用；转写没跑完则为 nil（失败的运行不参与标定）
    func calibrationSample() -> (transcriptionSeconds: TimeInterval, diarizationSeconds: TimeInterval?)? {
        guard let transcriptionStart, let transcriptionEnd else { return nil }
        let transcriptionSeconds = transcriptionEnd.timeIntervalSince(transcriptionStart)
        guard transcriptionSeconds > 0 else { return nil }
        let diarizationSeconds = diarizationEnd.flatMap { end in
            diarizationStart.map { end.timeIntervalSince($0) }
        }
        return (transcriptionSeconds, diarizationSeconds)
    }

    // MARK: 内部

    /// 转写段内的填充比例：有真实窗口进度就用它，否则按时间蠕动（云端上传没有回调）
    private func transcriptionFill() -> Double {
        if transcriptionEnd != nil { return 1 }
        if let fraction = transcriptionFraction { return fraction }
        let estimated = max(profile.transcriptionRTF * audioSeconds, 0.001)
        return Self.creepFill(ratio: transcriptionElapsed / estimated)
    }

    /// 运行期速率反推：`elapsed / fraction` 即按当前实测速率算出的转写**总耗时**
    private mutating func updateLiveEstimate(fraction: Double) {
        guard fraction >= Self.minimumFractionForLiveEstimate else { return }
        let elapsed = transcriptionElapsed
        let base = profile.transcriptionRTF * audioSeconds
        guard elapsed > 0, base > 0 else { return }
        let lower = base * Self.liveEstimateRange.lowerBound
        let upper = base * Self.liveEstimateRange.upperBound
        let observed = min(max(elapsed / fraction, lower), upper)
        let blended = base * (1 - Self.liveEstimateWeight) + observed * Self.liveEstimateWeight
        liveTranscriptionEstimate = max(liveTranscriptionEstimate ?? base, blended)
    }

    private var transcriptionElapsed: TimeInterval {
        guard let transcriptionStart else { return 0 }
        return (transcriptionEnd ?? now()).timeIntervalSince(transcriptionStart)
    }

    private var diarizationElapsed: TimeInterval {
        guard let diarizationStart else { return 0 }
        return (diarizationEnd ?? now()).timeIntervalSince(diarizationStart)
    }

    /// 时间蠕动的填充比例：估计值以内线性（估算准就是真实速率），
    /// 超出后减速并渐近 `creepCeiling`——既不静止，也永不提前到 100%
    static func creepFill(ratio: Double) -> Double {
        guard ratio > 0 else { return 0 }
        guard ratio > 1 else { return ratio * linearCeiling }
        let excess = 1 - exp(-(ratio - 1))
        return linearCeiling + (creepCeiling - linearCeiling) * excess
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

// MARK: - 标定日志

/// 耗时标定日志。
///
/// 用 `info` 而非 `debug`：这些数值需要事后从 Console/日志里捞出来定 RTF 常数，
/// 而 `debug` 不落盘。属低频（每次转写一条），不违反「高频诊断用 debug」。
enum TranscriptionPerfLog {
    private static let logger = Logger(subsystem: "app.memozia", category: "TranscriptionPerf")

    static func report(
        mode: STTMode,
        modelName: String,
        audioSeconds: Double,
        transcriptionSeconds: Double,
        diarizationSeconds: Double?,
        profile: TranscriptionRTFProfile
    ) {
        let diarization = diarizationSeconds.map { String(format: "%.1f", $0) } ?? "skipped"
        let audio = String(format: "%.1f", audioSeconds)
        let transcription = String(format: "%.1f", transcriptionSeconds)
        let transcriptionRTF = String(format: "%.4f", profile.transcriptionRTF)
        let diarizationRTF = String(format: "%.4f", profile.diarizationRTF)
        logger.info("""
        [RTF] mode=\(mode.rawValue, privacy: .public) model=\(modelName, privacy: .public) \
        audioSeconds=\(audio, privacy: .public) transcriptionSeconds=\(transcription, privacy: .public) \
        diarizationSeconds=\(diarization, privacy: .public) transcriptionRTF=\(transcriptionRTF, privacy: .public) \
        diarizationRTF=\(diarizationRTF, privacy: .public) calibrated=\(profile.isCalibrated, privacy: .public)
        """)
    }

    /// 模型加载耗时与音频时长无关，单独打点，供将来把「固定开销」拆成独立阶段
    static func reportModelLoad(mode: STTMode, modelName: String, seconds: Double) {
        let value = String(format: "%.1f", seconds)
        logger.info("""
        [RTF-load] mode=\(mode.rawValue, privacy: .public) model=\(modelName, privacy: .public) \
        seconds=\(value, privacy: .public)
        """)
    }
}
