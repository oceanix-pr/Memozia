# 08 · 資料同步與安全

[← 返回首頁](Home.md) · 原始碼：Memozia/Services/FileSyncService.swift、CloudSyncService.swift、EncryptionService.swift

本篇覆蓋資料可靠性與安全三件套：磁碟↔資料庫雙向同步、iCloud 狀態、加密體系。

## 1. FileSyncService — 磁碟 → 資料庫同步

原始碼：[FileSyncService.swift](../../../Memozia/Services/FileSyncService.swift)

**設計哲學：檔案系統是權威資料來源**（每條錄音/筆記一個 `yyyyMMddHHmmss[-N]` 資料夾），資料庫只是索引。資料庫損壞/換機時，全部記錄可從磁碟重建。

### 1.1 主流程

```
掃描 ~/Documents/Memozia/ 子資料夾
  → 識別新資料夾（資料庫中無對應 folderName 的記錄）
  → readItemType(meta.json) 判定型別：recording / quicknote
  → 併發階段：讀取 meta.json + 探測音訊時長（IO 密集，並行提速）
  → 序列階段：逐條入庫（共享同一 ModelContext，防交錯）+ 儲存資料庫
```

### 1.2 關鍵方法

| 方法 | 職責 |
|------|------|
| 同步主流程 | 上述掃描-併發讀-序列入庫；崩潰遺留 PCM 分片（`*_mic_tmp_*.caf` / `*_sys_tmp_*.wav`）校驗時長與音軌後恢復合併 |
| 快捷筆記同步 | 讀加密/明文 `source.txt` 與 `source.png` → `EncryptionService.decryptFileOrPlaintext` → 文字加密入庫 |
| `readItemType` | 讀 meta.json 的 `itemType` 欄位；`quicknote` 或"無音訊但有筆記內容檔案"（`hasQuickNoteContent`）判為筆記，否則按錄音處理 |

### 1.3 觸發時機與門控

- 啟動任務鏈（RootView `LifecycleTasksModifier`，單 `.task` 內**序列**處理遷移、狀態重置、磁碟對賬與佇列續跑，模型預熱是唯一併行的獨立任務；具體順序見 RootView），用 `.task(id: 隐私同意状态)` 門控——狀態由 `MemoziaPrivacyPolicy.needsConsent(...)` 計算（同意布林量 + 政策主版本號），使用者同意當前主版本後才掃描使用者資料；撤回同意會退出應用並重新走同意頁
- 加密遷移分頁儲存並支援遊標續跑；大迴圈定期 `Task.yield()` 保持 UI 響應

### 1.4 可靠性細節

- 新建條目資料夾用原子分配（`AudioRecording.createUniqueFolder(from:)`）：以 mkdir 成敗為準，已存在則換名重試；「先查後建」在併發下會拿到同名，而舊 `createFolder` 對已存在目錄也返回成功，兩條記錄會共用目錄互相覆蓋
- 掃描階段併發讀盤（可能持續數十秒），插入資料庫前對 `folderName` 再做一次存在性檢查（`fetchLimit = 1`），防止掃描期間使用者匯入/手動重新整理插入同一資料夾導致重複條目
- 條目映象（轉寫/總結/畫面要點）統一走 `EntryMirrorStore`：同一目標的連續寫入**合併為只寫最新一份**，同一目標任意時刻只有一個寫者；退出流程在拉起守護程序前 `flush()` 有界等待落盤。寫失敗經 `PersistenceReporting` 上報（舊實現是每處一個 `Task.detached` 一把火，剛儲存完退出即丟最後一次修改）
- 已入庫條目不再「完全跳過」：對賬時雙向補缺口——庫裡有內容而映象缺失則補寫映象，映象存在而庫裡為空則從磁碟補回庫。只補缺失、不覆蓋已有內容，正常條目只多一次 stat
- 後臺任務佇列（`.background_task_queue.json`）區分「檔案不存在」與「檔案損壞」：損壞時隔離為 `.corrupt-<时间戳>` 並嘗試從 `.bak` 恢復，同時上報使用者；拿不到跨程序 flock 時明確失敗且**不寫盤**（舊實現鎖檔案打不開就無鎖執行、把損壞當空佇列，會把全部待辦任務覆蓋掉）
- 資料夾名相容 12/14 位時間戳格式（歷史版本）；同秒衝突 `-N` 字尾解析前先剝離
- 舊版後設資料（`title.txt`）回退相容，新格式 `meta.json` 優先
- 原子寫入 `data.write(to:options:.atomic)` 防後設資料損壞

## 2. CloudSyncService — iCloud 同步狀態

原始碼：[CloudSyncService.swift](../../../Memozia/Services/CloudSyncService.swift)

