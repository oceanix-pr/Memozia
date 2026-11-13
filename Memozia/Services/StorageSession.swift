import Foundation
import os.log

// MARK: - 存储会话（每次启动解析一次、运行期不可变）

/// 每次启动解析一次、运行期不可变的存储会话快照。
///
/// 为什么需要它：存储目录此前是「每次访问都从 UserDefaults 重新解析」，设置页确认后
/// 立即改偏好，会让运行中的进程出现「锁与队列仍按旧根定位、新条目却写进新根」的双根状态，
/// 旧条目的 `folderURL` 也会突然解析到不存在的位置。
///
/// 这里把根目录在**首次访问时解析并冻结**，运行期不再改变；设置页选择新目录只写
/// `AudioRecording.pendingStorageDirectory`，下次启动才提升为 active。
struct StorageSessionContext: Sendable, Equatable {
    let rootDirectory: URL
    let lockFileURL: URL

    var queueFileURL: URL {
        rootDirectory.appendingPathComponent(".background_task_queue.json")
    }
}

/// 存储会话安装点：与 `DatabaseOwnershipLock` 同属「进程级、只读一次的启动事实」。
///
/// 首次调用 `resolve()` 时（通常发生在 `DatabaseOwnershipLock.lockFileURL` 求值过程中）
/// 解析并冻结根目录，其后恒返回同一快照。
enum StorageSession {
    private static let logger = Logger(subsystem: "app.memozia", category: "StorageSession")
    private static let lock = NSLock()
    /// `nonisolated(unsafe)`：读写都在 `lock` 保护下，生命周期与进程一致
    nonisolated(unsafe) private static var _context: StorageSessionContext?

    /// 已解析的会话快照；nil 表示尚未解析（诊断/测试用）
    static var context: StorageSessionContext? {
        lock.lock(); defer { lock.unlock() }
        return _context
    }

    /// 首次访问时解析并冻结根目录，之后恒返回同一快照
    static func resolve() -> StorageSessionContext {
        lock.lock(); defer { lock.unlock() }
        if let context = _context { return context }
        let context = StorageSessionFactory.make()
        _context = context
        logger.info("存储会话已建立：\(context.rootDirectory.path, privacy: .public)")
        return context
    }

    /// 立即改变本进程的根目录（仅供测试与运行时验证脚本）。
    ///
    /// - Important: 生产路径不要用它——运行中改根正是 BK-2 要消除的「双根目录」来源。
    ///   生产改用 `AudioRecording.setPendingStorageDirectory` + 重启。
    static func forceRoot(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        _context = StorageSessionContext(
            rootDirectory: url,
            lockFileURL: url.appendingPathComponent(".db_ownership.lock")
        )
    }

    /// 测试复位：清空会话，下次访问重新解析
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        _context = nil
    }
}

/// 会话构造：把「待生效」提升为「当前生效」，并做启动期兜底预检。
enum StorageSessionFactory {
    private static let logger = Logger(subsystem: "app.memozia", category: "StorageSession")

    static func make() -> StorageSessionContext {
        let active = AudioRecording.activeStorageDirectory
        if let pending = AudioRecording.pendingStorageDirectory {
            if prepare(pending) {
                // 目录可用：提升为当前生效并清除待生效项
                AudioRecording.promotePendingStorageDirectory()
                logger.info("已应用待生效的数据文件夹：\(pending.path, privacy: .public)")
                return context(for: pending)
            }
            // 目录不可用：沿用当前路径并**保留** pending，下次启动再试（不静默丢用户选择）
            logger.fault("待生效的数据文件夹不可用，沿用当前路径：\(pending.path, privacy: .public)")
        }
        _ = prepare(active)
        return context(for: active)
    }

    /// 确保目录存在；失败不抛，交由调用方决定回退
    private static func prepare(_ url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            logger.error("创建数据文件夹失败：\(url.path, privacy: .public)，\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func context(for url: URL) -> StorageSessionContext {
        StorageSessionContext(
            rootDirectory: url,
            lockFileURL: url.appendingPathComponent(".db_ownership.lock")
        )
    }
}

// MARK: - 切换数据文件夹前的预检

/// 预检结果：目录可创建、可原子写删、卷在线、剩余空间
struct StoragePreflightResult: Sendable {
    var canCreateDirectory: Bool
    var atomicWriteProbe: Bool
    var isVolumeOnline: Bool
    var availableCapacity: Int64?
    /// 不满足的项（面向用户的说明，空表示通过）
    var blockers: [String]

    var isPassing: Bool { blockers.isEmpty }
}

enum StoragePreflight {

    /// 轻量预检：不迁移数据，只确认目标目录现在真的可用。
    /// 结束后的破坏性动作（改根）交给「重启」去做，因此这里只做目录级检查。
    static func evaluate(_ url: URL) -> StoragePreflightResult {
        var result = StoragePreflightResult(
            canCreateDirectory: false,
            atomicWriteProbe: false,
            isVolumeOnline: false,
            availableCapacity: nil,
            blockers: []
        )

        // 卷在线：外置盘被拔掉时目录「看起来存在」但不可访问。
        // 父目录不存在时交给 createDirectory 判定（允许补建中间目录），不算离线。
        let parent = url.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        let parentExists = FileManager.default.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory)
        if parentExists && parentIsDirectory.boolValue {
            result.isVolumeOnline = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil
        } else {
            result.isVolumeOnline = true
        }
        if !result.isVolumeOnline {
            result.blockers.append(String(localized: "目标位置所在磁盘当前不可用（可能是外置卷已断开）。"))
        }

        // 目录可创建
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            result.canCreateDirectory = true
        } catch {
            result.blockers.append(String(localized: "目标文件夹不可创建或不可写入，请检查权限与磁盘空间后重试。"))
            return result
        }

        // 原子写/删探针：只读卷、权限撤销、磁盘满都会在这里暴露
        let probe = url.appendingPathComponent(".Memozia_write_probe")
        do {
            try Data([0]).write(to: probe, options: .atomic)
            try FileManager.default.removeItem(at: probe)
            result.atomicWriteProbe = true
        } catch {
            result.blockers.append(String(localized: "目标文件夹不可创建或不可写入，请检查权限与磁盘空间后重试。"))
        }

        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            result.availableCapacity = values.volumeAvailableCapacityForImportantUsage
        }

        return result
    }
}
