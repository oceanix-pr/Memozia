import Foundation
import os

/// 统一构建 Chat Completions 请求，兼容 OpenAI 官方接口和仅支持旧参数的网关。
struct ChatCompletionRequest {
    let config: LLMConfigSnapshot
    var systemPrompt: String
    let userContent: Any
    let stream: Bool
    let temperature: Double
    // 本地推理和云端长文本请求沿用原有预算。已知模型的输出上限在发送前应用。
    var outputTokens = 65_536
    var reasoningOutputTokens: Int?
    var reasoningEffort: String?
    var responseFormat: [String: Any]?
    var includeUsage = false

    private static let logger = Logger(subsystem: "app.memozia", category: "LLM")

    func data(
        timeout: TimeInterval, session: URLSession = .shared, promptSuffix: () -> String = { "" }
    ) async throws -> Data {
        let (data, _) = try await send(timeout: timeout, promptSuffix: promptSuffix) { request in
            try await session.data(for: request, delegate: EndpointPolicy.RedirectGuard.shared)
        } readError: { data in
            String(decoding: data, as: UTF8.self)
        }
        return data
    }

    func bytes(
        timeout: TimeInterval, session: URLSession = .shared, promptSuffix: () -> String = { "" }
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await send(timeout: timeout, promptSuffix: promptSuffix) { request in
            try await session.bytes(for: request, delegate: EndpointPolicy.RedirectGuard.shared)
        } readError: { bytes in
            var message = ""
            for try await line in bytes.lines { message += line }
            return message
        }
    }

