# Segmented recording, recovery, and long-meeting transcription

A long meeting makes file finalization part of the product experience. If the app stops unexpectedly, the useful question is which audio reached disk, which segments are readable, and how to recover them without erasing the evidence needed to diagnose the failure.

Memozia rolls microphone and system-audio capture into separate segments. The current meeting recorder targets a rotation every **300 seconds**. This is a capture-storage interval; it is not a promise about transcription chunk size or recovery granularity.

## The capture and recovery path

1. Create a unique meeting folder without replacing an existing entry.
2. Write microphone and system audio independently and record segment timing.
3. When a rotation is due, prepare the next writer. If replacement fails, preserve the active recording path where possible.
4. At stop or recovery, inspect the available segments and their duration and audio tracks.
5. Where possible, repair an unfinished PCM container using a **copy**. Preserve problematic originals when recovery or capture warnings make them useful.
6. Merge usable audio with its timeline, then index the recovered entry.

Container repair can make audio that was written but not finalized readable. It cannot recreate samples that never reached disk, an unplugged input, or an interval lost while the machine was unable to capture. A recovery report should distinguish recovered, repaired, and skipped material.

## Three different kinds of chunking

| Layer | Current behavior | Purpose |
| --- | --- | --- |
| Capture storage | Rolling segments, targeting 300 seconds | Bound file lifetime and support recovery |
| Local transcription | Submit the selected audio file to WhisperKit; the library manages decoding windows | On-device speech recognition |
| Cloud transcription | App upload limit is 25 MiB; larger inputs are split adaptively, with a 60–600 second target range | Fit provider requests within the app's upload budget |

The cloud path also checks the size of the exported chunks; choosing a duration is not a guarantee of encoded file size. Local transcription does not automatically reuse each five-minute capture segment as a separate inference request. Keeping these layers distinct avoids misleading users about timestamps, progress, and failure boundaries.

## Reproduce segment rotation and recovery

Use a **separate development app and fictional workspace**, following [the build guide](../BUILDING.md). Do not run an interruption experiment against the workspace containing your real meetings.

1. Record a synthetic meeting for a little over five minutes. Place an audible marker near the start and another after the five-minute point. In the development workspace, observe that the capture rolls files while the meeting remains active.
2. Stop normally. Check playback around the rotation and confirm both markers. Compare the resulting duration with the time actually recorded.
3. For a separate test, make a new synthetic recording. Interrupt only that development app after some audio has been written, then relaunch it. Follow the recovery prompt if one is offered.
4. Check the recovered playback, the marker positions, the reported duration, and any warning about missing or repaired segments. Retain a copy of the synthetic files when investigating a failure. Do not interpret “entry recovered” as proof that no audio is missing.
5. Transcribe the recovered audio locally and compare timestamps around the interruption. If testing the optional cloud route, remember that its audio is sent to the configured service.

This procedure is a test plan. The promotional tour uses prepared content and does not demonstrate a crash or establish a maximum supported meeting duration.

## Files are the recovery boundary

Memozia's entry folders under `~/Documents/Memozia/` are the authoritative workspace; SwiftData provides an index. That design lets recovery inspect files without treating the database as the only copy of a meeting. It also means a backup plan must include the workspace and the app's key-management requirements. The file-first design does not mean every media file is encrypted: the app's encrypted text-artifact path is distinct from locally stored audio and images.

The important engineering test is whether the app reports partial results accurately and preserves useful source files, not whether a recovery path can always return a success flag.

## Read and test the implementation

- [Rotation, merge, and recovery coordination](../../Memozia/Services/MeetingRecorderService.swift)
- [Microphone recovery](../../Memozia/Services/MicCaptureRecovery.swift) and [file synchronization](../../Memozia/Services/FileSyncService.swift)
- [Segment timeline](../../Memozia/Models/RecordingSegmentTimeline.swift)
- [Local WhisperKit path](../../Memozia/Services/WhisperLocalService.swift) and [cloud upload splitting](../../Memozia/Services/WhisperAPIService.swift)
- [Recovery tests](../../MemoziaTests/MicCaptureRecoveryTests.swift), [timeline tests](../../MemoziaTests/RecordingSegmentTimelineTests.swift), and [merge tests](../../MemoziaTests/RecordingMergeTests.swift)
- [Actual app workflow tour](../assets/demo/memozia-workflow.mp4), with fictional meeting results

中文要点：五分钟分片用于采集与落盘，不等于转写分块。恢复先检查可读性，必要时修复副本并保留问题原件；无法恢复未写入的声音。本地 WhisperKit 解码与云端 25 MiB 上传分块是另外两层逻辑。中断测试应使用独立开发工作区和虚构素材。
