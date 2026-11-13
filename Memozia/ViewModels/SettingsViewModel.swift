import Foundation
import Observation
import KeychainAccess

/// 设置管理 ViewModel
@MainActor
@Observable
final class SettingsViewModel {

    // STT 配置
    /// 转写模式：Pro 与普通模式共用该偏好。macOS 26 起默认系统语音识别，
    /// 低版本回退本地 WhisperKit；已有保存值不会被覆盖（见 `loadSettings`）
    var sttMode: STTMode = STTMode.defaultMode
    /// 本地 Whisper 模型文件夹路径，默认 ~/Documents/Memozia/WhisperModel
    var whisperModelPath: String = WhisperModelFolder.defaultPath
    /// Whisper 模型下载源（HuggingFace 官方 / HF-Mirror 镜像），默认镜像
    var whisperModelSource: WhisperModelSource = WhisperModelSource.defaultValue
    var whisperAPIKey: String = ""
    var whisperBaseURL: String = "https://api.openai.com/v1"
    var whisperLanguage: String = WhisperLanguage.zh.rawValue  // 默认简体中文

    // 说话人分离（sherpa-onnx CPU 推理）
    /// 转写后是否自动区分不同说话人
    var enableSpeakerDiarization: Bool = true
    /// 说话人分离模型文件夹路径，默认 ~/Documents/Memozia/DiarizationModel
    var diarizationModelPath: String = DiarizationModelFolder.defaultPath
    /// 分离后是否自动识别已注册声纹（命中标注姓名，未命中保留“说话人 N”）
    var enableVoiceprintRecognition: Bool = true
    /// 说话人分离可用的 CPU 核心数（专业模式可调，范围见 `DiarizationThreads`）
    var diarizationThreadCount: Int = DiarizationThreads.defaultThreads
    /// 说话人区分精细度（专业模式可调，默认中间档；档位定义见 `DiarizationPrecision`）
    var diarizationPrecision: DiarizationPrecision = DiarizationPrecision.defaultValue

    // 语音解析词典
    /// 转写后是否应用词典纠正（拼音匹配 + 精确替换）
    var enableDictionaryCorrection: Bool = true

    // PII 去标识化
    /// 送云端大模型前是否对总结/待办的输入做去标识化，返回后再还原
    var enablePIIScrub: Bool = true

    // 当前选中的 LLM 配置 ID
    var activeLLMConfigID: UUID?

    // 录音配置
    var recordingSource: RecordingSource = .mixed
    var autoMuteDetection: Bool = true
    var appMuteDetection: Bool = false
    /// 普通模式只暴露会议场景，不让用户直接处理采集源组合。
    var standardRecordingMode: StandardRecordingMode = .onlineMeeting
    /// 与 Pro 转写路径分开，保证普通模式下载模型不覆盖专业配置。
    var standardWhisperModelPath: String = WhisperModelFolder.defaultPath

    /// 当前生效的数据文件夹（用于存储录音、转写、总结）
    var storageDirectoryPath: String {
        get { AudioRecording.activeStorageDirectory.path }
        set {
            // 只记为「待重启生效」，不在运行期改根（避免「双根目录」）；
            // 空串表示重置为默认路径
            if newValue.isEmpty {
                AudioRecording.setPendingStorageDirectory(AudioRecording.defaultStorageDirectory)
            } else {
                AudioRecording.setPendingStorageDirectory(URL(fileURLWithPath: newValue))
            }
        }
    }

    /// 已选择、待重启生效的数据文件夹（nil 表示没有待切换项）
    var pendingStorageDirectoryPath: String? {
        AudioRecording.pendingStorageDirectory?.path
    }

    /// 数据文件夹 URL（当前生效）
    var storageDirectoryURL: URL {
        AudioRecording.activeStorageDirectory
    }

    /// 是否在录音列表中显示隐藏的录音
    var showHiddenRecordings: Bool = false

    /// 默认提醒事项列表 ID（用户在设置中指定）
    var defaultReminderListID: String = ""

    /// 错误提示状态（供 View 绑定展示）
    var errorMessage: String?
    var showError = false

    // 持久化 Key
    private enum Keys {
        static let sttMode = "stt_mode"
        static let whisperModelPath = WhisperModelFolder.defaultsKey
        static let whisperModelSource = WhisperModelSourceStore.defaultsKey
        static let whisperBaseURL = "whisper_base_url"
        static let whisperLanguage = "whisper_language"
        static let enableSpeakerDiarization = "enable_speaker_diarization"
        static let diarizationModelPath = DiarizationModelFolder.defaultsKey
        static let enableVoiceprintRecognition = "enable_voiceprint_recognition"
        static let diarizationThreadCount = DiarizationThreads.defaultsKey
        static let diarizationPrecision = DiarizationPrecision.defaultsKey
        static let enableDictionaryCorrection = "enable_dictionary_correction"
        static let enablePIIScrub = "enable_pii_scrub"
        static let activeLLMConfigID = "active_llm_config_id"
        static let recordingSource = "recording_source"
        static let autoMuteDetection = "auto_mute_detection"
        static let appMuteDetection = "app_mute_detection"
        static let standardRecordingMode = AppExperiencePreference.standardRecordingModeKey
        static let standardWhisperModelPath = AppExperiencePreference.standardWhisperModelPathKey
        static let showHiddenRecordings = "show_hidden_recordings"
        static let defaultReminderListID = "default_reminder_list_id"
    }

