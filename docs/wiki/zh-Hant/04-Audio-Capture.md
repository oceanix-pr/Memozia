# 04 · 錄音與音訊採集

[← 返回首頁](Home.md) · 原始碼目錄：Memozia/Services

本篇覆蓋會議錄音的完整採集鏈路：總控編排 + 雙路採集 + 靜音檢測 + 音訊工具。

```
MeetingRecorderService（總控，@MainActor @Observable 單例）
 ├── MicCaptureService         麥克風：AVAudioEngine + AVAudioFile（CAF/PCM 分片）
 ├── SystemAudioCaptureService 系統音訊：ScreenCaptureKit + AVAssetWriter（WAV/PCM 分片）
 ├── AppMuteDetector           會議 App 靜音按鈕檢測（AX 輪詢）
 ├── MicMuteMonitor            系統麥克風靜音監聽（CoreAudio）
 └── AudioConverter            時長探測 / 格式轉換（AVAssetReader/Writer）
```

## 1. MeetingRecorderService — 錄音總控

原始碼：[MeetingRecorderService.swift](../../../Memozia/Services/MeetingRecorderService.swift)（`@MainActor @Observable final class`，`shared` 單例）

### 1.1 職責

編排一次會議錄音的完整生命週期：磁碟檢查 → 目錄建立 → 按 `RecordingConfig.source` 啟動採集 → 分片輪轉 → 停止合併 → 產出最終 m4a。UI 透過 `@Observable` 直接觀察其狀態（`isRecording`/`elapsedSeconds`/`isMicMuted`/`muteSource`）。

### 1.2 分片滾動架構

| 狀態 | 說明 |
|------|------|
| `segmentDuration = 300s` | 每 5 分鐘一個分片，限制單檔案損壞的影響面 |
| mic 分片 URL 列表 / sys 分片 URL 列表 | 雙路各自獨立分片 |
| `pendingMergeFinalURL` | 停止後的合併目標路徑 |
| PCM 分片檔案 | 條目目錄內 `*_mic_tmp_*.caf` / `*_sys_tmp_*.wav`，停止後合併清理 |

### 1.3 關鍵方法

| 方法 | 職責 |
|------|------|
| `startRecording(config:)` | 磁碟預檢（≥500MB）→ 建立 `~/Documents/Memozia/yyyy-MM/yyyyMMddHHmmss[-N]/` → 按 source 啟動 microphone/systemAudio/mixed 採集 → macOS 系統音訊許可權預檢；返回最終檔案 URL |
| `stopRecording()` | 停止計時器/靜音監聽/全部採集 → `mergeSegments()` 合併 → 返回最終 m4a URL；儲存失敗與歷史採集提醒分別交給 UI；已恢復的中斷不再觸發錯誤彈窗 |
| 分片輪轉 | 每 300s 觸發：mic 同步 `rotateSegment()`、sys 非同步 `rotateWriter()`；**輪轉失敗保留舊分片繼續寫入**，保障不丟資料 |
| `mergeSegments()` | 過濾可播放分片（校驗時長/音軌，跳過損壞與靜音空段）→ **混合模式下先逐片做參考回聲消除**（見 §7）→ 優先 `AVMutableComposition` 雙軌混音 → `AVAssetExportSession` 匯出 m4a（macOS 15+ async `export(to:as:)`）→ 失敗回退單軌拼接 → 正常完整合並清理分片，降級或採集故障保留原片。收尾拆成「檢查分片 → 回聲消除 → 混音匯出 → 儲存」四階段（`mergePhase`），供介面顯示當前進度 |
| `finalizeForTermination()` | App 退出時緊急收尾：finalize 臨時檔案（不完整分片下次啟動經 FileSyncService 校驗恢復合併） |

### 1.4 易迴歸約束

控制代碼峰值、PCM 容器、磁碟閾值、序列寫入與 SDK 分支統一見 [專案實踐](../../../DEVELOPMENT_GUIDE.md) §1；恢復讀錯不可誤刪原件見 §3。

## 2. MicCaptureService — 麥克風採集

原始碼：[MicCaptureService.swift](../../../Memozia/Services/MicCaptureService.swift)

**注意**：本類**不標 @MainActor**——`installTap` 閉包在後臺實時音訊執行緒執行，若標 @MainActor 閉包會繼承主 actor 隔離導致崩潰；用 `nonisolated` 切斷隔離。

