# How Memozia works

These implementation notes follow the path from capture to reviewed meeting notes. Each includes source links and a small reproduction procedure using fictional content.

| Article | What you can reproduce |
| --- | --- |
| [Local meeting notes with WhisperKit and Ollama](local-meeting-notes.md) | Connect a local speech model and a local summary service, then check a short meeting against the source audio. |
| [Recording microphone and system audio on macOS](macos-audio-capture.md) | Check the two inputs separately, then verify their timeline in a mixed recording. |
| [Segmented recording, recovery, and long-meeting transcription](long-recording-recovery.md) | Observe rolling capture segments and test recovery with an isolated development workspace. |

[45-second workflow tour](../assets/demo/memozia-workflow.mp4) · [Download the preview](https://github.com/oceanix-pr/Memozia/releases) · [Build from source](../BUILDING.md) · [Contribute](../../CONTRIBUTING.md)

The screenshots and tour show the real app with prepared fictional content. They illustrate the workflow and are not accuracy, throughput, or recovery benchmarks. Model-dependent steps below are reproduction instructions, not a claim that every model or device has been tested.

中文导读：三篇文章分别讲本地模型接入、麦克风与系统声音采集、长录音分片与恢复。每篇末尾提供中文要点；具体实现以链接到的源码为准。
