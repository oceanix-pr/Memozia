import Testing
import Foundation
import SwiftData
@testable import Memozia

/// 稳定性/性能回归测试
///
/// 覆盖本次 code_review 落地中"最容易再次退化"的几处纯逻辑：
/// 1. `RacingWatchdog` 必须能在被等操作永久挂起时**真正按时返回**
///    （旧版 `withThrowingTaskGroup` 写法会在离开作用域时 join 挂起的子任务，看门狗形同虚设）；
/// 2. `CancellableGate` 排队必须响应取消（旧版用不响应取消的续体排队，
///    持锁者挂起会让全部排队者一起悬挂并泄漏各自捕获的闭包）；
/// 3. `TokenCoalescer` 流式合批与收尾 flush 语义（丢尾块会让最后几个字永不显示）；
/// 4. `mergeExportTimeout` 单调且有上限（退出等待时长与它同源）；
/// 5. 录音时长文本格式化（从 RootView 抽成独立子视图后的等价性）。
struct StabilityRegressionTests {

    // MARK: - 看门狗：超时必须能真正脱离

    @Test(arguments: [0.05, 0.2])
    func raceReturnsOnTimeoutEvenWhenOperationHangs(timeout: TimeInterval) async {
        let started = Date()
        // 被等操作模拟"不响应协作取消的挂起"：睡 30 秒且忽略取消
        let finished = await RacingWatchdog.race(
            name: "挂起的导出",
            timeout: timeout
        ) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let elapsed = Date().timeIntervalSince(started)

        #expect(!finished, "操作挂起时 race 必须返回 false")
        // 关键断言：没有 join 孤儿任务，耗时只由 timeout 决定
        // （留 2 秒余量避免 CI 抖动，同时远小于被等操作本身的 30 秒）
        #expect(elapsed < timeout + 2.0, "超时后必须立即返回，实测等待 \(elapsed)s")
    }

    @Test func raceReturnsTrueWhenOperationCompletes() async {
        let box = LockedBox<Bool>(false)
        let finished = await RacingWatchdog.race(
            name: "正常导出",
            timeout: 10
        ) {
            box.value = true
        }
        #expect(finished)
        #expect(box.value, "操作结果必须在超时前已写入盒子")
    }

