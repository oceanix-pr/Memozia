# 10 · ViewModel 層

[← 返回首頁](Home.md) · 原始碼目錄：[Memozia/ViewModels](../../../Memozia/ViewModels)

三個業務 ViewModel，全部為 `@MainActor @Observable final class`（Swift 6 併發標註），服務依賴以單例引用方式注入。

| ViewModel | 職責域 |
|-----------|--------|
| [RecordingViewModel](../../../Memozia/ViewModels/RecordingViewModel.swift) | 錄音/轉寫/總結/待辦全鏈路（核心樞紐） |
| [QuickNoteViewModel](../../../Memozia/ViewModels/QuickNoteViewModel.swift) | 快捷筆記（文字/圖片/剪貼簿）+ OCR + 總結 + 待辦 |
| [SettingsViewModel](../../../Memozia/ViewModels/SettingsViewModel.swift) | 全部設定項持久化 + LLM 配置管理 |

## 1. RecordingViewModel — 核心業務樞紐

### 1.1 宣告與依賴

```swift
@MainActor @Observable final class RecordingViewModel
```

- `whisperLocalService = WhisperLocalService.shared`：本地轉寫
- `meetingRecorder = MeetingRecorderService.shared`：**直接暴露給 View 觀察**（computed property 不追蹤 @Observable 依賴，故用 let 儲存屬性）
- 可觀察狀態：轉寫進度/階段、匯入進度文字、`summaryText`（流式總結緩衝）、`showError`/錯誤訊息、`isMergingAudio`、`selectedRecording` 等
- 音訊匯入只有工具欄選擇與主視窗拖拽兩條入口（原 iOS Share Extension inbox 鏈路已刪除）

### 1.2 轉寫域

| 方法 | 職責 |
|------|------|
| `startTranscription` | 單條轉寫入口：置 `.processing` → 校驗音訊 → 系統（SystemTranscription / SystemTranscriptionService，macOS 26+）、本地（WhisperLocalService）或雲端（WhisperAPIService）分流 → 更新進度 |
| 轉寫後處理鏈 | 固定順序：說話人分離（可選）→ 繁簡歸一化 → 詞典糾正 → 加密 → 建立 `TranscriptSegment[]` → 轉寫檔案落盤 → 狀態 `.completed/.failed`（詳見 [05-語音轉寫與說話人分離](05-Transcription-and-Diarization.md) §9） |
| `cancelTranscription` | 取消入口，轉發到推理與序列門 |
| `resetStaleProcessingStates` | 啟動時把崩潰遺留的 `.processing` 重置為 `.pending`；覆蓋 `transcriptionStatus / summaryStatus / visualStatus / todoStatus` 與 `QuickNote` 的 `summaryStatus / todoStatus` |

> **批次入口已移除**：批次轉寫 / 批次總結的發起入口（`startBatchTranscription` / `startBatchSummary` / `cancelBatch*`）及其 TaskGroup + 訊號量併發排程已刪除。列表右鍵只保留「一鍵處理」（投遞到處理佇列，見 [02-整體架構](02-Architecture.md) §3.4）；`calculateMaxConcurrency`、`shouldContinueBatchLoop` 等遺留輔助暫無呼叫方。

### 1.3 總結域

```
generateSummary(recording, llmConfig, …)
  ① 讀取 transcriptMarkdown（解密拼接，含快取）
  ② [雲端 && enablePIIScrub] PIIScrubService.scrub → mapping
  ③ LLMService.generateSummary(onToken: 流式追加到 summaryText → UI 實時渲染)
     （onAttemptStart 時清空已展示部分結果，防重試重複拼接）
  ④ PIIScrubService.restore(全文, mapping)
  ⑤ 異常時儲存部分摘要（不丟已生成內容）
  ⑥ 加密儲存 recording.summary + summary.md 落盤
  ⑦ LLMService.generateTitle 自動生成標題
```

單條總結由處理佇列排程（View 層構造 Job 並 `await` 本方法的 Task），不再有批次總結迴圈。

### 1.4 待辦域

```
extractTodos：summary → [PII scrub] → TodoExtractionService.extract
  → PIIScrubService.restore(TodoDocument) → todos.json 加密落盤
  → 使用者確認 → RemindersService 寫入提醒事項
```

### 1.5 會議錄音域

| 成員 | 職責 |
|------|------|
| `meetingRecorder` | 直接暴露服務例項供 View 觀察 |
| `isMeetingRecording` / `recordingElapsed` / `isRecordingMuted` / `recordingMuteSource` | UI 繫結計算屬性（轉發服務狀態） |
| `startMeetingRecording(config:context:)` | Task 包裹啟動，錯誤彈窗 |
| `stopMeetingRecording(context:source:)` | `isMergingAudio` + `mergePhase` 標誌（轉發 `MeetingRecorderService`，介面按「檢查分片 → 回聲消除 → 混音匯出 → 儲存」顯示進度；僅回聲消除階段經 `cancelEchoReduction()` 提供取消）→ stopRecording → lastError 提示（合併降級/系統音訊停止）→ `AudioConverter.getDuration` → 建立 `AudioRecording` + `saveContextWithRetry`（短退避重試，應對長錄音合併後瞬時 fd 耗盡）→ `saveMetaToFolder` → 選中展示 |

