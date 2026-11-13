# 12 · 依賴關係

[← 返回首頁](Home.md)

## 1. SPM 三方依賴（project.yml）

| 包 | 版本 | 產品 | 用途 | 備註 |
|----|------|------|------|------|
| **WhisperKit**（argmaxinc/argmax-oss-swift） | from 0.9.0 | WhisperKit | 本地語音轉寫（CoreML 推理） | 模型經 `HF_ENDPOINT=https://hf-mirror.com` 映象下載 |
| **Sparkle** | exact 2.10.0 | Sparkle | 應用更新檢查、簽名校驗與安裝 | 僅 macOS 直髮；MIT 及隨附第三方宣告，完整宣告隨 App 分發；體積須隨 Release 實測 |
| **KeychainAccess**（kishikawakatsumi） | from 4.2.2 | KeychainAccess | API Key / AES 金鑰存取 | `.accessibility(.afterFirstUnlock)` |
| **SherpaOnnx**（k2-fsa/sherpa-onnx） | 固定 revision（見 project.yml） | **sherpa-onnx-shared** | 說話人分離（pyannote segmentation + 3D-Speaker embedding，CPU） | 用 shared 動態產品：靜態 onnxruntime 產物是 ar archive 非標準 framework，嵌入簽名會失敗；透過固定提交避免上游變化破壞可復現性，升級後迴歸分離鏈路 |

`.packages/` 目錄是 SPM 本地快取（checkouts），非工程內容。

本機 MCP 新增 **MCP Swift SDK**（固定 0.12.1，MCP 產品）及 **SwiftNIO**（from 2.65.0，NIOCore/NIOPosix/NIOHTTP1 產品）；解析結果由 Package.resolved 鎖定。SDK 為 MIT/Apache-2.0 過渡許可，SwiftNIO 為 Apache-2.0 及附帶第三方宣告，宣告隨應用資源分發。它們用於 JSON-RPC、HTTP 解析和本機傳輸；無新模型資源。SDK/NIO 會增加原生程式碼體積，另有一份獨立 stdio helper，精確體積隨最終 Release 構建測量，不以 Debug 體積代替釋出估算。入口和使用方式見 [MCP](../../MCP.md)。

### SherpaOnnx 的特殊構建處理

`Scripts/fix_onnxruntime_framework.sh`（preBuild 指令碼）：上游 onnxruntime shared xcframework 佈局非標準（實體目錄替代符號連結），構建前規範為標準 framework 佈局 + 修正 dylib 引用，否則嵌入後 CodeSign 嚴格校驗失敗。

## 2. 系統框架依賴

| 框架 | 使用方 |
|------|--------|
| SwiftUI / SwiftData | 全 UI + 持久化 |
| AVFoundation | 麥克風採集（AVAudioEngine/AVAudioFile）、寫入（AVAssetWriter）、混音（AVMutableComposition/AVAssetExportSession）、時長探測（AVAssetReader） |
| ScreenCaptureKit | 系統音訊採集（SCStream）+ 截圖凍結/直拍（SCScreenshotManager、SCShareableContent） |
| Vision | OCR（VNRecognizeTextRequest） |
| Speech | 系統語音識別（SpeechAnalyzer / SpeechTranscriber，macOS 26+，語言資產由系統管理） |
| CryptoKit | AES-GCM 加密 |
| AppKit | 選單欄（NSStatusItem）、截圖面板（NSPanel/NSView）、視窗管理、分享（NSSharingServicePicker） |
| Carbon（HIToolbox） | 全域性熱鍵（RegisterEventHotKey） |
| CoreAudio | 麥克風靜音監聽（kAudioDevicePropertyMute） |
| ApplicationServices（AXUIElement） | 會議 App 靜音按鈕檢測 |
| EventKit | 提醒事項寫入（EKReminder） |
| Metal | 批次轉寫併發估算（recommendedMaxWorkingSetSize）——批次入口已下線，僅遺留輔助 `calculateMaxConcurrency` 使用，暫無呼叫方 |
| os.log | 統一 Logger（subsystem = bundle ID） |

## 3. 模組間依賴圖

### 3.1 服務依賴（誰用誰）

