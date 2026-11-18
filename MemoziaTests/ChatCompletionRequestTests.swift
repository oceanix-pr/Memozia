import Foundation
import ImageIO
import Synchronization
import Testing
import UniformTypeIdentifiers
@testable import Memozia

// 官方端点的夹具共用服务商域名，串行运行以隔离各次请求。
@Suite(.serialized)
@MainActor
struct ChatCompletionRequestTests {
    nonisolated private static let summary = "测试总结"
    nonisolated private static let completion = """
    data: {"choices":[{"delta":{"content":"测试总结"}}]}

    data: {"choices":[{"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    private func config(
        host: String, model: String, isLocal: Bool = false, supportsVision: Bool = false
    ) throws -> LLMConfigSnapshot {
        try LLMConfigSnapshot(config: LLMConfig(
            name: "Chat test", baseURL: "\(isLocal ? "http" : "https")://\(host)",
            modelName: model, isLocal: isLocal, supportsVision: supportsVision
        ))
    }

    @Test(arguments: ["gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-6.2-astra", "gpt-5-mini", "o4-mini"])
    func openAIReasoningModelsRunClassifierAndStreamingSummary(model: String) async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture(host: "api.openai.com") { request in
            posts.withLock { $0 += 1 }
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/chat/completions")
            let body = TodoHTTPFixture.body(request)
            #expect(body["model"] as? String == model)
            #expect(body["temperature"] == nil)
            #expect(body["max_tokens"] == nil)
            #expect(body["reasoning_effort"] == nil)
            let messages = body["messages"] as? [[String: String]]
            #expect(messages?.first?["role"] == "developer")
            if body["stream"] as? Bool == false {
                #expect(body["max_completion_tokens"] as? Int == 4_096)
                return .json(#"{"choices":[{"message":{"content":"否"},"finish_reason":"stop"}]}"#)
            }
            #expect(body["max_completion_tokens"] as? Int == 65_536)
            #expect(messages?.last?["content"]?.contains("该内容不是会议") == true)
            return .sse(Self.completion)
        }
        defer { fixture.close() }
        let result = try await LLMService.generateSummary(
            transcript: "这是一段课程的演讲转写。", config: config(host: fixture.host, model: model),
            onToken: { _ in }, session: fixture.session
        )
        #expect(result == Self.summary)
        #expect(posts.withLock { $0 } == 2)
    }

    @Test(arguments: [
        ("claude-sonnet-5-5", 4_096, 65_536, false),
        ("claude-opus-4-7", 8, 65_536, false),
        ("claude-sonnet-4-5-20250929", 8, 64_000, true)
    ])
    func anthropicAppliesSamplingAndBudgetRules(
        expected: (model: String, classifierTokens: Int, summaryTokens: Int, supportsTemperature: Bool)
    ) async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture(host: "api.anthropic.com") { request in
            posts.withLock { $0 += 1 }
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/chat/completions")
            let body = TodoHTTPFixture.body(request)
            #expect(body["model"] as? String == expected.model)
            #expect(body["max_completion_tokens"] == nil)
            #expect(body["reasoning_effort"] == nil)
            #expect(body["thinking"] == nil)
            let messages = body["messages"] as? [[String: String]]
            #expect(messages?.first?["role"] == "system")
            if body["stream"] as? Bool == false {
                #expect(body["temperature"] as? Double == (expected.supportsTemperature ? 0 : nil))
                #expect(body["max_tokens"] as? Int == expected.classifierTokens)
                return .json(#"{"choices":[{"message":{"content":"否"},"finish_reason":"stop"}]}"#)
            }
            #expect(body["temperature"] as? Double == (expected.supportsTemperature ? 0.7 : nil))
            #expect(body["max_tokens"] as? Int == expected.summaryTokens)
            #expect(messages?.last?["content"]?.contains("该内容不是会议") == true)
            return .sse(Self.completion)
        }
        defer { fixture.close() }
        let result = try await LLMService.generateSummary(
            transcript: "这是一段课程转写。", config: config(host: fixture.host, model: expected.model),
            onToken: { _ in }, session: fixture.session
        )
        #expect(result == Self.summary)
        #expect(posts.withLock { $0 } == 2)
    }

    @Test func anthropicModelListUsesVersionHeader() async throws {
        let fixture = TodoHTTPFixture(host: "api.anthropic.com") { request in
            #expect(request.httpMethod == "GET")
            #expect(request.url?.path == "/v1/models")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            return .json(#"{"data":[{"id":"claude-sonnet-5-5"}]}"#)
        }
        defer { fixture.close() }
        let preset = LLMPreset.anthropic
        #expect(preset.defaultModel == "claude-sonnet-5-5")
        #expect(preset.suggestedModels == ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5"])
        let models = try await LLMService.fetchAvailableModels(
            baseURL: preset.baseURL, apiKey: "test-key", isLocal: false, session: fixture.session
        )
        #expect(models == [preset.defaultModel])
    }

    @Test func gatewayCanNegotiateTokensTemperatureAndInstructionRole() async throws {
        let posts = Mutex(0)
        let tokens = Mutex("")
        let fixture = TodoHTTPFixture { request in
            let attempt = posts.withLock { $0 += 1; return $0 }
            let body = TodoHTTPFixture.body(request)
            switch attempt {
            case 1:
                #expect(body["max_tokens"] as? Int == 65_536)
                #expect(body["max_completion_tokens"] == nil)
                return .json(#"{"error":{"message":"Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead."}}"#, status: 400)
            case 2:
                #expect(body["max_tokens"] == nil)
                #expect(body["max_completion_tokens"] as? Int == 65_536)
                #expect(body["temperature"] as? Double == 0.7)
                return .json(#"{"error":{"code":"unsupported_value","param":"temperature","message":"Only the default value is supported."}}"#, status: 400)
            case 3:
                let messages = body["messages"] as? [[String: String]]
                #expect(messages?.first?["role"] == "system")
                return .json(#"{"error":{"code":"unsupported_value","param":"messages[0].role"}}"#, status: 400)
            default:
                #expect(body["max_completion_tokens"] as? Int == 65_536)
                #expect(body["temperature"] == nil)
                let messages = body["messages"] as? [[String: String]]
                #expect(messages?.map { $0["role"] } == ["developer", "user"])
                return .sse(Self.completion)
            }
        }
        defer { fixture.close() }
        let result = try await LLMService.generateSummary(
            transcript: "测试转写", config: config(host: fixture.host, model: "deployment-alias"),
            forceOverview: true, onToken: { value in tokens.withLock { $0 += value } }, session: fixture.session
        )
        #expect(result == Self.summary)
        #expect(tokens.withLock { $0 } == Self.summary)
        #expect(posts.withLock { $0 } == 4)
    }

    @Test func gatewayKeepsLegacyFieldWhenServerReportsSmallerOutputLimit() async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            let attempt = posts.withLock { $0 += 1; return $0 }
            let body = TodoHTTPFixture.body(request)
            #expect(body["max_completion_tokens"] == nil)
            if attempt == 1 {
                #expect(body["max_tokens"] as? Int == 65_536)
                return .json(#"{"error":{"param":"max_tokens","message":"max_tokens is too large. This model supports at most 8,192 completion tokens."}}"#, status: 400)
            }
            #expect(body["max_tokens"] as? Int == 8_192)
            return .json(#"{"choices":[{"message":{"content":"项目标题"},"finish_reason":"stop"}]}"#)
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "项目内容", config: config(host: fixture.host, model: "deployment-alias"), session: fixture.session
        )
        #expect(title == "项目标题")
        #expect(posts.withLock { $0 } == 2)
    }

    @Test func gatewayCanForwardAnthropicValidationErrorsWithoutParameterMetadata() async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { request in
            let attempt = posts.withLock { $0 += 1; return $0 }
            let body = TodoHTTPFixture.body(request)
            #expect(body["max_completion_tokens"] == nil)
            switch attempt {
            case 1:
                #expect(body["temperature"] as? Double == 0.3)
                return .json(#"{"error":{"code":"invalid_request_error","param":null,"message":"`temperature` is deprecated for this model."}}"#, status: 400)
            case 2:
                #expect(body["temperature"] == nil)
                #expect(body["max_tokens"] as? Int == 65_536)
                return .json(#"{"error":{"code":"invalid_request_error","param":null,"message":"max_tokens: 65536 > 64000, which is the maximum allowed number of output tokens"}}"#, status: 400)
            default:
                #expect(body["temperature"] == nil)
                #expect(body["max_tokens"] as? Int == 64_000)
                return .json(#"{"choices":[{"message":{"content":"项目标题"},"finish_reason":"stop"}]}"#)
            }
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "项目内容", config: config(host: fixture.host, model: "claude-alias"), session: fixture.session
        )
        #expect(title == "项目标题")
        #expect(posts.withLock { $0 } == 3)
    }

    @Test(arguments: [400, 401, 429])
    func unrelatedErrorsAreNotRetried(status: Int) async throws {
        let posts = Mutex(0)
        let fixture = TodoHTTPFixture { _ in
            posts.withLock { $0 += 1 }
            let error = status == 400
                ? #"{"error":{"code":"context_length_exceeded","message":"Prompt too long. Reduce the input or max_tokens."}}"#
                : #"{"error":{"code":"unsupported_parameter","param":"max_tokens"}}"#
            return .json(error, status: status)
        }
        defer { fixture.close() }
        do {
            _ = try await LLMService.generateSummary(
                transcript: "测试转写", config: config(host: fixture.host, model: "test-model"),
                forceOverview: true, onToken: { _ in }, session: fixture.session
            )
            Issue.record("应返回请求失败")
        } catch LLMError.apiError(let code, _) {
            #expect(code == status)
        }
        #expect(posts.withLock { $0 } == 1)
    }

    @Test func openAINonReasoningModelUsesDocumentedOutputLimit() async throws {
        let fixture = TodoHTTPFixture(host: "api.openai.com") { request in
            let body = TodoHTTPFixture.body(request)
            #expect(body["max_tokens"] == nil)
            #expect(body["max_completion_tokens"] as? Int == 16_384)
            #expect(body["temperature"] as? Double == 0.3)
            return .json(#"{"choices":[{"message":{"content":"项目标题"},"finish_reason":"stop"}]}"#)
        }
        defer { fixture.close() }
        let title = try await LLMService.generateTitle(
            from: "项目内容", config: config(host: fixture.host, model: "gpt-4o-mini"), session: fixture.session
        )
        #expect(title == "项目标题")
    }

    @Test(arguments: [false, true])
    func openAITodoRequestsKeepTimeInDeveloperMessage(isImage: Bool) async throws {
        let fixture = TodoHTTPFixture(host: "api.openai.com") { request in
            let body = TodoHTTPFixture.body(request)
            #expect(body["max_completion_tokens"] as? Int == 65_536)
            #expect(body["temperature"] == nil)
            #expect(body["stream"] as? Bool == false)
            let messages = body["messages"] as? [[String: Any]]
            #expect(messages?.first?["role"] as? String == "developer")
            #expect((messages?.first?["content"] as? String)?.contains("App 当前时间（系统时钟）") == true)
            #expect((messages?.last?["content"] is [[String: Any]]) == isImage)
            return .json(#"{"choices":[{"message":{"content":"{\"items\":[{\"title\":\"提交报告\"}]}"},"finish_reason":"stop"}]}"#)
        }
        defer { fixture.close() }
        let snapshot = try config(host: fixture.host, model: "gpt-6.1-sol", supportsVision: true)
        let result = if isImage {
            try await TodoExtractionService.extractFromImage(
                imageData: Self.jpeg(), config: snapshot, source: "test", session: fixture.session
            )
        } else {
            try await TodoExtractionService.extract(
                from: "提交报告", config: snapshot, source: "test", session: fixture.session
            )
        }
        #expect(result.items.map(\.title) == ["提交报告"])
    }

    @Test func openAIScreenshotSummaryUsesReasoningModelParameters() async throws {
        let fixture = TodoHTTPFixture(host: "api.openai.com") { request in
            let body = TodoHTTPFixture.body(request)
            #expect(body["max_completion_tokens"] as? Int == 65_536)
            #expect(body["max_tokens"] == nil)
            #expect(body["temperature"] == nil)
            #expect(body["stream"] as? Bool == true)
            let messages = body["messages"] as? [[String: Any]]
            #expect(messages?.first?["role"] as? String == "developer")
            let parts = messages?.last?["content"] as? [[String: Any]]
            #expect(parts?.last?["type"] as? String == "image_url")
            return .sse(Self.completion)
        }
        defer { fixture.close() }
        let snapshot = try config(host: fixture.host, model: "gpt-6.1-terra", supportsVision: true)
        let summary = try await LLMService.generateSummaryFromImage(
            imageData: Self.jpeg(), config: snapshot, session: fixture.session
        )
        #expect(summary == Self.summary)
    }

    @Test(arguments: [false, true])
    func visualNotesUseCorrectJPEGTypeAndOnlySendDeclaredReasoningSetting(allowedOff: Bool) async throws {
        let fixture = TodoHTTPFixture { request in
            if request.httpMethod == "GET" {
                let option = allowedOff ? "off" : "on"
                return .json(#"{"models":[{"type":"llm","key":"local-model","format":"mlx","capabilities":{"reasoning":{"allowed_options":["\#(option)"]}}}]}"#)
            }
            let body = TodoHTTPFixture.body(request)
            #expect(body["max_tokens"] as? Int == 65_536)
            #expect(body["max_completion_tokens"] == nil)
            #expect(body["reasoning_effort"] as? String == (allowedOff ? "none" : nil))
            let messages = body["messages"] as? [[String: Any]]
            let parts = messages?.last?["content"] as? [[String: Any]]
            let image = parts?.last?["image_url"] as? [String: String]
            #expect(image?["url"]?.hasPrefix("data:image/jpeg;base64,") == true)
            return .sse(Self.completion)
        }
        defer { fixture.close() }
        let result = try await LLMService.generateVisualNotes(
            frames: [VideoKeyframe(time: 10, jpegData: Self.jpeg())],
            config: config(host: fixture.host, model: "local-model", isLocal: true, supportsVision: true),
            onToken: { _ in }, session: fixture.session
        )
        #expect(result.text == Self.summary)
        #expect(result.allSegmentsCompleted)
    }

    private static func jpeg() throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