    @Test func raceInvokesOnTimeoutCallback() async {
        let flagged = LockedBox<Bool>(false)
        let finished = await RacingWatchdog.race(
            name: "模型加载",
            timeout: 0.05,
            onTimeout: { flagged.value = true }
        ) {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        #expect(!finished)
        #expect(flagged.value, "超时回调必须触发（调用方靠它标记放弃/卸载孤儿资源）")
    }

    @Test func raceReturnsImmediatelyWhenAlreadyCancelled() async {
        let task = Task {
            await RacingWatchdog.race(name: "被取消的操作", timeout: 30) {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        // 留出启动时间后取消：调用方取消必须能立即脱身，而不是等满 30 秒
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let finished = await task.value
        #expect(!finished)
    }

    @Test func raceInvokesCancellationCallbackOnlyWhenCancellationWins() async {
        let cancelled = LockedBox(false)
        let timedOut = LockedBox(false)
        let task = Task {
            await RacingWatchdog.race(
                name: "取消中的模型加载",
                timeout: 30,
                onTimeout: { timedOut.value = true },
                onCancel: { cancelled.value = true }
            ) {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        #expect(await task.value == false)
        #expect(cancelled.value, "取消胜出时必须标记孤儿资源，供模型加载完成后自行卸载")
        #expect(!timedOut.value, "用户取消不能被误记为超时")
    }

    @Test func completedRaceDoesNotInvokeLateTimeoutCallback() async {
        let timedOut = LockedBox(false)
        let finished = await RacingWatchdog.race(
            name: "立即完成",
            timeout: 0.05,
            onTimeout: { timedOut.value = true }
        ) {}
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(finished)
        #expect(!timedOut.value, "完成结果胜出后，迟到计时器不得覆盖结果或触发清理")
    }

    // MARK: - 串行门：排队者必须能被取消

    @Test func gateCancelsQueuedWaiterInsteadOfHangingForever() async throws {
        let gate = CancellableGate()

        // 一路持锁且不自行结束（模拟旧版会让全队列悬挂的场景）
        let holder = Task {
            try await gate.acquire()
            try? await Task.sleep(nanoseconds: 400_000_000)
            await gate.release()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // 确保 holder 已持锁

        let queued = Task {
            try await gate.acquire()
            await gate.release()
        }
        try await Task.sleep(nanoseconds: 50_000_000)   // 确保 queued 已入队
        queued.cancel()

        // 排队者应在有界时间内抛错返回（旧实现会永久悬挂）
        let outcome = await queued.result
        let didFail: Bool
        switch outcome {
        case .success: didFail = false
        case .failure: didFail = true
        }
        #expect(didFail, "被取消的排队者必须抛错返回，而不是无限等待")

        _ = try await holder.value    // holder 正常走完并释放
        // 门仍可用：能再次获取并释放
        try await gate.acquire()
        await gate.release()
    }

    /// 已取消的调用方不得占门：这是最容易写错的一处——先占门再检查取消会抛错退出，
    /// 但门已被占下且无人释放，整条队列从此永久锁死。
    @Test func cancelledAcquirerBeforeEnteringDoesNotOccupyGate() async throws {
        let gate = CancellableGate()
        let preCancelled = Task {
            try await gate.acquire()
            await gate.release()
        }
        preCancelled.cancel()
        let outcome = await preCancelled.result
        let didFail: Bool
        switch outcome {
        case .success: didFail = false
        case .failure: didFail = true
        }
        #expect(didFail, "已取消的获取必须失败返回")

        // 关键断言：门必须仍可用（若被取消者占门不放，这里会永久挂起 → 测试超时）
        let usable = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                (try? await gate.run { true }) ?? false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(usable, "取消者不得留下占门状态")
    }

    @Test func gateSerializesConcurrentRuns() async {
        let gate = CancellableGate()
        let counter = LockedBox<Int>(0)
        let concurrentPeak = LockedBox<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await gate.run {
                        let now = counter.value + 1
                        counter.value = now
                        concurrentPeak.value = max(concurrentPeak.value, now)
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        counter.value = counter.value - 1
                    }
                }
            }
        }
        // 门未被正确串行化时峰值会 >1（WhisperKit 并发 transcribe 的竞态崩溃来源）
        #expect(concurrentPeak.value <= 1, "同一时刻最多一路执行，实测峰值 \(concurrentPeak.value)")
    }

    // MARK: - 流式 token 合批

    @Test func coalescerBatchesWithinWindowAndFlushesTail() {
        let received = LockedBox<[String]>([])
        let coalescer = TokenCoalescer(interval: 5) { chunk in
            // interval 取 5 秒：本用例只验证"窗口内合批 + flush 交付尾块"，与真实时序无关
            var current = received.value
            current.append(chunk)
            received.value = current
        }

        // 首个 token 立即交付（保证"点了就有反馈"），后续在窗口内合批
        coalescer.receive("你")
        #expect(received.value == ["你"])

        coalescer.receive("好")
        coalescer.receive("，")
        // 窗口未到：不得再产生回调（否则就退化成逐 token 灌主队列）
        #expect(received.value.count == 1)

        coalescer.flush()
        #expect(received.value == ["你", "好，"], "flush 必须把不足一个窗口的尾块整批交付")
        #expect(received.value.joined() == "你好，")

        // flush 之后再 flush 不应重复交付
        coalescer.flush()
        #expect(received.value.count == 2)
    }

    @Test func coalescerEmitsWhenWindowElapses() async {
        let received = LockedBox<[String]>([])
        let coalescer = TokenCoalescer(interval: 0.02) { chunk in
            var current = received.value
            current.append(chunk)
            received.value = current
        }
        coalescer.receive("a")
        try? await Task.sleep(nanoseconds: 60_000_000)
        coalescer.receive("b")
        coalescer.flush()

        // 窗口过后应分批交付（首批 + 过窗后的第二批 + 尾块），而不是一次性堆积到最后
        #expect(received.value.count >= 2)
        #expect(received.value.joined() == "ab", "分批内容拼接后必须与逐 token 结果一致")
    }

    // MARK: - 导出超时上限（退出等待与之同源）

    @Test(arguments: stride(from: 0.0, through: 20 * 3600, by: 1800.0).map { $0 })
    func mergeExportTimeoutIsMonotonicAndCapped(duration: TimeInterval) {
        let timeout = FileSyncService.mergeExportTimeout(estimatedAudioDuration: duration)
        #expect(timeout >= 600, "任何素材都至少给 10 分钟基础窗口")
        #expect(timeout <= 3600, "必须有硬上限，否则退出等待无法收敛")
        #expect(
            FileSyncService.mergeExportTimeout(estimatedAudioDuration: duration + 3600) >= timeout,
            "更长素材的窗口不应更短"
        )
    }

    @Test(arguments: stride(from: 0.0, through: 20 * 3600, by: 1800.0).map { $0 })
    func echoReductionTimeoutIsMonotonicAndCapped(duration: TimeInterval) {
        let timeout = FileSyncService.echoReductionTimeout(estimatedAudioDuration: duration)
        #expect(timeout >= 300, "任何素材都至少给 5 分钟基础窗口")
        #expect(timeout <= 1800, "必须有硬上限，否则停录收尾无法收敛")
        #expect(
            FileSyncService.echoReductionTimeout(estimatedAudioDuration: duration + 3600) >= timeout,
            "更长素材的窗口不应更短"
        )
    }

    // MARK: - 录音时长文本（已从 RootView 抽成独立子视图）

    @Test(arguments: [
        (0.0, "00:00"),
        (59.0, "00:59"),
        (60.0, "01:00"),
        (600.0, "10:00"),
        (3600.0, "1:00:00"),
        (3725.0, "1:02:05"),
        (-5.0, "00:00"),
    ])
    @MainActor
    func recordingElapsedFormatting(seconds: TimeInterval, expected: String) {
        #expect(RecordingElapsedLabel.formatted(seconds) == expected)
    }

    // MARK: - 词典纠正快照：纯函数等价性（纠正已移出 MainActor）

    @Test func correctionSnapshotEmptinessDrivesEarlyExit() {
        // correct() 在快照为空时直接原样返回，避免每次纠正都进后台任务
        #expect(CorrectionSnapshot(pairs: [], terms: []).isEmpty)
        #expect(!CorrectionSnapshot(
            pairs: [CorrectionSnapshot.Pair(wrong: "与义笔记", correct: "语忆笔记")],
            terms: []
        ).isEmpty)
        #expect(!CorrectionSnapshot(
            pairs: [],
            terms: [CorrectionSnapshot.Term(text: "语音", chars: ["语", "音"], pinyins: ["yu", "yin"])]
        ).isEmpty)
    }
    // MARK: - 批次 1/2：节拍器、分片临时目录、保存失败账本、词典后台扫描

    /// 磁盘巡检节拍的回归点：旧写法 `Int(elapsed) % 30 == 0` 要求 1s 定时器**正好**落在
    /// 30 的整数倍上；定时器漂移或漏 tick（29.4s → 31.2s）会让这一轮完全不命中。
    @Test func timePacerFiresWithoutPerfectAlignment() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var pacer = TimePacer(interval: 30, lastFiredAt: base)

        // 漂移的两个 tick：旧写法 Int(29.4)=29、Int(31.2)=31，%30 均不为 0 → 整段漏检
        let firedBeforeInterval = pacer.fireIfNeeded(at: base.addingTimeInterval(29.4))
        #expect(!firedBeforeInterval, "未到间隔不应放行")
        let firedAfterInterval = pacer.fireIfNeeded(at: base.addingTimeInterval(31.2))
        #expect(firedAfterInterval, "超过间隔必须放行，哪怕没落在整数倍上")

        // 放行后基准应推进：紧接着的 tick 不应再次放行（否则每次 tick 都 stat 磁盘）
        let firedImmediatelyAgain = pacer.fireIfNeeded(at: base.addingTimeInterval(32.0))
        #expect(!firedImmediatelyAgain)
        let firedAtNextInterval = pacer.fireIfNeeded(at: base.addingTimeInterval(61.5))
        #expect(firedAtNextInterval)
    }

    @Test func timePacerFiresImmediatelyWithoutBaseline() {
        var pacer = TimePacer(interval: 30, lastFiredAt: nil)
        let fired = pacer.fireIfNeeded(at: Date())
        #expect(fired, "未建立基准时应立即放行一次")
    }

    /// 分片临时文件必须按调用隔离：云端批量转写是 3 路并发，
    /// 旧的固定名 `chunk_<起始秒>.m4a` 会让两个录音互相覆盖/互删对方正在上传的文件。
    @Test func chunkScratchDirectoriesAreUniquePerCall() {
        let a = WhisperAPIService.chunkScratchDirectory()
        let b = WhisperAPIService.chunkScratchDirectory()
        #expect(a != b, "两次调用不得落在同一目录")
        #expect(a.lastPathComponent.hasPrefix("Memozia-chunk-"))
        // 关键：不得再直接落在 temporaryDirectory 下用可预测的文件名
        #expect(a.deletingLastPathComponent() != FileManager.default.temporaryDirectory)
    }

    @Test func cancelledBatchLoopStopsWithUnsubmittedItems() {
        #expect(!RecordingViewModel.shouldContinueBatchLoop(
            nextIndex: 2, total: 10, activeTasks: 0, isCancelled: true
        ))
        #expect(!RecordingViewModel.shouldContinueBatchLoop(
            nextIndex: 2, total: 10, activeTasks: 3, isCancelled: true
        ))
        #expect(RecordingViewModel.shouldContinueBatchLoop(
            nextIndex: 2, total: 10, activeTasks: 0, isCancelled: false
        ))
        #expect(RecordingViewModel.shouldContinueBatchLoop(
            nextIndex: 10, total: 10, activeTasks: 1, isCancelled: false
        ))
    }

    @Test func workerIdentityRejectsPIDReuseAndDifferentExecutable() {
        let recorded = BackgroundWorker.ProcessIdentity(
            pid: 42,
            startSeconds: 100,
            startMicroseconds: 10,
            executablePath: "/Applications/Memozia.app/Contents/MacOS/Memozia"
        )
        #expect(BackgroundWorker.identitiesMatch(recorded: recorded, actual: recorded))
        #expect(!BackgroundWorker.identitiesMatch(
            recorded: recorded,
            actual: BackgroundWorker.ProcessIdentity(
                pid: 42,
                startSeconds: 101,
                startMicroseconds: 10,
                executablePath: recorded.executablePath
            )
        ), "同一 PID 被复用后启动时间不同，必须拒绝")
        #expect(!BackgroundWorker.identitiesMatch(
            recorded: recorded,
            actual: BackgroundWorker.ProcessIdentity(
                pid: 42,
                startSeconds: 100,
                startMicroseconds: 10,
                executablePath: "/usr/bin/other"
            )
        ), "无关可执行文件不得被当作 worker")
    }

    @Test func diskToDatabaseMirrorRestoreRequiresExplicitSave() {
        #expect(FileSyncService.shouldSaveMirrorReconciliation(
            repairedDiskMirrorCount: 0,
            restoredDatabaseFromMirrors: true
        ), "仅发生磁盘 → 数据库恢复时也必须 context.save()")
        #expect(FileSyncService.shouldSaveMirrorReconciliation(
            repairedDiskMirrorCount: 1,
            restoredDatabaseFromMirrors: false
        ))
        #expect(!FileSyncService.shouldSaveMirrorReconciliation(
            repairedDiskMirrorCount: 0,
            restoredDatabaseFromMirrors: false
        ))
    }

    /// 保存失败：每次都记数，但只提示一次（否则批量转写失败会弹几十个窗）
    @Test func failureLedgerNotifiesOnceButCountsEveryFailure() {
        let ledger = FailureNoticeLedger()
        #expect(ledger.record(scene: "startTranscription()"))
        #expect(!ledger.record(scene: "markVoiceprint()"))
        #expect(!ledger.record(scene: "resetStaleProcessingStates()"))
        #expect(ledger.failureCount == 3)
        #expect(ledger.lastScene == "resetStaleProcessingStates()")
        ledger.reset()
        #expect(ledger.record(scene: "再来一次"))
    }

    /// 词典扫描（目录枚举 + 解析）已改为 nonisolated：可在后台执行器调用，
    /// 并且缺目录/空目录必须安全返回空结果而不是崩溃
    @Test func dictionaryScanWorksOffMainActor() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Memozia-dict-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("测试词典.md")
        try? TranscriptDictionaryService.sampleMarkdown.write(
            to: file,
            atomically: true,
            encoding: .utf8
        )

        // 显式在后台执行器调用：若 scan 仍被推导为 MainActor，这行会走不到结果
        let result = await Task.detached(priority: .background) {
            TranscriptDictionaryService.scan(folderURL: dir)
        }.value
        #expect(result.files.count == 1)
        #expect(!result.pinyinTerms.isEmpty, "示例词典应解析出可用于拼音纠正的术语")

        let missing = await Task.detached(priority: .background) {
            TranscriptDictionaryService.scan(folderURL: dir.appendingPathComponent("不存在"))
        }.value
        #expect(missing.files.isEmpty)
        #expect(missing.exactPairs.isEmpty)
    }

    // MARK: - 系统语音识别（SpeechAnalyzer）接入

    /// 新增的 .system 必须能按原始值往返：后台任务队列用 rawValue 序列化 STT 快照，
    /// 且未知值仍退化为 .local，避免跨版本快照把模式丢成空值
    @Test func systemSTTModeSurvivesSnapshotRoundTrip() {
        #expect(STTMode(rawValue: "system") == .system)
        #expect(STTMode(rawValue: STTMode.system.rawValue) == .system)
        #expect(STTMode(rawValue: "some-future-mode") == nil)
        #expect((STTMode(rawValue: "some-future-mode") ?? .local) == .local)
    }

    /// 设置界面的可选模式必须与系统能力一致：macOS 26 以下不得出现 .system，
    /// 且系统语音识别必须排在本地 WhisperKit 之前
    @Test func selectableSTTModesFollowSystemCapability() {
        #expect(STTMode.selectableCases.contains(.local))
        #expect(
            STTMode.selectableCases.contains(.system) == SystemTranscription.isSupported,
            "系统语音识别的可选项必须与 #available 判定一致"
        )
        if SystemTranscription.isSupported {
            #expect(STTMode.selectableCases == [.system, .local], "系统语音识别应排在最前")
        } else {
            #expect(STTMode.selectableCases == [.local])
        }
    }

    /// 默认模式：macOS 26 起为系统语音识别，低版本回退本地 WhisperKit
    @Test func defaultSTTModeFollowsSystemCapability() {
        #expect(
            STTMode.defaultMode == (SystemTranscription.isSupported ? .system : .local),
            "默认转写模式必须与 #available 判定一致"
        )
    }

    /// OpenAI Whisper API 已从选择器隐藏：不再作为新选择提供；
    /// 但已保存该模式的用户必须仍能在列表里看到它，否则会出现悬空选中态
    @Test func hiddenCloudModeStaysVisibleForExistingSelection() {
        #expect(!STTMode.selectableCases.contains(.cloud))
        #expect(!STTMode.pickerModes(current: .local).contains(.cloud))
        #expect(!STTMode.pickerModes(current: .system).contains(.cloud))
        // 已保存的隐藏模式补在首位，其余可选模式顺序不变
        #expect(STTMode.pickerModes(current: .cloud) == [.cloud] + STTMode.selectableCases)
        // 未被隐藏的模式不得被重复追加
        #expect(STTMode.pickerModes(current: .local).filter { $0 == .local }.count == 1)
    }

    /// 系统语音识别没有自动语种检测：空值表示跟随系统语言；
    /// 中文与粤语统一落到简体中文（系统无粤语模型），其余语言沿用自身代码
    @Test func systemLocaleMappingFromLanguageSetting() {
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: "") == nil)
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: WhisperLanguage.zh.rawValue) == "zh_CN")
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: WhisperLanguage.zhYue.rawValue) == "zh_CN")
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: "yue") == "zh_CN")
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: WhisperLanguage.en.rawValue) == "en")
        #expect(STTConfig.systemLocaleIdentifier(forLanguage: WhisperLanguage.ja.rawValue) == "ja")
    }

    // MARK: - 流式合批：字符阈值触发（E3）

    /// 字符阈值与时间窗口取先到者：本地模型几十毫秒就能吐出一大段，
    /// 只等时间窗口会让首屏空等；达到阈值必须立即整批交付，且拼接结果与逐 token 一致。
    @Test func coalescerFlushesWhenCharacterThresholdReached() {
        let received = LockedBox<[String]>([])
        let coalescer = TokenCoalescer(interval: 5, maxBufferedCharacters: 6) { chunk in
            var current = received.value
            current.append(chunk)
            received.value = current
        }

        // 首个 token 立即交付（保证"点了就有反馈"）
        coalescer.receive("12345")
        #expect(received.value == ["12345"])

        // 窗口未到（5s）但累计字符已达阈值 → 立即整批交付，不再堆积
        coalescer.receive("6789012")
        #expect(received.value == ["12345", "6789012"])
        #expect(received.value.joined() == "123456789012", "合批内容拼接后必须与逐 token 结果一致")
    }

    // MARK: - 待办数量索引（E2）

    /// 统计口径：已完成 = 已写入提醒事项（exported），其余计入未完成；
    /// 空文档不入索引（等同未拆待办），保证列表「已拆待办」徽标判据不变
    @Test func todoCountIndexCountsOpenAndCompleted() {
        let items = [
            TodoItem(title: "a", status: .pending),
            TodoItem(title: "b", status: .exported),
            TodoItem(title: "c", status: .failed)
        ]
        let entry = TodoCountIndex.make(entryID: "20260101090000", items: items, modificationDate: nil)
        #expect(entry?.totalCount == 3)
        #expect(entry?.openCount == 2)
        #expect(entry?.completedCount == 1)
        #expect(entry?.entryID == "20260101090000")

        #expect(TodoCountIndex.make(entryID: "x", items: [], modificationDate: nil) == nil)
    }

    /// mtime 判定：仅当 todos.json 修改时间发生变化（或文件新增/删除）才需要重算，
    /// 未变化的目录复用缓存——这是"避免每次通知都全库解密解析"的关键
    @Test func todoCountIndexNeedsRefreshFollowsModificationDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cached = EntryTodoCount(
            entryID: "f", openCount: 1, completedCount: 0, sourceModificationDate: date
        )
        #expect(!TodoCountIndex.needsRefresh(cached: cached, modificationDate: date),
                "mtime 未变不应重算")
        #expect(TodoCountIndex.needsRefresh(cached: cached, modificationDate: date.addingTimeInterval(1)),
                "mtime 变化必须重算")
        #expect(TodoCountIndex.needsRefresh(cached: cached, modificationDate: nil),
                "文件被删除必须重算（随后会剔除该条目）")

        let noDate = EntryTodoCount(
            entryID: "f", openCount: 0, completedCount: 1, sourceModificationDate: nil
        )
        #expect(!TodoCountIndex.needsRefresh(cached: noDate, modificationDate: nil),
                "两侧都无 mtime 时保持现状，避免每个周期都空转重算")
    }

    /// 增量对账：mtime 一致的目录直接复用缓存，不做任何读盘/解密/解析
    @Test func todoCountIndexReusesUnchangedCacheWithoutReadingFile() {
        let folder = "Memozia-todoindex-test-\(UUID().uuidString)"
        let cached = EntryTodoCount(
            entryID: folder, openCount: 2, completedCount: 1, sourceModificationDate: nil
        )
        let result = TodoCountIndex.reconcile(previous: [folder: cached], folders: [folder])
        #expect(result[folder] == cached)
    }

    /// 增量对账：目录里的 todos.json 已消失（缓存与磁盘 mtime 不一致）时，
    /// 该条目必须从索引中剔除，而不是继续显示过期的「已拆待办」
    @Test func todoCountIndexDropsEntriesWhoseFileDisappeared() {
        let folder = "Memozia-todoindex-test-\(UUID().uuidString)"
        let cached = EntryTodoCount(
            entryID: folder, openCount: 2, completedCount: 0,
            sourceModificationDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let result = TodoCountIndex.reconcile(previous: [folder: cached], folders: [folder])
        #expect(result.isEmpty)
    }

    /// 回归：`reconcile` 必须把**文件夹** URL 交给 `TodoDocument.load`（后者内部再拼 `todos.json`）。
    /// 曾经的缺陷是把已拼好的 `.../todos.json` 路径再次传入 `load`，实际查找
    /// `.../todos.json/todos.json`，导致索引恒为空、「已拆待办」徽标永不显示。
    @Test func todoCountIndexReadsTodosFileFromFolderURL() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Memozia-todoindex-\(UUID().uuidString)")
        let folderName = "20260101090000"
        let folderURL = root.appendingPathComponent(folderName)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        AudioRecording.setRuntimeStorageOverride(root)
        defer {
            AudioRecording.setRuntimeStorageOverride(nil)
            try? FileManager.default.removeItem(at: root)
        }

        let document = TodoDocument(
            source: "summary",
            model: "test-model",
            items: [
                TodoItem(title: "待办一"),
                TodoItem(title: "待办二", status: .exported),
            ]
        )
        try document.save(to: folderURL)

        let result = TodoCountIndex.reconcile(previous: [:], folders: [folderName])
        let entry = try #require(result[folderName])
        #expect(entry.totalCount == 2)
        #expect(entry.openCount == 1)
        #expect(entry.completedCount == 1)
        #expect(entry.sourceModificationDate != nil)
    }

    /// 增量对账会忽略空文件夹名并去重同名条目（录音与笔记数据源可能同时给出同一名字）
    @Test func todoCountIndexIgnoresEmptyAndDuplicateFolders() {
        let folder = "Memozia-todoindex-test-\(UUID().uuidString)"
        let cached = EntryTodoCount(
            entryID: folder, openCount: 1, completedCount: 0, sourceModificationDate: nil
        )
        let result = TodoCountIndex.reconcile(
            previous: [folder: cached],
            folders: [folder, folder, ""]
        )
        #expect(result.count == 1)
        #expect(result[folder] == cached)
    }

    /// NX-3：带 folderName 的待办通知只重算目标条目，其余条目复用缓存（省掉全库逐个 stat）
    @Test func todoReconcileOneTouchesOnlyTargetFolder() {
        let target = "Memozia-reconcile-one-\(UUID().uuidString)"
        let other = "Memozia-reconcile-other-\(UUID().uuidString)"
        let keep = EntryTodoCount(entryID: other, openCount: 2, completedCount: 1, sourceModificationDate: nil)
        let stale = EntryTodoCount(entryID: target, openCount: 1, completedCount: 0, sourceModificationDate: nil)
        let previous = [target: stale, other: keep]

        // 目标目录没有 todos.json → 仅移除该键，其余条目原样保留
        let removed = TodoCountIndex.reconcileOne(previous: previous, folderName: target)
        #expect(removed[target] == nil)
        #expect(removed[other] == keep)

        // 不在缓存里的文件夹名且无文件：previous 保持不变
        let untouched = TodoCountIndex.reconcileOne(
            previous: previous, folderName: "Memozia-absent-\(UUID().uuidString)"
        )
        #expect(untouched == previous)

        // 空文件夹名：原样返回，不触发任何变更
        #expect(TodoCountIndex.reconcileOne(previous: previous, folderName: "") == previous)
    }

    /// NX-3：待办变更通知携带文件夹名；不带时接收方退回全量对账
    @Test func todoDocumentDidChangeCarriesFolderName() {
        let captured = CapturedUserInfo()
        let token = NotificationCenter.default.addObserver(
            forName: .todoDocumentDidChange, object: nil, queue: nil
        ) { note in
            captured.set(note.userInfo?[TodoDocument.folderNameUserInfoKey] as? String)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        TodoDocument.postDidChange(folder: URL(fileURLWithPath: "/tmp/MemoziaTest/20300101000000"))
        #expect(captured.value == "20300101000000", "带 folder 的通知应携带文件夹名")

        TodoDocument.postDidChange(folder: nil)
        #expect(captured.value == nil, "无 folder 的通知不携带文件夹名（接收方退回全量对账）")
    }

    /// 供通知观察闭包（@Sendable）写入的线程安全盒
    private final class CapturedUserInfo: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: String?
        func set(_ value: String?) { lock.lock(); storage = value; lock.unlock() }
        var value: String? { lock.lock(); defer { lock.unlock() }; return storage }
    }

    /// NX-2：插入前二次检查的**合批**版本——只返回候选集中确实已入库的文件夹名。
    /// 这条跳过分支在 CLI harness 里走不到（`newDirs` 已排除已入库文件夹），故在此直接钉住。
    @MainActor
    @Test func persistedFolderNamesReturnsOnlyPersistedCandidates() throws {
        let container = StartupModelContainerFactory.makeTransient()
        let context = ModelContext(container)
        context.insert(AudioRecording(
            fileName: "已经入库的录音",
            fileExtension: "wav",
            duration: 1,
            storedFileName: "a.wav",
            folderName: "20260101090000"
        ))
        context.insert(QuickNote(
            title: "已经入库的笔记",
            textContent: "正文",
            sourceImageFileName: nil,
            ocrText: nil,
            folderName: "20260101090100"
        ))
        try context.save()

        let persisted = FileSyncService.persistedFolderNames(
            among: ["20260101090000", "20260101090100", "20260101090200"],
            context: context
        )
        #expect(persisted == ["20260101090000", "20260101090100"],
                "应同时命中录音与笔记，且不包含未入库的候选")

        #expect(FileSyncService.persistedFolderNames(among: [], context: context).isEmpty,
                "空候选集直接返回空，不发起查询")
    }

    /// NX-2 3c：全表取数改为按 `folderName` 的 keyset 分页。用 `fetchPageSize + 1` 条跨过一次
    /// 分页边界，钉住「不漏条、不重复、集合与整表实现一致」。
    @MainActor
    @Test func pagedRecordingFetchCrossesPageBoundaryWithoutLossOrDuplication() async throws {
        let container = StartupModelContainerFactory.makeTransient()
        let context = ModelContext(container)
        let total = FileSyncService.fetchPageSize + 1
        var expected: Set<String> = []
        for index in 0..<total {
            let folderName = "2026" + String(format: "%012d", index)
            expected.insert(folderName)
            context.insert(AudioRecording(
                fileName: "录音 \(index)",
                fileExtension: "wav",
                duration: 1,
                storedFileName: "\(folderName).wav",
                folderName: folderName
            ))
        }
        // 空 folderName 的行不应进入字典（与原整表实现一致）
        context.insert(AudioRecording(
            fileName: "无目录名",
            fileExtension: "wav",
            duration: 1,
            storedFileName: "orphan.wav",
            folderName: ""
        ))
        try context.save()

        let dict = await FileSyncService.fetchExistingRecordingsDict(context: context)
        let fetched = try #require(dict)
        #expect(fetched.count == total, "跨页应取到全部 \(total) 条，不重不漏")
        #expect(Set(fetched.keys) == expected, "文件夹名集合应与插入一致")
        #expect(fetched[""] == nil, "空 folderName 的行应被跳过")
    }
}
