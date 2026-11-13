# 技术债与待验证事项

仅在相关整改任务中读取。由历史审查记录提炼，2026-09-15 整理；“待复核”不是断言当前仍有缺陷，执行前先查源码与复现证据。

## 已确认的边界

| 项目 | 现状与后续方向 | 定位 |
|---|---|---|
| 启动握手与数据库独占 | 已改为 `DatabaseOwnershipLock`（flock）：主应用以「能否取得独占锁」为唯一接管判据，拿不到就不打开可写容器（退化内存 + 提示用户不落盘）；worker 先取锁再开容器。PID 标记包含启动时间与可执行路径，拒绝复用 PID。握手仍在 App 初始化期同步等待（宽限 3s + SIGTERM 后 2s），异步化与进度展示未做 | `BackgroundWorker.handshakeAndWaitForWorkerExit`、`DatabaseOwnershipLock`、`MemoziaApp` |
| 队列文件互斥 | 已有界等待并明确失败（不再无锁执行、不再忽略 flock 返回值）；损坏区分「文件不存在」与「读不出」，隔离为 `.corrupt-*` + 从 `.bak` 恢复 + 经 `PersistenceReporting` 上报。回归见 `MemoziaTests/BackgroundTaskQueueTests.swift` | `BackgroundTaskQueue.mutate` / `acquireLock` / `recoverFromCorruption` |
| worker 调度 | 队列主循环保留 semaphore 轮询并驱动 RunLoop；接管请求在任务边界检查。改动需验证取消、续跑和主线程回调 | `BackgroundWorker.run` / `drainQueue` |
| MainActor 桥接 | `MainActor.assumeOnMainThread` 的 unsafeBitCast / precondition 是规避 executor 问题的既有取舍；替换前在受影响 macOS 上复现验证 | `Services/MainActor+AssumeOnMainThread.swift` |
| iCloud | CloudKit 容器同步配置尚未启用；本地保存成功不能视为远端同步成功 | `MemoziaApp`、`CloudSyncService` |

## 历史审查遗留，逐项复核后排期

