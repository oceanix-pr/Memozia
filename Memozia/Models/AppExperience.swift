import Foundation
import Observation

/// 产品体验模式。两种模式共用同一套数据、服务和持久化格式；
/// 差异只存在于可见控制项、允许发起的动作和新任务使用的有效配置。
enum AppExperience: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case pro

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return String(localized: "普通模式")
        case .pro: return String(localized: "专业模式")
        }
    }
}

/// 普通模式使用面向场景的录音选择，避免要求用户理解音频采集源。
enum StandardRecordingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case onlineMeeting
    case inPersonMeeting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .onlineMeeting: return String(localized: "线上会议")
        case .inPersonMeeting: return String(localized: "面对面会议")
        }
    }

    var description: String {
        switch self {
        case .onlineMeeting:
            return String(localized: "同时记录自己的麦克风和电脑中的会议声音。")
        case .inPersonMeeting:
            return String(localized: "使用麦克风记录同一空间中的谈话。")
        }
    }
}

/// 高级能力统一枚举，避免在视图中散落互不一致的 `isPro` 判断。
enum AppCapability: Hashable, Sendable {
    case customSTT
    case customLLM
    case modelSelection
    case voiceprintLibrary
    case customDictionary
    case videoUnderstanding
    case screenRecording
    case advancedCapture
    case batchOperations
    case customStorage
    case advancedTodoEditing
    case advancedTranscriptEditing
    case hiddenItems
}

struct FeaturePolicy: Equatable, Sendable {
    let experience: AppExperience

    func allows(_ capability: AppCapability) -> Bool {
        switch experience {
        case .pro:
            return true
        case .standard:
            // 普通模式保留录音、转写、总结、待办、截图/OCR 等完整主链路，
            // 这里只关闭需要专业知识或会显著增加界面复杂度的控制面。
            return false
        }
    }
}

/// 模式偏好的无 UI 存取层。后台 worker、AppKit 菜单和 SwiftUI 使用同一口径。
enum AppExperiencePreference {
    static let defaultsKey = "app_experience_mode"
    static let standardRecordingModeKey = "standard_recording_mode"
    static let standardWhisperModelPathKey = "standard_whisper_model_path"

    /// 首次引入模式时，老用户保持当前完整体验；全新用户进入普通模式。
    static func resolved(in defaults: UserDefaults = .standard) -> AppExperience {
        if let raw = defaults.string(forKey: defaultsKey),
           let stored = AppExperience(rawValue: raw) {
            return stored
        }

        let migrated: AppExperience = defaults.bool(forKey: "hasCompletedOnboarding") ? .pro : .standard
        defaults.set(migrated.rawValue, forKey: defaultsKey)
        return migrated
    }

    static func set(_ experience: AppExperience, in defaults: UserDefaults = .standard) {
        defaults.set(experience.rawValue, forKey: defaultsKey)
    }
}

extension Notification.Name {
    static let appExperienceDidChange = Notification.Name("appExperienceDidChange")
}

/// UI 侧唯一可观察模式状态。写入模式不会修改任何专业设置或用户数据。
@MainActor
@Observable
final class AppExperienceStore {
    static let shared = AppExperienceStore()

    private let defaults: UserDefaults
    private(set) var current: AppExperience

    var policy: FeaturePolicy { FeaturePolicy(experience: current) }
    var isPro: Bool { current == .pro }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.current = AppExperiencePreference.resolved(in: defaults)
    }

    func set(_ experience: AppExperience) {
        guard current != experience else { return }
        current = experience
        AppExperiencePreference.set(experience, in: defaults)
        NotificationCenter.default.post(name: .appExperienceDidChange, object: experience.rawValue)
    }
}

/// 把“用户保存的专业设置”解析为“新任务实际使用的配置”。
/// 解析过程只读，不回写或清空专业设置，因此切回 Pro 后能完整恢复。
enum EffectiveSettingsResolver {
    static func sttConfig(
        saved: STTConfig,
        experience: AppExperience,
        standardModelPath: String = WhisperModelFolder.defaultPath,
        systemTranscriptionSupported: Bool = SystemTranscription.isSupported
    ) -> STTConfig {
        guard experience == .standard else { return saved }

        // 普通模式固定使用本机转写：macOS 26 起走系统语音识别（免下载、长音频），
        // 低版本回退本地 WhisperKit，保证老系统仍可转写。
        // 该开关由参数注入而非直接读系统版本，便于测试覆盖两条分支。
        let usesSystemTranscription = systemTranscriptionSupported

        return STTConfig(
            mode: usesSystemTranscription ? .system : .local,
            // 独立保存普通模式的本地模型路径，避免下载或切换模式时
            // 覆盖 Pro 中的云端/自定义转写配置。
            modelPath: standardModelPath,
            apiKey: "",
            baseURL: "https://api.openai.com/v1",
            // 系统语音识别按 locale 识别，空值即「跟随系统语言」；
            // 回退 WhisperKit 时同为空值，语义为自动检测语种。
            language: "",
            enableSpeakerDiarization: true,
            diarizationModelPath: saved.diarizationModelPath,
            enableVoiceprintRecognition: false,
            enableDictionaryCorrection: false
        )
    }

    static func recordingConfig(
        saved: RecordingConfig,
        standardMode: StandardRecordingMode,
        experience: AppExperience
    ) -> RecordingConfig {
        guard experience == .standard else { return saved }

        return RecordingConfig(
            source: standardMode == .onlineMeeting ? .mixed : .microphone,
            autoMuteDetection: true,
            appMuteDetection: false,
            // 标准模式不暴露静音策略：用户在此看不到开关，沿用专业模式留下的
            // 「开始时静音」会变成「以为在录其实没声」，一律按不静音开始
            startMuted: false,
            fileFormat: saved.fileFormat
        )
    }

    /// 普通模式始终保护云端请求；Pro 才尊重用户保存的高级开关。
    static func piiScrubEnabled(savedValue: Bool, experience: AppExperience) -> Bool {
        experience == .standard ? true : savedValue
    }

    static func screenshotMode(savedRawValue: String, experience: AppExperience) -> String {
        experience == .standard ? "region" : savedRawValue
    }
}
