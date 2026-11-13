import Foundation
import WhisperKit
import os.log

/// 统一日志（生产日志走系统统一收集）
private let whisperDownloadLogger = Logger(subsystem: "app.memozia", category: "WhisperModelDownload")

/// Whisper 模型下载错误（errorDescription 直接展示给用户）
enum WhisperModelDownloadError: LocalizedError {
    case folderUnavailable(String)
    case destinationExists(String)
    case downloadFailed(String)
    case incomplete(String)

    var errorDescription: String? {
        switch self {
        case .folderUnavailable(let path):
            return String(format: String(localized: "无法创建或访问模型文件夹：%@"), path)
        case .destinationExists(let path):
            return String(format: String(localized: "该文件夹下已存在同名模型：%@。请先删除它，或换一个模型文件夹。"), path)
        case .downloadFailed(let reason):
            return String(format: String(localized: "模型下载失败：%@"), reason)
        case .incomplete(let path):
            return String(format: String(localized: "下载已完成但模型文件不完整：%@"), path)
        }
    }
}

/// Whisper CoreML 模型下载（HuggingFace 官方 / HF-Mirror 镜像）
///
/// 复用 WhisperKit 的 `download(variant:downloadBase:from:endpoint:)`：
/// - 按逐文件字节流落盘，读流循环响应 Task 取消，取消后残留分片与 .cache 元数据可续传；
/// - 落盘位置为 `<模型文件夹>/models/<repo>/<variant>`，下载完成后再重命名到
///   `<模型文件夹>/<variant>`，与手动放置模型的目录结构保持一致。
final class WhisperModelDownloader: Sendable {

    static let shared = WhisperModelDownloader()

    /// 下载串行门：多路并发下载同一仓库会互相覆盖 .cache 下载元数据
    private static let downloadGate = CancellableGate()

    /// WhisperKit 加载模型时必需的三件套，缺任一即视为未就绪
    private static let requiredModelNames = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]

    private init() {}

    // MARK: - 路径与状态

    /// 档位在模型文件夹下的目标目录
    nonisolated static func modelFolderURL(option: WhisperModelOption, modelRootPath: String) -> URL {
        URL(fileURLWithPath: (modelRootPath as NSString).expandingTildeInPath)
            .appendingPathComponent(option.variant, isDirectory: true)
    }

    /// 模型是否已就绪（三个 .mlmodelc 齐全；手动放置与下载安装走同一判定）
    nonisolated static func isModelPresent(option: WhisperModelOption, modelRootPath: String) -> Bool {
        let fm = FileManager.default
        let folder = modelFolderURL(option: option, modelRootPath: modelRootPath)
        return requiredModelNames.allSatisfy {
            fm.fileExists(atPath: folder.appendingPathComponent("\($0).mlmodelc").path)
        }
    }

    // MARK: - 下载

    /// 下载指定档位到 `<模型文件夹>/<档位名>`，返回最终模型文件夹路径
    ///
    /// 幂等：目标目录已就绪时直接返回，不重复下载。
    /// - Parameter onProgress: 进度回调（0.0~1.0），在下载线程回调，调用方自行切主线程
    nonisolated func download(
        option: WhisperModelOption,
        source: WhisperModelSource,
        modelRootPath: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        try await Self.downloadGate.run {
            let fm = FileManager.default
            let root = URL(fileURLWithPath: (modelRootPath as NSString).expandingTildeInPath)
            let destination = Self.modelFolderURL(option: option, modelRootPath: root.path)

            if Self.isModelPresent(option: option, modelRootPath: root.path) {
                whisperDownloadLogger.info("模型已存在，跳过下载: \(destination.path, privacy: .public)")
                onProgress?(1.0)
                return destination.path
            }

            // 目录存在但不完整：不静默删除用户数据，交由用户决定
            if fm.fileExists(atPath: destination.path) {
                throw WhisperModelDownloadError.destinationExists(destination.path)
            }

            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                whisperDownloadLogger.error("模型文件夹不可创建: \(root.path, privacy: .public)")
                throw WhisperModelDownloadError.folderUnavailable(root.path)
            }

            // tokenizer 缺失时 WhisperKit 会按 HF_ENDPOINT 回退联网取 tokenizer，
            // 这里同步所选源，保证「官方 / 镜像」对下载与后续加载一致生效
            source.applyAsHubEnvironment()

            whisperDownloadLogger.info(
                "开始下载 \(option.variant, privacy: .public)，源 \(source.endpoint, privacy: .public)"
            )

            let stagedURL: URL
            do {
                stagedURL = try await WhisperKit.download(
                    variant: option.variant,
                    downloadBase: root,
                    useBackgroundSession: false,
                    from: WhisperModelOption.repository,
                    endpoint: source.endpoint
                ) { progress in
                    let total = progress.totalUnitCount
                    guard total > 0 else { return }
                    onProgress?(Double(progress.completedUnitCount) / Double(total))
                }
            } catch is CancellationError {
                // 保留已下载分片与 .cache 元数据：下次下载可续传，不清理半成品
                whisperDownloadLogger.info("模型下载已取消，保留可续传的分片")
                throw CancellationError()
            } catch {
                whisperDownloadLogger.error(
                    "模型下载失败: \(error.localizedDescription, privacy: .public)"
                )
                throw WhisperModelDownloadError.downloadFailed(error.localizedDescription)
            }

            try Task.checkCancellation()

            do {
                try fm.moveItem(at: stagedURL, to: destination)
            } catch {
                whisperDownloadLogger.error(
                    "模型目录整理失败: \(error.localizedDescription, privacy: .public)"
                )
                throw WhisperModelDownloadError.downloadFailed(error.localizedDescription)
            }
            Self.removeEmptyStagingDirectories(under: root)

            guard Self.isModelPresent(option: option, modelRootPath: root.path) else {
                throw WhisperModelDownloadError.incomplete(destination.path)
            }

            onProgress?(1.0)
            whisperDownloadLogger.info("模型下载完成: \(destination.path, privacy: .public)")
            return destination.path
        }
    }

    /// 清理下载中转留下的空目录层级（`<root>/models/<repo>`）。
    /// 只删空目录：含 .cache 元数据（可续传其他档位）时保留
    private nonisolated static func removeEmptyStagingDirectories(under root: URL) {
        let fm = FileManager.default
        let modelsDirectory = root.appendingPathComponent("models")
        let repoDirectory = modelsDirectory.appendingPathComponent(WhisperModelOption.repository)
        for candidate in [repoDirectory, modelsDirectory] {
            guard let items = try? fm.contentsOfDirectory(atPath: candidate.path), items.isEmpty else { continue }
            try? fm.removeItem(at: candidate)
        }
    }
}
