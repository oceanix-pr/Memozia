# 09 · 系統整合服務

[← 返回首頁](Home.md) · 原始碼：Memozia/Services/

本篇覆蓋與作業系統深度整合的輔助服務：選單欄、全域性熱鍵、AppKit 橋接工具。

## 1. MenuBarController — 選單欄控制器

原始碼：[MenuBarController.swift](../../../Memozia/Services/MenuBarController.swift)（`@MainActor` 單例）

### 1.1 職責

macOS 選單欄常駐控制中心（`NSStatusBar.system.statusItem`），在主視窗隱藏/共享螢幕場景下提供全部功能入口。

### 1.2 選單結構（`start()`）

| 選單項 | 動作 |
|--------|------|
| 開始錄音 / 停止錄音 | `menuBarStartRecording` / `menuBarStopRecording` 通知 → RootView → RecordingViewModel；錄屏進行中狀態項顯示「錄屏中」、切換項顯示「停止錄製」（依據 `MeetingRecorderService.isScreenRecording`，音訊 + 影片軌共用同一停止鏈路） |
| 捕獲螢幕（子選單，原「截圖」+「錄屏」兩項合併） | 截圖組：新建區域截圖（⌥⌘S）/擷取視窗/擷取全屏 → `menuBarStartScreenshot`（帶 mode），進統一捕獲會話（會話工具欄含「錄製」出口）；錄屏組：錄全屏（滑鼠所在屏）一步直達，錄選區/錄視窗 → `menuBarStartScreenRecording`（帶 target），路由到帶錄製出口的捕獲會話（intent=record，選定目標後自動 3 秒倒計時）；尾部聲源/質量 radio 為獨立偏好 `screen_recording_source/quality`（與設定頁「捕獲」節同鍵），不影響會議錄音設定 |
| 麥克風（子選單，與「捕獲螢幕」同級、緊隨其下） | 列系統全部輸入裝置（`MicrophoneDeviceRegistry`，含虛擬/迴環裝置，勾選當前項，已選裝置拔出時佔位提示）；與設定頁「錄音 → 輸入裝置」、截圖會話工具欄 mic 按鈕、錄音中狀態徽章的麥克風選單共用同一偏好 `microphone_device_uid`。會議錄音與錄屏都用它，故不再放在「捕獲螢幕」子選單內。子選單另含錄製中的「靜音麥克風 / 解除靜音」與空閒時預設下一場錄音的「錄音開始時靜音麥克風」勾選項（與錄音狀態徽章、截圖會話工具欄共用 `MicrophoneStartMutePreference`） |
| 隱藏主視窗 | `NSApp.setActivationPolicy(.accessory)`（隱藏 Dock 圖示+主窗，僅留選單欄——共享螢幕場景） |
| 從剪貼簿新建筆記 | `menuBarCreateQuickNoteFromClipboard` → QuickNoteViewModel.createQuickNoteFromClipboard（該命令實際建立的是快捷筆記，名稱已由 `AppCommandCatalog` 統一為「從剪貼簿新建筆記」） |
| 切換語言（子選單） | `applyInterfaceLanguage(code)`：寫 AppleLanguages + 彈重啟詢問 |
| 設定 | `menuBarOpenSettings` 通知 |
| 退出 | 錄音中先走**統一停止入口**：選單欄只發 `menuBarStopRecording`，等 ViewModel 收尾完成回發的 `menuBarStopRecordingCompleted`（並以「服務已停且合併不進行中」兜底、900s 上限）再 `NSApp.terminate`；舊實現先直接調服務的 `stopRecording()`，停止通知隨後被 `guard isMeetingRecording` 攔下，封存/合併/入庫整段被跳過（檔案已生成但本次沒有資料庫條目）。常規退出走 `applicationShouldTerminate` 收尾鏈，收尾完成後 `_exit` 結束程序以跳過 onnxruntime 靜態析構崩潰 |

命令的**名稱與快捷鍵**不在這裡各自硬編碼：選單欄、應用選單（`MemoziaApp.commands`）、幫助頁「快捷鍵」小節與設定搜尋統一引用 `AppCommandCatalog`（`AppCommandDescriptor`：id / `titleKey` / `CommandShortcut` / `settingsDestination`）。全域性熱鍵類命令的顯示值實時讀 `GlobalHotkeyManager`，使用者改完熱鍵後各處立刻同步。

