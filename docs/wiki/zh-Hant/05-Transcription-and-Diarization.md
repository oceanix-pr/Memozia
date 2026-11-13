# 05 · 語音轉寫與說話人分離

[← 返回首頁](Home.md) · 原始碼目錄：Memozia/Services

本篇覆蓋"音訊 → 帶說話人標註的糾正後轉寫文字"的完整管線：

```
音訊檔案
 ├── 系統：SystemTranscription → SystemTranscriptionService（macOS 26+，SpeechAnalyzer）
 ├── 本地：WhisperLocalService（WhisperKit / CoreML）
 └── 雲端：WhisperAPIService（OpenAI Whisper API，>25MB 分片）
        ↓ TranscriptionResult（帶時間戳的 segments）
 ├── SpeakerDiarizationService（可選）說話人分離 → 回填 speaker
 │    ├── VoiceprintStore 聲紋識別（可選）→ 替換為註冊姓名
 │    └── DiarizationCalibrator（開發期校準工具）
 ├── ChineseConverterService 繁簡歸一化
 ├── TranscriptDictionaryService 詞典糾正（精確 + 拼音）
 └── TranscriptCache（UI 渲染快取，加速重複開啟）
```

## 1. WhisperLocalService — 本地轉寫

原始碼：[WhisperLocalService.swift](../../../Memozia/Services/WhisperLocalService.swift)（`@MainActor @Observable` 單例）

### 1.1 模型管理

| 成員 | 說明 |
|------|------|
| `loadModel` | 優先使用者指定 `modelFolder`（自動解析模型子目錄）→ 構造 `WhisperKitConfig(modelFolder/tokenizerFolder)` → 載入 `WhisperKit` → 更新載入狀態與進度 |
| `unloadModel()` / `unloadModelBlocking()` | 退出時非同步/阻塞解除安裝（App 退出路徑呼叫）；轉寫等任務空閒時也可解除安裝釋放視訊記憶體 |
| `modelBox` | 同步保護模型所有權；解除安裝原子取出，拿推理門後再讀取模型 |
| 序列門 | WhisperKit 單例項不支援併發推理，多路轉寫經 actor 序列門（非同步訊號量）排隊 |

### 1.2 轉寫執行

```swift
func transcribe(audioPath: URL, decodeOptions: DecodingOptions,
                callback: ((TranscriptionProgress) -> Bool?)?) async throws -> TranscriptionResult
```

- `DecodingOptions(task: .transcribe, language: <STTConfig.language>, temperature: 0.0)`
- `callback` 返回 `Bool?` 控制取消：沿用顯式取消標誌並返回 false；不能僅依賴回撥所在 Task 的取消狀態
- 輸出 `TranscriptionResult`：文字 + 起止時間 + 說話人欄位（供後續回填）

### 1.3 WhisperKit 配置約定

| 引數 | 值 |
|------|-----|
| `modelFolder` / `tokenizerFolder` | 同一目錄（tokenizer 與模型同放） |
| 模型來源 | 使用者指定目錄，載入前校驗；不依賴 Bundle 內建或自動下載完整模型 |
| 預設目錄 | `WhisperModelFolder.defaultPath`；當前構造只顯式傳入 modelFolder / tokenizerFolder |

## 2. WhisperAPIService — 雲端轉寫

原始碼：[WhisperAPIService.swift](../../../Memozia/Services/WhisperAPIService.swift)

| 方法 | 職責 |
|------|------|
| 轉寫入口 | 校驗 API URL（HTTPS 強制，localhost 豁免）→ 檢查音訊大小 → **>25MB 走分片轉寫** |
| 單檔案轉寫 | POST `/audio/transcriptions`，multipart/form-data 上傳音訊，`model=whisper-1`、`response_format=verbose_json` → 解析帶時間戳的 segments |
| 分片轉寫 | 切分音訊逐段上傳，結果按時間偏移拼接 |

API Key 存取經 Keychain（KeychainAccess），不落 UserDefaults。

