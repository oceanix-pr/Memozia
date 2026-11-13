#if os(macOS)
import Foundation
import Security
import Observation
import os.log
import Darwin

/// 临时签名更新后的授权衔接。只在主应用持有可写会话、已同意隐私政策时运行，
/// 新代码身份首次启动重置一次本应用的 TCC；不把完成标记当成系统已授权。
@MainActor
@Observable
final class UpdatePermissionRepair {
    nonisolated static let bundleID = "app.memozia"
    nonisolated static let identityKey = "Memozia_last_permission_repair_identity"
    static let shared = makeLive()

    private static func makeLive() -> UpdatePermissionRepair {
        UpdatePermissionRepair(
            snapshot: { liveSnapshot() },
            rememberedIdentity: { UserDefaults.standard.string(forKey: identityKey) },
            rememberIdentity: { UserDefaults.standard.set($0, forKey: identityKey) },
            runReset: { await TCCResetCommand.run() },
            persistentSession: false
        )
    }

    struct Snapshot: Sendable {
        var bundleID: String = UpdatePermissionRepair.bundleID
        var identity: String?
        var isAdHoc: Bool
        var isUnnotarizedDistribution: Bool = true
        var canReset: Bool = true
        var hasPriorInstallation: Bool = true
        var hasCaptureResources: Bool = false
    }

    enum Outcome: Equatable, Sendable {
        case notNeeded, reset, failed

        var message: String? {
            switch self {
            case .notNeeded: nil
            case .reset: String(localized: "旧版本系统授权已清理。首次使用相关功能时，请在系统弹窗中重新授权。")
            case .failed: String(localized: "旧版本系统授权未能自动清理。请完全退出 Memozia 后重试；若仍报未授权，可在系统设置移除旧记录并重新添加当前应用。")
            }
        }
    }

    private(set) var isPreparing = false
    private(set) var outcome = Outcome.notNeeded
    @ObservationIgnored private var persistentSession: Bool
    @ObservationIgnored private var attempt: Task<Outcome, Never>?
    @ObservationIgnored private var preparedForLaunch = false
    @ObservationIgnored private let snapshot: @MainActor () -> Snapshot
    @ObservationIgnored private let rememberedIdentity: @MainActor () -> String?
    @ObservationIgnored private let rememberIdentity: @MainActor (String) -> Void
    @ObservationIgnored private let runReset: @MainActor () async -> TCCResetCommand.Result
    private let logger = Logger(subsystem: "app.memozia", category: "PermissionRepair")

    init(snapshot: @escaping @MainActor () -> Snapshot, rememberedIdentity: @escaping @MainActor () -> String?,
         rememberIdentity: @escaping @MainActor (String) -> Void, runReset: @escaping @MainActor () async -> TCCResetCommand.Result,
         persistentSession: Bool = true) {
        self.snapshot = snapshot
        self.rememberedIdentity = rememberedIdentity
        self.rememberIdentity = rememberIdentity
        self.runReset = runReset
        self.persistentSession = persistentSession
    }

    func configureSession(isPersistent: Bool) { persistentSession = isPersistent }

    var needsPreparation: Bool {
        if isPreparing { return true }
        guard persistentSession, !preparedForLaunch else { return false }
        let current = snapshot()
        return current.canReset && current.isUnnotarizedDistribution
    }

