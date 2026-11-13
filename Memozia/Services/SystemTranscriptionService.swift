import Foundation
import AVFoundation
import Speech
import os.log

/// 系统语音识别（SpeechAnalyzer / SpeechTranscriber，macOS 26 起）接入层。
///
/// 对外统一暴露成不依赖新 SDK 的签名：低版本系统调用直接抛 `unsupportedOS`，
/// 因此调用点（RecordingViewModel / BackgroundWorker / 设置页）不需要散落 `#available`。
///
/// 与 WhisperKit 的差异：
/// - 无「模型文件夹」概念，语言模型由系统经 `AssetInventory` 下载并管理
/// - 没有自动语种检测，必须显式 locale；空语言表示跟随系统语言
/// - 不提供说话人标签，说话人区分仍由 `SpeakerDiarizationService` 按时间轴标注
enum SystemTranscription {

    /// 系统语音识别是否可用（只看系统版本；语言模型是否已下载另行判断）
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// 转写前预检：系统版本与用户授权。失败时抛出可直接展示给用户的错误，
    /// 供批量转写「启动即快速失败」使用（避免逐条任务各自报同一个错）
    static func preflight() async throws {
        guard #available(macOS 26.0, *) else { throw SystemTranscriptionError.unsupportedOS }
        guard await SystemTranscriptionService.ensureAuthorized() else {
            throw SystemTranscriptionError.authorizationDenied
        }
    }

    /// 音频文件 → 按时间升序的转写片段
    /// - Parameters:
    ///   - audioURL: 音频文件（m4a/wav/mp3 等 AVAudioFile 可读格式）
    ///   - language: 设置中的语言值；空串表示跟随系统语言
    ///   - onProgress: 进度回调（0.0~1.0），按已识别到的时间轴位置估算
    static func transcribe(
        audioURL: URL,
        language: String,
        onProgress: (@Sendable (Float) -> Void)? = nil
    ) async throws -> [TranscriptionResult] {
        guard #available(macOS 26.0, *) else { throw SystemTranscriptionError.unsupportedOS }
        return try await SystemTranscriptionService.shared.transcribe(
            audioURL: audioURL, language: language, onProgress: onProgress
        )
    }

    /// 当前语言对应的系统模型状态（供设置页展示）。nil 表示系统不支持该能力
    static func localeStatus(language: String) async -> SystemTranscriptionLocaleStatus? {
        guard #available(macOS 26.0, *) else { return nil }
        return await SystemTranscriptionService.shared.localeStatus(language: language)
    }

    /// 下载并安装当前语言的系统模型（首次转写也会自动触发，这里供设置页提前准备）
    static func prepareLocale(language: String) async throws {
        guard #available(macOS 26.0, *) else { throw SystemTranscriptionError.unsupportedOS }
        try await SystemTranscriptionService.shared.prepareLocale(language: language)
    }
}

/// 系统语音识别的语言模型状态
enum SystemTranscriptionLocaleStatus: Sendable, Equatable {
    /// 该语言的系统模型已安装，可直接转写
    case ready
    /// 系统支持该语言，但模型尚未下载
    case needsDownload
    /// 系统不支持该语言
    case unsupported
}

enum SystemTranscriptionError: LocalizedError {
    case unsupportedOS
    case authorizationDenied
    case localeUnsupported(String)
    case audioUnreadable
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return String(localized: "系统语音识别需要 macOS 26 或更高版本。")
        case .authorizationDenied:
            return String(localized: "未获得语音识别权限。请在「系统设置 → 隐私与安全性 → 语音识别」中允许 Memozia 后重试。")
        case .localeUnsupported(let identifier):
            return String(format: String(localized: "系统语音识别不支持该语言（%@）。"), identifier)
        case .audioUnreadable:
            return String(localized: "音频文件无法读取，无法进行系统语音识别。")
        case .timedOut:
            return String(localized: "系统语音识别长时间无响应，已中止本次识别。请重试；若反复出现，可在设置中改用其他转写引擎。")
        }
    }
}

/// 系统语音识别服务：所有 SpeechAnalyzer 细节都收敛在这个类型里
@available(macOS 26.0, *)
final class SystemTranscriptionService: @unchecked Sendable {

    static let shared = SystemTranscriptionService()

    private static let logger = Logger(subsystem: "app.memozia", category: "SystemSTT")

    /// 推理串行门：单次分析会话在系统进程里各自独立，但并发拉起多份语言模型
    /// 会显著抬高内存峰值；沿用工程既有约定（与 WhisperKit、sherpa-onnx 一致）
    /// 用可取消门串行化——持锁者被取消时排队者不会一起悬挂
    private let gate = CancellableGate()

    private init() {}

    // MARK: - 授权

    /// 确认（必要时请求）语音识别授权；`notDetermined` 时弹出系统授权框。
    /// 后台 worker 无 UI，此时依赖主应用此前已授予的授权（已授予可直接复用）
    static func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    // MARK: - 语言与模型资产

