# 02 · 整體架構

[← 返回首頁](Home.md)

## 1. 分層架構總覽

專案採用經典的 **MV + Service** 分層（SwiftUI 生態下的 MVVM 變體），工程為 macOS 單平臺，按需保留 `#if os(macOS)` 守衛：

```
┌─────────────────────────────────────────────────────────────────┐
│  App 殼層  MemoziaApp.swift + AppDelegate                       │
│  單例項守衛 / fd 限制 / HF 映象 / ModelContainer / 選單命令        │
├─────────────────────────────────────────────────────────────────┤
│  檢視層  Views/                                                   │
│  RootView（NavigationSplitView 樞紐）                             │
│  ├── RecordingListView（錄音+筆記合併側邊欄）                      │
│  ├── RecordingDetailView → Transcript / Summary / VideoUnderstanding│
│  ├── QuickNoteDetailView / Screenshot 截圖與標註元件              │
│  ├── SettingsView / HelpView / OnboardingView / PrivacyConsent   │
│  └── MarkdownView / TextFindReplace                              │
├─────────────────────────────────────────────────────────────────┤
│  ViewModel 層  ViewModels/（@MainActor @Observable）              │
│  RecordingViewModel（轉寫/總結/待辦/錄音編排核心樞紐）      │
│  QuickNoteViewModel / SettingsViewModel                          │
├─────────────────────────────────────────────────────────────────┤
│  服務層  Services/（狀態型服務多為 @MainActor @Observable）   │
│  ① 錄音採集：MeetingRecorderService（總控）                        │
│     ├ MicCaptureService（AVAudioEngine）                          │
│     ├ SystemAudioCaptureService（ScreenCaptureKit）               │
│     ├ AppMuteDetector（AX 輪詢）/ MicMuteMonitor（CoreAudio）      │
│     └ AudioConverter（時長/轉換）                                  │
│  ② 轉寫管線：WhisperLocalService / WhisperAPIService              │
│     ├ SpeakerDiarizationService + VoiceprintStore（分離+聲紋）     │
│     ├ TranscriptDictionaryService / ChineseConverterService      │
│     └ TranscriptCache（渲染快取）                                  │
│  ③ 智慧功能：LLMService / TodoExtractionService                   │
│     ├ KeyframeExtractor / VideoUnderstandingService（影片理解）     │
│     ├ RemindersService（EventKit）/ PIIScrubService               │
│     └ PIIScanService（本地模型掃描）                                │
│  ④ 截圖子系統：ScreenshotManager / VisionOCRService               │
│  ⑤ 同步與安全：FileSyncService / CloudSyncService                  │
│     └ EncryptionService（AES-GCM + Keychain）                     │
│  ⑥ 系統整合：MenuBarController / GlobalHotkeyManager              │
│     └ RemindersURLDiagnostic / MainActor+AssumeOnMainThread      │
│  ⑦ 任務排程：TaskCenter（全域性處理佇列 + AsyncClassGate 資源門）    │
├─────────────────────────────────────────────────────────────────┤
│  資料層  Models/                                                   │
│  SwiftData：AudioRecording ⇄ TranscriptSegment、LLMConfig、       │
│             QuickNote（截圖作為圖片型 QuickNote）                   │
│  值型別配置：STTConfig / RecordingConfig / TodoItem(+TodoDocument)│
│  磁碟權威源：~/Documents/Memozia/yyyy-MM/yyyyMMddHHmmss[-N]/ 資料夾體系        │
├─────────────────────────────────────────────────────────────────┤
│  三方依賴（SPM）：WhisperKit · KeychainAccess · SherpaOnnx · Sparkle│
└─────────────────────────────────────────────────────────────────┘
```

**分層規則**：View 只依賴 ViewModel 與 SwiftData `@Query`；ViewModel 編排服務；服務之間透過單例引用或 `NotificationCenter` 解耦通訊；跨 actor 傳值用值型別快照（如 `LLMConfigSnapshot`）避免傳遞 SwiftData 物件。

### 1.1 普通 / 專業體驗邊界

