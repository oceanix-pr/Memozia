#if os(macOS)
import AppKit
import Observation
import Sparkle
import SwiftData
import os

/// 只在已同意隐私政策、持有持久数据库的主应用中启动；worker 和测试不联网。
@MainActor
@Observable
final class AppUpdateService: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdateService()
    private static let logger = Logger(subsystem: "app.memozia", category: "Updates")

    private(set) var isStarted = false
    private(set) var canCheckForUpdates = false
    private(set) var automaticChecks = false
    private(set) var installationRequested = false
    let installation = UpdateInstallationCoordinator()
    var isPreparingToInstall: Bool { installation.isPreparing }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var checkObservation: NSKeyValueObservation?
    @ObservationIgnored private var saveContext: (() throws -> Void)?
    @ObservationIgnored private var hasActiveFileOperation: () -> Bool = { false }

    func start(context: ModelContext, hasActiveFileOperation: @escaping () -> Bool) {
        guard !isStarted, !AppRuntime.isRunningTests, !AppRuntime.isUITesting,
              !MemoziaPrivacyPolicy.needsConsent() else { return }
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String else {
            Self.logger.debug("更新源未配置，更新器保持关闭")
            return
        }
        guard let url = URL(string: feed), url.scheme == "https", url.host != nil,
              Data(base64Encoded: key)?.count == 32 else {
            Self.logger.error("更新器配置无效，未启动")
            return
        }
        saveContext = { try context.save() }
        self.hasActiveFileOperation = hasActiveFileOperation
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        do {
            try controller.updater.start()
            isStarted = true
            automaticChecks = controller.updater.automaticallyChecksForUpdates
            canCheckForUpdates = controller.updater.canCheckForUpdates
            checkObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let available = change.newValue ?? false
                Task { @MainActor [weak self] in self?.canCheckForUpdates = available }
            }
        } catch {
            self.controller = nil
            Self.logger.error("更新器启动失败：\(error.localizedDescription)")
        }
    }

    func checkForUpdates() {
        guard isStarted, !MemoziaPrivacyPolicy.needsConsent(), !isPreparingToInstall else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard isStarted else { return }
        controller?.updater.automaticallyChecksForUpdates = enabled
        automaticChecks = enabled
    }

    private var isBusy: Bool {
        hasActiveFileOperation() || RecordingMergeActivity.shared.isRunning || MediaCleanupService.shared.isRunning
            || UpdatePermissionRepair.shared.isPreparing
            || FileSyncService.hasResourcesPreventingUpdate
            || MeetingRecorderService.shared.hasResourcesPreventingUpdate
            || ScreenVideoRecorder.hasResourcesPreventingUpdate
            || ScreenshotManager.shared.hasResourcesPreventingUpdate
            || TaskCenter.shared.hasActiveWork
            || !TaskCenter.shared.stoppingResourceClasses.isEmpty
            || !TaskCenter.shared.restartRequiredResourceClasses.isEmpty
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard !MemoziaPrivacyPolicy.needsConsent(), !isPreparingToInstall else {
            throw NSError(domain: "app.memozia.Updates", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "请稍后重试更新。")])
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationRequested = true
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        // 安装保护放在 App 自己的终止入口，覆盖 Sparkle 不调用此 delegate 的路径。
        installationRequested = true
        return false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        if !isPreparingToInstall { installationRequested = false }
        Self.logger.debug("更新周期结束，错误码：\((error as NSError).code)")
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        if !isPreparingToInstall { installationRequested = false }
    }

    /// 由 applicationShouldTerminate 的更新分支调用。失败必须 reply(false)，不走普通退出。
    func prepareForTermination() async -> Bool {
        do {
            try await installation.prepare(
                isBusy: { self.isBusy },
                save: {
                    guard let save = self.saveContext else {
                        throw UpdateInstallationCoordinator.PreparationError.persistence
                    }
                    try save()
                },
                stopWorker: {
                    await Task.detached(priority: .userInitiated) {
                        BackgroundWorker.requestWorkerStop().workerPID == nil
                    }.value
                },
                flush: { await EntryMirrorStore.shared.flush(timeout: .seconds(10)).isComplete }
            )
            return true
        } catch {
            // Sparkle 的重试可能不再发送 willInstallUpdate；保持更新退出语义，
            // 直到更新周期真正结束，避免重试时错误拉起旧 worker。
            TaskCenter.shared.resumeAfterUpdatePreparation()
            Self.logger.error("安装前收尾未完成，已取消本次退出")
            let alert = NSAlert()
            alert.messageText = String(localized: "暂时无法安装更新")
            alert.informativeText = String(localized: "请先结束录音、录屏和处理任务，并确认内容已保存，再重试安装更新。")
            alert.addButton(withTitle: String(localized: "好"))
            alert.runModal()
            return false
        }
    }
}
#endif