| 方法 | 職責 |
|------|------|
| 啟動採集 | 確認麥克風許可權（未決時請求並等待，取消/停止後遲到授權結果無效）→ 建立全新 `AVAudioEngine` → 按所選/預設裝置解析並檢查繫結結果 → 同時讀取硬體 `inputFormat`、客戶端 `outputFormat` 與 CoreAudio 目標裝置當前取樣率；節點仍暴露舊快照時以裝置取樣率對齊 tap，裝置查詢失敗留痕後回退節點格式 → 建立匹配的 CAF/PCM 檔案、應用初始靜音 → 安裝 tap、啟動引擎 → 等當前 tap 首個非空緩衝成功落盤才返回就緒。初次啟動與裝置恢復共用有限重試；許可權和真實檔案寫入錯誤不重試。 |
| `mute()` / `unmute()` | 執行時靜音：**tap 保持安裝、改寫全零緩衝**（`silencedBox`），靜音期間分片時間軸保持連續、輪轉不會產生零幀空殼；`unmute()` 在引擎停轉時一併觸發恢復流程，恢復結果由採集事件上報（不再丟擲，避免把「正在恢復」當成一次即時錯誤） |
| 裝置切換處理 | 監聽 `.AVAudioEngineConfigurationChange`（捕獲註冊時的會話/引擎代次，丟棄舊引擎遲到通知；啟動期也處理真正的裝置/格式變化，同格式且引擎仍執行的通知忽略）：在同一恢復輪次內使當前嘗試失效、撤銷舊 tap 寫入資格並提前重試，保留啟動等待方與總預算；格式協商與 `-10868` 重試複用現有引擎/輸入節點，繫結失敗或無法繼續使用時才重建，並**重新對齊目標裝置**（所選裝置仍存在則綁回，已拔出則明確回退系統預設，**繫結結果必須檢查**，失敗不能繼續按已成繫結的前提恢復）→ 移除舊 tap → 若取樣率/聲道/PCM 佈局改變，先以新格式開啟下一片 CAF 並登記到合併列表 → 按新輸入格式重灌 tap、重啟引擎。由 [MicCaptureRecovery.swift](../../../Memozia/Services/MicCaptureRecovery.swift) 統一協調：先做一次立即恢復，啟動失敗或首包等待超時均按 200ms/500ms/1s/2s 短退避**有限重試**（首包等待和退避共用 15s 總預算，最多 5 次）；配置變化使當前 tap/首包嘗試失效並在原輪次內重試，重複通知不重新整理預算；停止、新會話取消整輪流程。下一次重試前預留首包觀察視窗；準備/啟動同步呼叫仍計入總預算，若實際耗時使剩餘時間不足，則記為 `recoveryBudget`，不能把幾毫秒的觀察記為 `writeBuffer` 首包超時。`engine.start()` 成功只算「已啟動」，啟動後還須複核協商後的實際格式，變化時立即重新準備 tap；必須等當前嘗試**首個非空音訊緩衝成功寫入**（每次最多等待 3s，靜音全零緩衝同樣有效）才確認恢復。每個 tap 捕獲獨立嘗試標識，舊 tap 的遲到寫入不能確認新嘗試；最後一次首包超時後仍接受該嘗試的遲到成功寫入並自動結算告警。格式變化導致雙軌分片邊界不齊時跳過逐片回聲消除，仍完整拼接混音。 |
| 採集事件 | `MicCaptureEvent` 把「可恢復的裝置切換/恢復」與「真實寫盤失敗」分開：`deviceUnavailable / recoveryStarted / recovered / recoveryFailed / writeFailed`。裝置恢復只更新狀態橫幅，**不再被包裝成「麥克風錄音寫入失敗……建議停止後重新錄製」**；只有啟動/首包重試預算耗盡或真實寫盤失敗才作為錯誤告警；中間首包超時只更新狀態橫幅。最終文案說明麥克風聲音可能缺失，並分別顯示系統音訊採集狀態，不宣稱整個錄音失效。事件攜帶採集會話代次（停止後迅速重錄時舊事件無效）與失敗階段、裝置繫結結果、新舊取樣率/聲道、錯誤域與錯誤碼等定位欄位，供 `-10868`（格式不支援）這類無階段資訊的錯誤碼定位到具體操作。 |
| 寫失敗成因分流 | tap 寫入拋錯也分兩種成因：**引擎已停、剛處理過裝置配置變化（5s 內路由尚未穩定）、或輸入節點格式已與當前分片不一致** → 屬於裝置切換症狀，按 `deviceUnavailable` 處理並觸發恢復；只有引擎在跑、格式一致且遠離配置變化時的寫失敗才報「寫入失敗……建議停止後重新錄製」。判定抽成純函式 `MicCaptureService.writeFailureIsDeviceTransition`，閾值 `deviceTransitionWindow`。判定必須在主執行緒讀「當下」引擎狀態，故 `reportWriteError` 先回主執行緒再分流。 |

