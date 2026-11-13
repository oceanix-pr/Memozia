import Foundation
import Testing

@testable import Memozia

/// 条目镜像写入器（`EntryMirrorStore`）的核心不变式。
///
/// 背景：镜像（转写/总结/画面要点）此前是每处一个 `Task.detached` 的 fire-and-forget 写入，
/// 调用方既无法等待、也无从得知写没写成。本文件钉住新入口的两条约定：
///
/// 1. **同一目标的连续写入合并为只写最新一份**，且 `flush()` 之后磁盘内容就是最新版；
/// 2. **写入结果必须可判定**：`writeNow` 返回 false 时调用方不得执行依赖该镜像的破坏性动作
///    （画面要点写入成功才允许删除分析检查点）。
@Suite(.serialized)
struct EntryMirrorStoreTests {

    private func makeDirectory(_ prefix: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("同一目标的连续提交合并为最新一份，flush 后即落盘")
    func testConsecutiveSubmitsCoalesceToLatest() async throws {
        // 镜像写入走加密落盘；测试宿主 Keychain 不可用时无法验证磁盘内容
        guard (try? EncryptionService.encrypt("probe")) != nil else { return }

        let dir = try makeDirectory("MemoziaMirror")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summary.md")
        let folderName = "20260920090000"
        let store = EntryMirrorStore()

        store.submit("第一版", kind: .summary, folderName: folderName, to: url)
        store.submit("第二版", kind: .summary, folderName: folderName, to: url)
        store.submit("第三版", kind: .summary, folderName: folderName, to: url)
        await store.flush(timeout: .seconds(10))

        #expect(EncryptionService.decryptFileOrPlaintext(at: url) == "第三版")
        #expect(store.failureDescriptions.isEmpty)
    }

    @Test("writeNow 会如实报告写入失败，供调用方决定是否执行破坏性后续动作")
    func testWriteNowReportsFailure() async throws {
        let dir = try makeDirectory("MemoziaMirrorFail")
        defer { try? FileManager.default.removeItem(at: dir) }
        // 目标目录不存在：原子写必然失败（加密本身是否可用不影响结论）
        let missingDirURL = dir
            .appendingPathComponent("不存在的目录", isDirectory: true)
            .appendingPathComponent("visual.md")

        let store = EntryMirrorStore()
        let saved = await store.writeNow(
            "画面要点", kind: .visual, folderName: "20260920090100", to: missingDirURL
        )
        #expect(saved == false, "写入失败必须返回 false，否则调用方会误删分析检查点")
        #expect(FileManager.default.fileExists(atPath: missingDirURL.path) == false)
    }

    @Test("flush 超时包含已从 pending 取走但仍在写入的 worker")
    func testFlushTimesOutForInFlightWriter() async {
        let gate = DispatchSemaphore(value: 0)
        let started = LockedBox(false)
        let store = EntryMirrorStore { _, _ in
            started.value = true
            gate.wait()
        }
        store.submit(
            "slow", kind: .summary, folderName: "20260920090200",
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !started.value, ContinuousClock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(started.value)

        let clock = ContinuousClock()
        let start = clock.now
        await store.flush(timeout: .milliseconds(100))
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .seconds(1), "flush 必须在超时后返回，不能等阻塞写入结束")

        gate.signal()
        await store.flush(timeout: .seconds(1))
    }

    @Test("writeNow 对阻塞文件系统有界返回且不把迟到结果长期留存")
    func testWriteNowTimesOutForBlockedWriter() async {
        let gate = DispatchSemaphore(value: 0)
        let started = LockedBox(false)
        let store = EntryMirrorStore { _, _ in
            started.value = true
            gate.wait()
        }
        let clock = ContinuousClock()
        let start = clock.now
        let saved = await store.writeNow(
            "slow",
            kind: .visual,
            folderName: "20260920090300",
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            timeout: .milliseconds(100)
        )
        let elapsed = start.duration(to: clock.now)

        #expect(started.value)
        #expect(!saved)
        #expect(elapsed < .seconds(1), "writeNow 不得因文件系统阻塞而永久悬挂")
        gate.signal()
        await store.flush(timeout: .seconds(1))
    }

    @Test("镜像文件只对真正旧版明文降级，疑似损坏密文不得当明文返回")
    func testEncryptedLookingCorruptionIsNotReturnedAsPlaintext() throws {
        let dir = try makeDirectory("MemoziaMirrorDecrypt")
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacyURL = dir.appendingPathComponent("legacy.md")
        try "旧版明文总结".write(to: legacyURL, atomically: true, encoding: .utf8)
        #expect(EncryptionService.decryptFileOrPlaintext(at: legacyURL) == "旧版明文总结")

        let corruptURL = dir.appendingPathComponent("corrupt.md")
        let encryptedLooking = Data(repeating: 0xA5, count: 48).base64EncodedString()
        try encryptedLooking.write(to: corruptURL, atomically: true, encoding: .utf8)
        #expect(
            EncryptionService.decryptFileOrPlaintext(at: corruptURL) == nil,
            "足够长的 Base64 密文解密失败时必须拒绝，不能二次加密进数据库"
        )
    }

