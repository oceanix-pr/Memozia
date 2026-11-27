import Foundation
import Observation

protocol TodoEntry: AnyObject {
    var id: UUID { get }
    var folderName: String { get }
    var folderURL: URL { get }
}

extension AudioRecording: TodoEntry {}
extension QuickNote: TodoEntry {}

private struct TodoEditConflict: LocalizedError {
    var errorDescription: String? { String(localized: "待办已被修改，请核对最新内容后重试。") }
}

@MainActor
protocol TodoReminderExporting: AnyObject {
    var isAuthorized: Bool { get }
    func requestAccess() async -> Bool
    func writeReminders(items: [TodoItem], to list: String) async -> (updatedItems: [TodoItem], success: Int, failed: Int)
    func deleteReminder(identifier: String) -> Bool
}

extension RemindersService: TodoReminderExporting {}

@MainActor @Observable
private final class TodoExports {
    static let shared = TodoExports()
    var active: Set<UUID> = []
}

struct TodoLocation: Equatable, Sendable {
    let id: UUID
    let folder: URL

    init?(_ entry: some TodoEntry) {
        guard !entry.folderName.isEmpty else { return nil }
        id = entry.id
        folder = entry.folderURL
    }
}

@MainActor @Observable
final class EntryTodoEditor {
    private(set) var location: TodoLocation?
    private(set) var document: TodoDocument?
    private(set) var ready = false
    var exporting: Set<UUID> { TodoExports.shared.active }
    private var revision = 0

    func select(_ target: TodoLocation?) {
        guard target != location else { return }
        location = target
        document = nil
        ready = false
        revision += 1
    }

    func load(_ target: TodoLocation?, report: @escaping @MainActor (String) -> Void) {
        select(target)
        guard let target else { return }
        revision += 1
        let expected = revision
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TodoDocument.read(from: target.folder) }
            }.value
            guard revision == expected else { return }
            switch result {
            case .success(let value): document = value; ready = true
            case .failure:
                document = nil
                ready = false
                report(String(localized: "条目文件缺失或无法读取。"))
            }
        }
    }

    /// 每次修改都从目标文件取得最新版本。只有原子写入成功后才替换当前展示的文档。
    func save(_ value: TodoDocument?, at target: TodoLocation) throws {
        let saved: TodoDocument?
        if let value { saved = try value.save(to: target.folder) }
        else { try TodoDocument.remove(from: target.folder); saved = nil }
        if location == target {
            revision += 1
            document = saved
            ready = true
        }
    }
}

@MainActor
protocol EntryTodoEditing: AnyObject {
    var todoEditor: EntryTodoEditor { get }
    var persistence: PersistenceGuard { get }
    func reportTodoError(_ message: String)
}

extension EntryTodoEditing {
    func currentTodoDocument(for entry: some TodoEntry) -> TodoDocument? {
        TodoLocation(entry) == todoEditor.location ? todoEditor.document : nil
    }
    var isWritingTodos: Bool { todoEditor.location.map { todoEditor.exporting.contains($0.id) } ?? false }

    func loadTodoDocument(for entry: some TodoEntry) {
        todoEditor.load(TodoLocation(entry), report: reportTodoError)
    }

    private func permitsTodoWrite() -> Bool {
        guard let rejection = persistence.rejection(for: .editTodo) else { return true }
        reportTodoError(rejection.message)
        return false
    }

    private func writeError(_ error: any Error) {
        reportTodoError(String(localized: "待办文件写入失败：\(UserFacingError.summary(for: error))"))
    }

    /// 生成操作可能跨越用户编辑。仅替换开始生成时读到的那一版。
    func saveExtracted(_ document: TodoDocument, for entry: some TodoEntry, replacing previous: TodoDocument?) throws -> Bool {
        guard permitsTodoWrite(), !document.items.isEmpty, let target = TodoLocation(entry),
              !todoEditor.exporting.contains(target.id) else { return false }
        guard try TodoDocument.read(from: target.folder) == previous else {
            if todoEditor.location == target { loadTodoDocument(for: entry) }
            throw TodoEditConflict()
        }
        try todoEditor.save(document, at: target)
        return true
    }

    @discardableResult
    private func edit(_ entry: some TodoEntry, change: (inout TodoDocument?) -> Void) -> TodoLocation? {
        guard permitsTodoWrite(), let target = TodoLocation(entry),
              target == todoEditor.location, !todoEditor.exporting.contains(target.id) else { return nil }
        do {
            let before = try TodoDocument.read(from: target.folder)
            var next = before
            change(&next)
            guard next != before else { return nil }
            try todoEditor.save(next, at: target)
            return target
        } catch { writeError(error); return nil }
    }

    func addTodoItem(_ item: TodoItem, for entry: some TodoEntry) {
        edit(entry) { doc in
            if doc == nil { doc = TodoDocument(source: "manual", model: String(localized: "手动添加")) }
            doc?.items.append(item)
        }
    }