    /// 同一启动期间多个窗口/热键共享一个执行体；失败留待下次启动重试，避免使用中再撤销授权。
    @discardableResult
    func prepareIfNeeded() async -> Outcome {
        if let attempt { return await attempt.value }
        guard persistentSession, !preparedForLaunch else { return outcome }
        let current = snapshot()
        guard current.canReset, current.bundleID == Self.bundleID else { return .notNeeded }
        guard current.isUnnotarizedDistribution else {
            preparedForLaunch = true
            return .notNeeded
        }
        guard let identity = current.identity else {
            preparedForLaunch = true
            if current.isAdHoc {
                logger.error("无法读取当前代码签名身份，保留授权并提示用户")
                outcome = .failed
            }
            return outcome
        }
        if !current.isAdHoc || rememberedIdentity() == identity ||
            (rememberedIdentity() == nil && !current.hasPriorInstallation) {
            rememberIdentity(identity)
            preparedForLaunch = true
            return .notNeeded
        }
        guard !current.hasCaptureResources else {
            logger.warning("仍有采集资源，保留本次授权，留待下次启动修复")
            preparedForLaunch = true
            outcome = .failed
            return outcome
        }
        isPreparing = true
        let task = Task { @MainActor in
            let result = await self.runReset()
            if result == .success {
                self.rememberIdentity(identity)
                self.logger.info("已清理本应用旧代码身份的 TCC 授权，后续由系统重新征求同意")
                self.outcome = .reset
            } else {
                self.logger.error("本应用旧授权清理失败：\(String(describing: result), privacy: .public)")
                self.outcome = .failed
            }
            self.preparedForLaunch = true
            self.isPreparing = false
            return self.outcome
        }
        attempt = task
        return await task.value
    }

    private static func liveSnapshot() -> Snapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        let signing = signingIdentity()
        let isUnnotarized = info["MemoziaUnnotarizedBuild"] as? Bool == true ||
            info["MemoziaUnnotarizedBuild"] as? String == "YES"
        let version = info["CFBundleVersion"] as? String ?? ""
        return Snapshot(
            bundleID: Bundle.main.bundleIdentifier ?? "",
            identity: signing.map { version + ":" + $0.hash },
            isAdHoc: signing?.isAdHoc ?? isUnnotarized,
            isUnnotarizedDistribution: isUnnotarized,
            canReset: !AppRuntime.isRunningTests && !AppRuntime.isUITesting &&
                !ProcessInfo.processInfo.arguments.contains(BackgroundWorker.launchFlag) &&
                DatabaseOwnershipLock.isHeld && !MemoziaPrivacyPolicy.needsConsent(),
            hasPriorInstallation: UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
            hasCaptureResources: MeetingRecorderService.shared.hasResourcesPreventingUpdate ||
                ScreenshotManager.shared.hasResourcesPreventingUpdate || ScreenVideoRecorder.hasResourcesPreventingUpdate
        )
    }

    static func signingIdentity() -> (hash: String, isAdHoc: Bool)? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var information: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber else { return nil }
        return (hash.map { String(format: "%02x", $0) }.joined(), SecCodeSignatureFlags(rawValue: flags.uint32Value).contains(.adhoc))
    }
}

/// 系统工具只按固定 Bundle ID 重置本应用；不使用 shell、不提权、不直接读写 TCC 数据库。
enum TCCResetCommand {
    enum Result: Sendable, Equatable { case success, failed(Int32), timedOut, cancelled, launchFailed }
    static let executable = URL(fileURLWithPath: "/usr/bin/tccutil")
    static let arguments = ["reset", "All", "app.memozia"]

    static func run() async -> Result {
        await execute(executable: executable, arguments: arguments, timeout: 5)
    }

    static func execute(executable: URL, arguments: [String], timeout: TimeInterval) async -> Result {
        let worker = Task.detached(priority: .userInitiated) {
            runSynchronously(executable: executable, arguments: arguments, timeout: timeout)
        }
        return await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    }

    /// Process 始终只在该后台同步栈内访问，无跨 actor 传递；超时/取消直接结束子进程并返回。
    private static func runSynchronously(executable: URL, arguments: [String], timeout: TimeInterval) -> Result {
        guard !Task<Never, Never>.isCancelled else { return .cancelled }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .launchFailed }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while process.isRunning {
            if Task<Never, Never>.isCancelled {
                kill(process.processIdentifier, SIGKILL)
                return .cancelled
            }
            if ContinuousClock.now >= deadline {
                kill(process.processIdentifier, SIGKILL)
                return .timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return process.terminationStatus == 0 ? .success : .failed(process.terminationStatus)
    }
}
#endif
