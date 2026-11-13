# 07 · 截圖與 OCR

[← 返回首頁](Home.md) · 原始碼：Memozia/Services/ScreenshotManager.swift、Memozia/Views/Screenshot/

截圖子系統是一條相對獨立的產品線：全域性熱鍵觸發 → 凍結螢幕 → 框選/視窗拾取 → 標註 → 儲存/複製/釘住/OCR → 轉為圖片筆記；同一會話工具欄另設「錄製」出口，把當前選區/拾取視窗/全屏直接錄成影片（與會議錄音共用停止鏈路）。UI 層用 AppKit（NSView/NSPanel）實現，經通知匯流排與 SwiftUI 主程式解耦。

## 1. 子系統組成

```
觸發層   GlobalHotkeyManager（⌃⌘S 截圖 / ⌃⌘W 全屏直拍，Carbon；另含錄音熱鍵 ⌃⌘R，見 [系統整合](09-System-Integration.md) §2）
         MenuBarController「捕獲螢幕」子選單（截圖組+錄屏直達+偏好）/ 側欄「捕獲」按鈕（僅專業模式；無下拉，出口收斂到會話工具欄）
         / 應用內 CommandGroup 選單
              ↓ NotificationCenter
入口     ScreenshotManager（許可權預檢、模式+意圖分發、PNG 編碼、結果通知）
              ↓
會話     ScreenshotOverlayController.RegionSelectionController（單例，統一捕獲會話）
         ├── 凍結所有螢幕（SCScreenshotManager，排除自身視窗入鏡）
         ├── 每屏一個 OverlayPanel 懸浮面板
         ├── OverlayAnnotationView（框選 + 標註畫布 + 錄製出口）
         │     └── 錄製出口：RecordCountdownPanel.RecordCountdownController（3 秒倒計時層）
         ├── ReannotatePanel（重新標註編輯窗）
         └── PinnedWindowSession（釘住置頂視窗會話）
              ↓ Outcome（截圖出口 → 通知入庫；.recordRequested → screenRecordingTargetRequested 通知）
入庫     RootView.handleScreenshotSaved → QuickNoteViewModel.createQuickNote(fromImage:)
         （轉為圖片型快捷筆記 → OCR → 多模態總結）
錄屏     RootView.startScreenRecording(target:) → RecordingViewModel（複用會議錄音管線+影片軌，
         見錄音與音訊採集篇 §錄屏）
```

## 2. ScreenshotManager — 截圖入口服務

原始碼：[ScreenshotManager.swift](../../../Memozia/Services/ScreenshotManager.swift)（`@MainActor` 單例）

### 2.1 捕獲模式

```swift
enum CaptureMode: String {
    case region      // 区域框选
    case window      // 窗口拾取
    case fullscreen  // 全屏
}
```

預設模式經 UserDefaults `screenshotDefaultMode` 配置（熱鍵觸發時讀取）。

### 2.2 關鍵方法

| 方法 | 職責 |
|------|------|
| `startCapture(mode:intent:)` | 統一捕獲會話：許可權預檢 → `RegionSelectionController.shared.begin(mode:intent:)` → 選擇+標註流程；`intent = .record`（選單/工具欄「錄選區/錄視窗」直達）時選定目標後自動進入錄製倒計時 |
| `startCapture(mode:delay:)` | 延時截圖（預設 3 秒倒計時） |
| `captureFullScreenDirect()` | 全屏直拍（⌃⌘W）：許可權檢查 → 獲取滑鼠所在螢幕 → `captureDirect` 直接捕獲 → PNG 編碼 → 發 `screenshotCaptureSaved` 通知，**不經過懸浮標註層**。佔用標誌由「看門狗 + 代次」管理：單次直拍超過 `directCaptureTimeout`（15s）未完成即作廢該代次並釋放佔用（排隊的直拍可立即重試），遲到的捕獲/編碼結果按代次不匹配丟棄；舊實現只在任務 `defer` 裡復位標誌，ScreenCaptureKit 不返回時會讓該標誌永久為 true、全屏熱鍵徹底失效直到重啟 |

### 2.3 許可權處理

