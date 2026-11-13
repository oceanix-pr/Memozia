# 04 · Recording and Audio Capture

[← Home](Home.md) · Source: Memozia/Services

```text
MeetingRecorderService (@MainActor @Observable shared coordinator)
  ├─ MicCaptureService: AVAudioEngine / AVAudioFile, CAF PCM segments
  ├─ SystemAudioCaptureService: ScreenCaptureKit / AVAssetWriter, WAV PCM
  ├─ AppMuteDetector: meeting-app Accessibility polling
  ├─ MicMuteMonitor: CoreAudio mute observation
  └─ AudioConverter: duration and conversion
```

## 1. MeetingRecorderService

Source: [MeetingRecorderService.swift](../../../Memozia/Services/MeetingRecorderService.swift).

### 1.1 Responsibility

Coordinate disk checks, atomic folder creation, configured source startup, rolling segments, stop/merge, and final m4a. UI observes isRecording, elapsedSeconds, isMicMuted, and muteSource directly.

### 1.2 Rolling segments

Each source rotates independently every 300 seconds, limiting the damage from a corrupted single file. Entry directories contain `*_mic_tmp_*.caf` and `*_sys_tmp_*.wav`; `pendingMergeFinalURL` tracks the final target. Normal complete merging removes source segments; degraded/faulted captures preserve originals.

### 1.3 Operations

| Method | Contract |
|---|---|
| `startRecording(config:)` | Require at least 500 MB, atomically create the month/timestamp folder, start microphone/system/mixed capture, and preflight required permissions |
| `stopRecording()` | Stop timer, mute observers, and capture; merge; return the final URL. Separate save failures from historical capture notices; recovered interruptions do not become repeated error dialogs |
| Rotation | Synchronous microphone rotateSegment and asynchronous system rotateWriter. If rotation fails, keep writing the old segment |
| `mergeSegments()` | Validate playable tracks/durations, skip invalid/empty segments, run aligned mixed-track reference echo reduction, compose/export m4a, fall back to single-track concatenation. Expose checking → echo reduction → mix/export → save through mergePhase |
| `finalizeForTermination()` | Finalize remaining temporary containers so the next disk scan can validate/recover them |

### 1.4 Regression-sensitive constraints

See [Development Guide](../../../DEVELOPMENT_GUIDE.md), §1, for descriptor peaks, PCM containers, disk thresholds, serial writes, and SDK branches. Recovery read failures must never justify deleting originals.

## 2. MicCaptureService

Source: [MicCaptureService.swift](../../../Memozia/Services/MicCaptureService.swift). The class/tap callback must not inherit MainActor isolation: real-time callbacks run off the main actor. Engine/node control and current engine-state reads still occur on MainActor.

### Startup and format

Request undetermined microphone permission and await the answer; ignore late authorization after stop/cancel. Read-only preflight alone would never register the app in the system Microphone pane. Denied permission produces an actionable settings error without retrying prompts.

Create a fresh AVAudioEngine, resolve selected/default device, check binding success, and inspect hardware inputFormat, client outputFormat, and current CoreAudio device sample rate. Align a stale node snapshot to the device; log failed device queries and fall back to node format. Create matching CAF PCM, apply initial mute, install tap, start, then wait for the current tap's first nonempty buffer to be successfully written. Engine start alone is not readiness. Initial startup and recovery share bounded retries; actual permission/file-write errors are not blindly retried.

PCM uses current sample rate/channel count, 16-bit, non-float, little-endian, non-interleaved format. File processing format must match buffers. Never append a new device format into an old-format segment.

### Mute and recovery

Mute keeps the tap installed and writes zero buffers through silencedBox, preserving time and valid rotating segments. Unmute can initiate recovery if the engine stopped; report progress through capture events rather than treating recovery as immediate write failure.

AVAudioEngineConfigurationChange observations carry session/engine generations. Drop old notifications and ignore same-format notices while running. A real change invalidates the current attempt/tap and retries within the existing recovery round without resetting its budget. Reuse engine/input node for negotiation and `-10868` retries when possible; rebuild only if binding or continued use requires it. Re-resolve the chosen device and check the binding result, explicitly falling back to system default if unplugged.

