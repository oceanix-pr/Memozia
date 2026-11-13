#if os(macOS)
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit
import os.log

/// 系统截图总调度：权限检查 + 启动截图会话（区域/窗口/全屏）
///
/// 会话结果通过 NotificationCenter 通知分发（.screenshotCaptureSaved），
/// 由 RootView 负责入库（需要 ModelContext，Manager 不持有）。
/// 复制到剪贴板在悬浮层内直接完成，不经过数据库。
@MainActor
final class ScreenshotManager {

    static let shared = ScreenshotManager()

    /// 捕获模式
    enum CaptureMode: String {
        case region
        case window
        case fullscreen
    }

    private static let logger = Logger(subsystem: "app.memozia", category: "Screenshot")

    private init() {}

    /// 是否已获得屏幕录制权限（不触发系统弹窗）
    static var hasScreenPermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 会话是否空闲（进行中时忽略重复触发）
    var isIdle: Bool {
        RegionSelectionController.shared.isIdle
    }

    var hasResourcesPreventingUpdate: Bool {
        !isIdle || isCapturingDirect || isRequestingPermission
    }

    /// 当前是否为重新标注会话
    private var isReannotating = false
    private var pendingPermissionRepairCapture: (() -> Void)?

    private func deferCaptureForPermissionRepair(_ retry: @escaping () -> Void) -> Bool {
        guard UpdatePermissionRepair.shared.needsPreparation else { return false }
        guard pendingPermissionRepairCapture == nil else {
            reportPermissionPending(context: "等待更新授权清理")
            return true
        }
        pendingPermissionRepairCapture = retry
        Task { @MainActor in
            await UpdatePermissionRepair.shared.prepareIfNeeded()
            let action = pendingPermissionRepairCapture
            pendingPermissionRepairCapture = nil
            action?()
        }
        return true
    }

    /// 活动的钉住窗口会话（每个钉住的截图一个独立置顶窗口，可同时存在多个）
    private var pinnedSessions: [PinnedWindowSession] = []

    /// 全屏直拍进行中（防热键连按重复入库）
    private var isCapturingDirect = false

    /// 本次直拍开始时间：与 `directCaptureTimeout` 一起判定占用是否已卡死
    private var directCaptureStartedAt: Date?

    /// 直拍看门狗任务：到点仍未完成则强制释放占用
    private var directCaptureWatchdog: Task<Void, Never>?

    /// 直拍代次：被看门狗作废后自增，用于丢弃超时后迟到返回的结果
    private var directCaptureGeneration = 0

    /// 单次全屏直拍的占用上限。ScreenCaptureKit 在权限/系统状态异常时不保证返回，
    /// 而本标志原先只在任务 defer 里复位：一旦某次调用卡住，`isCapturingDirect`
    /// 会永久为 true，之后每次全屏热键都被守卫静默丢弃（表现为「热键彻底失效，直到重启」）。
    /// 区域截图热键不检查该标志，所以故障恰好只落在全屏直拍上。
    private static let directCaptureTimeout: TimeInterval = 15

    /// 权限申请弹窗进行中：等待系统授权窗响应期间忽略新的截图请求，
    /// 防止热键连按堆积多个 detached 请求、授权后逐一执行
    private var isRequestingPermission = false