`AppExperienceStore` 是 SwiftUI 可觀察的模式狀態，`AppExperiencePreference` 是 AppKit 選單、熱鍵與後臺程式碼共用的無 UI 存取層，`FeaturePolicy` 統一判定能力可見性與是否允許發起。`EffectiveSettingsResolver` 在任務邊界把使用者儲存的專業設定解析成本次實際使用的錄音、STT、截圖與 PII 策略。

兩種模式共用同一 target、SwiftData schema、檔案格式與服務實現。切換模式不會重寫專業配置；普通模式的會議場景和本地轉寫模型路徑使用獨立偏好。新使用者預設普通模式，舊版已完成引導的使用者在首次遷移時保持專業模式。截圖/錄屏等全域性入口同時在選單、熱鍵、RootView 通知接收和服務邊界校驗，不依賴單一檢視隱藏保證邊界。

## 2. 核心資料流

### 2.1 會議錄音 → 轉寫 → 總結（主鏈路）

```
使用者點選「開始錄音」（選單欄/側邊欄）
  → RecordingViewModel.startMeetingRecording
  → MeetingRecorderService.startRecording
      ├─ 磁碟預檢（≥500MB）→ 建立 ~/Documents/Memozia/yyyy-MM/yyyyMMddHHmmss[-N]/
      ├─ 按 RecordingSource 啟動採集：
      │   ├─ .microphone → MicCaptureService（AVAudioFile，CAF/PCM 分片）
      │   ├─ .systemAudio → SystemAudioCaptureService（SCStream，WAV/PCM 分片）
      │   └─ .mixed → 雙路並行（mic + sys 各自分片）
      ├─ 每 300s 分片輪轉（rotateSegment/rotateWriter）
      ├─ AppMuteDetector（AX 1s 輪詢 Teams/Zoom 靜音按鈕）
      └─ MicMuteMonitor（CoreAudio mute 屬性監聽）
  ↓
使用者點選「停止錄音」
  → stopMeetingRecording → stopRecording
      ├─ mergeSegments：AVMutableComposition 雙軌混音 → m4a
      │   （失敗回退單軌拼接；崩潰遺留分片校驗時長後恢復）
      └─ 建立 AudioRecording 記錄 + saveMetaToFolder（meta.json）
  ↓
使用者點選「轉寫」/「一鍵處理」（單條任務經處理佇列排程，見 §3.4）
  → 投遞到 TaskCenter 的 Job，轉寫步驟呼叫 RecordingViewModel.startTranscription
      ├─ 系統模式：SystemTranscription → SystemTranscriptionService（macOS 26+，按需準備語言資產）
      ├─ 本地模式：WhisperLocalService（WhisperKit/CoreML，序列門）
      ├─ 雲端模式：WhisperAPIService（multipart，>25MB 分片）
      └─ 後處理鏈（順序固定）：
          ① SpeakerDiarizationService（可選，按時間重疊回填 speaker）
             └─ VoiceprintStore 聲紋識別（可選，替換為註冊姓名）
          ② ChineseConverterService 繁簡歸一化
          ③ TranscriptDictionaryService 詞典糾正（精確 + 拼音）
          ④ EncryptionService 加密 → TranscriptSegment[] 入庫
          ⑤ 轉寫檔案寫盤（transcript.json）
  ↓
使用者選擇 LLM 配置 → 「生成總結」
  → RecordingViewModel.generateSummary
      ├─ PIIScrubService.scrub（僅雲端 LLM 且開關開啟）
      ├─ LLMService.generateSummary（SSE 流式，onToken 逐段渲染）
      ├─ PIIScrubService.restore（流式全文還原）
      ├─ 加密儲存 recording.summary + summary.md 寫盤
      └─ LLMService.generateTitle 自動命名
  ↓
使用者點選「拆解待辦」
  → TodoExtractionService.extract（JSON 結構化輸出）
  → PIIScrubService.restore(TodoDocument)
  → TodoDocument 持久化（todos.json，加密）
  → 使用者確認 → RemindersService 寫入系統提醒事項（EventKit）
```

### 2.2 截圖 → 圖片筆記（輔鏈路）

