#if os(macOS)
import AppKit
import Carbon.HIToolbox
import os.log

/// 热键更新结果：把「应用内冲突 / 系统保留组合 / 真的被占用」区分开，
/// 避免所有失败都提示成「已被其他应用占用」而误导用户
enum HotkeyUpdateResult {
    case success
    /// 与另一条应用内热键相同（同一组合会触发两条热键）
    case duplicateWithOtherHotkey
    /// 系统保留组合：⌃⌘F 为 Cocoa 标准菜单「进入全屏幕」
    case reservedBySystem
    /// 不可注册：非功能键必须至少带一个修饰键（设置页已拦截，此处兜底）
    case unusable
    /// 注册失败：组合已被其他应用占用
    case registrationFailed
}

/// 全局热键管理：基于 Carbon RegisterEventHotKey（应用未激活时也能触发）
///
/// 支持三条热键：
/// - 录音热键（默认 ⌃⌘R）：开/停切换会议录音，两种模式均可用
/// - 截图热键（默认 ⌃⌘S）：按「设置 → 热键」中的默认捕获模式启动截图会话
/// - 全屏直拍热键（默认 ⌃⌘W）：立即捕获鼠标所在屏幕并直接入库，无悬浮层（仅专业模式注册）
/// 均可在「设置 → 热键」中修改。触发后以 NotificationCenter 通知分发，
/// 避免跨隔离引用（Swift 6 并发安全）。
@MainActor
final class GlobalHotkeyManager {

    static let shared = GlobalHotkeyManager()

    /// 热键槽位：用于记录/展示哪一条注册失败
    enum HotkeyKind: Hashable {
        case screenshot
        case fullscreen
        case recording
    }

