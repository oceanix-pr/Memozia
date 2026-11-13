# 10 · ViewModels

[← Home](Home.md) · Source: [Memozia/ViewModels](../../../Memozia/ViewModels)

The three business ViewModels are `@MainActor @Observable final class` types. They use references to shared services.

| ViewModel | Responsibility |
|---|---|
| [RecordingViewModel](../../../Memozia/ViewModels/RecordingViewModel.swift) | Recording, transcription, summaries, and tasks; the main business coordinator |
| [QuickNoteViewModel](../../../Memozia/ViewModels/QuickNoteViewModel.swift) | Text/image/clipboard notes, OCR, summaries, tasks |
| [SettingsViewModel](../../../Memozia/ViewModels/SettingsViewModel.swift) | Settings persistence and LLM configuration management |

## 1. RecordingViewModel

### 1.1 Declaration and dependencies

```swift
@MainActor @Observable final class RecordingViewModel
```

- `whisperLocalService = WhisperLocalService.shared` provides local transcription.
- `meetingRecorder = MeetingRecorderService.shared` is exposed directly for view observation. A stored `let` reference preserves observable dependency tracking instead of relying on a forwarding computed property.
- Observable state includes transcription progress/stage, import progress text, the streaming `summaryText` buffer, error presentation, `isMergingAudio`, and `selectedRecording`.
- Audio/video import comes from the toolbar picker or main-window drop. The old iOS Share Extension inbox route is gone.

### 1.2 Transcription

| Entry | Responsibility |
|---|---|
| `startTranscription` | Set `.processing`, validate media, route to system recognition (`SystemTranscription`/`SystemTranscriptionService`, macOS 26+), local `WhisperLocalService`, or cloud `WhisperAPIService`, and publish progress |
| Post-processing | Optional diarization → Chinese script normalization → dictionary correction → encryption → `TranscriptSegment[]` → transcript mirror → `.completed`/`.failed`; see [Transcription](05-Transcription-and-Diarization.md), §9 |
| `cancelTranscription` | Forward cancellation into inference and the serial gate |
| `resetStaleProcessingStates` | Reset crash-left `.processing` to `.pending` across recording transcription/summary/visual/task status and note summary/task status |

The old batch transcription/summary entry points (`startBatchTranscription`, `startBatchSummary`, `cancelBatch*`) and their TaskGroup/semaphore scheduler have been removed. The list context menu uses one-click processing through [TaskCenter](02-Architecture.md), §3.4. Legacy helpers such as `calculateMaxConcurrency` and `shouldContinueBatchLoop` have no callers.

### 1.3 Summaries

```text
generateSummary(recording, llmConfig, …)
  1. Read decrypted, cached transcriptMarkdown
  2. For cloud requests with PII protection: scrub → mapping
  3. Stream LLM tokens into summaryText and render
     Clear prior partial output at onAttemptStart to avoid duplicate retries
  4. Restore identifiers with the mapping
  5. Preserve partial output on failure
  6. Encrypt recording.summary and persist summary.md
  7. Generate a title
```

The queue schedules an individual summary as a Job whose Step awaits the existing ViewModel task; there is no batch summary loop.

### 1.4 Tasks

```text
Summary → optional PII scrub → TodoExtractionService.extract
→ Restore TodoDocument → encrypted todos.json
→ User confirmation → RemindersService
```

### 1.5 Meeting recording

| Member | Responsibility |
|---|---|
| `meetingRecorder` | Directly observable service reference |
| `isMeetingRecording`, `recordingElapsed`, `isRecordingMuted`, `recordingMuteSource` | Forward service state into UI bindings |
| `startMeetingRecording(config:context:)` | Task-based startup with visible errors |
| `stopMeetingRecording(context:source:)` | Publish merging and phase state: segment checks → echo reduction → mix/export → save. Only echo reduction exposes `cancelEchoReduction()`. Stop capture, report degraded merge/system-audio stop, obtain duration, create `AudioRecording`, save with short backoff via `saveContextWithRetry`, write metadata, and select the result |

