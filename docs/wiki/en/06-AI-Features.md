# 06 · LLM Summaries and AI Features

[← Home](Home.md) · Source: Memozia/Services

## 1. LLMService

[LLMService.swift](../../../Memozia/Services/LLMService.swift) provides static request functions with Sendable LLMConfigSnapshot values. It supports OpenAI-compatible services including OpenAI, LM Studio, Ollama, and compatible gateways; explicit isLocal drives PII and URL policy.

### 1.1 Entry points

| Method | Purpose |
|---|---|
| generateSummary | Transcript/note text to Markdown summary |
| generateTitle | Short title after summary |
| generateSummaryFromImage | Image-note summary when supportsVision is enabled |
| generateVisualNotes | Timestamped keyframe notes |
| detectMeeting | Fallback classification for entry points without explicit template selection |

### 1.2 Summary flow

Cap oversized input, then use the explicit meeting/overview template choice. Pro recording/video views expose both buttons and corresponding regeneration actions. Save the choice in isMeeting/meetingJudgedBy and carry it in summary queue entries so the worker does not reclassify. Legacy entries fall back to the persisted decision, then conservative detectMeeting classification. Retranscription invalidates the prior classification. Notes force overview.

Meeting uses systemPrompt; non-meeting audio uses overviewSystemPrompt; non-meeting video with existing visual notes uses videoOverviewSystemPrompt. Overview prompts reorganize important conclusions by topic instead of retelling events in sequence, retaining relevant mm:ss anchors. Existing visualSummary enters as same-timeline supporting evidence. Summary does not automatically extract/upload frames. Task extraction follows the entry's meeting decision and constrains non-meeting items.

For each retry call onAttemptStart and clear visible partial output before accepting new tokens. TokenCoalescer batches onToken callbacks and flushes the tail; retain the accumulated final text and restore PII when complete.

### 1.3 Requests and SSE

POST chat/completions JSON with Bearer authentication, a restrained max_tokens default, and a one-hour request timeout for long text. URLSession.shared.bytes reads SSE lines, parses data/choices[0].delta.content, coalesces tokens, and accumulates the result.

### 1.4 Snapshots

LLMConfigSnapshot carries chatCompletionsURL, apiKey, modelName, isLocal, supportsVision. Do not capture non-Sendable SwiftData configuration objects across actors.

### 1.5 Safety boundaries

validateSecureURL normally requires HTTPS. Existing HTTP exceptions cover recognized loopback hosts or an explicit isLocalModel selection, supporting user-configured LAN local-model servers. Every chat request passes the actual configuration flag through validateSecureURL(for:). Never label a cloud configuration local to bypass validation; reject non-HTTP(S) schemes. Legacy Whisper API has only HTTPS/loopback exceptions. Explicitly selected remote-local HTTP carries plaintext risk; do not silently broaden it.

Wrap input as data with delimiters and system-prompt instructions rather than trusting embedded instructions. Escape multipart filenames by removing quotes/newlines to prevent header injection.

## 2. TodoExtractionService

Source: [TodoExtractionService.swift](../../../Memozia/Services/TodoExtractionService.swift).

Prefer summary text, otherwise transcript; notes combine body/OCR. Prompts request structured JSON title, notes, URL, deadline, advance alarm, priority. Confirmed non-meeting input adds constraints to extract explicit tasks/practice only, not turn every knowledge point into an action. Parse into TodoItems/TodoDocument and encrypt todos.json. Entry points include recording/note task actions; writing to Reminders remains a separate user-confirmed step.

[CurrentTimeService.swift](../../../Memozia/Services/CurrentTimeService.swift) creates fresh current-time context immediately before text/OCR/image requests, including custom templates: ISO8601 with offset, Gregorian date, weekday, and local timezone identifier. Read again on retries. Relative phrases such as tomorrow/next Friday use that context, not model training dates or sample JSON. Device clock/timezone determine accuracy; no network clock lookup is added.

