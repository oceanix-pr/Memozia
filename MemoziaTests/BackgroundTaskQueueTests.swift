import Foundation
import Testing

@testable import Memozia

/// 后台任务队列的可靠性边界。
///
/// 队列里放的是「用户已发起、但还没跑完」的任务（转写/总结/分片合并）。它的每次变更都是
/// 「读-改-写」，因此有两类静默故障会把用户的任务弄丢：
///
/// 1. **把读失败/损坏当成空队列**：接下来的一次写就只剩本次改动的那一条，旧任务全被覆盖；
///    同时 `hasEntries()` 返回 false，守护进程认为无事可做直接退出，主应用也不再兜底续跑。
/// 2. **拿不到跨进程锁还照写**：主应用入队与 worker 消费互相覆盖，同样丢条目。
///
/// 本文件把这两条钉成不变式：损坏要么从 last-known-good 备份恢复、要么隔离留存并上报，
/// 锁拿不到就明确失败且**不写盘**。
struct BackgroundTaskQueueTests {

    /// 队列文件（与 BackgroundTaskQueue 的命名约定一致）
    private func queueURL(in storage: URL) -> URL {
        storage.appendingPathComponent(".background_task_queue.json")
    }

    private func backupURL(in storage: URL) -> URL {
        queueURL(in: storage).appendingPathExtension("bak")
    }

    private func entry(_ folderName: String) -> BackgroundTaskEntry {
        BackgroundTaskEntry(kind: .transcription, folderName: folderName)
    }

    @Test("任务保留入队时的体验模式且兼容旧队列")
    func testExperienceSnapshotCodableCompatibility() throws {
        let current = BackgroundTaskEntry(
            kind: .summary,
            folderName: "20260920100000",
            experience: .standard
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let roundTripped = try decoder.decode(
            BackgroundTaskEntry.self,
            from: encoder.encode(current)
        )
        #expect(roundTripped.experience == .standard)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(current)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "experience")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try decoder.decode(BackgroundTaskEntry.self, from: legacyData)
        #expect(legacy.experience == nil)
    }

    /// 把存储目录指向临时目录，测试结束后恢复（队列文件位置由存储目录推导）
    @MainActor
    private func withIsolatedStorage(_ body: (URL) throws -> Void) throws {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaQueue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let previous = UserDefaults.standard.string(forKey: AudioRecording.storageDirectoryKey)
        AudioRecording.setStorageDirectory(storage)
        defer {
            if let previous {
                AudioRecording.setStorageDirectory(URL(fileURLWithPath: previous))
            } else {
                AudioRecording.resetStorageDirectory()
            }
            try? FileManager.default.removeItem(at: storage)
        }
        try body(storage)
    }

    @MainActor
    @Test("队列文件损坏时从最近一次成功保存的备份恢复，并隔离损坏文件")
    func testCorruptedQueueRecoversFromBackupAndQuarantines() throws {
        try withIsolatedStorage { storage in
            let first = entry("20260920090000")
            #expect(BackgroundTaskQueue.enqueue(first))

            // 主文件损坏，备份保持完好
            try Data("这不是 JSON".utf8).write(to: queueURL(in: storage))

            let loaded = BackgroundTaskQueue.loadFromDisk()
            #expect(
                loaded.tasks.contains { $0.folderName == first.folderName },
                "读路径同样不能把损坏当空队列：它同时是「是否有遗留任务」的判据"
            )

            #expect(BackgroundTaskQueue.enqueue(entry("20260920090100")))

            let contents = try FileManager.default.contentsOfDirectory(atPath: storage.path)
            #expect(contents.contains { $0.contains(".corrupt-") }, "损坏文件必须改名留存以便排查")

            let after = BackgroundTaskQueue.loadFromDisk()
            #expect(after.tasks.count == 2, "恢复出的旧任务与本次新任务都要在队列里")
        }
    }

