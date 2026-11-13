# 03 · Data Models

[← Home](Home.md) · Source: [Memozia/Models](../../../Memozia/Models)

The data layer has three roles: SwiftData `@Model` entities (`AudioRecording`, `TranscriptSegment`, `LLMConfig`, `QuickNote`), value configurations (`STTConfig`, `RecordingConfig`), and file-level structures (`RecordingCaptureReport`, `TodoItem`, `TodoDocument`, exports). Screenshots are image QuickNotes. `capture_report.json` describes capture integrity and observation intervals without meeting content.

Keep computed properties in extensions of `@Model` types to avoid macro conflicts.

## 1. AudioRecording

Source: [AudioRecording.swift](../../../Memozia/Models/AudioRecording.swift).

### 1.1 Processing state

```swift
enum TranscriptionStatus: String, Codable {
    case pending, processing, completed, failed
}
enum ProcessingStatus: String, Codable {
    case pending, processing, completed, failed
}
```

ProcessingStatus persists summary, visual, and task state instead of losing it with ViewModel memory. At startup, `resetStaleProcessingStates` resets crash-left `.processing` to `.pending` for recording transcription/summary/visual/tasks and note summary/tasks. This supports queue-status restoration without persisting TaskCenter itself.

### 1.2 Persistent fields

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Primary key |
| `fileName` | String | Display name |
| `fileExtension` | String | Media extension |
| `duration` | TimeInterval | Seconds |
| `storedFileName` | String | Stored filename with collision-safe naming |
| `folderName` | String | `yyyyMMddHHmmss[-N]` entry directory |
| `videoFileName` | String? | Retained `{base}_video.{ext}` original, nil for audio or after video cleanup; reconstructed from naming conventions |
| `hasVideoSource` | Bool | Persistent video identity independent of the original filename. Cleanup clears the filename but preserves the flag so icons/type do not revert to audio. Saved in meta.json and repaired from disk evidence for old entries |
| `createdAt` | Date | Creation time |
| `recordingSource` | RecordingSource | Capture source |
| `transcriptionStatus` | TranscriptionStatus | Transcription state |
| `summaryStatus`, `visualStatus`, `todoStatus` | ProcessingStatus | Persistent processing state |
| `summary` | String? | Encrypted LLM summary |
| `visualSummary` | String? | Encrypted timeline visual notes, mirrored to visual.md |
| `visualSummaryGeneratedAt` | Date? | Visual analysis time |
| `segments` | [TranscriptSegment] | Related transcript segments |

### 1.3 Relationships

```swift
@Relationship(deleteRule: .cascade, inverse: \TranscriptSegment.recording)
var segments: [TranscriptSegment]
```

Deleting the recording cascades to its transcript segments.

### 1.4 Extension members

| Member | Contract |
|---|---|
| `storageDirectory` / `defaultStorageDirectory` | UserDefaults-backed location; default `~/Documents/Memozia/`, with get/set/reset |
| `createUniqueFolder(from:)` | Month-first storage and legacy flat lookup; allocate with atomic mkdir, retry `-N`, return nil and report failure when creation fails |
| `fullTranscript` | Concatenate decrypted plain text |
| `transcriptMarkdown` | Timestamped/speaker-labeled Markdown |
| `decryptedSummary` | Decrypt summary |
| `formattedDuration` | Duration formatting |
| `saveMetaToFolder()` | Persist title, hidden state, hasVideoSource in meta.json |
| `mediaKind` | Sole recording/video icon/type decision, derived from hasVideoSource and preserved after original cleanup |
| `folderIndicatesVideoSource(folderURL:files:)` / `folderHasVisualArtifacts(folderURL:)` | Shared disk evidence for indexing and old-entry repair |

## 2. TranscriptSegment

Source: [TranscriptSegment.swift](../../../Memozia/Models/TranscriptSegment.swift).

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Primary key |
| `startTime`, `endTime` | TimeInterval | Time range |
| `speaker` | String? | Speaker label or registered voiceprint name |
| `text` | String | Encrypted text |
| `recording` | AudioRecording? | Inverse relationship |

`formattedTimeRange` displays tenth-second precision, for example `1:01:23.4 - 1:02:45.6`; `decryptedText` is the display read path.

## 3. LLMConfig

Source: [LLMConfig.swift](../../../Memozia/Models/LLMConfig.swift).

### 3.1 SwiftData fields

| Field | Type | Meaning |
|---|---|---|
| `id` | UUID | Primary key and Keychain lookup identity |
| `name` | String | Display label |
| `baseURL` | String | Service endpoint |
| `modelName` | String | Model identifier |
| `isLocal` | Bool | Explicit local-service selection, affecting PII handling and URL policy |
| `supportsVision` | Bool | Image-input capability, false by default |

### 3.2 Helpers in extensions

`chatCompletionsURL` safely constructs `/v1/chat/completions`. Computed `apiKey`/`setAPIKey(_:)` use `LLMKeychainStore`, service `app.memozia.llm-apikeys`, configuration UUID keys, `.afterFirstUnlock`, and deletion for empty values. Secrets are not SwiftData fields.

Templates include LM Studio (`http://localhost:1234`), Ollama (`http://localhost:11434`), OpenAI (`gpt-4o`, vision enabled), and custom services.

### 3.3 Import/export

