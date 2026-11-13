import Foundation
import os

/// 按服务端声明适配本地推理参数，不把 LM Studio 的选项发送给其他兼容服务。
struct LocalLLMCapabilities: Equatable, Sendable {
    var reasoningOffValue: String?
    var supportsJSONSchema = false

    private static let logger = Logger(subsystem: "app.memozia", category: "LocalLLMCapabilities")

    static func discover(config: LLMConfigSnapshot, session: URLSession) async throws -> Self {
        guard config.isLocal, let url = modelsURL(chatCompletionsURL: config.chatCompletionsURL) else {
            return Self()
        }
        try EndpointPolicy.validate(url.absoluteString, allowInsecureLAN: config.allowInsecureLAN)
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request, delegate: EndpointPolicy.RedirectGuard.shared)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let capabilities = parse(data: data, model: config.modelName) else {
                logger.debug("本地服务未声明当前模型能力，沿用兼容请求参数")
                return Self()
            }
            return capabilities
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // 能力探测是可选步骤；旧版 LM Studio / Ollama 没有此端点，不能阻断实际请求。
            logger.debug("本地模型能力探测不可用，沿用兼容请求参数")
            return Self()
        }
    }

    static func modelsURL(chatCompletionsURL: String) -> URL? {
        guard var components = URLComponents(string: chatCompletionsURL),
              components.path.hasSuffix("/v1/chat/completions") else { return nil }
        components.path = String(components.path.dropLast("/v1/chat/completions".count)) + "/api/v1/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// LM Studio 原生 v1 模型列表。精确匹配模型 key、量化变体或已加载实例的自定义 ID。
    /// https://lmstudio.ai/docs/developer/rest/list
    static func parse(data: Data, model: String) -> Self? {
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data),
              let entry = list.models.first(where: {
                  $0.type == "llm" && ($0.key == model || $0.selected_variant == model
                      || $0.variants?.contains(model) == true
                      || $0.loaded_instances?.contains(where: { $0.id == model }) == true)
              }) else { return nil }
        let options = entry.capabilities?.reasoning?.allowed_options ?? []
        return Self(
            // 原生 API 的公开选项叫 off；/v1/chat/completions 使用 OpenAI 枚举 none。
            // 直接发送 off 会被 LM Studio 的兼容层以 HTTP 400 拒绝。
            reasoningOffValue: options.contains("off") || options.contains("none") ? "none" : nil,
            supportsJSONSchema: entry.format == "gguf" || entry.format == "mlx"
        )
    }

    private struct ModelList: Decodable { let models: [Model] }
    private struct Model: Decodable {
        let type: String
        let key: String
        let format: String?
        let variants: [String]?
        let selected_variant: String?
        let loaded_instances: [Instance]?
        let capabilities: Capabilities?
    }
    private struct Instance: Decodable { let id: String }
    private struct Capabilities: Decodable { let reasoning: Reasoning? }
    private struct Reasoning: Decodable { let allowed_options: [String] }
}
