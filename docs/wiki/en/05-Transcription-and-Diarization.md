# 05 · Transcription and Speaker Diarization

[← Home](Home.md) · Source: Memozia/Services

```text
Audio → system speech / local WhisperKit / legacy cloud Whisper
→ Timestamped TranscriptionResult
→ Optional SpeakerDiarizationService → optional VoiceprintStore identity
→ ChineseConverterService → TranscriptDictionaryService
→ Encryption / persistence → TranscriptCache for display
```

## 1. WhisperLocalService

Source: [WhisperLocalService.swift](../../../Memozia/Services/WhisperLocalService.swift), MainActor observable singleton.

### 1.1 Models

`loadModel` resolves the user's modelFolder/nested folder, constructs WhisperKitConfig with colocated model/tokenizer folders, loads WhisperKit, and reports progress. Unload asynchronously or through `unloadModelBlocking()` on exit/when idle. Synchronized modelBox owns the instance; unload atomically takes ownership, and inference reads only after acquiring the cancellable actor gate. Never invoke one WhisperKit instance concurrently.

### 1.2 Execution

```swift
func transcribe(audioPath: URL, decodeOptions: DecodingOptions,
                callback: ((TranscriptionProgress) -> Bool?)?) async throws -> TranscriptionResult
```

Use transcribe task, configured language, and temperature 0. An explicit cancellation flag returning false controls callback cancellation; callback Task cancellation alone is insufficient. Results carry text, time ranges, and later speaker labels.

### 1.3 Configuration

modelFolder and tokenizerFolder point to the same validated user directory. Do not assume bundled models or an implicit full-model download during construction. The default comes from WhisperModelFolder.defaultPath.

## 2. WhisperAPIService

Source: [WhisperAPIService.swift](../../../Memozia/Services/WhisperAPIService.swift).

Validate HTTPS or the existing loopback HTTP exception. POST multipart audio to `/audio/transcriptions` with whisper-1 and verbose_json; parse timestamped segments. Files above 25 MB are split, uploaded sequentially, and combined using offsets. Read API keys through KeychainAccess, never UserDefaults. Cloud execution remains for saved legacy configurations, although it is no longer offered as a new engine choice.

## 3. SpeakerDiarizationService

Source: [SpeakerDiarizationService.swift](../../../Memozia/Services/SpeakerDiarizationService.swift).

### 3.1 Implementation

sherpa-onnx runs CPU-only offline diarization with automatically estimated speaker count: pyannote segmentation 3.0, 3D-Speaker eres2net embeddings, and fast clustering. Window duration comes from model metadata (five seconds for this segmentation model); shift equals windowShiftRatio × window duration. Precision controls ratio from 0.10 to 0.40, default 0.25.

DiarizationThreads.resolved shares the configured thread count across models; Pro can select within supported logical-core limits. Historical default is cores minus two capped at six. No thermal/QoS backoff is implemented here; control cost through precision, thread count, and capped refinement sampling. Models live in DiarizationModel, can be supplied manually or downloaded from GitHub Releases without an HF token, and are prepared on first use. Download and inference each have serial gates.

### 3.2 Main flow

`diarizeWithSamples` configures sherpa, runs segmentation/embeddings/clustering, then refineClusters. Fill transcript speakers by maximum temporal overlap and optionally replace generic labels with voiceprint names.

### 3.3 Three-stage cluster refinement

Fast clustering can split one speaker into many clusters. Iteratively merge high-similarity centroids above 0.60, gather fragment clusters shorter than max(3 seconds, 5% of total duration) using 0.50, then attach remaining fragments to their closest large cluster. Reindex by descending speaking duration so Speaker 1 is the longest speaker, and expose reusable centroids.

The wrapper does not expose its original embeddings, requiring a second extraction pass. `embeddingSegmentsBySpeaker` limits that pass to the longest 30 segments per speaker of at least 1.5 seconds. Refinement, segmented global centroids, and registration must share selection, duration-weighted averaging, and L2 normalization. See [DiarizationSegmentationTests.swift](../../../MemoziaTests/DiarizationSegmentationTests.swift) and [VoiceprintMergeTests.swift](../../../MemoziaTests/VoiceprintMergeTests.swift).

### 3.3.1 Long recordings

