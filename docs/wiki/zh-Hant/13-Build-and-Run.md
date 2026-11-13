# 13 · 構建與執行

[← 返回首頁](Home.md)

## 1. 工程與環境

[project.yml](../../../project.yml) 是 XcodeGen 配置源：`deploymentTarget`、`SWIFT_VERSION`、`xcodeVersion`、targets、簽名與依賴均以它為準。
當前宣告 macOS 15 最低部署、Swift 6 語言模式和 Xcode 27 工程版本；構建工具鏈還需包含原始碼引用的新 SDK API。
最低應用執行版本不等於開發機最低版本；不要沿用舊文件“macOS 13 + Xcode 16 即可構建”的假設。

`Memozia`、`MemoziaTests`（Swift Testing 單元測試）與 `MemoziaUITests`（XCUITest）均為 macOS target（工程已取消 iOS 支援，iOS 分享擴充套件 target 與相關程式碼已刪除）。

## 2. 構建與測試命令

在專案目錄執行；若 Xcode 安裝位置不同，替換 `DEVELOPER_DIR`。這也避免 `xcode-select` 指向 Command Line Tools 時找不到完整 SDK。

```sh
# 首次生成，或源文件增删、依赖/工程配置变化后运行；仅改文档不用执行
xcodegen generate

# macOS Debug
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' build

# Swift Testing（单元测试；UI 测试需 GUI 会话与辅助功能授权，见 §5）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' test -only-testing:MemoziaTests

# XCUITest（冒烟 + 无障碍审计 + 多语言/RTL/伪本地化截图基线）
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Memozia.xcodeproj -scheme Memozia -configuration Debug -destination 'platform=macOS' test -only-testing:MemoziaUITests
```

不要手改生成的 `.xcodeproj`。簽名團隊不可用時按本機環境配置後重生成工程。
測試 target 的 `TEST_HOST` 在 `project.yml` 中顯式指向 app 內部可執行檔案（`Contents/MacOS`），勿改回缺少該路徑的舊值。
改了 `Scripts/` 下的構建指令碼後必須重新執行 `xcodegen generate`：指令碼內容在生成階段寫進工程，否則構建仍跑舊副本。

## 3. 模型與首次執行

- 首啟隱私同意後展示按體驗模式組織的功能引導；引導不再包含模型下載頁。模型在實際使用時按需準備，專業模式也可在設定中管理。麥克風、語音識別、螢幕錄製、輔助功能、提醒事項按功能請求。
- 系統語音識別透過 `SystemTranscription` / `SystemTranscriptionService` 在 macOS 26+ 使用 SpeechAnalyzer；語言資產由系統按需管理，不依賴 Whisper 模型目錄。`STTMode.defaultMode` 與體驗模式解析器按系統能力決定預設引擎，舊系統保留 WhisperKit 路徑。
- 本地 Whisper 透過設定選擇模型資料夾，預設目錄由 `WhisperModelFolder.defaultPath` 提供；模型與 tokenizer 檔案須完整，載入邏輯會解析子目錄。
- 設定頁「下載模型」可按檔位下載（`WhisperModelOption.catalog`），源可選 HuggingFace 官方或 HF-Mirror 映象（預設映象，見 `WhisperModelSource`）；下載走 `WhisperKit.download` 並顯式傳 endpoint，完成後從 `<模型文件夹>/models/<repo>/<档位>` 重新命名到 `<模型文件夹>/<档位>`，隨即載入該模型。下載任務經全域性處理佇列（`TaskCenter.whisperDownloadJob`），是**唯一支援真正暫停 / 續傳**的任務：取消（含暫停觸發的取消）保留已落盤分片與 `.cache` 後設資料，繼續時重新排程該步即從斷點續傳。
- 當前工程排除 `Resources/Models/**`，不要假設 App 內建 tiny/base/small/medium；模型只能由使用者手動放置或經上述下載獲得。
- 說話人分離模型由設定頁下載，或指定包含 segmentation.onnx / embedding.onnx 的目錄。下載與 Whisper 統一為「取消保留、重下續傳」：`SpeakerDiarizationService.downloadFile` 用 URLSession 流式寫臨時檔案，取消時把 `resumeData` 落盤為 `.resume`，重下時以 `downloadTask(withResumeData:)` 從斷點繼續。
- LLM 設定使用 OpenAI 相容服務；請求端沿用 URL 校驗，迴環 HTTP 豁免與任意區域網 HTTP 是不同情況。

## 4. 指令碼與資源

| 指令碼 | 用途 |
|---|---|
| [fix_onnxruntime_framework.sh](../../../Scripts/fix_onnxruntime_framework.sh) | preBuild 修復動態 framework 佈局和引用，避免嵌入簽名/啟動失敗 |
| [verify_embedded_frameworks.sh](../../../Scripts/verify_embedded_frameworks.sh) | postBuild 重籤 Xcode Run/Test 會優先載入的構建目錄框架，並校驗 `SherpaOnnxC` 引用與簽名 |
| [bump_build_number.sh](../../../Scripts/bump_build_number.sh) | 釋出前手動分配構建號，不在構建階段執行 |
| [bump_version.sh](../../../Scripts/bump_version.sh) | 釋出時手動 `patch` / `minor` / `major` 更新營銷版本，之後重生成工程 |

**ONNX Runtime 產物修復與校驗**（啟動崩潰防線）：

