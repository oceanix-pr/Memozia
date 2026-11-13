import Foundation
import CloudKit
import SwiftData
import Combine

/// iCloud 同步服务
/// 监控 CloudKit 同步状态，提供用户可见的同步反馈
@MainActor
@Observable
final class CloudSyncService {

    /// 同步状态
    enum SyncStatus: Equatable {
        case idle           // 空闲
        case syncing        // 同步中
        case success        // 同步成功
        case error(String)  // 同步失败
        case disabled       // 未登录 iCloud 或未启用
    }

    /// 当前同步状态
    private(set) var status: SyncStatus = .idle

    /// 上次同步时间
    private(set) var lastSyncDate: Date?

    /// 是否启用了 iCloud 同步
    var isSyncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudSyncEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "iCloudSyncEnabled") }
    }

    /// 检查 iCloud 账户状态
    func checkiCloudStatus() {
        CKContainer.default().accountStatus { [weak self] accountStatus, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error = error {
                    self.status = .error(error.localizedDescription)
                    return
                }

                switch accountStatus {
                case .available:
                    // iCloud 可用，同步状态保持 idle
                    if self.status == .disabled {
                        self.status = .idle
                    }
                case .noAccount, .couldNotDetermine, .temporarilyUnavailable:
                    self.status = .disabled
                case .restricted:
                    self.status = .disabled
                @unknown default:
                    self.status = .disabled
                }
            }
        }
    }

    /// 手动触发保存（通过保存上下文触发）
    ///
    /// 注意：SwiftData + CloudKit 的实际同步由系统后台异步完成，
    /// 此处无法立即得知同步结果。不做"sleep 1 秒即报成功"的虚假反馈，
    /// 仅如实更新本地保存时间；真实同步状态需通过持久化历史监控（待后续实现）。
    func triggerSync(context: ModelContext) {
        guard isSyncEnabled else {
            status = .disabled
            return
        }

        status = .syncing

        do {
            try context.save()
            // 本地保存成功：记录保存时间，状态回到 idle（不谎报"已同步"）
            lastSyncDate = Date()
            status = .idle
        } catch {
            status = .error(String(format: String(localized: "保存失败：%@"), error.localizedDescription))
        }
    }

    /// 状态显示文本
    var statusText: String {
        switch status {
        case .idle:        return lastSyncDate != nil ? String(localized: "已保存到本地") : String(localized: "就绪")
        case .syncing:     return String(localized: "保存中...")
        case .success:     return String(localized: "已同步")
        case .error(let msg): return String(format: String(localized: "保存错误：%@"), msg)
        case .disabled:    return String(localized: "iCloud 未启用")
        }
    }

    /// 状态图标
    var statusIcon: String {
        switch status {
        case .idle:        return "checkmark.icloud"
        case .syncing:     return "arrow.triangle.2.circlepath.icloud"
        case .success:     return "checkmark.icloud.fill"
        case .error:       return "exclamationmark.icloud"
        case .disabled:    return "icloud.slash"
        }
    }
}