    @MainActor
    @Test("无可用备份时拒绝覆盖损坏队列并保留原文件")
    func testCorruptedQueueWithoutBackupRejectsMutation() throws {
        try withIsolatedStorage { storage in
            #expect(BackgroundTaskQueue.enqueue(entry("20260920090000")))
            try? FileManager.default.removeItem(at: backupURL(in: storage))
            try Data("{ 截断的 JSON".utf8).write(to: queueURL(in: storage))

            #expect(BackgroundTaskQueue.enqueue(entry("20260920090200")) == false)

            let contents = try FileManager.default.contentsOfDirectory(atPath: storage.path)
            #expect(!contents.contains { $0.contains(".corrupt-") })
            #expect(try String(contentsOf: queueURL(in: storage), encoding: .utf8) == "{ 截断的 JSON")
            if case .success = BackgroundTaskQueue.hasEntriesResult() {
                Issue.record("损坏且无备份时不得伪装成空队列")
            }
        }
    }

    @MainActor
    @Test("每次成功落盘都会刷新 last-known-good 备份")
    func testSuccessfulSaveRefreshesBackup() throws {
        try withIsolatedStorage { storage in
            #expect(BackgroundTaskQueue.enqueue(entry("20260920090000")))
            #expect(FileManager.default.fileExists(atPath: backupURL(in: storage).path))

            #expect(BackgroundTaskQueue.markInProgress(id: UUID()))
            let backup = try Data(contentsOf: backupURL(in: storage))
            let decoded = try JSONDecoder().decode(BackgroundTaskQueueData.self, from: backup)
            #expect(decoded.tasks.count == 1, "备份应反映最近一次成功保存的内容")
        }
    }

    @MainActor
    @Test("拿不到跨进程锁时明确失败，且不写盘")
    func testLockContentionFailsWithoutUnlockedWrite() throws {
        try withIsolatedStorage { storage in
            let queued = entry("20260920090000")
            #expect(BackgroundTaskQueue.enqueue(queued))

            // 另一把 fd 占住同一把锁，模拟 worker 正在消费队列
            let lockPath = queueURL(in: storage).appendingPathExtension("lock").path
            let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
            #expect(fd >= 0)
            #expect(flock(fd, LOCK_EX) == 0)
            defer { close(fd) }   // 关闭即释放

            // 旧实现会「无锁执行」，把并发写入覆盖掉；现在必须失败且队列保持原样
            #expect(BackgroundTaskQueue.enqueue(entry("20260920090300")) == false)

            let tasks = BackgroundTaskQueue.loadFromDisk().tasks
            #expect(tasks.count == 1)
            #expect(tasks.first?.folderName == queued.folderName)
        }
    }

    // MARK: - 重试退避与失败区（BK-4）

    @Test("指数退避按次数递增并封顶")
    func testBackoffSchedule() {
        #expect(BackgroundTaskQueue.Backoff.delay(forAttempt: 0) == 0)
        #expect(BackgroundTaskQueue.Backoff.delay(forAttempt: 1) == 30)
        #expect(BackgroundTaskQueue.Backoff.delay(forAttempt: 2) == 60)
        #expect(BackgroundTaskQueue.Backoff.delay(forAttempt: 3) == 120)
        #expect(BackgroundTaskQueue.Backoff.delay(forAttempt: 10) == BackgroundTaskQueue.Backoff.capSeconds)
    }

    @Test("远端转写读不到密钥时给出阻塞原因，本地/系统模式不受影响")
    func testKeyGuardBlocksOnlyForCloudWithoutKey() {
        #expect(BackgroundTaskKeyGuard.blockReason(mode: .local, keyReadResult: .readFailed("x")) == nil)
        #expect(BackgroundTaskKeyGuard.blockReason(mode: .system, keyReadResult: .readFailed("x")) == nil)
        #expect(BackgroundTaskKeyGuard.blockReason(mode: .cloud, keyReadResult: .readFailed("x")) != nil)
        #expect(BackgroundTaskKeyGuard.blockReason(mode: .cloud, keyReadResult: .absent) != nil)
        #expect(BackgroundTaskKeyGuard.blockReason(mode: .cloud, keyReadResult: .value("k")) == nil)
    }

