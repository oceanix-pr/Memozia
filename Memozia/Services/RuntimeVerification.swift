import Foundation
import SwiftData
import AVFoundation
import Darwin
import os.log

/// 应用自检钩子（无界面）：把「只能在运行时验证」的项目做成可用脚本复现的命令行入口。
///
/// 与 `DiarizationCalibrator.runIfRequested()` 同一模式：在 `MemoziaApp` 结构体初始化时、
/// **单实例守卫之前**调用一次；未带参数时直接返回（零开销），命中参数时执行对应自检、
/// 输出单行 JSON 后调用 `ProcessLimits.exitSkippingStaticDestructors` 退出，不进入 UI。
///
/// 支持：
/// - `--verify-startup`：执行真实启动接管（worker 停止握手 → 数据库独占锁 → 持锁才建可写容器），
///   输出 workerWaitMs / lockAcquired / lockWaitMs / containerOpenMs / totalMs / mode / reason
/// - `--print-db-lock-path`：打印数据库独占锁文件绝对路径（供脚本持有锁）
/// - `--verify-memory <audioPath> [--segments <n>]`：用说话人分离的采样加载 + 分段规划
///   （不加载 sherpa 模型、不做推理）载入音频，输出内存/耗时/取消延迟指标
/// - `--verify-filesync <dataRoot> [--iterations <n>]`：把存储目录进程内临时指向 dataRoot，
///   对内存 ModelContainer 跑一次磁盘对账 + 待办索引统计
///
/// 约束：不读写用户密钥，不打印未脱敏文本；仅在进程内改存储目录（不写 UserDefaults）。
enum RuntimeVerification {

    static let startupFlag = "--verify-startup"
    static let lockPathFlag = "--print-db-lock-path"
    static let memoryFlag = "--verify-memory"
    static let fileSyncFlag = "--verify-filesync"

    private static let logger = Logger(subsystem: "app.memozia", category: "RuntimeVerify")