    /// 默认热键：⌃⌘S（control + command + S）
    static let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_S)
    static let defaultModifiers: UInt32 = UInt32(controlKey | cmdKey)

    /// 默认全屏直拍热键：⌃⌘W（control + command + W）；
    /// 不再用 ⌃⌘F——与 Cocoa 标准菜单「进入全屏幕」同组合，应用退出时按到会误触发前台 App 全屏。
    /// 该组合由 `isSystemReserved` 统一拦截，用户在设置页重设时也会被拒绝并提示原因
    static let fullscreenDefaultKeyCode: UInt32 = UInt32(kVK_ANSI_W)
    static let fullscreenDefaultModifiers: UInt32 = UInt32(controlKey | cmdKey)

    /// 默认录音热键：⌃⌘R（control + command + R），开/停切换会议录音
    ///
    /// 标 `nonisolated`：回退判定是纯函数（`recordingFallbackCombination`），
    /// 需要在非 MainActor 上下文（测试）中读取这几个常量
    nonisolated static let recordingDefaultKeyCode: UInt32 = UInt32(kVK_ANSI_R)
    nonisolated static let recordingDefaultModifiers: UInt32 = UInt32(controlKey | cmdKey)

    /// ⌃⌘R 被其他应用占用时的备选组合：⇧⌃⌘R
    nonisolated static let recordingFallbackKeyCode: UInt32 = UInt32(kVK_ANSI_R)
    nonisolated static let recordingFallbackModifiers: UInt32 = UInt32(controlKey | cmdKey | shiftKey)

    /// UserDefaults 持久化 Key
    nonisolated static let keyCodeDefaultsKey = "screenshot_hotkey_keycode"
    nonisolated static let modifiersDefaultsKey = "screenshot_hotkey_modifiers"
    nonisolated static let fullscreenKeyCodeDefaultsKey = "fullscreen_screenshot_hotkey_keycode"
    nonisolated static let fullscreenModifiersDefaultsKey = "fullscreen_screenshot_hotkey_modifiers"
    nonisolated static let recordingKeyCodeDefaultsKey = "recording_hotkey_keycode"
    nonisolated static let recordingModifiersDefaultsKey = "recording_hotkey_modifiers"

    private static let logger = Logger(subsystem: "app.memozia", category: "GlobalHotkey")

    /// 热键签名（FourCharCode 'MMSS'）与 ID，用于在回调中识别自己的热键
    private nonisolated let signature: FourCharCode = 0x4D4D5353
    private nonisolated let hotkeyID: UInt32 = 1
    private nonisolated let fullscreenHotkeyID: UInt32 = 2
    private nonisolated let recordingHotkeyID: UInt32 = 3

    private var hotKeyRef: EventHotKeyRef?
    private var fullscreenHotKeyRef: EventHotKeyRef?
    private var recordingHotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var didStart = false

    /// 当前未注册成功的热键：注册失败原先只写日志、界面无任何提示，
    /// 用户只能感知「按了没反应」；设置页据此处展示真实状态
    private(set) var unregisteredHotkeys: Set<HotkeyKind> = []

    /// 系统保留组合：⌃⌘F 是 Cocoa 标准菜单「进入全屏幕」，
    /// 注册成全局热键会吃掉前台应用（含本应用）的系统全屏快捷键
    static func isSystemReserved(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        keyCode == UInt32(kVK_ANSI_F) && carbonModifiers == UInt32(controlKey | cmdKey)
    }

    /// 录音热键注册失败时的回退决策（纯函数，便于回归测试）。
    ///
    /// 只有「当前组合就是默认 ⌃⌘R」时才回退到 ⇧⌃⌘R：用户显式改过的组合若注册失败，
    /// 应当保持不动并由设置页提示失败，而不是被悄悄换成另一个组合。
    /// - Returns: 需要改用的备选组合；nil 表示不回退
    nonisolated static func recordingFallbackCombination(
        keyCode: UInt32,
        carbonModifiers: UInt32
    ) -> (keyCode: UInt32, carbonModifiers: UInt32)? {
        guard keyCode == recordingDefaultKeyCode,
              carbonModifiers == recordingDefaultModifiers else { return nil }
        return (recordingFallbackKeyCode, recordingFallbackModifiers)
    }

    /// 当前生效的热键（keyCode + Carbon 修饰键掩码）
    private(set) var keyCode: UInt32 = GlobalHotkeyManager.defaultKeyCode
    private(set) var modifiers: UInt32 = GlobalHotkeyManager.defaultModifiers

    /// 当前生效的全屏直拍热键
    private(set) var fullscreenKeyCode: UInt32 = GlobalHotkeyManager.fullscreenDefaultKeyCode
    private(set) var fullscreenModifiers: UInt32 = GlobalHotkeyManager.fullscreenDefaultModifiers

    /// 当前生效的录音热键
    private(set) var recordingKeyCode: UInt32 = GlobalHotkeyManager.recordingDefaultKeyCode
    private(set) var recordingModifiers: UInt32 = GlobalHotkeyManager.recordingDefaultModifiers

    /// 录音热键是否已自动退回备选组合 ⇧⌃⌘R（本次运行内的解析结果，
    /// 不写入 UserDefaults——冲突应用卸载后下次启动会自动回到 ⌃⌘R）。
    /// 设置页据此显性说明「为什么显示的不是 ⌃⌘R」
    private(set) var recordingHotkeyFellBack = false

    private init() {
        loadFromDefaults()
    }

    /// 启动：读取 UserDefaults 并注册热键（幂等，仅可调用一次）
    func start() {
        guard !didStart else { return }
        didStart = true
        installEventHandler()
        let result = registerHotkey()
        if result.screenshot {
            Self.logger.info("全局热键已启动：\(HotkeyFormatter.displayString(keyCode: self.keyCode, carbonModifiers: self.modifiers))")
        }
        if result.recording {
            Self.logger.info("录音热键已启动：\(HotkeyFormatter.displayString(keyCode: self.recordingKeyCode, carbonModifiers: self.recordingModifiers))")
        }
        if result.fullscreen && AppExperiencePreference.resolved() == .pro {
            Self.logger.info("全屏直拍热键已启动：\(HotkeyFormatter.displayString(keyCode: self.fullscreenKeyCode, carbonModifiers: self.fullscreenModifiers))")
        }
        // 失败的一条已由 registerHotkey 记入 unregisteredHotkeys（error 日志 + 设置页状态），
        // 另一条仍照常可用，不再像旧实现那样整体静默失效
    }

    /// 待设置的组合是否与「另外两条」应用内热键重复。
    /// 同一组合注册两次会互相覆盖，只剩一条真正生效，因此必须拦截
    private func isDuplicateOfOtherHotkey(
        keyCode newKeyCode: UInt32,
        modifiers newModifiers: UInt32,
        excluding excluded: HotkeyKind
    ) -> Bool {
        if excluded != .screenshot, newKeyCode == keyCode, newModifiers == modifiers { return true }
        if excluded != .fullscreen, newKeyCode == fullscreenKeyCode, newModifiers == fullscreenModifiers { return true }
        if excluded != .recording, newKeyCode == recordingKeyCode, newModifiers == recordingModifiers { return true }
        return false
    }

    /// 更新截图热键（写回 UserDefaults 并重新注册）
    /// - Returns: 更新结果；失败时保持原热键并返回具体原因
    @discardableResult
    func updateHotkey(keyCode newKeyCode: UInt32, carbonModifiers newModifiers: UInt32) -> HotkeyUpdateResult {
        guard !Self.isSystemReserved(keyCode: newKeyCode, carbonModifiers: newModifiers) else { return .reservedBySystem }
        guard newModifiers != 0 || HotkeyFormatter.isFunctionKey(newKeyCode) else { return .unusable }
        // 不允许与录音/全屏直拍热键相同（否则同一组合触发两条热键）
        guard !isDuplicateOfOtherHotkey(keyCode: newKeyCode, modifiers: newModifiers, excluding: .screenshot) else {
            return .duplicateWithOtherHotkey
        }
        let oldKeyCode = keyCode
        let oldModifiers = modifiers

        keyCode = newKeyCode
        modifiers = newModifiers
        guard registerHotkey().screenshot else {
            keyCode = oldKeyCode
            modifiers = oldModifiers
            Self.logger.error("截图热键更新失败，回退原组合：\(HotkeyFormatter.displayString(keyCode: oldKeyCode, carbonModifiers: oldModifiers))")
            _ = registerHotkey()
            return .registrationFailed
        }

        UserDefaults.standard.set(Int(newKeyCode), forKey: Self.keyCodeDefaultsKey)
        UserDefaults.standard.set(Int(newModifiers), forKey: Self.modifiersDefaultsKey)
        Self.logger.info("全局热键已更新：\(HotkeyFormatter.displayString(keyCode: newKeyCode, carbonModifiers: newModifiers))")
        return .success
    }

    /// 更新全屏直拍热键（写回 UserDefaults 并重新注册）
    /// - Returns: 更新结果；失败时保持原热键并返回具体原因
    @discardableResult
    func updateFullscreenHotkey(keyCode newKeyCode: UInt32, carbonModifiers newModifiers: UInt32) -> HotkeyUpdateResult {
        guard !Self.isSystemReserved(keyCode: newKeyCode, carbonModifiers: newModifiers) else { return .reservedBySystem }
        guard newModifiers != 0 || HotkeyFormatter.isFunctionKey(newKeyCode) else { return .unusable }
        guard !isDuplicateOfOtherHotkey(keyCode: newKeyCode, modifiers: newModifiers, excluding: .fullscreen) else {
            return .duplicateWithOtherHotkey
        }
        let oldKeyCode = fullscreenKeyCode
        let oldModifiers = fullscreenModifiers

        fullscreenKeyCode = newKeyCode
        fullscreenModifiers = newModifiers
        guard registerHotkey().fullscreen else {
            fullscreenKeyCode = oldKeyCode
            fullscreenModifiers = oldModifiers
            Self.logger.error("全屏直拍热键更新失败，回退原组合：\(HotkeyFormatter.displayString(keyCode: oldKeyCode, carbonModifiers: oldModifiers))")
            _ = registerHotkey()
            return .registrationFailed
        }

        UserDefaults.standard.set(Int(newKeyCode), forKey: Self.fullscreenKeyCodeDefaultsKey)
        UserDefaults.standard.set(Int(newModifiers), forKey: Self.fullscreenModifiersDefaultsKey)
        Self.logger.info("全屏直拍热键已更新：\(HotkeyFormatter.displayString(keyCode: newKeyCode, carbonModifiers: newModifiers))")
        return .success
    }

    /// 更新录音热键（写回 UserDefaults 并重新注册）
    /// - Returns: 更新结果；失败时保持原热键并返回具体原因
    ///
    /// 注意持久化的是「用户意图」，而 `recordingKeyCode` 是「本次运行的实际生效值」：
    /// 若用户选回默认 ⌃⌘R 而该组合仍被占用，`registerHotkey` 会在内存里退回 ⇧⌃⌘R，
    /// 这里仍写入 ⌃⌘R，因此冲突应用消失后下次启动会自动回到 ⌃⌘R
    @discardableResult
    func updateRecordingHotkey(keyCode newKeyCode: UInt32, carbonModifiers newModifiers: UInt32) -> HotkeyUpdateResult {
        guard !Self.isSystemReserved(keyCode: newKeyCode, carbonModifiers: newModifiers) else { return .reservedBySystem }
        guard newModifiers != 0 || HotkeyFormatter.isFunctionKey(newKeyCode) else { return .unusable }
        guard !isDuplicateOfOtherHotkey(keyCode: newKeyCode, modifiers: newModifiers, excluding: .recording) else {
            return .duplicateWithOtherHotkey
        }
        let oldKeyCode = recordingKeyCode
        let oldModifiers = recordingModifiers

        recordingKeyCode = newKeyCode
        recordingModifiers = newModifiers
        guard registerHotkey().recording else {
            recordingKeyCode = oldKeyCode
            recordingModifiers = oldModifiers
            Self.logger.error("录音热键更新失败，回退原组合：\(HotkeyFormatter.displayString(keyCode: oldKeyCode, carbonModifiers: oldModifiers))")
            _ = registerHotkey()
            return .registrationFailed
        }

        UserDefaults.standard.set(Int(newKeyCode), forKey: Self.recordingKeyCodeDefaultsKey)
        UserDefaults.standard.set(Int(newModifiers), forKey: Self.recordingModifiersDefaultsKey)
        Self.logger.info("录音热键已更新：\(HotkeyFormatter.displayString(keyCode: newKeyCode, carbonModifiers: newModifiers))")
        return .success
    }

    /// 恢复默认热键
    @discardableResult
    func resetToDefault() -> HotkeyUpdateResult {
        updateHotkey(keyCode: Self.defaultKeyCode, carbonModifiers: Self.defaultModifiers)
    }

    /// 恢复默认全屏直拍热键
    @discardableResult
    func resetFullscreenToDefault() -> HotkeyUpdateResult {
        updateFullscreenHotkey(keyCode: Self.fullscreenDefaultKeyCode, carbonModifiers: Self.fullscreenDefaultModifiers)
    }

    /// 恢复默认录音热键（⌃⌘R；若仍被占用则当场退回备选 ⇧⌃⌘R）
    @discardableResult
    func resetRecordingToDefault() -> HotkeyUpdateResult {
        updateRecordingHotkey(
            keyCode: Self.recordingDefaultKeyCode,
            carbonModifiers: Self.recordingDefaultModifiers
        )
    }

    /// 模式切换后重新注册可用的热键；用户原热键配置保留不变。
    func refreshForExperienceChange() {
        guard didStart else { return }
        _ = registerHotkey()
    }

    // MARK: - 私有实现

    private func loadFromDefaults() {
        let savedCode = UserDefaults.standard.integer(forKey: Self.keyCodeDefaultsKey)
        let savedMods = UserDefaults.standard.integer(forKey: Self.modifiersDefaultsKey)
        // 任一项被写入过即视为已配置：功能键组合的修饰键合法地为 0（F1–F20 可单独使用），
        // 旧条件要求两者都非 0，会把已保存的「F 键无修饰键」组合误判成未设置而回退默认值
        if savedCode != 0 || savedMods != 0 {
            keyCode = UInt32(bitPattern: Int32(truncatingIfNeeded: savedCode))
            modifiers = UInt32(bitPattern: Int32(truncatingIfNeeded: savedMods))
        }

        let savedFullscreenCode = UserDefaults.standard.integer(forKey: Self.fullscreenKeyCodeDefaultsKey)
        let savedFullscreenMods = UserDefaults.standard.integer(forKey: Self.fullscreenModifiersDefaultsKey)
        if savedFullscreenCode != 0 || savedFullscreenMods != 0 {
            fullscreenKeyCode = UInt32(bitPattern: Int32(truncatingIfNeeded: savedFullscreenCode))
            fullscreenModifiers = UInt32(bitPattern: Int32(truncatingIfNeeded: savedFullscreenMods))
        }

        let savedRecordingCode = UserDefaults.standard.integer(forKey: Self.recordingKeyCodeDefaultsKey)
        let savedRecordingMods = UserDefaults.standard.integer(forKey: Self.recordingModifiersDefaultsKey)
        if savedRecordingCode != 0 || savedRecordingMods != 0 {
            recordingKeyCode = UInt32(bitPattern: Int32(truncatingIfNeeded: savedRecordingCode))
            recordingModifiers = UInt32(bitPattern: Int32(truncatingIfNeeded: savedRecordingMods))
        }
    }

    /// 注册/重新注册全部热键，逐条判定：单条失败只影响该条
    /// - Returns: 三条热键各自的注册结果
    ///
    /// 旧实现把两条当原子事务、任一失败即整体回滚，导致「某条组合被其他应用占用」
    /// 会连带拖垮另一条，且失败只写日志、界面无任何提示
    private func registerHotkey() -> (screenshot: Bool, fullscreen: Bool, recording: Bool) {
        unregisterHotkey()

        let mainID = EventHotKeyID(signature: signature, id: hotkeyID)
        var mainRef: EventHotKeyRef?
        // RegisterEventHotKey 必须在主线程调用（应用事件循环）
        let mainStatus = RegisterEventHotKey(keyCode, modifiers, mainID, GetApplicationEventTarget(), 0, &mainRef)

        let shouldRegisterFullscreen = AppExperiencePreference.resolved() == .pro
        var fullscreenRef: EventHotKeyRef?
        var fullscreenStatus: OSStatus = noErr
        if shouldRegisterFullscreen {
            let fullscreenID = EventHotKeyID(signature: signature, id: fullscreenHotkeyID)
            fullscreenStatus = RegisterEventHotKey(
                fullscreenKeyCode,
                fullscreenModifiers,
                fullscreenID,
                GetApplicationEventTarget(),
                0,
                &fullscreenRef
            )
        }

        // 录音热键：默认 ⌃⌘R；该组合被其他应用占用时自动退回备选 ⇧⌃⌘R。
        // 回退只针对「仍是默认组合」的情形，用户自定义的组合注册失败就如实报失败
        recordingHotkeyFellBack = false
        var recordingRef: EventHotKeyRef?
        var recordingStatus = RegisterEventHotKey(
            recordingKeyCode,
            recordingModifiers,
            EventHotKeyID(signature: signature, id: recordingHotkeyID),
            GetApplicationEventTarget(),
            0,
            &recordingRef
        )
        if recordingStatus != noErr,
           let fallback = Self.recordingFallbackCombination(
               keyCode: recordingKeyCode,
               carbonModifiers: recordingModifiers
           ) {
            if let ref = recordingRef {
                UnregisterEventHotKey(ref)
                recordingRef = nil
            }
            Self.logger.notice("录音热键 \(HotkeyFormatter.displayString(keyCode: self.recordingKeyCode, carbonModifiers: self.recordingModifiers)) 注册失败（OSStatus=\(recordingStatus)），改用备选组合 \(HotkeyFormatter.displayString(keyCode: fallback.keyCode, carbonModifiers: fallback.carbonModifiers))")
            recordingKeyCode = fallback.keyCode
            recordingModifiers = fallback.carbonModifiers
            recordingStatus = RegisterEventHotKey(
                fallback.keyCode,
                fallback.carbonModifiers,
                EventHotKeyID(signature: signature, id: recordingHotkeyID),
                GetApplicationEventTarget(),
                0,
                &recordingRef
            )
            // 只有备选组合真的注册成功才算「已回退」，否则设置页会同时显示
            // 「已改用 ⇧⌃⌘R」与「热键注册失败」两条互相矛盾的状态
            recordingHotkeyFellBack = recordingStatus == noErr
        }

        if let ref = mainRef, mainStatus == noErr {
            hotKeyRef = ref
        } else {
            if let ref = mainRef { UnregisterEventHotKey(ref) }
            Self.logger.error("截图热键注册失败（\(HotkeyFormatter.displayString(keyCode: self.keyCode, carbonModifiers: self.modifiers))，OSStatus=\(mainStatus)），该热键暂不可用")
        }

        if !shouldRegisterFullscreen {
            fullscreenHotKeyRef = nil
        } else if let ref = fullscreenRef, fullscreenStatus == noErr {
            fullscreenHotKeyRef = ref
        } else {
            if let ref = fullscreenRef { UnregisterEventHotKey(ref) }
            Self.logger.error("全屏直拍热键注册失败（\(HotkeyFormatter.displayString(keyCode: self.fullscreenKeyCode, carbonModifiers: self.fullscreenModifiers))，OSStatus=\(fullscreenStatus)），该热键暂不可用")
        }

        if let ref = recordingRef, recordingStatus == noErr {
            recordingHotKeyRef = ref
        } else {
            if let ref = recordingRef { UnregisterEventHotKey(ref) }
            Self.logger.error("录音热键注册失败（\(HotkeyFormatter.displayString(keyCode: self.recordingKeyCode, carbonModifiers: self.recordingModifiers))，OSStatus=\(recordingStatus)），该热键暂不可用")
        }

        let screenshotOK = hotKeyRef != nil
        let fullscreenOK = !shouldRegisterFullscreen || fullscreenHotKeyRef != nil
        let recordingOK = recordingHotKeyRef != nil
        if screenshotOK { unregisteredHotkeys.remove(.screenshot) } else { unregisteredHotkeys.insert(.screenshot) }
        if fullscreenOK { unregisteredHotkeys.remove(.fullscreen) } else { unregisteredHotkeys.insert(.fullscreen) }
        if recordingOK { unregisteredHotkeys.remove(.recording) } else { unregisteredHotkeys.insert(.recording) }
        return (screenshotOK, fullscreenOK, recordingOK)
    }

    private func unregisterHotkey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = fullscreenHotKeyRef {
            UnregisterEventHotKey(ref)
            fullscreenHotKeyRef = nil
        }
        if let ref = recordingHotKeyRef {
            UnregisterEventHotKey(ref)
            recordingHotKeyRef = nil
        }
    }

    /// 安装 Carbon 事件处理器（幂等）
    private func installEventHandler() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // C 回调不能捕获上下文：识别到自己的热键后仅发 NotificationCenter 通知
        // （热键在主事件循环分发，此处已在主线程，直接 post）
        let callback: EventHandlerUPP = { _, event, _ in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard status == noErr, hkID.signature == 0x4D4D5353 else { return noErr }
            switch hkID.id {
            case 1:
                NotificationCenter.default.post(name: .screenshotHotkeyPressed, object: nil)
            case 2:
                NotificationCenter.default.post(name: .fullscreenScreenshotHotkeyPressed, object: nil)
            case 3:
                NotificationCenter.default.post(name: .recordingHotkeyPressed, object: nil)
            default:
                break
            }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, nil, &eventHandler)
    }
}