## 3. SpeakerDiarizationService — 說話人分離

原始碼：[SpeakerDiarizationService.swift](../../../Memozia/Services/SpeakerDiarizationService.swift)

### 3.1 技術方案

sherpa-onnx 離線說話人日誌（**純 CPU 推理**，說話人數量自動估計）：

- **分段**：pyannote segmentation 3.0 的 ONNX 匯出；滑窗步長 `windowShiftRatio` 由**精細度檔位**決定（`0.10` = 90% 重疊，sherpa 預設；`0.40` = 60% 重疊，最省；預設檔 `0.25`）；視窗秒數由模型後設資料決定（pyannote segmentation-3.0 為 5s），步長 = ratio × 視窗
- **聲紋嵌入**：3D-Speaker eres2net（embedding.onnx）
- **聚類**：fast clustering（快速聚類）
- **執行緒**：`DiarizationThreads.resolved`（專業模式可調，區間 2…邏輯核心數−1，預設沿用歷史「核心數−2、封頂 6」），分段/嵌入兩模型共用；本階段無 QoS/thermal 退讓，長錄音時風扇拉高屬預期，降載手段見精細度檔位、CPU 核心數與 `refineClusters` 取樣上限
- **模型位置**：`~/Documents/Memozia/DiarizationModel/`（segmentation.onnx + embedding.onnx），設定頁一鍵從 GitHub Releases 下載（免 HuggingFace token），也支援手動放入
- 下載與推理各有**序列門**，防併發踩踏

### 3.2 主流程

| 方法 | 職責 |
|------|------|
| `diarizeWithSamples` | 構建 `sherpaOnnxOfflineSpeakerDiarizationConfig` → 執行 VAD/segmentation → embedding → fast clustering → 呼叫 `refineClusters` 精修 |
| 說話人回填 | 將 `TranscriptionResult` 片段與分離結果按**時間重疊最大原則**匹配，回填 `speaker`（"說話人 1"）；可選接聲紋識別替換姓名 |
| `refineClusters` | 簇後處理精修（見下） |

### 3.3 refineClusters 三階段精修（關鍵設計）

快速聚類常把同一人拆成多簇（實測雙人錄音出 9~13 簇），三階段修復：

1. **高相似合併**：同人拆簇相似度高（校準值：同人 0.903 vs 跨人 ≤0.68），閾值 **>0.60** 迭代合併
2. **碎片簇聚攏**：時長 < max(3s, 總時長 5%) 的碎片簇之間以 **0.50** 放寬閾值聚攏
3. **碎片併入大簇**：剩餘碎片併入最相似的大簇

最終按時長降序重編號（**說話人 1 = 說得最多的人**），併產出各說話人**質心嵌入**——直接供聲紋識別複用，不重複提取。

> 二遍提取的 CPU 約束：主 `process` 內部已對每段算過一次嵌入，但 sherpa wrapper 不暴露這些嵌入，精修只能重建提取器再算一遍；因此選段統一由純函式 `embeddingSegmentsBySpeaker` 控制：過濾 ≥1.5s 後**每說話人只取時長最長的 `maxSegmentsPerSpeaker`（30）段**（長片段資訊量更高，質心質量與全量提取等價）。風扇狂轉整改前這裡是對全部有效段無上限重提。

**質心構造三處必須同源**（選段規則 + 加權方式）：整段精修 `refineClusters`、分段模式的全域性質心、註冊流程 `extractVoiceprint`。三者都走「過濾 ≥1.5s → 取最長 30 段 → **按時長加權**平均 → L2 歸一化」。迴歸用例見 [DiarizationSegmentationTests.swift](../../../MemoziaTests/DiarizationSegmentationTests.swift)、[VoiceprintMergeTests.swift](../../../MemoziaTests/VoiceprintMergeTests.swift)（含註冊側與識別側選段一致性）。

### 3.3.1 長錄音分段處理（超過 `maxDirectDuration`，預設 30 分鐘）

