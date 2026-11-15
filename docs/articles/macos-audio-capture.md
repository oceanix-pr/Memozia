# Recording microphone and system audio on macOS

A meeting recorder needs to hear both the person at the Mac and the remote participants coming through its speakers. Those inputs have separate lifecycles: a headset can disconnect while system audio continues, and a system-capture permission can fail while the microphone still works. Memozia keeps the capture paths separate and combines their files later.

## Two inputs, one meeting timeline

| Input | Capture path in Memozia | Intermediate storage |
| --- | --- | --- |
| Microphone | `AVAudioEngine` input tap | PCM in CAF segments |
| System audio | ScreenCaptureKit audio sample callbacks | PCM in WAV segments |
| Finished meeting | Validate, align, and merge usable segments | Playback audio for the entry |

Apple's [audio tap documentation](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap%28onbus%3Abuffersize%3Aformat%3Ablock%3A%29) describes receiving buffers from an audio node. [ScreenCaptureKit](https://developer.apple.com/documentation/ScreenCaptureKit) supplies screen and audio capture; its [`capturesAudio` setting](https://developer.apple.com/documentation/ScreenCaptureKit/SCStreamConfiguration/capturesAudio) must be enabled to receive audio. These are the platform building blocks. The separate-file lifecycle and later merge are Memozia's implementation choices.

## Keep the callback path small

An audio callback should not wait for a language model, render SwiftUI, or merge an entire recording. Memozia's microphone path handles incoming buffers and recording state separately from the app's main-actor UI. System audio has its own sample handler and writer state. The meeting recorder coordinates start, stop, rolling segments, and the final merge.

“Recording” is not sufficient evidence that samples are still arriving. Device changes, sleeping and waking, stream failures, and a writer that has stopped accepting input need distinct handling. Resource cleanup also needs to consider live engines, streams, taps, and writers even if a displayed state flag has already changed.

## Reproduce the two-source check

Use your own short synthetic test, with headphones if possible, so the microphone does not simply hear the system test through the speakers.

1. Select microphone-only recording in Memozia's recording settings. Say “microphone marker one,” wait a few seconds, then stop. Confirm the marker in playback.
2. Select system-audio recording. Play a short clip containing “system marker two” from another local app. Grant the system-capture permission when macOS requests it. Confirm that playback contains the clip.
3. Select mixed recording. Start the system clip, say “microphone marker three,” and stop. Listen for both sources and check their relative timing. Do not use the first two tests as proof that mixing is correct.
4. For a device-change check, repeat the mixed test in a development session and switch the input device once. Note the time of the change. Check any capture warning, the saved duration, and playback around the transition. Record the macOS version and hardware with a synthetic reproduction report.

The expected outcome is understandable playback with both markers at the times they occurred. If a source is unavailable, the app should expose that condition; an empty or partial recording should not be described as a successful two-source capture.

## Preserve time before combining files

Joining every segment directly after the previous segment can hide a gap and shift the rest of a meeting. The merge path uses segment timing information and validates usable audio before export. Memozia also has an optional reference-based echo-reduction path, but that is not a substitute for verifying routing and input levels on the actual Mac.

These reproduction steps exercise recording; the [workflow tour](../assets/demo/memozia-workflow.mp4) shows the subsequent transcript, summary, and task views with fictional content. Neither the tour nor a single short test establishes reliability across every headset or conferencing app.

## Read and test the implementation

- [Microphone capture](../../Memozia/Services/MicCaptureService.swift)
- [System-audio capture](../../Memozia/Services/SystemAudioCaptureService.swift)
- [Meeting lifecycle and segment coordination](../../Memozia/Services/MeetingRecorderService.swift)
- [Segment timing model](../../Memozia/Models/RecordingSegmentTimeline.swift)
- [Capture health tests](../../MemoziaTests/RecordingCaptureHealthTests.swift) and [timeline tests](../../MemoziaTests/RecordingSegmentTimelineTests.swift)

Build instructions and test invocation are in [BUILDING.md](../BUILDING.md). Automated tests cover specific logic; permissions and physical-device transitions still need a graphical macOS session.

中文要点：麦克风和系统声音分别采集、分别写入，停止后再按时间线校验和合并。先各测一路，再测混合，最后检查设备切换与中断；不能仅凭“正在录音”的状态判定音频完整。复现报告只需提供虚构素材与相关设备信息。