```
RecordingViewModel ──┬─→ WhisperLocalService ──→ WhisperKit(SPM)
                     ├─→ WhisperAPIService ──→ KeychainAccess(SPM)
                     ├─→ MeetingRecorderService ──┬─→ MicCaptureService
                     │                            ├─→ SystemAudioCaptureService
                     │                            ├─→ AppMuteDetector
                     │                            ├─→ MicMuteMonitor
                     │                            └─→ AudioConverter
                     ├─→ SpeakerDiarizationService ──→ SherpaOnnx(SPM)
                     │        └─→ VoiceprintStore（質心複用）
                     ├─→ ChineseConverterService
                     ├─→ TranscriptDictionaryService（詞典讀取）
                     ├─→ TranscriptCache（渲染快取）
                     ├─→ LLMService ──→ PIIScrubService（脫敏編排）
                     │        └─→ TodoExtractionService
                     │              └─→ RemindersService（EventKit）
                     ├─→ EncryptionService（加密/解密）
                     └─→ FileSyncService（啟動同步/刪除協議）

QuickNoteViewModel ──┬─→ VisionOCRService（圖片 OCR）
                     ├─→ LLMService（generateSummaryFromImage 多模態 / 文字總結 / 標題）
                     ├─→ TodoExtractionService + PIIScrubService
                     ├─→ EncryptionService
                     └─→ RemindersService

SettingsViewModel ───┬─→ KeychainAccess（API Key）
                     └─→ SpeakerDiarizationService（模型下載）

ScreenshotManager ───┬─→ RegionSelectionController（會話）
                     │       ├─→ OverlayAnnotationView（標註）
                     │       └─→ PinnedWindowSession（釘住）
                     └─→ ScreenCaptureKit（許可權/直拍）

RootView ────────────┬─→ 全部 ViewModel（編排）
                     ├─→ TaskCenter（把轉寫/總結/畫面分析/待辦等構造成 Job/Step 投遞；只排程）
                     ├─→ MenuBarController / GlobalHotkeyManager（通知）
                     └─→ ScreenshotManager（通知驅動）

SettingsView/SettingsViewModel ──→ TaskCenter（whisperDownloadJob 模型下載）

TaskCenter ──────────┬─→ WhisperModelDownloader（下載步驟，唯一支援暫停/續傳）
                     └─→ 各 ViewModel 方法（Step 執行體；取消走既有 cancelXxx 入口）

PIIScanService ──────→ LLMService（本地模型分析）
AppUpdateService ────→ Sparkle（更新）+ UpdateInstallationCoordinator（安裝前收尾）
```

### 3.2 資料層依賴

```
AudioRecording ──cascade──→ TranscriptSegment（一對多，級聯刪除）
AudioRecording / QuickNote ──folderName──→ 磁碟資料夾（權威源）
AudioRecording / QuickNote ──ProcessingStatus──→ TaskCenter 佇列面板（重啟後恢復展示「進行中 / 失敗」）
FileSyncService ──→ AudioRecording + QuickNote（磁碟 → DB 補錄）
TodoDocument（todos.json）──→ RemindersService（reminderIdentifier 清理）
所有加密欄位 ──→ EncryptionService ──→ Keychain（金鑰）
```

### 3.3 通知匯流排依賴（松耦合）

GlobalHotkeyManager / MenuBarController / ScreenshotManager → NotificationCenter → RootView（見 [02-整體架構](02-Architecture.md) §6）。服務之間不直接引用 UI，UI 透過通知響應服務事件。

## 4. Target 依賴

```
MemoziaTests ──────→ Memozia（host app）
MemoziaUITests ────→ Memozia（被測應用）
```

工程為 macOS 單平臺：iOS 分享擴充套件 target（原 `MemoziaShareExtension`）與 App Group「inbox」中轉鏈路已刪除。

## 5. 外部資源依賴

| 資源 | 位置 | 說明 |
|------|------|------|
| Whisper 模型 | 使用者選擇目錄，預設見 WhisperModelFolder | 工程排除內建模型；需完整 CoreML 模型與 tokenizer 檔案。設定頁可按檔位下載（WhisperModelCatalog），落盤為 `<模型文件夹>/<档位名>` |
| 分離模型 | `~/Documents/Memozia/DiarizationModel` | segmentation.onnx + embedding.onnx，設定頁從 GitHub Releases 下載（免 HF token）；下載與 Whisper 統一為「取消保留、重下續傳」（URLSession `resumeData` 落盤為 `.resume`） |
| 聲紋庫 | `~/Documents/Memozia/Voiceprints` | JSON，modelId 繫結嵌入模型 |
| 中文詞典資料 | Bundle Resources/ChineseDictionary | 內建基礎詞典 |
| HuggingFace 端點 | hf-mirror.com（預設）/ huggingface.co | 模型下載與 tokenizer 回退按設定的下載源寫 HF_ENDPOINT；WhisperKit 下載另顯式傳 endpoint |