    // MARK: - flush 结构化结果

    @Test("flush 报告未完成目标与失败原因，而不只是一个数量")
    func testFlushReportsStructuredResult() async throws {
        let dir = try makeDirectory("MemoziaMirrorFlush")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = DispatchSemaphore(value: 0)
        let started = LockedBox(false)
        let store = EntryMirrorStore { _, _ in
            started.value = true
            gate.wait()
        }
        store.submit(
            "slow", kind: .summary, folderName: "20260920100000",
            to: dir.appendingPathComponent("summary.md")
        )
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !started.value, ContinuousClock.now < startDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }

        let timedOut = await store.flush(timeout: .milliseconds(100))
        #expect(timedOut.isComplete == false)
        #expect(
            timedOut.remaining.contains("summary/20260920100000"),
            "超时未落盘的目标必须可被调用方列出"
        )

        gate.signal()
        let completed = await store.flush(timeout: .seconds(2))
        #expect(completed.remaining.isEmpty)
        #expect(completed.succeeded >= 1)
    }

    // MARK: - 流式临时文件 + 原子替换

    @Test("大内容走同目录临时文件 + 原子替换，且不留临时文件")
    func testStreamingAtomicWriteReplacesWithoutLeftovers() throws {
        let dir = try makeDirectory("MemoziaMirrorStream")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("transcript.json")

        try EntryMirrorStore.writeStreamingAtomically("第一版", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "第一版")

        // 第二版显著更大：验证分块写入与覆盖替换
        let large = "第二版-" + String(repeating: "x", count: 3_000_000)
        try EntryMirrorStore.writeStreamingAtomically(large, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == large)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(".tmp-") }
        #expect(leftovers.isEmpty, "原子替换后不得残留临时文件：\(leftovers)")
    }

    // MARK: - 恢复标记

    @Test("写入成功清除恢复标记")
    func testPendingMarkerClearedOnSuccess() async throws {
        let dir = try makeDirectory("MemoziaMirrorMarkerOK")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("summary.md")
        let store = EntryMirrorStore { content, url in
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        store.submit("ok", kind: .summary, folderName: "20260920100200", to: url)
        let result = await store.flush(timeout: .seconds(2))
        #expect(result.isComplete)
        #expect(EntryMirrorStore.hasPendingMarker(for: url) == false)
    }

    @Test("写入失败留下恢复标记，供下次启动磁盘对账补写")
    func testPendingMarkerKeptOnFailure() async throws {
        let dir = try makeDirectory("MemoziaMirrorMarkerFail")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("visual.md")
        #expect(EntryMirrorStore.hasPendingMarker(for: url) == false)

        let store = EntryMirrorStore { _, _ in
            throw EntryMirrorStoreError(reason: "模拟写入失败")
        }
        store.submit("画面要点", kind: .visual, folderName: "20260920100100", to: url)
        _ = await store.flush(timeout: .seconds(2))
        #expect(
            EntryMirrorStore.hasPendingMarker(for: url),
            "写入失败必须留下恢复标记，供下次启动由磁盘对账重新补写"
        )

        EntryMirrorStore.discardPendingMarker(for: url)
        #expect(EntryMirrorStore.hasPendingMarker(for: url) == false)
    }

    @Test("镜像磁盘探测：一次探出存在性、mtime 与恢复标记（NX-2：避免 MainActor 逐条 stat）")
    func testMirrorProbeCollectsExistenceDateAndMarker() throws {
        let dir = try makeDirectory("MemoziaMirrorProbe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcriptURL = dir.appendingPathComponent("transcript.md")
        let summaryURL = dir.appendingPathComponent("summary.md")
        let visualURL = dir.appendingPathComponent("visual.md")
        try Data("t".utf8).write(to: transcriptURL)
        // summary 故意不存在；visual 存在且带恢复标记
        try Data("v".utf8).write(to: visualURL)
        try Data("visual.md\n".utf8).write(to: EntryMirrorStore.pendingMarkerURL(for: visualURL))

        let state = FileSyncService.probe(FileSyncService.RecordingMirrorTarget(
            folderName: "20260101090000",
            transcriptURL: transcriptURL,
            summaryURL: summaryURL,
            visualURL: visualURL
        ))
        #expect(state.transcriptExists)
        #expect(state.transcriptDate != nil)
        #expect(state.transcriptPendingMarker == false)
        #expect(state.summaryExists == false)
        #expect(state.summaryDate == nil)
        #expect(state.summaryPendingMarker == false)
        #expect(state.visualExists)
        #expect(state.visualPendingMarker, "visual 的恢复标记应被探出（对账据此强制补写）")

        let noteState = FileSyncService.probe(FileSyncService.NoteMirrorTarget(
            folderName: "20260101090000",
            summaryURL: dir.appendingPathComponent("note-summary.md")
        ))
        #expect(noteState.exists == false)
        #expect(noteState.date == nil)
        #expect(noteState.pendingMarker == false)
    }
}
