# 03 · 資料模型層

[← 返回首頁](Home.md) · 原始碼目錄：[Memozia/Models](../../../Memozia/Models)

資料層包含三類角色：

1. **SwiftData 持久化實體**（`@Model`）：`AudioRecording`、`TranscriptSegment`、`LLMConfig`、`QuickNote`；截圖作為圖片型 `QuickNote` 入庫
2. **值型別配置結構**（UserDefaults/Keychain 持久化）：`STTConfig`、`RecordingConfig`
3. **檔案級資料結構**：`RecordingCaptureReport`（`capture_report.json`，採集完整性說明與觀察區間，無會議內容）及 `TodoItem` + `TodoDocument`（todos.json）、`ExportDocuments`（匯出）

> SwiftData 注意：`@Model` 宏與計算屬性衝突，**所有計算屬性放在 `extension` 中**（本專案統一約定）。

## 1. AudioRecording — 錄音實體

原始碼：[AudioRecording.swift](../../../Memozia/Models/AudioRecording.swift)

### 1.1 狀態列舉（TranscriptionStatus / ProcessingStatus）

```swift
enum TranscriptionStatus: String, Codable {
    case pending      // 待转写（初始态）
    case processing   // 转写中
    case completed    // 已完成
    case failed       // 失败
}

// 通用处理状态：总结 / 画面要点 / 待办拆解（语义与 TranscriptionStatus 对齐）
enum ProcessingStatus: String, Codable {
    case pending      // 未开始
    case processing   // 处理中
    case completed    // 已完成
    case failed       // 失败
}
```

`ProcessingStatus` 為這些任務補上**持久化**狀態（過去只存在於 ViewModel 的瞬時屬性裡，程序重啟即丟失），佇列面板才能重啟後恢復展示「進行中 / 失敗」。啟動時 `RecordingViewModel.resetStaleProcessingStates` 會把崩潰遺留的 `.processing` 復位為 `.pending`——覆蓋 `AudioRecording.transcriptionStatus / summaryStatus / visualStatus / todoStatus` 與 `QuickNote.summaryStatus / todoStatus`。

### 1.2 持久化欄位

| 欄位 | 型別 | 說明 |
|------|------|------|
| `id` | UUID | 主鍵 |
| `fileName` | String | 顯示名（如"會議錄音 2026/9/9 10:30"） |
| `fileExtension` | String | 副檔名（m4a 等） |
| `duration` | TimeInterval | 時長秒 |
| `storedFileName` | String | 磁碟檔名（UUID 命名防衝突） |
| `audioRemovedAt` | Date? | 僅清理音訊原件的時間；路徑和時長隨 meta.json 保留，檔案缺失時仍能從磁碟重建條目與文字內容 |
| `folderName` | String | 所屬磁碟資料夾（`yyyyMMddHHmmss[-N]`） |
| `videoFileName` | String? | 影片匯入時留存的原始影片檔名（`{base}_video.{ext}`）；純錄音為 nil，由磁碟掃描按檔名約定重建；「清理影片」後置空 |
| `hasVideoSource` | Bool | 是否為影片條目（錄屏 / 匯入影片）。與 `videoFileName` 解耦：清理原影片後檔名必須置空（不讓模型指向不存在的檔案），但該標記保留，列表圖示與型別文案不退回「錄音」。隨 `meta.json` 落盤；舊資料由磁碟掃描按影片檔案是否還在補位 |
| `createdAt` | Date | 建立時間 |
| `recordingSource` | RecordingSource | 錄音來源 |
| `transcriptionStatus` | TranscriptionStatus | 轉寫狀態 |
| `summaryStatus` | ProcessingStatus | 總結處理狀態（供佇列面板重啟後恢復展示） |
| `visualStatus` | ProcessingStatus | 畫面要點處理狀態 |
| `todoStatus` | ProcessingStatus | 待辦拆解處理狀態 |
| `summary` | String? | LLM 總結（**加密儲存**） |
| `visualSummary` | String? | 「畫面要點」：影片關鍵幀經多模態 LLM 產出的按時間軸畫面記錄（**加密儲存**）；磁碟映象 `visual.md` |
| `visualSummaryGeneratedAt` | Date? | 畫面要點生成時間 |
| `segments` | [TranscriptSegment] | 級聯關係（見下） |

