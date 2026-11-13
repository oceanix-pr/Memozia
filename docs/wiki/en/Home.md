# Memozia Code Wiki

Architecture and module navigation organized by task. See [AGENTS.md](../../../AGENTS.md) for coding instructions and the [PRD](../../../PRD.md) for product behavior and acceptance criteria. Verify implementation details against source code, `project.yml`, and current validation results; these pages are reference material, not instructions to load every document for every task.

## Project overview

Memozia uses Swift 6, SwiftUI, and SwiftData. Its main pipeline is:

```text
Record / import audio or video
→ System speech recognition / local WhisperKit / cloud Whisper transcription
→ Speaker diarization / voiceprint recognition
→ Chinese script normalization / dictionary correction
→ Encrypted text storage → LLM summary → Editable tasks
→ User-confirmed export to Apple Reminders
```

- Queueable processing work—model downloads, transcription, visual analysis, summaries, title refinement, and task extraction—goes through the global [TaskCenter](02-Architecture.md). The queue panel supports inspection, pause where supported, and cancellation. One-click processing is available from the list context menu, recording playback bar, and note task actions. It first previews the steps to run or skip and the scope of cloud data, then runs transcription → visual analysis for video → summary → task extraction in order. Completed steps are skipped unless retranscription is explicitly selected.
- Text, image, clipboard notes, and confirmed screenshots share `QuickNote`; screenshots are not a separate persistent entity. Chinese-interface text notes can use macOS voices to synthesize speech and export WAV/M4A; see [Views](11-Views.md), §8.1.
- Video entries preserve the original video and extracted audio. The Visual tab combines playback, cached keyframes, and manually initiated visual analysis on the transcription timeline.
- macOS integration includes the menu bar, global capture shortcuts, microphone and meeting-app mute detection, and Dock visibility.
- Files are authoritative; SwiftData is an index. Encryption and cloud text de-identification have distinct boundaries; see [Sync and Security](08-Sync-and-Security.md).
- The app and its tests target macOS only. iOS support and the iOS Share Extension have been removed.

## Navigation

| Document | Use it for |
|---|---|
| [02 Architecture](02-Architecture.md) | Layers, data flow, startup, shutdown, background takeover, storage |
| [03 Data Models](03-Data-Models.md) | SwiftData entities, configuration, tasks, exports |
| [04 Audio Capture](04-Audio-Capture.md) | Microphone/system capture, segments, mixing, reference echo cancellation, mute detection |
| [05 Transcription and Diarization](05-Transcription-and-Diarization.md) | Engines, model catalog, cloud chunks, speakers, voiceprints, dictionary, caching |
| [06 AI Features](06-AI-Features.md) | SSE, summaries, video understanding, tasks, PII |
| [07 Screenshots and OCR](07-Screenshots-and-OCR.md) | Selection, annotation, pinning, image notes |
| [08 Sync and Security](08-Sync-and-Security.md) | Recovery, encryption, deletion, CloudKit boundaries |
| [09 System Integration](09-System-Integration.md) | Menu bar, shortcuts, windows, permissions, application updates |
| [10 ViewModels](10-ViewModels.md) | Business orchestration and state binding |
| [11 Views](11-Views.md) | Screens, interactions, UI components |
| [12 Dependencies](12-Dependencies.md) | SPM packages, system frameworks, dependency graph |
| [13 Build and Run](13-Build-and-Run.md) | Toolchain, commands, scripts, tests, debugging |
| [Development Guide](../../../DEVELOPMENT_GUIDE.md) | Audio, concurrency, storage, and permission practices |
| [Technical Debt](../../TECH_DEBT.md) | Open issues and regression scenarios relevant to the task |
| [Release Checklist](../../RELEASE_CHECKLIST.md) | Distribution and open-source preparation |

## Maintenance

Update the affected chapters only. Maintain each fact in one primary place and link to it elsewhere. Locate code by file and symbol, not fixed line numbers, source line counts, or app build snapshots. Separate implemented behavior from pending work. Update the corresponding PRD acceptance criteria when behavior changes; historical passing checks do not establish current correctness.

English source documents live in `en/`; generated Traditional Chinese documents live in `zh-Hant/`, preserving executable examples and paths. Run `python3 docs/wiki/publish_wiki.py --output <wiki-checkout> --refresh-traditional` to render GitHub Wiki pages. Refreshing Traditional Chinese requires `opencc-python-reimplemented`. The generator validates local references, Wiki links, and code fences and supplies language navigation; it never commits or pushes automatically. Review changes and commit the main documentation and Wiki repositories separately. A new GitHub Wiki needs its first page created on the website before cloning.
