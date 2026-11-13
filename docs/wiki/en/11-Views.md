# 11 · Views

[← Home](Home.md) · Source: [Memozia/Views](../../../Memozia/Views)

The SwiftUI interface uses a two-column `NavigationSplitView`, observable ViewModels, and SwiftData `@Query`.

## 1. View inventory

| View | Responsibility |
|---|---|
| [RootView](../../../Memozia/Views/RootView.swift) | Layout, notifications, import, dialogs, lifecycle orchestration |
| [RecordingListView](../../../Memozia/Views/RecordingListView.swift) | Combined recording/note sidebar and media import; capture toolbar entry in Pro |
| [RecordingDetailView](../../../Memozia/Views/RecordingDetailView.swift) | Player, Transcript/Visual/Summary tabs, shared model selector |
| [TranscriptView](../../../Memozia/Views/TranscriptView.swift) | Transcript display, editing, search |
| [SummaryView](../../../Memozia/Views/SummaryView.swift) | Meeting/overview summaries, streaming, tasks |
| [VideoUnderstandingView](../../../Memozia/Views/VideoUnderstandingView.swift) | Video playback, visual analysis, keyframe timeline |
| [QuickNoteDetailView](../../../Memozia/Views/QuickNoteDetailView.swift) | Note detail |
| [SettingsView](../../../Memozia/Views/SettingsView.swift) | Settings, privacy policy, consent management |
| [MarkdownView](../../../Memozia/Views/MarkdownView.swift) | Block-level Markdown renderer |
| [TextFindReplace](../../../Memozia/Views/TextFindReplace.swift) | Find/replace component |
| [HelpView](../../../Memozia/Views/HelpView.swift) | Built-in documentation |
| [OnboardingView](../../../Memozia/Views/OnboardingView.swift) | Experience-specific feature introduction; models prepared at use time |
| [PrivacyConsentView](../../../Memozia/Views/PrivacyConsentView.swift) | Policy consent and separate voiceprint consent |
| [PrivacyPolicyDetailView](../../../Memozia/Views/Settings/PrivacyPolicyDetailView.swift) | Full policy, voiceprint consent, general consent withdrawal |
| [QueuePanelView](../../../Memozia/Views/QueuePanelView.swift) | `QueueToolbarButton` and running/queued/recently failed work |
| [OneClickPreviewView](../../../Memozia/Views/OneClickPreviewView.swift) | `OneClickPlan`, run/skip preview, retranscription choice, cloud data scope |
| [OverlayAnnotationView](../../../Memozia/Views/Screenshot/OverlayAnnotationView.swift) | Screenshot annotation canvas |
| [ScreenshotOverlayController](../../../Memozia/Views/Screenshot/ScreenshotOverlayController.swift) | Capture session controller; see [Screenshots](07-Screenshots-and-OCR.md) |

## 2. RootView

### 2.1 Structure

Layered computed properties keep type checking manageable:

```text
body = dialogLayers
  .overlay(progressOverlay)
  .contextMenu(forSelectionType: ListItem.self)
  .modifier(ExportModifiers)
  .modifier(LifecycleTasksModifier)
```

`observerLayers` owns the split view, notification listeners, and first appearance; `sheetAndAlertLayers` adds privacy/onboarding/settings/help and errors; the final dialog layer handles confirmation, export, and sharing. Progress overlays cover capture/import. `ExportModifiers` provides Markdown/PDF and recording sharing. Startup lifecycle work is serial.

### 2.2 Main mechanisms

- **Notifications:** Recording controls/shortcut, screenshot controls, saved images, permission/errors, settings, help, clipboard notes; see [Architecture](02-Architecture.md), §6.
- **First launch:** `MemoziaPrivacyPolicy.needsConsent(...)` checks the consent flag and policy major version. Then `hasCompletedOnboarding` controls onboarding; an app-major-version change tracked by `onboardingCompletedVersion`/`currentAppVersion` introduces new features again.
- **Sidebar:** Import audio/video, create note, capture in Pro, delete, rename, reconcile disk, start/stop recording, and validate dropped files.
- **Detail routing:** Selected recording/note determines the detail view and its transcription/cancellation/model/reminder dependencies.
- **Queue:** The persistent upper-right toolbar entry changes icon for failures/activity and opens `QueuePanelView`. Root extensions construct Jobs/Steps for transcription, summaries, titles, visuals, tasks, and one-click work. Steps await existing ViewModel operations, update persistent `ProcessingStatus`, and report stable `TaskErrorCode` values.
- **One-click processing:** List context menu, right side of recording playback, and beside note task extraction all call `presentOneClickPreview(_:)`, then `enqueueOneClick(_:plan:)`. The order is transcription → visuals for video → summary → tasks. Already completed transcription is skipped unless explicitly reselected; manually edited text is backed up before replacement. Notes use summary → tasks. Recordings default to meeting summaries; notes use overview summaries. Tasks are saved locally and are not automatically sent to Reminders. A banner opens the queue through `openTaskQueuePanel`.
- **Selection:** `ListItem.recording(AudioRecording)` / `.quickNote(QuickNote)` supports Pro multi-selection for deletion/export.
- **Export:** Separate Markdown/PDF choices for transcripts and summaries, plus copying text and original audio export. `MarkdownPDFRenderer` lays out off the main thread before showing `fileExporter`, so errors appear before choosing a destination.