// MARK: - 热键格式化（纯函数，供设置页与菜单显示）

enum HotkeyFormatter {

    /// Carbon 修饰键掩码 → 显示字符串（如 "⌥⌘"）
    static func modifierSymbols(carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    /// SDK 仅定义 F1-F20（F21+ 无虚拟键码常量），且 F 键码不连续（如 F1=0x7A、F5=0x60），用字典精确映射
    static let functionKeys: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15",
        UInt32(kVK_F16): "F16", UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18",
        UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    /// 是否为功能键（F1-F20）：功能键可不带修饰键注册，其余键必须至少一个修饰键
    static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        functionKeys[keyCode] != nil
    }

    /// keyCode → 键名（如 "S"、"F5"、"→"）
    static func keySymbol(for keyCode: UInt32) -> String {
        let letters: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        ]
        if let letter = letters[keyCode] { return letter }

        let digits: [UInt32: String] = [
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
        ]
        if let digit = digits[keyCode] { return digit }

        if let functionKey = functionKeys[keyCode] { return functionKey }

        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Delete: return "⌫"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Grave: return "`"
        default: return "Key(\(keyCode))"
        }
    }

    /// 组合显示（如 "⌥⌘S"）
    static func displayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        modifierSymbols(carbonModifiers: carbonModifiers) + keySymbol(for: keyCode)
    }
}

// MARK: - NSEvent 便捷转换

extension NSEvent {

    /// NSEvent 修饰键 → Carbon 修饰键掩码（keyCode 一致，无需转换）
    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}
#endif