    /// 启动参数命中时执行对应自检并退出；未命中直接返回（对正常启动零开销）
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count > 1 else { return }
        if args.contains(startupFlag) { runStartupVerification() }
        if args.contains(lockPathFlag) { runPrintLockPath() }
        if let index = args.firstIndex(of: memoryFlag) {
            runMemoryVerification(args: args, flagIndex: index)
        }
        if let index = args.firstIndex(of: fileSyncFlag) {
            runFileSyncVerification(args: args, flagIndex: index)
        }
    }

    // MARK: - ① 真实启动接管

    /// 执行真实启动接管并输出指标：worker 停止握手 → 取数据库独占锁 → 持锁才建可写容器。
    /// 未取得独占锁时**绝不**创建可写容器（与 `StartupCoordinator` 同一判据）。
    private static func runStartupVerification() -> Never {
        let deps = StartupDependencies.live()
        let totalStart = Date()

        let workerStart = Date()
        let stopOutcome = deps.requestWorkerStop()
        let workerWaitMs = milliseconds(since: workerStart)

        let lockStart = Date()
        let acquisition = deps.acquireDatabaseLock()
        let lockWaitMs = milliseconds(since: lockStart)

        var lockAcquired = false
        var writableContainerOpened = false
        var containerOpenMs = 0.0
        var mode = "ephemeral"
        var reason: String

        switch acquisition {
        case .acquired:
            lockAcquired = true
            let openStart = Date()
            do {
                _ = try deps.makePersistentContainer()
                writableContainerOpened = true
                mode = "writable"
                reason = "acquired"
            } catch {
                mode = "persistentStoreFailed"
                reason = error.localizedDescription
            }
            containerOpenMs = milliseconds(since: openStart)
        case .heldByOtherProcess:
            // 未持锁：只建内存容器（与 UI 的“临时模式”等价），绝不打开可写容器
            reason = "databaseLockHeldByOtherProcess"
            let openStart = Date()
            _ = deps.makeTransientContainer()
            containerOpenMs = milliseconds(since: openStart)
        case .lockFileUnavailable(let errnoCode):
            reason = "lockFileUnavailable(errno=\(errnoCode))"
            let openStart = Date()
            _ = deps.makeTransientContainer()
            containerOpenMs = milliseconds(since: openStart)
        }

        let totalMs = milliseconds(since: totalStart)
        let line = jsonObject([
            ("workerWaitMs", number(workerWaitMs)),
            ("lockAcquired", boolean(lockAcquired)),
            ("lockWaitMs", number(lockWaitMs)),
            ("containerOpenMs", number(containerOpenMs)),
            ("totalMs", number(totalMs)),
            ("mode", string(mode)),
            ("writableContainerOpened", boolean(writableContainerOpened)),
            ("reason", string(reason)),
            ("workerOutcome", string(workerOutcomeName(stopOutcome))),
        ])
        print(line)
        ProcessLimits.exitSkippingStaticDestructors(0)
    }

    private static func workerOutcomeName(_ outcome: WorkerStopOutcome) -> String {
        switch outcome {
        case .noWorker: return "noWorker"
        case .exitedDuringGrace: return "exitedDuringGrace"
        case .exitedAfterTermination: return "exitedAfterTermination"
        case .stillRunning(let pid): return "stillRunning(pid=\(pid))"
        }
    }

    // MARK: - ② 打印数据库锁文件路径

    private static func runPrintLockPath() -> Never {
        print(DatabaseOwnershipLock.lockFileURL.path)
        ProcessLimits.exitSkippingStaticDestructors(0)
    }

    // MARK: - ③ 说话人分离采样加载的内存/耗时/取消指标

    /// 采样率与嵌入模型一致（16kHz），与实际分离管线使用同一常量口径
    private static let verificationSampleRate = 16000

    private static func runMemoryVerification(args: [String], flagIndex: Int) -> Never {
        let rest = Array(args.dropFirst(flagIndex + 1))
        var audioPath: String?
        var segmentLimit: Int?
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            if arg == "--segments" {
                if index + 1 < rest.count { segmentLimit = Int(rest[index + 1]) }
                index += 2
                continue
            }
            if !arg.hasPrefix("--"), audioPath == nil { audioPath = arg }
            index += 1
        }
        guard let audioPath else {
            writeStderr("用法: --verify-memory <音频路径> [--segments <n>]\n")
            ProcessLimits.exitSkippingStaticDestructors(2)
        }

        let url = URL(fileURLWithPath: audioPath)
        let exitCode = LockedBox<Int32>(0)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let code = await performMemoryVerification(url: url, segmentLimit: segmentLimit)
            exitCode.value = code
            semaphore.signal()
        }
        semaphore.wait()
        ProcessLimits.exitSkippingStaticDestructors(exitCode.value)
    }

    private static func performMemoryVerification(url: URL, segmentLimit: Int?) async -> Int32 {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print(jsonObject([
                ("error", string("audioNotFound")),
                ("path", string(url.path)),
            ]))
            return 2
        }

        let policy = DiarizationSegmentationPlanner.Policy.default
        let duration: TimeInterval
        do {
            duration = try audioDurationSeconds(at: url)
        } catch {
            print(jsonObject([
                ("error", string("audioUnreadable")),
                ("reason", string(error.localizedDescription)),
            ]))
            return 2
        }

        let estimatedBytes = DiarizationSegmentationPlanner.estimatedSampleBytes(
            duration: duration, sampleRate: verificationSampleRate
        )
        let plannerMode = DiarizationSegmentationPlanner.mode(
            duration: duration, sampleRate: verificationSampleRate, policy: policy
        )
        let ranges = DiarizationSegmentationPlanner.segmentRanges(
            totalDuration: duration,
            segmentDuration: policy.segmentDuration,
            overlap: policy.segmentOverlap
        )

        var loadMode = "whole"
        var segmentsLoaded = 0
        var sampleCount = 0
        let loadStart = Date()
        do {
            if let limit = segmentLimit, limit > 0 {
                loadMode = "segmented"
                for range in ranges.prefix(limit) {
                    let samples = try SpeakerDiarizationService.loadMonoSamples(
                        audioURL: url,
                        sampleRate: verificationSampleRate,
                        from: range.lowerBound,
                        to: range.upperBound
                    )
                    sampleCount += samples.count
                    segmentsLoaded += 1
                }
            } else {
                let samples = try SpeakerDiarizationService.loadMonoSamples(
                    audioURL: url, sampleRate: verificationSampleRate
                )
                sampleCount = samples.count
                segmentsLoaded = 1
            }
        } catch {
            print(jsonObject([
                ("error", string("audioLoadFailed")),
                ("reason", string(error.localizedDescription)),
            ]))
            return 1
        }
        let elapsedMs = milliseconds(since: loadStart)
        // 整段/分段加载完成后读取进程峰值常驻（mach task_info 的 resident_size_max）
        let peakRSSBytes = peakResidentBytes()

        // 取消延迟：另起一次可取消加载并取消，测量从 cancel() 到任务返回的耗时。
        // 取消时点取「本次加载实测耗时」的一定比例（而非固定 sleep）：采样加载受内存带宽
        // 限制、只需毫秒级，固定延时容易在任务结束之后才取消，从而测不到真实的取消传播延迟。
        let cancelTask = Task.detached(priority: .userInitiated) { () throws -> Int in
            try SpeakerDiarizationService.loadMonoSamples(
                audioURL: url, sampleRate: verificationSampleRate
            ).count
        }
        let cancelDelaySeconds = min(max(elapsedMs / 1000 * 0.3, 0.0002), 0.02)
        try? await Task.sleep(nanoseconds: UInt64(cancelDelaySeconds * 1_000_000_000))
        let cancelStart = Date()
        cancelTask.cancel()
        let cancelled = await cancelTask.result
        let cancelLatencyMs = milliseconds(since: cancelStart)
        let cancellationObserved: Bool
        switch cancelled {
        case .success: cancellationObserved = false
        case .failure(let error): cancellationObserved = error is CancellationError
        }

        print(jsonObject([
            ("durationSeconds", number(duration)),
            ("estimatedSampleBytes", integer(estimatedBytes)),
            ("plannerMode", string(plannerModeName(plannerMode))),
            ("segmentCount", integer(ranges.count)),
            ("peakRSSBytes", integer(Int(peakRSSBytes))),
            ("elapsedMs", number(elapsedMs)),
            ("cancelLatencyMs", number(cancelLatencyMs)),
            ("cancellationObserved", boolean(cancellationObserved)),
            ("loadMode", string(loadMode)),
            ("segmentsLoaded", integer(segmentsLoaded)),
            ("sampleCount", integer(sampleCount)),
        ]))
        return 0
    }

    private static func plannerModeName(_ mode: DiarizationSegmentationPlanner.Mode) -> String {
        switch mode {
        case .direct: return "direct"
        case .segmented: return "segmented"
        }
    }

    private static func audioDurationSeconds(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { throw RuntimeVerificationError.audioUnreadable("采样率无效") }
        return Double(max(Int64(0), file.length)) / sampleRate
    }

    // MARK: - ④ 磁盘对账 + 待办索引统计

    private struct FileSyncVerificationResult: Sendable {
        let elapsedMs: Double
        let discoveredEntries: Int
        let insertedEntries: Int
        let todoIndexStatCalls: Int
        let todoIndexParsedDirs: Int
        let iterations: Int
        let saveFailed: Bool
        /// 主线程单次同步阻塞的最大时长（毫秒）
        let mainThreadMaxBlockMs: Double
        /// 心跳时延超过阈值的采样数（主线程被卡住的次数）
        let mainThreadBlockedOverThreshold: Int
        /// 心跳采样总数
        let mainThreadSamples: Int
        /// 退出前镜像写入器是否已全部落盘（写方向可观测的前提）
        let mirrorFlushComplete: Bool
    }

    /// 主线程停顿探针：从后台线程按固定间隔向主队列投递「心跳」，
    /// 用「投递 → 执行」的时延近似主线程单次同步阻塞时长。
    ///
    /// 动机：`--verify-filesync` 只报总墙钟，无法区分「主线程被长时间卡住」与
    /// 「主线程空闲、后台在忙」。而审计关注的是前者（单次阻塞 ≤ 50ms）。
    /// 仅用于 CLI 自检：不注册通知、不触碰被测代码。
    private final class MainThreadStallProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var maxBlockMs: Double = 0
        private var overThreshold = 0
        private var samples = 0
        private var stopped = false

        private let interval: TimeInterval
        private let thresholdMs: Double
        private let worker = DispatchQueue(label: "app.memozia.stall-probe")

        init(interval: TimeInterval = 0.01, thresholdMs: Double = 50) {
            self.interval = interval
            self.thresholdMs = thresholdMs
        }

        func start() {
            worker.async { [weak self] in
                guard let self else { return }
                while true {
                    self.lock.lock()
                    let done = self.stopped
                    self.lock.unlock()
                    if done { return }

                    let enqueuedAt = Date()
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        let latencyMs = Date().timeIntervalSince(enqueuedAt) * 1000
                        self.lock.lock()
                        self.samples += 1
                        if latencyMs > self.maxBlockMs { self.maxBlockMs = latencyMs }
                        if latencyMs >= self.thresholdMs { self.overThreshold += 1 }
                        self.lock.unlock()
                    }
                    Thread.sleep(forTimeInterval: self.interval)
                }
            }
        }

        /// 停止采样并等一小段，让在途心跳落地后再取快照
        func stop() -> (maxBlockMs: Double, overThreshold: Int, samples: Int) {
            lock.lock()
            stopped = true
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock()
            let snapshot = (maxBlockMs, overThreshold, samples)
            lock.unlock()
            return snapshot
        }
    }

    private static func runFileSyncVerification(args: [String], flagIndex: Int) -> Never {
        let rest = Array(args.dropFirst(flagIndex + 1))
        var dataRoot: String?
        var iterations = 1
        var dbDirectory: String?
        var index = 0
        while index < rest.count {
            let arg = rest[index]
            if arg == "--iterations" {
                if index + 1 < rest.count, let value = Int(rest[index + 1]) { iterations = max(1, value) }
                index += 2
                continue
            }
            if arg == "--db" {
                if index + 1 < rest.count { dbDirectory = rest[index + 1] }
                index += 2
                continue
            }
            if !arg.hasPrefix("--"), dataRoot == nil { dataRoot = rest[index] }
            index += 1
        }
        guard let dataRoot else {
            writeStderr("用法: --verify-filesync <dataRoot> [--iterations <n>] [--db <dir>]\n")
            ProcessLimits.exitSkippingStaticDestructors(2)
        }
        let rootURL = URL(fileURLWithPath: dataRoot).standardizedFileURL
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            print(jsonObject([
                ("error", string("dataRootNotFound")),
                ("path", string(rootURL.path)),
            ]))
            ProcessLimits.exitSkippingStaticDestructors(2)
        }

        // `--db <dir>`：用落在该目录的持久容器，让多次运行共享同一份库，
        // 才能验证「库里有内容 → 补写缺失镜像」这个写方向（内存容器每次运行都是空的）
        let container: ModelContainer
        let dbMode: String
        if let dbDirectory {
            let dbURL = URL(fileURLWithPath: dbDirectory).standardizedFileURL
            try? FileManager.default.createDirectory(at: dbURL, withIntermediateDirectories: true)
            do {
                container = try StartupModelContainerFactory.makePersistent(
                    at: dbURL.appendingPathComponent("verify.store")
                )
                dbMode = "persistent"
            } catch {
                print(jsonObject([
                    ("error", string("persistentContainerFailed")),
                    ("reason", string(error.localizedDescription)),
                ]))
                ProcessLimits.exitSkippingStaticDestructors(2)
            }
        } else {
            container = StartupModelContainerFactory.makeTransient()
            dbMode = "transient"
        }

        // 进程内临时覆盖存储目录（不写 UserDefaults，退出即失效）
        AudioRecording.setRuntimeStorageOverride(rootURL)
        let resultBox = LockedBox<FileSyncVerificationResult?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let result = await performFileSyncVerification(container: container, iterations: iterations)
            resultBox.value = result
            semaphore.signal()
        }
        // 主线程泵 RunLoop：让 MainActor 任务（含其 await 续体）得以推进。
        // 用非阻塞轮询（timeout: .now()）而非 20ms 阻塞等待——否则主队列心跳会被这段
        // 等待本身延迟 ~20ms，污染「主线程阻塞」指标。
        while semaphore.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        AudioRecording.setRuntimeStorageOverride(nil)

        guard let result = resultBox.value else {
            print(jsonObject([("error", string("verificationProducedNoResult"))]))
            ProcessLimits.exitSkippingStaticDestructors(1)
        }
        print(jsonObject([
            ("elapsedMs", number(result.elapsedMs)),
            ("discoveredEntries", integer(result.discoveredEntries)),
            ("insertedEntries", integer(result.insertedEntries)),
            ("todoIndexStatCalls", integer(result.todoIndexStatCalls)),
            ("todoIndexParsedDirs", integer(result.todoIndexParsedDirs)),
            ("iterations", integer(result.iterations)),
            ("saveFailed", boolean(result.saveFailed)),
            ("mainThreadMaxBlockMs", number(result.mainThreadMaxBlockMs)),
            ("mainThreadBlockedOverThreshold", integer(result.mainThreadBlockedOverThreshold)),
            ("mainThreadSamples", integer(result.mainThreadSamples)),
            ("dbMode", string(dbMode)),
            ("mirrorFlushComplete", boolean(result.mirrorFlushComplete)),
        ]))
        ProcessLimits.exitSkippingStaticDestructors(0)
    }

    @MainActor
    private static func performFileSyncVerification(
        container: ModelContainer, iterations: Int
    ) async -> FileSyncVerificationResult {
        let context = ModelContext(container)
        let probe = MainThreadStallProbe()
        probe.start()
        let start = Date()
        var discoveredEntries = 0
        var insertedEntries = 0
        var todoIndexStatCalls = 0
        var todoIndexParsedDirs = 0
        var saveFailed = false

        for _ in 0..<iterations {
            let directories = FileSyncService.discoverEntryDirectories(
                at: AudioRecording.storageDirectory
            ) ?? []
            discoveredEntries = max(discoveredEntries, directories.count)
            let folders = directories.map { $0.lastPathComponent }
            // 待办索引统计：生产里 `RecordingListView.rebuildTodoIndex` 在 detached 任务中执行，
            // 这里也必须放后台——否则上千次同步 stat 会被算进「主线程阻塞」，测的就成了 harness 自己。
            let index = await Task.detached(priority: .utility) {
                TodoCountIndex.reconcile(previous: [:], folders: folders)
            }.value
            todoIndexStatCalls += Set(folders.filter { !$0.isEmpty }).count
            todoIndexParsedDirs += index.count

            let syncResult = await FileSyncService.syncFromDisk(context: context)
            insertedEntries += syncResult.newCount
            saveFailed = saveFailed || syncResult.saveFailed
        }

        // 先取「对账本体」的指标（与基线可比）：flush 属退出前落盘，不计入
        let stalls = probe.stop()
        let loopElapsedMs = milliseconds(since: start)

        // 对账期间提交的镜像写入由合并写入器批量落盘。`FileSyncService` 自己不 flush
        // （应用侧由退出流程 flush、worker 在 drain 末尾 flush），CLI 进程退出前必须显式 flush，
        // 否则「库里有内容 → 补写缺失镜像」在磁盘上不可观测，验证会假阴性。
        let flushResult = await EntryMirrorStore.shared.flush(timeout: .seconds(10))

        return FileSyncVerificationResult(
            elapsedMs: loopElapsedMs,
            discoveredEntries: discoveredEntries,
            insertedEntries: insertedEntries,
            todoIndexStatCalls: todoIndexStatCalls,
            todoIndexParsedDirs: todoIndexParsedDirs,
            iterations: iterations,
            saveFailed: saveFailed,
            mainThreadMaxBlockMs: stalls.maxBlockMs,
            mainThreadBlockedOverThreshold: stalls.overThreshold,
            mainThreadSamples: stalls.samples,
            mirrorFlushComplete: flushResult.isComplete
        )
    }

    // MARK: - 进程指标

    /// 进程峰值常驻内存（字节）：mach `task_info(MACH_TASK_BASIC_INFO)` 的 resident_size_max。
    /// 取不到时返回 0（不抛错，避免诊断路径本身影响被测路径）
    private static func peakResidentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size_max)
    }

    // MARK: - JSON 输出（单行、手工拼装以固定字段顺序）

    private static func jsonObject(_ pairs: [(String, String)]) -> String {
        "{" + pairs.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    private static func string(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", value) : "0"
    }

    private static func integer(_ value: Int) -> String { String(value) }

    private static func boolean(_ value: Bool) -> String { value ? "true" : "false" }

    private static func milliseconds(since start: Date) -> Double {
        Date().timeIntervalSince(start) * 1000
    }

    private static func writeStderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}

private enum RuntimeVerificationError: LocalizedError {
    case audioUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .audioUnreadable(let detail): return "音频读取失败：\(detail)"
        }
    }
}
