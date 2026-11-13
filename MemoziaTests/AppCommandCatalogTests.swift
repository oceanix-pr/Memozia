import SwiftUI
import Testing

@testable import Memozia

/// 统一命令描述（`AppCommandCatalog`）的结构性回归。
///
/// 这些不变式保证「菜单栏 / 应用菜单 / 帮助页 / 设置搜索」四处引用同一份描述时不会漂移：
/// 名称非空、id 可反查、快捷键可直接用于应用菜单、设置去向能落到真实的设置页。
@MainActor
struct AppCommandCatalogTests {

    @Test("命令 id 唯一，且每个 id 都能反查到描述")
    func idsAreUniqueAndResolvable() {
        let ids = AppCommandCatalog.all.map(\.id)
        #expect(ids.count == AppCommandID.allCases.count)
        #expect(Set(ids).count == ids.count, "命令 id 不得重复")

        for id in AppCommandID.allCases {
            let descriptor = AppCommandCatalog.descriptor(for: id)
            #expect(descriptor.id == id)
            #expect(descriptor.titleKey.isEmpty == false, "命令名称不得为空")
            #expect(descriptor.localizedTitleString.isEmpty == false, "本地化名称不得为空")
        }
    }

    @Test("帮助页快捷键小节引用的命令都存在且都有快捷键显示")
    func shortcutReferenceEntriesAreDisplayable() {
        for id in AppCommandCatalog.shortcutReferenceIDs {
            let shortcut = AppCommandCatalog.descriptor(for: id).shortcut
            #expect(shortcut.display?.isEmpty == false, "帮助页列出的命令必须有快捷键显示：\(id.rawValue)")
        }
        #expect(Set(AppCommandCatalog.shortcutReferenceIDs).count == AppCommandCatalog.shortcutReferenceIDs.count)
    }

    @Test("应用菜单快捷键描述与既有组合键一致")
    func appMenuShortcutsMatchExpectations() {
        #expect(AppCommandCatalog.descriptor(for: .newQuickNote).shortcut.keyEquivalent?.key == "n")
        #expect(AppCommandCatalog.descriptor(for: .newQuickNote).shortcut.keyEquivalent?.modifiers == .command)
        #expect(AppCommandCatalog.descriptor(for: .importMedia).shortcut.keyEquivalent?.key == "o")
        #expect(AppCommandCatalog.descriptor(for: .captureRegion).shortcut.keyEquivalent?.modifiers == [.command, .control])
        #expect(AppCommandCatalog.descriptor(for: .openSettings).shortcut.keyEquivalent?.key == ",")
        #expect(AppCommandCatalog.descriptor(for: .openHelp).shortcut.keyEquivalent?.key == "?")
        // 全局热键类命令不参与应用菜单快捷键（由 Carbon 全局热键负责）
        #expect(AppCommandCatalog.descriptor(for: .toggleRecording).shortcut.keyEquivalent == nil)
        #expect(AppCommandCatalog.descriptor(for: .toggleRecording).shortcut.isGlobalHotkey)
        #expect(AppCommandCatalog.descriptor(for: .captureRegion).shortcut.isGlobalHotkey == false)
    }

    @Test("全局热键命令的当前快捷键实时取自热键管理器")
    func globalHotkeyDisplayMatchesManager() {
        let manager = GlobalHotkeyManager.shared
        #expect(AppCommandCatalog.descriptor(for: .toggleRecording).shortcut.display
                == HotkeyFormatter.displayString(keyCode: manager.recordingKeyCode,
                                                 carbonModifiers: manager.recordingModifiers))
        #expect(AppCommandCatalog.descriptor(for: .captureScreenshot).shortcut.display
                == HotkeyFormatter.displayString(keyCode: manager.keyCode,
                                                 carbonModifiers: manager.modifiers))
        #expect(AppCommandCatalog.descriptor(for: .captureFullScreenDirect).shortcut.display
                == HotkeyFormatter.displayString(keyCode: manager.fullscreenKeyCode,
                                                 carbonModifiers: manager.fullscreenModifiers))
    }

    @Test("命令的设置去向都能落到真实的设置页")
    func settingsDestinationsResolveToSections() {
        for descriptor in AppCommandCatalog.all {
            guard let destination = descriptor.settingsDestination else { continue }
            #expect(SettingsView.SettingsSection(rawValue: destination.rawValue) != nil,
                    "设置去向未对应任何设置页：\(destination.rawValue)")
            #expect(destination.localizedName.isEmpty == false)
        }
    }

    @Test("「从剪贴板新建笔记」命名与实际产物一致（创建的是笔记而非待办）")
    func clipboardCommandTitleIsAccurate() {
        let descriptor = AppCommandCatalog.descriptor(for: .newQuickNoteFromClipboard)
        #expect(descriptor.titleKey == "从剪贴板新建笔记")
        #expect(descriptor.titleKey.contains("待办") == false)
    }
}
