import Foundation
import Synchronization
import Testing

@testable import Memozia

/// 任务中心并发与结果判定的确定性测试。
///
/// 钉住四条不变式：
/// 1. **执行句柄隔离**：取消一个 Job 只影响它自己，不触发另一个 Job 的取消回调；
/// 2. **结果强类型判定**：失败/取消/成功的结论由执行体给出，失败步骤不得被当成完成；
/// 3. **看门狗超时按失败处理**：挂死的步骤不能永久占住调度；
/// 4. **入队去重**：同目标同步骤序列的活动 Job 复用，不重复入队。
///
/// 测试全部基于注入的独立 `TaskCenter` 实例与手动闸门，不触碰真实网络/模型，结果确定。
/// 闸门/标志用 `Mutex` 承载状态以成为 `Sendable`，可被步骤闭包安全捕获（否则会被
/// 区域隔离判定为跨隔离发送）。
@MainActor
struct TaskCenterTests {

    // MARK: - 测试夹具

    /// 手动闸门：让步骤在执行中停住，便于观察取消/隔离行为。
    private final class Gate: Sendable {
        private let isOpen = Mutex(false)

        func open() { isOpen.withLock { $0 = true } }

        func wait() async {
            while !isOpen.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// 单次写入的标志位
    private final class Flag: Sendable {
        private let state = Mutex(false)
        func set() { state.withLock { $0 = true } }
        var value: Bool { state.withLock { $0 } }
    }

    /// 计数（用于区分「重跑」与「复用已完成结果」）
    private final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    /// 手动放行的挂起闸门：用续体挂住执行体，**不响应取消**（复现「底层不可取消」的孤儿执行体）
    private final class HangingGate: Sendable {
        private let waiting = Mutex(false)
        private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

        var isWaiting: Bool { waiting.withLock { $0 } }

        func wait() async {
            await withCheckedContinuation { c in
                continuation.withLock { $0 = c }
                waiting.withLock { $0 = true }
            }
        }

        func resume() {
            let c = continuation.withLock { let v = $0; $0 = nil; return v }
            c?.resume()
        }
    }

    private func step(
        _ kind: TaskKind,
        run: @escaping @MainActor () async -> TaskCenter.StepOutcome,
        cancel: @escaping @MainActor () -> Void = {}
    ) -> TaskCenter.Step {
        // 调度器会把「本次执行」的失败盒传进执行体；这里包装成无参闭包，简化既有用例写法
        TaskCenter.Step(kind: kind, run: { _ in await run() }, cancel: cancel)
    }

    /// 必失败步骤：把稳定错误码写进调度器传入的失败信息盒
    private func failingStep(_ kind: TaskKind, code: TaskErrorCode) -> TaskCenter.Step {
        TaskCenter.Step(
            kind: kind,
            run: { failure in failure.code = code; return .failed },
            cancel: {}
        )
    }

    private func makeJob(folder: String, steps: [TaskCenter.Step]) -> TaskCenter.Job {
        TaskCenter.Job(folderName: folder, title: folder, steps: steps, isDurable: false)
    }

    /// 轮询等待条件成立（步骤执行体是异步调度的，需要一个有界等待）
    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("等待条件超时（\(timeout)s）")
    }

    private func state(of center: TaskCenter, id: UUID) -> TaskCenter.JobState? {
        center.jobs.first { $0.id == id }?.state
    }

    // MARK: - 去重

    @Test("同目标同步骤序列的活动 Job 被去重复用，不重复入队")
    func duplicateEnqueueIsReused() async throws {
        let center = TaskCenter()
        let gate = Gate()
        let first = center.enqueue(makeJob(
            folder: "20260101000000",
            steps: [step(.summary) { await gate.wait(); return .succeeded }]
        ))
        let second = center.enqueue(makeJob(
            folder: "20260101000000",
            steps: [step(.summary) { await gate.wait(); return .succeeded }]
        ))

        #expect(first == second, "同目标同步骤序列应复用同一 Job")
        #expect(center.jobs.count == 1)

        // 不同步骤序列：不去重
        let third = center.enqueue(makeJob(
            folder: "20260101000000",
            steps: [step(.todoExtraction) { await gate.wait(); return .succeeded }]
        ))
        #expect(third != first)
        #expect(center.jobs.count == 2)

        // 不同目标：不去重
        let fourth = center.enqueue(makeJob(
            folder: "20260101000001",
            steps: [step(.summary) { await gate.wait(); return .succeeded }]
        ))
        #expect(fourth != first)
        #expect(center.jobs.count == 3)

        gate.open()
        try await waitUntil { self.state(of: center, id: first) == .done }

        // 已完成的 Job 不再是「活动 Job」：移除后同标识再次入队应重新入队
        center.removeJob(id: first)
        let again = center.enqueue(makeJob(
            folder: "20260101000000",
            steps: [step(.summary) { .succeeded }]
        ))
        #expect(again != first)
    }

