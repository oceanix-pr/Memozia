# 07 · 截图与 OCR

[← 返回首页](Home.md) · 源码：Memozia/Services/ScreenshotManager.swift、Memozia/Views/Screenshot/

截图子系统是一条相对独立的产品线：全局热键触发 → 冻结屏幕 → 框选/窗口拾取 → 标注 → 保存/复制/钉住/OCR → 转为图片笔记；同一会话工具栏另设「录制」出口，把当前选区/拾取窗口/全屏直接录成视频（与会议录音共用停止链路）。UI 层用 AppKit（NSView/NSPanel）实现，经通知总线与 SwiftUI 主程序解耦。

## 1. 子系统组成

```
触发层   GlobalHotkeyManager（⌃⌘S 截图 / ⌃⌘W 全屏直拍，Carbon；另含录音热键 ⌃⌘R，见 [系统集成](09-系统集成服务.md) §2）
         MenuBarController「捕获屏幕」子菜单（截图组+录屏直达+偏好）/ 侧栏「捕获」按钮（仅专业模式；无下拉，出口收敛到会话工具栏）
         / 应用内 CommandGroup 菜单
              ↓ NotificationCenter
入口     ScreenshotManager（权限预检、模式+意图分发、PNG 编码、结果通知）
              ↓
会话     ScreenshotOverlayController.RegionSelectionController（单例，统一捕获会话）
         ├── 冻结所有屏幕（SCScreenshotManager，排除自身窗口入镜）
         ├── 每屏一个 OverlayPanel 悬浮面板
         ├── OverlayAnnotationView（框选 + 标注画布 + 录制出口）
         │     └── 录制出口：RecordCountdownPanel.RecordCountdownController（3 秒倒计时层）
         ├── ReannotatePanel（重新标注编辑窗）
         └── PinnedWindowSession（钉住置顶窗口会话）
              ↓ Outcome（截图出口 → 通知入库；.recordRequested → screenRecordingTargetRequested 通知）
入库     RootView.handleScreenshotSaved → QuickNoteViewModel.createQuickNote(fromImage:)
         （转为图片型快捷笔记 → OCR → 多模态总结）
录屏     RootView.startScreenRecording(target:) → RecordingViewModel（复用会议录音管线+视频轨，
         见录音与音频采集篇 §录屏）
```

## 2. ScreenshotManager — 截图入口服务

源码：[ScreenshotManager.swift](../../Memozia/Services/ScreenshotManager.swift)（`@MainActor` 单例）

### 2.1 捕获模式

```swift
enum CaptureMode: String {
    case region      // 区域框选
    case window      // 窗口拾取
    case fullscreen  // 全屏
}
```

默认模式经 UserDefaults `screenshotDefaultMode` 配置（热键触发时读取）。

### 2.2 关键方法

| 方法 | 职责 |
|------|------|
| `startCapture(mode:intent:)` | 统一捕获会话：权限预检 → `RegionSelectionController.shared.begin(mode:intent:)` → 选择+标注流程；`intent = .record`（菜单/工具栏「录选区/录窗口」直达）时选定目标后自动进入录制倒计时 |
| `startCapture(mode:delay:)` | 延时截图（默认 3 秒倒计时） |
| `captureFullScreenDirect()` | 全屏直拍（⌃⌘W）：权限检查 → 获取鼠标所在屏幕 → `captureDirect` 直接捕获 → PNG 编码 → 发 `screenshotCaptureSaved` 通知，**不经过悬浮标注层**。占用标志由「看门狗 + 代次」管理：单次直拍超过 `directCaptureTimeout`（15s）未完成即作废该代次并释放占用（排队的直拍可立即重试），迟到的捕获/编码结果按代次不匹配丢弃；旧实现只在任务 `defer` 里复位标志，ScreenCaptureKit 不返回时会让该标志永久为 true、全屏热键彻底失效直到重启 |

### 2.3 权限处理

- `CGPreflightScreenCaptureAccess()` 先检查状态（避免未授权时模糊行为）→ `CGRequestScreenCaptureAccess()` 触发 TCC 弹窗
- 未授权/失败经 `screenshotPermissionNeeded` / `screenshotErrorOccurred` 通知 RootView 弹窗
- 屏幕录制权限授权后**必须重启应用**才生效

### 2.4 请求被忽略时的反馈

会话未结束（`RegionSelectionController.isIdle` 为 false）或权限授权等待中（`isRequestingPermission`）导致请求被忽略时不再只写 info 日志——旧实现下全局热键表现为「按了没反应」，与热键彻底失效无从区分：

