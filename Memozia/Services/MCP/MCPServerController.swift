import Foundation
import SwiftData
import Observation
import os.log

@MainActor
@Observable
final class MCPServerController {
    static let shared = MCPServerController()
    enum State: Equatable { case stopped, waiting, starting, listening, failed }
    private(set) var state = State.stopped
    private var context: ModelContext?
    private var listener: MCPLoopbackListener?
    private var router: MCPReadOnlyServer?
    private var preparation: Task<Void, Error>?
    private var stopping: Task<Void, Never>?
    private var generation = UUID()
    private let logger = Logger(subsystem: "app.memozia", category: "MCP")

    var statusText: String {
        switch state {
        case .stopped: String(localized: "已关闭")
        case .waiting: String(localized: "等待应用完成启动")
        case .starting: String(localized: "正在启动本机 MCP…")
        case .listening: String(localized: "本机 MCP 正在运行")
        case .failed: String(localized: "MCP 启动失败，请检查端口、数据文件夹或钥匙串权限后重试。")
        }
    }

    private var canServe: Bool {
        state == .listening && context != nil && DatabaseOwnershipLock.isHeld
            && !MemoziaPrivacyPolicy.needsConsent() && !AppUpdateService.shared.isPreparingToInstall
            && !FileSyncService.hasResourcesPreventingUpdate
            && !RecordingMergeActivity.shared.isRunning
            && MCPAccessStore.shared.enabled
    }

    func install(context: ModelContext, isTransient: Bool) async {
        guard !isTransient, DatabaseOwnershipLock.isHeld, !MemoziaPrivacyPolicy.needsConsent() else {
            await suspend()
            return
        }
        self.context = context
        await refresh()
    }

    func setEnabled(_ enabled: Bool) async {
        MCPAccessStore.shared.setEnabled(enabled)
        await refresh()
    }

    func stopAcceptingRequests() {
        generation = UUID()
        context = nil
        state = MCPAccessStore.shared.enabled ? .waiting : .stopped
        preparation?.cancel()
    }

    func suspend() async {
        stopAcceptingRequests()
        await stopServices()
    }

    func refresh() async {
        let current = UUID()
        generation = current
        state = .stopped
        await stopServices()
        guard current == generation else { return }
        let access = MCPAccessStore.shared
        guard access.enabled else { return }
        guard let context, DatabaseOwnershipLock.isHeld, !MemoziaPrivacyPolicy.needsConsent() else { state = .waiting; return }
        state = .starting
        do {
            let preparation = Task { try await EntryIdentityStore.prepare(context: context) }
            self.preparation = preparation
            try await preparation.value
            guard generation == current, access.enabled else { return }
            self.preparation = nil
            let query = EntryQueryService(context: context, checkAccess: { [weak self] grant in
                self?.canServe == true && access.isCurrent(grant)
            })
            let router = MCPReadOnlyServer(access: access, query: query, isReady: { [weak self] in self?.canServe == true })
            let listener = MCPLoopbackListener()
            self.router = router
            self.listener = listener
            _ = try await listener.start(port: access.port) { request in await router.handle(request) }
            guard generation == current, access.enabled else {
                await router.stop()
                try await listener.stop()
                return
            }
            state = .listening
            logger.info("本机只读 MCP 服务已启动")
        } catch {
            guard generation == current else { return }
            await stopServices()
            state = .failed
            logger.error("本机 MCP 启动失败：\(error.localizedDescription)")
            PersistenceReporting.reportSaveFailure(error)
        }
    }

    private func stopServices() async {
        preparation?.cancel()
        preparation = nil
        if let stopping { await stopping.value; return }
        let router = router
        let listener = listener
        self.router = nil
        self.listener = nil
        let task = Task {
            await router?.stop()
            do { try await listener?.stop() }
            catch { logger.error("关闭本机 MCP 监听失败：\(error.localizedDescription)") }
        }
        stopping = task
        await task.value
        stopping = nil
    }
}