    /// 直接全屏截图（无悬浮层）：立即捕获鼠标所在屏幕并入库为图片笔记
    func captureFullScreenDirect() {
        guard !deferCaptureForPermissionRepair({ self.captureFullScreenDirect() }) else { return }
        guard !AppUpdateService.shared.isPreparingToInstall else { return }
        guard FeaturePolicy(experience: AppExperiencePreference.resolved()).allows(.advancedCapture) else {
            Self.logger.debug("普通模式忽略全屏直拍请求")
            return
        }
        if isCapturingDirect {
            // 未超时视为热键连按，直接忽略；已超时说明上一次大概率卡在 ScreenCaptureKit
            guard isDirectCaptureStale else {
                Self.logger.info("全屏直拍进行中，忽略重复请求")
                return
            }
            Self.logger.error("上一次全屏直拍超过 \(Int(Self.directCaptureTimeout))s 未完成，作废其占用后重试")
            abortDirectCapture()
        }

        guard !isRequestingPermission else {
            reportPermissionPending(context: "全屏直拍")
            return
        }
        guard RegionSelectionController.shared.isIdle else {
            reportSessionBusy(context: "全屏直拍")
            return
        }

        guard Self.hasScreenPermission else {
            isRequestingPermission = true
            Task.detached(priority: .userInitiated) {
                let granted = CGRequestScreenCaptureAccess()
                await MainActor.run {
                    self.isRequestingPermission = false
                    if granted {
                        self.captureFullScreenDirect()
                    } else {
                        self.showPermissionAlert()
                    }
                }
            }
            return
        }

        let generation = beginDirectCapture()
        Task { @MainActor in
            defer { releaseDirectCapture(generation: generation) }

            // 鼠标所在屏；取不到时退回主屏
            let mouseLocation = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
            guard let screen else { return }

            guard let image = await RegionSelectionController.captureDirect(screen: screen) else {
                guard generation == directCaptureGeneration else { return }
                Self.logger.error("全屏直拍捕获失败")
                showErrorAlert(message: String(localized: "无法捕获屏幕内容，请重试"))
                return
            }

            // 看门狗已判定超时并作废该代次：丢弃迟到结果，避免与新一轮直拍重复入库
            guard generation == directCaptureGeneration else {
                Self.logger.error("全屏直拍结果迟到（已超时作废），丢弃")
                return
            }

            // PNG 编码移出主线程：5K/Retina 全屏约 15–45MP，`NSBitmapImageRep` 编码要
            // 几百毫秒到数秒，旧写法在 `Task { @MainActor }` 里直接编 → 热键连按会连续冻结整个应用
            // CGImage 本身是 Sendable，可直接被后台任务捕获，无需 nonisolated(unsafe) 豁免
            let cgImage = image
            let encoded: Data? = await Task.detached(priority: .userInitiated) {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(
                    output, UTType.png.identifier as CFString, 1, nil
                ) else { return nil }
                CGImageDestinationAddImage(destination, cgImage, nil)
                guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
                return output as Data
            }.value

            guard let png = encoded, generation == directCaptureGeneration else {
                if generation != directCaptureGeneration {
                    Self.logger.error("全屏直拍结果迟到（编码期间已超时作废），丢弃")
                } else {
                    Self.logger.error("全屏直拍 PNG 编码失败")
                    showErrorAlert(message: String(localized: "生成截图失败，请重试"))
                }
                return
            }

            // 无标注：不传 markedPNG，入库时自动回退到原图。
            // originalPNG 必须用 ScreenshotPayloadBox 包装：RootView 按 ScreenshotPayloadBox 解包，
            // 旧写法传裸 Data 会导致 as? 转换失败、guard 直接返回，直拍结果被静默丢弃（热键表现为无效）
            NotificationCenter.default.post(
                name: .screenshotCaptureSaved,
                object: nil,
                userInfo: [
                    "originalPNG": ScreenshotPayloadBox(png),
                    "pixelWidth": image.width,
                    "pixelHeight": image.height,
                    "captureMode": CaptureMode.fullscreen.rawValue,
                ]
            )
        }
    }

    // MARK: - 全屏直拍占用（看门狗 + 代次）

    /// 当前直拍占用是否已超过上限（视为卡死，允许作废后重试）
    private var isDirectCaptureStale: Bool {
        guard let startedAt = directCaptureStartedAt else { return true }
        return Date().timeIntervalSince(startedAt) >= Self.directCaptureTimeout
    }

