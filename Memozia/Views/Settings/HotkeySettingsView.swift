import SwiftUI
import SwiftData
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Carbon)
import Carbon.HIToolbox
#endif

// MARK: - 热键设置视图（录音 / 截图 / 全屏直拍 的全局热键）
///
/// 原先挤在「捕获」页里的「全局热键」小节独立成页：录音热键与捕获无关，
/// 且普通模式同样需要修改它，而「捕获」页在普通模式不可见。
/// 本页两种模式都显示，只按模式过滤「全屏直拍热键」这一行（该组合仅在专业模式注册）
struct HotkeySettingsView: View {
    /// 是否专业模式
    let isPro: Bool

    #if os(macOS)
    /// 热键录制目标
    private enum HotkeyTarget: Hashable {
        case recording
        case screenshot
        case fullscreen
    }

    /// 正在录制的热键（nil = 未在录制）
    @State private var recordingTarget: HotkeyTarget?
    /// 本地事件监听器（录制热键期间捕获按键）
    @State private var eventMonitor: Any?
    /// 热键设置失败提示（标题固定，文案按失败原因区分）
    @State private var showHotkeyAlert = false
    @State private var hotkeyFailureMessage = ""
    /// 当前生效的三条热键显示（录音 / 截图 / 全屏直拍）
    @State private var recordingDisplay: String = HotkeyFormatter.displayString(
        keyCode: GlobalHotkeyManager.shared.recordingKeyCode,
        carbonModifiers: GlobalHotkeyManager.shared.recordingModifiers
    )
    @State private var currentDisplay: String = HotkeyFormatter.displayString(
        keyCode: GlobalHotkeyManager.shared.keyCode,
        carbonModifiers: GlobalHotkeyManager.shared.modifiers
    )
    @State private var fullscreenDisplay: String = HotkeyFormatter.displayString(
        keyCode: GlobalHotkeyManager.shared.fullscreenKeyCode,
        carbonModifiers: GlobalHotkeyManager.shared.fullscreenModifiers
    )
    #endif

