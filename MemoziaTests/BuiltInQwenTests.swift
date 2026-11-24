import CryptoKit
import Foundation
import CoreGraphics
import ImageIO
import Network
import os
import Testing
@testable import Memozia

struct BuiltInQwenTests {
    @Test("简体中文默认镜像，其余语言使用官方源",
          arguments: [("zh-Hans", true), ("zh-Hans-CN", true), ("zh-CN", true),
                      ("zh-Hant", false), ("zh-TW", false), ("en", false), ("ja", false), ("ar", false)])
    func sourceSelection(language: String, mirror: Bool) {
        let source = BuiltInQwenModel.source(for: language)
        #expect(source == (mirror ? .hfMirror : .huggingFace))
        let url = BuiltInQwenModel.downloadURL(for: BuiltInQwenModel.files[0], source: source)
        #expect(url.host == (mirror ? "hf-mirror.com" : "huggingface.co"))
        #expect(url.path.contains(BuiltInQwenModel.revision))
    }

    @Test @MainActor
    func builtInIsSeparateFromAPIConfigurations() throws {
        let config = LLMConfig.builtInQwen
        #expect(config.id == BuiltInQwenModel.id)
        #expect(config.isBuiltIn && config.isLocal && config.supportsVision)
        #expect(config.apiKey.isEmpty)
        let snapshot = try LLMConfigSnapshot(config: config)
        #expect(snapshot.isBuiltIn && !snapshot.shouldScrubText)
        try LLMService.validateSecureURL(for: snapshot)
        // Merely naming an external service Qwen must not bypass endpoint policy.
        let remote = LLMConfig(name: "Qwen3.5-2B", baseURL: "http://api.example.com",
                               modelName: BuiltInQwenModel.repository, isLocal: true)
        let remoteSnapshot = try LLMConfigSnapshot(config: remote)
        #expect(!remoteSnapshot.isBuiltIn)
        #expect(throws: (any Error).self) { try LLMService.validateSecureURL(for: remoteSnapshot) }
    }

    @Test("新用户默认内置模型，已有服务保留优先级") @MainActor
    func resolvesBuiltInWithoutPersistingAConfiguration() {
        let settings = SettingsViewModel()
        settings.activeLLMConfigID = nil
        #expect(settings.getActiveLLMConfig(from: [])?.id == BuiltInQwenModel.id)
        let remote = LLMConfig(name: "Saved service", baseURL: "https://example.com", modelName: "saved")
        #expect(settings.getActiveLLMConfig(from: [remote])?.id == remote.id)
        settings.activeLLMConfigID = BuiltInQwenModel.id
        #expect(settings.getActiveLLMConfig(from: [remote])?.isBuiltIn == true)
        settings.activeLLMConfigID = UUID()
        #expect(settings.getActiveLLMConfig(from: [remote])?.id == remote.id)
    }