DiarizationSegmentationPlanner handles duration/memory estimates, overlapping chunks, overlap deduplication, cross-chunk identity, and duration-based indexing. The default whole-recording limit is 30 minutes. Segmented inference uses eight-minute chunks with 30-second overlaps and frees samples after each chunk.

globalSpeakerMapping aligns local identities in order at similarity ≥0.55; empty centroids receive distinct identities. mergeOverlapping favors earlier labels. Do not average local centroids equally: short noisy speech would carry the same weight as long stable speech and results would depend on chunk order. Instead, re-extract global speakers from the longest 30 final intervals with duration weighting; weightedCentroid reads one interval at a time rather than loading the full recording.

### 3.3.2 Precision tiers

Pro exposes DiarizationPrecision under transcription/diarization, persisted as diarization_precision. Missing/invalid values resolve to the middle tier.

| Tier | Whole duration | Decoded-memory limit | Chunk | Overlap | Shift ratio |
|---|---|---|---|---|---|
| 1 Fastest | 10 min | 96 MB | 5 min | 15 s | 0.400 |
| 2 Faster | 20 min | 160 MB | 6 min | 20 s | 0.325 |
| 3 Standard | 30 min | 256 MB | 8 min | 30 s | 0.250 |
| 4 Detailed | 30 min | 256 MB | 15 min | 45 s | 0.175 |
| 5 Most detailed | 30 min | 256 MB | 20 min | 60 s | 0.100 |

The middle tier preserves historical behavior. All whole-recording limits stay at or below 30 minutes: ONNX intermediate tensors depend on process() duration, not only the decoded sample-array budget. A historical 143-minute, four-thread comparison showed 12-minute chunks at 1.68 GB/12m30s, 20-minute chunks at 2.60 GB/18m13s, and whole-file processing at 8.3 GB before termination without completion. These measurements explain the design rather than guarantee performance. Higher precision uses longer chunks/denser windows, not unbounded whole-file inference.

Keep the 30-segment cap and calibrated 0.60/0.50/0.55 thresholds independent of tier: registration and recognition must remain compatible. Resolve precision once per inference and pass it down consistently; changing it affects future retranscription only. DiarizationCalibrator uses the same tier.

### 3.4 Degradation

Model/preparation/diarization failure does not prevent text transcription. Refinement failure retains raw clustering. Warnings and skipped analysis explain the result; do not treat unlabeled text as proof that diarization succeeded. Zero-result analysis also logs a warning.

### 3.5 Audio loading

loadMonoSamples serves diarization and voiceprints through AVAudioFile plus AVAudioConverter to 16 kHz mono Float32. Whole and timeRange entry points share chunked reading (sourceChunkFrames 48000); selected interval reads avoid multi-gigabyte full-source buffers.

Drive EOF by file.length/frame budget. On affected macOS SDK/runtime combinations, AVAudioFile can throw eofErr (-39) instead of returning zero frames; isEndOfFileRead treats only that exact code as normal completion. Other decode/permission errors propagate. Fixing memory without EOF handling would still discard fully read audio during fallback. DiarizationAudioLoadTests cover conversion/copy and error boundaries.

## 4. VoiceprintStore

Source: [VoiceprintStore.swift](../../../Memozia/Services/VoiceprintStore.swift).

### 4.1 Storage

`~/Documents/Memozia/Voiceprints/<uuid>.json` contains name, normalized embedding, and modelId. A different embedding model disables incompatible voiceprints.

### 4.1.1 Same-name merge

Different recording conditions can produce duplicate names below registration similarity. Settings offers Merge Same Name only when eligible groups exist. Group by name/modelId/dimension, weight centroids by sampleCount and normalize, preserve earliest ID/time and unique source-recording IDs. Write the merged result before deleting extras; never merge across models or discard originals on write failure. See VoiceprintMergeTests.

### 4.2 Thresholds

| Constant | Value | Purpose |
|---|---|---|
| matchThreshold | 0.50 | Recognition score |
| matchMargin | 0.05 | Minimum top1-minus-top2 margin |
| samePersonThreshold | 0.65 | Registration duplicate threshold |

### 4.3 Operations

Load/save/delete JSON and compare L2-normalized embeddings using cosine similarity.

### 4.4 Registration and recognition