```
全域性熱鍵 ⌃⌘S（Carbon）或選單欄/應用內選單
  → GlobalHotkeyManager → NotificationCenter(.screenshotHotkeyPressed)
  → RootView → ScreenshotManager.startCapture(mode)
      ├─ 許可權預檢（CGPreflight/CGRequestScreenCaptureAccess）
      ├─ ⌃⌘W 全屏直拍：captureFullScreenDirect（滑鼠所在屏，SCScreenshotManager）
      └─ 區域/視窗/全屏會話：ScreenshotOverlayController
          ├─ 凍結螢幕圖 → 框選 / 視窗拾取（SCShareableContent）
          └─ OverlayAnnotationView 標註（形狀/文字/撤銷重做/貼圖置頂）
              └─ 複製到剪貼簿 / 儲存到桌面 / 完成入庫
  → NotificationCenter(.screenshotCaptureSaved, originalPNG/markedPNG)
  → RootView.handleScreenshotSaved
  → QuickNoteViewModel.createQuickNote(fromImage:)   ← 轉為圖片型快捷筆記
  → （可選）VisionOCRService.recognizeText → OCR 文字加密入庫
  → （可選）LLMService.generateSummaryFromImage 多模態總結
```

> 截圖不使用獨立資料實體：確認後的最終圖片統一轉為 QuickNote，複用圖片筆記的 OCR、總結、待辦、同步與刪除能力，詳見 [07-截圖與OCR](07-Screenshots-and-OCR.md)。

### 2.3 分享擴充套件匯入（已下線）

工程原有一個 iOS Share Extension（`MemoziaShareExtension`）經 App Group `inbox/` 把分享的音訊/文字/圖片轉交主應用。**iOS 支援已整體取消**：該 target、App Group 鏈路與主應用側的匯入方法（`importFromShareExtension`）均已刪除；音訊匯入只剩工具欄/拖拽兩條路徑（見 [10-ViewModel層](10-ViewModels.md)）。

## 3. 生命週期與後臺任務

入口：[MemoziaApp.swift](../../../Memozia/MemoziaApp.swift)、[BackgroundWorker.swift](../../../Memozia/Services/BackgroundWorker.swift)、[BackgroundTaskQueue.swift](../../../Memozia/Services/BackgroundTaskQueue.swift)。

### 3.1 啟動與退出

macOS 程序入口依次處理 `calibrationHook`、`backgroundWorkerHook`、`runtimeVerificationHook`、`singleInstanceGuard` 與 fd 限制提升。普通啟動由 `StartupCoordinator`（`StartupBootstrap.swift`）非同步執行 worker 停止握手 → 取得資料庫獨佔鎖 → 建立 ModelContainer；`StartupRootView` 展示階段、失敗原因和重試入口。
帶校準、worker 或執行時自檢引數時先處理專用入口；普通重複例項先退出。阻塞的握手和加鎖放到後臺執行，不在 App 屬性初始化期間阻塞主執行緒。
接管判據是 `DatabaseOwnershipLock`（儲存目錄下 `.db_ownership.lock` 上的 `flock`）：主應用在寬限內等守護程序讓出鎖，拿不到就**不開啟可寫容器**，展示資料庫佔用或鎖檔案失敗原因；使用者可重試，或明確選擇臨時記憶體模式（本次執行不落盤）。worker 同樣先取得鎖再開容器，拿不到就保留佇列退出。程序退出（含崩潰）由核心釋放鎖，因此不會出現「PID 已死但鎖未釋放」。
容器在持久化失敗時同樣展示錯誤，可重試或選擇臨時記憶體模式；CloudKit 配置尚未啟用。RootView 的隱私同意門控任務序列處理遷移、狀態重置、磁碟對賬與遺留佇列續跑（模型預熱是唯一併行的獨立任務），具體次序查生命週期 modifier。

退出時若合併進行中，按預計結束時間加餘量非同步等待（有上下限）；隨後**先緊急收尾錄音**（分片 finalize 最不可逆），再 `EntryMirrorStore.flush()` 有界等待條目映象落盤，然後按需拉起 worker、解除安裝模型，最後**直接結束程序**（`ProcessLimits.exitSkippingStaticDestructors` → `_exit`，跳過 `exit()` 的 C++ 靜態析構）：onnxruntime / SherpaOnnx 的靜態全域性物件在 `__cxa_finalize_ranges` 裡析構時會 abort，曾表現為「用過說話人分離後退出應用必崩」。同類 `exit()` 入口（單例項守衛、校準工具、守護程序、隱私拒絕）一律走該助手。
視窗恢復由 AppDelegate / MenuBarController 冪等處理；不能把關視窗等同於退出應用。