**許可權**（`start(to:)` 為 `async`）：只做只讀預檢不行——系統只在 App **主動請求**後才把應用登記進「麥克風」面板，只讀判定會把「未決」當成「拒絕」直接報錯，全新機器上既不會彈授權框、也無從手工授權（分發到新機器表現為面板裡沒有 Memozia）。因此未決時調 `AVAudioApplication.requestRecordPermission()`（macOS 14+）/ `AVCaptureDevice.requestAccess(for:)` 並等待；已拒絕時重複呼叫不會再次彈窗，直接按錯誤上報（文案指向系統設定）。

**寫入格式**：Linear PCM、取樣率和聲道數取自當前輸入裝置、16-bit、非浮點、非 big-endian、非 interleaved。檔案處理格式必須與 tap 緩衝匹配；輸入裝置格式變化時不能繼續寫入舊格式的分片。

**執行緒安全與停止**：引擎及節點控制、執行狀態讀取均在 MainActor；tap 閉包保持非 MainActor。`MicCaptureFileStore` 用同一把鎖保護檔案替換、tap 標識撤銷及實際寫入：舊 tap 遲到緩衝不能寫入新檔案；成功確認與寫失敗還須複核 tap/會話標識。每個 tap 獨立持有靜音零緩衝池。停止先取消首包等待並使會話失效，再撤銷寫入、移除觀察者/tap、釋放引擎和檔案；下一次錄音不復用舊引擎。啟動/恢復嘗試失敗僅清理空殼，已有資料的分片及讀取失敗的檔案保留。

**麥克風裝置選擇**：`MicrophoneDeviceRegistry`（[MicrophoneDeviceRegistry.swift](../../../Memozia/Services/MicrophoneDeviceRegistry.swift)）負責列舉系統輸入裝置、按 UID 持久化選擇、把裝置繫結到引擎輸入節點。

- **列舉**：CoreAudio（`kAudioHardwarePropertyDevices` + 輸入流過濾），口徑與系統「聲音 → 輸入」一致，**包含 Loopback 等虛擬/迴環裝置**（會議軟體能用它們，App 不隱藏）。
- **繫結**：AUHAL `kAudioOutputUnitProperty_CurrentDevice`，**不修改系統預設輸入裝置**，不影響其他應用；新引擎當前裝置與目標一致時不重複繫結；需要繫結時必須檢查返回值。未指定時每次準備採集都解析當前系統預設裝置，偏好仍保持“跟隨系統預設”，不儲存為固定裝置。
- **回退**：所選裝置已拔出時回退系統預設（採集與靜音監聽同一規則）。
- **標識**：以 CoreAudio Device UID 為準（與 `AVCaptureDevice.uniqueID` 同值）；顯示名會重複且隨語言變化，不能作為鍵。
- **效能**：展示用裝置列表帶 1 秒 TTL 快取——單次列舉約 0.6ms（20+ 次 CoreAudio IPC），而設定頁每次渲染讀 3 次、選單欄每秒讀 1 次，逐次直查會在主執行緒白白累積；**採集決策路徑始終直查**，快取過期不影響錄到哪個裝置。
- **入口**：設定頁「錄音 → 輸入裝置」、選單欄「麥克風」（頂級項，緊隨「捕獲螢幕」）、截圖會話工具欄 mic 按鈕，以及錄音中狀態徽章的麥克風選單（[RootView.swift](../../../Memozia/Views/RootView.swift)）；四處共用同一偏好 `microphone_device_uid`，會議錄音與錄屏錄音同時生效。
- **靜音入口與選擇入口同處**：凡是能選麥克風的地方都能靜音。錄音中由錄音狀態徽章選單與選單欄「麥克風」子選單提供同一條執行時命令（文案 / 圖示 / 禁用條件集中在 `MicMuteCommand`，[MicMuteCommand.swift](../../../Memozia/Models/MicMuteCommand.swift)：系統或會議軟體觸發的靜音不能在 App 內解除）；截圖會話工具欄的麥克風選單在錄製開始前展示，切換的是偏好 `microphone_start_muted`（「錄音開始時靜音麥克風」，與設定頁開關、[RecordingConfig.swift](../../../Memozia/Models/RecordingConfig.swift) 的 `MicrophoneStartMutePreference` 同一份），開始錄音/錄屏時由 `MeetingRecorderService` 落實為初始靜音。

