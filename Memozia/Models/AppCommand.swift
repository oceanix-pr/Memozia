import Foundation
import SwiftUI

/// 应用命令的统一描述模型。
///
/// 解决的问题：同一条命令的名称与快捷键此前散落在四处——菜单栏状态项菜单
/// （`MenuBarController`）、应用菜单（`MemoziaApp.commands`）、帮助页「快捷键」小节
/// （`HelpView`）与设置页（热键页 / 设置搜索）。任一处改名或改快捷键，其余三处不会跟随，
/// 于是出现「菜单里叫 A、帮助里叫 B、设置里显示的组合键早就被改掉了」这类不一致。
///
/// 这里把「id / 本地化标题键 / 当前快捷键 / 对应设置页」收敛成一份描述：
/// - 名称：所有界面都从 `titleKey` 取，不再各自写字符串
/// - 快捷键：全局热键类命令的显示值**实时**读取 `GlobalHotkeyManager`，
///   因此设置页改完立刻在帮助页/设置搜索里同步（不会出现写死的旧组合键）
/// - 设置页：`settingsDestination` 供设置搜索直接跳到相关页面

// MARK: - 命令标识

/// 命令稳定标识（与本地化文案、快捷键组合解耦）
enum AppCommandID: String, CaseIterable, Hashable, Sendable {
    /// 开始 / 停止会议录音（全局热键，默认 ⌃⌘R）
    case toggleRecording
    /// 截图会话（全局热键，默认 ⌃⌘S）
    case captureScreenshot
    /// 全屏直拍入库（全局热键，默认 ⌃⌘W）
    case captureFullScreenDirect
    /// 新建快捷笔记面板（应用菜单 ⌘N）
    case newQuickNote
    /// 从剪贴板新建笔记（菜单栏）
    case newQuickNoteFromClipboard
    /// 导入音频或视频（应用菜单 ⌘O）
    case importMedia
    /// 新建区域截图（应用菜单 ⌃⌘S）
    case captureRegion
    /// 截取窗口（应用菜单）
    case captureWindow
    /// 截取全屏（应用菜单）
    case captureFullScreen
    /// 打开设置（⌘,）
    case openSettings
    /// 打开帮助（⌘?）
    case openHelp
}

// MARK: - 快捷键

/// 命令快捷键：区分「应用内固定组合」与「用户可改的全局热键」。
///
/// 全局热键的显示值必须实时读管理器，不能在描述里写死——否则用户改完热键，
/// 帮助页与设置搜索仍显示旧组合键（正是本次要消除的不一致）。
enum CommandShortcut: Hashable, Sendable {
    /// 无快捷键
    case none
    /// ⌘ + 字母（如 ⌘N / ⌘O / ⌘, / ⌘?）
    case command(Character)
    /// ⌃⌘ + 字母（如应用菜单的区域截图 ⌃⌘S）
    case commandControl(Character)
    /// 全局录音热键（⌃⌘R，可在设置 → 热键修改）
    case globalRecordingHotkey
    /// 全局截图热键（⌃⌘S，可在设置 → 热键修改）
    case globalScreenshotHotkey
    /// 全局全屏直拍热键（⌃⌘W，可在设置 → 热键修改）
    case globalFullScreenHotkey

    /// 应用菜单使用的固定组合（全局热键不走菜单快捷键，返回 nil）
    var keyEquivalent: (key: Character, modifiers: EventModifiers)? {
        switch self {
        case .command(let key):                 return (key, .command)
        case .commandControl(let key):          return (key, [.command, .control])
        case .none, .globalRecordingHotkey, .globalScreenshotHotkey, .globalFullScreenHotkey:
            return nil
        }
    }

    /// 是否为「用户可在设置 → 热键中修改」的全局热键
    var isGlobalHotkey: Bool {
        switch self {
        case .globalRecordingHotkey, .globalScreenshotHotkey, .globalFullScreenHotkey: return true
        case .none, .command, .commandControl: return false
        }
    }

    /// 当前生效的快捷键显示串（如 "⌃⌘R"）；无快捷键时为 nil。
    ///
    /// 全局热键读取 `GlobalHotkeyManager` 的实时值（含录音热键被占用后的自动回退组合），
    /// 因此菜单栏、帮助页、设置搜索显示的一定是「现在真正生效」的组合键。
    @MainActor
    var display: String? {
        switch self {
        case .none:
            return nil
        case .command(let key), .commandControl(let key):
            let symbol: String
            switch self {
            case .commandControl: symbol = "⌃⌘"
            default:              symbol = "⌘"
            }
            return symbol + String(key).uppercased()
        #if os(macOS)
        case .globalRecordingHotkey:
            let manager = GlobalHotkeyManager.shared
            return HotkeyFormatter.displayString(
                keyCode: manager.recordingKeyCode,
                carbonModifiers: manager.recordingModifiers
            )
        case .globalScreenshotHotkey:
            let manager = GlobalHotkeyManager.shared
            return HotkeyFormatter.displayString(
                keyCode: manager.keyCode,
                carbonModifiers: manager.modifiers
            )
        case .globalFullScreenHotkey:
            let manager = GlobalHotkeyManager.shared
            return HotkeyFormatter.displayString(
                keyCode: manager.fullscreenKeyCode,
                carbonModifiers: manager.fullscreenModifiers
            )
        #else
        case .globalRecordingHotkey, .globalScreenshotHotkey, .globalFullScreenHotkey:
            return nil
        #endif
        }
    }
}