### 1.3 關係建模

```swift
@Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.recording)
var segments: [TranscriptSegment]
```

刪除錄音時級聯刪除全部轉寫片段。

### 1.4 關鍵方法與計算屬性（extension）

| 成員 | 職責 |
|------|------|
| `storageDirectory` / `defaultStorageDirectory` | 儲存目錄解析：UserDefaults 可配置 key；預設 `~/Documents/Memozia/`；含讀取/設定/重置 |
| `createUniqueFolder(from:)` 等資料夾工具 | 資料夾唯一命名：月份目錄優先、舊平鋪目錄相容；以 mkdir 成敗為準原子分配（已存在則追加 `-N` 重試），失敗返回 nil，呼叫方報錯 |
| `fullTranscript` | 全部片段解密拼接的純文字 |
| `transcriptMarkdown` | 片段拼接為 Markdown（含時間戳/說話人） |
| `decryptedSummary` | 解密 summary |
| `formattedDuration` | 時長格式化（`01:23:45`） |
| `saveMetaToFolder()` | 把標題、隱藏狀態、條目型別、媒體路徑與時長、原件清理時間寫盤為 `meta.json` |
| `mediaKind` | 條目型別（錄音 / 錄屏）：列表圖示與型別文案的唯一判據；錄屏與匯入影片不區分，由 `hasVideoSource` 派生，清理原影片後不回退成錄音 |
| `folderIndicatesVideoSource(folderURL:files:)` / `folderHasVisualArtifacts(folderURL:)` | 按資料夾判定影片證據（留存原影片或畫面產物），供磁碟掃描與歷史條目修復複用 |

## 2. TranscriptSegment — 轉寫片段實體

原始碼：[TranscriptSegment.swift](../../../Memozia/Models/TranscriptSegment.swift)

| 欄位 | 型別 | 說明 |
|------|------|------|
| `id` | UUID | 主鍵 |
| `startTime` / `endTime` | TimeInterval | 片段時間區間 |
| `speaker` | String? | 說話人標註（"說話人 1"或聲紋註冊姓名） |
| `text` | String | 片段文字（**加密儲存**） |
| `recording` | AudioRecording? | 反向關聯 |

計算屬性：`formattedTimeRange`（`1:01:23.4 - 1:02:45.6`，0.1 秒精度）、`decryptedText`（解密展示路徑）。

## 3. LLMConfig — LLM 配置實體

原始碼：[LLMConfig.swift](../../../Memozia/Models/LLMConfig.swift)

### 3.1 持久化欄位（SwiftData）

| 欄位 | 型別 | 說明 |
|------|------|------|
| `id` | UUID | 主鍵（同時作為 Keychain 存 Key 的鍵） |
| `name` | String | 配置顯示名（"GPT-4o"/"LM Studio 本地"） |
| `baseURL` | String | 服務地址（OpenAI / LM Studio / Ollama） |
| `modelName` | String | 模型名 |
| `isLocal` | Bool | 是否本地服務——決定 PII 脫敏是否啟用、URL HTTPS 校驗豁免等 |
| `supportsVision` | Bool | 是否支援多模態（圖片筆記總結走此分支），預設 false |

### 3.2 計算屬性與輔助（extension，@Model 要求）

| 成員 | 職責 |
|------|------|
| `chatCompletionsURL` | baseURL 安全拼接 `/v1/chat/completions` 端點 |
| `apiKey` / `setAPIKey(_:)` | API Key 讀寫——**計算屬性，實際存 Keychain**（`LLMKeychainStore`，service `app.memozia.llm-apikeys`，以配置 UUID 為鍵；空值刪除） |
| `LLMKeychainStore` | Keychain 存取輔助（KeychainAccess，`.afterFirstUnlock`） |
| 預設模板 | `lmStudioTemplate()`（http://localhost:1234）/ `ollamaTemplate()`（http://localhost:11434）/ `openAITemplate()`（gpt-4o，supportsVision）/ `customTemplate()` |