### 持續寫入監測與共同時間軸

- `MicCaptureService.checkCaptureHealth` 隨錄音節拍每秒檢查成功落盤（包括使用者靜音的零緩衝），連續 3 秒無成功寫入或引擎停轉即加入現有有限恢復流程。`MicCaptureLiveness` 將故障鎖定在一輪預算內，耗盡後等待真實裝置變化、手動恢復或同一嘗試遲到首包，不因每秒巡檢無限重啟預算。CoreAudio 同時監聽預設輸入、裝置列表、當前裝置存活與取樣率；重複路由通知合併。
- 任何已有資料的麥克風恢復都會開新 CAF，格式相同也不續寫舊片。`RecordingSegmentTimelineStore` 在成功寫入時登記每片首包的 host clock，主執行緒原子儲存 `capture_timeline.json`；正常停止與崩潰恢復均由 `RecordingSegmentTimeline.append` 按相對時間插入分片，中間及末尾缺口保留靜音，不壓縮時間。舊錄音無 sidecar 時相容順序拼接；新 sidecar 損壞或缺少可播放片的時間資訊時保留素材並明確失敗。
- 兩軌片數、起點和時長都匹配才做逐片回聲消除；無法證實對齊時保留原始音軌繼續混音。裝置恢復與定時輪轉共用編號，輪轉在非同步收尾前預留編號，防止重入覆蓋檔案。
- 降級、跳片或歷史採集故障時保留全部原片，詳情列出跳過的檔名及最近成功寫入時間。恢復掃描看到可播放最終檔案時不會重新消費原片；讀取失敗或體積小不能作為刪除空殼的依據。`RecordingSegmentTimelineTests` 覆蓋時間缺口、取樣率變化、末尾靜音、降級保留及崩潰恢復；真實引擎停轉驗證需顯式設定 `MEMOZIA_VERIFY_AUDIO_CAPTURE=1`，只寫零緩衝。

## 3. SystemAudioCaptureService — 系統音訊採集

原始碼：[SystemAudioCaptureService.swift](../../../Memozia/Services/SystemAudioCaptureService.swift)

基於 **ScreenCaptureKit**（錄系統音訊也需要"螢幕錄製"許可權，需重啟生效）。

| 方法 | 職責 |
|------|------|
| 啟動採集 | 許可權檢查 → 建立 `SCStream`：`capturesAudio=true`、2 聲道、48kHz、`excludesCurrentProcessAudio=true`（防回授）→ 註冊音訊 + 佔位螢幕輸出 |
| `SCStreamOutput` 回撥 | 只處理 `.audio` 樣本；**首包 PTS 啟動 writer 會話**（SCStream 時間戳不從 0 開始，固定 `.zero` 會開頭空白/與麥克風軌錯位）→ `input.append(sampleBuffer)`（寫入前檢查 `isReadyForMoreMediaData`） |
| `rotateWriter()` | 分片輪轉：關閉當前 AVAssetWriter、開啟新分片檔案（非同步） |

**寫入格式**：AVAssetWriter 輸出 WAV/PCM，48kHz、2 聲道、16-bit、`expectsMediaDataInRealTime = true`。

**狀態機與清理（重要）**：採集狀態是顯式的 `idle / starting / running / reconnecting / stopping / failed`，**清理依據是「資源是否存在」而不是某個布林標誌**：