    var body: some View {
        #if os(macOS)
        Form {
            Section("全局热键") {
                // 三行名称与帮助页「快捷键」小节、设置搜索同源（AppCommandCatalog）
                hotkeyRow(
                    title: AppCommandCatalog.descriptor(for: .toggleRecording).localizedTitle,
                    subtitle: "开始 / 停止会议录音，应用未激活时也可触发",
                    icon: "record.circle",
                    display: recordingDisplay,
                    target: .recording
                )
                hotkeyRow(
                    title: AppCommandCatalog.descriptor(for: .captureScreenshot).localizedTitle,
                    subtitle: "应用未激活时也可触发，按默认模式启动",
                    icon: "camera.viewfinder",
                    display: currentDisplay,
                    target: .screenshot
                )
                if isPro {
                    hotkeyRow(
                        title: AppCommandCatalog.descriptor(for: .captureFullScreenDirect).localizedTitle,
                        subtitle: "立即捕获鼠标所在屏幕并保存，不经标注",
                        icon: "rectangle.on.rectangle",
                        display: fullscreenDisplay,
                        target: .fullscreen
                    )
                }

                if recordingTarget != nil {
                    Label("请按下新的组合键（功能键 F1–F20 可单独使用，其余需包含 ⌘/⌥/⌃ 中至少一个修饰键），按 Esc 取消", systemImage: "circle.dotted")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // ⌃⌘R 被其他应用占用时已自动改用备选组合：不说明的话用户会以为设置没生效
                if GlobalHotkeyManager.shared.recordingHotkeyFellBack {
                    Label("录音热键的默认组合 ⌃⌘R 已被其他应用占用，本次已自动改用 ⌃⇧⌘R；可点击「修改热键」自行更换。", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                // 注册失败原先只写日志：用户按了没反应却看不到任何状态，这里显性化
                if !GlobalHotkeyManager.shared.unregisteredHotkeys.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Label("热键注册失败", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(unregisteredHotkeyDisplays)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                        Text("该组合键可能已被其他应用占用，请换一个组合键。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("热键")
        .alert("热键注册失败", isPresented: $showHotkeyAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(hotkeyFailureMessage)
        }
        .onDisappear {
            stopRecording()
        }
        #else
        /* iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）
        ContentUnavailableView("热键", systemImage: "keyboard", description: Text("全局热键仅支持 macOS。"))
        */
        #endif
    }

    // MARK: - 热键录制（macOS）

    #if os(macOS)
    /// 单条热键行（录音热键 / 截图热键 / 全屏直拍热键共用布局）
    private func hotkeyRow(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        icon: String,
        display: String,
        target: HotkeyTarget
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(display)
                .font(.system(.body, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quinary)
                .cornerRadius(6)

            if recordingTarget == target {
                Button("取消") {
                    stopRecording()
                }
                .buttonStyle(.bordered)
            } else {
                Button("修改热键") {
                    startRecording(target)
                }
                .buttonStyle(.bordered)

                Button("恢复默认") {
                    resetHotkey(target)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func startRecording(_ target: HotkeyTarget) {
        // 切换录制目标时先撤掉旧监听器
        stopRecording()
        recordingTarget = target
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc 取消录制
            if event.keyCode == UInt16(kVK_Escape) {
                DispatchQueue.main.async { stopRecording() }
                return nil
            }
            let carbonMods = event.carbonModifiers
            // 仅功能键（F1-F20）可不带修饰键，其余必须至少一个修饰键
            let isFunctionKey = HotkeyFormatter.isFunctionKey(UInt32(event.keyCode))
            guard carbonMods != 0 || isFunctionKey else { return event }

            let newKeyCode = UInt32(event.keyCode)
            let result: HotkeyUpdateResult
            switch target {
            case .recording:
                result = GlobalHotkeyManager.shared.updateRecordingHotkey(keyCode: newKeyCode, carbonModifiers: carbonMods)
            case .screenshot:
                result = GlobalHotkeyManager.shared.updateHotkey(keyCode: newKeyCode, carbonModifiers: carbonMods)
            case .fullscreen:
                result = GlobalHotkeyManager.shared.updateFullscreenHotkey(keyCode: newKeyCode, carbonModifiers: carbonMods)
            }
            DispatchQueue.main.async {
                stopRecording()
                switch result {
                case .success:
                    // 回读管理器而不是直接采用请求组合：录音热键可能已被自动退回备选组合
                    refreshDisplays()
                default:
                    handleHotkeyFailure(result)
                }
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingTarget = nil
    }

    private func resetHotkey(_ target: HotkeyTarget) {
        let result: HotkeyUpdateResult
        switch target {
        case .recording:
            result = GlobalHotkeyManager.shared.resetRecordingToDefault()
        case .screenshot:
            result = GlobalHotkeyManager.shared.resetToDefault()
        case .fullscreen:
            result = GlobalHotkeyManager.shared.resetFullscreenToDefault()
        }
        switch result {
        case .success:
            refreshDisplays()
        default:
            handleHotkeyFailure(result)
        }
    }

    /// 从管理器回读三条热键的当前生效组合。
    /// 不能直接用请求的组合：录音热键被其他应用占用时管理器会自动退回备选组合，
    /// 界面必须显示真实生效的那一个
    private func refreshDisplays() {
        recordingDisplay = HotkeyFormatter.displayString(
            keyCode: GlobalHotkeyManager.shared.recordingKeyCode,
            carbonModifiers: GlobalHotkeyManager.shared.recordingModifiers
        )
        currentDisplay = HotkeyFormatter.displayString(
            keyCode: GlobalHotkeyManager.shared.keyCode,
            carbonModifiers: GlobalHotkeyManager.shared.modifiers
        )
        fullscreenDisplay = HotkeyFormatter.displayString(
            keyCode: GlobalHotkeyManager.shared.fullscreenKeyCode,
            carbonModifiers: GlobalHotkeyManager.shared.fullscreenModifiers
        )
    }

    /// 按失败原因给出准确提示：旧实现把所有失败都提示成「已被其他应用占用」，
    /// 应用内重复、系统保留组合（⌃⌘F）等真实原因被掩盖
    private func handleHotkeyFailure(_ result: HotkeyUpdateResult) {
        switch result {
        case .success:
            return
        case .duplicateWithOtherHotkey:
            hotkeyFailureMessage = String(localized: "该组合键已被 Memozia 的另一条热键占用，请换一个组合键。")
        case .reservedBySystem:
            hotkeyFailureMessage = String(localized: "⌃⌘F 是系统「进入全屏幕」的快捷键，不能用作全局热键，请换一个组合键。")
        case .unusable:
            hotkeyFailureMessage = String(localized: "该组合键不可注册：除功能键 F1–F20 外，需包含 ⌘/⌥/⌃ 中至少一个修饰键。")
        case .registrationFailed:
            hotkeyFailureMessage = String(localized: "该组合键可能已被其他应用占用，请换一个组合键。")
        }
        showHotkeyAlert = true
    }

    /// 未注册成功的热键显示串（如 "⌃⌘W"），用于设置页状态提示
    private var unregisteredHotkeyDisplays: String {
        let manager = GlobalHotkeyManager.shared
        var displays: [String] = []
        if manager.unregisteredHotkeys.contains(.recording) {
            displays.append(HotkeyFormatter.displayString(
                keyCode: manager.recordingKeyCode,
                carbonModifiers: manager.recordingModifiers
            ))
        }
        if manager.unregisteredHotkeys.contains(.screenshot) {
            displays.append(HotkeyFormatter.displayString(
                keyCode: manager.keyCode,
                carbonModifiers: manager.modifiers
            ))
        }
        if manager.unregisteredHotkeys.contains(.fullscreen) {
            displays.append(HotkeyFormatter.displayString(
                keyCode: manager.fullscreenKeyCode,
                carbonModifiers: manager.fullscreenModifiers
            ))
        }
        return displays.joined(separator: "  ")
    }
    #endif
}
