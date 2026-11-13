# 02 · Architecture

[← Home](Home.md)

## 1. Layers

Memozia uses MV + Service, an MVVM-style organization for SwiftUI. The project is macOS-only and retains platform guards where appropriate.

```text
App shell: MemoziaApp + AppDelegate
  single instance / file limits / model endpoint / startup / menu commands
Views: RootView (NavigationSplitView)
  ├─ RecordingListView (recordings and notes)
  ├─ RecordingDetailView → Transcript / Summary / VideoUnderstanding
  ├─ QuickNoteDetailView / screenshot AppKit components
  └─ Settings / Help / Onboarding / Privacy / Markdown / FindReplace
ViewModels (@MainActor @Observable)
  RecordingViewModel / QuickNoteViewModel / SettingsViewModel
Services
  ├─ Capture: MeetingRecorderService → MicCaptureService / SystemAudioCaptureService
  │           AppMuteDetector / MicMuteMonitor / AudioConverter
  ├─ Transcription: SystemTranscription / WhisperLocalService / WhisperAPIService
  │                 SpeakerDiarizationService / VoiceprintStore
  │                 ChineseConverterService / TranscriptDictionaryService / TranscriptCache
  ├─ AI: LLMService / TodoExtractionService / KeyframeExtractor
  │      VideoUnderstandingService / RemindersService / PIIScrubService / PIIScanService
  ├─ Screenshots: ScreenshotManager / VisionOCRService
  ├─ Storage: FileSyncService / CloudSyncService / EncryptionService
  ├─ OS: MenuBarController / GlobalHotkeyManager / RemindersURLDiagnostic
  ├─ Scheduling: TaskCenter + AsyncClassGate
  └─ Updates: AppUpdateService / UpdateInstallationCoordinator
Data: AudioRecording / TranscriptSegment / LLMConfig / QuickNote
      STTConfig / RecordingConfig / TodoItem / TodoDocument
      Authoritative files in month/timestamp entry folders
SPM: WhisperKit / KeychainAccess / SherpaOnnx / Sparkle
```

Views bind to ViewModels and SwiftData queries; ViewModels orchestrate services. Shared-service references and notifications decouple coordination. Cross actors using IDs and Sendable snapshots such as `LLMConfigSnapshot`, not SwiftData objects.

### 1.1 Standard and Pro experiences

`AppExperienceStore` supplies observable UI state; `AppExperiencePreference` is the non-UI preference layer shared by AppKit, shortcuts, and background code. `FeaturePolicy` gates visibility and action permissions. `EffectiveSettingsResolver` derives effective capture/STT/screenshot/PII settings at task boundaries.

Both experiences share targets, schema, file format, and implementations. Switching does not rewrite Pro preferences; Standard meeting scenario and local model path are separate. New users default to Standard; previously onboarded users retain Pro during migration. Menus, shortcuts, RootView notification handlers, and service boundaries all enforce feature policy rather than relying solely on hidden views.

## 2. Data flow

### 2.1 Recording → transcription → summary → tasks

```text
Start recording (toolbar/menu/shortcut)
→ RecordingViewModel.startMeetingRecording
→ MeetingRecorderService.startRecording
   ├─ Disk preflight (at least 500 MB), atomically allocate entry folder
   ├─ microphone / systemAudio / parallel mixed capture
   ├─ Rotate microphone CAF and system WAV segments every 300 seconds
   ├─ AppMuteDetector polls Teams/Zoom AX controls
   └─ MicMuteMonitor observes CoreAudio mute state
Stop recording
→ stopMeetingRecording → stopRecording
→ AVMutableComposition mixing/export to m4a
   (single-track fallback; validate crash-left segments before recovery)
→ AudioRecording + meta.json
User requests transcription or confirms one-click processing
→ TaskCenter Job → startTranscription
   ├─ SystemTranscription → SystemTranscriptionService (macOS 26+ language assets)
   ├─ WhisperLocalService → WhisperKit/CoreML serial gate
   └─ WhisperAPIService (legacy cloud, chunks above 25 MB)
→ Optional diarization and voiceprint identity
→ Chinese normalization → dictionary correction
→ Encrypt segments → index + transcript.json
User requests summary
→ Optional cloud-text PII scrub → LLM streaming → restore identifiers
→ Encrypt summary + summary.md → generate title
User requests tasks
→ Structured JSON extraction → restore identifiers → encrypted todos.json
→ User confirmation → EventKit Reminders
```

### 2.2 Screenshot → image note

