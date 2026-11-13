import Foundation

/// 截图结果传递盒：大体积 PNG（Retina 全屏可达数十 MB）直接放 userInfo
/// 会在通知分发期间多处装箱持有；改传类引用，接收方取值后随盒子一起释放
final class ScreenshotPayloadBox: @unchecked Sendable {
    let data: Data
    init(_ data: Data) { self.data = data }
}

/// 捕获 / 全局热键相关通知名（跨平台定义：RootView 在 iOS/macOS 均引用，
/// 发送方 GlobalHotkeyManager/ScreenshotManager/MenuBarController 仅 macOS）
extension Notification.Name {
    /// 全局热键触发（录音开/停切换）
    static let recordingHotkeyPressed = Notification.Name("recordingHotkeyPressed")
    /// 全局热键触发（截图）
    static let screenshotHotkeyPressed = Notification.Name("screenshotHotkeyPressed")
    /// 全局热键触发（直接全屏截图，无悬浮层）
    static let fullscreenScreenshotHotkeyPressed = Notification.Name("fullscreenScreenshotHotkeyPressed")
    /// 截图会话保存完成（userInfo：originalPNG/markedPNG/pixelWidth/pixelHeight/captureMode）
    static let screenshotCaptureSaved = Notification.Name("screenshotCaptureSaved")
    /// 重新标注保存完成（userInfo：markedPNG — 标注后的图片数据）
    static let screenshotReannotated = Notification.Name("screenshotReannotated")
    /// 菜单栏请求截图（userInfo：mode — region / window / fullscreen）
    static let menuBarStartScreenshot = Notification.Name("menuBarStartScreenshot")
    /// 菜单栏/工具栏请求开始录屏（userInfo：target — fullScreen / region / window；
    /// 统一捕获后 region/window 进入带录制出口的捕获会话，fullScreen 保持一步直达）
    static let menuBarStartScreenRecording = Notification.Name("menuBarStartScreenRecording")
    /// 统一捕获会话的录制出口（userInfo：target — ScreenRecordingTarget，目标已换算）；
    /// RootView 收到后复用现有录屏链路启动
    static let screenRecordingTargetRequested = Notification.Name("screenRecordingTargetRequested")
    /// 菜单栏请求延时截图（userInfo：mode — region / window / fullscreen, delay — 3 / 5）
    static let menuBarStartDelayedScreenshot = Notification.Name("menuBarStartDelayedScreenshot")
    /// 截图权限缺失，需引导用户前往系统设置
    static let screenshotPermissionNeeded = Notification.Name("screenshotPermissionNeeded")
    /// 截图失败（userInfo：message — 错误描述）
    static let screenshotErrorOccurred = Notification.Name("screenshotErrorOccurred")
    /// 截图一次性结果提示（userInfo：message）。
    /// 用于「已复制到剪贴板」「已保存到文件」这类**不入库**的出口：此前只写日志，
    /// 悬浮层一收起用户就失去任何确定性反馈（会怀疑是否真的复制/保存成功）
    static let screenshotCaptureNotice = Notification.Name("screenshotCaptureNotice")
}
