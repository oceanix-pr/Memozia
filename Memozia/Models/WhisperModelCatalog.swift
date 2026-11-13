import Foundation

/// Whisper 模型下载源：HuggingFace 官方与 HF-Mirror 镜像
enum WhisperModelSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case hfMirror = "hf_mirror"
    case huggingFace = "huggingface"

    var id: String { rawValue }

    /// 默认源：镜像（国内网络可直连，官方站点常不可达）
    static let defaultValue: WhisperModelSource = .hfMirror

    var displayName: String {
        switch self {
        case .hfMirror: return String(localized: "HF-Mirror 镜像")
        case .huggingFace: return String(localized: "HuggingFace 官方")
        }
    }

    /// HubApi 端点：WhisperKit 下载显式传它，tokenizer 回退等未显式传端点的路径读 HF_ENDPOINT
    var endpoint: String {
        switch self {
        case .hfMirror: return "https://hf-mirror.com"
        case .huggingFace: return "https://huggingface.co"
        }
    }

    /// 写进程级 HF_ENDPOINT。HubApi 在**初始化时**读取该变量，因此必须在
    /// 创建 HubApi/WhisperKit 之前调用；WhisperKit 只在显式传 endpoint 的路径上绕过它
    func applyAsHubEnvironment() {
        setenv("HF_ENDPOINT", endpoint, 1)
    }
}

/// 下载源设置的持久化入口
///
/// 主应用与后台守护进程都要在**打开容器/加载模型之前**按用户选择刷新 HF_ENDPOINT，
/// 而这两处都不能依赖 MainActor 上的 SettingsViewModel，故独立出读取入口
enum WhisperModelSourceStore {
    static let defaultsKey = "whisper_model_source"

    static var current: WhisperModelSource {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let source = WhisperModelSource(rawValue: raw) else {
            return WhisperModelSource.defaultValue
        }
        return source
    }

    static func applyCurrentAsHubEnvironment() {
        current.applyAsHubEnvironment()
    }
}

/// 可下载的 Whisper 模型档位
struct WhisperModelOption: Identifiable, Hashable, Sendable {
    /// `argmaxinc/whisperkit-coreml` 仓库中的顶层目录名，必须精确匹配：
    /// WhisperKit 用 glob `*<variant>/*` 搜索，只传 "large-v3" 会同时命中
    /// large-v3 / large-v3_turbo / large-v3-v20240930 而报“Multiple models found”
    let variant: String
    /// 体积估算（仅用于界面提示）
    let approxSizeBytes: Int64

    var id: String { variant }

    /// 展示名：去掉仓库前缀，保留档位标识（模型名属专有名词，不做本地化）
    var displayName: String {
        variant.replacingOccurrences(of: "openai_whisper-", with: "")
    }

    /// 体积文本（ByteCountFormatter 按系统语言输出，无需进 String Catalog）
    var sizeText: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: approxSizeBytes)
    }

    /// 模型仓库（官方与镜像同仓库）
    static let repository = "argmaxinc/whisperkit-coreml"

    /// 多语种档位（不含 .en 英文专用与量化小体积档，应用本身支持 21 种语言）
    static let catalog: [WhisperModelOption] = [
        WhisperModelOption(variant: "openai_whisper-tiny", approxSizeBytes: 75 * 1_000_000),
        WhisperModelOption(variant: "openai_whisper-base", approxSizeBytes: 145 * 1_000_000),
        WhisperModelOption(variant: "openai_whisper-small", approxSizeBytes: 465 * 1_000_000),
        WhisperModelOption(variant: "openai_whisper-medium", approxSizeBytes: 1_500_000_000),
        WhisperModelOption(variant: "openai_whisper-large-v3_turbo", approxSizeBytes: 1_600_000_000),
        WhisperModelOption(variant: "openai_whisper-large-v3", approxSizeBytes: 3_000_000_000),
    ]

    /// 界面默认选中档位：small 在体积与中文识别质量之间较均衡
    static let defaultVariant = "openai_whisper-small"

    static func option(for variant: String) -> WhisperModelOption? {
        catalog.first { $0.variant == variant }
    }
}