Global capture shortcut or menu notification routes through RootView to ScreenshotManager. Preflight permission, then either direct full-screen capture on the pointer's display or a frozen region/window/full-screen session. Annotation produces copy/file/pin/confirmed-note outcomes. `screenshotCaptureSaved` sends original/marked PNG; RootView creates an image QuickNote, optionally performs OCR, and uses a vision-capable model for image summaries. Screenshots are not separate entities; see [Screenshots and OCR](07-Screenshots-and-OCR.md).

### 2.3 Removed sharing extension

The iOS Share Extension, App Group inbox, and `importFromShareExtension` route were removed with iOS support. Media import now uses the toolbar picker or drag/drop; see [ViewModels](10-ViewModels.md).

## 3. Lifecycle and background work

Sources: [MemoziaApp.swift](../../../Memozia/MemoziaApp.swift), [BackgroundWorker.swift](../../../Memozia/Services/BackgroundWorker.swift), [BackgroundTaskQueue.swift](../../../Memozia/Services/BackgroundTaskQueue.swift).

### 3.1 Startup and shutdown

Process hooks handle calibration, worker execution, runtime verification, duplicate-instance exit, and file-descriptor limits before normal startup. `StartupCoordinator` in [StartupBootstrap.swift](../../../Memozia/Services/StartupBootstrap.swift) performs worker stop → database lock → ModelContainer asynchronously; `StartupRootView` displays phases, failures, and retry choices. Blocking handshake/lock work runs off the main thread.

`DatabaseOwnershipLock` uses flock on `.db_ownership.lock` under storage. Neither app nor worker opens a writable container without it. If occupied or unavailable, show the cause and allow retry or an explicit user choice of transient memory mode. The worker preserves the queue and exits when it cannot acquire ownership. Kernel process cleanup releases locks after normal exit or crash. Persistent-container failures also expose retry/transient choices. CloudKit remains disabled.

Consent-gated lifecycle tasks serialize migration, state reset, disk reconciliation, and queue recovery; independent model prewarming is separate. During termination, wait for merging within bounded estimates, finalize live capture, flush EntryMirrorStore with a bound, spawn the worker if required, unload inference resources, and call `ProcessLimits.exitSkippingStaticDestructors` (`_exit`). Ordinary C++ finalization in ONNX/Sherpa can abort; duplicate-instance, calibration, worker, and privacy-refusal exits use the same helper. Closing a window is not quitting; AppDelegate/MenuBarController restore it idempotently. Update-specific shutdown is described in [System Integration](09-System-Integration.md), §6.

### 3.2 Product boundaries

- The same binary starts a no-UI `--background-worker`; there is no extra target.
- Continue only user-initiated transcription/recording summary/note summary and recover leftover segments. Do not issue AI requests for untouched entries.
- Do not prevent sleep; continue after waking and exit when no ready work remains.
- Main-app startup requests cooperative handoff. Grace/termination waits are chosen by callers such as `StartupDependencies.live()`. Even a still-running worker never permits bypassing the database lock.
- Visual frame analysis does not run in the background queue; quitting cannot be described as continuing visual extraction/requests.

### 3.3 Persistent queue protocol

| Object | Contract |
|---|---|
| `.background_task_queue.json` | Storage-root queue with kind, folderName, config ID/snapshot, enqueue time |
| STT snapshot | Model/language/post-processing settings; no API key in JSON; read Keychain at execution |
| LLM reference | ID lookup with documented active/first-config fallback, not a complete immutable parameter snapshot |
| Writes | Atomic replace and flock read-modify-write. Lock failure abandons changes; corruption is quarantined with backup recovery and visible reporting |
| `inProgressID` | Clear crash-left execution marks; retained entries remain eligible; enqueue deduplicates by target/kind |
| PID/stop files | `.background_worker.pid`, `.background_worker_stop` coordinate liveness and handoff |

The worker recovers segments before opening the database and then creates its own ModelContext; no `@Model` crosses processes. MainActor tasks and the run loop drive processing without blocking callbacks.

`drainQueue` removes completed or confirmed-missing targets only. Read/network/model/credential failures retain entries, increment `attempt`, set `nextRetryAt` with exponential backoff, and preserve a stable reason code. The maximum attempts move entries into `failedEntries` for explicit retry. Failure to persist execution marks, dequeue, or backoff stops consumption to avoid duplicate execution. Note processing saves content/tasks but never invokes UI-dependent Reminders consent/write flows. The main app may reuse queue draining for recovery.

### 3.4 In-app TaskCenter