純計算部分在 `DiarizationSegmentationPlanner`（時長/記憶體估算、閾值判定、切分含重疊、重疊區去重、跨段身份合併、按時長重編號），逐段推理在 `diarizeSegmented`：

- 按 `segmentDuration`（8 分鐘）切分、相鄰段重疊 `segmentOverlap`（30 秒）；每段單獨 `process` + 段內簇精修，段末即釋放取樣，**峰值記憶體 ≈ 單段**。
- 跨段身份合併 `globalSpeakerMapping`：按段順序把區域性編號對齊到全域性編號（相似度 ≥ `chunkIdentityMergeThreshold` 0.55 視為同一人），空質心單獨佔號；相鄰段重疊區由 `mergeOverlapping` 去重（前段標籤優先）。
- **全域性質心不平均各段質心**：早期實現把逐段區域性質心等權算術平均，存在權重錯配（只講 20 秒的噪聲質心與講 5 分鐘的穩定質心同權）與順序相關兩個缺陷，長會議下同人質心被拉偏。現改為在整段錄音上對最終全域性說話人**重新按最長 30 段 + 時長加權提取**，與整段路徑同源；`weightedCentroid` 逐區間讀取，峰值記憶體 = 單個片段取樣（不回到整段常駐）。

### 3.3.2 精細度五檔（`DiarizationPrecision`）

專業模式「設定 → 轉寫 → 說話人分離」暴露的五檔，單一軸是**邊界與分段精度 ↔ CPU / 記憶體開銷**。持久化鍵 `diarization_precision`，無儲存值或越界回落到中間檔。

| 檔 | `maxDirectDuration` | `maxDirectMemoryBytes` | `segmentDuration` | `segmentOverlap` | `windowShiftRatio` |
|---|---|---|---|---|---|
| 1 最快 | 10 min | 96 MB | 5 min | 15 s | 0.400 |
| 2 較快 | 20 min | 160 MB | 6 min | 20 s | 0.325 |
| **3 標準（預設）** | **30 min** | **256 MB** | **8 min** | **30 s** | **0.250** |
| 4 精細 | 30 min | 256 MB | 15 min | 45 s | 0.175 |
| 5 最精細 | 30 min | 256 MB | 20 min | 60 s | 0.100 |

設計約束（改檔位表時必須同時滿足）：

- **中間檔嚴格等於歷史預設行為**，預設檔不得改變既有結果。
- **整段門檻對所有檔位都不超過 30 分鐘**。峰值記憶體由**單次 `process()` 的音訊長度**主導（ONNX Runtime 中間張量），不是解碼後的取樣陣列；`maxDirectMemoryBytes` 只約束後者。2026-09-24 用同一條 143 分鐘 16k 單聲道錄音（4 執行緒）實測：

  | 處理方式 | 峰值記憶體 | 耗時 | 結果 |
  |---|---|---|---|
  | 分段 12 分鐘/段 | 1.68 GB | 12 分 30 秒 | 5 個說話人 |
  | 分段 20 分鐘/段 | 2.60 GB | 18 分 13 秒 | 4 個說話人 |
  | **整段（143 分鐘一次）** | **8.3 GB** | 14 分 20 秒仍未完成（終止） | — |

  所以「提高 `maxDirectDuration` 換精度」是危險做法：檔位越高越應靠**更長的分段 + 更密的視窗**換精度，而不是靠整段。檔 4/5 與檔 3 的整段門檻相同是**有意為之**，不是筆誤。
- **兩類引數刻意不隨檔位變化**：① 嵌入選段上限 `maxSegmentsPerSpeaker`（註冊與識別共用，隨檔變化會讓舊檔註冊的聲紋與新檔比對的質心錯位）；② 聚類與跨段合併閾值 `0.60 / 0.50 / 0.55`（由 `DiarizationCalibrator` 聯合標定，脫離校準改數值會把「同人拆簇」變成「兩人合併」）。
- 檔位在**每次推理開始時解析一次**並向下傳遞，避免同一次分離裡「模式判定」與「實際切分」讀到兩個不同檔位；改檔位**不追溯**，需重新轉寫才生效。`DiarizationCalibrator` 也讀同一檔位，保證校準結果可直接套用。