    // MARK: - 取消隔离

    @Test("取消一个 Job 不触发另一个 Job 的取消，也不影响其完成")
    func cancellingOneJobDoesNotAffectAnother() async throws {
        let center = TaskCenter()
        let gateA = Gate()
        let gateB = Gate()
        let aCancelled = Flag()
        let bCancelled = Flag()

        let idA = center.enqueue(makeJob(
            folder: "fa",
            steps: [step(.summary, run: { await gateA.wait(); return .succeeded }, cancel: { aCancelled.set() })]
        ))
        let idB = center.enqueue(makeJob(
            folder: "fb",
            steps: [step(.summary, run: { await gateB.wait(); return .succeeded }, cancel: { bCancelled.set() })]
        ))

        try await waitUntil {
            self.state(of: center, id: idA) == .running && self.state(of: center, id: idB) == .running
        }

        center.cancel(jobID: idA)

        #expect(aCancelled.value, "被取消的 Job 必须触发自身取消回调")
        #expect(bCancelled.value == false, "取消 A 不得触发 B 的取消回调")
        #expect(center.jobs.contains { $0.id == idB }, "B 必须仍在队列中")
        #expect(self.state(of: center, id: idB) == .running, "取消 A 不得改变 B 的状态")

        // 放开 B：它仍应正常完成，而不是被 A 的取消连带取消
        gateB.open()
        try await waitUntil { self.state(of: center, id: idB) == .done }
        #expect(bCancelled.value == false)

        // 放开 A 仍挂起的执行体，避免遗留
        gateA.open()
    }

    @Test("取消 Job 会将其从队列移除")
    func cancelledJobIsRemoved() async throws {
        let center = TaskCenter()
        let gate = Gate()
        let id = center.enqueue(makeJob(
            folder: "f",
            steps: [step(.summary) { await gate.wait(); return .succeeded }]
        ))

        try await waitUntil { self.state(of: center, id: id) == .running }
        center.cancel(jobID: id)
        #expect(center.jobs.contains { $0.id == id } == false, "取消后 Job 从队列移除")
        gate.open()
    }

    // MARK: - 结果判定

    @Test("失败的步骤按失败结算，不会被误报为成功")
    func failedStepIsNotReportedAsSuccess() async throws {
        let center = TaskCenter()
        let failID = center.enqueue(makeJob(
            folder: "f1",
            steps: [step(.summary) { .failed }]
        ))
        try await waitUntil { self.state(of: center, id: failID) == .failed }
        #expect(self.state(of: center, id: failID) != .done, "失败不得被当作完成")

        let okID = center.enqueue(makeJob(
            folder: "f2",
            steps: [step(.summary) { .succeeded }]
        ))
        try await waitUntil { self.state(of: center, id: okID) == .done }
        #expect(self.state(of: center, id: okID) == .done)
    }

    @Test("执行体自报取消时 Job 按取消结算")
    func selfReportedCancellationIsCancelled() async throws {
        let center = TaskCenter()
        let id = center.enqueue(makeJob(
            folder: "f",
            steps: [step(.summary) { .cancelled }]
        ))
        try await waitUntil { self.state(of: center, id: id) == .cancelled }
        #expect(self.state(of: center, id: id) != .done)
        #expect(self.state(of: center, id: id) != .failed)
    }

    @Test("多步骤 Job：中间步骤失败即整体失败，不继续后续步骤")
    func multiStepStopsOnFailure() async throws {
        let center = TaskCenter()
        let secondRan = Flag()
        let id = center.enqueue(makeJob(
            folder: "f",
            steps: [
                step(.summary) { .failed },
                step(.todoExtraction) { secondRan.set(); return .succeeded }
            ]
        ))
        try await waitUntil { self.state(of: center, id: id) == .failed }
        #expect(secondRan.value == false, "前一步失败后不得再执行后续步骤")
    }

    // MARK: - 看门狗超时

    @Test("看门狗超时按失败处理")
    func watchdogTimeoutFailsStep() async throws {
        // 注入极短超时，确定性地复现「执行体永不返回」
        let center = TaskCenter(stepTimeoutProvider: { _ in 0.05 })
        let id = center.enqueue(makeJob(
            folder: "hang",
            steps: [step(.summary) {
                try? await Task.sleep(for: .seconds(30))
                return .succeeded
            }]
        ))
        try await waitUntil(timeout: 5) { self.state(of: center, id: id) == .failed }
        #expect(self.state(of: center, id: id) != .done)
        // 超时必须落成「超时」稳定码，界面据此提示并允许重试（而不是笼统的未知失败）
        #expect(center.failedJobs.first?.steps.first?.errorCode == .timedOut)
    }