### 1.6 資料管理域

- **匯入**：拖拽（RootView handleDrop，`AudioImportValidator` 校驗副檔名+真實音訊型別）、檔案選擇
- **刪除**：先載入 TodoDocument 清理提醒事項殘留 → 先刪磁碟資料夾 → 後刪 DB 記錄（檔案刪除失敗保留記錄防"復活"）；單刪/批刪均彈確認
- **合併錄音**：`orderedMergeCandidates` 校驗至少兩筆純錄音並按建立時間排序（同時間用 ID 穩定排序）；`mergeRecordings` 在使用者確認後把完整快照交給 `RecordingMergeService`。實際音軌時長決定拼接點與轉寫偏移，總結按順序拼接、待辦保留提醒事項標識。暫存完整目標目錄，經映象成功與音訊校驗後原子交換；索引儲存失敗回滾，成功後才刪較早條目。刪除失敗保留剩餘條目並提示，目標內的合併來源 ID 防止重複拼接。舊式根目錄錄音可參與合併；最新條目若無獨立目錄，用 `createUniqueFolder` 原子分配並遷入月份目錄。
- **編輯**：segment 文字編輯、說話人改名（聲紋註冊入口）、`invalidateTranscriptCache` 失效快取
- **匯出**：轉寫/總結匯出 txt/md（ExportDocuments）、錄音檔案分享（NSSharingServicePicker 錨定主視窗彈出）

## 2. QuickNoteViewModel — 快捷筆記

### 2.1 職責

無錄音場景的速記中心：文字/圖片/剪貼簿三種來源，AI 總結與待辦提取。

### 2.2 關鍵方法

| 方法 | 職責 |
|------|------|
| 剪貼簿筆記 | 讀取 `NSPasteboard` 圖片/文字 → 建筆記（僅 macOS） |
| `createQuickNoteFromClipboard` | 剪貼簿文字/圖片一鍵建筆記（選單欄入口） |
| `createQuickNote(fromImage:)` | **截圖入庫主路徑**（RootView 呼叫） |
| AI 總結 | 圖片筆記：`supportsVision` 走 `generateSummaryFromImage` 多模態，否則先 OCR；文字筆記：文字總結；均流式渲染 + 加密儲存 + 自動標題 |
| 待辦提取 | 優先文字內容（文字+OCR 合併），無文字時從圖片提取；支援 PII 脫敏 |
| 刪除/重新命名 | 同錄音刪除協議（先磁碟後 DB） |

## 3. SettingsViewModel — 設定持久化

### 3.1 職責域

| 分組 | 內容 |
|------|------|
| STT | 模式（系統/本地/雲端，系統模式僅在支援時顯示）、模型資料夾（預設 `~/Documents/Memozia/WhisperModel`）、雲端 API URL/Key、語言 |
| 說話人分離 | 開關、模型路徑（預設 `DiarizationModel`）、聲紋識別開關 |
| 詞典 | 糾正開關、PII 脫敏開關 |
| LLM | 多套配置 CRUD、當前生效配置 |
| 錄音 | 來源（mic/systemAudio/mixed）、靜音選項 |
| 捕獲 | 螢幕錄製許可權、預設模式、錄屏聲源/質量偏好 |
| 熱鍵 | 錄音 / 截圖 / 全屏直拍三條全域性熱鍵的錄製與恢復預設（獨立頁面，見 [系統整合](09-System-Integration.md) §2） |
| 體驗模式 | 普通模式的會議場景、獨立 Whisper 路徑；Pro 原始設定保留不變 |

### 3.2 持久化機制

- **讀取**：啟動時逐項從 UserDefaults 載入；Whisper API Key 從 **Keychain**（KeychainAccess）讀取
- **儲存**：修改即寫回 UserDefaults；API Key 寫 Keychain（不落 UserDefaults）
- **配置轉換**：`makeSTTConfig(experience:)` / `makeRecordingConfig(experience:)` 先生成已儲存配置，再經 `EffectiveSettingsResolver` 得到當前模式的有效配置；解析過程不回寫 Pro 設定。`getActiveLLMConfig` 在儲存 ID 失效時穩定回退到現存第一個配置；`setActiveLLMConfig` 是**唯一**的活動模型入口——設定頁與錄音/筆記詳情頁的模型選擇器都調它（寫 ID 後 `saveSettings`），因此「活動模型」只有一份事實源，重開條目或重啟應用後選擇保持一致。

## 4. View ↔ ViewModel 繫結關係

| View | 依賴的 VM |
|------|-----------|
| RootView | RecordingViewModel（主依賴）+ QuickNoteViewModel + SettingsViewModel |
| RecordingListView | 經 RootView 傳入 RecordingViewModel（刪除/重新命名/批次操作） |
| RecordingDetailView | RecordingViewModel（轉寫/總結/待辦/畫面理解） |
| TranscriptView | RecordingViewModel（編輯/快取失效/聲紋註冊） |
| SummaryView | RecordingViewModel（summaryText 流式/重新生成/待辦） |
| VideoUnderstandingView | RecordingViewModel（visualNotesText 流式/取消/持久化），管線委託 VideoUnderstandingService |
| QuickNoteDetailView | QuickNoteViewModel |
| SettingsView | SettingsViewModel |