## 3. RecordingListView

| Feature | Behavior |
|---|---|
| Layout | `.listStyle(.sidebar)`, custom search above the list, toolbar, multi-selection binding |
| Search | Replaces system `.searchable`, which otherwise crowds macOS window toolbar actions. macOS 26+ uses `glassEffect(.regular.interactive())`; older systems use rounded `.quaternary` fill. ⌘F focuses; Escape first clears then unfocuses. Preserve filtering, 300 ms debounce, and `.id("filter-…")` rebuilding |
| Window title | Memozia · 闻墨集 |
| Groups | Month sections with `expandedBinding` |
| Rows | `deletableRenamableRow`, inline rename, swipe delete, transcription status badges |

## 4. RecordingDetailView

The toolbar, AVAudioPlayer wrapper, seek controls, and Transcript/Summary tabs form the recording view. Pro video entries also expose the Visual tab, governed by `availableTabs(experience:hasVideoAttachment:)`. A shared `LLMModelSelectorBar` below the tabs appears for Summary/Visual, not transcription. It replaces duplicate selectors and persists the global active model. One-click processing sits at the right of the playback bar and requires preview confirmation.

After saving capture, RootView shows a non-modal information/warning banner for eight seconds. View Details selects the entry and expands `captureReportSection`. The detail page reads `capture_report.json` to show track interruption ranges, recovery state, and mute evidence; read failure is visible rather than treated as a clean capture. Unresolved live issues retain a banner and device-check action. Actual save failures retain an error dialog and Finder action.

## 5. TranscriptView

| Feature | Behavior |
|---|---|
| Display/edit | Toggle Markdown and TextEditor; increment `transcriptVersion` after saving to rebuild cache |
| Rendering | Segment count, matching-text highlighting, MarkdownView |
| Actions | Edit, TextFindReplace, search, copy, speaker/voiceprint registration, save draft |

## 6. SummaryView

The body combines streaming output, editing, task list, and sheets; model selection is shared by the parent. `StreamingMarkdownView` batches at most every 200 ms, parses in the background, cancels parsing when leaving, and switches to final rendering on completion. Explicit Meeting Summary/Overview Summary buttons become regeneration buttons when content exists and are disabled while running. Other actions copy, edit, extract tasks, review the task sheet, and confirm writing to Reminders.

## 7. VideoUnderstandingView

The Visual page embeds video playback, starts visual analysis manually, labels image-understanding versus local-OCR paths, and presents horizontally cached keyframes. Clicking a frame seeks precisely. Entering the tab pauses the top audio player to avoid simultaneous playback.

## 8. QuickNoteDetailView

Image preview or text editing, streaming summary, tasks, rename, and deletion mirror the recording-detail structure for `QuickNote`. One-click processing beside task extraction previews overview summary → tasks before enqueueing. The model picker calls `SettingsViewModel.setActiveLLMConfig`; it shares persistent global selection with settings and recording detail.

### 8.1 Text-to-speech

Text notes expose speech synthesis only when the explicit app language is Simplified/Traditional Chinese, or when following the system and its first preferred language is Chinese. Switching away closes the panel and cancels synthesis. `NoteSpeechAvailability` prioritizes explicit app selection; system-following reads global `AppleLanguages`, avoiding app override/cache effects and not enabling the feature merely because Chinese is a secondary preference. Opening is disabled while editing body/summary.

`NoteSpeechView`/`NoteSpeechViewModel` use an opening-time snapshot. Controls include voice language/region, gender only when actually supplied, speech rate, an initial preview, playback, and full export. Unknown gender displays the voice name only. Missing voices lead to system download instructions and refresh. Closing cancels work and removes temporary audio; it creates no recording and enters no background queue.

