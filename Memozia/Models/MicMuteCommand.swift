import Foundation

/// 麦克风静音命令的统一展示与可用性口径。
///
/// 「涉及麦克风选择的地方都要能静音」——录音徽章菜单（`RootView`）、菜单栏「麦克风」子菜单
/// （`MenuBarController`）都提供这条运行时命令；截图会话工具栏的麦克风菜单在录制开始前展示，
/// 因此那里提供的是同一偏好的「录音开始时静音麦克风」开关（见 `MicrophoneStartMutePreference`）。
/// 文案、图标与禁用条件集中在这里，避免同一命令在不同入口说法不一。
enum MicMuteCommand {

    /// 命令标题：未静音 → 「静音麦克风」，已静音 → 「解除静音」。
    /// 返回已本地化的字符串（`String(localized:)`），可直接交给 `NSMenuItem.title`
    /// 或 SwiftUI 的 `Label(_:systemImage:)`；不要在调用处再套 LocalizedStringKey。
    static func title(isMuted: Bool) -> String {
        isMuted ? String(localized: "解除静音") : String(localized: "静音麦克风")
    }

    /// 命令图标：未静音时用「划掉的麦克风」表示这一步会执行的动作
    static func iconName(isMuted: Bool) -> String {
        isMuted ? "mic.fill" : "mic.slash"
    }

    /// 静音是否允许本地切换：系统 / 会议软件触发的静音不能在 App 内解除
    /// （与手动按钮、菜单项的 disabled 条件同口径）
    static func canToggle(isMuted: Bool, source: MuteSource) -> Bool {
        !(isMuted && (source == .system || source == .app))
    }

    /// 已静音时的来源标签（徽章文案与菜单栏状态文案共用）
    static func sourceLabel(_ source: MuteSource) -> String {
        switch source {
        case .system: return String(localized: "系统静音")
        case .app:    return String(localized: "会议软件静音")
        case .local, .none: return String(localized: "已静音")
        }
    }

    /// 悬浮提示：说明这一步会做什么，或为什么当前不能解除
    static func helpText(isMuted: Bool, source: MuteSource) -> String {
        guard isMuted else { return String(localized: "静音麦克风") }
        switch source {
        case .system: return String(localized: "系统静音中，需在系统中解除")
        case .app:    return String(localized: "会议软件静音中，需在会议软件内解除")
        case .local, .none: return String(localized: "解除静音")
        }
    }
}
