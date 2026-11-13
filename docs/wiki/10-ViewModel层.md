# 10 · ViewModel 层

[← 返回首页](Home.md) · 源码目录：[Memozia/ViewModels](../../Memozia/ViewModels)

三个业务 ViewModel，全部为 `@MainActor @Observable final class`（Swift 6 并发标注），服务依赖以单例引用方式注入。

| ViewModel | 职责域 |
|-----------|--------|
| [RecordingViewModel](../../Memozia/ViewModels/RecordingViewModel.swift) | 录音/转写/总结/待办全链路（核心枢纽） |
| [QuickNoteViewModel](../../Memozia/ViewModels/QuickNoteViewModel.swift) | 快捷笔记（文字/图片/剪贴板）+ OCR + 总结 + 待办 |
| [SettingsViewModel](../../Memozia/ViewModels/SettingsViewModel.swift) | 全部设置项持久化 + LLM 配置管理 |

## 1. RecordingViewModel — 核心业务枢纽

### 1.1 声明与依赖

```swift
@MainActor @Observable final class RecordingViewModel
```

- `whisperLocalService = WhisperLocalService.shared`：本地转写
- `meetingRecorder = MeetingRecorderService.shared`：**直接暴露给 View 观察**（computed property 不追踪 @Observable 依赖，故用 let 存储属性）
- 可观察状态：转写进度/阶段、导入进度文本、`summaryText`（流式总结缓冲）、`showError`/错误消息、`isMergingAudio`、`selectedRecording` 等
- 音频导入只有工具栏选择与主窗口拖拽两条入口（原 iOS Share Extension inbox 链路已删除）

### 1.2 转写域

| 方法 | 职责 |
|------|------|
| `startTranscription` | 单条转写入口：置 `.processing` → 校验音频 → 系统（SystemTranscription / SystemTranscriptionService，macOS 26+）、本地（WhisperLocalService）或云端（WhisperAPIService）分流 → 更新进度 |
| 转写后处理链 | 固定顺序：说话人分离（可选）→ 繁简归一化 → 词典纠正 → 加密 → 创建 `TranscriptSegment[]` → 转写文件落盘 → 状态 `.completed/.failed`（详见 [05-语音转写与说话人分离](05-语音转写与说话人分离.md) §9） |
| `cancelTranscription` | 取消入口，转发到推理与串行门 |
| `resetStaleProcessingStates` | 启动时把崩溃遗留的 `.processing` 重置为 `.pending`；覆盖 `transcriptionStatus / summaryStatus / visualStatus / todoStatus` 与 `QuickNote` 的 `summaryStatus / todoStatus` |

> **批量入口已移除**：批量转写 / 批量总结的发起入口（`startBatchTranscription` / `startBatchSummary` / `cancelBatch*`）及其 TaskGroup + 信号量并发调度已删除。列表右键只保留「一键处理」（投递到处理队列，见 [02-整体架构](02-整体架构.md) §3.4）；`calculateMaxConcurrency`、`shouldContinueBatchLoop` 等遗留辅助暂无调用方。

### 1.3 总结域

```
generateSummary(recording, llmConfig, …)
  ① 读取 transcriptMarkdown（解密拼接，含缓存）
  ② [云端 && enablePIIScrub] PIIScrubService.scrub → mapping
  ③ LLMService.generateSummary(onToken: 流式追加到 summaryText → UI 实时渲染)
     （onAttemptStart 时清空已展示部分结果，防重试重复拼接）
  ④ PIIScrubService.restore(全文, mapping)
  ⑤ 异常时保存部分摘要（不丢已生成内容）
  ⑥ 加密保存 recording.summary + summary.md 落盘
  ⑦ LLMService.generateTitle 自动生成标题
```

单条总结由处理队列调度（View 层构造 Job 并 `await` 本方法的 Task），不再有批量总结循环。

### 1.4 待办域

```
extractTodos：summary → [PII scrub] → TodoExtractionService.extract
  → PIIScrubService.restore(TodoDocument) → todos.json 加密落盘
  → 用户确认 → RemindersService 写入提醒事项
```

### 1.5 会议录音域

| 成员 | 职责 |
|------|------|
| `meetingRecorder` | 直接暴露服务实例供 View 观察 |
| `isMeetingRecording` / `recordingElapsed` / `isRecordingMuted` / `recordingMuteSource` | UI 绑定计算属性（转发服务状态） |
| `startMeetingRecording(config:context:)` | Task 包裹启动，错误弹窗 |
| `stopMeetingRecording(context:source:)` | `isMergingAudio` + `mergePhase` 标志（转发 `MeetingRecorderService`，界面按「检查分片 → 回声消除 → 混音导出 → 保存」显示进度；仅回声消除阶段经 `cancelEchoReduction()` 提供取消）→ stopRecording → lastError 提示（合并降级/系统音频停止）→ `AudioConverter.getDuration` → 创建 `AudioRecording` + `saveContextWithRetry`（短退避重试，应对长录音合并后瞬时 fd 耗尽）→ `saveMetaToFolder` → 选中展示 |