### 3.2 產品決策與邊界

- 同一應用二進位制以 `--background-worker` 啟動無 UI 程序，複用服務，不額外建 target。
- 只續跑使用者已啟動的轉寫、錄音總結、快捷筆記總結任務，並恢復遺留分片；不自動給從未操作的條目發起 AI 請求。
- worker 不阻止系統休眠，喚醒後繼續；佇列清空自動退出。
- 主應用啟動請求 worker 收尾讓位，意圖是單方持有資料庫並消費佇列；正常情況下完成當前任務後退出。
- 握手等待引數由 `StartupDependencies.live()` 與 `BackgroundWorker.requestWorkerStop` 的呼叫方決定；寬限超時後可發 SIGTERM。程序仍存活也不能繞過資料庫鎖，拿不到鎖時只允許重試或由使用者選擇臨時記憶體模式。
- 影片畫面分析不進入後臺佇列；不能宣稱關 App 後可續跑抽幀/視覺請求。

### 3.3 佇列與程序協議

| 物件 | 契約 |
|---|---|
| `.background_task_queue.json` | 可配置儲存根目錄下的持久佇列；條目含 kind、folderName、配置 ID/快照及入隊時間 |
| STT 快照 | 儲存模型、語言和後處理配置；API Key 不落 JSON，執行時從 Keychain 讀取 |
| LLM 配置 | 按配置 ID 查詢；失配時的 active/首個配置回退見 `execute`，不是快照鎖定所有 LLM 引數 |
| 佇列寫入 | 臨時檔案替換；讀改寫使用 flock，消費交接另由握手協調。鎖檔案打不開或超時則明確失敗、不執行修改；損壞佇列隔離後嘗試備份恢復，不把讀失敗當空佇列覆蓋 |
| `inProgressID` | 崩潰後清除執行標記，未出隊條目視為待續跑；入隊按型別和目標冪等去重 |
| PID / stop 檔案 | `.background_worker.pid` 與 `.background_worker_stop` 協調存活、停止與接管 |

worker 先恢復分片（不開資料庫），再建立自己的 ModelContext 消費佇列；不跨程序傳 `@Model` 物件。
佇列處理由 MainActor Task 與 RunLoop 驅動，不可阻塞主執行緒使業務回撥死鎖；當前輪詢細節見 `run`。
`drainQueue` 僅在完成或確認目標已不存在時出隊；讀庫、網路、模型和憑據阻塞失敗保留任務，以 `attempt`、`nextRetryAt` 和穩定失敗碼記錄指數退避，達到 `Backoff.maxAttempts` 後移入 `failedEntries`，支援顯式重試。執行標記、出隊或退避記錄無法落盤時立即停止消費，避免重複執行。
快捷筆記在 worker 中生成內容並儲存待辦，不觸發需要介面的提醒事項授權/寫入流程。
主應用可複用 `drainQueue` 兜底續跑；異常接管、退出、恢復與雙例項迴歸見 [技術債](../../TECH_DEBT.md)。

### 3.4 應用內處理佇列（TaskCenter）

[TaskCenter.swift](../../../Memozia/Services/TaskCenter.swift) 是程序級單例（`@MainActor @Observable`），把應用內所有「可排隊的處理任務」統一到一處排程與展示，與上文的 `BackgroundTaskQueue`（跨程序、守護程序消費）是**兩套不同機制**：前者只活在主應用程序內，後者是磁碟持久佇列。

