# 11 · 檢視層

[← 返回首頁](Home.md) · 原始碼目錄：[Memozia/Views](../../../Memozia/Views)

SwiftUI 檢視層，NavigationSplitView 雙欄佈局。`@Observable` VM + SwiftData `@Query` 驅動。

## 1. 檢視清單

| 檢視 | 職責 |
|------|------|
| [RootView](../../../Memozia/Views/RootView.swift) | 主樞紐：佈局、通知監聽、匯入、彈窗層、生命週期任務 |
| [RecordingListView](../../../Memozia/Views/RecordingListView.swift) | 側邊欄：錄音+筆記合併列表、媒體匯入入口（「捕獲」工具欄按鈕僅專業模式） |
| [RecordingDetailView](../../../Memozia/Views/RecordingDetailView.swift) | 詳情：播放器 + 轉寫/畫面（僅**專業模式**的影片條目）/總結 Tab（順序即影片處理鏈路），頁簽下方共享 `LLMModelSelectorBar`（總結/畫面頁籤顯示） |
| [TranscriptView](../../../Memozia/Views/TranscriptView.swift) | 轉寫展示/編輯/搜尋 |
| [SummaryView](../../../Memozia/Views/SummaryView.swift) | 總結：會議/概要雙按鈕、流式渲染、待辦（模型選擇條已上提至詳情頁共享） |
| [VideoUnderstandingView](../../../Memozia/Views/VideoUnderstandingView.swift) | 影片播放、視覺分析、關鍵幀時間軸與跳轉 |
| [QuickNoteDetailView](../../../Memozia/Views/QuickNoteDetailView.swift) | 快捷筆記詳情 |
| [SettingsView](../../../Memozia/Views/SettingsView.swift) | 設定中心（含隱私政策詳情與同意管理入口） |
| [MarkdownView](../../../Memozia/Views/MarkdownView.swift) | 自定義塊級 Markdown 渲染器 |
| [TextFindReplace](../../../Memozia/Views/TextFindReplace.swift) | 查詢替換元件 |
| [HelpView](../../../Memozia/Views/HelpView.swift) | 內建幫助文件 |
| [OnboardingView](../../../Memozia/Views/OnboardingView.swift) | 按體驗模式介紹功能；模型在實際使用時按需準備 |
| [PrivacyConsentView](../../../Memozia/Views/PrivacyConsentView.swift) | 隱私政策同意（正文來自 `MemoziaPrivacyPolicy`，含聲紋單獨同意） |
| [PrivacyPolicyDetailView](../../../Memozia/Views/Settings/PrivacyPolicyDetailView.swift) | 設定內的完整協議與同意管理（聲紋單獨同意、撤回總體同意） |
| [QueuePanelView](../../../Memozia/Views/QueuePanelView.swift) | 全域性處理佇列面板（`QueueToolbarButton` 工具欄入口 + 面板本體，含「處理中 / 排隊中 / 最近失敗」三區，見 [02-整體架構](02-Architecture.md) §3.4） |
| [OneClickPreviewView](../../../Memozia/Views/OneClickPreviewView.swift) | 一鍵處理預覽（`OneClickPlan` 計劃模型 + 預覽檢視：將執行 / 將跳過 / 重新轉寫開關 / 雲端資料範圍，見 [02-整體架構](02-Architecture.md) §3.4） |
| Screenshot/[OverlayAnnotationView](../../../Memozia/Views/Screenshot/OverlayAnnotationView.swift) | 截圖示註畫布（見 [07-截圖與OCR](07-Screenshots-and-OCR.md)） |
| Screenshot/[ScreenshotOverlayController](../../../Memozia/Views/Screenshot/ScreenshotOverlayController.swift) | 截圖會話控制器（同上） |

## 2. RootView — 主樞紐

### 2.1 結構（分層計算屬性防型別檢查超時）

```
body = dialogLayers                      // 彈窗/確認/匯出/分享
  .overlay(progressOverlay)              // 錄音中/匯入中的底部進度條
  .contextMenu(forSelectionType: ListItem.self)  // 列表上下文選單
  .modifier(ExportModifiers)             // 轉寫/總結匯出（.md + .pdf）+ 錄音分享
  .modifier(LifecycleTasksModifier)      // 啟動任務鏈（序列）
```