    // Keychain
    private let keychain = Keychain(service: "app.memozia")
        .accessibility(.afterFirstUnlock)
    private enum KeychainKeys {
        static let whisperAPIKey = "whisper_api_key"
    }

    // UserDefaults
    private let defaults = UserDefaults.standard

    // MARK: - 初始化

    init() {
        loadSettings()
    }

    // MARK: - 读取设置

    func loadSettings() {
        // STT 设置
        if let mode = defaults.string(forKey: Keys.sttMode),
           let sttMode = STTMode(rawValue: mode) {
            self.sttMode = sttMode
        }
        if let path = defaults.string(forKey: Keys.whisperModelPath), !path.isEmpty {
            self.whisperModelPath = path
        }
        if let source = defaults.string(forKey: Keys.whisperModelSource),
           let whisperModelSource = WhisperModelSource(rawValue: source) {
            self.whisperModelSource = whisperModelSource
        }
        self.whisperBaseURL = defaults.string(forKey: Keys.whisperBaseURL) ?? "https://api.openai.com/v1"
        self.whisperLanguage = defaults.string(forKey: Keys.whisperLanguage) ?? WhisperLanguage.zh.rawValue

        // 说话人分离（开关默认开启；未下载模型时自动跳过不影响转写）
        self.enableSpeakerDiarization = defaults.object(forKey: Keys.enableSpeakerDiarization) as? Bool ?? true
        if let path = defaults.string(forKey: Keys.diarizationModelPath), !path.isEmpty {
            self.diarizationModelPath = path
        }
        // 声纹识别（开关默认开启；声纹库为空时自动跳过无开销）
        self.enableVoiceprintRecognition = defaults.object(forKey: Keys.enableVoiceprintRecognition) as? Bool ?? true
        // 分离 CPU 核心数（越界值按当前机器核心数夹到 2…核心数-1）
        self.diarizationThreadCount = DiarizationThreads.resolved
        // 精细度档位（无保存值或越界回落到中间档「标准」）
        self.diarizationPrecision = DiarizationPrecision.resolved

        // 语音解析词典
        self.enableDictionaryCorrection = defaults.object(forKey: Keys.enableDictionaryCorrection) as? Bool ?? true

        // PII 去标识化（默认开启，云端处理前脱敏）
        self.enablePIIScrub = defaults.object(forKey: Keys.enablePIIScrub) as? Bool ?? true

        // API Key 从 Keychain 读取
        self.whisperAPIKey = (try? keychain.get(KeychainKeys.whisperAPIKey)) ?? ""

        // Active LLM Config ID
        if let idStr = defaults.string(forKey: Keys.activeLLMConfigID),
           let uuid = UUID(uuidString: idStr) {
            self.activeLLMConfigID = uuid
        }

        // 录音配置
        if let source = defaults.string(forKey: Keys.recordingSource),
           let recordingSource = RecordingSource(rawValue: source) {
            self.recordingSource = recordingSource
        }
        self.autoMuteDetection = defaults.object(forKey: Keys.autoMuteDetection) as? Bool ?? true
        self.appMuteDetection = defaults.bool(forKey: Keys.appMuteDetection)
        if let raw = defaults.string(forKey: Keys.standardRecordingMode),
           let mode = StandardRecordingMode(rawValue: raw) {
            self.standardRecordingMode = mode
        }
        if let path = defaults.string(forKey: Keys.standardWhisperModelPath), !path.isEmpty {
            self.standardWhisperModelPath = path
        }

        // 隐藏录音开关
        self.showHiddenRecordings = defaults.bool(forKey: Keys.showHiddenRecordings)

        // 默认提醒事项列表
        self.defaultReminderListID = defaults.string(forKey: Keys.defaultReminderListID) ?? ""
    }

    // MARK: - 保存设置