[MicCaptureRecovery.swift](../../../Memozia/Services/MicCaptureRecovery.swift) coordinates an immediate attempt then 200 ms / 500 ms / 1 s / 2 s backoff, at most five attempts within one 15-second budget. Reserve a meaningful first-buffer observation window; synchronous preparation/start time counts against the budget. Insufficient remaining time is recoveryBudget, not a fictitious writeBuffer timeout. After start, recheck negotiated format and rebuild the tap if needed. Each attempt waits at most three seconds for a successful nonempty write; muted zero buffers count. Independent tap/attempt IDs prevent old writes confirming new attempts. A late successful write for the final timed-out attempt may still resolve its warning.

When format changes, register a new CAF segment before restarting. Recovery with existing audio always starts a new CAF even if the format matches. If dual-track boundaries no longer align, skip per-segment echo cancellation and still preserve/mix complete audio.

### Events and write-failure classification

MicCaptureEvent separates deviceUnavailable, recoveryStarted, recovered, recoveryFailed, and writeFailed. Recoverable routing updates banners; final exhausted recovery or true disk-write failure becomes a warning. Explain possible missing microphone audio independently of system-audio health instead of declaring the entire recording lost.

Events include session generation, failure stage, binding result, old/new rates/channels, error domain/code. `writeFailureIsDeviceTransition` treats a stopped engine, recent configuration change within deviceTransitionWindow, or changed input format as routing symptoms. `reportWriteError` returns to MainActor to inspect current engine state before classification. Only stable running/matching-format writes far from a transition become actual write failures.

### Thread safety and stopping

MicCaptureFileStore uses one lock for file replacement, tap eligibility, and writing; stale taps cannot write into a new file. Success/failure callbacks recheck tap/session IDs. Each tap owns its zero-buffer pool. Stop invalidates the session and first-buffer wait, revokes writing, removes observers/tap, releases engine/files, and never reuses the old engine for the next recording. Failed attempts remove only confirmed empty shells; preserve segments with data or failed reads.

### Device selection

[MicrophoneDeviceRegistry.swift](../../../Memozia/Services/MicrophoneDeviceRegistry.swift) enumerates input-capable CoreAudio devices, including virtual/loopback devices. Bind through AUHAL CurrentDevice without changing the system-wide default. Skip redundant binding, validate every required bind, and resolve the current default at every capture preparation when following the system. Persist UID, not display name; unplugged selections fall back consistently for capture and mute monitoring.

Display lists use a one-second cache; actual capture decisions always query live device state. Settings, the top-level menu-bar Microphone item, capture toolbar, and recording badge share `microphone_device_uid`. All selection locations also offer mute. [MicMuteCommand.swift](../../../Memozia/Models/MicMuteCommand.swift) centralizes runtime text/icons/availability and cannot unmute a system/meeting-app mute. Before capture, menus edit `MicrophoneStartMutePreference` (`microphone_start_muted`), applied by MeetingRecorderService for audio and screen recording.

### Continuous health and shared timeline

The recording tick checks successful writes every second. Three seconds without writing or a stopped engine enters bounded recovery; MicCaptureLiveness prevents an exhausted budget from restarting each tick. Actual device changes, manual recovery, or a late successful first buffer may resolve it. CoreAudio observes default input, device list, liveness, and sample rate with duplicate-route coalescing.

RecordingSegmentTimelineStore records each segment's first-write host clock and atomically saves capture_timeline.json. Stop and crash recovery use relative-time insertion, retaining middle/end silence rather than compressing gaps. Old recordings without sidecars concatenate sequentially; corrupt new sidecars or missing timing for playable segments preserve material and fail explicitly. Echo cancellation requires matching counts, starts, and durations. Rotation reserves identifiers before async work to prevent overwrite/reentry.

Degraded/skipped/faulted captures preserve originals and expose skipped filenames/last successful write time. A playable final file prevents recovery from consuming originals again. Small size or failed reads cannot prove emptiness. RecordingSegmentTimelineTests cover timing, formats, silence, preservation, and recovery; real engine-stop verification requires explicit `MEMOZIA_VERIFY_AUDIO_CAPTURE=1` and writes zero buffers only.