內部分三層：`observerLayers`（NavigationSplitView + onReceive 通知監聽 + onAppear 首屏）→ `sheetAndAlertLayers`（Privacy/Onboarding/Settings/Help 彈窗 + 錯誤 alert）→ 對話方塊層。

### 2.2 關鍵機制

- **通知監聽**：選單欄錄音控制、錄音全域性熱鍵、截圖熱鍵/選單、截圖儲存入庫、截圖許可權/錯誤彈窗、設定/幫助/剪貼簿筆記（完整表見 [02-整體架構](02-Architecture.md) §6）
- **首屏門控**：`MemoziaPrivacyPolicy.needsConsent(...)`（同意布林量 + 政策主版本號）→ PrivacyConsentView；`hasCompletedOnboarding` → OnboardingView；**大版本升級**（`onboardingCompletedVersion != currentAppVersion`）重新展示引導介紹新功能
- **側邊欄**：`RecordingListView` + 工具欄（**匯入音訊/影片**、新建快捷筆記、截圖〔僅專業模式〕、刪除、重新命名、同步磁碟資料、開始/停止會議錄音）+ macOS 檔案拖拽匯入（`AudioImportValidator` 校驗）
- **詳情分流**：按選中項型別分流 `RecordingDetailView` / `QuickNoteDetailView`，注入轉寫/取消/LLM 配置/提醒列表等依賴
- **處理佇列接入**：詳情列右上角工具欄常駐 `QueueToolbarButton`（圖示隨狀態變化：有失敗任務顯示警示圖示，否則按是否有活動任務區分；點選彈出 `QueuePanelView`）。RootView 的私有 extension 只做排程——把「轉寫 / 總結 / 潤色標題 / 畫面分析 / 拆解待辦 / 一鍵處理」構造成 `TaskCenter` 的 Job/Step 投遞，每個 Step 呼叫既有 ViewModel 方法並更新模型上的 `ProcessingStatus` 欄位，並按上下文上報 `TaskErrorCode`（見 [02-整體架構](02-Architecture.md) §3.4）
- **一鍵處理三入口**：列表右鍵選單、錄音/錄屏詳情**播放條右側**按鈕、快捷筆記「拆解待辦」**旁**按鈕，均走 `presentOneClickPreview(_:)` → `OneClickPreviewView` 預覽 → `enqueueOneClick(_:plan:)` 入隊，鏈路為「轉寫（預設跳過已完成的，只有顯式勾選「重新轉寫」才重跑並先備份手動編輯）→ 畫面分析（錄屏 / 匯入影片）→ 總結 → 拆解待辦」；文字/圖片筆記無音軌，鏈路為「總結 → 拆解待辦」。錄音/錄屏預設會議總結，文字/圖片筆記按概要總結，**待辦只落盤不寫入提醒事項**。入隊後頂部橫幅提供「檢視佇列」入口（通知 `openTaskQueuePanel` 由工具欄按鈕響應）
- **`ListItem` 選中模型**：`.recording(AudioRecording)` / `.quickNote(QuickNote)` 聯合型別，支援 macOS List 多選（批次刪除/匯出）
- **匯出子選單**：轉寫與總結各自可匯出 `.md` 或 `.pdf`（另保留複製文字與匯出原始錄音）。`.pdf` 走 `MarkdownPDFRenderer` 後臺排版，排完再彈 `fileExporter`：排版不頂主執行緒，失敗也能在使用者選路徑前彈錯

## 3. RecordingListView — 側邊欄列表

| 能力 | 說明 |
|------|------|
| 主體佈局 | `.listStyle(.sidebar)` + **列表頂部自定義搜尋框** + toolbar + `selectedListItems` 多選繫結 |
| 自定義搜尋框 | 釘在列表頂部，**替代系統 `.searchable`**（後者在 macOS 會併入視窗工具欄右上角按鈕同區）。macOS 26+（macOS 27 同款設計語言）用 Liquid Glass（`glassEffect(.regular.interactive())`）懸浮玻璃面，舊系統回退 `.quaternary` 半透明填充 + 圓角；⌘F 聚焦、Esc 先清空再退出焦點；過濾、300ms 防抖與 `.id("filter-…")` 強制重建邏輯保持不變 |
| 視窗標題 | `navigationTitle` 恢復為「Memozia 聞墨達」 |
| 月份分組 | 按月分組展示，`expandedBinding` 控制摺疊/展開 |
| 行元件 | `deletableRenamableRow`：內聯重新命名 + 滑動刪除 + 狀態角標（轉寫中/已完成/失敗） |