### 3.4 穩定性約束

模型缺失 / 分離失敗 / 精修失敗時**逐級回退**（精修失敗用原始聚類結果），任何失敗都不影響轉寫本身。失敗只進 `Logger`（`FileSyncService.logWarning`）並在 `applySpeakers` 被 catch 後原樣返回結果，因此 UI 上只表現為「轉寫正常但沒有說話人」；分離產出 0 片段同樣會留一條 warning，避免只能靠猜。

### 3.5 音訊載入 `loadMonoSamples`（曾經的靜默失效點）

分離與聲紋（`extractVoiceprint`）共用這一個載入器：`AVAudioFile` 逐塊讀取 + `AVAudioConverter` 重取樣到模型要求的 16k 單聲道 Float32。載入器分**整段**與**區間**（`timeRange`）兩個入口：整段路徑用前者，註冊與分段全域性質心的 `weightedCentroid` 用後者（只讀所選片段，不把整段錄音讀進記憶體）。兩個約束必須同時成立：

- **記憶體**：不得按整段時長一次分配源緩衝（2h48k 立體聲源緩衝≈2.7GB，峰值近 4GB，長會議會被系統直接殺掉且無日誌），故按 `sourceChunkFrames`（48000 幀）分塊。
- **EOF 出口**：macOS 27 beta (26A428) 上 `AVAudioFile.read(into:)` 讀到檔案末尾會拋 `NSOSStatusErrorDomain` 的 `eofErr(-39)`，**不返回 0 幀**。因此迴圈以幀預算（`file.length`）驅動，並把 `eofErr` 當作正常收尾（`isEndOfFileRead`）；只認這一個碼，其餘解碼/許可權錯誤繼續上拋，不能偽裝成「讀完了」。

兩者是同一提交裡一起改的：只修記憶體不修 EOF 出口時，每一段音訊都會在**全部幀已讀出之後**失敗，並被上面的靜默回退吞掉——表現為升級後說話人與聲紋整體不再產出，且日誌裡只有一條 warning。迴歸用例見 `MemoziaTests/DiarizationAudioLoadTests.swift`（覆蓋重取樣與直拷兩條分支 + 空音訊/缺失檔案仍報錯）。

## 4. VoiceprintStore — 聲紋庫

原始碼：[VoiceprintStore.swift](../../../Memozia/Services/VoiceprintStore.swift)

### 4.1 儲存

- 路徑：`~/Documents/Memozia/Voiceprints/<uuid>.json`
- 記錄：姓名 + 歸一化聲紋向量 + `modelId`（**繫結嵌入模型**，換模型後舊聲紋自動停用）

### 4.1.1 同名聲紋合併

同人聲音條件差異大（感冒/遠距麥克風）時註冊相似度不達查重閾值 0.65，會按同名新建出多條記錄。聲紋庫管理頁（設定→聲紋庫）僅在存在可合併組時展示「合併同名」入口：`VoiceprintStore.mergeSameNameGroups` 按 (name, modelId, dim) 分組，`mergedVoiceprint` 純計算按 sampleCount 加權質心→ L2 歸一化，id/createdAt 沿用最早一條（覆寫其檔案），來源錄音 ID 並集去重；**先寫合併結果再刪餘條**，寫失敗不丟原資料；不跨模型合併。純函式+臨時目錄迴歸見 `MemoziaTests/VoiceprintMergeTests.swift`。

### 4.2 閾值常量

| 常量 | 值 | 用途 |
|------|-----|------|
| `matchThreshold` | 0.5 | 識別命中閾值 |
| `matchMargin` | 0.05 | top1-top2 領先幅度（防歧義） |
| `samePersonThreshold` | 0.65 | 註冊查重（≥ 視為同人） |

### 4.3 核心方法

