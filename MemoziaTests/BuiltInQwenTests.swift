import CryptoKit
import Foundation
import CoreGraphics
import ImageIO
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