## 4. RecordingDetailView — 錄音詳情

工具欄（播放控制、匯出、刪除）+ 音訊播放器（AVAudioPlayer 封裝，進度條/跳轉）+ Tab 切換 **TranscriptView / SummaryView**；匯入過原影片的**專業模式**條目額外顯示 **VideoUnderstandingView**「畫面」Tab（普通模式不展示該頁籤，規則見 `RecordingDetailView.availableTabs(experience:hasVideoAttachment:)`）。頁籤欄下方渲染共享 `LLMModelSelectorBar`（僅總結/畫面頁籤顯示，轉寫用 STT 配置不展示），取代此前兩個子檢視各畫一份的同狀態選擇條（曾被誤讀為“兩個下拉框”）；頁內改選會寫回全域性活動大模型配置並持久化。**播放條右側**提供「一鍵處理」按鈕，點選先彈出 `OneClickPreviewView` 預覽，確認後由宿主投遞到處理佇列。macOS 佈局適配（引數順序見 RootView 呼叫處）。

錄音儲存完成後，RootView 複用重新整理結果的非模態橫幅，按資訊/提醒顯示圖示，8 秒後收起；「檢視詳情」定位相應條目並展開 `captureReportSection`。錄音詳情從目錄中的 `capture_report.json` 恢復音軌中斷區間、恢復狀態與靜音證據；讀取失敗明確顯示，不能當成無異常。錄音中未恢復問題使用常駐橫幅及「檢查裝置」，實際儲存失敗保留錯誤對話方塊與 Finder 入口。

## 5. TranscriptView — 轉寫檢視

| 能力 | 說明 |
|------|------|
| 展示/編輯切換 | `isEditing` 切換 Markdown 展示 / TextEditor 編輯；`transcriptVersion` 計數**驅動快取重建**（編輯儲存後 +1） |
| Markdown 渲染 | 展示段數、**搜尋高亮**（匹配片段渲染）、呼叫 MarkdownView |
| 底部操作欄 | 編輯、**查詢替換**（TextFindReplace）、搜尋、複製、**聲紋標記**（說話人註冊入口 → VoiceprintStore 流程 A）、儲存草稿 |

## 6. SummaryView — 總結檢視

| 區域 | 說明 |
|------|------|
| 主體 | 流式輸出區 + 編輯模式 + 待辦列表 + sheet 彈窗（模型選擇條由詳情頁共享） |
| 流式渲染 | `StreamingMarkdownView` 最多每 200ms 合批，在後臺解析並展示 Markdown；切走時取消後臺解析，結束後切換正式展示 |
| 底部操作欄 | **會議總結/概要總結雙按鈕**（已有總結時為兩個重新生成按鈕，模板由使用者顯式選擇、進行中禁用）、複製、編輯、**拆解待辦**（→ 待辦列表 sheet → 寫入提醒事項） |

## 7. VideoUnderstandingView — 影片理解

影片條目的獨立「畫面」頁由 `VideoUnderstandingView` 承擔：內嵌 `VideoPlayer`，手動觸發畫面分析，明確顯示“圖片理解/本地 OCR”路徑；快取關鍵幀橫向展示，點選後播放器精確跳轉。切換到該頁會暫停詳情頂部的音訊播放器，避免雙路同時播放。

## 8. QuickNoteDetailView — 快捷筆記詳情

圖片預覽 / 文字編輯 + AI 總結（流式）+ 待辦提取 + 重新命名/刪除。與 RecordingDetailView 同構但面向 QuickNote 實體。底部操作欄在「拆解待辦」**旁**提供「一鍵處理」（概要總結 → 拆解待辦，先經 `OneClickPreviewView` 預覽再入隊）。頂部的模型選擇器寫回**全域性活動大模型配置**並持久化（`SettingsViewModel.setActiveLLMConfig`），與設定頁、錄音詳情的模型選擇是同一份偏好，重開筆記或重啟應用後保持一致。

### 8.1 文字筆記轉語音

