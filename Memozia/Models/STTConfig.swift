import Foundation

/// STT 模式
enum STTMode: String, Codable, CaseIterable {
    case local = "local"
    case cloud = "cloud"
    /// 系统语音识别（SpeechAnalyzer / SpeechTranscriber）：纯本地推理，
    /// 模型由系统经 AssetInventory 管理，仅 macOS 26 起可用
    case system = "system"

    var displayName: String {
        switch self {
        case .local: return String(localized: "本地 WhisperKit")
        case .cloud: return String(localized: "OpenAI Whisper API")
        case .system: return String(localized: "系统语音识别")
        }
    }

    /// 默认转写模式：macOS 26 起系统语音识别是默认且首选的本机引擎；
    /// 低版本回退本地 WhisperKit（系统语音识别在该版本不可用）。
    /// 仅在用户从未保存过该偏好时生效，已有选择不会被覆盖（见 `SettingsViewModel.loadSettings`）
    static var defaultMode: STTMode {
        SystemTranscription.isSupported ? .system : .local
    }

    /// 可作为新选择提供的模式，**按界面展示顺序**排列。
    /// - 系统语音识别（macOS 26+）排在本地 WhisperKit 之前
    /// - OpenAI Whisper API 已隐藏，不作为新选择提供
    static var selectableCases: [STTMode] {
        var modes: [STTMode] = []
        if SystemTranscription.isSupported {
            modes.append(.system)
        }
        modes.append(.local)
        return modes
    }

    /// 选择器实际展示的模式列表。
    ///
    /// 已保存的模式若已被隐藏（典型情况：用户此前选的是 OpenAI Whisper API），
    /// 仍然补入列表，否则会出现「选择器里没有对应项」的悬空选中态，
    /// 用户既看不出当前处于哪种模式，也无法从界面上理解为何配置项还在。
    static func pickerModes(current: STTMode) -> [STTMode] {
        var modes = selectableCases
        if !modes.contains(current) {
            modes.insert(current, at: 0)
        }
        return modes
    }
}

/// Whisper 模型文件夹默认路径
enum WhisperModelFolder {
    /// 模型文件夹路径的持久化键（设置页写入；引导页等非 MainActor 场景读同一键）
    static let defaultsKey = "whisper_model_path"

    /// 默认模型文件夹路径：macOS 为 ~/Documents/Memozia/WhisperModel，
    /// iOS 为沙盒 Documents/Memozia/WhisperModel（homeDirectoryForCurrentUser 在 iOS 不可用）
    static var defaultPath: String {
        #if os(macOS)
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        */
        #endif
        return base
            .appendingPathComponent("Memozia")
            .appendingPathComponent("WhisperModel")
            .path
    }

    /// 当前生效路径：设置覆盖优先（空串视为未设置），否则默认目录
    static var resolvedPath: String {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey), !stored.isEmpty else {
            return defaultPath
        }
        return stored
    }
}

/// 支持的语言列表
enum WhisperLanguage: String, Codable, CaseIterable, Identifiable {
    case auto = ""           // 自动检测
    case zh = "zh"            // 中文（简体）
    case zhYue = "zh-Yue"     // 中文（繁體）
    case en = "en"            // 英文
    case ja = "ja"            // 日文
    case ko = "ko"            // 韩文
    case fr = "fr"            // 法文
    case de = "de"            // 德文
    case es = "es"            // 西班牙文
    case it = "it"            // 意大利文
    case pt = "pt"            // 葡萄牙文
    case ru = "ru"            // 俄文
    case ar = "ar"            // 阿拉伯文
    case hi = "hi"            // 印地文
    case th = "th"            // 泰文
    case vi = "vi"            // 越南文
    case id = "id"            // 印尼文
    case tr = "tr"            // 土耳其文
    case nl = "nl"            // 荷兰文
    case pl = "pl"            // 波兰文
    case uk = "uk"            // 乌克兰文
    case sv = "sv"            // 瑞典文

    var id: String { rawValue }