Local task requests use SSE, distinguish thinking/generating UI phases, and create a document only after complete untruncated content. Also accept services ignoring stream and returning full JSON. Idle/resource limits are 180/600 seconds; cancellation interrupts capability probing and inference. Cloud stays nonstreaming with 120 seconds.

LocalLLMCapabilities probes the same server's LM Studio GET /api/v1/models with a three-second timeout and exact model/quantization/loaded-instance matching. Send reasoning_effort none only if disabling reasoning is advertised; translate native off to the compatible endpoint's none. Confirmed LM Studio GGUF/MLX models get a task JSON Schema. Unavailable old-server probing uses generic parameters; explicit schema rejection removes only schema and retries negotiation once, retaining reasoning settings. Other local errors do not automatically retry.

Distinguish empty items, empty content, reasoning-only output, exhausted budget, truncation, and timeout. reasoning_content/reasoning contribute lengths only, never task input; strip legacy leading think blocks. Logs record timings, finish reasons, lengths, and server token counts without user or reasoning text.

## 3. RemindersService

Source: [RemindersService.swift](../../../Memozia/Services/RemindersService.swift), EventKit integration.

Map TodoItem title/notes/url to EKReminder; map dueDate/alarmOffsetMinutes to date components/alarms and priority to system priority. Support default or selected lists. Persist reminderIdentifier and written/failed status in TodoDocument. Load it before deleting the entry folder to clean associated reminders. Always confirm LLM-generated changes to system resources.

## 4. URL diagnostics

[RemindersURLDiagnostic.swift](../../../Memozia/Services/RemindersURLDiagnostic.swift) is a one-time debugging tool:

```sh
defaults write app.memozia reminders_url_diagnostic -bool true
```

Next launch tests URL writes using a synthetic reminder and an example.com URL, records only success states in url_diagnostic.txt under storage, and clears the flag. It does not read or repair existing todos.

## 5. PIIScrubService

Source: [PIIScrubService.swift](../../../Memozia/Services/PIIScrubService.swift).

### 5.1 Activation

Apply to cloud summaries/tasks only when enablePIIScrub is enabled and isLocal is false. The preference defaults on. Local configurations bypass this text substitution.

### 5.2 Detection

First use dictionary entries with the literal `#去标识化:类别` marker, longest first. Then automatically detect phone numbers, 18-digit identity numbers, and email addresses using regex.

### 5.3 Placeholders and restoration

scrub returns protected text plus a mapping. Restore the full final summary after streaming rather than individual tokens, since placeholders can span tokens. Restore TodoDocument fields after JSON parsing.

### 5.4 Call sites

RecordingViewModel protects individual/queued summaries and recording tasks; QuickNoteViewModel protects note text task requests. Direct images are not text-redacted. Do not imply a screenshot/frame has been de-identified by this service.

### 5.5 Dictionary cooperation

PII and correction entries share Dictionary files with different markers. Synchronize Names from Voiceprints adds common person-name PII. Update De-identification uses local PIIScanService to derive marked terms from completed transcripts.

## 6. PIIScanService

[PIIScanService.swift](../../../Memozia/Services/PIIScanService.swift) accepts local-model configurations only, preventing sensitive text from being sent to a cloud model merely to discover what to redact. Settings → Dictionary triggers completed-transcript scanning and marked company/person term insertion.

## 7. End-to-end text flow

```text
Decrypted transcriptMarkdown
→ Optional cloud PII scrub + mapping
→ Streaming summary → full-text identifier restoration
→ Encrypt summary field and summary.md → title generation
→ Summary/full text → optional scrub → structured task extraction
→ Restore document fields → encrypt todos.json
→ User confirmation → EventKit → persist reminderIdentifier/status
```

## 8. Video visual notes