`QuickNoteDetailView` 的文字筆記僅在應用語言為簡體/繁體中文，或跟隨系統且系統第一首選語言為簡體/繁體中文時提供「轉為語音」入口；非中文隱藏入口，切換到非中文時關閉已開啟的面板並取消合成。`NoteSpeechAvailability` 優先使用顯式應用語言；跟隨系統時讀取系統全域性 `AppleLanguages`，避免應用覆蓋/語言快取影響判定，也不因第二首選語言含中文而開放。編輯正文/總結期間不可開啟。`NoteSpeechView` 與 `NoteSpeechViewModel` 使用開啟時的正文/總結快照，支援系統音色語言/地區、實際標註的性別、語速、前段試聽、播放和完整音訊匯出。性別未知的音色僅顯示名稱；缺少音色時引導在系統設定下載後重新整理。面板關閉即取消當前任務並清理暫存音訊，不自動建立錄音條目，也不放入後臺續跑佇列。

`SpeechTextPreparer` 複用 `TranscriptMarkdownBuilder`，整理標題、連結名、列表、引用與表格，跳過程式碼塊/圖片；長文優先按句末分段，保留字元順序。`NativeSpeechService` 序列呼叫 `AVSpeechSynthesizer.write`，音訊回撥透過鎖保護的 `SpeechAudioSink` 寫入 WAV，不繼承 MainActor 隔離。取消封住寫入並恢復等待方，30 秒無回撥看門狗處理掛起，塊令牌忽略遲到結果。`SpeechAudioEncoder` 在獨立 actor 流式編碼 M4A；MP3 按系統編碼能力開放，當前未附帶第三方編碼器。AAC 由系統選擇與音色取樣率匹配的位元速率。

音訊寫入許可權為僅當前使用者的獨立臨時目錄；不進入條目掃描或錄音恢復。匯出使用儲存面板，在目標目錄暫存後原子替換；取消/失敗不覆蓋舊檔案。轉語音相關文案在 `Localizable.xcstrings` 提供全部 21 種支援語言（與 `project.yml` 的 `knownRegions` 一致）。迴歸測試見 `NoteSpeechTests.swift`。

## 9. SettingsView — 設定中心

### 9.1 佈局

sidebar（分組列表，頂部帶「設定與命令」搜尋框）+ detail（分組表單）。

側邊欄搜尋（`.searchable`）同時過濾設定頁名稱與應用命令：命令結果的名稱與**當前快捷鍵**取自 `AppCommandCatalog`（與選單欄、應用選單、幫助頁同一份描述），點選後跳到該命令對應的 `settingsDestination` 設定頁；沒有對應設定項的命令（如 ⌘N 新建筆記）只作名稱與快捷鍵展示。

`SettingsView` 透過 `AppExperienceStore` 切換兩套資訊密度：普通模式只顯示語音轉寫元件準備、智慧服務連線、會議場景、熱鍵、資料狀態和關於；專業模式顯示全部引擎、模型、捕獲、熱鍵、待辦、詞典、聲紋和儲存控制。模式開關位於“關於”，切換後當前不可見的設定頁會自動回到首個可見分組。

### 9.2 設定分組

| 分組 | 內容 |
|------|------|
| stt 語音轉寫 | 引擎模式、本地模型管理（下載/選擇資料夾）、雲端 API 配置、語言；本地模型下載經處理佇列（`TaskCenter.whisperDownloadJob`），可在佇列面板暫停 / 繼續（斷點續傳） |
| llm 大模型 | 多套配置 CRUD（name/baseURL/model/apiKey/isLocal/supportsVision）、連線測試 |
| recording 錄音 | 來源（mic/systemAudio/mixed）、輸入裝置與「錄音開始時靜音麥克風」（見 [04 音訊採集](04-Audio-Capture.md) §2）、磁碟空間、靜音提示選項 |
| screenshot 捕獲 | 螢幕錄製許可權、預設捕獲模式、錄屏偏好（熱鍵已遷出，見下） |
| hotkeys 熱鍵 | **全域性熱鍵錄製**（錄音 / 截圖 / 全屏直拍）、註冊失敗狀態、`⌃⌘R` 衝突回退說明；兩種模式均可見（普通模式隱藏「全屏直拍熱鍵」行） |
| todo 待辦 | 預設提醒事項列表、提前提醒量 |
| dictionary 詞典 | 詞條視覺化管理（新建/編輯/刪除）、**從聲紋同步**、**更新去標識化**（PIIScanService） |
| voiceprints 聲紋 | 聲紋庫管理（檢視/刪除） |
| data 資料 | 儲存目錄、磁碟同步；iCloud 同步當前未啟用（無狀態入口） |
| about 關於 | 版本、隱私政策與同意管理、開源授權；配置更新來源後顯示更新控制 |

