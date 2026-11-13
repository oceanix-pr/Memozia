import Foundation
import AVFoundation

/// 包装非 Sendable 的 AVFoundation 对象，解决 Swift 6 并发安全警告
private final class AudioConversionContext: @unchecked Sendable {
    let reader: AVAssetReader
    let readerOutput: AVAssetReaderTrackOutput
    let writer: AVAssetWriter
    let writerInput: AVAssetWriterInput
    var didResume = false
    
    init(reader: AVAssetReader, readerOutput: AVAssetReaderTrackOutput, writer: AVAssetWriter, writerInput: AVAssetWriterInput) {
        self.reader = reader
        self.readerOutput = readerOutput
        self.writer = writer
        self.writerInput = writerInput
    }
}

/// 音频格式转换服务
struct AudioConverter {

    /// 支持的音频格式
    static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav"]

    /// 可导入的视频容器：导入时把音轨抽成 m4a 进入既有转写链路，
    /// 原始视频以 `{base}_video.{ext}` 留在同一文件夹（见 AudioRecording.videoFileName）
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 原始视频附件的文件名标记：磁盘扫描据此识别视频附件，
    /// 与 QuickNote 的 `source.png` 同一「文件名约定即事实」范式，不写入 meta.json
    static let videoFileNameMarker = "_video"

    /// 生成导入视频在同文件夹的留存文件名（与 `retainedVideoFileName(in:)` 对称，拆为纯函数便于测试）
    static func retainedVideoName(base: String, ext: String) -> String {
        "\(base)\(videoFileNameMarker).\(ext)"
    }

    /// 从文件夹内容识别导入时留存的原始视频附件，返回文件名（无则 nil）
    static func retainedVideoFileName(in files: [URL]) -> String? {
        files.first { file in
            videoExtensions.contains(file.pathExtension.lowercased())
                && file.deletingPathExtension().lastPathComponent.contains(videoFileNameMarker)
        }?.lastPathComponent
    }

    /// 16kHz 单声道 16-bit PCM 输出设置（Writer 和 Reader 共用）
    private static var pcm16kHzMonoSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    /// 将任意支持的音频格式转换为 16kHz 单声道 WAV
    static func convertToWAV16kHz(input inputURL: URL, output outputURL: URL? = nil) async throws -> URL {
        let outputFile = outputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        try? FileManager.default.removeItem(at: outputFile)

        let asset = AVURLAsset(url: inputURL)

        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioConverterError.noAudioTrack
        }

        do {
            try await convertWithAssetWriter(
                inputURL: inputURL,
                outputURL: outputFile,
                audioTrack: audioTrack
            )
        } catch {
            // 转换失败时清理临时文件
            try? FileManager.default.removeItem(at: outputFile)
            throw error
        }