The Pro Visual tab offers playback, manual analysis, privacy-path labeling, and a keyframe timeline. LLMModelSelectorBar is shared with Summary, with image-understanding/local-OCR capability labels. Click thumbnails to seek. Copy/edit generated notes; edits use updateRecordingVisualSummary to encrypt the field/mirror. Switching entries or starting reanalysis discards unsaved drafts.

Visual processing has two deliberate steps. Extract Keyframes is local only, saves frames, reports count/estimated batches, and refreshes the timeline. Only a subsequent confirmation sends frames to the chosen model. Reanalysis reuses disk frames. loadOrExtractFrames is shared; summary buttons never trigger extraction, although existing visual notes support later summaries.

### 8.1 Original-video cleanup

VideoUnderstandingView asks for confirmation with estimated freed space and retained outputs. cleanupVideo requires hasReusableFrameCache: current strategy marker and actual frames. Missing cache rejects deletion before touching data. cleanupOriginalVideo removes the single videoFileURL only, retaining frames, visual.md, checkpoints, audio, and transcript; failures propagate.

After removal videoFileName is nil, while visual artifacts keep the Visual tab available. loadOrExtractFrames accepts nil videoURL and cached frames, so analysis/model changes still work; fresh extraction is disabled without the original. See VideoCleanupTests.

### 8.2 Keyframes and resumable analysis

The significant-events-v5 cache policy scans at max(0.5 seconds, duration/10000) using batched 96-pixel thumbnails, excluding endpoints. Signatures combine 9×8 coarse bidirectional dHash, 17×16 detail dHash, and 3×3 luminance/RGB means. Duplicate gates use coarse distance ≤12, detail ≤24, luminance ≤26, RGB ≤24. Normal minimum spacing is three seconds, hard cuts at distance ≥26 are immediate, and 30-second fallback samples cover slow changes.

Collapse consecutive duplicate fallback points and transient A→B→A changes lasting at most three seconds; preserve other significant changes and genuine later returns to a page. The old duration budget lost brief pages/steps; 1024 stable events is now an extreme-dynamic-material safety valve, selecting by temporal coverage when exceeded, not an ordinary long-video frame budget.

Save JPEGs in frames with the existing timestamp naming. generateVisualNotes dynamically batches all extracted frames into requests of at most eight, without a second fixed 12-batch/96-frame downsampling cap. Vision models receive interleaved frame/time labels and image_url content; text models receive per-frame local OCR with timestamps under the same task prompt.

Persist each successful chunk encrypted in visual-analysis-checkpoint. The same model/endpoint/full frame-content identity reuses completed chunks after cancellation, exit, or network loss; changed identity invalidates old checkpoints. The manifest contains versions, identity digest, and count only, never keys or frame text. Delete checkpoints only after final result persistence succeeds.

Low-resolution horizontal hashes alone miss vertical scrolls/template text/color changes. More features and preserved event budgets improve retention; a larger distance threshold alone is not greater sensitivity. Avoid global deduplication that erases genuine later timeline events.

### 8.3 Shared audio/video timeline

The audio comes from the same source video, aligning visual mm:ss notes and transcript timestamps for comparison.

### 8.4 Cancellation, errors, and privacy

- No BackgroundTaskQueue visual processing; app exit stops it, with checkpoints available for later explicit analysis.
- Check cancellation per batch/frame. Stop/delete calls cancelVisualNotes. Merely selecting another entry does not cancel ViewModel-owned work.
- Unexpected host/view reconstruction cancellation gets one self-healing checkpoint resume if the task still owns its generation. Repeated failure is visible and preserves completed chunks. Explicit cancellation/replacement remains quiet.
- Unreadable/zero-duration video, no valid frames, and text-model OCR with no text produce explicit errors rather than empty successful notes.
- If one chunk exhausts retries, retain other chunks, continue, and append failed time ranges. Throw only if all chunks fail.
- Frames share screenshot boundaries: unencrypted local images, sent unchanged to the configured vision model. Prompts restrict notes to visible evidence and treat frame text as data, but do not claim image PII redaction.