### 9.3 普通模式的漸進披露

- 錄音設定用“線上會議 / 面對面會議”對映採集源，不顯示軌道、裝置和靜音策略。
- 總結只提供一個自動生成入口；模型選擇、會議/概要模板指定、高階編輯和待辦結構維護僅在 Pro 顯示。
- 已有影片畫面要點在普通模式仍可閱讀，但不能新建/重新分析或清理原始影片，避免切換模式造成使用者感知的資料丟失。
- 列表在普通模式收斂為單選，不顯示批次、隱藏與標題潤色入口；專業模式恢復原有多選與上下文選單。

## 10. MarkdownView — Markdown 渲染器

介面與 `MarkdownPDFRenderer` 共用 `TranscriptMarkdownBuilder.parseBlocks` 和 `TranscriptBlock`，避免閱讀與匯出使用不同的塊級語法。支援 H1–H6 與 Setext 標題、段落軟換行/顯式換行、帶縮排層級和勾選狀態的列表、反引號/波浪號圍欄、巢狀引用、分隔線及管道表格。表格要求表頭後有列數匹配的分隔行，外圍豎線可省略，保留空單元格、轉義豎線和列對齊；短行補空單元格，超出表頭的單元格忽略。

`MarkdownView` 用原生 Grid 展示表格，長單元格換行、寬表格橫向滾動。標題、段落、列表與單元格的行內格式統一使用 `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)`；程式碼保留字面內容。搜尋高亮也適用於標題、程式碼和單元格。`TranscriptCache` 提供後臺預解析的轉寫塊；其他靜態文字使用有容量和位元組上限的多篇 LRU 快取。

`StreamingMarkdownView` 用於錄音和快捷筆記總結，後臺合批解析後更新介面，不逐 token 在主執行緒解析全文。PDF 逐格排版並繪製邊框，跨頁重複普通表頭，超長單元格分段續頁；巨大表頭自身需要分頁時不重複。PDF 行內樣式仍由 CoreText 匯出實現負責（刪除線只去標記），不承諾完整 CommonMark/GFM、HTML、公式或圖片渲染。

相關回歸用例位於 `MarkdownPDFRendererTests.swift`（含共用解析器、表格分頁與長單元格測試）。

## 11. HelpView / OnboardingView / PrivacyConsentView

- **HelpView**：內建幫助，覆蓋會議錄音（含「錄音開始時靜音麥克風」預設與採集完整性報告）、匯入、快捷筆記、轉為語音、轉寫、聲紋識別、總結、AI 待辦、智慧截圖、選單欄/後臺錄音、錄音管理、資料隱私、快捷鍵；「快捷鍵」小節不硬編碼，由 `AppCommandCatalog.shortcutReferenceIDs` 生成（名稱與當前快捷鍵同上）
- **OnboardingView**：功能特性引導頁（大版本升級重新展示）。普通模式使用精簡主鏈路頁面，Pro 保留完整功能介紹（「快捷筆記」頁含轉語音說明）。引導頁**不再引導下載模型**：轉寫與說話人區分的模型準備都發生在實際使用時（系統語音識別按語言資產按需安裝，說話人分離模型由 `SpeakerDiarizationService.ensureModelsReady` 首次使用時自動下載，失敗則提示並降級為不做分離）。
- **PrivacyConsentView**：首啟隱私同意（資料收集、許可權用途、傳輸、本地儲存、螢幕共享說明、使用者權利、第三方服務約束；`interactiveDismissDisabled` 強制選擇）

## 12. iOS 分享擴充套件（已下線）

工程原有一個 iOS Share Extension（`MemoziaShareExtension/ShareExtensionView.swift`）與 `ShareSheet`（iOS 匯出分享），**已隨 iOS 支援取消一併刪除**：不要新增 iOS 檢視或分享擴充套件分支。