| Member | Contract |
|---|---|
| `LLMConfigTransferFile` | Codable/Sendable payload with version, ISO8601 exportedAt, and optional configs[].apiKey for legacy compatibility |
| `transferPayload(from:)` | Plaintext in-memory payload including API keys; encrypt before any file write |
| `decodeTransfer(_:existing:)` | Validate required fields and endpoints using the same `LLMService.validateSecureURL(_:isLocalModel:)` policy as requests; deduplicate lowercased baseURL without trailing slash plus modelName; at most 200 per import |
| `EncryptionService` | Same device Keychain key used for local text; encrypted exports can only be imported on that Mac |
| `LLMConfigExportDocument` | FileDocument carrying encrypted bytes only; expose encryption/layout failures before completing the save interaction |

Settings → LLM → configuration transfer exports without asking for a password. Import decrypts or accepts legacy plaintext exports, creates new UUIDs, stores API keys under those IDs, and activates the first imported config only when no active configuration exists. Another Mac cannot decrypt the export: explain this explicitly. See [Sync and Security](08-Sync-and-Security.md), §3.5. Runtime LLM requests cross actors using `LLMConfigSnapshot`, not the SwiftData object; see [LLMService.swift](../../../Memozia/Services/LLMService.swift).

## 4. QuickNote

Source: [QuickNote.swift](../../../Memozia/Models/QuickNote.swift).

Notes reuse the timestamp/collision-safe folder convention with `itemType: "quicknote"`.

| Field | Meaning |
|---|---|
| `id`, `title`, `createdAt` | Metadata |
| Text content | Encrypted, source.txt mirror |
| Image filename | source.png |
| `ocrText` | Encrypted OCR |
| AI summary | Encrypted, summary.md mirror |
| `summaryStatus`, `todoStatus` | Persistent ProcessingStatus |
| `folderName` | Entry directory |

`combinedTextForExtraction` combines note text and OCR for tasks. `saveMetaToFolder()` writes the quicknote item type.

## 5. STTConfig

Source: [STTConfig.swift](../../../Memozia/Models/STTConfig.swift).

- `STTMode` retains system/local/cloud values. System recognition is available on macOS 26+; `defaultMode` chooses it when supported, otherwise local WhisperKit.
- `selectableCases` no longer offers cloud Whisper as a new choice. `pickerModes(current:)` preserves a saved hidden mode, and legacy cloud configuration/execution remains compatible.
- `WhisperModelFolder` supplies the model location; fixed-size WhisperModelSize is no longer used.
- `WhisperLanguage` lists language choices. `whisperLanguageCode` maps internal `zh-Yue` to engine `yue`.
- Configuration includes mode, modelPath, apiKey, baseURL, language, diarization/voiceprint/dictionary switches, and diarizationModelPath, assembled by SettingsViewModel.

## 6. RecordingConfig

Source: [RecordingConfig.swift](../../../Memozia/Models/RecordingConfig.swift).

```swift
enum RecordingSource: String {
    case microphone
    case systemAudio
    case mixed
}
```

RecordingConfig contains source/mute options, persists in UserDefaults, and is assembled by `SettingsViewModel.makeRecordingConfig()`; source display labels/icons belong to the model.

## 7. TodoItem and TodoDocument

Source: [TodoItem.swift](../../../Memozia/Models/TodoItem.swift).

```swift
enum TodoPriority: Int { case none, low, normal, high }
enum TodoStatus: String { case pending, written, failed }
```

TodoItem contains `id/title/notes?/url?/dueDate?/alarmOffsetMinutes?/priority/reminderIdentifier?/status/targetListID?`. Its default UUID-string ID is stable for deduplication; a nil targetListID follows the default list. TodoStatus describes the Reminders write result.

TodoDocument encrypts `todos.json` in the entry folder and provides save/read/delete. Writing to Reminders fills reminderIdentifier/status for later cleanup. Load this data before removing an entry folder.

## 8. Export documents

[ExportDocuments.swift](../../../Memozia/Models/ExportDocuments.swift) contains PlainTextDocument (.txt), MarkdownDocument (.md), and MarkdownPDFDocument (.pdf). PDF documents carry already-laid-out bytes. `MarkdownPDFRenderer` uses CoreText pagination without AppKit/UIKit types, running before the save panel to avoid blocking UI and expose failures early. PDF import is not provided; `init(configuration:)` rejects it.

## 9. Duration formatting

[TimeInterval+Formatting.swift](../../../Memozia/Models/TimeInterval+Formatting.swift) supplies `mm:ss` / `HH:mm:ss` formatting for players and lists.

## 10. Persistence overview

| Data | Storage | Protection |
|---|---|---|
| Recordings, segments, configs, notes | SwiftData default.store | AES-GCM for sensitive fields |
| Transcript, summary, OCR, tasks | Entry files | Existing encrypted writes and compatible reads; see Security |
| Whisper/LLM API keys | Keychain, afterFirstUnlock | System protection |
| Encryption key | Keychain | System protection |
| Non-sensitive settings | UserDefaults | No app encryption |
| Voiceprints | `~/Documents/Memozia/Voiceprints/<uuid>.json` | Unencrypted vectors |
| Dictionary | `~/Documents/Memozia/Dictionary/*.md` | Unencrypted |