    private func send<Payload>(
        timeout: TimeInterval,
        promptSuffix: () -> String,
        perform: (URLRequest) async throws -> (Payload, URLResponse),
        readError: (Payload) async throws -> String
    ) async throws -> (Payload, HTTPURLResponse) {
        guard let url = URL(string: config.chatCompletionsURL) else { throw LLMError.invalidURL }
        try LLMService.validateSecureURL(for: config)

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let host = url.host?.lowercased()
        let isOpenAI = host == "api.openai.com"
        let isAnthropic = host == "api.anthropic.com"
        let model = Self.baseModelName(config.modelName)
        let isOpenAIReasoning = model == "chat-latest"
            || model.firstMatch(of: /^(gpt-[56]|o[134])([.-]|$)/) != nil
        let claudeDefaultsToThinking = isAnthropic && (model == "claude-mythos-preview"
            || model.firstMatch(of: /^claude-[a-z]+-[5-9](-|$)/) != nil)
        let useDeveloperRole = isOpenAI && isOpenAIReasoning
        let claudeRestrictsTemperature = claudeDefaultsToThinking || (isAnthropic
            && model.firstMatch(of: /^claude-[a-z]+-4-[7-9](-|$)/) != nil)
        let requestedTokens = (isOpenAIReasoning || claudeDefaultsToThinking)
            ? reasoningOutputTokens ?? outputTokens : outputTokens
        let modelLimit: Int? = switch host {
        case "api.openai.com": Self.openAIOutputLimit(model)
        case "api.anthropic.com": Self.anthropicOutputLimit(model)
        default: nil
        }
        var tokenBudget = min(requestedTokens, modelLimit ?? requestedTokens)
        var tokenField = isOpenAI ? "max_completion_tokens" : "max_tokens"
        var didSwitchTokenField = false
        var instructionRole = useDeveloperRole ? "developer" : "system"
        var body: [String: Any] = ["model": config.modelName, "stream": stream]
        if !useDeveloperRole && !claudeRestrictsTemperature { body["temperature"] = temperature }
        body["reasoning_effort"] = reasoningEffort
        body["response_format"] = responseFormat
        if stream, includeUsage { body["stream_options"] = ["include_usage": true] }

        // 只在服务明确拒绝已发送的参数时协商，且在消费任何成功响应之前完成。
        let maxAdjustments = 4
        for adjustment in 0...maxAdjustments {
            try Task.checkCancellation()
            body[tokenField] = tokenBudget
            body["messages"] = [
                ["role": instructionRole, "content": systemPrompt + promptSuffix()],
                ["role": "user", "content": userContent]
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (payload, response) = try await perform(request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
            if http.statusCode == 200 { return (payload, http) }

            let raw = try await readError(payload)
            let error = LLMError.apiError(statusCode: http.statusCode, message: raw)
            guard adjustment < maxAdjustments, [400, 422].contains(http.statusCode) else { throw error }
            let rejection = ParameterRejection(raw)
            let rejectedField = rejection.unsupportedField
            let alternateTokenField = tokenField == "max_tokens" ? "max_completion_tokens" : "max_tokens"
            if let limit = rejection.upperLimit(for: tokenField), limit < tokenBudget {
                tokenBudget = limit
            } else if rejectedField == tokenField, !didSwitchTokenField,
                      !rejection.rejectsValue || rejection.message.contains(alternateTokenField) {
                body.removeValue(forKey: tokenField)
                tokenField = alternateTokenField
                didSwitchTokenField = true
                if tokenField == "max_completion_tokens" {
                    // 转发端点可能使用模型别名。分类请求需要给推理预留预算。
                    tokenBudget = max(tokenBudget, reasoningOutputTokens ?? tokenBudget)
                    tokenBudget = min(tokenBudget, Self.openAIOutputLimit(model) ?? tokenBudget)
                }
            } else if rejectedField == "messages[0].role", instructionRole == "system" {
                instructionRole = "developer"
            } else if let field = rejectedField,
                      ["temperature", "reasoning_effort", "stream_options"].contains(field),
                      body[field] != nil {
                // 这些参数是可选的，省略后由服务选择默认值。
                body.removeValue(forKey: field)
            } else {
                throw error
            }
            Self.logger.debug("Chat Completions 参数被服务拒绝，调整后重试")
        }
        throw LLMError.invalidResponse
    }

    private static func baseModelName(_ model: String) -> String {
        let name = model.lowercased()
        if name.hasPrefix("ft:"), let base = name.split(separator: ":").dropFirst().first {
            return String(base)
        }
        return name
    }

    /// https://developers.openai.com/api/docs/models
    private static func openAIOutputLimit(_ model: String) -> Int? {
        if model.hasPrefix("gpt-4.1") { return 32_768 }
        if model.hasPrefix("gpt-4o") || model == "chatgpt-4o-latest"
            || (model.hasPrefix("gpt-5") && model.hasSuffix("-chat-latest")) { return 16_384 }
        if model == "gpt-4" || model.hasPrefix("gpt-4-") || model.hasPrefix("gpt-3.5-turbo") {
            return 4_096
        }
        return nil
    }

    /// https://platform.claude.com/docs/en/models/overview
    private static func anthropicOutputLimit(_ model: String) -> Int? {
        model.firstMatch(of: /^claude-(sonnet|opus|haiku)-4-5(-|$)/) == nil ? nil : 64_000
    }

    private struct ParameterRejection {
        let code: String?
        let parameter: String?
        let message: String

        init(_ raw: String) {
            let json = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any]
            let error = json?["error"] as? [String: Any]
            code = error?["code"] as? String
            parameter = error?["param"] as? String
            message = (error?["message"] as? String ?? raw)
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var rejectsValue: Bool { code == "unsupported_value" || message.hasPrefix("unsupported value:") }

        var unsupportedField: String? {
            if let parameter, let code, ["unsupported_parameter", "unsupported_value", "unknown_parameter"].contains(code) {
                return parameter
            }
            if message.firstMatch(of: /^`?temperature`? is (?:deprecated|not supported) for this model/) != nil {
                return "temperature"
            }
            let match = message.firstMatch(of: /^(?:unsupported parameter|unsupported value|unknown parameter|unrecognized request argument supplied):\s*['"]?([a-z][a-z0-9_.\[\]]*)/)
            return match.map { String($0.1) }
        }

        func upperLimit(for field: String) -> Int? {
            let maximum: Substring?
            if message.hasPrefix("\(field):"),
               let match = message.firstMatch(of: /:\s*[0-9,]+\s*>\s*([0-9,]+), which is the maximum allowed number of output tokens/) {
                maximum = match.1
            } else if parameter == field || message.hasPrefix("\(field) is too large")
                        || message.hasPrefix("\(field) must be between") {
                maximum = message.firstMatch(of: /(?:supports at most|must be between 1 and)\s+([0-9,]+)/)?.1
            } else {
                return nil
            }
            guard let digits = maximum,
                  let limit = Int(digits.replacingOccurrences(of: ",", with: "")), limit > 0 else { return nil }
            return limit
        }
    }
}