`SpeechTextPreparer` shares `TranscriptMarkdownBuilder`: retain text order, headings, link labels, lists, quotes, and tables; skip code/images; split long input preferentially at sentence endings. `NativeSpeechService` serially calls `AVSpeechSynthesizer.write`. A lock-protected `SpeechAudioSink` writes WAV without inheriting MainActor in callbacks. Cancellation seals output and resumes waiters; a 30-second no-callback watchdog handles hangs; chunk tokens reject late output. `SpeechAudioEncoder` streams M4A encoding on a separate actor. MP3 is offered only if the system supports it; no third-party encoder is bundled. AAC bitrate matches the voice sample rate through the system encoder.

Temporary audio lives in a user-private directory outside entry scans and recording recovery. Export stages beside the destination and atomically replaces it; cancellation/failure preserves existing files. UI strings cover all `knownRegions` in `Localizable.xcstrings`. See `NoteSpeechTests.swift` for regressions.

## 9. SettingsView

### 9.1 Layout and search

A searchable sidebar routes to grouped forms. Search covers settings and commands, with names and current shortcuts from `AppCommandCatalog`, shared with menus/help. Results with `settingsDestination` navigate there; commands without one, such as a new note, are informational.

`AppExperienceStore` selects information density. Standard mode offers transcription readiness, intelligent-service connection, meeting scenario, shortcuts, data status, and About. Pro exposes all engines, models, capture, tasks, dictionary, voiceprints, and storage controls. The experience switch lives in About; a now-hidden selected page resets to the first visible group.

### 9.2 Groups

| Group | Contents |
|---|---|
| stt | Engine, model download/folder selection, cloud API, language. Whisper downloads use `TaskCenter.whisperDownloadJob` and queue pause/resume |
| llm | CRUD for name/baseURL/model/apiKey/isLocal/supportsVision and connection tests |
| recording | Source, input device, start-muted preference, disk space, mute notices |
| screenshot | Screen permission, capture mode, recording preferences |
| hotkeys | Recording/screenshot/full-screen shortcut recording, failures, default-recording conflict fallback; Standard hides the full-screen row |
| todo | Default Reminders list and advance notification |
| dictionary | Create/edit/delete, synchronize from voiceprints, update de-identification |
| voiceprints | Inspect/delete voiceprints |
| data | Storage location and disk reconciliation; iCloud is disabled with no sync-state entry |
| about | Version, privacy consent and licenses; update controls appear only after a feed is configured |

### 9.3 Progressive disclosure

Standard mode maps online/in-person meetings to capture sources and hides track/device/mute policies. Summaries have one automatic action; model/template choice, advanced editing, and task structure remain Pro features. Existing visual notes remain readable in Standard, while new analysis, reanalysis, and original-video cleanup are unavailable. Standard uses single selection and hides bulk/hide/title-refinement actions; Pro restores them.

## 10. MarkdownView

UI and PDF share `TranscriptMarkdownBuilder.parseBlocks`/`TranscriptBlock`. Supported blocks include H1–H6 and Setext headings, soft/hard breaks, nested/task lists, backtick/tilde fences, nested quotes, rules, and pipe tables. A table requires a matching separator row; outer pipes are optional. Preserve empty cells, escaped pipes, and alignment; pad short rows and ignore cells beyond the header width.

Native Grid tables wrap long cells and scroll wide tables horizontally. Headings, paragraphs, lists, and cells share `AttributedString(markdown:options:.inlineOnlyPreservingWhitespace)`; code remains literal. Search highlighting also covers headings/code/cells. `TranscriptCache` supplies background-parsed transcript blocks; other static text uses a multi-document LRU cache bounded by count and bytes.

Streaming summaries batch parse off the main thread instead of reparsing all text per token. PDF draws cells/borders, repeats ordinary headers across pages, and continues oversized cells on later pages. A header requiring pagination is not repeated. CoreText handles PDF inline style; strikethrough removes markup only. Complete CommonMark/GFM, HTML, equations, and images are not promised. See `MarkdownPDFRendererTests.swift`.

## 11. Help, onboarding, and consent

- **HelpView:** Recording/start-muted/capture reports, import, notes, speech, transcription, voiceprints, summaries, tasks, capture, background/menu-bar use, management, privacy, shortcuts. The shortcut section comes from `AppCommandCatalog.shortcutReferenceIDs`.
- **OnboardingView:** Reappears for major upgrades, with a concise Standard flow and fuller Pro introduction. It no longer downloads models. System recognition prepares language assets on demand; `SpeakerDiarizationService.ensureModelsReady` downloads diarization models on first use and visibly degrades without diarization on failure.
- **PrivacyConsentView:** First-launch consent covering collection, permissions, transmission, local storage, screen sharing, user rights, and third-party boundaries. `interactiveDismissDisabled` requires an explicit choice.

## 12. Removed iOS Share Extension

The old `MemoziaShareExtension/ShareExtensionView.swift` and iOS export `ShareSheet` were removed with iOS support. Do not add iOS view or extension branches.