- **任務種類**（`TaskKind`）：下載模型 / 轉寫 / 畫面分析 / 總結 / 潤色標題 / 拆解待辦，並給每種資源類分類。錄音與錄屏是實時會話，必須立即開始，**不進本佇列**。
- **排程**：同時執行的 Job 上限 `maxConcurrentJobs = 3`；Job 由若干 `Step` 按順序執行。資源類再由 `AsyncClassGate` 限流——本地推理（轉寫 / 畫面分析）1、下載 1、網路 LLM 3，與「單例項推理序列門」疊加不衝突（那個門保護底層推理例項，這個門保護排程層步驟數）。
- **一鍵處理**：不攤平成多個獨立 Job，而是**一個父 Job 內含多個順序子步驟**（轉寫 → 畫面分析 → 總結 → 拆解待辦），以免破壞「轉寫先備模型、總結後自動潤色標題」這類既有依賴。Job 名取當前條目標題。入隊前先經 `OneClickPlan`（純資料，可單測）+ `OneClickPreviewView` 出預覽：按**產物**判定已完成步驟並預設跳過（僅「重新轉寫」顯式開啟才覆蓋已有轉寫；轉寫有手動編輯時先備份為 `transcript.backup.md`），雲端圖片 / 影片幀的資料範圍也在預覽中說明。
- **失敗處理與重試**：步驟失敗時由執行體上報**穩定錯誤碼**（`TaskErrorCode`，不落英文 `localizedDescription`），排程器補記失敗時刻；失敗 Job 保留在佇列的「最近失敗」區，可「重試此步驟」（只重排失敗步驟）、「重新執行整個任務」，並按錯誤碼提供開啟設定 / 在 Finder 中顯示 / 開啟系統設定等修復入口。
- **暫停 / 續傳**：只有下載模型（`TaskKind.canPause`）支援真正的暫停與續傳——暫停即取消底層下載並保留分片與 `.cache` 後設資料，繼續時重新排程該步即從斷點續傳；其餘任務沒有續傳遊標，暫停等價於取消。
- **只做排程**：每個 Step 的執行體呼叫既有 ViewModel 方法並 `await` 其 Task，不重寫業務邏輯；取消轉發到既有 `cancelXxx` 入口。
- **狀態恢復**：佇列面板重啟後能顯示「進行中 / 失敗」，靠的是模型上的持久化 `ProcessingStatus` 欄位（見 [03-資料模型層](03-Data-Models.md) §1.1），而非 TaskCenter 自身的記憶體狀態；失敗碼與失敗時刻只活在本次執行的佇列裡（重啟後不保留）。
- **邊界**：TaskCenter 不影響守護程序——應用退到後臺後任務語義仍由 §3.3 的握手協議保證；錄屏抽幀等畫面分析不進後臺佇列（守護程序無抽幀能力）。

## 4. 磁碟儲存佈局（權威資料來源）

預設儲存根目錄為 `~/Documents/Memozia/`，可在設定中修改。新條目歸入 `yyyy-MM` 月份目錄，讀取相容舊平鋪目錄；錄音/筆記共用路徑工具，截圖按圖片筆記儲存。資料夾名 `yyyyMMddHHmmss[-N]`：

```
~/Documents/Memozia/
├── 2026-09/20260909103000/               # 一條錄音或快捷筆記（截圖屬於圖片筆記）
│   ├── recording.m4a             #   最終錄音（分片合併產物）
│   ├── {base}_video.mp4         #   影片匯入時留存的原始影片（可選，不加密）
│   ├── frames/kf_NN_秒s.jpg     #   畫面要點抽出的關鍵幀（重新分析時複用快取）
│   ├── visual.md                #   畫面要點（加密映象，僅影片條目）
│   ├── meta.json                 #   後設資料（title/itemType: recording|quicknote）
│   ├── transcript.json           #   轉寫片段（含說話人）
│   ├── summary.md                #   總結（加密映象）
│   ├── todos.json                #   AI 待辦（加密）
│   ├── source.txt                #   快捷筆記正文（加密）
│   ├── source.png                #   圖片筆記/截圖最終圖片（不加密）
│   ├── ocr.txt                   #   OCR 文字（加密）
│   └── *_mic_tmp_*.caf / *_sys_tmp_*.wav  # PCM 臨時分片，停止後合併清理
├── WhisperModel/                 # 本地 Whisper 模型資料夾（使用者下載/指定）
├── DiarizationModel/             # 說話人分離模型（segmentation.onnx + embedding.onnx）
├── Voiceprints/                  # 聲紋庫（<uuid>.json：姓名+向量+modelId）
├── Dictionary/                   # Markdown 詞典（糾正詞條 + PII 標記詞條）
└── url_diagnostic.txt            # 提醒事項 URL 診斷輸出（一次性）
```

**雙向同步**：`FileSyncService` 啟動時掃描上述目錄，把磁碟上的錄音/筆記補錄進資料庫（資料庫是磁碟的映象）；刪除操作先刪磁碟再刪 DB 記錄（防"復活"）。