### 1.6 数据管理域

- **导入**：拖拽（RootView handleDrop，`AudioImportValidator` 校验扩展名+真实音频类型）、文件选择
- **删除**：先加载 TodoDocument 清理提醒事项残留 → 先删磁盘文件夹 → 后删 DB 记录（文件删除失败保留记录防"复活"）；单删/批删均弹确认
- **合并录音**：`orderedMergeCandidates` 校验至少两笔纯录音并按创建时间排序（同时间用 ID 稳定排序）；`mergeRecordings` 在用户确认后把完整快照交给 `RecordingMergeService`。实际音轨时长决定拼接点与转写偏移，总结按顺序拼接、待办保留提醒事项标识。暂存完整目标目录，经镜像成功与音频校验后原子交换；索引保存失败回滚，成功后才删较早条目。删除失败保留剩余条目并提示，目标内的合并来源 ID 防止重复拼接。旧式根目录录音可参与合并；最新条目若无独立目录，用 `createUniqueFolder` 原子分配并迁入月份目录。
- **编辑**：segment 文本编辑、说话人改名（声纹注册入口）、`invalidateTranscriptCache` 失效缓存
- **导出**：转写/总结导出 txt/md（ExportDocuments）、录音文件分享（NSSharingServicePicker 锚定主窗口弹出）

## 2. QuickNoteViewModel — 快捷笔记

### 2.1 职责

无录音场景的速记中心：文字/图片/剪贴板三种来源，AI 总结与待办提取。

### 2.2 关键方法

| 方法 | 职责 |
|------|------|
| 剪贴板笔记 | 读取 `NSPasteboard` 图片/文字 → 建笔记（仅 macOS） |
| `createQuickNoteFromClipboard` | 剪贴板文本/图片一键建笔记（菜单栏入口） |
| `createQuickNote(fromImage:)` | **截图入库主路径**（RootView 调用） |
| AI 总结 | 图片笔记：`supportsVision` 走 `generateSummaryFromImage` 多模态，否则先 OCR；文字笔记：文本总结；均流式渲染 + 加密保存 + 自动标题 |
| 待办提取 | 优先文字内容（文字+OCR 合并），无文字时从图片提取；支持 PII 脱敏 |
| 删除/重命名 | 同录音删除协议（先磁盘后 DB） |

## 3. SettingsViewModel — 设置持久化

### 3.1 职责域

| 分组 | 内容 |
|------|------|
| STT | 模式（系统/本地/云端，系统模式仅在支持时显示）、模型文件夹（默认 `~/Documents/Memozia/WhisperModel`）、云端 API URL/Key、语言 |
| 说话人分离 | 开关、模型路径（默认 `DiarizationModel`）、声纹识别开关 |
| 词典 | 纠正开关、PII 脱敏开关 |
| LLM | 多套配置 CRUD、当前生效配置 |
| 录音 | 来源（mic/systemAudio/mixed）、静音选项 |
| 捕获 | 屏幕录制权限、默认模式、录屏声源/质量偏好 |
| 热键 | 录音 / 截图 / 全屏直拍三条全局热键的录制与恢复默认（独立页面，见 [系统集成](09-系统集成服务.md) §2） |
| 体验模式 | 普通模式的会议场景、独立 Whisper 路径；Pro 原始设置保留不变 |

### 3.2 持久化机制

- **读取**：启动时逐项从 UserDefaults 加载；Whisper API Key 从 **Keychain**（KeychainAccess）读取
- **保存**：修改即写回 UserDefaults；API Key 写 Keychain（不落 UserDefaults）
- **配置转换**：`makeSTTConfig(experience:)` / `makeRecordingConfig(experience:)` 先生成已保存配置，再经 `EffectiveSettingsResolver` 得到当前模式的有效配置；解析过程不回写 Pro 设置。`getActiveLLMConfig` 在保存 ID 失效时稳定回退到现存第一个配置；`setActiveLLMConfig` 是**唯一**的活动模型入口——设置页与录音/笔记详情页的模型选择器都调它（写 ID 后 `saveSettings`），因此「活动模型」只有一份事实源，重开条目或重启应用后选择保持一致。

## 4. View ↔ ViewModel 绑定关系

| View | 依赖的 VM |
|------|-----------|
| RootView | RecordingViewModel（主依赖）+ QuickNoteViewModel + SettingsViewModel |
| RecordingListView | 经 RootView 传入 RecordingViewModel（删除/重命名/批量操作） |
| RecordingDetailView | RecordingViewModel（转写/总结/待办/画面理解） |
| TranscriptView | RecordingViewModel（编辑/缓存失效/声纹注册） |
| SummaryView | RecordingViewModel（summaryText 流式/重新生成/待办） |
| VideoUnderstandingView | RecordingViewModel（visualNotesText 流式/取消/持久化），管线委托 VideoUnderstandingService |
| QuickNoteDetailView | QuickNoteViewModel |
| SettingsView | SettingsViewModel |