- `FileSyncService.syncFromDisk`：顶层目录枚举、视频证据检查和镜像 stat 已移出 MainActor，镜像已双向补齐并显式保存；新增空库快速通道（`fetchCount` 探测为空时跳过两次全表 fetch）；恢复标记的探测也已并入后台批量（`probe(_:)`），消除了对账循环里每条目 3~4 次的 MainActor `stat`。**主线程阻塞已可测**：`--verify-filesync` 新增心跳探针（`mainThreadMaxBlockMs` / `mainThreadBlockedOverThreshold`）。**生产同构口径**（持久容器 + 与生产一致的分工）下基线为：200 条目单次阻塞 ≤6ms、1000 条目 ≤23ms（0 次 ≥50ms）、**10000 条目首轮 33ms / 0 次 ≥50ms（总 6.7s）与次轮 34ms / 0 次（无插入，总 2.60s）**（见 `Scripts/runtime_verify/benchmark_filesync.sh` 头部）。**结论：规模决定一切，但各规模均已达标**——≤10k 条目下单次主线程阻塞 ≤34ms、0 次 ≥50ms。归因：首轮（库空跳过全表 fetch）的阻塞来自**插入路径**（每条目一次 `folderIsPersisted` 存在性查询 ⇒ 10k 条目 ≈ 20k 次查询）；次轮（无插入）来自**全表 fetch + 字典物化**（10k 模型）。**已修：逐条存在性查询合批**为对候选集的分块查询（`persistedFolderNames`，500/批，避开 SQLite 绑定参数上限）——10k 首轮 **41.9s → 6.7s、最大阻塞 558ms → 37ms、≥50ms 82 次 → 0 次**（入库数不变、无保存失败）。**已修：镜像探测目标的构建移出主线程**——此前在主线程 `.map` 构建 10k 个 `RecordingMirrorTarget`（每条 3 个 URL，每个 URL 走一次 `resolveFolderURL` 的 `fileExists`，合计 ≈4 万次系统调用叠成一段同步阻塞），现只把 `folderName` 字符串带出 MainActor、在后台任务里解析并 stat（`RecordingMirrorTarget.forFolder(named:)`）；次轮 **418ms / 44 次 → 202ms / 13 次**。次轮剩余的单块是**同步全表 `fetch`**（10k 模型物化，实测 201ms，`Task.yield()` 无法切分 `fetch` 调用本身）。**注意此前记录的 148ms/10 次是 harness 假象**，由两处造成并已修掉：① 用内存容器当代理（其 fetch/save 成本与实际 SQLite 文件不同，同机同规模会报到 116ms/6 次）；② harness 曾在主线程内联执行 `TodoCountIndex` 的逐目录 stat，而生产里这步在 `Task.detached` 中。**已修：全表 fetch 分页**——按 `folderName` 做 keyset 分页（`folderName > 游标` + `fetchLimit` + 每页间 `Task.yield()`，`folderName` 一目录一条故为全序），把单次 201ms 的 `context.fetch` 拆成每页物化的量级：10k 次轮 **202ms / 13 次 → 34ms / 0 次**，条目集合与顺序无关、语义等价（`discovered`/`inserted` 计数与保存结果不变；总耗时 2.60s 略高于整表 2.46s，为分页开销）。**写方向也已可验证**：`--verify-filesync` 支持 `--db <dir>`（落在隔离目录的持久容器，多次运行共享同一份库），且 CLI 退出前显式 `flush` 镜像写入器（`FileSyncService` 自身不 flush，应用侧由退出流程、worker 在 drain 末尾 flush）——已验证「删掉 summary.md → 再对账 → 按库内容补写回来」。**已试并否决：把深度修复延后到首屏之后**（曾加临时阶段开关，实测后已回退，生产仍为完整对账）。拆分会多一次全表 fetch（总耗时 +16%），而修复循环原本每 20 条的 `Task.yield()` 还起到主线程让出作用；在阻塞源头（见上：全表 fetch 而非修复）认清之前，这条路收益为负。全表 SwiftData 物化本身已用 keyset 分页解决（见上），**未做** ModelActor 迁移；仍留在主线程的是逐条关系访问与插入路径：对账里「库有转写」分支会读 `recording.segments`（每条一次关系 fault），插入路径按条写库。本次 10k 语料不含转写，故未触发 segments fault；**含大量转写的库需另测**，如出现单块回升，优先把该分支改为按需/批读取，其次才考虑整体迁入后台 ModelContext（需跨上下文合并与插入路径的一致改造）。
- `RecordingListView`：待办数量索引已由「每次数据源变化/待办通知都全库解密解析」改为按 `todos.json` mtime 的增量对账（`EntryTodoCount` / `TodoCountIndex`，未变化目录复用缓存）。`.todoDocumentDidChange` 现携带文件夹名（`TodoDocument.postDidChange`），列表据此只重算该条目（`TodoCountIndex.reconcileOne`），全库逐个 stat 只在数据源变化或无负载通知时发生。总结存在性与预览派生缓存、列表 `.id` 和隐藏状态观察导致的刷新范围仍待处理。
- `EntryMirrorStore`：合并写入、退出 flush、`writeNow` 的取消与 30s 超时已落地；`flush` 仍只有 10s 上限，超时记 fault 后继续退出，长转写（数十 MB JSON）在极慢磁盘上仍可能截断，评估按剩余量动态放宽或分片写入。
- `SpeakerDiarizationService`：音频解码和簇精修已补取消检查，sherpa-onnx 单次 native 推理仍不可中断；超过 30 分钟或估算 256 MB 的音频**已按 8 分钟 + 30 秒重叠分段**，残余项是「单段推理不可取消」（取消需等当前分段结束）与分段身份合并的内存峰值仍需继续量测。
- `MarkdownView`：总结流式阶段现使用纯文本，完成后才解析 Markdown；后续只需关注超长已完成文档的全文解析与列表构建。
- `TextFindReplace`：逐字符重刷高亮、全文比较定位编辑器的开销。
- `RecordingListView`：总结存在性与预览派生缓存、列表 `.id` 和隐藏状态观察导致的刷新范围。
- `RecordingDetailView`：播放进度定时更新是否导致整个详情树重算，评估播放器子视图隔离。
- `OverlayAnnotationView`：`dirtyRect` 局部重绘与冻结图烘焙，需肉眼确认标注正确性与拖拽帧率。
- 菜单栏定时器保留 `.common` RunLoop 模式及 MainActor 跳板；优化时须验证菜单展开期间仍更新。
- iOS 支持已整体取消：主应用与测试均为 macOS 单平台，iOS Share Extension 与 App Group inbox 链路已删除，不再需要双平台构建验证。
- 测试：旧报告中的失效模型枚举与不可构造 WriteConfiguration 断言已有后续修改，不再认定测试 target 必然不能编译；以实际 `xcodebuild test` 结果判断。

## 回归场景（按改动选择）

1. 录音中静音、切换/拔出设备、分片轮转、睡眠唤醒后继续；停录混音可播放且双轨对齐。
2. 在隔离测试数据上模拟录音/合并中断；恢复成功，无法读取的音频及无分片可重建的损坏原件不被误删。
3. worker 转写中启动主应用：交接、剩余队列续跑、异常终止、双实例、队列清空退出；单独覆盖 SIGTERM 无响应分支。
4. 本地模型加载/卸载/取消、门闸排队取消、1–2 小时分离的内存峰值；不将分块读取误当成零整段样本内存。
5. 三个以上大音频同时云转写：临时分片不串台；请求退避中取消后不继续发送。
6. OCR 降级、连续截图、马赛克拖拽；词典保存/删除后更新、过期扫描不覆盖新扫描。
7. 菜单栏录音状态在刷新周期内变化；磁盘检查经历 tick 漂移或唤醒仍执行，低磁盘止损走正常保存流程。
8. Keychain / 加密 / 数据库写入失败：有可见告警，读旧明文与密文行为正确，日志不泄露正文或密钥。

自动化覆盖入口见 [构建与运行](wiki/13-构建与运行.md)。历史语法/类型检查结果不作为当前构建、签名或真机验证证据。