[TaskCenter.swift](../../../Memozia/Services/TaskCenter.swift) is an in-memory MainActor observable scheduler, distinct from the disk-backed cross-process queue.

- `TaskKind` covers downloads, transcription, visuals, summary, title refinement, and tasks. Real-time capture starts immediately and does not enter this queue.
- At most three Jobs run concurrently. AsyncClassGate additionally limits local inference to one, downloads to one, and network LLM work to three. The lower-level inference gate still protects model instances.
- One-click processing is one parent Job with ordered Steps. `OneClickPlan` and preview determine completed outputs, skips, retranscription, edited-transcript backup, and cloud image/frame scope.
- Report stable `TaskErrorCode` plus failure time, retain failed Jobs, allow retrying a Step or whole Job, and offer context-specific repair actions.
- Model download pause cancels transport while preserving pieces/cache for resume. Other tasks have no resume cursor and pause is cancellation.
- Steps call existing ViewModel methods and await their tasks; forward cancellation through existing cancel entry points.
- Model `ProcessingStatus` restores display across restarts. TaskCenter failure codes/times are session-local. Worker capabilities remain separate; no background visual analysis is added.

## 4. Authoritative storage

The default root is `~/Documents/Memozia/`, configurable in settings. New entries use month directories and collision-safe timestamps; read old flat folders too.

```text
Memozia/
├─ yyyy-MM/yyyyMMddHHmmss[-N]/
│  ├─ recording.m4a
│  ├─ {base}_video.mp4              (optional original)
│  ├─ frames/                      (cached JPEG keyframes)
│  ├─ visual.md / summary.md        (encrypted mirrors)
│  ├─ meta.json / transcript.json
│  ├─ todos.json / source.txt / ocr.txt
│  ├─ source.png
│  └─ *_mic_tmp_*.caf / *_sys_tmp_*.wav
├─ WhisperModel/ / DiarizationModel/
├─ Voiceprints/ / Dictionary/
└─ url_diagnostic.txt
```

Reconciliation rebuilds missing index entries and fills missing mirrors without overwriting existing content. Confirm deletion, load dependent side data, remove disk before database, and retain records on disk errors. Encryption boundaries are detailed in [Security](08-Sync-and-Security.md).

## 5. Swift 6 concurrency

| Context | Approach |
|---|---|
| Observable UI services | MainActor observable shared references |
| Audio callbacks | No inherited MainActor; synchronized wrappers for non-Sendable audio files |
| Single-instance inference | Cancellable actor serial gates |
| Cross-actor state | Synchronized ModelBox, IDs/Sendable snapshots rather than SwiftData objects |
| C callbacks | Hop to MainActor for UI; synchronous AppKit callbacks use assumeOnMainThread |
| Cancellation | Check cancellation and forward it into inference/gates/callbacks |
| First key creation | Lock, double-check, memory cache |

Unsafe annotations require actual synchronization/lifetime guarantees. See [Development Guide](../../../DEVELOPMENT_GUIDE.md), §2.

## 6. Notification bus

| Notifications | Sender → receiver |
|---|---|
| screenshotHotkeyPressed / fullscreenScreenshotHotkeyPressed | GlobalHotkeyManager → RootView/ScreenshotManager |
| recordingHotkeyPressed | GlobalHotkeyManager → RootView.toggleMeetingRecording |
| menuBarStartRecording / menuBarStopRecording | MenuBarController → RootView/RecordingViewModel |
| menuBarStartScreenshot / menuBarStartDelayedScreenshot | MenuBarController → RootView/ScreenshotManager |
| screenshotCaptureSaved | ScreenshotManager → RootView/QuickNoteViewModel |
| screenshotPermissionNeeded / screenshotErrorOccurred | ScreenshotManager → RootView alerts |
| menuBarOpenSettings / openHelp / menuBarCreateQuickNoteFromClipboard | Menus → RootView |
| MemoziaShowMainWindowFromOtherInstance | Exiting duplicate → existing AppDelegate, distributed notification |

Definitions live in ScreenshotNotifications.swift and relevant services.

## 7. Architectural characteristics

Stateful service singletons simplify access but reduce testability; pure computation/audio callbacks retain separate isolation. Files plus a rebuildable index anchor reliability. Degradation paths—visible plaintext compatibility, transient database, single-track audio, unlabeled speakers—remain explicit rather than silently redefining success. macOS guards stay near relevant APIs. TaskCenter centralizes queueable foreground work while the persistent background queue owns cross-process continuation.
