import Foundation
import AVFoundation

/// OpenAI Whisper API 云端转写服务
struct WhisperAPIService {

    /// API 配置
    let apiKey: String
    let baseURL: String   // 默认 https://api.openai.com/v1
    let language: String? // 语言代码（nil=自动检测）

    /// 最大文件大小（25MB，OpenAI API 限制）
    private let maxFileSize: UInt64 = 25 * 1024 * 1024

    /// 网络重试次数
    private let maxRetries = 3

    /// 转写音频文件
    /// - Parameter audioURL: 音频文件路径
    /// - Returns: 带时间戳的转写片段数组
    func transcribe(audioURL: URL) async throws -> [TranscriptionResult] {
        // 云端配置必须 HTTPS（本地 localhost HTTP 除外），避免 API Key 与音频明文传输
        try LLMService.validateSecureURL(baseURL)

        let fileSize = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0

        if UInt64(fileSize) > maxFileSize {
            // 大文件需要分片处理
            return try await transcribeChunked(audioURL: audioURL)
        }

        return try await transcribeWithRetry(audioURL: audioURL)
    }

    // MARK: - 私有方法

    /// 带重试的转写（针对网络瞬时错误）
    private func transcribeWithRetry(audioURL: URL) async throws -> [TranscriptionResult] {
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                return try await transcribeSingle(audioURL: audioURL)
            } catch {
                lastError = error
                // 仅对网络瞬时错误重试（非 4xx 业务错误）
                if case WhisperAPIError.apiError(let statusCode, _) = error,
                   statusCode >= 400 && statusCode < 500 {
                    throw error // 客户端错误，不重试
                }
                if attempt < maxRetries {
                    // 指数退避：1s, 2s。退避**必须响应取消**：旧写法 `try? await` 吞掉
                    // CancellationError，用户取消后仍会把剩余重试全部打完（继续占带宽与配额）
                    let delay = UInt64(attempt) * 1_000_000_000
                    try await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? WhisperAPIError.invalidResponse
    }

    /// 单文件转写
    private func transcribeSingle(audioURL: URL) async throws -> [TranscriptionResult] {
        let urlString = baseURL.hasSuffix("/") ? "\(baseURL)audio/transcriptions" : "\(baseURL)/audio/transcriptions"
        guard let url = URL(string: urlString) else {
            throw WhisperAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 25MB 音频在慢速上行环境下可能超过 URLRequest 的默认等待窗口；
        // 仍保持有界，避免网络栈异常时永久占住批处理槽位。
        request.timeoutInterval = 10 * 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // 构建 multipart/form-data，写入临时文件避免内存峰值
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let tempBodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bin")
        defer { try? FileManager.default.removeItem(at: tempBodyURL) }

        try writeMultipartBody(
            to: tempBodyURL,
            boundary: boundary,
            audioURL: audioURL,
            language: language
        )

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempBodyURL)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WhisperAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw WhisperAPIError.apiError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        // 解析 verbose_json 响应
        return try parseVerboseJSON(data: data)
    }

    /// 本次分片调用的专属临时目录（**必须唯一**）。
    ///
    /// 旧实现把分片直接写成 `temporaryDirectory/chunk_<起始秒>.m4a`：云端批量转写是
    /// **3 路并发**（`RecordingViewModel` 的 maxConcurrency），两个录音的分片起始秒相同
    /// → 同名文件互相覆盖，且 A 的 `defer removeItem` 会删掉 B 正在上传的文件；
    /// 轻则报“文件不存在/导出失败”，重则**把别人的音频当成本录音的结果上传**
    /// （转写内容串台且完全无错误提示）。命名规则抽成纯函数以便回归测试。
    static func chunkScratchDirectory(
        base: URL = FileManager.default.temporaryDirectory,
        token: String = UUID().uuidString
    ) -> URL {
        base
            .appendingPathComponent("Memozia", isDirectory: true)
            .appendingPathComponent("TranscriptionChunks", isDirectory: true)
            .appendingPathComponent("Memozia-chunk-\(token)", isDirectory: true)
    }

    /// 大文件分片转写
    private func transcribeChunked(audioURL: URL) async throws -> [TranscriptionResult] {
        // 使用 AVFoundation 分割音频为 25MB 以下的片段（写入本次调用专属子目录）
        let tempDir = Self.chunkScratchDirectory()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // 子目录整体在退出时清除（单个分片的 defer 仍保留：及时释放 20MB 级中间文件）
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let asset = AVURLAsset(url: audioURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)

        // 按实际码率计算分片时长，保证单片体积在限制内（高码率音频不再固定 10 分钟）
        let fileSize = UInt64((try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let chunkDuration: TimeInterval
        if totalSeconds > 0, fileSize > 0 {
            let bytesPerSecond = Double(fileSize) / totalSeconds
            // 目标 20MB/片（留 5MB 余量），并限制在 60s~600s 区间
            let estimated = 20.0 * 1024 * 1024 / max(bytesPerSecond, 1)
            chunkDuration = min(max(estimated, 60), 600)
        } else {
            chunkDuration = 600
        }

        var allResults: [TranscriptionResult] = []
        var currentTime: TimeInterval = 0

        while currentTime < totalSeconds {
            let endTime = min(currentTime + chunkDuration, totalSeconds)

            // 导出片段（始终使用 .m4a 格式，与 exportChunk 实际输出一致）
            let chunkURL = tempDir.appendingPathComponent("chunk_\(Int(currentTime)).m4a")
            // A-1: 用 defer 注册清理，确保后续任意分支（含抛错）都能释放临时文件
            defer { try? FileManager.default.removeItem(at: chunkURL) }
            try await exportChunk(from: audioURL, to: chunkURL, startTime: currentTime, endTime: endTime)

            // 导出后校验分片体积，超过 API 限制则报错（避免上传后被拒导致整段转写失败位置难定位）
            let chunkSize = UInt64((try? chunkURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if chunkSize > maxFileSize {
                throw WhisperAPIError.chunkTooLarge(chunkSize)
            }

            // 每个分片独立重试：长录音后段的一次瞬时网络错误不应让前面已完成的
            // 多个分片全部作废。4xx 配置/配额错误仍由 transcribeWithRetry 快速失败。
            let results = try await transcribeWithRetry(audioURL: chunkURL)

            // 修正时间偏移
            let offsetResults = results.map { result -> TranscriptionResult in
                TranscriptionResult(
                    text: result.text,
                    startTime: result.startTime + currentTime,
                    endTime: result.endTime + currentTime
                )
            }
            allResults.append(contentsOf: offsetResults)

            currentTime = endTime
        }

        return allResults
    }

    /// 导出音频片段
    private func exportChunk(from inputURL: URL, to outputURL: URL, startTime: TimeInterval, endTime: TimeInterval) async throws {
        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVURLAsset(url: inputURL)
        let startCMTime = CMTime(seconds: startTime, preferredTimescale: 44100)
        let endCMTime = CMTime(seconds: endTime, preferredTimescale: 44100)
        let timeRange = CMTimeRange(start: startCMTime, end: endCMTime)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw WhisperAPIError.chunkExportFailed
        }

        exportSession.timeRange = timeRange

        try await exportSession.export(to: outputURL, as: .m4a)
    }

    /// 解析 verbose_json 格式响应
    private func parseVerboseJSON(data: Data) throws -> [TranscriptionResult] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WhisperAPIError.parseError
        }

        // 如果有 segments 字段（verbose_json 格式）
        if let segments = json["segments"] as? [[String: Any]] {
            return segments.compactMap { segment -> TranscriptionResult? in
                guard let text = segment["text"] as? String,
                      let start = segment["start"] as? TimeInterval,
                      let end = segment["end"] as? TimeInterval else {
                    return nil
                }
                return TranscriptionResult(text: text, startTime: start, endTime: end)
            }
        }

        // 降级：只有完整文本，没有时间戳
        if let text = json["text"] as? String, !text.isEmpty {
            return [TranscriptionResult(text: text, startTime: 0, endTime: 0)]
        }

        // C-7: 既没有 segments 也没有非空 text，视为解析失败，避免调用方把空结果误判为转写完成
        throw WhisperAPIError.parseError
    }

    private func mimeTypeForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "m4a":  return "audio/mp4"
        case "mp3":  return "audio/mpeg"
        case "wav":  return "audio/wav"
        default:     return "application/octet-stream"
        }
    }