## 5. 併發模型（Swift 6 嚴格併發）

| 場景 | 方案 |
|------|------|
| UI 繫結服務 | `@MainActor @Observable final class` + `shared` 單例 |
| 後臺音訊執行緒回撥 | `installTap` / `SCStreamOutput` 閉包執行在實時音訊執行緒，所在服務**不標 @MainActor**，用 `nonisolated` + `@unchecked Sendable` 包裝盒封裝 `AVAudioFile` 等非 Sendable 物件 |
| 單例項推理引擎 | WhisperKit/sherpa-onnx 不支援併發，經 **actor 序列門（非同步訊號量）** 排隊 |
| 跨 actor 訪問 | 模型引用使用同步保護的 `ModelBox`；SwiftData 物件改為 ID 或值型別快照（`LLMConfigSnapshot`），不靠 unsafe 標註繞過同步 |
| C 回撥橋接 | CoreAudio/Carbon 回撥內 `Task { @MainActor in }` 跳回主執行緒；AppKit 同步回撥用 `MainActor.assumeOnMainThread`（規避 macOS 26 executor 斷言） |
| 取消傳播 | 長任務 `Task.checkCancellation()`；WhisperKit 回撥沿用顯式取消標誌，呼叫方取消須轉發到推理 |
| 首次建立競態 | Keychain 金鑰等"讀不到就建立"模式：鎖 + 雙重檢查 + 記憶體快取 |

併發與回撥經驗見 [專案實踐](../../../DEVELOPMENT_GUIDE.md) §2。

## 6. 通知匯流排（ NotificationCenter 解耦）

跨元件通訊統一走自定義 `Notification.Name`（定義見 `ScreenshotNotifications.swift` 與各服務）：

| 通知 | 傳送方 | 接收方 |
|------|--------|--------|
| `screenshotHotkeyPressed` / `fullscreenScreenshotHotkeyPressed` | GlobalHotkeyManager | RootView → ScreenshotManager |
| `recordingHotkeyPressed` | GlobalHotkeyManager | RootView → `toggleMeetingRecording()`（錄音全域性熱鍵 ⌃⌘R） |
| `menuBarStartRecording` / `menuBarStopRecording` | MenuBarController | RootView → RecordingViewModel |
| `menuBarStartScreenshot` / `menuBarStartDelayedScreenshot` | MenuBarController | RootView → ScreenshotManager |
| `screenshotCaptureSaved` | ScreenshotManager | RootView → QuickNoteViewModel（轉圖片筆記） |
| `screenshotPermissionNeeded` / `screenshotErrorOccurred` | ScreenshotManager | RootView（彈窗） |
| `menuBarOpenSettings` / `openHelp` / `menuBarCreateQuickNoteFromClipboard` | MenuBarController / 選單命令 | RootView |
| `MemoziaShowMainWindowFromOtherInstance`（分散式通知） | 新例項退出前 | 舊例項 AppDelegate（恢復主視窗） |

## 7. 架構特徵總結

1. **服務單例化**：狀態型系統服務多為 `@MainActor @Observable` 單例，純計算與音訊回撥有獨立隔離邊界，ViewModel 直接持有引用，簡單直接（犧牲可測試性換取跨模組訪問便利）
2. **檔案系統權威 + 資料庫索引**：任何 SwiftData 記錄都能從磁碟資料夾重建，是本專案資料可靠性的基石
3. **漸進降級**：呼叫方加密失敗回退明文並通知（讀路徑 `decryptSafely` 相容）、資料庫失敗回退記憶體、混音失敗回退單軌、分離失敗回退無說話人、聲紋失敗靜默跳過——每個環節都有降級路徑
4. **平臺守衛內聯**：macOS 專屬程式碼（AppKit/Carbon/ScreenCaptureKit/AX）以 `#if os(macOS)` 內聯在共享檔案中，而非分目錄
5. **處理任務統一入隊**：應用內可排隊任務（下載 / 轉寫 / 畫面分析 / 總結 / 潤色標題 / 拆解待辦）收斂到 `TaskCenter`（最多 3 併發 + 資源類限流），「一鍵處理」是單個父 Job 的順序子步驟；與跨程序後臺佇列分工明確