- `CGPreflightScreenCaptureAccess()` 先檢查狀態（避免未授權時模糊行為）→ `CGRequestScreenCaptureAccess()` 觸發 TCC 彈窗
- 未授權/失敗經 `screenshotPermissionNeeded` / `screenshotErrorOccurred` 通知 RootView 彈窗
- 螢幕錄製許可權授權後**必須重啟應用**才生效

### 2.4 請求被忽略時的反饋

會話未結束（`RegionSelectionController.isIdle` 為 false）或許可權授權等待中（`isRequestingPermission`）導致請求被忽略時不再只寫 info 日誌——舊實現下全域性熱鍵表現為「按了沒反應」，與熱鍵徹底失效無從區分：

- `hasVisibleSessionWindow` 為真（懸浮層/重標註窗可見）時只記日誌：使用者正看著會話，重複觸發自明，且告警窗層級低於 `.screenSaver` 懸浮層會被完全遮住
- 非空閒卻沒有可見介面 = 會話卡在啟動階段，按 error 記錄並向使用者提示
- 主視窗不可見時（選單欄「隱藏主視窗」或視窗「關閉即隱藏」後），掛在 RootView 上的 alert 沒有可見宿主視窗，`showErrorAlert` / `showPermissionAlert` 改用獨立 `NSAlert`（按鈕行為一致）直接呈現，避擴音示被隱藏視窗吞掉

## 3. RegionSelectionController — 截圖會話控制器

原始碼：[ScreenshotOverlayController.swift](../../../Memozia/Views/Screenshot/ScreenshotOverlayController.swift)（`@MainActor` 單例）

### 3.1 會話流程

1. **凍結螢幕**：`SCShareableContent` 列舉螢幕與視窗 → `SCContentFilter`（排除自身 App 視窗入鏡）→ `SCScreenshotManager.captureImage` 按螢幕解析度+縮放比例捕獲凍結圖 → 計算可拾取視窗區域（檢視座標、按 `CGWindowListCopyWindowInfo` 的權威前→後順序重排，含視窗 ID 供錄製出口升級為獨立視窗錄製；`SCShareableContent.windows` 的順序未經 Apple 承諾，不可直接依賴）
2. **每屏建立懸浮面板**承載 `OverlayAnnotationView`（僅全屏會話 `enableScreenRecording()` 開放錄製出口；`.record` 意圖另 `armAutoRecordOnSelection()`）
3. **會話結束**回收面板並回撥 `Outcome`（結束前歸還啟動時被搶走的 key 視窗，避免主窗體閃白）
4. `captureDirect`：全屏直拍專用，不經過懸浮層
5. **啟動看門狗**：凍結螢幕階段超過 `startupTimeout`（10s）未返回即 `finish(.failed)` 交還空閒狀態並提示使用者，遲到的凍結結果按代次丟棄——`isIdle` 舊實現只在 `finish` 中復位，`captureAllDisplays()` 掛起會讓它永久為 false，之後所有截圖/錄屏入口（含兩條全域性熱鍵）都被靜默忽略，直到重啟應用

### 3.2 Outcome 結果列舉

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

### 3.3 AnnotationSessionHost 協議

標註檢視只依賴此介面上報結果，全屏截圖會話（RegionSelectionController）與**釘住視窗會話**（PinnedWindowSession）共用——釘住的截圖可再次標註（工具欄"釘住"按鈕保持選中不可重複釘住）。

## 4. OverlayAnnotationView — 框選與標註畫布

原始碼：[OverlayAnnotationView.swift](../../../Memozia/Views/Screenshot/OverlayAnnotationView.swift)（`final class OverlayAnnotationView: NSView, NSTextFieldDelegate`）

### 4.1 兩階段狀態機

```swift
private enum Phase {
    case selecting    // 框选阶段：region 模式拖拽框选 / window 模式悬停高亮窗口
    case annotating   // 标注阶段：显示工具栏，可移动/缩放选区、绘制标注、编辑文字
}
```

### 4.2 標註工具

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

標註模型含 `kind/color/lineWidth（2/4/6 三档）/points/text/fontSize/isBold/isItalic`；文字長度上限 500 字元（規避 macOS 26 大文字同步佈局掛死）。

### 4.3 繪製與互動

