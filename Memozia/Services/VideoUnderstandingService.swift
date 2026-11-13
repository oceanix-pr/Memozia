import Foundation
import CryptoKit

struct VisualAnalysisCheckpoint: Sendable {
    let analysisID: String
    let totalSegments: Int
    let completedSegments: [Int: String]
}

/// 视频理解管线。只接收文件 URL、配置快照和 Sendable 回调，不持有 SwiftData/UI 对象。
enum VideoUnderstandingService {
    /// 抽帧策略变更时升级版本，使旧的稀疏帧缓存只失效一次。
    /// v3：指纹加入上下路与分块亮度、事件加最小间隔/最长静默兜底、名额随时长自适应并按时间轴覆盖选帧。
    /// v5：不再按视频时长把稳定变化压成最多 64 帧；连续重复/短暂跳变在本地过滤后，
    /// 保留全部重大变化（极端动态素材仅受 1024 帧安全保护），模型侧动态分批且不再二次降采样。
    /// 版本与标记文件名对单测开放：「清理视频」的安全前提就是这一对值。
    static let framesCacheVersion = "significant-events-v5"
    static let framesCacheVersionFileName = ".sampling-version"
    private static let checkpointManifestFileName = "manifest.json"
    private static let checkpointVersion = 1

    private struct CheckpointManifest: Codable, Equatable, Sendable {
        let version: Int
        let analysisID: String
        let totalSegments: Int
    }

    /// 无关联值，额外满足 Equatable：单测可直接断具体拒绝了哪个前置条件
    enum VideoUnderstandingError: LocalizedError, Equatable {
        /// 关键帧还没抽取（或缓存版本已过期）：此时清理视频等于把画面分析一起删掉
        case frameCacheMissing
        /// 原件已清理且缓存未命中：没有可重抽的来源
        case sourceUnavailable

        var errorDescription: String? {
            switch self {
            case .frameCacheMissing:
                return String(localized: "还没有可复用的关键帧。请先抽取关键帧，再清理原始视频。")
            case .sourceUnavailable:
                return String(localized: "原始视频已清理，且没有可复用的关键帧，无法分析画面（重新导入视频即可恢复）。")
            }
        }
    }