- `start()` 先安裝 `SCStream`/writer，再 `await startCapture()`；`startCapture()` 拋錯時立即回滾（停流 + finalize writer + 歸還 idle），不把殘留 writer 留在狀態裡。
- SCStream 異常停止回撥只把狀態標為 `failed`，**保留** writer/stream 引用：writer 仍需在 `stop()` 裡 finalize（否則當前分片容器不完整、檔案控制代碼洩漏），喚醒重連也依賴它繼續寫當前分片。
- `stop()` 冪等：沒有資源就是空操作，並且只在仍處於 `stopping` 時歸位 `idle`，不會踩掉併發啟動的新會話。
- 舊實現只有單個 `isCapturing` 標誌且 `stop()` 以它為準，上述兩條路徑都會判定「無需清理」直接返回，遺留未 finalize 的分片與舊 stream。

**睡眠恢復與告警**：

- 事件攜帶採集代次；停止、重連和 writer 輪轉會使舊代次失效。`MeetingRecorderService` 在 MainActor 接收事件時同時複查錄音會話及採集代次，舊回撥不得覆蓋恢復結果或汙染下一次錄音。主動停止/替換的舊流回撥只記 debug；有效斷流日誌記錄錯誤域與錯誤碼。
- 睡眠恢復按本次聲源與仍存在的資源判斷，不依賴瞬時 `capturing`（斷流可能先於睡眠通知）。使用者主動停止系統共享後不因睡眠喚醒自動重開共享。恢復由 30 秒看門狗兜底，超時/取消撤銷對應恢復代次；遲到新流不得重新接管。
- 新流啟動且 writer 可寫後仍處於等待確認狀態，成功寫入首個音訊樣本才確認恢復；睡眠間隙的麥克風靜音補寫繫結原檔案，停錄或換片後不再向另一檔案繼續補寫。
- [RecordingCaptureHealth.swift](../../../Memozia/Models/RecordingCaptureHealth.swift) 分開記錄當前狀態與歷史影響：系統音訊（睡眠、斷流、寫入失敗、丟樣本）與麥克風裝置（`unavailable / recovering / active`）各一組。恢復只更新橫幅與「當前狀態」，**不清除曾經缺口的記錄**；恢復成功後 `MeetingRecorderService` 結算獨立儲存的「麥克風恢復失敗」告警，保留磁碟/寫入等其他錯誤，避免同一次恢復故障在停錄時重複提示。停止時彙總最終影響，不重複顯示「錄音將繼續」的舊提示。`RecordingCaptureReport` 儲存觀察到的音軌中斷區間、恢復確認、麥克風最近成功寫入時間與區間內靜音證據；這些區間不等於精確的聲音丟失時長。正常切換並立即恢復不生成缺口記錄；全程靜音且已恢復的中斷按資訊展示，不宣稱丟失說話內容。同類實時告警去抖，不同故障互不遮蔽。


### 停錄結果與採集詳情

- `RecordingViewModel.finishRecordingSave` 在音訊已校驗、採集詳情及 `meta.json` 落盤、資料庫儲存成功後釋出 `RecordingFeedback`。恢復的歷史中斷、音軌/影片降級使用與重新整理同層的非模態橫幅，可透過「檢視詳情」定位錄音；真正無可播放產物、時長無法校驗或關鍵儲存失敗仍明確報錯，失敗資料夾可在 Finder 中開啟。
- 錄音中未恢復的採集問題使用常駐橫幅，提供「檢查裝置」入口；恢復後收起當前故障，短暫顯示恢復結果，不因歷史中斷再彈錯誤窗。
- `capture_report.json` 由 [RecordingCaptureReport.swift](../../../Memozia/Models/RecordingCaptureReport.swift) 原子儲存穩定原因碼和採集證據，不包含會議內容或金鑰，不新增 SwiftData 列。詳情頁按錄音目錄讀取；關閉橫幅、重啟、重新命名或磁碟重建索引後仍可檢視。舊條目無此檔案是正常情況，損壞/讀失敗不能偽裝成無記錄。恢復清理不得刪除僅剩採集詳情的目錄。
- 驗證見 [RecordingCaptureReportTests.swift](../../../MemoziaTests/RecordingCaptureReportTests.swift)：成功附提醒、關鍵儲存失敗不報成功、靜音全區間證據、未確認恢復時停止、落盤往返和空分片恢復清理。

## 4. AppMuteDetector — 會議 App 靜音檢測

原始碼：[AppMuteDetector.swift](../../../Memozia/Services/AppMuteDetector.swift)

透過 **Accessibility（AXUIElement）樹**推斷 Teams/Zoom 等會議軟體的麥克風按鈕狀態。