| 能力 | 說明 |
|------|------|
| 畫布繪製 | 凍結影象 → 遮罩（選區外暗化）→ 標註形狀 → 選區邊框 → 視窗懸停高亮 → 尺寸提示與操作提示 |
| 滑鼠/鍵盤互動 | 框選、視窗捕獲、標註繪製、移動/縮放、刪除、**撤銷/重做**；快捷鍵：`Esc` 取消、`Enter` 確認、空格（工具切換）、各工具快捷鍵 |
| 工具欄 | 與其他按鈕統一樣式（36×36 SF Symbol）：複製 / **儲存為檔案** / 釘住 / OCR / **錄製**（僅全屏捕獲會話展示，`setRecordingSupported`）/ **麥克風**（與「錄製」同步顯隱，聲源為「僅系統音訊」時隱藏；點選彈出與設定頁/選單欄同一份裝置列表，含虛擬裝置與當前項勾選）/ 取消 / 確認；`makeToolButton` 統一構造 |
| 錄製出口 | 點「錄製」（或錄屏直達意圖自動觸發）→ `makeRecordTarget` 換算目標 → 揭開懸浮層（複用 suspend/resume 機制）→ `RecordCountdownController` 在目標屏畫選區紅框 + 3-2-1（點選/Enter 立即開始，Esc 返回標註會話原地繼續）→ 完成時 `finish(.recordRequested)`；標註不會燒錄進影片（錄的是實時螢幕），倒計時層展示當前質量/聲源/麥克風供最後確認 |
| `saveToDesktop()` | 渲染含標註 PNG → 寫桌面 `截图_yyyyMMdd_HHmmss.png` → `Outcome.savedToDisk` 結束會話 |

### 4.4 可訪問性

`setAccessibilityLabel("截图标注区域")`，無障礙角色標註。

## 5. VisionOCRService — OCR

原始碼：[VisionOCRService.swift](../../../Memozia/Services/VisionOCRService.swift)

`recognizeText`：PNG/JPEG → `CGImage` → `VNRecognizeTextRequest`（中英文識別 + 語言校正）→ 還認文字。併發安全：`OneShotThrowingBox<Value>` 輔助（泛型 Sendable 約束，配合 continuation.resume 只執行一次）。

## 6. 當前主流程：截圖 → 圖片筆記

[RootView.swift](../../../Memozia/Views/RootView.swift)：

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

之後快捷筆記的常規能力全部可用：`runOCR`（QuickNoteViewModel）→ OCR 文字加密入庫 → 圖片多模態總結（`generateSummaryFromImage`，需 LLM 配置 `supportsVision`）→ 待辦提取。

## 7. 通知定義

[ScreenshotNotifications.swift](../../../Memozia/Services/ScreenshotNotifications.swift) 集中定義截圖相關 `Notification.Name`（`screenshotCaptureSaved` / `screenshotPermissionNeeded` / `screenshotErrorOccurred` 等），傳送方 ScreenshotManager，接收方 RootView。

## 8. 完整使用者流程圖

```
⌃⌘S（全域性）/ 選單欄「截圖」/ 應用內選單
  → ScreenshotManager.startCapture(mode)
      → 許可權預檢（無許可權 → 彈窗提示重啟）
      → RegionSelectionController.begin
          → 凍結全部螢幕（排除自身視窗）
          → [selecting] 拖拽框選 / 點視窗 / 全屏
          → [annotating] 工具欄標註（rect/ellipse/arrow/pen/text/mosaic
                          + 撤銷重做 + 移動縮放選區）
          → 使用者選擇出口：
              ├── 複製    → Outcome.copied（剪貼簿，不入庫）
              ├── 存桌面  → Outcome.savedToDisk（~/Desktop/截圖_*.png）
              ├── 釘住    → Outcome.pinned → PinnedWindowSession 置頂小窗
              │            （釘住會話可再次標註）
              └── 確認    → Outcome.saved(originalPNG, markedPNG, …)
                            → screenshotCaptureSaved 通知
                            → RootView → QuickNoteViewModel.createQuickNote(fromImage:)
                            → 圖片筆記入庫（選中展示）
                            → [可選] OCR / 多模態總結 / 待辦提取
```