## 3. SystemAudioCaptureService

Source: [SystemAudioCaptureService.swift](../../../Memozia/Services/SystemAudioCaptureService.swift).

ScreenCaptureKit requires Screen Recording permission even for system audio. SCStream captures 48 kHz stereo and excludes the current process to avoid feedback, with audio and placeholder-screen outputs. Handle audio samples only. Start AVAssetWriter's session at the first sample PTS, never fixed zero; check readiness before append. rotateWriter finalizes a WAV PCM segment asynchronously and opens the next. Output is real-time 16-bit stereo PCM.

### State and cleanup

Use explicit idle/starting/running/reconnecting/stopping/failed state. Cleanup follows actual resources, not a Boolean. Startup failure rolls back stream and writer. Unexpected stream stop marks failed but retains resources for later finalize/reconnect. Stop is idempotent, and may restore idle only if still stopping so it cannot overwrite a newer concurrent startup.

### Sleep, recovery, and reports

Events carry capture generations; MainActor checks both recording and capture identity. Old stopped/replaced streams log debug only. Recover sleep using actual configured source/resources, not transient capturing state; never reopen sharing the user intentionally stopped. A 30-second watchdog invalidates timed-out/cancelled recovery, and late streams cannot take over. Confirm recovery only after the first successful audio sample write, not merely stream start. Sleep-gap microphone silence belongs to the original file and cannot spill into a replacement.

[RecordingCaptureHealth.swift](../../../Memozia/Models/RecordingCaptureHealth.swift) separates current state from historical impact for system audio and microphone devices. Recovery changes current UI but does not erase interruption evidence. Resolve only the matching recovery-failed warning, preserving unrelated disk errors. RecordingCaptureReport stores observed interruption ranges, confirmed recovery, last mic write, and mute evidence. Ranges are not precise measured sound-loss durations. Immediate normal route changes produce no gap; fully muted recovered intervals are informational, not claims of lost speech. Debounce equivalent warnings without hiding unrelated faults.

### Stop feedback

`finishRecordingSave` emits RecordingFeedback only after media validation, capture report/metadata persistence, and database save. Historical recovered issues/degraded tracks use a non-modal banner with View Details. Missing/unverifiable media or key save failures remain explicit errors with Finder access. Unresolved live problems keep a persistent device-check banner.

[RecordingCaptureReport.swift](../../../Memozia/Models/RecordingCaptureReport.swift) atomically stores stable reason codes/evidence, no content or keys, without adding SwiftData columns. Reports remain readable after rename/restart/reindex. Missing legacy reports are normal; damaged/unreadable reports cannot masquerade as no issues. Preserve folders whose only remaining useful data is the report. See [RecordingCaptureReportTests.swift](../../../MemoziaTests/RecordingCaptureReportTests.swift).

## 4. AppMuteDetector

[AppMuteDetector.swift](../../../Memozia/Services/AppMuteDetector.swift) polls meeting-app Accessibility trees once per second after permission. Prefer Teams `domID == "microphone-button"`, then combined description/role checks; Chinese unmute detection requires combined keywords to avoid matching unrelated dialogs. Limit recursion depth to 35. Feed the differentiated meeting-app/system mute source to MeetingRecorderService.

## 5. MicMuteMonitor

[MicMuteMonitor.swift](../../../Memozia/Services/MicMuteMonitor.swift) observes CoreAudio kAudioDevicePropertyMute on the resolved capture device, rebinding on changes. Read the event's objectID, not a newly queried default that may have changed. C callbacks bridge through an unretained pointer to a singleton whose lifetime exceeds registration and hop to MainActor for state updates.

## 6. AudioConverter

[AudioConverter.swift](../../../Memozia/Services/AudioConverter.swift) uses AVAssetReader/Writer for asynchronous duration (`getDuration(of:)`) and import normalization. Duration fills AudioRecording after stop.

## 7. Offline reference echo reduction

Sources: [EchoReductionService.swift](../../../Memozia/Services/EchoReductionService.swift), [EchoCanceller.swift](../../../Memozia/Services/EchoCanceller.swift). The former orchestrates I/O; the DSP core is testable without AVFoundation.