| 成員 | 職責 |
|------|------|
| 啟動檢測 | 檢查輔助功能許可權 → 建立 **1 秒輪詢定時器** → `pollMuteState()` |
| AX 樹搜尋 | 靜音按鈕識別：優先 `domID == "microphone-button"`（Teams）→ 回退"描述關鍵詞 + 按鈕角色"複合匹配（中文關鍵詞必須複合條件，如"取消"+"靜音"同時出現，防誤判對話方塊）→ 遞迴深度限制 35 |

需要使用者在系統設定授予"輔助功能"許可權。檢測結果匯入 `MeetingRecorderService.muteSource`（區分系統靜音 / 會議 App 靜音），供 UI 提示。

## 5. MicMuteMonitor — 系統麥克風靜音監聽

原始碼：[MicMuteMonitor.swift](../../../Memozia/Services/MicMuteMonitor.swift)

基於 **CoreAudio `kAudioDevicePropertyMute` 屬性監聽**：

| 方法 | 職責 |
|------|------|
| 啟動監聽 | 註冊預設輸入裝置變化監聽 + 繫結**當前採集裝置**（`MicrophoneDeviceRegistry.resolvedDeviceID()`：跟隨已選麥克風，未選或已拔出回退系統預設，與採集繫結同一規則）的 mute 屬性監聽（裝置切換時重新繫結） |
| mute 回撥 | **從觸發事件的裝置（objectID）讀取 mute 值**（不重新查預設裝置，避免切換瞬間誤讀）→ 更新 `isSystemMuted` → `onMuteChange` 回撥 |

C 回撥橋接：`Unmanaged.passUnretained` 傳 self，回撥內 `Task { @MainActor in }` 跳回主執行緒；監聽物件由單例持有（生命週期長於註冊期）。

## 6. AudioConverter — 音訊工具

原始碼：[AudioConverter.swift](../../../Memozia/Services/AudioConverter.swift)

基於 AVAssetReader/AVAssetWriter：

- `getDuration(of:)`：探測音訊檔案時長（非同步）——錄音停止後用於回填 `AudioRecording.duration`
- 格式轉換：供匯入音訊的規格化處理

## 7. EchoReductionService — 離線參考回聲消除

原始碼：[EchoReductionService.swift](../../../Memozia/Services/EchoReductionService.swift)（IO 編排）、[EchoCanceller.swift](../../../Memozia/Services/EchoCanceller.swift)（DSP 核心，不依賴 AVFoundation，可單測）

**要解決的問題**：遠端的話從本地揚聲器外放，又被本地麥克風採回，「麥克風軌」裡於是混進了「系統音軌」的內容。混音後同一句話出現兩份，轉寫重複、說話人判定也會被打亂。

**只處理可線性建模的那條路徑**：本地揚聲器 → 本地麥克風（聲學回聲路徑可用自適應濾波還原）。「自己聲音繞網路到遠端再回來」受遠端編碼與網路抖動影響，線性濾波無法建模，交給雙軌分離轉寫去重。