- `hasVisibleSessionWindow` 为真（悬浮层/重标注窗可见）时只记日志：用户正看着会话，重复触发自明，且告警窗层级低于 `.screenSaver` 悬浮层会被完全遮住
- 非空闲却没有可见界面 = 会话卡在启动阶段，按 error 记录并向用户提示
- 主窗口不可见时（菜单栏「隐藏主窗口」或窗口「关闭即隐藏」后），挂在 RootView 上的 alert 没有可见宿主窗口，`showErrorAlert` / `showPermissionAlert` 改用独立 `NSAlert`（按钮行为一致）直接呈现，避免提示被隐藏窗口吞掉

## 3. RegionSelectionController — 截图会话控制器

源码：[ScreenshotOverlayController.swift](../../Memozia/Views/Screenshot/ScreenshotOverlayController.swift)（`@MainActor` 单例）

### 3.1 会话流程

1. **冻结屏幕**：`SCShareableContent` 枚举屏幕与窗口 → `SCContentFilter`（排除自身 App 窗口入镜）→ `SCScreenshotManager.captureImage` 按屏幕分辨率+缩放比例捕获冻结图 → 计算可拾取窗口区域（视图坐标、按 `CGWindowListCopyWindowInfo` 的权威前→后顺序重排，含窗口 ID 供录制出口升级为独立窗口录制；`SCShareableContent.windows` 的顺序未经 Apple 承诺，不可直接依赖）
2. **每屏创建悬浮面板**承载 `OverlayAnnotationView`（仅全屏会话 `enableScreenRecording()` 开放录制出口；`.record` 意图另 `armAutoRecordOnSelection()`）
3. **会话结束**回收面板并回调 `Outcome`（结束前归还启动时被抢走的 key 窗口，避免主窗体闪白）
4. `captureDirect`：全屏直拍专用，不经过悬浮层
5. **启动看门狗**：冻结屏幕阶段超过 `startupTimeout`（10s）未返回即 `finish(.failed)` 交还空闲状态并提示用户，迟到的冻结结果按代次丢弃——`isIdle` 旧实现只在 `finish` 中复位，`captureAllDisplays()` 挂起会让它永久为 false，之后所有截图/录屏入口（含两条全局热键）都被静默忽略，直到重启应用

### 3.2 Outcome 结果枚举

```swift
enum Outcome {
    case saved(originalPNG: Data, markedPNG: Data?, pixelWidth: Int, pixelHeight: Int, captureMode: String)
        // 确认保存；captureMode 记录用户现场实际操作（点窗=window/框选=region/全屏=fullscreen），与入口模式无关
    case copied                  // 已复制到剪贴板（不入库）
    case savedToDisk(path: String) // 已保存到桌面（截图_年月日_时分秒.png）
    case pinned(png: Data)       // 钉住：选区（含标注）栅格化为 PNG，由上层开启置顶窗口
    case pinnedWithOCR(png: Data) // OCR 识别并钉住（右侧附可编辑文字面板）
    case recordRequested(target: ScreenRecordingTarget)
        // 录制出口：目标由会话换算（点窗未调整=window/覆盖整屏=display(nil)/其余=display(区域)，
        // 区域为屏内左上原点 points）；ScreenshotManager 收到后转 `screenRecordingTargetRequested`
        // 通知，RootView 复用现有录屏链路启动（互斥/会话进行中给出显式提示，不再静默）
    case cancelled               // 取消（ESC/右键/取消按钮）
    case failed(String)          // 失败（权限/捕获异常）
}
```

### 3.3 AnnotationSessionHost 协议

标注视图只依赖此接口上报结果，全屏截图会话（RegionSelectionController）与**钉住窗口会话**（PinnedWindowSession）共用——钉住的截图可再次标注（工具栏"钉住"按钮保持选中不可重复钉住）。

## 4. OverlayAnnotationView — 框选与标注画布

源码：[OverlayAnnotationView.swift](../../Memozia/Views/Screenshot/OverlayAnnotationView.swift)（`final class OverlayAnnotationView: NSView, NSTextFieldDelegate`）

### 4.1 两阶段状态机

```swift
private enum Phase {
    case selecting    // 框选阶段：region 模式拖拽框选 / window 模式悬停高亮窗口
    case annotating   // 标注阶段：显示工具栏，可移动/缩放选区、绘制标注、编辑文字
}
```

### 4.2 标注工具

```swift
enum AnnotationTool: CaseIterable {
    case none      // 默认：调整选区（移动/缩放/重新框选）
    case select    // 选择/移动/删除单个标注
    case rect      // 矩形
    case ellipse   // 椭圆
    case arrow     // 箭头
    case pen       // 画笔
    case text      // 文字（粗体/斜体可选，字号 14/24/36 三档）
    case mosaic    // 马赛克
}
```

