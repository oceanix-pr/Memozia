# 12 · Dependencies

[← Home](Home.md)

## 1. Swift Package Manager

Package declarations live in [project.yml](../../../project.yml); retain the resolved lockfile when upgrading.

| Package | Constraint | Product and purpose | Notes |
|---|---|---|---|
| WhisperKit, argmaxinc/argmax-oss-swift | from 0.9.0 | WhisperKit; local CoreML transcription | Default model endpoint is `https://hf-mirror.com` |
| Sparkle | exact 2.10.0 | Update checks, signature verification, installation | macOS direct distribution; MIT plus bundled third-party notices. Measure size on actual Release output |
| KeychainAccess, kishikawakatsumi | from 4.2.2 | API/AES key storage | `.accessibility(.afterFirstUnlock)` |
| SherpaOnnx, k2-fsa/sherpa-onnx | Pinned revision in project.yml | `sherpa-onnx-shared`; CPU pyannote segmentation and 3D-Speaker embeddings | The static onnxruntime archive is not a standard embeddable framework. Use the shared product and explicitly regression-test diarization when changing the revision |

`.packages/` is a local package cache, not project source.

### SherpaOnnx build repair

The pre-build [fix_onnxruntime_framework.sh](../../../Scripts/fix_onnxruntime_framework.sh) repairs upstream framework layout (real directories where symlinks are required) and dynamic-library references. Without this, strict signing or launch can fail. The post-build verifier is mandatory; see [Build and Run](13-Build-and-Run.md).

## 2. System frameworks

| Framework | Usage |
|---|---|
| SwiftUI / SwiftData | UI and persistence |
| AVFoundation | AVAudioEngine/AVAudioFile capture, AVAssetWriter, composition/export, duration inspection |
| ScreenCaptureKit | System audio through SCStream; capture/freeze through SCScreenshotManager and SCShareableContent |
| Vision | VNRecognizeTextRequest OCR |
| Speech | SpeechAnalyzer/SpeechTranscriber, macOS 26+, system-managed language assets |
| CryptoKit | AES-GCM |
| AppKit | Status item, screenshot panels/views, windows, NSSharingServicePicker |
| Carbon / HIToolbox | RegisterEventHotKey global shortcuts |
| CoreAudio | Microphone mute-property observation |
| ApplicationServices | AXUIElement meeting-app mute detection |
| EventKit | EKReminder creation |
| Metal | `recommendedMaxWorkingSetSize` in unused legacy batch-concurrency helper |
| os.log | Logger, subsystem based on bundle ID |

## 3. Module dependencies

### 3.1 Services

```text
RecordingViewModel
  ├─ WhisperLocalService → WhisperKit
  ├─ SystemTranscription → SystemTranscriptionService → Speech
  ├─ WhisperAPIService → KeychainAccess
  ├─ MeetingRecorderService
  │    ├─ MicCaptureService
  │    ├─ SystemAudioCaptureService
  │    ├─ AppMuteDetector / MicMuteMonitor
  │    └─ AudioConverter
  ├─ SpeakerDiarizationService → SherpaOnnx + VoiceprintStore
  ├─ ChineseConverterService / TranscriptDictionaryService / TranscriptCache
  ├─ LLMService / PIIScrubService / TodoExtractionService / RemindersService
  └─ EncryptionService / FileSyncService

QuickNoteViewModel
  ├─ VisionOCRService
  ├─ LLMService (image/text summaries and titles)
  ├─ TodoExtractionService / PIIScrubService
  └─ EncryptionService / RemindersService

SettingsViewModel → KeychainAccess / SpeakerDiarizationService
ScreenshotManager → RegionSelectionController
                    ├─ OverlayAnnotationView
                    └─ PinnedWindowSession
                  → ScreenCaptureKit

RootView → ViewModels / TaskCenter / MenuBarController
         / GlobalHotkeyManager / ScreenshotManager
SettingsView + SettingsViewModel → TaskCenter.whisperDownloadJob
TaskCenter → WhisperModelDownloader + existing ViewModel operations
PIIScanService → local-model LLMService
AppUpdateService → Sparkle + UpdateInstallationCoordinator
```

TaskCenter only schedules; Steps use existing ViewModel methods and forward cancellation to their existing cancel entry points. The resumable Whisper download step is distinct from ordinary processing work.

### 3.2 Data

```text
AudioRecording --cascade--> TranscriptSegment[]
AudioRecording / QuickNote --folderName--> authoritative disk folder
AudioRecording / QuickNote --ProcessingStatus--> queue UI after restart
FileSyncService --> AudioRecording + QuickNote index reconstruction
TodoDocument (todos.json) --> RemindersService identifier cleanup
Encrypted fields --> EncryptionService --> Keychain
```

### 3.3 Notifications

GlobalHotkeyManager, MenuBarController, and ScreenshotManager publish through NotificationCenter to RootView; services do not depend on UI. See [Architecture](02-Architecture.md), §6.

## 4. Targets

```text
MemoziaTests   → Memozia (test host)
MemoziaUITests → Memozia (application under test)
```

All targets are macOS-only. The iOS Share Extension and App Group inbox handoff were removed.

## 5. External resources

| Resource | Location and boundary |
|---|---|
| Whisper models | User-selected path, default from `WhisperModelFolder`; complete CoreML/tokenizer files required. Download catalog models into `<model-folder>/<tier>`; none are bundled |
| Diarization models | `~/Documents/Memozia/DiarizationModel`, segmentation.onnx and embedding.onnx. Download from GitHub Releases without an HF token; preserve `.resume` data for resumption |
| Voiceprints | `~/Documents/Memozia/Voiceprints`, JSON tied to embedding `modelId` |
| Chinese dictionaries | Bundle Resources/ChineseDictionary |
| Hugging Face endpoints | hf-mirror.com by default or huggingface.co. Apply selected source to `HF_ENDPOINT` and explicitly to WhisperKit downloads |