| 環節 | 做法 |
|------|------|
| 觸發 | `mergeSegments()` 過濾出可播放分片後、混音前逐片處理；`EchoReductionPreference`（預設開啟）關閉即跳過；僅兩軌都有分片時生效 |
| 時間預算與取消 | 由 `MeetingRecorderService.runEchoReduction` 的獨立看門狗兜底（`FileSyncService.echoReductionTimeout`：基礎 5 分鐘 + 每小時素材 10 分鐘，上限 30 分鐘）；逐片前檢查 `deadline` 與跨隔離 `CancellationFlag`（`MeetingRecorderService.requestCancelEchoReduction`），片內每塊也檢查取消。超時/取消/演算法失敗一律把未處理尾部回退為原始音軌，不丟音訊、不阻斷合併入庫；超時後 best-effort 清理殘留 `_mic_clean` 臨時片 |
| 進度上報 | `reduceEcho(onProgress:)` 每處理完一片回撥 (已完成, 總數)，經 `mergePhase == .echoReduction` 暴露給介面（`mergeProgressCompleted/Total` 與 `mergeStageStartedAt`） |
| 延遲估計 | `EchoCanceller.estimateDelay`：抽取到 ~12kHz 做歸一化互相關粗搜，再回原取樣率精修。延遲含兩路啟動時間差、聲學延遲與播放緩衝，必須實測；相關性過低返回 nil 並按 0 處理 |
| 自適應濾波 | `FrequencyDomainAdaptiveFilter`：約束式 overlap-save 頻域 NLMS（視窗 = 2×blockSize，可建模尾長 blockSize = 4096 抽頭 ≈ 85ms@48kHz）。歸一化必須排在時域梯度約束**之前**——順序反了會被 1/regularization 放大而發散 |
| 雙講保護 | 每塊按「麥克風能量 / 參考能量」判定：本地語音主導時凍結權重更新，避免把使用者本人的聲音當回聲消掉 |
| 取樣率 | 以麥克風分片為準；系統音訊（48kHz 立體聲）由 `AVAudioConverter` 下混並重取樣 |
| 輸出 | `{base}_mic_tmp_%04d.caf` → `{base}_mic_clean_%04d.caf`，16-bit 單聲道 CAF，與麥克風採集同規格，下游零改動 |
| 失敗回退 | 任一環節失敗即沿用原始分片；只有完整寫出（幀數 ≥ 原片）才認賬，半成品分片刪除。階段整體超時/被取消時，已算出的清理片保留、其餘尾部回退原始音軌 |
| 命名約束 | 清理分片刻意不帶 `_mic_tmp`/`_sys_tmp` 標記，否則崩潰恢復會把它當成另一份待合併素材而重複入庫 |

片內不做時鐘漂移補償：5 分鐘片內的漂移量（典型 50ppm → 15ms）遠小於濾波器尾長。控制項只在專業模式的錄音設定頁暴露，普通模式沿用預設值。

## 8. 一次完整錄音的時序

```
[開始] RecordingViewModel.startMeetingRecording(config, context)
   └→ MeetingRecorderService.startRecording
        ├─ 磁碟預檢（≥500MB，不足拋錯）
        ├─ 原子建目錄 ~/Documents/Memozia/yyyy-MM/yyyyMMddHHmmss[-N]/（分片直接在條目目錄）
        ├─ source == .microphone → MicCaptureService.start（engine+tap）
        ├─ source == .systemAudio → SystemAudioCaptureService.start（SCStream）
        ├─ source == .mixed → 兩路並行
        ├─ 啟動 elapsed 計時器 + 磁碟複檢定時器（<1GB 警告、<200MB 請求停止儲存）
        ├─ 啟動 AppMuteDetector（AX 輪詢）+ MicMuteMonitor（CoreAudio）
        └─ [錄音中] 每 300s rotateSegment/rotateWriter 分片輪轉
              （麥克風靜音時保持 tap 並寫入零緩衝，解除時恢復真實取樣）

[停止] stopMeetingRecording(context, source)
   └→ stopRecording
        ├─ 停計時器/靜音監聽/兩路採集（各 flush 最後分片）
        ├─ mergeSegments（四階段：檢查分片 → 回聲消除 → 混音匯出 → 儲存）：
        │    校驗分片（時長/音軌）→ [混合模式] 逐片參考回聲消除（獨立看門狗，可取消）
        │      → AVMutableComposition 雙軌 → m4a
        │    失敗回退：單軌拼接（保住至少一路）；回聲消除超時/取消回退原始音軌
        ├─ 返回最終 URL → AudioConverter.getDuration
        └→ 建立 AudioRecording + context.insert
             + saveContextWithRetry（應對合並後瞬時 fd 耗盡，短退避重試）
             + saveMetaToFolder（meta.json 落盤）

[異常] 錄音中崩潰/強殺 → 已輪轉及當前分片留在條目目錄（當前片可能未 finalize）
   └→ 下次啟動 FileSyncService 校驗恢復（見 08-資料同步與安全）

[退出] applicationShouldTerminate → finalizeForTermination()
```

## 9. 錄屏（螢幕錄製 → 影片條目）

實現：**錄屏 = 現有錄音管線 + 獨立影片軌服務**，不新建音訊鏈路。