    // MARK: - 超时孤儿不释放槽位（generation/lease）

    @Test("超时后旧执行未退出前不释放资源类槽位：重试只能排队，迟到结果不覆盖新代次")
    func orphanHoldsSlotUntilItExits() async throws {
        // 极短超时 + 极短宽限期，确定性复现「执行体不响应取消、迟到返回」
        let center = TaskCenter(stepTimeoutProvider: { _ in 0.05 }, orphanGraceProvider: { 0.05 })
        let calls = Counter()
        let hanging = HangingGate()
        let id = center.enqueue(makeJob(
            folder: "orphan",
            steps: [step(.transcription) {
                let n = calls.count
                calls.increment()
                if n == 0 { await hanging.wait() }   // 第一次执行：不响应取消地挂住
                return .succeeded
            }]
        ))

        // 超时按失败结算，并标记资源类「停止中」（没有立即释放槽位）
        try await waitUntil(timeout: 5) { self.state(of: center, id: id) == .failed }
        #expect(center.failedJobs.first?.steps.first?.errorCode == .timedOut)
        try await waitUntil(timeout: 5) { hanging.isWaiting }
        #expect(center.isResourceClassStopping(.inference), "孤儿未退出前该资源类应保持停止中且不释放槽位")

        // 重试：旧执行仍占着唯一的 inference 槽位，第二次执行不得开始
        center.retryStep(jobID: id)
        try await Task.sleep(for: .milliseconds(200))
        #expect(calls.count == 1, "旧执行未退出前，重试必须排队而不是并发执行")

        // 旧执行迟到返回：槽位释放，重试得以开始并完成
        hanging.resume()
        try await waitUntil(timeout: 5) { self.state(of: center, id: id) == .done }
        #expect(calls.count == 2)
        try await waitUntil(timeout: 5) { center.isResourceClassStopping(.inference) == false }
    }

    @Test("孤儿超过宽限期未退出 → 资源类标记为需重启恢复")
    func orphanBeyondGraceRequiresRestart() async throws {
        let center = TaskCenter(stepTimeoutProvider: { _ in 0.05 }, orphanGraceProvider: { 0.05 })
        let hanging = HangingGate()
        let id = center.enqueue(makeJob(
            folder: "orphan-grace",
            steps: [step(.transcription) { await hanging.wait(); return .succeeded }]
        ))
        try await waitUntil(timeout: 5) { center.isRestartRequired(for: .inference) }
        #expect(self.state(of: center, id: id) == .failed)
        hanging.resume()   // 收尾，避免留下悬挂的孤儿
        try await waitUntil(timeout: 5) { center.isResourceClassStopping(.inference) == false }
    }

    // MARK: - 失败码 / 失败时间 / 重试

    @Test("失败步骤记录执行体上报的稳定错误码、失败时间与可重试性")
    func failedStepRecordsStableCodeAndTime() async throws {
        let center = TaskCenter()
        let id = center.enqueue(makeJob(folder: "fail", steps: [failingStep(.transcription, code: .missingLocalModel)]))
        try await waitUntil { self.state(of: center, id: id) == .failed }

        let job = try #require(center.failedJobs.first)
        #expect(job.steps.first?.errorCode == .missingLocalModel)
        #expect(job.steps.first?.finishedAt != nil, "失败步骤必须记录结束时间")
        #expect(center.failedStepIndex(jobID: id) == 0)
        #expect(TaskErrorCode.missingLocalModel.isRetryable)
        #expect(TaskErrorCode.cancelled.isRetryable == false, "已取消不提供重试")
        #expect(TaskErrorCode.missingLocalModel.recovery == .appSettings)
        #expect(TaskErrorCode.inputFileMissing.recovery == .revealInFinder)
    }

    @Test("重试此步骤：只重排失败步骤，已完成的步骤不重跑")
    func retryStepKeepsCompletedStepsDone() async throws {
        let center = TaskCenter()
        let transcriptRuns = Counter()
        let summaryRuns = Counter()
        let id = center.enqueue(makeJob(
            folder: "retry-step",
            steps: [
                step(.transcription) { transcriptRuns.increment(); return .succeeded },
                TaskCenter.Step(
                    kind: .summary,
                    run: { failure in summaryRuns.increment(); failure.code = .missingLocalModel; return .failed },
                    cancel: {}
                ),
            ]
        ))
        try await waitUntil { self.state(of: center, id: id) == .failed }
        #expect(transcriptRuns.count == 1)
        #expect(summaryRuns.count == 1)

        center.retryStep(jobID: id)
        // 只等「失败步骤重跑」这一事实成立，避免旧的 .failed 状态让等待提前返回
        try await waitUntil { summaryRuns.count == 2 }
        try await waitUntil { self.state(of: center, id: id) == .failed }

        #expect(transcriptRuns.count == 1, "已完成的前置步骤不得被重跑")
        // 失败码只落在失败的那一步，成功的步骤不写码
        #expect(center.failedJobs.first?.steps.first?.errorCode == nil)
        #expect(center.failedJobs.first?.steps.last?.errorCode == .missingLocalModel)
    }