**職責邊界**：只做 iCloud 賬戶狀態檢查與"儲存 → 同步中/成功/失敗"狀態反饋。**實際資料同步由 SwiftData+CloudKit 系統後臺完成**——但注意 ModelContainer 中 `cloudKitDatabase: .automatic` 配置**當前被註釋禁用**（待 CloudKit 容器配置完成後啟用，需所有模型屬性可選或有預設值）。

**當前接線狀態**：`SettingsView` 只宣告瞭 `CloudSyncService` 例項，沒有呼叫點；應用不會主動檢查 iCloud 賬戶狀態，也不會寫入 CloudKit。隱私政策按“當前未啟用 iCloud / CloudKit 同步”披露；啟用前需先更新政策並重新徵得同意。

誠實反饋原則：無法得知真實同步結果時不偽造狀態（不 sleep 後謊報"已同步"），CloudKit 未啟用時只報"已儲存到本地"。

## 3. EncryptionService — 加密服務

原始碼：[EncryptionService.swift](../../../Memozia/Services/EncryptionService.swift)

### 3.1 演算法與金鑰

| 項 | 方案 |
|----|------|
| 演算法 | CryptoKit **AES-GCM 256**（認證加密） |
| 金鑰儲存 | **Keychain**（`accessibility(.afterFirstUnlock)`） |
| 金鑰建立 | 鎖 + 雙重檢查 + **記憶體快取**（防併發首次建立互相覆蓋——舊金鑰加密的資料將永久不可讀；也避免每次加解密訪問 Keychain） |
| 落盤策略 | 金鑰落盤失敗時報錯，**絕不使用僅存記憶體的金鑰** |

### 3.2 核心方法

| 方法 | 職責 |
|------|------|
| `encrypt(_:)` | 文字 → Base64 密文；失敗報告並拋錯，由呼叫方決定現有明文回退策略 |
| `decrypt(_:)` | Base64 密文 → 明文 |
| `decryptSafely(_:)` | **讀路徑相容關鍵**：非 Base64 內容 = 明文回退，原樣返回；僅 Base64 解密失敗（損壞密文）才返回空。若統一返回空會靜默清空明文資料並在下次儲存時永久丟失 |
| `encryptAndWrite` / `decryptFileOrPlaintext` | 檔案級加密寫/相容讀（todos.json、ocr.txt、source.txt） |

### 3.3 加密資料清單

| 資料 | 位置 | 加密 |
|------|------|------|
| 轉寫片段文字 | SwiftData `TranscriptSegment.text` + transcript.json | ✅ |
| 錄音總結 | SwiftData `AudioRecording.summary` | ✅（summary.md 為加密映象） |
| 快捷筆記正文/OCR/總結 | SwiftData + 檔案 | ✅ |
| 截圖 OCR/紀要 | 圖片型 QuickNote 欄位 + 檔案 | ✅ |
| AI 待辦 | todos.json | ✅ |
| 截圖圖片 | PNG 檔案 | ❌（原圖/標註版不加密） |
| 錄音音訊 | m4a 檔案 | ❌ |
| 匯入的原始影片 | `{base}_video.mp4/mov/m4v` | ❌（與截圖原圖同一邊界，僅本地留存；轉寫用的是抽出音軌，不是影片本體） |
| 畫面要點 | SwiftData `visualSummary` + visual.md | ✅（與 summary 同一策略） |
| 抽出的關鍵幀 | `frames/kf_NN_秒s.jpg` | ❌（與圖片類產物同一邊界；幀裡可能含他人螢幕與文件文字，重新分析時複用快取） |
| API Key（Whisper/LLM） | Keychain（KeychainAccess 庫） | 系統級 |
| AES 金鑰本身 | Keychain | 系統級 |
| 匯出的模型配置（含 API Key） | 使用者選擇的檔案 | ✅ 與 §3.1 同一把**裝置金鑰**（`EncryptionService`）；金鑰不出本機 ⇒ 僅本機可解（邊界見 §3.5） |

### 3.4 一次性遷移

加密升級用 UserDefaults 標誌 `encryption_migration_completed` 控制只跑一次；冪等判斷用**真實解密嘗試**而非格式啟發式（見啟動任務鏈）。

### 3.5 大模型配置匯出的加密邊界

匯出走 `EncryptionService`（與 §3.1 同一把裝置金鑰，和轉寫/總結一致），**不向使用者索取密碼**：少一步操作，但換來一條硬邊界 ——