### 1.3 視窗管理

| 方法 | 職責 |
|------|------|
| `showMainWindow()` | 冪等恢復主視窗：makeKeyAndOrderFront + deminiaturize 最小化視窗；維護 `mainWindows` 列表 |
| `applyInterfaceLanguage(_:)` | 語言切換：空 = 跟隨系統（清 AppleLanguages）；寫偏好後詢問重啟 |
| `availableLanguages` | 語言清單見原始碼與本地化資源，選單顯示各語言自稱 |

狀態圖示：以 03「折角紙頁 + 聲波」製作自訂 SF Symbol（Regular Small / Medium / Large），`image?.isTemplate = true` 適配深淺色，形狀與顏色均由系統處理；錄音狀態由選單項文字表達（錄音中／錄屏中／靜音），錄屏時切換項顯示「停止錄製」。

### 1.4 Dock 圖示顯隱

`NSApp.setActivationPolicy(.regular / .accessory)` 切換；配合 AppDelegate 的 reopen/becomeActive 兜底（見 [02-整體架構](02-Architecture.md) §3）實現"點 Dock 圖示即可恢復"。

## 2. GlobalHotkeyManager — 全域性熱鍵

原始碼：[GlobalHotkeyManager.swift](../../../Memozia/Services/GlobalHotkeyManager.swift)（`@MainActor` 單例）

### 2.1 技術方案

**Carbon `RegisterEventHotKey`**（應用未啟用時也可觸發，這是 Carbon API 在現代 macOS 上仍不可替代的場景）。

### 2.2 預設熱鍵

| 熱鍵 | 功能 | 生效範圍 |
|------|------|----------|
| `⌃⌘R` | 會議錄音開/停切換 | 兩種模式 |
| `⌃⌘S` | 區域截圖（按預設模式） | 兩種模式 |
| `⌃⌘W` | 全屏直拍 | 僅專業模式註冊 |

熱鍵組合可配置（UserDefaults 持久化），`start()`啟動時載入配置並註冊，記錄生效組合。設定入口是獨立的「設定 → 熱鍵」頁（`HotkeySettingsView`），兩種模式均可見；該頁在普通模式隱藏「全屏直拍熱鍵」一行（對應組合在普通模式本就不註冊）。

**錄音熱鍵衝突回退**：`⌃⌘R` 被其他應用佔用（`RegisterEventHotKey` 返回非 `noErr`）時自動改用備選組合 `⇧⌃⌘R`。回退只針對「當前組合仍是預設值」的情形（判定見純函式 `recordingFallbackCombination`）——使用者顯式改過的組合若註冊失敗就如實報失敗，不會被悄悄替換。回退結果只存在記憶體（`recordingHotkeyFellBack`，設定頁據此說明原因），不寫入 UserDefaults：持久化的是**使用者意圖**，因此佔用方消失後下次啟動會自動回到 `⌃⌘R`。

配置約束（`updateHotkey` / `updateFullscreenHotkey` / `updateRecordingHotkey` 返回具體失敗原因，設定頁據此提示）：

- 非功能鍵必須至少帶一個修飾鍵；**F1–F20 可單獨使用**（此類組合修飾鍵為 0，`loadFromDefaults` 以「任一項非 0」判定是否已配置）
- 拒絕應用內重複組合（三條熱鍵兩兩不得相同，統一由 `isDuplicateOfOtherHotkey` 判定）
- 拒絕系統保留組合 `⌃⌘F`（Cocoa 標準選單「進入全螢幕」）

註冊與失敗可見性：三條熱鍵**逐條註冊**，單條失敗隻影響該條（不整體回滾）；失敗的熱鍵記入 `unregisteredHotkeys`（error 級日誌 + 設定頁「熱鍵」頁提示），避免舊實現「一條被佔用即全部失效且介面無提示」。

### 2.4 事件分發

註冊 `EventHandler` → 回撥按熱鍵 ID 分發 `NotificationCenter` 通知：

- `.recordingHotkeyPressed` → RootView `toggleMeetingRecording()`（與工具欄「錄音」按鈕同一動作）
- `.screenshotHotkeyPressed` → RootView 讀取 `screenshotDefaultMode` → `ScreenshotManager.startCapture(mode:)`
- `.fullscreenScreenshotHotkeyPressed` → `ScreenshotManager.captureFullScreenDirect()`