    /// 是否已有**可复用**的关键帧缓存：版本标记与当前抽帧策略一致且目录里确有帧。
    /// 与 `loadCachedFrames` 的失效判定同源（版本不符的旧帧必须重抽），
    /// 但只列目录不读图，供「清理视频」前置条件与画面页签可见性使用。
    static func hasReusableFrameCache(in directoryURL: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            let versionURL = directoryURL.appendingPathComponent(framesCacheVersionFileName)
            guard let version = try? String(contentsOf: versionURL, encoding: .utf8),
                  version == framesCacheVersion else { return false }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return urls.contains { $0.pathExtension.lowercased() == "jpg" }
        }.value
    }

    /// 清理条目的原始视频：**只删视频这一个文件**。
    ///
    /// 关键帧（`frames/`）、画面要点（`visual.md`）、分析检查点、音频与转写全部保留；
    /// 因此强制要求帧缓存已可复用——否则原件一走，画面链路就彻底无法继续。
    /// 不做递归删除也不按后缀扫目录，避免误伤同名前缀的其他产物。
    /// - Returns: 实际释放的字节数（取不到属性时为 0）
    static func cleanupOriginalVideo(videoURL: URL, framesDirectoryURL: URL) async throws -> Int64 {
        guard await hasReusableFrameCache(in: framesDirectoryURL) else {
            throw VideoUnderstandingError.frameCacheMissing
        }
        return try await Task.detached(priority: .userInitiated) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
            let freedBytes = (attributes?[.size] as? Int64) ?? 0
            // 只删这一个路径；失败向上抛，不静默当成已清理
            try FileManager.default.removeItem(at: videoURL)
            return freedBytes
        }.value
    }

    /// 复用已保存的关键帧；无可用缓存时才抽帧并保存。
    /// 视频链路共享步骤：总结前的画面会议判定与画面要点用同一份帧缓存（画面位于转写与总结之间）。
    ///
    /// `videoURL` 允许为 nil（用户已点「清理视频」）：命中缓存时照常返回帧，
    /// 让画面要点与重新分析在原件清理后仍可用；只有缓存未命中才需要原件，此时明确报错。
    /// onProgress 只报抽帧原始进度 0...1，由调用方映射到各自 UI。
    static func loadOrExtractFrames(
        videoURL: URL?,
        framesDirectoryURL: URL,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [VideoKeyframe] {
        let cachedFrames = await loadCachedFrames(from: framesDirectoryURL)
        guard cachedFrames.isEmpty else { return cachedFrames }

        guard let videoURL, FileManager.default.fileExists(atPath: videoURL.path) else {
            throw VideoUnderstandingError.sourceUnavailable
        }

        let frames = try await KeyframeExtractor.extractKeyframes(from: videoURL) { progress in
            onProgress(progress)
        }
        try Task.checkCancellation()
        await persist(frames: frames, to: framesDirectoryURL)
        return frames
    }

    /// 关键帧以时间编码在文件名中，可直接恢复成模型请求所需的值类型。
    /// 缓存损坏或目录不存在时返回空数组，由调用方重新抽帧。
    private static func loadCachedFrames(from directoryURL: URL) async -> [VideoKeyframe] {
        await Task.detached(priority: .utility) {
            let versionURL = directoryURL.appendingPathComponent(framesCacheVersionFileName)
            guard let version = try? String(contentsOf: versionURL, encoding: .utf8),
                  version == framesCacheVersion else { return [] }
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            return urls
                .filter { $0.pathExtension.lowercased() == "jpg" }
                .compactMap { url -> VideoKeyframe? in
                    let stem = url.deletingPathExtension().lastPathComponent
                    guard let timeComponent = stem.split(separator: "_").last,
                          timeComponent.hasSuffix("s"),
                          let time = Double(timeComponent.dropLast()),
                          let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          (values.fileSize ?? 0) > 0 else { return nil }
                    return VideoKeyframe(time: time, cachedFileURL: url)
                }
                .sorted { $0.time < $1.time }
        }.value
    }

    /// 关键帧是可再生缓存，写入失败不阻断模型分析。
    private static func persist(frames: [VideoKeyframe], to directoryURL: URL) async {
        let files = frames.enumerated().map { index, frame in
            (
                name: AudioRecording.frameFileName(index: index + 1, time: frame.time),
                data: frame.jpegData
            )
        }
        await Task.detached(priority: .utility) {
            do {
                if FileManager.default.fileExists(atPath: directoryURL.path) {
                    try FileManager.default.removeItem(at: directoryURL)
                }
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                for file in files {
                    try file.data.write(
                        to: directoryURL.appendingPathComponent(file.name),
                        options: .atomic
                    )
                }
                // 最后写版本标记：进程中断或任一帧失败时，下次不会误用半成品缓存。
                try framesCacheVersion.write(
                    to: directoryURL.appendingPathComponent(framesCacheVersionFileName),
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                FileSyncService.logWarning("关键帧缓存写入失败，将在下次分析时重新抽取: \(error.localizedDescription)")
            }
        }.value
    }

    /// 为当前「模型配置 + 完整帧内容」准备断点。身份不包含 API Key；检查点正文逐段加密。
    /// 模型、端点、视觉能力或任一帧变化时会舍弃旧检查点，避免拼接不一致的分析结果。
    static func prepareVisualAnalysisCheckpoint(
        frames: [VideoKeyframe],
        config: LLMConfigSnapshot,
        directoryURL: URL,
        framesPerSegment: Int
    ) async -> VisualAnalysisCheckpoint {
        let totalSegments = LLMService.visualChunks(
            from: frames,
            perRequest: framesPerSegment
        ).count

        // 身份计算也放进 detached：checkpointIdentity 会对全部关键帧逐个取 jpegData
        // （缓存帧为磁盘读取）并 SHA256 全量哈希，最多 1024 张 1280px 帧。旧实现把它
        // 留在调用方（MainActor），等于在主线程做数百 MB 读盘 + 哈希，直接卡住 UI。
        let (analysisID, completed) = await Task.detached(priority: .utility) {
            () -> (String, [Int: String]) in
            let analysisID = checkpointIdentity(frames: frames, config: config)
            let expected = CheckpointManifest(
                version: checkpointVersion,
                analysisID: analysisID,
                totalSegments: totalSegments
            )

            let fileManager = FileManager.default
            let manifestURL = directoryURL.appendingPathComponent(checkpointManifestFileName)
            let existing = (try? Data(contentsOf: manifestURL))
                .flatMap { try? JSONDecoder().decode(CheckpointManifest.self, from: $0) }

            do {
                if existing != expected, fileManager.fileExists(atPath: directoryURL.path) {
                    try fileManager.removeItem(at: directoryURL)
                }
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                if existing != expected {
                    try JSONEncoder().encode(expected).write(to: manifestURL, options: .atomic)
                }
            } catch {
                FileSyncService.logWarning(
                    "画面分析检查点初始化失败，将从头分析: \(error.localizedDescription)"
                )
                return (analysisID, [:])
            }

            var results: [Int: String] = [:]
            for segment in 0..<totalSegments {
                let url = checkpointSegmentURL(segment, in: directoryURL)
                guard let data = try? Data(contentsOf: url),
                      let ciphertext = String(data: data, encoding: .utf8),
                      let plaintext = try? EncryptionService.decrypt(ciphertext),
                      !plaintext.isEmpty else { continue }
                results[segment] = plaintext
            }
            return (analysisID, results)
        }.value

        return VisualAnalysisCheckpoint(
            analysisID: analysisID,
            totalSegments: totalSegments,
            completedSegments: completed
        )
    }

    /// 成功一段就同步写入加密检查点。写入失败只影响续跑能力，不丢弃本次内存结果。
    static func persistVisualAnalysisSegment(
        _ text: String,
        segment: Int,
        checkpoint: VisualAnalysisCheckpoint,
        directoryURL: URL
    ) async {
        await Task.detached(priority: .utility) {
            guard segment >= 0, segment < checkpoint.totalSegments else { return }
            let manifestURL = directoryURL.appendingPathComponent(checkpointManifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(CheckpointManifest.self, from: data),
                  manifest.analysisID == checkpoint.analysisID,
                  manifest.totalSegments == checkpoint.totalSegments else { return }
            do {
                try EncryptionService.encryptAndWrite(
                    text,
                    to: checkpointSegmentURL(segment, in: directoryURL)
                )
            } catch {
                FileSyncService.logWarning(
                    "画面分析第 \(segment + 1) 段检查点写入失败: \(error.localizedDescription)"
                )
            }
        }.value
    }

    /// 完整结果已持久化后才清理检查点；部分失败、取消或进程退出均保留以供下次续跑。
    static func clearVisualAnalysisCheckpoint(
        _ checkpoint: VisualAnalysisCheckpoint,
        directoryURL: URL
    ) async {
        await Task.detached(priority: .utility) {
            let manifestURL = directoryURL.appendingPathComponent(checkpointManifestFileName)
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(CheckpointManifest.self, from: data),
                  manifest.analysisID == checkpoint.analysisID else { return }
            do {
                try FileManager.default.removeItem(at: directoryURL)
            } catch {
                FileSyncService.logWarning(
                    "画面分析检查点清理失败: \(error.localizedDescription)"
                )
            }
        }.value
    }

    private static func checkpointIdentity(
        frames: [VideoKeyframe],
        config: LLMConfigSnapshot
    ) -> String {
        var hasher = SHA256()
        func update(_ value: String) {
            hasher.update(data: Data(value.utf8))
            hasher.update(data: Data([0]))
        }
        update(framesCacheVersion)
        update(config.chatCompletionsURL)
        update(config.modelName)
        update(config.isLocal ? "local" : "remote")
        update(config.supportsVision ? "vision" : "ocr")
        for frame in frames.sorted(by: { $0.time < $1.time }) {
            var timeBits = frame.time.bitPattern.bigEndian
            withUnsafeBytes(of: &timeBits) { hasher.update(data: Data($0)) }
            hasher.update(data: frame.jpegData)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func checkpointSegmentURL(_ segment: Int, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(
            String(format: "segment-%04d.enc", segment)
        )
    }
}