标注模型含 `kind/color/lineWidth（2/4/6 三档）/points/text/fontSize/isBold/isItalic`；文字长度上限 500 字符（规避 macOS 26 大文本同步布局挂死）。

### 4.3 绘制与交互

| 能力 | 说明 |
|------|------|
| 画布绘制 | 冻结图像 → 遮罩（选区外暗化）→ 标注形状 → 选区边框 → 窗口悬停高亮 → 尺寸提示与操作提示 |
| 鼠标/键盘交互 | 框选、窗口捕获、标注绘制、移动/缩放、删除、**撤销/重做**；快捷键：`Esc` 取消、`Enter` 确认、空格（工具切换）、各工具快捷键 |
| 工具栏 | 与其他按钮统一样式（36×36 SF Symbol）：复制 / **保存为文件** / 钉住 / OCR / **录制**（仅全屏捕获会话展示，`setRecordingSupported`）/ **麦克风**（与「录制」同步显隐，声源为「仅系统音频」时隐藏；点击弹出与设置页/菜单栏同一份设备列表，含虚拟设备与当前项勾选）/ 取消 / 确认；`makeToolButton` 统一构造 |
| 录制出口 | 点「录制」（或录屏直达意图自动触发）→ `makeRecordTarget` 换算目标 → 揭开悬浮层（复用 suspend/resume 机制）→ `RecordCountdownController` 在目标屏画选区红框 + 3-2-1（点击/Enter 立即开始，Esc 返回标注会话原地继续）→ 完成时 `finish(.recordRequested)`；标注不会烧录进视频（录的是实时屏幕），倒计时层展示当前质量/声源/麦克风供最后确认 |
| `saveToDesktop()` | 渲染含标注 PNG → 写桌面 `截图_yyyyMMdd_HHmmss.png` → `Outcome.savedToDisk` 结束会话 |

### 4.4 可访问性

`setAccessibilityLabel("截图标注区域")`，无障碍角色标注。

## 5. VisionOCRService — OCR

源码：[VisionOCRService.swift](../../Memozia/Services/VisionOCRService.swift)

`recognizeText`：PNG/JPEG → `CGImage` → `VNRecognizeTextRequest`（中英文识别 + 语言校正）→ 还认文本。并发安全：`OneShotThrowingBox<Value>` 辅助（泛型 Sendable 约束，配合 continuation.resume 只执行一次）。

## 6. 当前主流程：截图 → 图片笔记

[RootView.swift](../../Memozia/Views/RootView.swift)：

```swift
private func handleScreenshotSaved(userInfo: [AnyHashable: Any]?) {
    guard let userInfo, let originalPNG = userInfo["originalPNG"] as? Data else { return }
    // 优先使用标注版（用户标注的最终产物），无标注时用原图
    let imageToSave = (userInfo["markedPNG"] as? Data) ?? originalPNG
    if let note = quickNoteVM.createQuickNote(fromImage: imageToSave, context: modelContext) {
        selectedListItems = [.quickNote(note)]
    }
}
```

之后快捷笔记的常规能力全部可用：`runOCR`（QuickNoteViewModel）→ OCR 文本加密入库 → 图片多模态总结（`generateSummaryFromImage`，需 LLM 配置 `supportsVision`）→ 待办提取。

## 7. 通知定义

[ScreenshotNotifications.swift](../../Memozia/Services/ScreenshotNotifications.swift) 集中定义截图相关 `Notification.Name`（`screenshotCaptureSaved` / `screenshotPermissionNeeded` / `screenshotErrorOccurred` 等），发送方 ScreenshotManager，接收方 RootView。

## 8. 完整用户流程图

```
⌃⌘S（全局）/ 菜单栏「截图」/ 应用内菜单
  → ScreenshotManager.startCapture(mode)
      → 权限预检（无权限 → 弹窗提示重启）
      → RegionSelectionController.begin
          → 冻结全部屏幕（排除自身窗口）
          → [selecting] 拖拽框选 / 点窗口 / 全屏
          → [annotating] 工具栏标注（rect/ellipse/arrow/pen/text/mosaic
                          + 撤销重做 + 移动缩放选区）
          → 用户选择出口：
              ├── 复制    → Outcome.copied（剪贴板，不入库）
              ├── 存桌面  → Outcome.savedToDisk（~/Desktop/截图_*.png）
              ├── 钉住    → Outcome.pinned → PinnedWindowSession 置顶小窗
              │            （钉住会话可再次标注）
              └── 确认    → Outcome.saved(originalPNG, markedPNG, …)
                            → screenshotCaptureSaved 通知
                            → RootView → QuickNoteViewModel.createQuickNote(fromImage:)
                            → 图片笔记入库（选中展示）
                            → [可选] OCR / 多模态总结 / 待办提取
```