### 3.3 配置匯入匯出（換機遷移）

| 成員 | 職責 |
|------|------|
| `LLMConfigTransferFile` | 遷移**負載**格式（`version` / `exportedAt` / `configs[].apiKey`），`Codable + Sendable`，日期 ISO8601；`apiKey` 可選，相容不含該欄位的舊檔案 |
| `transferPayload(from:)` | 組裝負載（**明文，含 API Key**）。命名即警示：呼叫方必須先經 `EncryptionService` 加密再落盤，絕不可直接寫檔案 |
| `decodeTransfer(_:existing:)` | 解析 + 校驗 + 去重，返回待插入配置、`[新 id: API Key]` 與統計：欄位為空判無效；端點安全**沿用請求路徑同一套** `LLMService.validateSecureURL(_:isLocalModel:)`（明文 HTTP 只放行本地模型）；與現有配置按 `baseURL`（去尾斜槓）+ `modelName` 小寫比對跳過重複；單次上限 200 條 |
| `EncryptionService` | 加解密用**本機金鑰**（Keychain，裝置唯一），與轉寫、總結等本地檔案同一套；因此匯出檔案**只能在本機匯入**，跨 Mac 會解密失敗並給出明確提示（詳見 [同步與安全](08-Sync-and-Security.md) §3.5） |
| `LLMConfigExportDocument` | `FileDocument`（見 [ExportDocuments.swift](../../../Memozia/Models/ExportDocuments.swift)）：只承載已加密位元組，失敗早於使用者選完儲存路徑暴露 |

入口：設定 → 大模型 → 配置遷移。匯出**不需使用者設密碼**：負載用本機金鑰（`EncryptionService`）加密後落盤，API Key 隨配置一起遷移；匯入時自動解密，非密文（舊版未加密匯出）按明文解析相容。**邊界**：金鑰是本機 Keychain 唯一的，所以匯出檔案**只能在本機 Memozia 匯入**，跨 Mac 解密失敗並給出明確提示。匯入的配置以新 UUID 落庫，API Key 寫入 Keychain 中對應的新 id；原本沒有啟用配置時自動啟用第一條。

執行期 LLMService 不直接跨 actor 傳此物件，而是轉成 `LLMConfigSnapshot` 值快照（[LLMService.swift](../../../Memozia/Services/LLMService.swift)）。

## 4. QuickNote — 快捷筆記實體

原始碼：[QuickNote.swift](../../../Memozia/Models/QuickNote.swift)

無錄音場景的文字/圖片速記，**複用錄音的資料夾約定**（`yyyyMMddHHmmss`，`itemType: "quicknote"`）。

| 欄位 | 型別 | 說明 |
|------|------|------|
| `id` / `title` / `createdAt` | — | 基礎後設資料 |
| 文字內容 | String? | **加密**（磁碟映象 `source.txt`） |
| 圖片檔名 | String? | `source.png` |
| `hasImageSource` | Bool? | 圖片來源標記，相容舊庫；清理原圖後保留，`isImageNote` 據此維持圖片型別與圖示 |
| `ocrText` | String? | 圖片 OCR 結果（**加密**） |
| AI 總結 | String? | **加密**（磁碟映象 `summary.md`） |
| 總結處理狀態 | ProcessingStatus | `summaryStatus`，供佇列面板重啟後恢復展示 |
| 待辦拆解狀態 | ProcessingStatus | `todoStatus` |
| `folderName` | String | 磁碟資料夾 |

關鍵成員：

| 成員 | 職責 |
|------|------|
| `combinedTextForExtraction` | 待辦提取輸入：文字 + OCR 文字合併 |
| `saveMetaToFolder()` | 寫 `meta.json`（`itemType: "quicknote"`） |

## 5. STTConfig — 轉寫配置（值型別）

原始碼：[STTConfig.swift](../../../Memozia/Models/STTConfig.swift)