    @Test("重新执行整个任务：所有步骤回到排队并从头开始")
    func retryJobRestartsAllSteps() async throws {
        let center = TaskCenter()
        let transcriptRuns = Counter()
        let summaryRuns = Counter()
        let id = center.enqueue(makeJob(
            folder: "retry-job",
            steps: [
                step(.transcription) { transcriptRuns.increment(); return .succeeded },
                step(.summary) { summaryRuns.increment(); return .failed },
            ]
        ))
        try await waitUntil { self.state(of: center, id: id) == .failed }
        #expect(transcriptRuns.count == 1)
        #expect(summaryRuns.count == 1)

        center.retryJob(jobID: id)
        try await waitUntil { summaryRuns.count == 2 }
        try await waitUntil { self.state(of: center, id: id) == .failed }

        #expect(transcriptRuns.count == 2, "重新执行整个任务必须重跑前置步骤")
    }

    @Test("重试入口只对失败态生效：活动/已完成任务不被误重排")
    func retryOnlyAppliesToFailedJobs() async throws {
        let center = TaskCenter()
        let gate = Gate()
        let id = center.enqueue(makeJob(folder: "running", steps: [step(.summary) { await gate.wait(); return .succeeded }]))
        try await waitUntil { self.state(of: center, id: id) == .running }

        center.retryStep(jobID: id)
        center.retryJob(jobID: id)
        #expect(self.state(of: center, id: id) == .running, "运行中的任务不得被重试入口改动")

        gate.open()
        try await waitUntil { self.state(of: center, id: id) == .done }
        center.retryJob(jobID: id)
        #expect(self.state(of: center, id: id) == .done, "已完成的任务不得被重试入口改动")
    }

    // MARK: - 兜底归类

    @Test("兜底错误码归类：输入缺失优先，其次磁盘不足，否则未知")
    func failureClassificationRules() {
        #expect(TaskFailureClassifier.classify(primaryInputExists: false, availableDiskBytes: nil) == .inputFileMissing)
        #expect(TaskFailureClassifier.classify(primaryInputExists: false, availableDiskBytes: 1) == .inputFileMissing)
        #expect(TaskFailureClassifier.classify(
            primaryInputExists: true,
            availableDiskBytes: TaskFailureClassifier.lowDiskThresholdBytes - 1
        ) == .insufficientDisk)
        #expect(TaskFailureClassifier.classify(
            primaryInputExists: true,
            availableDiskBytes: TaskFailureClassifier.lowDiskThresholdBytes
        ) == .unknown)
        #expect(TaskFailureClassifier.classify(primaryInputExists: true, availableDiskBytes: nil) == .unknown)
    }

    // MARK: - 用户文案归类（UserFacingError）

    /// 模拟 `MeetingRecorderError` / `SystemAudioError` / `VideoUnderstandingError` 这类
    /// 应用自定义、自带本地化描述的 `LocalizedError`。
    private struct StubLocalizedError: LocalizedError {
        let errorDescription: String?
    }

    /// 既不在已知系统域、也没有本地化描述的普通错误。
    private struct StubPlainError: Error {}

    @Test("自定义 LocalizedError 直接采用其自身文案，而不是被兜底成泛化提示")
    func customLocalizedErrorSurfacesOwnDescription() {
        let detail = "原始视频已清理，且没有可复用的关键帧，无法分析画面。"
        #expect(UserFacingError.summary(for: StubLocalizedError(errorDescription: detail)) == detail)
        // 空白描述视为无效，仍回退到兜底文案
        #expect(UserFacingError.summary(for: StubLocalizedError(errorDescription: "  "))
                == TaskErrorCode.unknown.localizedSummary)
    }

    @Test("没有可用描述的未归类错误回退到兜底文案")
    func unclassifiedErrorFallsBackToUnknownSummary() {
        #expect(UserFacingError.summary(for: StubPlainError()) == TaskErrorCode.unknown.localizedSummary)
    }

    @Test("系统网络错误仍走网络分支，不被自定义描述分支截获")
    func systemNetworkErrorKeepsDomainMapping() {
        #expect(UserFacingError.summary(for: URLError(.cannotConnectToHost))
                != TaskErrorCode.unknown.localizedSummary)
    }
}
