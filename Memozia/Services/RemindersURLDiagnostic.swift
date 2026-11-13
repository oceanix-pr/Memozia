#if os(macOS)
import Foundation
import EventKit
import os.log

/// 一次性诊断：仅用合成数据验证 EKReminder.url 的持久化。
/// 触发方式：defaults write app.memozia reminders_url_diagnostic -bool true
/// 结果写入 ~/Documents/Memozia/url_diagnostic.txt，随后清除触发标记。
enum RemindersURLDiagnostic {

    private static let logger = Logger(subsystem: "app.memozia", category: "URLDiagnostic")
    private static let flagKey = "reminders_url_diagnostic"

    @MainActor
    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: flagKey) else { return }
        UserDefaults.standard.removeObject(forKey: flagKey)
        Task { @MainActor in
            let lines = await run()
            let outURL = AudioRecording.storageDirectory.appendingPathComponent("url_diagnostic.txt")
            do {
                try lines.joined(separator: "\n").write(to: outURL, atomically: true, encoding: .utf8)
                logger.notice("提醒事项 URL 字段诊断完成")
            } catch {
                logger.error("提醒事项 URL 字段诊断报告写入失败")
            }
        }
    }

    @MainActor
    private static func run() async -> [String] {
        let store = EKEventStore()
        var lines = ["=== Reminders URL 字段诊断 \(Date()) ==="]

        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        } else {
            granted = (try? await store.requestAccess(to: .reminder)) ?? false
        }
        lines.append("授权: \(granted)")
        guard granted else { return lines }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            lines.append("默认提醒列表不可用")
            return lines
        }
        guard let testURL = URL(string: "https://example.com/memozia-url-diagnostic") else {
            lines.append("诊断地址无效")
            return lines
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = "Memozia URL 诊断"
        reminder.url = testURL
        do {
            try store.save(reminder, commit: true)
        } catch {
            lines.append("合成提醒保存: 失败")
            return lines
        }

        let savedID = reminder.calendarItemIdentifier
        let sameStoreURL = (store.calendarItem(withIdentifier: savedID) as? EKReminder)?.url
        lines.append("同一存储回读: \(sameStoreURL == testURL ? "成功" : "失败")")

        let freshStore = EKEventStore()
        let freshStoreURL = (freshStore.calendarItem(withIdentifier: savedID) as? EKReminder)?.url
        lines.append("新存储回读: \(freshStoreURL == testURL ? "成功" : "失败")")

        do {
            try store.remove(reminder, commit: true)
            lines.append("合成提醒清理: 成功")
        } catch {
            lines.append("合成提醒清理: 失败")
            logger.error("提醒事项 URL 字段诊断的合成提醒清理失败")
        }
        return lines
    }
}
#endif