Registration presents per-speaker preview of the earliest segment through AudioPlayerState.playRange, with exact start and automatic end pause checked by a periodic observer. Missing source disables preview. Enter a name, extract the longest 30 ≥1.5-second intervals, duration-weight/L2-normalize, save, and replace the recording's labels. Match ≥0.65 updates the same name or rejects a conflicting name. Read selected intervals only.

After editing names, invalidateTranscriptCache must clear TranscriptCache before incrementing transcriptVersion; otherwise a new task can read stale data with no later trigger to repair it.

Recognition first collapses same-name/model/dimension entries so one person cannot occupy both top candidates and erase the margin. Compare refined centroids without changing clustering. Accept score ≥0.5 and margin ≥0.05; otherwise keep generic labels. A global maximum-weight assignment with top three candidates enforces one registered identity per speaker; beyond eight speakers use greedy assignment. Empty/failing stores do not block transcription. Recognition defaults on, with unmatched/ambiguous score diagnostics that avoid transcript content.

## 5. DiarizationCalibrator

Source: [DiarizationCalibrator.swift](../../../Memozia/Services/DiarizationCalibrator.swift).

```sh
Memozia --calibrate-diarization <audio-path> [threshold|centroid[:threshold]|refine] [model-folder]
```

The early process hook runs calibration then exits without UI. Threshold scans report per-speaker durations; centroid/refine modes inspect similarity and verify the calibrated merge thresholds.

## 6. Chinese normalization

[ChineseConverterService.swift](../../../Memozia/Services/ChineseConverterService.swift) runs after diarization and before dictionary correction. Bundled OpenCC dictionaries normalize script according to language settings; consult the service/caller for direction.

## 7. Dictionary correction

Source: [TranscriptDictionaryService.swift](../../../Memozia/Services/TranscriptDictionaryService.swift).

### 7.1 Format

Markdown files under `~/Documents/Memozia/Dictionary/` are managed in settings. Bullet terms enable homophone correction; table or `wrong -> correct` pairs define exact replacements. Keep the literal `#去标识化:类别` marker for PII entries; those do not participate in transcription correction.

### 7.2 Algorithm

correct applies exact replacements first, longest first, then applyPinyinCorrection. rawPinyin uses CFStringTransform to remove tones/separators; sliding windows are limited to continuous Han-character runs with matching normalized pronunciation.

### 7.3 Timing

Run after script normalization and before encryption. Changes do not rewrite finished transcripts; retranscription applies them.

## 8. TranscriptCache

[TranscriptCache.swift](../../../Memozia/Services/TranscriptCache.swift) caches decrypted, concatenated, parsed SegmentData by recording ID. Its LRU is bounded by cost (64 MB) and entry count (24), retaining at least one item; consult Store for current thresholds. Editing/retranscription must invalidate it, and transcriptVersion drives view rebuilding.

## 9. Post-processing order

```text
TranscriptionResult
→ Optional diarization by overlap
→ Optional voiceprint global identity assignment
→ Chinese script normalization
→ Exact then phonetic dictionary correction
→ Encryption
→ TranscriptSegment[] and transcript.json
→ Cache construction/invalidation
```

RecordingViewModel owns orchestration; see [ViewModels](10-ViewModels.md), §1.2.

## 10. System speech recognition

[SystemTranscriptionService.swift](../../../Memozia/Services/SystemTranscriptionService.swift) exposes the version-safe SystemTranscription facade. On macOS 26+ it delegates to SystemTranscriptionService using SpeechAnalyzer/SpeechTranscriber; older systems receive unsupportedOS.

AssetInventory manages language assets, not Whisper folders. First transcription prepares them, or prepareLocale can do so explicitly; localeStatus distinguishes ready, needsDownload, unsupported. There is no automatic language detection: explicit language wins, empty follows system preferences, and speech-recognition authorization is required. Timestamped output shares the existing diarization/post-processing pipeline. A cancellable gate serializes inference; asset preparation may be indeterminate and recognition progress follows processed time.

defaultMode prefers this engine when supported, otherwise WhisperKit. New engine choices exclude cloud Whisper while preserving saved cloud modes. NativeSpeechService belongs to text-to-speech synthesis, not recognition; see [Views](11-Views.md), §8.1.