        return outputFile
    }

    /// 获取音频时长（秒）
    static func getDuration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }

    // MARK: - 导入大文件的 I/O 执行

    /// 文件字节数（在独立 I/O 执行器上探测，避免慢速外置盘阻塞主线程）
    static func fileSize(of url: URL) async -> Int64 {
        await Task.detached(priority: .utility) { () -> Int64 in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }.value
    }

    /// 目标卷可用空间（字节）；探测失败返回 nil（在独立 I/O 执行器上探测）
    static func availableDiskBytes(at url: URL) async -> Int64? {
        await Task.detached(priority: .utility) { () -> Int64? in
            guard let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
                  let free = values[.systemFreeSize] as? NSNumber else { return nil }
            return free.int64Value
        }.value
    }

    /// 分块复制文件到独立 I/O 执行器：GB 级素材、跨磁盘、慢速外置盘不再阻塞主线程。
    ///
    /// `FileManager.copyItem` 是同步阻塞调用，即使外层方法标 `async` 也不会离开主线程。
    /// 这里改为分块读写：① 每块拷贝前检查取消，取消即清理半成品目标；② 可选进度回调，
    /// 供调用方在主线程更新进度 UI。I/O 全部发生在 detached 执行器上。
    /// - Parameters:
    ///   - source: 源文件
    ///   - destination: 目标文件（必要时覆盖已存在文件）
    ///   - onProgress: 已拷贝比例回调（0...1），在后台执行器上调用
    static func copyFileOffMain(
        from source: URL,
        to destination: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // detached 不继承调用方的取消：用受锁保护的标志把取消传进去
        let cancelled = LockedBox(false)
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try copyInChunks(from: source, to: destination, cancelled: cancelled, onProgress: onProgress)
            }.value
        } onCancel: {
            cancelled.value = true
        }
    }

    /// 分块复制实现（纯同步，运行在 I/O 执行器上）
    private static func copyInChunks(
        from source: URL,
        to destination: URL,
        cancelled: LockedBox<Bool>,
        onProgress: (@Sendable (Double) -> Void)?
    ) throws {
        let fm = FileManager.default
        let chunkSize = 4 * 1024 * 1024
        let totalBytes: Int64 = {
            guard let attrs = try? fm.attributesOfItem(atPath: source.path),
                  let size = attrs[.size] as? NSNumber else { return 0 }
            return size.int64Value
        }()

        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard let reader = try? FileHandle(forReadingFrom: source),
              let writer = try? FileHandle(forWritingTo: destination) else {
            try? fm.removeItem(at: destination)
            throw CocoaError(.fileReadNoSuchFile)
        }
        defer {
            try? reader.close()
            try? writer.close()
        }

        var copied: Int64 = 0
        while true {
            if cancelled.value {
                try? fm.removeItem(at: destination)
                throw CancellationError()
            }
            let data = try reader.read(upToCount: chunkSize) ?? Data()
            if data.isEmpty { break }
            try writer.write(contentsOf: data)
            copied += Int64(data.count)
            if totalBytes > 0 { onProgress?(Double(copied) / Double(totalBytes)) }
        }
        try writer.synchronize()
    }

    /// 抽取视频（或任何含音轨的媒体文件）的音轨，导出为 m4a（AAC）
    ///
    /// 只把音轨挂进 AVMutableComposition 再用 AppleM4A 预设导出，产物是纯音频：
    /// 下游转写（WhisperKit / Whisper API）、时长、播放、加密一律按普通 m4a 处理，
    /// 不需要为视频新增任何分支。
    ///
    /// AVAssetExportSession 有永久挂起前科（见 FileSyncService 导出看门狗注释），
    /// 因此沿用同一范式：LockedBox 收错误 + RacingWatchdog 兜超时（超时后按系统版本中止，见下文）
    /// - Parameters:
    ///   - inputURL: 源媒体文件
    ///   - outputURL: 目标 m4a 路径（已存在则先删除）
    /// - Returns: 抽取完成的 outputURL
    static func extractAudioTrack(from inputURL: URL, to outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioConverterError.noAudioTrack
        }
        let duration = try await asset.load(.duration)

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw AudioConverterError.writerSetupFailed
        }
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack,
            at: .zero
        )

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioConverterError.writerSetupFailed
        }
        // AVAssetWriter/ExportSession 均要求目标文件不存在
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // AVAssetExportSession 非 Sendable：session 仅由导出任务独占操作，
        // 错误留在 LockedBox 内交接，不跟 Task 边界传递
        nonisolated(unsafe) let session = exporter
        let errorBox = LockedBox<SentError?>(nil)
        let finished = await RacingWatchdog.race(
            name: "视频音轨抽取 \(outputURL.lastPathComponent)",
            timeout: FileSyncService.mergeExportTimeout(
                estimatedAudioDuration: max(0, CMTimeGetSeconds(duration))
            ),
            onTimeout: {
                // 超时后必须尽力中止导出：否则该导出可能继续往 outputURL 写，
                // 而调用方此后可能已删除/重建同一路径。cancelExport() 在 macOS 27
                // 被标记弃用但仍可用，故无条件调用（仅一条弃用警告）
                session.cancelExport()
            }
        ) {
            do {
                try await session.export(to: outputURL, as: .m4a)
            } catch {
                errorBox.value = SentError(error)
            }
        }
        guard finished else {
            if Task.isCancelled { throw CancellationError() }
            throw AudioConverterError.exportTimeout
        }
        if let exportError = errorBox.value {
            throw exportError.value
        }
        // 导出“没报错但产物为空”也会被当成有效录音：以时长 > 0 作为最低可用门槛
        let exportedSeconds = (try? await getDuration(of: outputURL)) ?? 0
        guard exportedSeconds > 0 else {
            throw AudioConverterError.conversionFailed("抽取结果为 0 秒音轨")
        }
        return outputURL
    }

    /// 混流：把完整混音 m4a（含麦克风）作为唯一音轨封装进视频文件，替换原音轨。
    /// 录屏停止专用：mp4 视频轨 + 录音管线合并好的混音 → 回放有声且含人声；
    /// 视频/音频样本均按原压缩格式 **passthrough 透传，不转码**（IO 速度，零质量损失）。
    ///
    /// 时间基准说明：两源各自从 0 起流，录音先于视频流启动的几十~几百 ms 真实差值
    /// 文件内不存在，mux 后表现为音频略领先画面；录屏无口型场景，工程上接受，
    /// 中断/唤醒导致的两轨内部不连续由各自分片拼接语义兜底（与纯音频条目同一机制）。
    static func embedAudio(into videoURL: URL, from audioURL: URL) async throws -> URL {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw AudioConverterError.conversionFailed("缺少视频或混音轨，无法混流")
        }
        let duration = try await videoAsset.load(.duration)
        let videoFormatHint = try await videoTrack.load(.formatDescriptions).first
        let audioFormatHint = try await audioTrack.load(.formatDescriptions).first

        let outputURL = videoURL.appendingPathExtension("muxing.mp4")
        try? FileManager.default.removeItem(at: outputURL)

        do {
            let videoReader = try AVAssetReader(asset: videoAsset)
            let audioReader = try AVAssetReader(asset: audioAsset)
            // outputSettings = nil → 压缩样本原样透传（reader/writer 两端均不解码重编）
            let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            guard videoReader.canAdd(videoOutput), audioReader.canAdd(audioOutput) else {
                throw AudioConverterError.readerSetupFailed
            }
            videoReader.add(videoOutput)
            audioReader.add(audioOutput)

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormatHint)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormatHint)
            videoInput.expectsMediaDataInRealTime = false
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
                throw AudioConverterError.writerSetupFailed
            }
            writer.add(videoInput)
            writer.add(audioInput)
            // startWriting 不抛错：失败经 status/.error 暴露
            writer.startWriting()
            guard writer.status == .writing else {
                throw AudioConverterError.conversionFailed("混流写入器启动失败：\(writer.error?.localizedDescription ?? "未知")")
            }
            writer.startSession(atSourceTime: .zero)
            guard videoReader.startReading(), audioReader.startReading() else {
                throw AudioConverterError.readerSetupFailed
            }

            // AVFoundation 管道对象非 Sendable：与 extractAudioTrack 同一交接风格，
            // 仅由 race 闭包内的任务独占操作；错误经 LockedBox 交接不跨 Task 边界传递
            nonisolated(unsafe) let vReader = videoReader
            nonisolated(unsafe) let aReader = audioReader
            nonisolated(unsafe) let vOut = videoOutput
            nonisolated(unsafe) let aOut = audioOutput
            nonisolated(unsafe) let vIn = videoInput
            nonisolated(unsafe) let aIn = audioInput
            nonisolated(unsafe) let w = writer
            let errorBox = LockedBox<SentError?>(nil)

            // passthrough 复制为纯 IO：超时按视频时长线性，上限与导出看门狗同源
            let finished = await RacingWatchdog.race(
                name: "录屏混流 \(outputURL.lastPathComponent)",
                timeout: FileSyncService.mergeExportTimeout(
                    estimatedAudioDuration: max(0, CMTimeGetSeconds(duration)) * 2
                ),
                onTimeout: {
                    if w.status == .writing { w.cancelWriting() }
                    vReader.cancelReading()
                    aReader.cancelReading()
                }
            ) {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { Self.passthroughCopy(from: vOut, reader: vReader, to: vIn, writer: w, errorBox: errorBox) }
                    group.addTask { Self.passthroughCopy(from: aOut, reader: aReader, to: aIn, writer: w, errorBox: errorBox) }
                    await group.waitForAll()
                }
                if w.status == .writing {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        w.finishWriting { continuation.resume() }
                    }
                }
            }

            guard finished else {
                if Task.isCancelled { throw CancellationError() }
                throw AudioConverterError.exportTimeout
            }
            if let boxed = errorBox.value {
                throw AudioConverterError.conversionFailed(boxed.value.localizedDescription)
            }
            guard w.status == .completed else {
                throw AudioConverterError.conversionFailed(w.error?.localizedDescription ?? "写入器异常结束")
            }
            let muxedSeconds = (try? await getDuration(of: outputURL)) ?? 0
            guard muxedSeconds > 0 else {
                throw AudioConverterError.conversionFailed("混流产物为 0 秒")
            }

            // 同目录临时文件 → 原子替换原路径，条目/扫描识别约定（{base}_video.mp4）不变
            try FileManager.default.removeItem(at: videoURL)
            try FileManager.default.moveItem(at: outputURL, to: videoURL)
            return videoURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// passthrough 样本拷贝：writer 背压 1ms 轮询等待，响应任务取消；
    /// reader 失败/append 失败写入 errorBox（首错保留）后中断本轨拷贝
    private nonisolated static func passthroughCopy(
        from output: AVAssetReaderTrackOutput,
        reader: AVAssetReader,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        errorBox: LockedBox<SentError?>
    ) {
        while reader.status == .reading {
            if Task.isCancelled {
                input.markAsFinished()
                reader.cancelReading()
                return
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            while !input.isReadyForMoreMediaData {
                if Task.isCancelled { break }
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !input.append(sample) {
                if errorBox.value == nil, let error = writer.error ?? reader.error {
                    errorBox.value = SentError(error)
                }
                input.markAsFinished()
                reader.cancelReading()
                return
            }
        }
        if reader.status == .failed, errorBox.value == nil, let error = reader.error {
            errorBox.value = SentError(error)
        }
        input.markAsFinished()
    }

    /// 使用 AVAssetWriter 进行精确的 PCM 转换
    private static func convertWithAssetWriter(
        inputURL: URL,
        outputURL: URL,
        audioTrack: AVAssetTrack
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        let reader = try AVAssetReader(asset: asset)

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm16kHzMonoSettings)
        guard reader.canAdd(readerOutput) else {
            throw AudioConverterError.readerSetupFailed
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm16kHzMonoSettings)

        guard writer.canAdd(writerInput) else {
            throw AudioConverterError.writerSetupFailed
        }

        if #available(macOS 26.0, iOS 26.0, *) {
            try await convertWithModernAssetWriter(
                reader: reader,
                readerOutput: readerOutput,
                writer: writer,
                writerInput: writerInput
            )
        } else {
            try await convertWithLegacyAssetWriter(
                reader: reader,
                readerOutput: readerOutput,
                writer: writer,
                writerInput: writerInput
            )
        }
    }

    /// macOS/iOS 26 起的并发 Reader/Writer 管线。
    /// Provider/Receiver 在创建时完成挂载，避免 macOS 27 已弃用的 add/copy/append API。
    @available(macOS 26.0, iOS 26.0, *)
    private static func convertWithModernAssetWriter(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async throws {
        let provider = reader.outputProvider(for: readerOutput)
        let receiver = writer.inputReceiver(for: writerInput)
        var receiverFinished = false

        do {
            try reader.start()
            try writer.start()
            writer.startSession(atSourceTime: .zero)

            while let sampleBuffer = try await provider.next() {
                try Task.checkCancellation()
                try await receiver.append(sampleBuffer)
            }
            receiver.finish()
            receiverFinished = true
            await writer.finishWriting()

            if reader.status == .failed {
                throw AudioConverterError.conversionFailed(
                    reader.error?.localizedDescription ?? String(localized: "读取音频失败")
                )
            }
            if writer.status == .failed {
                throw AudioConverterError.conversionFailed(
                    writer.error?.localizedDescription ?? String(localized: "写入音频失败")
                )
            }
        } catch {
            if !receiverFinished {
                receiver.finish()
            }
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
    }

    /// 兼容 macOS 15–25 / iOS 18–25。把旧 API 隔离在其有效系统范围内，
    /// 让 macOS 27 SDK 构建不会把兼容分支报告为弃用调用。
    @available(macOS, deprecated: 27.0)
    @available(iOS, deprecated: 27.0)
    private static func convertWithLegacyAssetWriter(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderTrackOutput,
        writer: AVAssetWriter,
        writerInput: AVAssetWriterInput
    ) async throws {
        reader.add(readerOutput)
        writer.add(writerInput)

        guard reader.startReading() else {
            throw AudioConverterError.conversionFailed(
                reader.error?.localizedDescription ?? String(localized: "读取音频失败")
            )
        }
        guard writer.startWriting() else {
            throw AudioConverterError.conversionFailed(
                writer.error?.localizedDescription ?? String(localized: "写入音频失败")
            )
        }
        writer.startSession(atSourceTime: .zero)

        // 包装为 @unchecked Sendable 以避免 Swift 6 并发警告
        let ctx = AudioConversionContext(reader: reader, readerOutput: readerOutput, writer: writer, writerInput: writerInput)

        // 使用 continuation 等待写入完成，确保所有路径都能 resume
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "app.memozia.audioconverter")

            ctx.writerInput.requestMediaDataWhenReady(on: queue) {
                while ctx.writerInput.isReadyForMoreMediaData {
                    if ctx.reader.status == .reading,
                       let sampleBuffer = ctx.readerOutput.copyNextSampleBuffer() {
                        guard ctx.writerInput.append(sampleBuffer) else {
                            ctx.writerInput.markAsFinished()
                            ctx.writer.cancelWriting()
                            if !ctx.didResume {
                                ctx.didResume = true
                                continuation.resume(throwing: AudioConverterError.conversionFailed(
                                    ctx.writer.error?.localizedDescription ?? String(localized: "写入音频失败")
                                ))
                            }
                            return
                        }
                    } else {
                        // 所有非 reading 状态（包括 failed）都走这里
                        ctx.writerInput.markAsFinished()

                        // 如果 reader 出错，取消 writer
                        if ctx.reader.status == .failed {
                            ctx.writer.cancelWriting()
                            if !ctx.didResume {
                                ctx.didResume = true
                                continuation.resume(throwing: AudioConverterError.conversionFailed(
                                    ctx.reader.error?.localizedDescription ?? String(localized: "读取音频失败")
                                ))
                            }
                            return
                        }

                        ctx.writer.finishWriting {
                            if !ctx.didResume {
                                ctx.didResume = true
                                if ctx.writer.status == .failed {
                                    continuation.resume(throwing: AudioConverterError.conversionFailed(
                                        ctx.writer.error?.localizedDescription ?? String(localized: "写入音频失败")
                                    ))
                                } else {
                                    continuation.resume()
                                }
                            }
                        }
                        return
                    }
                }
            }
        }
    }
}

// MARK: - 错误类型
enum AudioConverterError: LocalizedError {
    case noAudioTrack
    case readerSetupFailed
    case writerSetupFailed
    case conversionFailed(String)
    case exportTimeout

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return String(localized: "未找到音频轨道")
        case .readerSetupFailed: return String(localized: "音频读取器设置失败")
        case .writerSetupFailed: return String(localized: "音频写入器设置失败")
        case .conversionFailed(let msg):
            return String(format: String(localized: "音频转换失败：%@"), msg)
        case .exportTimeout:
            return String(localized: "视频音轨抽取超时（导出器无响应），请重试或改用较短的视频")
        }
    }
}
