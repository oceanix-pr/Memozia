import Foundation

// MARK: - 持久化能力（临时模式只读门控）

/// 进程级持久化能力：启动时确定，运行期不变。
///
/// 为什么需要它：临时模式（未取得数据库独占锁 / 可写容器创建失败，用户二次确认后以内存容器继续）
/// 下界面声称「不会保存任何改动」，但门控此前只存在于 `RootView` 的少数按钮上：重命名、隐藏、
/// 编辑转写/总结/画面要点、修改待办等入口仍可能直接写文件，或只写进内存库。这里把「能否持久化」
/// 收敛为唯一事实来源，供视图、ViewModel、文件与持久化服务三层统一校验，避免只靠按钮禁用。
enum PersistenceCapability: Sendable, Equatable {
    /// 正常模式：可写数据库与文件
    case readWrite
    /// 临时模式：本次运行不落盘，所有内容修改必须被拒绝
    case readOnlyTransient

    /// 是否处于临时（不落盘）模式
    var isTransient: Bool { self == .readOnlyTransient }

    /// 是否允许内容修改（新建/导入/编辑/删除/隐藏/入队等）
    var allowsContentMutation: Bool { self == .readWrite }
}

/// 会产生持久化副作用的操作分类；新增写入口时必须归类到其中之一，
/// 以便被拦截时能给出统一、可解释的提示。
enum PersistenceOperation: String, Sendable {
    case createEntry
    case importMedia
    case deleteEntry
    case renameEntry
    case editTitle
    case editTextContent
    case hideEntry
    case editTranscript
    case editSummary
    case editVisualSummary
    case editTodo
    case startProcessing
    case saveMeta
    case writeMirror
    case writeQueue
}

/// 因临时模式被拒绝的写操作
struct PersistenceBlockedError: LocalizedError, Sendable, Equatable {
    let capability: PersistenceCapability
    let operation: PersistenceOperation

    var errorDescription: String? { message }

    /// 统一提示：说明不会保存 + 恢复动作。
    /// 复用启动门控已有的本地化文案，避免新增 key 造成各语言译文缺口。
    var message: String {
        String(localized: "临时模式下不会保存任何改动，新建/导入/删除已被禁用。请先通过启动界面的「重试」连接数据库，或重启应用。")
    }
}

/// 写权限判据：注入到 ViewModel 与文件/持久化服务，作为「能否写」的唯一依据。
struct PersistenceGuard: Sendable, Equatable {
    let capability: PersistenceCapability

    /// 默认（正常）能力：单测与未注入路径沿用可写，避免改动面外溢
    static let readWrite = PersistenceGuard(capability: .readWrite)
    /// 临时（只读）能力
    static let readOnlyTransient = PersistenceGuard(capability: .readOnlyTransient)

    /// 是否允许该写操作（readWrite 恒为 true）
    func allows(_ operation: PersistenceOperation) -> Bool {
        capability.allowsContentMutation
    }

    /// 只读时返回被拒绝的原因，可写时返回 nil
    func rejection(for operation: PersistenceOperation) -> PersistenceBlockedError? {
        guard !capability.allowsContentMutation else { return nil }
        return PersistenceBlockedError(capability: capability, operation: operation)
    }
}