    /// 开始直拍占用：记录代次并启动看门狗，保证即使 ScreenCaptureKit 不返回也会释放
    private func beginDirectCapture() -> Int {
        directCaptureGeneration += 1
        let generation = directCaptureGeneration
        isCapturingDirect = true
        directCaptureStartedAt = Date()
        directCaptureWatchdog?.cancel()
        directCaptureWatchdog = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.directCaptureTimeout * 1_000_000_000))
            guard !Task.isCancelled, generation == self.directCaptureGeneration else { return }
            Self.logger.error("全屏直拍超时（\(Int(Self.directCaptureTimeout))s）未完成，释放占用（迟到结果按代次丢弃）")
            self.abortDirectCapture()
        }
        return generation
    }

    /// 正常结束直拍占用；代次不匹配（已被看门狗作废）时不动作，避免踩掉新一轮直拍
    private func releaseDirectCapture(generation: Int) {
        guard generation == directCaptureGeneration else { return }
        directCaptureWatchdog?.cancel()
        directCaptureWatchdog = nil
        directCaptureStartedAt = nil
        isCapturingDirect = false
    }

    /// 作废当前代次并释放占用：代次自增使在途结果全部按「迟到」丢弃
    private func abortDirectCapture() {
        directCaptureGeneration += 1
        directCaptureWatchdog?.cancel()
        directCaptureWatchdog = nil
        directCaptureStartedAt = nil
        isCapturingDirect = false
    }

    /// 从已有图片重新标注
    /// - Parameter imageData: 原始图片 PNG 数据
    func reannotate(imageData: Data) {
        guard RegionSelectionController.shared.isIdle else {
            reportSessionBusy(context: "重新标注")
            return
        }
        isReannotating = true
        RegionSelectionController.shared.reannotate(imageData: imageData) { [weak self] outcome in
            self?.handle(outcome: outcome)
        }
    }

    /// 启动捕获会话（统一入口：选定目标后可在工具栏选择截图出口或录制出口）
    /// - Parameters:
    ///   - mode: 捕获模式
    ///   - intent: .record 时选定目标后自动进入录制倒计时（菜单/工具栏「录选区/录窗口」直达）
    func startCapture(mode: CaptureMode, intent: CaptureIntent = .screenshot) {
        guard !deferCaptureForPermissionRepair({ self.startCapture(mode: mode, intent: intent) }) else { return }
        guard !AppUpdateService.shared.isPreparingToInstall else { return }
        let effectiveIntent: CaptureIntent = FeaturePolicy(
            experience: AppExperiencePreference.resolved()
        ).allows(.screenRecording) ? intent : .screenshot
        guard !isRequestingPermission else {
            reportPermissionPending(context: "启动截图会话")
            return
        }
        guard RegionSelectionController.shared.isIdle else {
            reportSessionBusy(context: "启动截图会话")
            return
        }

        guard Self.hasScreenPermission else {
            isRequestingPermission = true
            Task.detached(priority: .userInitiated) {
                // CGRequestScreenCaptureAccess 会弹系统授权窗并等待用户响应，
                // 在后台线程调用避免阻塞主线程
                let granted = CGRequestScreenCaptureAccess()
                await MainActor.run {
                    self.isRequestingPermission = false
                    if granted {
                        self.startCapture(mode: mode, intent: effectiveIntent)
                    } else {
                        self.showPermissionAlert()
                    }
                }
            }
            return
        }

        RegionSelectionController.shared.begin(mode: mode, intent: effectiveIntent) { [weak self] outcome in
            self?.handle(outcome: outcome)
        }
    }

    /// 延时截图：倒计时结束后自动启动截图会话
    /// - Parameters:
    ///   - mode: 捕获模式
    ///   - delay: 延时秒数（3 或 5）
    func startCapture(mode: CaptureMode, delay: Int) {
        guard RegionSelectionController.shared.isIdle else {
            reportSessionBusy(context: "延时截图")
            return
        }
        guard delay > 0 else {
            startCapture(mode: mode)
            return
        }

        Task { @MainActor in
            // 显示全屏倒计时覆盖层
            let overlay = CountdownOverlayView(seconds: delay)
            overlay.show()
            for remaining in stride(from: delay, through: 1, by: -1) {
                overlay.update(count: remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            overlay.dismiss()
            startCapture(mode: mode)
        }
    }

    // MARK: - 私有实现

    private func handle(outcome: RegionSelectionController.Outcome) {
        let wasReannotating = isReannotating
        isReannotating = false

        switch outcome {
        case .saved(let originalPNG, let markedPNG, let pixelWidth, let pixelHeight, let captureMode):
            if wasReannotating {
                let finalPNG = markedPNG ?? originalPNG
                NotificationCenter.default.post(
                    name: .screenshotReannotated,
                    object: nil,
                    userInfo: ["markedPNG": ScreenshotPayloadBox(finalPNG)]
                )
            } else {
                NotificationCenter.default.post(
                    name: .screenshotCaptureSaved,
                    object: nil,
                    userInfo: [
                        "originalPNG": ScreenshotPayloadBox(originalPNG),
                        "markedPNG": markedPNG.map { ScreenshotPayloadBox($0) } as Any,
                        "pixelWidth": pixelWidth,
                        "pixelHeight": pixelHeight,
                        "captureMode": captureMode,
                    ]
                )
            }
        case .copied:
            Self.logger.info("截图已复制到剪贴板")
            postCaptureNotice(String(localized: "截图已复制到剪贴板"))
        case .savedToDisk(let path):
            Self.logger.info("截图已保存：\(path)")
            postCaptureNotice(String(format: String(localized: "截图已保存到 %@"), path))
        case .pinned(let png):
            openPinnedWindow(imageData: png)
        case .pinnedWithOCR(let png):
            // 钉住并在窗口右侧展示 OCR 识别文字（单纯钉住走上面的 .pinned，无文字面板）
            openPinnedWindow(imageData: png, showOCR: true)
        case .recordRequested(let target):
            // 统一捕获的录制出口：目标已由会话换算完成，转通知交 RootView 走现有录屏链路
            Self.logger.info("捕获会话→录制出口：目标已选定，分发录屏请求")
            NotificationCenter.default.post(
                name: .screenRecordingTargetRequested,
                object: nil,
                userInfo: ["target": target]
            )
        case .cancelled:
            Self.logger.info("截图已取消")
        case .failed(let reason):
            Self.logger.error("截图失败：\(reason)")
            showErrorAlert(message: reason)
        }
    }

    /// 把截图放入置顶钉住窗口（可继续标注与缩放，确认后按普通截图入库）
    /// - Parameter showOCR: 是否同时识别图片文字并在窗口右侧展示可编辑的文字面板
    private func openPinnedWindow(imageData: Data, showOCR: Bool = false) {
        guard let session = PinnedWindowSession(imageData: imageData, showOCR: showOCR, onEnd: { [weak self] session in
            self?.pinnedSessions.removeAll { $0 === session }
        }) else {
            Self.logger.error("钉住窗口开启失败（图片解码失败）")
            showErrorAlert(message: String(localized: "无法加载图片"))
            return
        }
        pinnedSessions.append(session)
    }

    // MARK: - 请求被忽略时的用户提示

    /// 截图会话未结束导致请求被忽略。原先各入口只写 info 日志，用户按热键后
    /// 得不到任何反馈，与「热键彻底失效」无从区分。
    ///
    /// 已有可见会话界面（全屏悬浮层/重新标注窗）时只记日志：用户正看着会话，重复触发是
    /// 自明的，且告警窗层级低于 .screenSaver 悬浮层会被完全遮住。非空闲却看不到任何界面，
    /// 说明会话卡在启动阶段（ScreenCaptureKit 未返回），用户没有任何线索，必须明确提示
    private func reportSessionBusy(context: String) {
        guard !RegionSelectionController.shared.hasVisibleSessionWindow else {
            Self.logger.info("\(context)：已有可见截图会话，忽略重复触发")
            return
        }
        Self.logger.error("\(context)：截图会话未结束且无可见界面（疑似启动卡住），提示用户")
        showErrorAlert(message: String(localized: "上一次截图尚未结束，请稍候重试；若长时间无响应，请重启应用。"))
    }

    /// 屏幕录制权限授权等待中导致请求被忽略（原先静默返回）
    private func reportPermissionPending(context: String) {
        Self.logger.error("\(context)：正在等待屏幕录制权限授权，提示用户")
        showPermissionAlert()
    }

    /// 是否存在可见的主窗口（SwiftUI alert 的宿主窗口）
    private var hasVisibleMainWindow: Bool {
        MenuBarController.shared.mainWindows.contains(where: { $0.isVisible })
    }

    private func showPermissionAlert() {
        // 主窗口不可见时（菜单栏「隐藏主窗口」或窗口「关闭即隐藏」后）挂在 RootView 上的
        // alert 没有可见宿主窗口，提示等于没提示，改为独立 NSAlert 直接呈现（按钮行为一致）
        guard hasVisibleMainWindow else {
            let alert = NSAlert()
            alert.messageText = String(localized: "需要屏幕录制权限")
            alert.informativeText = String(localized: "请在「系统设置 → 隐私与安全性 → 屏幕录制」中允许 Memozia，然后重新触发截图。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "打开系统设置"))
            alert.addButton(withTitle: String(localized: "取消"))
            if alert.runModal() == .alertFirstButtonReturn {
                guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
                NSWorkspace.shared.open(url)
            }
            return
        }
        NotificationCenter.default.post(name: .screenshotPermissionNeeded, object: nil)
    }

    private func showErrorAlert(message: String) {
        // 同上：主窗口不可见时改用独立 NSAlert，避免「热键失效却看不到任何提示」
        guard hasVisibleMainWindow else {
            let alert = NSAlert()
            alert.messageText = String(localized: "截图失败")
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "确定"))
            alert.runModal()
            return
        }
        NotificationCenter.default.post(
            name: .screenshotErrorOccurred,
            object: nil,
            userInfo: ["message": message]
        )
    }

    /// 截图一次性结果（已复制 / 已保存到文件）的非阻塞提示。
    /// 主窗口可见时走 RootView 顶部横幅（自动消失，不打断当前操作）；
    /// 主窗口被隐藏时（共享屏幕场景）不提示：横幅无人可见，而模态框会打断共享。
    private func postCaptureNotice(_ message: String) {
        guard hasVisibleMainWindow else { return }
        NotificationCenter.default.post(
            name: .screenshotCaptureNotice,
            object: nil,
            userInfo: ["message": message]
        )
    }
}