The save retry addresses transient file-descriptor exhaustion immediately after merging long recordings.

### 1.6 Data management

- **Import:** RootView drop handling and file picker, with extension and actual-media validation by `AudioImportValidator`.
- **Delete:** Confirm single/bulk deletion, load `TodoDocument` before removing its folder, clean associated Reminders, remove disk data before the database record, and preserve the record if file removal fails.
- **Edit:** Segment text, speaker names/voiceprint registration, and transcript cache invalidation.
- **Export:** Transcript/summary text documents through `ExportDocuments`; recording sharing through `NSSharingServicePicker` anchored to the main window. See [Views](11-Views.md) for Markdown/PDF export UI.

## 2. QuickNoteViewModel

### 2.1 Responsibility

Notes without recording: text, image, or clipboard input, with AI summaries and task extraction.

### 2.2 Main operations

| Operation | Behavior |
|---|---|
| Clipboard note | Read `NSPasteboard` text/image and create a note on macOS |
| `createQuickNoteFromClipboard` | Menu-bar shortcut to clipboard note creation |
| `createQuickNote(fromImage:)` | Main screenshot-to-note path called by RootView |
| AI summary | Vision-capable image configuration uses `generateSummaryFromImage`; otherwise OCR first. Text notes use text summarization. Both stream, encrypt, and generate a title |
| Task extraction | Prefer combined text/OCR content; extract from the image only if text is absent. Text requests support PII protection |
| Delete/rename | Use the same disk-before-database deletion protocol as recordings |

## 3. SettingsViewModel

### 3.1 Settings domains

| Group | Contents |
|---|---|
| STT | System/local/cloud mode as supported, model directory (default `~/Documents/Memozia/WhisperModel`), cloud URL/key, language |
| Diarization | Enable flag, model path (default `DiarizationModel`), voiceprint recognition |
| Dictionary | Correction and PII-protection switches |
| LLM | Multiple configurations and active selection |
| Recording | mic/systemAudio/mixed source and mute behavior |
| Capture | Screen-recording permission, default capture mode, recording source/quality |
| Shortcuts | Recording, screenshot, and direct full-screen capture; separate settings page, [System Integration](09-System-Integration.md), §2 |
| Experience | Standard-mode meeting scenario and independent Whisper path; preserve saved Pro settings |

### 3.2 Persistence

- Load ordinary settings from UserDefaults; read the Whisper API key from Keychain through KeychainAccess.
- Save edits immediately. API keys go to Keychain, never UserDefaults.
- `makeSTTConfig(experience:)` and `makeRecordingConfig(experience:)` resolve saved settings through `EffectiveSettingsResolver` without rewriting Pro configuration.
- `getActiveLLMConfig` falls back deterministically to the first remaining configuration if the saved ID is invalid. `setActiveLLMConfig` is the sole active-model mutation entry; settings and both detail-view pickers use it, persist the ID, and call `saveSettings`. Reopening an entry or restarting preserves one shared active selection.

## 4. View bindings

| View | ViewModel dependency |
|---|---|
| RootView | RecordingViewModel, QuickNoteViewModel, SettingsViewModel |
| RecordingListView | RecordingViewModel passed through RootView for deletion, rename, selection operations |
| RecordingDetailView | RecordingViewModel for transcription, summaries, tasks, visual understanding |
| TranscriptView | RecordingViewModel for edits, cache invalidation, voiceprint registration |
| SummaryView | RecordingViewModel for streaming summary, regeneration, tasks |
| VideoUnderstandingView | RecordingViewModel for streaming visual notes, cancellation, persistence; delegates analysis to VideoUnderstandingService |
| QuickNoteDetailView | QuickNoteViewModel |
| SettingsView | SettingsViewModel |
