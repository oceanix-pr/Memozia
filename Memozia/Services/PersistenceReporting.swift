import Foundation
import SwiftData
import os.log

// MARK: - 持久化失败上报

/// SwiftData 保存失败的统一上报入口。
///
/// 为什么需要它：工程里原先有十余处 `try? context.save()`，把写库异常整个吞掉。
/// `save()` 是会真实失败的（磁盘写满、约束冲突、迁移后 schema 不一致），而失败的表现是
/// **“界面看着已经改好了，重启回到旧值”**——最难排查的正是这种。最典型的一处是启动时
/// 重置上次崩溃遗留的 `.processing` 状态：保存失败会让那条录音在列表里**永久显示“转写中”**，
/// 而日志里什么都没有。
///
/// 取舍：把每个调用点都改成 throws 会牵动几十处签名与 UI 流程（且多数流程本来就无法回滚），
/// 因此沿用 `EncryptionService` 已验证的同一套做法——**每次失败必打 fault 日志，
/// 本次运行最多提示用户一次**。调用点从 `try? context.save()` 换成
/// `PersistenceReporting.saveOrReport { try context.save() }`，行为不变但不再静默。
enum PersistenceReporting {

    /// 保存失败通知（RootView 观察并提示用户）
    static let saveFailureNotification = Notification.Name("MemoziaSaveFailureDetected")

    private static let logger = Logger(subsystem: "app.memozia", category: "Persistence")

    /// 提示去重账本（跨调用点共享：整个进程生命周期内只提示一次）
    private static let ledger = FailureNoticeLedger()

    /// 执行保存，失败时留痕。
    ///
    /// 保存动作以**非逃逸闭包**传入，因此对 actor 隔离无要求：MainActor 上下文与
    /// 后台队列上的 `ModelContext` 都能复用同一入口（`ModelContext` 本身非 Sendable，
    /// 用 `@MainActor` 版签名会把后台调用点全挡在外面）。
    /// - Returns: 是否保存成功（调用方可据此决定是否继续后续依赖落库的步骤）
    @discardableResult
    static func saveOrReport(
        scene: String = #function,
        file: String = #filePath,
        line: Int = #line,
        save: () throws -> Void
    ) -> Bool {
        do {
            try save()
            return true
        } catch {
            reportSaveFailure(error, scene: scene, file: file, line: line)
            return false
        }
    }

    /// 登记一次保存失败：日志每次都打，用户提示仅首次。
    /// 单独公开是为了让**已经自己 catch 过**的调用点（例如批量导入里带重试的写库）也能复用同一通道。
    static func reportSaveFailure(
        _ error: any Error,
        scene: String = #function,
        file: String = #filePath,
        line: Int = #line
    ) {
        let isFirst = ledger.record(scene: scene)
        // 文件名去路径，避免日志被长绝对路径淹没
        let fileName = (file as NSString).lastPathComponent
        logger.fault(
            "SwiftData 保存失败（场景 \(scene, privacy: .public) @ \(fileName, privacy: .public):\(line)）：\(error.localizedDescription, privacy: .public)"
        )
        guard isFirst else { return }
        // 与 EncryptionService 的失败通知同样经主队列投递，观察端无需关心调用线程
        Task { @MainActor in
            NotificationCenter.default.post(name: saveFailureNotification, object: nil)
        }
    }

    /// 仅供测试复位提示状态
    static func resetForTesting() {
        ledger.reset()
    }
}

// MARK: - 失败提示账本

/// “每次都记、只提示一次”的纯状态机（从上报通道里独立出来，便于回归测试）。
final class FailureNoticeLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var posted = false
    private var scenes: [String] = []

    /// 登记一次失败。返回 `true` 表示本次运行内首次（调用方应发出用户提示）。
    @discardableResult
    func record(scene: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        scenes.append(scene)
        let first = !posted
        posted = true
        return first
    }

    /// 已登记的失败次数（用于日志/诊断，不去重）
    var failureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return scenes.count
    }

    /// 最近一次登记的场景
    var lastScene: String? {
        lock.lock()
        defer { lock.unlock() }
        return scenes.last
    }

    var hasPosted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return posted
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        posted = false
        scenes.removeAll()
    }
}