登出/重註冊：設定變更後先 unregister 再 register。

## 3. MainActor+AssumeOnMainThread — AppKit 橋接工具

原始碼：[MainActor+AssumeOnMainThread.swift](../../../Memozia/Services/MainActor+AssumeOnMainThread.swift)

```swift
extension MainActor {
    /// AppKit 同步回调中安全进入 MainActor
    static func assumeOnMainThread(_ body: @MainActor () -> Void)
}
```

**解決的問題**：AppKit 同步回撥（`applicationDidFinishLaunching` 等，無 Task 上下文）直接用 `MainActor.assumeIsolated` 在 macOS 26 上可能觸發 executor 斷言崩潰；此工具只做主執行緒檢查後直接進入 MainActor 上下文。全專案 AppDelegate 回撥統一使用。

## 4. RemindersURLDiagnostic — 提醒事項 URL 診斷

原始碼：[RemindersURLDiagnostic.swift](../../../Memozia/Services/RemindersURLDiagnostic.swift)

一次性診斷工具（詳見 [06-LLM總結與智慧功能](06-AI-Features.md) §4）：`reminders_url_diagnostic` defaults 標記觸發，驗證 EKReminder 的 URL 欄位寫入行為，結果寫 `~/Documents/Memozia/url_diagnostic.txt`，完成後自動清除標記。

## 5. 系統許可權總表

| 許可權 | 用途 | 授權方式 |
|------|------|----------|
| 麥克風（NSMicrophoneUsageDescription） | 會議錄音 | TCC 彈窗 |
| 語音識別（NSSpeechRecognitionUsageDescription） | 系統語音轉寫（macOS 26+） | 按功能請求 TCC 授權 |
| 螢幕錄製 | 系統音訊採集（SCStream）+ 截圖（SCScreenshotManager） | 系統設定，**授權後需重啟應用** |
| 輔助功能（Accessibility） | AppMuteDetector AX 樹輪詢 | 系統設定 |
| 提醒事項（NSRemindersUsageDescription） | 待辦寫入 EKReminder | TCC 彈窗 |
| 網路客戶端（entitlements） | 雲端 API / 模型下載 | entitlements |
| 使用者選擇檔案讀寫（entitlements） | 匯入音訊/匯出文件 | entitlements |

macOS entitlements（[Memozia.entitlements](../../../Memozia/Resources/Memozia.entitlements)）遵循最小許可權：`audio-input` + `network.client` + `files.user-selected.read-write`，**未啟用** App Sandbox（直寫 ~/Documents 需要），**未啟用** `cs.disable-library-validation`（安全考量）。工程已取消 iOS 支援，原 iOS 分享擴充套件的 App Group entitlement 已隨擴充套件刪除。

## 6. 應用更新

原始碼：[AppUpdateService.swift](../../../Memozia/Services/AppUpdateService.swift)、[UpdateInstallationCoordinator.swift](../../../Memozia/Services/UpdateInstallationCoordinator.swift)。

- Sparkle 更新器只在主應用已獲隱私同意並取得持久化容器後啟動；worker、單元測試和 UI 測試不啟動更新器。
- 目前副本未配置更新來源與公鑰，更新器不會啟動，選單和「設定 → 關於」不顯示檢查入口。配置可信更新來源後，自動檢查仍預設關閉，安裝仍須確認。
- 安裝前檢查錄音、錄屏、截圖、匯入、磁碟對賬及處理任務資源，儲存 ModelContext、停止舊 worker 並等待 `EntryMirrorStore.flush()`；非同步等待後再次檢查空閒。失敗會取消退出並提示稍後重試。
- 更新退出不會拉起舊 worker，新版按既有啟動協議接管；退出仍使用 `_exit` 規避 ONNX 靜態析構。
- 獨立發佈時須配置並驗證 stable 更新頻道；目前副本未建立更新頻道。
- 完整的兩版本替換、重啟與許可權連續性需要實際升級驗收；構建與單元測試不能替代這一步。發佈前配置與驗收見 [發佈檢查](../../RELEASE_CHECKLIST.md)。