    func saveSettings() {
        defaults.set(sttMode.rawValue, forKey: Keys.sttMode)
        defaults.set(whisperModelPath, forKey: Keys.whisperModelPath)
        defaults.set(whisperModelSource.rawValue, forKey: Keys.whisperModelSource)
        // 下载源变更立即生效：加载模型时 tokenizer 回退会读 HF_ENDPOINT，无需重启应用
        whisperModelSource.applyAsHubEnvironment()
        defaults.set(whisperBaseURL, forKey: Keys.whisperBaseURL)
        defaults.set(whisperLanguage, forKey: Keys.whisperLanguage)

        // 说话人分离
        defaults.set(enableSpeakerDiarization, forKey: Keys.enableSpeakerDiarization)
        defaults.set(diarizationModelPath, forKey: Keys.diarizationModelPath)
        defaults.set(enableVoiceprintRecognition, forKey: Keys.enableVoiceprintRecognition)
        defaults.set(DiarizationThreads.clamp(diarizationThreadCount), forKey: Keys.diarizationThreadCount)
        DiarizationPrecision.set(diarizationPrecision, in: defaults)

        // 语音解析词典
        defaults.set(enableDictionaryCorrection, forKey: Keys.enableDictionaryCorrection)

        // PII 去标识化
        defaults.set(enablePIIScrub, forKey: Keys.enablePIIScrub)

        // API Key 保存到 Keychain
        do {
            if whisperAPIKey.isEmpty {
                try keychain.remove(KeychainKeys.whisperAPIKey)
            } else {
                try keychain.set(whisperAPIKey, key: KeychainKeys.whisperAPIKey)
            }
        } catch {
            showErrorMessage(String(localized: "API Key 保存失败，请检查钥匙串访问权限后重试。"))
        }

        if let id = activeLLMConfigID {
            defaults.set(id.uuidString, forKey: Keys.activeLLMConfigID)
        }

        // 录音配置
        defaults.set(recordingSource.rawValue, forKey: Keys.recordingSource)
        defaults.set(autoMuteDetection, forKey: Keys.autoMuteDetection)
        defaults.set(appMuteDetection, forKey: Keys.appMuteDetection)
        defaults.set(standardRecordingMode.rawValue, forKey: Keys.standardRecordingMode)
        defaults.set(standardWhisperModelPath, forKey: Keys.standardWhisperModelPath)

        // 隐藏录音开关
        defaults.set(showHiddenRecordings, forKey: Keys.showHiddenRecordings)

        // 默认提醒事项列表
        defaults.set(defaultReminderListID, forKey: Keys.defaultReminderListID)
    }

    // MARK: - 安全校验

    /// Whisper Base URL 是否安全（HTTPS 或 localhost HTTP）
    var isWhisperBaseURLSecure: Bool {
        guard let url = URL(string: whisperBaseURL) else { return false }
        if url.scheme == "https" { return true }
        if url.scheme == "http" {
            let host = url.host ?? ""
            return host == "localhost" || host == "127.0.0.1" || host == "0.0.0.0"
        }
        return false
    }

    // MARK: - Recording Config 转换

    /// 从当前设置创建 RecordingConfig 实例。
    /// 「录音开始时静音麦克风」不在本 ViewModel 里镜像：它与麦克风设备选择一样由设置页
    /// `@AppStorage` 与截图会话工具栏直接读写同一份 UserDefaults，这里在启动瞬间取最新值
    func makeRecordingConfig(experience: AppExperience = .pro) -> RecordingConfig {
        let saved = RecordingConfig(
            source: recordingSource,
            autoMuteDetection: autoMuteDetection,
            appMuteDetection: appMuteDetection,
            startMuted: MicrophoneStartMutePreference.isEnabled()
        )
        return EffectiveSettingsResolver.recordingConfig(
            saved: saved,
            standardMode: standardRecordingMode,
            experience: experience
        )
    }

    // MARK: - STT Config 转换

    /// 从当前设置创建 STTConfig 实例
    func makeSTTConfig(experience: AppExperience = .pro) -> STTConfig {
        let saved = STTConfig(
            mode: sttMode,
            modelPath: whisperModelPath,
            apiKey: whisperAPIKey,
            baseURL: whisperBaseURL,
            language: whisperLanguage,
            enableSpeakerDiarization: enableSpeakerDiarization,
            diarizationModelPath: diarizationModelPath,
            enableVoiceprintRecognition: enableVoiceprintRecognition,
            enableDictionaryCorrection: enableDictionaryCorrection
        )
        return EffectiveSettingsResolver.sttConfig(
            saved: saved,
            experience: experience,
            standardModelPath: standardWhisperModelPath
        )
    }

    // MARK: - LLM Config 管理

    func getActiveLLMConfig(from configs: [LLMConfig]) -> LLMConfig? {
        guard let id = activeLLMConfigID else {
            return configs.first
        }
        // 配置被删除或恢复备份后，保存的 ID 可能已失效。
        // 普通模式没有模型选择器，因此必须稳定回退到现存的第一个配置。
        return configs.first { $0.id == id } ?? configs.first
    }

    func setActiveLLMConfig(_ config: LLMConfig) {
        activeLLMConfigID = config.id
        saveSettings()
    }

    // MARK: - 错误提示

    private func showErrorMessage(_ message: LocalizedStringResource) {
        errorMessage = String(localized: message)
        showError = true
    }

    /// 纯文本版本：已本地化或不可本地化的动态字符串
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
}