- `STTMode`：system / local / cloud；系統模式僅在 macOS 26+ 支援時顯示，預設引擎由 `STTMode.defaultMode` 按系統能力選擇。
- `selectableCases` 不再為新選擇提供雲端 Whisper；`pickerModes(current:)` 會保留已儲存的隱藏模式，舊雲端配置和執行路徑仍相容。
- `WhisperModelFolder`：預設模型目錄；不再使用固定檔位的 WhisperModelSize 列舉。
- `WhisperLanguage`：介面語言選項；`STTConfig.whisperLanguageCode` 將內部 `zh-Yue` 對映為引擎接受的 `yue`。
- `STTConfig`：`mode`、`modelPath`、`apiKey`、`baseURL`、`language`、分離/聲紋/糾正開關及 `diarizationModelPath`，由 SettingsViewModel 組裝。
- 預設本地模型目錄由原始碼輔助方法給出。

## 6. RecordingConfig — 錄音配置（值型別）

原始碼：[RecordingConfig.swift](../../../Memozia/Models/RecordingConfig.swift)

```swift
enum RecordingSource: String {   // 录音来源
    case microphone               // 仅麦克风
    case systemAudio              // 仅系统音频
    case mixed                    // 混音（双轨）
    // 含 displayName / iconName（UI 用）
}
```

`RecordingConfig`：`source` + 靜音相關選項，UserDefaults 持久化，經 `SettingsViewModel.makeRecordingConfig()` 生成。

## 7. TodoItem / TodoDocument — 待辦

原始碼：[TodoItem.swift](../../../Memozia/Models/TodoItem.swift)

```swift
enum TodoPriority: Int { case none, low, normal, high }
enum TodoStatus: String { case pending, written, failed }   // 写入提醒事项的结果状态
```

`TodoItem` 結構：`id/title/notes?/url?/dueDate?/alarmOffsetMinutes?/priority/reminderIdentifier?/status/targetListID?`——id 是預設 UUID 字串，穩定用於去重；targetListID 為空時跟隨預設列表。

`TodoDocument`：待辦集合的檔案持久化，序列化為錄音資料夾內 **`todos.json`（加密）**；提供儲存/解密讀取/刪除；寫入提醒事項後回填 `reminderIdentifier` 與 `status`，用於刪除錄音時清理提醒事項殘留（先於刪資料夾載入）。

## 8. ExportDocuments — 匯出文件

原始碼：[ExportDocuments.swift](../../../Memozia/Models/ExportDocuments.swift)

三個 `FileDocument` 實現，供 `fileExporter` 匯出：

- `PlainTextDocument`（.txt）
- `MarkdownDocument`（.md）
- `MarkdownPDFDocument`（.pdf）：只攜帶已排版的 PDF 位元組。排版在 `MarkdownPDFRenderer`（Services）裡完成：純 CoreText 分頁，不依賴 AppKit/UIKit 型別；先排版後彈儲存面板是為了不頂主執行緒，且排版失敗能在使用者選路徑前報錯。應用不提供 PDF 匯入，`init(configuration:)` 明確報錯

## 9. TimeInterval+Formatting — 格式化擴充套件

原始碼：[TimeInterval+Formatting.swift](../../../Memozia/Models/TimeInterval+Formatting.swift)

`TimeInterval` 的時長格式化擴充套件（`mm:ss` / `HH:mm:ss`），供播放器與列表使用。

## 10. 持久化分層總覽

| 資料 | 儲存位置 | 加密 |
|------|----------|------|
| 錄音/片段/LLM 配置/快捷筆記 | SwiftData（default.store） | 敏感欄位 AES-GCM |
| 轉寫/總結/OCR/待辦檔案 | 條目資料夾（transcript.json/summary.md/ocr.txt/todos.json） | 使用現有加密寫入與相容讀取；具體邊界見安全篇 |
| API Key（Whisper/LLM） | Keychain（.afterFirstUnlock） | 系統級 |
| 加密金鑰 | Keychain | 系統級 |
| STT/錄音/截圖/詞典等配置 | UserDefaults | 無（非敏感） |
| 聲紋庫 | ~/Documents/Memozia/Voiceprints/&lt;uuid&gt;.json | 無（向量資料） |
| 詞典 | ~/Documents/Memozia/Dictionary/*.md | 無 |