    func updateTodoItem(_ item: TodoItem, for entry: some TodoEntry) {
        let savedTarget = edit(entry) { doc in
            guard let i = doc?.items.firstIndex(where: { $0.id == item.id }) else { return }
            doc?.items[i] = item
        }
        guard let target = savedTarget,
              item.status == .exported, let identifier = item.reminderIdentifier else { return }
        Task {
            guard !(await RemindersService.shared.updateReminder(identifier: identifier, with: item)) else { return }
            do {
                guard permitsTodoWrite(), var latest = try TodoDocument.read(from: target.folder),
                      let i = latest.items.firstIndex(of: item) else { return }
                latest.items[i].status = .failed
                try todoEditor.save(latest, at: target)
                reportTodoError(String(localized: "提醒事项同步更新失败，本地已保存。可重新点击「写入提醒事项」重试。"))
            } catch { writeError(error) }
        }
    }

    func deleteTodoItem(_ item: TodoItem, for entry: some TodoEntry) {
        removeTodos(for: entry) { $0.id == item.id }
    }

    func clearTodos(for entry: some TodoEntry) {
        removeTodos(for: entry) { _ in true }
    }

    private func removeTodos(for entry: some TodoEntry, matching matches: (TodoItem) -> Bool) {
        guard permitsTodoWrite(), let target = TodoLocation(entry),
              target == todoEditor.location, !todoEditor.exporting.contains(target.id) else { return }
        do {
            guard var doc = try TodoDocument.read(from: target.folder) else { return }
            let removed = doc.items.filter(matches)
            doc.items.removeAll(where: matches)
            try todoEditor.save(doc.items.isEmpty ? nil : doc, at: target)
            deleteLinkedReminders(in: removed)
        } catch { writeError(error) }
    }

    func deleteLinkedReminders(in items: [TodoItem], using service: any TodoReminderExporting = RemindersService.shared) {
        var failed = false
        for id in Set(items.compactMap(\.reminderIdentifier)) {
            if !service.deleteReminder(identifier: id) { failed = true }
        }
        if failed { reportTodoError(String(localized: "部分提醒事项删除失败，系统「提醒事项」中可能仍有残留。请手动打开提醒事项 App 删除。")) }
    }

    func writeTodosToReminders(for entry: some TodoEntry, defaultListID: String,
                               using service: any TodoReminderExporting = RemindersService.shared) async {
        guard permitsTodoWrite(), let target = TodoLocation(entry), target == todoEditor.location,
              TodoExports.shared.active.insert(target.id).inserted else { return }
        defer { TodoExports.shared.active.remove(target.id) }
        do {
            guard let original = currentTodoDocument(for: entry), !original.items.isEmpty else { return }
            if !service.isAuthorized {
                guard await service.requestAccess() else {
                    reportTodoError(String(localized: "未授权提醒事项访问，无法写入待办。\n请到「系统设置 → 隐私与安全性 → 提醒事项」中开启 Memozia，或在「应用设置 → 待办」中点击「请求授权」后重试。"))
                    return
                }
            }
            guard permitsTodoWrite() else { return }
            guard try TodoDocument.read(from: target.folder) == original else {
                if todoEditor.location == target { loadTodoDocument(for: entry) }
                reportTodoError(TodoEditConflict().localizedDescription)
                return
            }
            let result = await service.writeReminders(items: original.items, to: defaultListID)
            let receipts = zip(original.items, result.updatedItems).filter { $0 != $1 }
            let created = receipts.compactMap { before, after in
                after.status == .exported && after.reminderIdentifier != before.reminderIdentifier ? after : nil
            }
            guard permitsTodoWrite() else { deleteLinkedReminders(in: created, using: service); return }
            do {
                var latest = try TodoDocument.read(from: target.folder)
                // 只合并回执字段。生成提醒后若用户已删除对应待办，一并清理新建的提醒。
                for (before, after) in receipts {
                    guard let i = latest?.items.firstIndex(where: { $0.id == before.id }) else { continue }
                    let unchanged = latest?.items[i] == before
                    latest?.items[i].reminderIdentifier = after.reminderIdentifier
                    latest?.items[i].status = unchanged ? after.status : .failed
                }
                if let latest { try todoEditor.save(latest, at: target) }
                let retained = Set(latest?.items.map(\.id) ?? [])
                deleteLinkedReminders(in: created.filter { !retained.contains($0.id) }, using: service)
            } catch {
                deleteLinkedReminders(in: created, using: service)
                throw error
            }
            if result.failed > 0 {
                reportTodoError(service.isAuthorized
                    ? String(localized: "部分待办写入失败：成功 \(result.success) 个，失败 \(result.failed) 个")
                    : String(localized: "待办写入失败：提醒事项授权已失效。\n请到「系统设置 → 隐私与安全性 → 提醒事项」中重新开启 Memozia 后重试。"))
            }
        } catch { writeError(error) }
    }
}
