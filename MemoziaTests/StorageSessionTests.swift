import Foundation
import Testing

@testable import Memozia

/// BK-2：存储根目录不可变快照。
///
/// 背景：存储目录此前是「每次访问都从 UserDefaults 重新解析」，设置页确认后立即改偏好，
/// 会让运行中的进程出现「锁与队列仍按旧根定位、新条目却写进新根」的双根状态。
/// 本文件钉住新约定：
///
/// 1. 首次访问解析并**冻结**根目录，运行期不再随偏好漂移；
/// 2. 设置页选择的目录只记为「待生效」，下次启动才提升为 active；
/// 3. 待生效目录不可用时回退当前路径并保留待生效项，不静默丢用户选择。
@Suite(.serialized)
@MainActor
struct StorageSessionTests {

    private func makeDir(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 隔离 UserDefaults 中的存储目录偏好与会话状态，测试结束恢复
    private func withIsolatedStorage(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let originalActive = defaults.string(forKey: AudioRecording.storageDirectoryKey)
        let originalPending = defaults.string(forKey: AudioRecording.pendingStorageDirectoryKey)
        StorageSession.resetForTesting()
        defer {
            if let originalActive {
                defaults.set(originalActive, forKey: AudioRecording.storageDirectoryKey)
            } else {
                defaults.removeObject(forKey: AudioRecording.storageDirectoryKey)
            }
            if let originalPending {
                defaults.set(originalPending, forKey: AudioRecording.pendingStorageDirectoryKey)
            } else {
                defaults.removeObject(forKey: AudioRecording.pendingStorageDirectoryKey)
            }
            StorageSession.resetForTesting()
        }
        try body()
    }

    @Test("首次解析把待生效目录提升为当前生效并清除待生效项")
    func testPendingPromotedOnFirstResolve() throws {
        try withIsolatedStorage {
            let active = try makeDir("MemoziaActive")
            let pending = try makeDir("MemoziaPending")
            defer {
                try? FileManager.default.removeItem(at: active)
                try? FileManager.default.removeItem(at: pending)
            }

            AudioRecording.setStorageDirectory(active)
            StorageSession.resetForTesting()
            AudioRecording.setPendingStorageDirectory(pending)

            let context = StorageSession.resolve()
            #expect(context.rootDirectory.path == pending.path, "待生效目录应在启动时被采用")
            #expect(AudioRecording.pendingStorageDirectory == nil, "提升后应清除待生效项")
            #expect(AudioRecording.activeStorageDirectory.path == pending.path)
            #expect(AudioRecording.storageDirectory.path == pending.path)
        }
    }

    @Test("会话解析后运行期不再改根：改偏好不影响已冻结的根与锁路径")
    func testResolvedSessionIsFrozen() throws {
        try withIsolatedStorage {
            let first = try makeDir("MemoziaFrozenA")
            let second = try makeDir("MemoziaFrozenB")
            defer {
                try? FileManager.default.removeItem(at: first)
                try? FileManager.default.removeItem(at: second)
            }

            AudioRecording.setStorageDirectory(first)
            StorageSession.resetForTesting()
            let resolved = StorageSession.resolve()
            #expect(resolved.rootDirectory.path == first.path)
            #expect(resolved.lockFileURL.path == first.appendingPathComponent(".db_ownership.lock").path)

            // 模拟「运行中切换偏好」：只写 UserDefaults，不 forceRoot
            UserDefaults.standard.set(second.path, forKey: AudioRecording.storageDirectoryKey)

            #expect(
                AudioRecording.storageDirectory.path == first.path,
                "已冻结的根不得随偏好漂移，否则锁/队列/条目路径会与新根脱节（双根目录）"
            )
            #expect(StorageSession.resolve().rootDirectory.path == first.path)
        }
    }

    @Test("待生效目录不可用时回退当前路径并保留待生效项")
    func testUnusablePendingFallsBackAndKeepsPending() throws {
        try withIsolatedStorage {
            let active = try makeDir("MemoziaActiveFallback")
            defer { try? FileManager.default.removeItem(at: active) }

            AudioRecording.setStorageDirectory(active)
            StorageSession.resetForTesting()

            // 目标是一个「文件」而非目录：createDirectory 必然失败
            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("MemoziaNotADir-\(UUID().uuidString)")
            try Data([0]).write(to: fileURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: fileURL) }
            AudioRecording.setPendingStorageDirectory(fileURL)

            let context = StorageSession.resolve()
            #expect(context.rootDirectory.path == active.path, "不可用的目标目录不得被采用")
            #expect(
                AudioRecording.pendingStorageDirectory?.path == fileURL.path,
                "待生效项必须保留，供下次启动重试而不是静默丢弃"
            )
        }
    }

    @Test("预检：可写目录通过且不留探针文件；不可创建路径给出阻断原因")
    func testPreflight() throws {
        let ok = try makeDir("MemoziaPreflightOK")
        defer { try? FileManager.default.removeItem(at: ok) }
        let okResult = StoragePreflight.evaluate(ok)
        #expect(okResult.canCreateDirectory)
        #expect(okResult.atomicWriteProbe)
        #expect(okResult.isPassing)
        #expect(FileManager.default.fileExists(atPath: ok.appendingPathComponent(".Memozia_write_probe").path) == false)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoziaPreflightFile-\(UUID().uuidString)")
        try Data([0]).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let badResult = StoragePreflight.evaluate(fileURL)
        #expect(badResult.isPassing == false)
        #expect(badResult.blockers.isEmpty == false)
    }

    @Test("故障注入：目标目录只读时预检不通过（原子写探针暴露权限问题）")
    func testPreflightRejectsReadOnlyDirectory() throws {
        let readOnly = try makeDir("MemoziaReadOnly")
        defer {
            // 恢复可写后再删，避免权限残留影响清理
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly.path)
            try? FileManager.default.removeItem(at: readOnly)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)

        let result = StoragePreflight.evaluate(readOnly)
        #expect(result.isPassing == false, "只读目录不得通过预检")
        #expect(result.blockers.isEmpty == false)
    }
}