- 載入/儲存/刪除（JSON 檔案讀寫）
- 相似度計算：L2 歸一化 + 餘弦相似度

### 4.4 兩條業務流程

**流程 A · 註冊**（轉寫結果頁"聲紋"按鈕）：

1. 彈窗每個說話人左側有**試聽按鈕**：播放該說話人**最早**出現的片段（`AudioPlayerState.playRange` 從片段起點精確起播、播到片段結束自動暫停，邊界檢測掛在 0.5s 週期觀察者上），便於判斷這一串標註到底是誰；音訊原件缺失時按鈕禁用
2. 為說話人填姓名
3. 按該說話人的片段區間提取嵌入（純函式 `voiceprintRanges` 選段：過濾 ≥1.5s → 取**時長最長的 30 段**）→ **按時長加權**平均歸一化 → 入庫。選段與加權與識別側（`embeddingSegmentsBySpeaker` + `centroid(of:)`）同源，避免「註冊向量」與「比對質心」落在兩個構造上；只讀取所選區間，不把整段錄音讀進記憶體
4. 同時批次替換本錄音的說話人標註
5. 查重：與庫內最高相似聲紋比對，≥0.65 同人（同名更新、異名報錯）

標記成功後轉寫頁必須立即顯示新姓名。寫路徑統一走 `invalidateTranscriptCache`，它**先清 `TranscriptCache`、再遞增 `transcriptVersion`**——順序顛倒會讓 `TranscriptView` 的 `.task(id:)` 搶在清快取之前命中舊條目，頁面停在「說話人 N」且後續沒有新的版本變化、不會自愈。

**流程 B · 識別**（轉寫時，分離完成後）：

1. 先按 (name, modelId, dim) 把同名多條目摺疊為單條（`VoiceprintStore.collapsingSameName`）：同人跨場次註冊相似度達不到 0.65 會並存多條，不折疊會讓同一姓名同時佔據 top1/top2，把領先幅度壓到 `matchMargin` 以下，使該人**永遠無法被識別**
2. 用 `refineClusters` 產出的說話人質心與庫比對（**不介入聚類本身**）
3. 命中條件：相似度 ≥0.5 **且** top1-top2 領先 ≥0.05，否則保留"說話人 N"
4. **全域性唯一性分配**：小規模採用最大權重匹配（每人 top 3 候選），超過 8 個說話人降級為按分數貪心分配，每個註冊聲紋最多分配給一個說話人——防止兩個不同說話人被標成同一姓名

庫為空/失敗時**靜默回退**，不阻塞轉寫；開關 `enableVoiceprintRecognition` 預設開啟。未命中/歧義都會留一條 warning（含 top1/top2 與領先幅度），便於事後核對識別質量。

## 5. DiarizationCalibrator — 分離校準工具

原始碼：[DiarizationCalibrator.swift](../../../Memozia/Services/DiarizationCalibrator.swift)

開發期命令列校準工具，啟動引數觸發（`runIfRequested` 在 App 初始化最早期呼叫，校準後直接退出，不進 UI）：

```bash
Memozia --calibrate-diarization <音频路径> [阈值|centroid[:阈值]|refine] [模型文件夹]
```

| 模式 | 用途 |
|------|------|
| 閾值掃描 | 按閾值構造 `sherpaOnnxFastClusteringConfig` 逐個執行，輸出各說話人時長，用於選擇聚類閾值 |
| centroid / refine | 輸出質心相似度分佈 / 校驗 refineClusters 精修效果（0.60/0.50 等閾值即由此校準） |

## 6. ChineseConverterService — 繁簡歸一化

原始碼：[ChineseConverterService.swift](../../../Memozia/Services/ChineseConverterService.swift)

說話人分離之後、詞典糾正之前按語言設定進行繁簡歸一；使用內建 OpenCC 詞表與現有轉換輔助，方向以 ChineseConverterService 和呼叫方為準。

## 7. TranscriptDictionaryService — 詞典糾正

原始碼：[TranscriptDictionaryService.swift](../../../Memozia/Services/TranscriptDictionaryService.swift)