The target is local speaker sound recaptured by the microphone, causing duplicate transcription. A linear adaptive filter does not model one's voice traveling through remote codecs/network jitter; that case belongs to dual-track transcription/deduplication.

| Stage | Behavior |
|---|---|
| Trigger | Enabled by default through EchoReductionPreference; aligned mixed-track segments only, before final mixing |
| Deadline/cancel | Independent watchdog: base five minutes plus ten per source hour, capped at 30 minutes. Check deadline/CancellationFlag per segment and cancellation per DSP block. Keep completed cleaned segments and fall back to original remaining audio on timeout/cancel/failure; never block saving |
| Progress | reduceEcho reports completed/total through echoReduction phase and stage start time |
| Delay | Downsample to roughly 12 kHz for normalized cross-correlation, then refine at source rate. Low correlation yields no estimate and falls back to zero |
| Filter | Constrained overlap-save frequency-domain NLMS; window twice block size, 4096 taps ≈85 ms at 48 kHz. Normalize before time-domain gradient constraint to avoid divergence |
| Double talk | Freeze adaptation when local microphone energy dominates reference, preserving local speech |
| Rate/output | Resample/downmix reference to microphone rate. Write complete 16-bit mono CAF cleaned segments; accept only complete frame counts |
| Names | `_mic_clean` deliberately lacks `_mic_tmp`/`_sys_tmp`, preventing duplicate crash recovery |

Partial outputs are removed; originals remain on failure. No intra-segment clock-drift correction is needed for typical five-minute drift relative to filter length. Only Pro exposes the preference; Standard uses defaults.

## 8. Complete recording sequence

Start → disk check → atomic month/timestamp folder → selected capture source → elapsed/disk checks and mute observers → five-minute rotations. Low-space monitoring warns below 1 GB and requests stop/save below 200 MB. Muted microphone taps keep a continuous zero-buffer timeline.

Stop → finalize capture → check segments → optional bounded echo reduction → mix/export → inspect duration → create/save AudioRecording with short-backoff descriptor-exhaustion retry → save metadata. Crash-left segments stay in the entry directory for validated startup recovery. Application exit invokes emergency finalization.

## 9. Screen recording

Screen recording reuses the audio pipeline and adds [ScreenVideoRecorder.swift](../../../Memozia/Services/ScreenVideoRecorder.swift), not another audio implementation. Pro Capture toolbar/menu/session actions select full display directly or region/window through the unified frozen session, then show RecordCountdownPanel. An untouched window pick upgrades to desktopIndependentWindow. Source/quality use separate shared preferences.

RecordingViewModel starts audio and writes `{base}_video.mp4` beside it. SCStream/AVAssetWriter uses fragmented MP4 (`movieFragmentInterval` five seconds), preserving playable fragments after crash. First-frame PTS establishes the session; samples retain timestamps. Preflight estimated half-hour disk use, inspect every 20 seconds, and route critical space to unified stop. Display removal, revoked permission, or closed target stops video with a notice while audio continues.

Video finalization and audio merge can run concurrently; wait for both before `AudioConverter.embedAudio` passthrough muxing. Replace the video's audio with the full mixed m4a without re-encoding. Preserve the original video and report failure if muxing fails, without losing the audio/index entry. Independent startup can leave a small audio/video offset.

Finalize through RacingWatchdog with a 120-second bound. On timeout stop waiting but do not cancel the writer and destroy playable fragments. Validate a parseable positive-duration video track, not byte size. Append only complete/started frames, not idle/blank/suspended samples; static video may legitimately be shorter than audio.

HEVC quality tiers are native 30 fps, Standard ≤2560 px at 30 fps, and space-saving ≤1920 px at 15 fps, with approximate sizes 18/6.8/2.7 GB per hour. Convert region points by display scale, cap, and use even dimensions. Pass sourceRect as display-local top-left-origin points; investigate that coordinate assumption first if cropping shifts.

Screen recording never enters BackgroundTaskQueue. Fragmented output and startup scanning provide crash recovery, while normal UI recording safeguards apply. Use the actual activeRecordingSource. Selection/countdown belong to the shared capture session; old standalone selection controllers/window sheets are retired.