// MARK: - 设置页去向

/// 命令相关设置所在页面。`rawValue` 与 `SettingsView.SettingsSection` 的 rawValue 一致，
/// 设置搜索据此把用户直接送到对应页（不引入对视图层类型的依赖）。
enum SettingsDestination: String, CaseIterable, Hashable, Sendable {
    case stt = "语音转写"
    case llm = "大模型"
    case recording = "录音"
    case screenshot = "捕获"
    case hotkeys = "热键"
    case todo = "待办"
    case dictionary = "词典"
    case voiceprints = "声纹库"
    case data = "数据管理"
    case about = "关于"

    /// 本地化显示名（rawValue 即 Localizable.xcstrings 的源键，与设置页侧边栏同名）
    var localizedName: String { NSLocalizedString(rawValue, comment: "") }
}

// MARK: - 命令描述

/// 单条应用命令的描述
struct AppCommandDescriptor: Identifiable, Hashable {
    let id: AppCommandID
    /// 本地化标题键（与 `Localizable.xcstrings` 中的 key 一致；各语言翻译已存在或同批新增）
    let titleKey: String
    /// 当前快捷键
    let shortcut: CommandShortcut
    /// 该命令的设置入口（无对应设置页时为 nil）
    let settingsDestination: SettingsDestination?
    /// 图标（SF Symbol，菜单与设置搜索复用）
    let icon: String?
    /// 仅专业模式可用（普通模式下菜单栏/应用菜单不展示）
    let proOnly: Bool

    /// 供 SwiftUI 直接渲染的本地化标题
    var localizedTitle: LocalizedStringKey { LocalizedStringKey(titleKey) }

    /// 供 AppKit（NSMenuItem）使用的本地化标题
    var localizedTitleString: String { String(localized: String.LocalizationValue(titleKey)) }
}

// MARK: - 命令目录

/// 应用命令目录：菜单栏、应用菜单、帮助页与设置搜索的唯一事实源
enum AppCommandCatalog {

    static let all: [AppCommandDescriptor] = [
        AppCommandDescriptor(
            id: .toggleRecording,
            titleKey: "开始会议录音",
            shortcut: .globalRecordingHotkey,
            settingsDestination: .hotkeys,
            icon: "record.circle",
            proOnly: false
        ),
        AppCommandDescriptor(
            id: .captureScreenshot,
            titleKey: "截图热键",
            shortcut: .globalScreenshotHotkey,
            settingsDestination: .hotkeys,
            icon: "camera.viewfinder",
            proOnly: false
        ),
        AppCommandDescriptor(
            id: .captureFullScreenDirect,
            titleKey: "全屏直拍热键",
            shortcut: .globalFullScreenHotkey,
            settingsDestination: .hotkeys,
            icon: "rectangle.on.rectangle",
            proOnly: true
        ),
        AppCommandDescriptor(
            id: .newQuickNote,
            titleKey: "新建快捷笔记",
            shortcut: .command("n"),
            settingsDestination: nil,
            icon: "text.badge.plus",
            proOnly: false
        ),
        AppCommandDescriptor(
            id: .newQuickNoteFromClipboard,
            titleKey: "从剪贴板新建笔记",
            shortcut: .none,
            settingsDestination: nil,
            icon: "doc.on.clipboard",
            proOnly: true
        ),
        AppCommandDescriptor(
            id: .importMedia,
            titleKey: "导入音频或视频…",
            shortcut: .command("o"),
            settingsDestination: nil,
            icon: "square.and.arrow.down",
            proOnly: false
        ),
        AppCommandDescriptor(
            id: .captureRegion,
            titleKey: "新建区域截图",
            shortcut: .commandControl("s"),
            settingsDestination: .screenshot,
            icon: "crop",
            proOnly: false
        ),
        AppCommandDescriptor(
            id: .captureWindow,
            titleKey: "截取窗口",
            shortcut: .none,
            settingsDestination: .screenshot,
            icon: "macwindow.on.rectangle",
            proOnly: true
        ),
        AppCommandDescriptor(
            id: .captureFullScreen,
            titleKey: "截取全屏",
            shortcut: .none,
            settingsDestination: .screenshot,
            icon: "rectangle.dashed",
            proOnly: true
        ),
        AppCommandDescriptor(
            id: .openSettings,
            titleKey: "设置",
            shortcut: .command(","),
            settingsDestination: nil,
            icon: "gearshape",
            proOnly: false
        ),
        AppCommandDescriptor(
            id: .openHelp,
            titleKey: "Memozia 帮助",
            shortcut: .command("?"),
            settingsDestination: nil,
            icon: "questionmark.circle",
            proOnly: false
        ),
    ]

    /// 按 id 取描述（目录是静态的，找不到即为编程错误，用 fatalError 暴露而不是静默兜底）
    static func descriptor(for id: AppCommandID) -> AppCommandDescriptor {
        guard let descriptor = all.first(where: { $0.id == id }) else {
            preconditionFailure("命令目录缺少描述：\(id.rawValue)")
        }
        return descriptor
    }

    /// 帮助页「快捷键」小节展示的命令顺序（只列有快捷键的命令）
    static let shortcutReferenceIDs: [AppCommandID] = [
        .toggleRecording, .captureScreenshot, .captureFullScreenDirect,
        .newQuickNote, .importMedia, .openSettings, .openHelp,
    ]
}
