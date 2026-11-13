import Foundation
import SwiftData
// MARK: - LLM 预设类型
/// 大模型服务商预设。
///
/// 这里是「快捷添加」与「下拉选模型」的唯一事实源：新增服务商时只补一个 case
/// 与它的元数据（端点、默认模型、建议模型清单），设置页两种体验模式都自动生效。
///
/// 端点（`baseURL`）按 `LLMConfig.endpointURL(forBaseURL:appending:)` 的规则拼接：
/// 不带路径的补 `/v1`，自带版本路径的（智谱 `/api/paas/v4`、通义千问
/// `/compatible-mode/v1`）只补叶子端点，因此这里的取值要与服务商文档一致。
enum LLMPreset: String, CaseIterable, Identifiable {
    case openAI
    case anthropic
    case deepSeek
    case kimi
    case glm
    case qwen
    case miniMax
    case ollama
    case lmStudio
    case custom

    var id: String { rawValue }

    /// 展示名。品牌名不本地化：各语言下都应显示厂商原名
    var displayName: String {
        switch self {
        case .openAI:    return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .deepSeek:  return "DeepSeek 深度求索"
        case .kimi:      return "Kimi 月之暗面"
        case .glm:       return "智谱 GLM"
        case .qwen:      return "通义千问 Qwen"
        case .miniMax:   return "MiniMax"
        case .ollama:    return "Ollama"
        case .lmStudio:  return "LM Studio"
        case .custom:    return String(localized: "自定义 API")
        }
    }

    var icon: String {
        switch self {
        case .openAI, .anthropic, .deepSeek, .kimi, .glm, .qwen, .miniMax:
            return "cloud"
        case .ollama:   return "server.rack"
        case .lmStudio: return "cpu"
        case .custom:   return "gearshape"
        }
    }

    var description: String {
        switch self {
        case .openAI:    return String(localized: "云端 API，需要 API Key")
        case .anthropic: return String(localized: "云端 API，需要 API Key（OpenAI 兼容端点）")
        case .deepSeek:  return String(localized: "云端 API，需要 API Key")
        case .kimi:      return String(localized: "云端 API，需要 API Key")
        case .glm:       return String(localized: "云端 API，需要 API Key，端点路径 /api/paas/v4")
        case .qwen:      return String(localized: "云端 API，需要 API Key，端点路径 /compatible-mode/v1")
        case .miniMax:   return String(localized: "云端 API，需要 API Key")
        case .ollama:    return String(localized: "本地运行，无需 API Key，Base URL localhost:11434")
        case .lmStudio:  return String(localized: "本地运行，无需 API Key，Base URL localhost:1234")
        case .custom:    return String(localized: "配置自定义 OpenAI 兼容接口")
        }
    }

    // MARK: - 服务商元数据

    /// 端点 Base URL。代码会在其后按统一规则拼接 `/chat/completions`
    var baseURL: String {
        switch self {
        case .openAI:    return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .deepSeek:  return "https://api.deepseek.com"
        case .kimi:      return "https://api.moonshot.cn/v1"
        case .glm:       return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen:      return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .miniMax:   return "https://api.minimax.chat/v1"
        case .ollama:    return "http://localhost:11434"
        case .lmStudio:  return "http://localhost:1234"
        case .custom:    return "https://your-api.com"
        }
    }

    /// 添加时预填的模型名
    var defaultModel: String {
        switch self {
        case .openAI:    return "gpt-4o"
        case .anthropic: return "claude-sonnet-4-5"
        case .deepSeek:  return "deepseek-chat"
        case .kimi:      return "kimi-latest"
        case .glm:       return "glm-4-plus"
        case .qwen:      return "qwen-plus"
        case .miniMax:   return "MiniMax-Text-01"
        case .ollama:    return "llama3"
        case .lmStudio:  return "local-model"
        case .custom:    return "model-name"
        }
    }

    /// 下拉里的内置建议清单。服务商模型迭代快，这里只作离线兜底；
    /// 权威清单以「从服务获取模型列表」（`LLMService.fetchAvailableModels`）为准
    var suggestedModels: [String] {
        switch self {
        case .openAI:    return ["gpt-4o", "gpt-4o-mini", "gpt-4.1", "o4-mini"]
        case .anthropic: return ["claude-sonnet-4-5", "claude-opus-4-1", "claude-3-5-haiku-latest"]
        case .deepSeek:  return ["deepseek-chat", "deepseek-reasoner"]
        case .kimi:      return ["kimi-latest", "kimi-k2-0711-preview", "moonshot-v1-128k", "moonshot-v1-32k"]
        case .glm:       return ["glm-4-plus", "glm-4-air", "glm-4-flash"]
        case .qwen:      return ["qwen-max", "qwen-plus", "qwen-turbo", "qwen-long"]
        case .miniMax:   return ["MiniMax-Text-01", "abab6.5s-chat"]
        case .ollama:    return ["llama3", "qwen2.5", "gemma2", "mistral"]
        case .lmStudio:  return ["local-model"]
        case .custom:    return []
        }
    }

    /// 是否本地推理服务：决定明文 HTTP 是否放行、以及是否需要 API Key
    var isLocal: Bool {
        switch self {
        case .ollama, .lmStudio: return true
        default: return false
        }
    }

    var requiresAPIKey: Bool { !isLocal }

    /// 默认是否勾选「支持视觉（图片输入）」。
    /// 宁可默认关闭：多模态能力按模型而非按服务商区分，误开会把图片发给纯文本模型
    var supportsVisionByDefault: Bool { self == .openAI }

    /// 由已保存的 Base URL 反查服务商。
    ///
    /// 配置里只存端点与模型名，不存来源枚举，因此「下拉该给哪些模型」需要反查；
    /// 反查不到（用户改过端点）就退化为手动输入，不猜。
    static func matching(baseURL: String) -> LLMPreset? {
        guard let normalized = LLMConfig.normalizedBaseURL(baseURL)?.base.lowercased() else {
            return nil
        }
        return allCases.first { preset in
            LLMConfig.normalizedBaseURL(preset.baseURL)?.base.lowercased() == normalized
        }
    }
}