### 7.1 詞典儲存與格式

- 位置：`~/Documents/Memozia/Dictionary/` 下的 **Markdown 檔案**（設定 → 詞典 視覺化新建/編輯/刪除）
- 條目格式：

```markdown
- 术语                    ← 拼音自动纠正（同音/近音误写替换为"术语"）
| 错误词 | 正确词 |        ← 精确替换
错误词 -> 正确词           ← 精确替换（箭头式）
- 词语 #去标识化:类别      ← PII 词条标记（不参与转写纠正，见 06 篇）
```

### 7.2 糾正演算法

`correct(_:)` 兩階段，**精確替換優先**：

1. **精確替換**：字串直接匹配（長詞優先）
2. **拼音匹配**：`applyPinyinCorrection` —— `rawPinyin` 用 `CFStringTransform` 逐字轉無聲調拼音（去聲調、去分隔符歸一化），在**連續漢字片段內滑窗**比對讀音，相同則替換

### 7.3 執行時機

轉寫後、繁簡歸一化之後、加密之前；對已完成轉寫**不追溯**，重新轉寫後生效。

## 8. TranscriptCache — 轉寫渲染快取

原始碼：[TranscriptCache.swift](../../../Memozia/Services/TranscriptCache.swift)

按錄音 ID 快取"**解密 + 拼接 + Markdown 解析**"後的結果（`SegmentData`：Markdown 文字 + 塊結構），避免每次開啟詳情頁重複解密全量片段。

| 方法 | 職責 |
|------|------|
| 快取讀寫 | key = 錄音 ID；命中直接返回結構化資料 |
| `invalidate` | 編輯片段/重新轉寫後失效；TranscriptView 用 `transcriptVersion` 計數驅動快取重建 |

快取已有 LRU：當前代價上限 64MB、條目上限 24，並至少保留一條；閾值以 `TranscriptCache.Store` 實現為準。編輯/重轉寫必須失效快取。

## 9. 後處理管線執行順序（總表）

```
轉寫結果（TranscriptionResult）
 ① [可選] SpeakerDiarizationService.diarize → 按時間重疊回填 speaker
 ①' [可選] VoiceprintStore 質心識別 → 全域性唯一分配替換姓名
 ② ChineseConverterService 歸一化（繁→簡）
 ③ TranscriptDictionaryService.correct（精確 → 拼音滑窗）
 ④ EncryptionService 加密
 ⑤ TranscriptSegment[] 入庫 + transcript.json 落盤
（快取 TranscriptCache 在此之後構建/失效）
```

編排方為 `RecordingViewModel` 的轉寫後處理鏈（[10-ViewModel層](10-ViewModels.md) §1.2）。

## 10. SystemTranscription — 系統語音識別

原始碼：[SystemTranscriptionService.swift](../../../Memozia/Services/SystemTranscriptionService.swift)。

- `SystemTranscription` 是低版本安全的統一入口，macOS 26+ 委託 `SystemTranscriptionService` 使用 SpeechAnalyzer / SpeechTranscriber；低版本明確報不支援。
- 語言資產由系統 `AssetInventory` 管理，不使用 Whisper 模型目錄；首次轉寫可自動準備，也可透過 `prepareLocale` 提前準備。`localeStatus` 區分 ready / needsDownload / unsupported。
- 沒有自動語種檢測，顯式語言優先，空值跟隨系統語言；仍需語音識別授權。輸出時間軸片段後複用現有說話人分離與後處理。
- 推理由可取消序列門保護；模型準備階段可顯示不定進度，識別進度按已處理時間軸估算。
- `STTMode.defaultMode` 在支援的系統上預設選系統引擎，否則選 WhisperKit；新選擇不再提供雲端 Whisper，但已儲存的雲端配置仍可顯示和執行。
- `NativeSpeechService` 用於文字筆記轉語音，屬於語音合成，不是本節的語音識別服務，見 [檢視層](11-Views.md) §8.1。