// MARK: - 延时截图倒计时覆盖层

/// 全屏半透明覆盖层，显示倒计时数字
@MainActor
private final class CountdownOverlayView {
    private var panel: NSPanel?
    private let totalSeconds: Int

    init(seconds: Int) {
        self.totalSeconds = seconds
    }

    func show() {
        guard let screen = NSScreen.main else { return }
        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(count: Int) {
        guard let panel else { return }
        // contentView 理论上非 nil，仍用可选链兜底，避免无保护强解包
        let view = NSView(frame: panel.contentView?.bounds ?? panel.frame)
        view.wantsLayer = true

        let bgLayer = CALayer()
        bgLayer.frame = view.bounds
        bgLayer.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        view.layer?.addSublayer(bgLayer)

        let label = NSTextField(labelWithString: "\(count)")
        label.font = .systemFont(ofSize: 160, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.sizeToFit()
        let labelSize = label.fittingSize
        label.frame = NSRect(
            x: (view.bounds.width - labelSize.width) / 2,
            y: (view.bounds.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        view.addSubview(label)

        // 简单缩放动画
        label.wantsLayer = true
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = 1.5
        animation.toValue = 1.0
        animation.duration = 0.3
        label.layer?.add(animation, forKey: "scale")

        panel.contentView?.subviews.forEach { $0.removeFromSuperview() }
        panel.contentView?.addSubview(view)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
#endif