```
入口（統一「捕獲」後）：側欄「捕獲」按鈕（僅專業模式；無下拉，目標與出口在會話工具欄）/ 選單欄「捕獲螢幕」子選單（含錄屏直達）/ 會話工具欄「錄製」出口
  （RootView.beginScreenRecording → startScreenRecording）
  目標：錄全屏（滑鼠所在屏）= 一步直達；錄選區/錄視窗 = 進入帶錄製出口的
        統一捕獲會話（與截圖同一凍結屏框選/懸停拾窗），選定目標後自動
        3 秒錄製倒計時（RecordCountdownController，點選即開錄/Esc 返回會話）；
        拾窗後選區未調整時升級為獨立視窗錄製（desktopIndependentWindow）
  偏好：聲源/質量檔位獨立存 UserDefaults（screen_recording_source/quality），
        設定頁「捕獲」節與選單欄子選單 radio 共用同一組鍵
   ↓
RecordingViewModel.startScreenRecording(target, source, quality)
   ├→ MeetingRecorderService.startRecording（雙軌 PCM 分片/混音/磁碟止損，原樣複用）
   │    資料夾/基名由錄音管線分配（yyyyMMddHHmmss）
   └→ ScreenVideoRecorder.start → 同資料夾 {base}_video.mp4（AudioConverter.retainedVideoName 命名約定）
        SCStream → AVAssetWriter **分片化 MP4**（movieFragmentInterval 5s）：
        程序被殺/崩潰時已落碟片段仍可播放，下次啟動檔案掃描恢復為帶影片附件的條目；
        首幀 PTS 定標會話起點，音影片樣本保留原始 PTS 由 writer 自動對齊；
        磁碟預檢（≥半小時預估）+ 20s 巡檢臨界回撥走統一停止流程；
        拔屏/撤權/關窗 → didStopWithError 只停影片，音訊繼續並提示
   ↓ 停止（任一入口）：stopMeetingRecording 同時停止影片採集、啟動影片收尾並執行音訊合併→等待影片收尾後混流→
     建立 AudioRecording(videoFileName:) → 條目天然獲得「畫面」Tab，
     轉寫/總結（會議·概要雙按鈕）/關鍵幀時間軸全鏈路複用，零模型遷移

約束與限制：
- 收尾順序：影片收尾與音訊合併可並行，混流前等待兩者完成 → **passthrough 混流**（`AudioConverter.embedAudio`：
  mp4 影片軌 + 錄音管線混好的完整 m4a（含麥克風）重封裝替換原音軌，不轉碼不損質；
  失敗保留原 mp4（可能僅系統聲/無聲）並提示，不影響條目與音訊入庫）；
  兩源各自從 0 起流，mux 後音訊領先畫面約啟動差（數十至數百 ms，錄屏無口型場景接受）
- 影片收尾（`markAsFinished` + `finishWriting`）走 `RacingWatchdog`（上限 120s）：不回撥時放棄等待並記為「收尾超時」；超時**不取消 writer**（容器已落盤，取消會毀掉可播片段）。可播性由 `ScreenVideoRecorder.hasPlayableVideoTrack`（容器可解析 + 含時長 > 0 的影片軌）判定，不用檔案位元組數啟發式（靜止畫面可合法壓得很小）
- 只追加「有新畫面」的幀（`complete`/`started`；`idle`/`blank`/`suspended` 未生成新幀、無影象資料，追加會讓 writer 進入 `failed` 併產出缺 `moov` 的損壞容器）：代價是**靜止畫面時影片軌短於音訊軌**，音訊與轉寫不受影響
- 影片質量檔位：高畫質=原生解析度30fps≈18GB/h；標準（預設）=長邊≤2560px 30fps≈6.8GB/h；省空間=≤1920px 15fps≈2.7GB/h（HEVC，區域/視窗按屏 scale 換算畫素後限幅取偶）
- 錄屏不進 BackgroundTaskQueue（守護程序無採屏能力，與畫面要點同一理由）；退出/崩潰靠分片化 MP4 + 啟動掃描兌底
- 錄屏中複用會議錄音的全部 UI 守衛（徒章/紅條/防誤退）；聲源選擇用本次實際值 activeRecordingSource
- 選區 sourceRect 按顯示屏內 points（左上原點）傳入，輸出畫素由檔位限幅；若實測出現裁剪偏移，優先檢查此處座標系假設
原始碼：ScreenVideoRecorder.swift（服務，含 ScreenTargetKind 定義）/ Views/ScreenRecording/RecordCountdownPanel.swift（錄製倒計時層）/ RecordingViewModel（編排）；
選取與出口統一在截圖會話（見截圖與OCR篇），舊的獨立選區控制器/視窗列表 Sheet 已退役
```