- 上游 sherpa-onnx/onnxruntime 動態產物有兩個打包問題：framework 用實體目錄替代符號連結（嵌入後簽名嚴格校驗失敗），以及 `SherpaOnnxC` 引用 `@rpath/libonnxruntime.dylib`（該 dylib 並不隨包，啟動即 `Library not loaded`）。
- 修復指令碼只定位**本次構建**的產物：`BUILD_DIR` / `BUILD_ROOT` 都是 `…/DerivedData/<工程>/Build/Products`（不含配置目錄），`SourcePackages/artifacts` 位於其上級目錄（`../../`）；另支援釋出指令碼顯式傳入的 `MEMOZIA_PACKAGE_CACHE_PATH`、`OBJROOT` 與倉庫內 `.packages`（自定義 packageCachePath）。它不再遍歷其他工程的 DerivedData；`install_name_tool` 修復失敗會直接讓構建失敗。
- SwiftPM 會同時生成 `$(CONFIGURATION_BUILD_DIR)` 副本與 App 嵌入副本。Xcode Run/Test 會透過 `DYLD_LIBRARY_PATH` 優先載入前者；`install_name_tool` 又會使上游簽名失效，因此 postBuild 需用與 App 一致的身份重籤構建目錄副本。校驗指令碼同時檢查兩處的引用與簽名，防止「構建成功、除錯或測試啟動即被 AMFI 終止」。
- `Memozia` target 明確關閉 `ENABLE_USER_SCRIPT_SANDBOXING`：上述指令碼必須修改 SwiftPM 動態 hash 路徑下的二進位制產物，並讓 `codesign` 遞迴讀取 framework 及其擴充套件屬性，無法用固定的 Run Script Input/Output 列表完整宣告。該設定隻影響構建指令碼的執行沙箱，不會關閉 App Hardened Runtime 或最終程式碼簽名。

`Scripts/add_*l10n*.py` 屬一次性本地化維護工具，不是正常構建必需步驟。
`Scripts/fill_empty_l10n.py` 用於補齊 `Localizable.xcstrings` 的空條目：靜態解析各 `add_*l10n*.py` 的 `add(源文, [20 语言])` 取值（**不執行**它們，部分指令碼無 `__main__` 守衛、匯入即寫檔案），只寫當前缺少譯文的鍵與缺失的 zh-Hans 源文條目，已有譯文一律不覆蓋；寫入前校驗佔位符種類/數量與源文一致，並列出仍未覆蓋的鍵。
使用者文案位於 `Localizable.xcstrings`；語言列表由 `knownRegions` 和實際資源決定。修改佔位符需核對各語言型別。
圖示尺寸生成前核查當前源圖路徑及 Assets 引用，不依賴舊文件中的 `icon.png` 假設。

## 5. 測試覆蓋與驗證邊界

- [MemoziaTests.swift](../../../MemoziaTests/MemoziaTests.swift)：時長、狀態/配置、匯入與影片命名、關鍵幀指紋與事件/名額純函式、匯出文件等。
- [KeyframeExtractorTests.swift](../../../MemoziaTests/KeyframeExtractorTests.swift)：代表幀跨時間窗判重與名額回填、`LLMService.visualChunks` 分段送幀（與上一行的分工：本檔案只測這兩個不變式）。
- [StabilityRegressionTests.swift](../../../MemoziaTests/StabilityRegressionTests.swift)：看門狗、可取消門閘、流式合批、超時預算、磁碟節拍、臨時目錄唯一性、失敗報告、詞典掃描等。
- [WhisperModelDownloadTests.swift](../../../MemoziaTests/WhisperModelDownloadTests.swift)：模型檔位名（glob 唯一性/精確倉庫目錄名）、下載源端點與預設值、`HF_ENDPOINT` 寫入、三件套就緒判定與檔位隔離（均為純邏輯，不聯網）。
- 不在文件維護測試數量或“永久透過”結論；以當前原始碼及實際執行結果為準。
- 型別檢查不覆蓋連結、簽名和執行時；音訊裝置、許可權、Keychain、視窗、恢復及 worker 需按 [迴歸場景](../../TECH_DEBT.md) 選擇實測。

## 6. SDK 相容經驗

- AudioConverter 在 macOS 26+ 使用 provider/receiver 非同步路徑，保留舊系統 Reader/Writer 實現。
- SystemAudioCaptureService 的新實時寫入路徑使用 SampleBufferReceiver；MicCaptureService 的 macOS 27+ 路徑使用只讀 tap。
- 新 API 透過 availability 分支接入，不能為消除棄用警告提高應用最低部署版本。
- `deploymentTarget` 是當前工程使用的鍵；舊錯誤鍵 `deploymentTargets` 曾導致最低系統版本未正確生成。

## 7. 除錯與常見問題

| 場景 | 入口 |
|---|---|
| 分離閾值校準 | 應用可執行檔案 `--calibrate-diarization <音频> [阈值或 centroid/refine 模式] [模型目录]`；引數以 DiarizationCalibrator 為準 |
| worker 除錯 | 應用可執行檔案 `--background-worker` 會真實消費持久佇列，僅對隔離測試資料使用；協議見架構 §3 |
| 提醒事項 URL | `reminders_url_diagnostic` 偏好控制 RemindersURLDiagnostic；診斷檔案不作為常駐上下文 |
| 長錄音儲存失敗 | 檢查控制代碼數、磁碟和 PersistenceReporting 日誌；啟動 fd 限制提升見 ProcessLimits |
| 系統音訊無聲 | 檢查螢幕錄製許可權、重啟提示和首包 PTS 對齊 |
| 熱鍵/語言不生效 | 檢查使用者熱鍵配置、系統衝突；語言設定寫 AppleLanguages 後重啟 |
| TCC 除錯 | 僅明確的開發排障使用 DEBUG 清理路徑，不在釋出版自動重置授權 |

獨立發佈前須配置更新來源、公鑰、簽署與有效聯絡管道；驗收見 [發佈檢查](../../RELEASE_CHECKLIST.md)。

釋出、許可證與開源準備統一見 [釋出檢查](../../RELEASE_CHECKLIST.md)。