    /// 将 multipart body 写入临时文件，避免将整个音频加载到内存
    private func writeMultipartBody(
        to fileURL: URL,
        boundary: String,
        audioURL: URL,
        language: String?
    ) throws {
        // FileHandle(forWritingTo:) 要求文件已存在，先创建空文件
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        defer { try? fileHandle.close() }

        func write(_ string: String) throws {
            if let data = string.data(using: .utf8) {
                try fileHandle.write(contentsOf: data)
            }
        }

        // 文件字段（流式写入，不加载整个文件到内存）
        // 转义文件名中的引号/换行，防止破坏或注入 multipart 头
        let fileName = audioURL.lastPathComponent
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        let mimeType = mimeTypeForExtension(audioURL.pathExtension)

        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        try write("Content-Type: \(mimeType)\r\n\r\n")

        // 分块读取音频文件并写入
        let audioFileHandle = try FileHandle(forReadingFrom: audioURL)
        defer { try? audioFileHandle.close() }
        while true {
            let chunk = try audioFileHandle.read(upToCount: 1024 * 1024) // 1MB chunks
            guard let chunk = chunk, !chunk.isEmpty else { break }
            try fileHandle.write(contentsOf: chunk)
        }

        try write("\r\n")

        // model 字段
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        try write("whisper-1\r\n")

        // response_format 字段
        try write("--\(boundary)\r\n")
        try write("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        try write("verbose_json\r\n")

        // language 字段
        if let lang = language, !lang.isEmpty {
            try write("--\(boundary)\r\n")
            try write("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            try write("\(lang)\r\n")
        }

        // 结束标记
        try write("--\(boundary)--\r\n")
    }
}

// MARK: - 错误类型
enum WhisperAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case parseError
    case chunkExportFailed
    case chunkTooLarge(UInt64)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "API 地址无效，请在设置中检查 Base URL 配置")
        case .invalidResponse:
            return String(localized: "服务器返回了无效的响应，请稍后重试")
        case .apiError(let code, let msg):
            switch code {
            case 401: return String(localized: "API Key 无效或已过期，请在设置中检查")
            case 403: return String(localized: "没有访问权限，请检查 API Key 权限")
            case 413: return String(localized: "音频文件过大，请使用较短的音频或本地转写")
            case 429: return String(localized: "请求过于频繁，请稍后重试")
            case 500...599: return String(format: String(localized: "服务器暂时不可用（%lld），请稍后重试"), code)
            default: return String(format: String(localized: "转写失败（错误码 %lld）：%@"), code, msg)
            }
        case .parseError:
            return String(localized: "无法解析服务器返回的数据，请稍后重试")
        case .chunkExportFailed:
            return String(localized: "音频分片处理失败，请检查音频文件是否完整")
        case .chunkTooLarge(let size):
            return String(format: String(localized: "音频分片后仍超过 API 大小限制（%lluMB），请使用本地转写"), size / (1024 * 1024))
        }
    }
}