    @Test("相同长度的错误模型文件无法通过校验")
    func verifiesContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("weights")
        let content = Data("verified".utf8)
        let hash = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let file = BuiltInQwenModel.File(name: "weights", size: Int64(content.count), sha256: hash)
        try content.write(to: url)
        #expect(try BuiltInModelDownloader.verify(file, at: url))
        try Data("tampered".utf8).write(to: url)
        #expect(try !BuiltInModelDownloader.verify(file, at: url))
        #expect(!BuiltInQwenModel.isReady(at: root))
        try Data(BuiltInQwenModel.revision.utf8).write(to: root.appendingPathComponent(".ready"))
        #expect(!BuiltInQwenModel.isReady(at: root))
    }

    @Test("模型文件下载期间持续报告字节进度并保留完整文件", .timeLimit(.minutes(1)))
    func downloadReportsProgress() async throws {
        let server = try await ModelDownloadTestServer()
        defer { server.close() }
        let root = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.partial")
        let progress = OSAllocatedUnfairLock(initialState: [Int64]())

        let response = try await ModelFileDownload.download(
            from: server.url, to: destination, configuration: downloadTestConfiguration()
        ) { bytes in progress.withLock { $0.append(bytes) } }

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(try Data(contentsOf: destination) == server.payload)
        let updates = progress.withLock { $0 }
        #expect(updates.count > 1)
        #expect(updates.contains { $0 > 0 && $0 < Int64(server.payload.count) })
    }

    @Test("取消生成续传信息，重试按 Range 续传并继续更新进度", .timeLimit(.minutes(1)))
    func downloadResumesAfterCancellation() async throws {
        let server = try await ModelDownloadTestServer()
        defer { server.close() }
        let root = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.partial")
        let progress = AsyncStream<Int64>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let download = Task {
            defer { progress.continuation.finish() }
            return try await ModelFileDownload.download(
                from: server.url, to: destination, configuration: downloadTestConfiguration()
            ) { bytes in progress.continuation.yield(bytes) }
        }
        defer { download.cancel() }
        var cancelledDuringDownload = false
        for await bytes in progress.stream {
            if bytes >= 128 * 1024 && bytes < Int64(server.payload.count) {
                download.cancel()
                cancelledDuringDownload = true
                break
            }
        }
        #expect(cancelledDuringDownload)
        let error: any Error
        switch await download.result {
        case .success:
            Issue.record("取消下载后不应返回成功")
            return
        case .failure(let failure): error = failure
        }
        #expect((error as? URLError)?.code == .cancelled)
        let resumeData = try #require((error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        let resumedProgress = OSAllocatedUnfairLock(initialState: [Int64]())
        let response = try await ModelFileDownload.download(
            from: server.url, resumeData: resumeData, to: destination,
            configuration: downloadTestConfiguration()
        ) { bytes in resumedProgress.withLock { $0.append(bytes) } }

        #expect((response as? HTTPURLResponse)?.statusCode == 206)
        #expect(server.requestOffsets.contains { $0 > 0 })
        #expect(try Data(contentsOf: destination) == server.payload)
        let updates = resumedProgress.withLock { $0 }
        #expect(updates.count > 1)
        #expect(updates.contains { $0 > 0 && $0 < Int64(server.payload.count) })
    }

    @Test("已取消的下载直接返回，不创建文件", .timeLimit(.minutes(1)))
    func downloadCancelledBeforeStarting() async throws {
        let root = try downloadTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.partial")
        let download = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ModelFileDownload.download(
                from: URL(string: "http://127.0.0.1:1/model")!, to: destination,
                configuration: downloadTestConfiguration(), onProgress: { _ in }
            )
        }
        await #expect(throws: CancellationError.self) { try await download.value }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    private func downloadTestDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func downloadTestConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return configuration
    }

    @Test("本地流沿用系统解析并保留中文与结束标记")
    func localResponseLines() async throws {
        let source = "data: 中文😀\r\n\r\ndata: [DONE]\n"
        let stream = AsyncThrowingStream<UInt8, any Error> { continuation in
            for byte in source.utf8 { continuation.yield(byte) }
            continuation.finish()
        }
        var lines: [String] = []
        for try await line in ChatCompletionBytes(local: stream).lines { lines.append(line) }
        #expect(lines.filter { !$0.isEmpty } == ["data: 中文😀", "data: [DONE]"])
    }

    @Test("图片输入拒绝远端图片地址与未受限多图")
    func validatesImageInputs() throws {
        #expect(throws: BuiltInModelError.self) {
            try BuiltInQwenInference.Input(system: "test", content: [
                ["type": "image_url", "image_url": ["url": "https://example.com/image.png"]]
            ])
        }
        let part: [String: Any] = ["type": "image_url", "image_url": ["url": "data:image/png;base64,AA=="]]
        #expect(throws: BuiltInModelError.self) {
            try BuiltInQwenInference.Input(system: "test", content: [part, part])
        }
    }

    @Test("真实内置模型文字与图片推理",
          .enabled(if: ProcessInfo.processInfo.environment["MEMOZIA_VERIFY_BUILTIN_QWEN"] == "1"))
    @MainActor func actualInference() async throws {
        _ = try #require(ProcessInfo.processInfo.environment["MEMOZIA_BUILTIN_TEST_FOLDER"])
        let config = try LLMConfigSnapshot(config: .builtInQwen)
        let summary = try await LLMService.generateSummary(
            transcript: "会议决定由李明在周五完成接口测试。",
            config: config, isMeetingHint: true, onToken: { _ in }
        )
        #expect(summary.contains("李明"))
        #expect(summary.contains("测试"))

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let canvas = try #require(CGContext(
            data: nil, width: 160, height: 160, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
        let image = try #require(canvas.makeImage())
        let data = NSMutableData()
        let encoder = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        #expect(CGImageDestinationFinalize(encoder))
        let vision = try await LLMService.generateSummaryFromImage(
            imageData: data as Data, config: config, onToken: { _ in }
        )
        #expect(vision.contains("红"))

        let request = ChatCompletionRequest(
            config: config, systemPrompt: "只回答一个字：是", userContent: "请确认。",
            stream: false, temperature: 0, outputTokens: 16
        )
        let response = try await request.data(timeout: 60)
        let json = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let choices = try #require(json["choices"] as? [[String: Any]])
        let message = try #require(choices.first?["message"] as? [String: Any])
        #expect((message["content"] as? String)?.contains("是") == true)
    }
}

