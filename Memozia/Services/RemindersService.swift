import Foundation
import EventKit
import os.log

/// 提醒事项服务：封装 EventKit，负责授权、列出可写列表、写入待办
///
/// macOS 非 Sandbox 下，EventKit 可直接使用，无需额外 entitlement。
/// 权限首次请求时机：调用 requestAccess() 或首次写入时。
@MainActor
final class RemindersService: ObservableObject {

    static let shared = RemindersService()

    private let store = EKEventStore()
    private let logger = Logger(subsystem: "app.memozia", category: "Reminders")

    /// 授权状态（驱动 UI 刷新）
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined

    /// 可写的提醒事项列表（calendars of type .reminder）
    @Published private(set) var availableLists: [EKCalendar] = []

    /// 是否正在加载列表
    @Published private(set) var isLoadingLists = false

    /// identifier → EKCalendar 解析缓存。
    /// `store.calendars(for:)` 是同步的 EventKit 全量枚举，批量导出时
    /// 每条待办都会经由 `list(for:)` 走一次（availableLists 未命中时），
    /// 缓存后同一列表只枚举一次
    private var resolvedListCache: [String: EKCalendar] = [:]

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - 授权

    /// 请求提醒事项访问权限
    /// - macOS 14+ 使用 fullAccess，旧版本降级
    @discardableResult
    func requestAccess() async -> Bool {
        let granted: Bool
        if #available(macOS 14.0, iOS 17.0, *) {
            do {
                granted = try await store.requestFullAccessToReminders()
            } catch {
                logger.error("提醒事项授权请求出错: \(error.localizedDescription)")
                authorizationStatus = .denied
                return false
            }
        } else {
            do {
                granted = try await store.requestAccess(to: .reminder)
            } catch {
                logger.error("提醒事项授权请求出错: \(error.localizedDescription)")
                authorizationStatus = .denied
                return false
            }
        }
        authorizationStatus = granted ? .fullAccess : .denied
        logger.info("提醒事项授权结果：\(self.authorizationStatus.rawValue)")
        if granted {
            await refreshAvailableLists()
        }
        return granted
    }

    /// 同步授权状态（用于 UI 出现时刷新）
    func refreshAuthorizationStatus() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    /// 是否已授权
    var isAuthorized: Bool {
        switch authorizationStatus {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }

    // MARK: - 列表管理

    /// 刷新可写的提醒事项列表
    func refreshAvailableLists() async {
        guard isAuthorized else { return }
        isLoadingLists = true
        defer { isLoadingLists = false }

        let calendars = store.calendars(for: .reminder)
        availableLists = calendars.sorted { $0.title < $1.title }
        // 列表可能已在提醒事项App 里被改名/删除：重建缓存避免读到陈旧 EKCalendar
        resolvedListCache = Dictionary(
            calendars.map { ($0.calendarIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// 获取默认提醒事项列表（系统默认）
    var defaultSystemList: EKCalendar? {
        store.defaultCalendarForNewReminders()
    }

    /// 按 calendarIdentifier 查找列表
    func list(for identifier: String) -> EKCalendar? {
        if let cached = resolvedListCache[identifier] {
            return cached
        }
        if let listed = availableLists.first(where: { $0.calendarIdentifier == identifier }) {
            resolvedListCache[identifier] = listed
            return listed
        }
        // EventKit 不支持按 ID 直接查 calendar，遍历全部 reminder 日历匹配
        guard let found = store.calendars(for: .reminder).first(where: { $0.calendarIdentifier == identifier }) else {
            return nil
        }
        resolvedListCache[identifier] = found
        return found
    }

    // MARK: - 写入待办

    /// 写入单个待办到指定列表
    /// - Parameters:
    ///   - item: 待办项
    ///   - calendarIdentifier: 目标列表 ID（空则用系统默认列表）
    ///   - commit: 是否立即提交。**批量写入必须传 false**：`store.save(commit: true)`
    ///     每次都要走一轮同步的 EventKit 事务（百毫秒级），本类是 @MainActor，
    ///     导出 30 条待办就是 30 次主线程同步提交，直接表现为“导出时 UI 冻结”
    /// - Returns: 写入成功后的 EKReminder ID，失败返回 nil
    func writeReminder(item: TodoItem, to calendarIdentifier: String, commit: Bool = true) async -> String? {
        guard isAuthorized else {
            logger.error("未授权提醒事项访问，无法写入")
            return nil
        }

        let calendar: EKCalendar?
        if calendarIdentifier.isEmpty {
            calendar = store.defaultCalendarForNewReminders()
        } else {
            calendar = list(for: calendarIdentifier) ?? store.defaultCalendarForNewReminders()
        }

        guard let targetCalendar = calendar else {
            logger.error("找不到目标提醒事项列表：\(calendarIdentifier)")
            return nil
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = targetCalendar
        applyItemFields(reminder, item: item)

        do {
            try store.save(reminder, commit: commit)
            logger.info("待办写入成功：\(item.title) → \(targetCalendar.title)")
            return reminder.calendarItemIdentifier
        } catch {
            logger.error("待办写入失败：\(error.localizedDescription)")
            return nil
        }
    }

    /// 统一的字段写入（新建与更新共用）
    ///
    /// macOS 26「提醒事项」实测行为：
    /// - UI 的 URL 栏与提前提醒是私有存储，不读 EKCalendarItem.url 与 alarms；
    ///   url 仍写入 EventKit 字段（数据完整性/其它客户端可见），同时在 notes 末尾附上链接保证可见可点
    /// - EKAlarm(relativeOffset:) 会被 UI 曲解（把提醒时刻写进截止时间并丢弃闹钟），
    ///   改用绝对闹钟（due - 提前量），可正确触发通知且不污染截止时间
    private func applyItemFields(_ reminder: EKReminder, item: TodoItem) {
        reminder.title = item.title
        reminder.notes = composeNotesWithLink(notes: item.notes, url: item.url)
        reminder.url = item.url.flatMap { Foundation.URL(string: $0) }

        // 先移除旧闹钟再设置新的
        if let alarms = reminder.alarms {
            for alarm in alarms { reminder.removeAlarm(alarm) }
        }
        if let due = item.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            // 提前提醒用绝对闹钟：设置了提前量则在截止前提醒，未设置时兜底为准点提醒
            if let offset = item.alarmOffsetMinutes, offset > 0 {
                reminder.addAlarm(EKAlarm(absoluteDate: due.addingTimeInterval(-Double(offset * 60))))
            } else {
                reminder.addAlarm(EKAlarm(absoluteDate: due))
            }
        } else {
            // 无截止时间：绝对闹钟没有时间锚点，无法生成有效提醒；
            // 残留的提前量（旧数据硬编码 15 等）在此作废，避免「以为有提醒实际没有」
            reminder.dueDateComponents = nil
            if item.alarmOffsetMinutes != nil {
                logger.warning("待办无截止时间，忽略提前提醒设置：\(item.title)")
            }
        }

        // 优先级映射：EventKit 用 1-9（1=最高），0=无
        switch item.priority {
        case .high:   reminder.priority = 1
        case .medium: reminder.priority = 5
        case .low:    reminder.priority = 9
        case .none:   reminder.priority = 0
        }
    }

    /// 批量写入待办，返回更新后的待办列表及统计
    /// - Parameters:
    ///   - items: 待办列表（不可变，返回更新后的副本）
    ///   - calendarIdentifier: 目标列表 ID
    /// - Returns: (更新后的 items, 成功数, 失败数)
    func writeReminders(
        items: [TodoItem],
        to calendarIdentifier: String
    ) async -> (updatedItems: [TodoItem], success: Int, failed: Int) {
        var updated = items
        var success = 0
        var failed = 0
        // 本次批量新建的待提交项（下标 + 已生成的 reminderIdentifier）：
        // 逐条 commit 会让整批导出在主线程上串起几十次同步事务，故先 save(commit: false)，
        // 最后一次性 commit
        var pending: [(index: Int, identifier: String)] = []

        for index in updated.indices {
            // 已导出的项跳过，避免重复
            if updated[index].status == .exported, updated[index].reminderIdentifier != nil {
                continue
            }

            // 待办单独指定了目标列表则优先使用，否则写入调用方传入的默认列表
            let targetList = updated[index].targetListID.flatMap {
                $0.isEmpty ? nil : $0
            } ?? calendarIdentifier

            if let identifier = await writeReminder(item: updated[index], to: targetList, commit: false) {
                pending.append((index, identifier))
            } else {
                updated[index].status = .failed
                failed += 1
            }
        }

        // 一次性提交；失败意味着本批未落盘（EventKit 会丢弃未提交变更），整批计为失败
        if pending.isEmpty {
            return (updated, success, failed)
        }
        do {
            try store.commit()
            for entry in pending {
                updated[entry.index].reminderIdentifier = entry.identifier
                updated[entry.index].status = .exported
                success += 1
            }
            logger.info("待办批量提交成功：\(pending.count) 条")
        } catch {
            logger.error("待办批量提交失败：\(error.localizedDescription)")
            for entry in pending {
                updated[entry.index].status = .failed
                failed += 1
            }
        }

        return (updated, success, failed)
    }

    // MARK: - 更新

    /// 更新已写入的提醒事项（标题/备注/截止时间/优先级）
    /// - Parameters:
    ///   - identifier: EKReminder 的 calendarItemIdentifier
    ///   - item: 最新的待办数据
    /// - Returns: 更新成功返回 true，失败返回 false
    @discardableResult
    func updateReminder(identifier: String, with item: TodoItem) async -> Bool {
        guard isAuthorized else {
            logger.error("未授权提醒事项访问，无法更新")
            return false
        }
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            logger.warning("找不到提醒事项：\(identifier)，将重新创建")
            return false
        }
        applyItemFields(reminder, item: item)

        do {
            try store.save(reminder, commit: true)
            logger.info("提醒事项更新成功：\(item.title)")
            return true
        } catch {
            logger.error("提醒事项更新失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 删除

    /// 删除已写入的提醒事项（用于重新生成时清理旧项）
    /// - Returns: true 表示已删除或本就不存在；false 表示删除失败（调用方应提示用户）
    @discardableResult
    func deleteReminder(identifier: String) -> Bool {
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else { return true }
        do {
            try store.remove(reminder, commit: true)
            return true
        } catch {
            logger.warning("删除提醒事项失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 辅助

    /// 拼接备注与链接：macOS 26 UI 的 URL 栏不读 EventKit url 字段，
    /// 链接同时附在备注末尾保证在提醒事项中可见可点
    private func composeNotesWithLink(notes: String?, url: String?) -> String? {
        var parts: [String] = []
        if let n = notes, !n.isEmpty { parts.append(n) }
        if let u = url, !u.isEmpty { parts.append(u) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
