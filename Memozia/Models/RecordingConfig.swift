import Foundation

/// 录音来源
enum RecordingSource: String, Codable, CaseIterable {
    /// 仅麦克风
    case microphone = "microphone"
    /// 仅系统音频
    case systemAudio = "system"
    /// 麦克风 + 系统音频（混音）
    case mixed = "mixed"

    var displayName: String {
        switch self {
        case .microphone:   return String(localized: "仅麦克风")
        case .systemAudio:  return String(localized: "仅系统音频")
        case .mixed:        return String(localized: "麦克风 + 系统音频")
        }
    }

    var iconName: String {
        switch self {
        case .microphone:   return "mic.fill"
        case .systemAudio:  return "speaker.wave.2.fill"
        case .mixed:        return "mic.and.signal.meter.fill"
        }
    }
}

/// 离线参考回声消除偏好的无 UI 存取层。
///
/// 默认开启：混音产物里远端的话会同时出现在两条音轨上，导致转写重复与说话人误判，
/// 消除它没有副作用（失败时回退为原始音轨）。控制项只在专业模式的录音页暴露，
/// 普通模式沿用默认值。
enum EchoReductionPreference {
    static let defaultsKey = "echo_reduction_enabled"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// 「录音开始时静音麦克风」偏好的无 UI 存取层。
///
/// 与麦克风设备选择（`MicrophoneDeviceRegistry`）、录屏声源/质量同样只存 UserDefaults：
/// 设置页「录音 → 输入设备」下的开关、截图会话工具栏的麦克风菜单读写同一份偏好，
/// 开启后每次开始录音/录屏都先静音麦克风采集（录音中随时可从徽章菜单或菜单栏「麦克风」解除）。
/// 标准模式不暴露静音策略，`EffectiveSettingsResolver` 会把它强制为关闭。
enum MicrophoneStartMutePreference {
    static let defaultsKey = "microphone_start_muted"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

/// 录音配置（纯值类型，由 SettingsViewModel 通过 UserDefaults 持久化）
struct RecordingConfig: Sendable {
    /// 录音来源
    var source: RecordingSource
    /// 是否启用系统静音自动检测（检测到系统输入设备 mute 时自动暂停麦克风采集）
    var autoMuteDetection: Bool
    /// 是否启用应用层静音检测（通过 Accessibility API 检测 Teams/Zoom 等会议软件的静音状态）
    var appMuteDetection: Bool
    /// 是否在录音开始时静音麦克风采集（用户可在录音中手动解除）
    var startMuted: Bool
    /// 录音文件格式（m4a/AAC，便于转写前统一转换）
    var fileFormat: String

    init(
        source: RecordingSource = .mixed,
        autoMuteDetection: Bool = true,
        appMuteDetection: Bool = false,
        startMuted: Bool = false,
        fileFormat: String = "m4a"
    ) {
        self.source = source
        self.autoMuteDetection = autoMuteDetection
        self.appMuteDetection = appMuteDetection
        self.startMuted = startMuted
        self.fileFormat = fileFormat
    }
}