    @MainActor
    @Test("可重试失败：保留条目并退避；达上限移入失败区（不静默删除），可再取回")
    func testRetryableFailureBackoffAndFailedArea() throws {
        try withIsolatedStorage { _ in
            let queued = entry("20260920090000")
            #expect(BackgroundTaskQueue.enqueue(queued))

            let t0 = Date()
            #expect(BackgroundTaskQueue.recordRetryableFailure(id: queued.id, code: .processingFailed, now: t0))

            let afterFirst = BackgroundTaskQueue.loadFromDisk().tasks.first
            #expect(afterFirst?.attempt == 1)
            #expect(afterFirst?.lastFailureCode == .processingFailed)
            let expectedNext = t0.addingTimeInterval(BackgroundTaskQueue.Backoff.delay(forAttempt: 1))
            #expect(afterFirst?.nextRetryAt == expectedNext)

            // 退避窗口内不取出；到点后可取出
            let peekInWindow = try BackgroundTaskQueue.peekFirstReadyResult(now: t0).get()
            #expect(peekInWindow == nil, "退避窗口内不得取出该条目")
            let peekDue = try BackgroundTaskQueue.peekFirstReadyResult(now: expectedNext).get()
            #expect(peekDue?.id == queued.id)

            // 连续失败到上限 → 移入失败区（保留，不删除）
            for _ in 1..<BackgroundTaskQueue.Backoff.maxAttempts {
                #expect(BackgroundTaskQueue.recordRetryableFailure(id: queued.id, code: .processingFailed, now: t0))
            }
            #expect(BackgroundTaskQueue.loadFromDisk().tasks.isEmpty)
            let failed = BackgroundTaskQueue.failedEntries()
            #expect(failed.count == 1)
            #expect(failed.first?.id == queued.id)
            #expect(failed.first?.lastFailureCode == .processingFailed)

            // 用户重试：移回待办并清零退避
            #expect(BackgroundTaskQueue.retryFailedEntry(id: queued.id))
            #expect(BackgroundTaskQueue.failedEntries().isEmpty)
            let requeued = BackgroundTaskQueue.loadFromDisk().tasks.first
            #expect(requeued?.id == queued.id)
            #expect(requeued?.attempt == nil)
            #expect(requeued?.nextRetryAt == nil)
        }
    }

    @MainActor
    @Test("失败区条目可丢弃")
    func testDiscardFailedEntry() throws {
        try withIsolatedStorage { _ in
            let queued = entry("20260920090100")
            #expect(BackgroundTaskQueue.enqueue(queued))
            for _ in 0..<BackgroundTaskQueue.Backoff.maxAttempts {
                #expect(BackgroundTaskQueue.recordRetryableFailure(id: queued.id, code: .databaseReadFailed))
            }
            #expect(BackgroundTaskQueue.failedEntries().count == 1)
            #expect(BackgroundTaskQueue.discardFailedEntry(id: queued.id))
            #expect(BackgroundTaskQueue.failedEntries().isEmpty)
        }
    }

    @MainActor
    @Test("队列路径不可写时 enqueue 明确返回 false（不静默丢任务）")
    func testEnqueueFailsWhenQueuePathUnwritable() throws {
        // 存储根指向一个「文件」而非目录：队列文件与锁都建不出来
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaQueueNotADir-\(UUID().uuidString)")
        try Data([0]).write(to: fileURL, options: .atomic)
        let previous = UserDefaults.standard.string(forKey: AudioRecording.storageDirectoryKey)
        AudioRecording.setStorageDirectory(fileURL)
        defer {
            if let previous {
                AudioRecording.setStorageDirectory(URL(fileURLWithPath: previous))
            } else {
                AudioRecording.resetStorageDirectory()
            }
            try? FileManager.default.removeItem(at: fileURL)
        }

        #expect(BackgroundTaskQueue.enqueue(entry("20260920090200")) == false)
        #expect(BackgroundTaskQueue.hasEntries() == false)
    }

    @Test("旧队列文件缺少 failedEntries 与重试字段时仍可解码（不丢任务）")
    func testLegacyQueueDataDecodesWithoutNewFields() throws {
        let legacyJSON = """
        {"tasks":[{"id":"\(UUID().uuidString)","kind":"transcription","folderName":"20260920090000","enqueuedAt":0}],"inProgressID":null}
        """
        let decoded = try JSONDecoder().decode(BackgroundTaskQueueData.self, from: Data(legacyJSON.utf8))
        #expect(decoded.tasks.count == 1)
        #expect(decoded.failedEntries.isEmpty)
        #expect(decoded.tasks.first?.attempt == nil)
        #expect(decoded.tasks.first?.nextRetryAt == nil)
    }
}