    var displayName: String {
        // 各语言自称（English/日本語…）是有意不本地化的；但「自动检测」与两个中文项
        // 是描述性文案，需本地化，否则 21 种语言界面下恒显示中文
        switch self {
        case .auto: return String(localized: "自动检测")
        case .zh:   return String(localized: "中文（简体）")
        case .zhYue: return String(localized: "中文（繁體）")
        case .en:   return "English"
        case .ja:   return "日本語"
        case .ko:   return "한국어"
        case .fr:   return "Français"
        case .de:   return "Deutsch"
        case .es:   return "Español"
        case .it:   return "Italiano"
        case .pt:   return "Português"
        case .ru:   return "Русский"
        case .ar:   return "العربية"
        case .hi:   return "हिन्दी"
        case .th:   return "ไทย"
        case .vi:   return "Tiếng Việt"
        case .id:   return "Indonesia"
        case .tr:   return "Türkçe"
        case .nl:   return "Nederlands"
        case .pl:   return "Polski"
        case .uk:   return "Українська"
        case .sv:   return "Svenska"
        }
    }
}

/// STT 配置（纯值类型，由 SettingsViewModel 通过 UserDefaults/Keychain 持久化）
struct STTConfig: Sendable {
    var mode: STTMode
    /// 本地 Whisper 模型文件夹路径（内含完整模型文件或单个模型子文件夹）
    var modelPath: String
    var apiKey: String
    var baseURL: String
    var language: String
    /// 转写后是否执行说话人分离（sherpa-onnx CPU 推理，失败不影响转写）
    var enableSpeakerDiarization: Bool
    /// 说话人分离模型文件夹路径（内含 segmentation.onnx 与 embedding.onnx）
    var diarizationModelPath: String
    /// 分离后是否与声纹库比对，命中的说话人自动标注为注册姓名
    var enableVoiceprintRecognition: Bool
    /// 转写后是否应用语音解析词典纠正（拼音匹配 + 精确替换）
    var enableDictionaryCorrection: Bool

    /// 送入 Whisper/API 的语言代码（与设置值解耦）
    ///
    /// `zh-Yue` 是应用内部的设置值（兼作繁简转换方向标识），
    /// 但 Whisper tokenizer 与 OpenAI API 均不认识该代码：
    /// - 云端 API 会返回 400 导致转写失败
    /// - 本地 WhisperKit 找不到 `<|zh-Yue|>` token，静默回退英语
    /// 因此在送入转写引擎前统一映射为 Whisper 支持的粤语代码 `yue`；
    /// 繁简归一化仍使用原始设置值，不受此映射影响。
    static func whisperLanguageCode(_ language: String) -> String {
        language == WhisperLanguage.zhYue.rawValue ? "yue" : language
    }

    /// 送入系统语音识别（SpeechAnalyzer）的 locale 标识。
    ///
    /// 系统语音识别没有「自动语种检测」，必须显式给出 locale：
    /// - 空串（普通模式与 Whisper 的「自动检测」共用该值）→ 返回 nil，由调用方使用系统语言
    /// - 粤语：系统无 `yue` 模型，退化为简体中文识别；原始设置值仍用于繁简归一化，不受影响
    /// - 其余语言直接使用自身代码，由 `SpeechTranscriber.supportedLocale(equivalentTo:)` 匹配
    static func systemLocaleIdentifier(forLanguage language: String) -> String? {
        guard !language.isEmpty else { return nil }
        switch language {
        case WhisperLanguage.zh.rawValue, WhisperLanguage.zhYue.rawValue, "yue":
            return "zh_CN"
        default:
            return language
        }
    }

    init(
        mode: STTMode = .local,
        modelPath: String = WhisperModelFolder.defaultPath,
        apiKey: String = "",
        baseURL: String = "https://api.openai.com/v1",
        language: String = "",
        enableSpeakerDiarization: Bool = true,
        diarizationModelPath: String = DiarizationModelFolder.defaultPath,
        enableVoiceprintRecognition: Bool = true,
        enableDictionaryCorrection: Bool = true
    ) {
        self.mode = mode
        self.modelPath = modelPath
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.language = language
        self.enableSpeakerDiarization = enableSpeakerDiarization
        self.diarizationModelPath = diarizationModelPath
        self.enableVoiceprintRecognition = enableVoiceprintRecognition
        self.enableDictionaryCorrection = enableDictionaryCorrection
    }
}