- **只能在匯出它的那臺 Mac 上匯入**。金鑰存在本機 Keychain、不隨檔案走，所以檔案拷到另一臺 Mac 時匯入會解密失敗。實現上把這種情況與"檔案損壞"分開提示（「該檔案無法在本機解密：可能由其他 Mac 匯出，或檔案已損壞」），而不是含糊的「格式不正確」。
- 匯入側保留明文相容：舊版未加密匯出（不含 Key）仍可直接解析。判據沿用既有語義 —— 非 Base64 內容即明文（同 `decryptSafely` / `decryptFileOrPlaintext`）。注意匯入用的是會拋錯的 `decrypt(_:)` 而非 `decryptSafely(_:)`：後者會把"解不開的 Base64"記成解密失敗並觸發全域性「金鑰可能已更改」告警，而外來檔案不該驚動本機資料。
- 明文負載（`LLMConfig.transferPayload` 的產物）含 API Key，只允許在記憶體中短暫存在，匯出路徑必須先加密再交給儲存面板。

上述配置匯出仍不跨裝置，也未啟用 Keychain `synchronizable`。條目資料另提供**使用者口令保護的遷移備份**：設定中的 `PortableBackupSection` 呼叫 `PortableBackup`，先讀取條目檔案，以 PBKDF2-HMAC-SHA256 派生口令金鑰、AES-GCM 分塊認證加密為 `.memoziabackup` 目錄包；不匯出裝置金鑰和 API Key。

恢復預檢路徑及認證資料塊，在獨立目錄中以目標裝置金鑰重加密條目文字，不覆蓋當前庫；提醒事項的外部標識與同步狀態會重置。核對後由使用者手動選擇恢復根目錄並重啟。備份不是資料庫事務快照，建立期間必須停止錄音、處理和編輯；不包含配置、詞典、聲紋、模型或佇列。口令遺失無法恢復。完整格式、限制和恢復演練步驟見 [改造說明](../../IMPROVEMENTS.md)。

### 3.6 Memonta 歷史資料相容

Memozia 的新資料仍使用 `app.memozia.encryption` 中的裝置金鑰。AES-GCM 認證失敗時，文字與檔案解密先嚐試當前服務中 `previous_encryption_key` 儲存的舊 Memozia 金鑰，再只讀嘗試同一 Mac 上 `com.Memonta.encryption` 的 `encryption_key`，用於開啟歷史密文。應用不會自動輪換當前金鑰，也不會建立、刪除或修改 Memonta 的鑰匙串條目；舊金鑰僅在記憶體中快取，不寫入倉庫、日誌或釋出包。使用者明確要求將 Memozia 主金鑰改為 Memonta 金鑰時，必須先將原 Memozia 金鑰安全儲存到 Keychain 的 `previous_encryption_key` 並讀回確認，再更新主金鑰並讀回驗證；不得覆蓋不同的已歸檔金鑰。執行中的應用須重啟以重新整理記憶體金鑰快取。

Keychain 可能要求使用者允許 Memozia 訪問舊條目；拒絕、讀取失敗、金鑰不存在或密文損壞時保留現有失敗告警，不將密文作為明文接受。此相容不遷移目錄、不讀取 API Key；歷史條目仍需位於使用者為 Memozia 選擇的儲存目錄。同機舊金鑰缺失或跨裝置時，仍需透過口令保護的遷移備份恢復。

## 4. 資料刪除協議（安全刪除順序）

刪除錄音/筆記的統一順序（RecordingViewModel）：

1. 刪除確認對話方塊（單刪/批刪均彈），使用者確認後繼續
2. **先載入**依賴被刪資料夾的側資料（TodoDocument）→ 清理外部系統殘留（提醒事項中已寫入的 EKReminder）
3. **先刪磁碟資料夾**，後刪 DB 記錄——檔案刪除失敗時保留 DB 記錄，防止下次磁碟同步"復活"

媒體原件清理由 [MediaCleanupService](../../../Memozia/Services/MediaCleanupService.swift) 單獨處理：確認載荷固定目標與路徑，只刪除相應的音訊、圖片或影片單個檔案，不刪除條目資料夾、索引或提醒事項。清理前先儲存資料庫、內容映象與身份後設資料；轉寫走 `EntryMirrorStore.writeTranscriptNow`，總結與畫面要點走 `writeNow`，確認成功後才刪除原件。音訊清理意圖先落盤，避免崩潰恢復用遺留分片復活已清理音訊；圖片保留 `hasImageSource`，OCR 寫入加密 `ocr.txt`。磁碟重建可以恢復無音訊條目和無原圖的圖片條目，包括標題、身份、時長與已有文字內容。

清理與錄製、處理任務、磁碟掃描和錄音合併互斥；清理期間阻止更新安裝，正常退出等待清理收尾。列表右鍵統一收集所選條目中的音訊、圖片與影片原始檔；圖片索引缺失或失效時按磁碟事實核對 `source.png`，同一路徑去重。批次清理逐條執行，反饋實際刪除數量、檔案體積、無源件跳過數量與全部失敗條目及原因。定向驗證見 `MediaCleanupTests`（含 40 筆圖片、部分右鍵上下文、舊目錄與失效索引）及 `VideoCleanupTests`。