    /// 解析实际使用的 locale：显式语言优先 → 系统语言 → en-US；
    /// 三者都不被支持时抛出错误（而不是静默换成别的语言）
    static func resolvedLocale(for language: String) async throws -> Locale {
        let requested = STTConfig.systemLocaleIdentifier(forLanguage: language)
            .map { Locale(identifier: $0) }

        if let requested,
           let matched = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            return matched
        }
        if let requested {
            Self.logger.warning("系统语音识别不支持语言 \(requested.identifier)，改用系统语言")
        }
        if let systemMatched = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
            return systemMatched
        }
        if let fallback = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) {
            return fallback
        }
        throw SystemTranscriptionError.localeUnsupported(
            requested?.identifier ?? Locale.current.identifier
        )
    }

    /// 按语言确保系统模型已安装；已安装时为幂等空操作
    static func installAssetsIfNeeded(for locale: Locale) async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .installed else { return }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            // 无可安装项：多为系统已持有该语言资产，直接进入转写
            return
        }
        Self.logger.info("开始下载系统语音识别模型")
        try await request.downloadAndInstall()
        Self.logger.info("系统语音识别模型下载完成")
    }

    func localeStatus(language: String) async -> SystemTranscriptionLocaleStatus {
        guard SpeechTranscriber.isAvailable else { return .unsupported }
        guard let locale = try? await Self.resolvedLocale(for: language) else { return .unsupported }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        switch status {
        case .installed:
            return .ready
        case .supported, .downloading:
            return .needsDownload
        case .unsupported:
            return .unsupported
        @unknown default:
            return .needsDownload
        }
    }

    func prepareLocale(language: String) async throws {
        let locale = try await Self.resolvedLocale(for: language)
        try await Self.installAssetsIfNeeded(for: locale)
    }

    // MARK: - 转写

    func transcribe(
        audioURL: URL,
        language: String,
        onProgress: (@Sendable (Float) -> Void)?
    ) async throws -> [TranscriptionResult] {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw SystemTranscriptionError.audioUnreadable
        }
        guard await Self.ensureAuthorized() else {
            throw SystemTranscriptionError.authorizationDenied
        }
        guard SpeechTranscriber.isAvailable else {
            throw SystemTranscriptionError.unsupportedOS
        }

        let locale = try await Self.resolvedLocale(for: language)
        try await Self.installAssetsIfNeeded(for: locale)
        let totalDuration = await Self.audioDuration(of: audioURL)

        // 串行门保护：转写会话期间不允许其他转写/模型准备并发进入
        try await gate.acquire()
        do {
            let results = try await performTranscription(
                audioURL: audioURL,
                locale: locale,
                totalDuration: totalDuration,
                onProgress: onProgress
            )
            await gate.release()
            return results
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performTranscription(
        audioURL: URL,
        locale: Locale,
        totalDuration: TimeInterval,
        onProgress: (@Sendable (Float) -> Void)?
    ) async throws -> [TranscriptionResult] {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = TranscriptionCollector()

        let work = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                // 喂音频与消费结果必须并发：结果序列不被消费时分析不会向前推进
                group.addTask {
                    let file = try AVAudioFile(forReading: audioURL)
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                }
                group.addTask {
                    for try await result in transcriber.results {
                        try Task.checkCancellation()
                        guard result.isFinal else { continue }
                        let text = String(result.text.characters)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }

                        let start = CMTimeGetSeconds(result.range.start)
                        let end = CMTimeGetSeconds(result.range.end)
                        let safeStart = start.isFinite ? max(start, 0) : 0
                        let safeEnd = end.isFinite ? max(end, safeStart) : safeStart
                        await collector.append(TranscriptionResult(
                            text: text,
                            startTime: safeStart,
                            endTime: safeEnd
                        ))
                        if totalDuration > 0 {
                            onProgress?(Float(min(max(safeEnd / totalDuration, 0), 1)))
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        // 看门狗兜底：底层 SpeechAnalyzer 若不响应取消，`work.value` 可能永久不返回，
        // 调用方（transcribe）就拿不到返回、永远不释放串行门 —— 之后所有系统语音识别
        // 全部排在该门上。超时/取消时尽力取消分析会话并按失败返回。
        let errorBox = LockedBox<SentError?>(nil)
        let finished = await RacingWatchdog.race(
            name: "系统语音识别 \(audioURL.lastPathComponent)",
            timeout: Self.transcriptionTimeout(forDuration: totalDuration)
        ) {
            do {
                try await work.value
            } catch {
                errorBox.value = SentError(error)
            }
        }

        if !finished {
            work.cancel()
            await analyzer.cancelAndFinishNow()
            // 区分「调用方取消」与「看门狗超时」（race 的约定）
            if Task.isCancelled { throw CancellationError() }
            throw SystemTranscriptionError.timedOut
        }
        if let boxed = errorBox.value {
            work.cancel()
            await analyzer.cancelAndFinishNow()
            throw boxed.value
        }

        let results = await collector.snapshot()
        Self.logger.info("系统语音识别完成，片段数 \(results.count)")
        return results.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - 辅助

    /// 转写看门狗超时：仅兜「分析会话永久不返回」，按音频时长放宽（至少 20 分钟），
    /// 不打断慢但在推进的长音频识别
    private static func transcriptionTimeout(forDuration duration: TimeInterval) -> TimeInterval {
        max(20 * 60, duration * 2)
    }

    /// 音频总时长（秒）；取不到时返回 0，进度回调退化为不上报
    private static func audioDuration(of url: URL) async -> TimeInterval {
        await Task.detached(priority: .utility) { () -> TimeInterval in
            guard let file = try? AVAudioFile(forReading: url) else { return 0 }
            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else { return 0 }
            return Double(file.length) / sampleRate
        }.value
    }
}

/// 跨并发域收集转写片段（TaskGroup 子任务之间不共享可变状态）
private actor TranscriptionCollector {
    private var items: [TranscriptionResult] = []

    func append(_ item: TranscriptionResult) {
        items.append(item)
    }

    func snapshot() -> [TranscriptionResult] {
        items
    }
}