/// Real loopback HTTP exercises URLSession download delegate callbacks and resume
/// files, which an in-memory URLProtocol fixture cannot faithfully reproduce.
private final class ModelDownloadTestServer: Sendable {
    private struct State {
        var connections: [NWConnection] = []
        var offsets: [Int] = []
    }

    let payload = Data(repeating: 0x3D, count: 2 * 1024 * 1024)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "app.memozia.tests.model-download")
    private let listener: NWListener

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/model")! }
    var requestOffsets: [Int] { state.withLock { $0.offsets } }

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.state.withLock { $0.connections.append(connection) }
            connection.start(queue: self.queue)
            self.receiveRequest(connection)
        }
        let ready = OneShotThrowingBox<Void>()
        do {
            try await withCheckedThrowingContinuation { continuation in
                ready.attach(continuation)
                listener.stateUpdateHandler = { status in
                    switch status {
                    case .ready: ready.succeed(())
                    case .failed(let error): ready.fail(error)
                    case .cancelled: ready.fail(CancellationError())
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
        } catch {
            listener.cancel()
            throw error
        }
    }

    func close() {
        listener.cancel()
        for connection in state.withLock({ $0.connections }) { connection.cancel() }
    }

    private func receiveRequest(_ connection: NWConnection, pending: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, ended, error in
            guard error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            var request = pending
            request.append(data)
            guard request.count < 64 * 1024 else { connection.cancel(); return }
            let text = String(decoding: request, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if ended { connection.cancel() }
                else { self.receiveRequest(connection, pending: request) }
                return
            }
            let range = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("range:") }
            let offset = range.flatMap { $0.split(separator: "=").last?.split(separator: "-").first }
                .flatMap { Int($0) } ?? 0
            guard offset >= 0, offset < self.payload.count else { connection.cancel(); return }
            self.state.withLock { $0.offsets.append(offset) }
            var headers = [
                range == nil ? "HTTP/1.1 200 OK" : "HTTP/1.1 206 Partial Content",
                "Content-Length: \(self.payload.count - offset)",
                "Content-Type: application/octet-stream", "Accept-Ranges: bytes",
                "ETag: \"memozia-download-test\"", "Last-Modified: Mon, 01 Jan 2024 00:00:00 GMT",
                "Connection: close"
            ]
            if range != nil {
                headers.append("Content-Range: bytes \(offset)-\(self.payload.count - 1)/\(self.payload.count)")
            }
            let response = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
            connection.send(content: response, completion: .contentProcessed { error in
                guard error == nil else { connection.cancel(); return }
                self.sendBody(connection, offset: offset)
            })
        }
    }

    private func sendBody(_ connection: NWConnection, offset: Int) {
        guard offset < payload.count else { connection.cancel(); return }
        let end = min(offset + 64 * 1024, payload.count)
        connection.send(content: payload.subdata(in: offset..<end), completion: .contentProcessed { [self] error in
            guard error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                self.sendBody(connection, offset: end)
            }
        })
    }
}
