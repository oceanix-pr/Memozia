import SwiftUI
import SwiftData
import os.log
#if os(macOS)
import AppKit

enum AppRuntime {
    /// XCTest/Swift Testing 的 host 会启动应用可执行文件；测试必须跳过单实例退出、
    /// worker 握手与真实数据库，否则已运行的 Memozia 会让测试宿主在连接前退出。
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment["DYLD_INSERT_LIBRARIES"]?.contains("XCTestBundleInject") == true
            || ProcessInfo.processInfo.arguments.contains { $0.contains(".xctest") }
            || NSClassFromString("XCTestCase") != nil
    }

    /// XCUITest 驱动的进程：由测试以 `--ui-testing` 启动参数标记。
    ///
    /// 与 `isRunningTests` 的区别：被 UI 测试驱动的进程仍是**正常**进程（渲染真实界面、
    /// 走正常启动流程），只是必须跳过单实例守卫——否则用户机器上已有一个实例在运行时，
    /// 被测进程会在 UI 出现前 exit(0)，UI 测试永远拿不到窗口。
    static var isUITesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing")
    }
}

/// 单实例守卫：进程启动最早期的重复实例检查
///
/// 在 App 结构体初始化时调用（早于 ModelContainer、NSApplication 运行与一切 UI）：
/// 检测到已有实例时唤醒它并立即 exit(0)，确保不会出现第二个窗口。
/// 不能用 NSApp.terminate：它要等 run loop 启动后才真正退出，期间新实例的
/// Dock 图标/窗口已经出现，用户会看到“又打开了一个新实例”。
enum SingleInstanceGuard {
    private static let logger = Logger(subsystem: "app.memozia", category: "SingleInstance")

    static func exitIfDuplicateInstance() {
        guard !AppRuntime.isRunningTests, !AppRuntime.isUITesting else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let workerPID = BackgroundWorker.liveWorkerPID()
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != currentPID }
            // 守护进程是同 bundle 的合法第二实例，不参与重复实例判定
            .filter { $0.processIdentifier != workerPID }
        guard let existing = others.first else { return }

        // 新旧判定：正常 PID 递增、较大者为新；macOS PID 到 99998 会回绕，
        // 回绕后旧实例 PID 反而更大——差值超过半个回绕区间视为“对方其实更早启动”，
        // 当前进程仍是较新者应退出。避免双实例同时启动时互相判定导致双双退出。
        let existingPID = existing.processIdentifier
        let iAmNewer = currentPID > existingPID || (existingPID - currentPID) > 49_999
        guard iAmNewer else { return }

        logger.notice("检测到已有实例 PID=\(existingPID)，当前新实例 PID=\(currentPID)，唤醒已有实例并立即退出")
        // 唤醒已有实例：activate 会触发其 becomeActive 恢复被隐藏的主窗口；分布式通知兜底
        existing.activate(from: .current, options: [.activateAllWindows])
        DistributedNotificationCenter.default().postNotificationName(
            .MemoziaShowMainWindowFromOtherInstance,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        // 立即退出：此刻 ModelContainer 与一切 UI 均未初始化；
        // 新实例尚未加载模型/未开始录音，无需走正常退出流程卸载资源。
        // 用 _exit 跳过静态析构（onnxruntime 全局对象在 exit() 析构时会 abort）
        ProcessLimits.exitSkippingStaticDestructors(0)
    }
}

/// 进程资源限制调整：长录音停止合并会短暂同时持有大量文件句柄
/// （AVMutableComposition 同时引用全部分片 AVURLAsset），macOS GUI 应用默认软限制
/// 偏低，耗尽后 SQLite 无法打开数据库文件，导致 SwiftData 保存失败
/// （“未能打开文件 default.store”）；启动时抬高软限制从根源上避免
enum ProcessLimits {
    private static let logger = Logger(subsystem: "app.memozia", category: "ProcessLimits")

    /// 把文件描述符软限制抬高：目标 4096，不超过硬限制；失败不致命仅记录日志
    static func raiseFileDescriptorLimit() {
        var limits = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limits) == 0 else { return }
        guard limits.rlim_cur < 4096 else { return }
        limits.rlim_cur = min(4096, limits.rlim_max)
        if setrlimit(RLIMIT_NOFILE, &limits) != 0 {
            logger.warning("抬高文件描述符限制失败: errno=\(errno)")
        } else {
            logger.info("文件描述符软限制已抬高至 \(limits.rlim_cur)")
        }
    }

    /// 当前进程打开的文件描述符数量（诊断用；不可用时返回 -1）。
    /// 12 = F_COUNTFDS（Darwin 头文件常量，未导入 Swift overlay 故用字面量）
    static func openFileDescriptorCount() -> Int32 {
        fcntl(0, 12, 0)
    }

    /// 立即结束进程，**跳过 `exit()` 的 C++ 静态析构阶段**。
    ///
    /// 为什么不用 `exit(0)`：onnxruntime / sherpa-onnx 的静态全局对象在退出时由
    /// `__cxa_finalize_ranges` 析构，实测会 abort —— DiagnosticReports 里的退出崩溃
    /// （`EXC_CRASH/SIGABRT`、`abort() called`）栈就是
    /// `__cxa_finalize_ranges → ~unordered_set/~unordered_map → pthread_mutex_unlock → abort`，
    /// 且帧里带 `onnx::checker::experimental_ops`；表现为「用过说话人分离后退出应用必崩」。
    /// `_exit(2)` 直接触发进程终止系统调用，不跑 atexit 与静态析构，从根上绕开这段第三方代码。
    ///
    /// 调用方必须先完成自己的持久化：本项目的落盘（录音分片收尾、条目镜像 flush、SwiftData
    /// `save()`、后台队列派发）都是**显式写入**，不依赖 atexit。退出前冲刷 stdio，
    /// 避免校准工具等命令行路径的 `print` 输出被吞
    static func exitSkippingStaticDestructors(_ code: Int32 = 0) -> Never {
        fflush(stdout)
        fflush(stderr)
        _exit(code)
    }
}

/// 应用代理：负责启动菜单栏控制器
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// nonisolated：Logger 为 Sendable 且为 let，解除 MainActor 隔离后可在 @Sendable 闭包中引用
    nonisolated private static let logger = Logger(subsystem: "app.memozia", category: "SingleInstance")

    /// 其他实例请求显示主窗口的分布式通知观察者（需持有，释放后监听会失效）
    private var showWindowObserver: NSObjectProtocol?
    private var terminationInProgress = false

    /// 单实例守卫兜底：正常情况下重复实例已在 App 初始化阶段（SingleInstanceGuard）退出，
    /// 此处作为防御性备份（例如未来启动顺序变化时仍能拦截）。
    nonisolated func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeOnMainThread {
            guard !AppRuntime.isRunningTests, !AppRuntime.isUITesting else { return }
            guard let bundleID = Bundle.main.bundleIdentifier else { return }
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let workerPID = BackgroundWorker.liveWorkerPID()
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != currentPID }
                .filter { $0.processIdentifier != workerPID }
            guard let existing = others.first else { return }
            let existingPID = existing.processIdentifier
            let iAmNewer = currentPID > existingPID || (existingPID - currentPID) > 49_999
            guard iAmNewer else { return }
            Self.logger.notice("兜底拦截：检测到已有实例 PID=\(existingPID)，当前新实例退出")
            existing.activate(from: .current, options: [.activateAllWindows])
            DistributedNotificationCenter.default().postNotificationName(
                .MemoziaShowMainWindowFromOtherInstance,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            // 此时已过 App 初始化，用 _exit 仍可避免 terminate 等待 run loop 造成的窗口闪现；
            // 新实例未加载模型/未开始录音，无需正常退出流程；同时跳过 exit() 的静态析构
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
    }

    /// nonisolated + assumeOnMainThread：避免在 AppKit 同步回调（无 Task 上下文）上
    /// 走 MainActor.assumeIsolated 的 executor 断言（macOS 26 上可能读坏指针崩溃），
    /// 只做主线程检查后直接进入 MainActor 上下文
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeOnMainThread {
            guard !AppRuntime.isRunningTests else { return }
            MenuBarController.shared.start()
            // 截图全局热键（Carbon RegisterEventHotKey）：应用未激活时也可触发截图
            GlobalHotkeyManager.shared.start()
            // 一次性诊断（需 defaults write app.memozia reminders_url_diagnostic -bool true 触发）
            RemindersURLDiagnostic.runIfRequested()
            // 监听其他实例发来的「显示主窗口」分布式通知：
            // 隐藏主窗口后点 Dock 图标会误启动新实例，新实例退出前会发此通知，
            // 收到后恢复主窗口，表现为“点 Dock 图标即可恢复”，而非出现新实例
            showWindowObserver = DistributedNotificationCenter.default().addObserver(
                forName: .MemoziaShowMainWindowFromOtherInstance,
                object: nil,
                queue: .main
            ) { _ in
                AppDelegate.logger.notice("收到其他实例的显示主窗口请求，恢复主窗口")
                Task { @MainActor in
                    MenuBarController.shared.showMainWindow()
                }
            }
        }
    }

    /// 点击 Dock 图标时，若主窗口已隐藏则重新显示。
    ///
    /// 返回值条件化（兼顾防双窗口与窗口丢失恢复）：
    /// - 窗口存在：自己恢复并返回 false。若返回 true，AppKit/SwiftUI 会继续执行默认
    ///   reopen——而此刻 showMainWindow 里的 makeKeyAndOrderFront 尚在 DispatchQueue.main.async
    ///   中排队（AppKit 眼里“无可见窗口”），SwiftUI 的 WindowGroup 便会再新建一个窗口，
    ///   同一进程出现两个主窗口（隐藏主窗口后点 Dock 图标即触发）；
    /// - 窗口已丢失（policy 反复切换被 SwiftUI 销毁等）：showMainWindow 无窗口可显示，
    ///   返回 true 放行系统默认 reopen，让 SwiftUI 重建窗口，避免点 Dock 永远无反应。
    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeOnMainThread {
            // 同步枚举无竞态：窗口存在才自己处理；空列表时才放行重建，
            // 不存在“窗口存在但异步显示未完成”的中间态，不会回潮双窗口问题
            guard !MenuBarController.shared.mainWindows.isEmpty else {
                AppDelegate.logger.notice("applicationShouldHandleReopen：窗口列表为空，放行默认 reopen 重建窗口")
                return true
            }
            // 注意：最小化（miniaturized）窗口在 flag 中也算“可见”，
            // 所以不能只在 flag=false 时恢复；统一交给 showMainWindow（幂等），
            // 内部会 deminiaturize 最小化窗口
            Self.logger.notice("applicationShouldHandleReopen flag=\(flag)，拦截默认 reopen 行为并恢复主窗口")
            MenuBarController.shared.showMainWindow()
            return false
        }
    }

    /// 兜底恢复：应用处于 accessory（主窗口被隐藏）状态时被重新激活时恢复主窗口。
    /// 覆盖两类路径：1) 新实例退出前 activate 了本实例；2) 点 Dock 图标直接唤醒隐藏的已有实例。
    /// 仅在 accessory 状态生效，避免干扰正常的激活（此时激活策略已为 .regular，guard 直接返回）。
    nonisolated func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeOnMainThread {
            guard NSApp.activationPolicy() == .accessory else { return }
            AppDelegate.logger.notice("accessory 状态下被激活，恢复主窗口")
            MenuBarController.shared.showMainWindow()
        }
    }

    /// 退出前：若正在录音先紧急收尾（finalize 临时文件，下次启动自动恢复合并），再卸载 Whisper 模型。
    /// 合并进行中则先等待合并收尾再走退出流程，避免 Cmd+Q 杀死导出
    /// 留下半成品 m4a 与 .merging 标记（20260910 事故成因之一）；
    /// 用 terminateLater 把退出时机交给异步收尾（不阻塞主线程），
    /// 收尾完成后由 completeTerminationFlow 直接结束进程（跳过 `exit()` 的静态析构）
    nonisolated func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeOnMainThread {
            guard !terminationInProgress else { return .terminateLater }
            terminationInProgress = true
            if AppUpdateService.shared.installationRequested {
                Task { @MainActor in
                    guard await AppUpdateService.shared.prepareForTermination() else {
                        self.terminationInProgress = false
                        sender.reply(toApplicationShouldTerminate: false)
                        return
                    }
                    // 更新退出不生成旧 worker；已落盘队列由新版启动后恢复。
                    if WhisperLocalService.shared.hasLoadedModel {
                        await WhisperLocalService.shared.unloadModel()
                    }
                    ProcessLimits.exitSkippingStaticDestructors(0)
                }
                return .terminateLater
            }
            if RecordingMergeActivity.shared.isRunning || MediaCleanupService.shared.isRunning || UpdatePermissionRepair.shared.isPreparing {
                Task { @MainActor in
                    // 导出本身由有界看门狗保护；等待事务完成，避免提交/删除中途退出。
                    while RecordingMergeActivity.shared.isRunning || MediaCleanupService.shared.isRunning || UpdatePermissionRepair.shared.isPreparing {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    Self.completeTerminationFlow()
                }
                return .terminateLater
            }
            if MeetingRecorderService.shared.isMerging {
                let waitSeconds = Self.mergeWaitSeconds()
                Self.logger.notice("合并进行中，等待合并完成后再退出（按看门狗同源预计最多 \(Int(waitSeconds))s）")
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(waitSeconds)
                    while MeetingRecorderService.shared.isMerging, Date() < deadline {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    if MeetingRecorderService.shared.isMerging {
                        // 等待到期仍未完成：强退。此时 .merging 是 PID 化标记，
                        // 下次启动识别到进程已死会立即过期并按分片重建，不会丢录音
                        Self.logger.warning("等待合并收尾到期仍未完，强制退出；分片将由下次启动恢复拼接")
                    }
                    Self.completeTerminationFlow()
                }
                return .terminateLater
            }
            Self.completeTerminationFlow()
            // completeTerminationFlow 收尾完成后**自行结束进程**（不再 reply）：
            // 避开 AppKit terminate → exit() 阶段 onnxruntime 静态析构的 abort。
            // 这里返回 .terminateLater 只是不让 AppKit 抢先走它自己的退出路径
            return .terminateLater
        }
    }

    /// 退出前等待合并的时长：与导出看门狗同源（本次合并的预计完成时刻 + 少量余量），
    /// 并限定在 [30s, 900s]：下限保证极短合并也能等完，上限避免“退出时无限转圈”
    private static func mergeWaitSeconds() -> TimeInterval {
        let projected = MeetingRecorderService.shared.mergeProjectedFinishAt.map {
            $0.timeIntervalSinceNow + 30
        }
        return min(max(projected ?? 300, 30), 900)
    }

    /// 退出收尾统一入口（合并等待完成后调用）：
    /// 紧急收尾录音 → 等待条目镜像落盘 → 拉起守护进程 → 卸载模型 → 结束进程。
    /// 收尾完成后**不走 `NSApp.reply` → AppKit terminate → `exit()`**：那一步会在
    /// onnxruntime 的静态全局对象析构时 abort（见 `ProcessLimits.exitSkippingStaticDestructors`）。
    /// 本方法保证不返回，因此外层返回的 `.terminateLater` 只是把退出时机交给我们自己
    @MainActor
    private static func completeTerminationFlow() {
        let service = WhisperLocalService.shared
        let needsUnload = service.hasLoadedModel
        Task { @MainActor in
            MCPServerController.shared.stopAcceptingRequests()
            // 先等待采集资源收尾（内部有界看门狗），再启动 worker。
            await MeetingRecorderService.shared.finalizeForTermination()
            await MCPServerController.shared.suspend()
            // 条目镜像（转写/总结/画面要点）此前是 fire-and-forget 写入：刚保存完就退出、
            // 被系统终止时会丢掉最后一次修改，而磁盘对账又会跳过已入库条目，下次启动也补不回来。
            // 有界等待（超时只记 fault，不阻塞退出）。flush 返回结构化结果，据此记录
            // 哪些条目未完成：未落盘目标已留下恢复标记，下次启动由磁盘对账补写
            let mirrorResult = await EntryMirrorStore.shared.flush(timeout: .seconds(10))
            if !mirrorResult.isComplete {
                Self.logger.warning(
                    "退出时条目镜像未全部落盘：成功 \(mirrorResult.succeeded)，失败 \(mirrorResult.failed)，未完成目标 \(mirrorResult.remaining.joined(separator: ", "))；将由下次启动的磁盘对账补写"
                )
            }
            // 仍有用户发起的未完成任务（转写/总结）或未合并分片时，拉起守护进程续跑；
            // 必须在进程退出前同步启动（后台任务队列与分片状态均已落盘）。
            // 位于合并等待与镜像 flush 之后：worker 读到的是收尾完成的磁盘状态
            BackgroundWorker.spawnIfNeeded()
            if needsUnload {
                await service.unloadModel()
            }
            // 以上持久化全部是显式写入，此刻结束进程不会丢数据
            ProcessLimits.exitSkippingStaticDestructors(0)
        }
    }
}
#elseif os(iOS)
/* ---- iOS 专属分支（工程已改为仅 macOS，注释保留以备不时之需）----
import UIKit

/// iOS 应用代理：退出前收尾录音并卸载 Whisper 模型
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated func applicationWillTerminate(_ application: UIApplication) {
        // 回调在主线程执行；卸载内部用 detached 任务 + 信号量，不阻塞 MainActor
        MainActor.assumeOnMainThread {
            // 录音中退出时紧急收尾，避免整段录音因临时文件未 finalize 而损坏
            MeetingRecorderService.shared.finalizeForTermination()
            WhisperLocalService.shared.unloadModelBlocking()
        }
    }
}
---- 结束 iOS 分支注释 ---- */
#endif

@main
struct MemoziaApp: App {

    #if os(macOS)
    /// 校准钩子：声明在单实例守卫之前，带 --calibrate-diarization 启动参数时
    /// 执行聚类阈值校准并直接退出（不进入 UI，也不受单实例拦截）；正常启动零开销
    private let calibrationHook: Void = DiarizationCalibrator.runIfRequested()
    /// 守护进程钩子：带 --background-worker 启动参数时执行后台任务主循环（转写/总结/
    /// 分片合并续跑）并直接退出，不进入 UI；声明在单实例守卫之前，天然跳过重复实例拦截
    private let backgroundWorkerHook: Void = BackgroundWorker.runIfRequested()
    /// 运行时验证钩子：声明在单实例守卫之前，带 --verify-startup / --print-db-lock-path /
    /// --verify-memory / --verify-filesync 启动参数时执行对应无界面自检并直接退出；
    /// 正常启动零开销，且不改变上面既有钩子的相对顺序
    private let runtimeVerificationHook: Void = RuntimeVerification.runIfRequested()
    /// 单实例守卫：声明在最前，App 结构体初始化时最先执行（早于 ModelContainer 与一切 UI）；
    /// 检测到已有实例立即 exit(0) 退出，从根本上避免第二个窗口出现
    /// （守护进程已被识别为合法第二实例，不触发拦截）
    private let singleInstanceGuard: Void = SingleInstanceGuard.exitIfDuplicateInstance()
    /// 文件描述符限制：声明在容器创建之前，确保数据库打开前软限制已抬高，
    /// 避免长录音停止合并的句柄峰值耗尽默认限制导致 SwiftData 保存失败
    /// （容器改由 `StartupCoordinator` 异步创建，但本属性在 App 初始化时即同步执行，
    /// 仍早于任何可写容器打开）
    private let fdLimitBoost: Void = ProcessLimits.raiseFileDescriptorLimit()

    #if os(macOS)
    /// 界面语言选择（与菜单栏状态图标菜单共用偏好键）：
    /// 空 = 跟随系统；变更后由 MenuBarController 写入 AppleLanguages 并弹重启询问
    @AppStorage(MenuBarController.appLanguageDefaultsKey) private var interfaceLanguage = ""
    @AppStorage(AppExperiencePreference.defaultsKey)
    private var experienceRawValue = AppExperiencePreference.resolved().rawValue

    private var currentExperience: AppExperience {
        AppExperience(rawValue: experienceRawValue) ?? .standard
    }
    #endif

    /// 启动协调器：worker 握手、数据库独占锁、容器创建全部异步执行（阻塞步骤进 detached），
    /// 主线程先显示不依赖 SwiftData 的轻量启动界面，避免最坏数秒无窗口的启动假死
    @State private var startup = StartupCoordinator(dependencies: .live())

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(iOS)
    /* iOS 专属分支：@UIApplicationDelegateAdaptor（已注释，工程仅支持 macOS）
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    */
    #endif

    var body: some Scene {
        WindowGroup {
            if AppRuntime.isRunningTests {
                // XCTest 只需要一个存活的 host。不构造启动/主界面，避免测试期间
                // 触发真实握手、真实数据库、磁盘对账、Keychain 迁移或快捷键注册。
                Color.clear.frame(width: 1, height: 1)
            } else {
                StartupRootView(coordinator: startup)
            }
        }
        #if os(macOS)
        .commands {
            // 主链路入口的窗口内快捷键：此前主链路（导入 / 新建笔记）只能点工具栏，
            // 而 ⌘R/⌘H 只在菜单栏展开时可用。这里补上最常用的两个（⌘N / ⌘O），
            // 通过通知交给 RootView 打开对应面板（与设置/帮助命令同一套机制）
            CommandGroup(replacing: .newItem) {
                // 名称与快捷键来自统一命令描述（AppCommandCatalog）：
                // 与菜单栏状态项菜单、帮助页「快捷键」小节、设置搜索是同一份事实源
                let newNote = AppCommandCatalog.descriptor(for: .newQuickNote)
                let importMedia = AppCommandCatalog.descriptor(for: .importMedia)

                Button(newNote.localizedTitle) {
                    NotificationCenter.default.post(name: .appMenuNewQuickNote, object: nil)
                }
                .commandShortcut(newNote.shortcut)

                Button(importMedia.localizedTitle) {
                    NotificationCenter.default.post(name: .appMenuImportMedia, object: nil)
                }
                .commandShortcut(importMedia.shortcut)
            }
            // 截图命令（区域/窗口/全屏），应用内快捷键；全局热键由 Carbon 注册（默认 ⌃⌘S）
            CommandGroup(after: .newItem) {
                let region = AppCommandCatalog.descriptor(for: .captureRegion)
                let captureWindow = AppCommandCatalog.descriptor(for: .captureWindow)
                let captureFullScreen = AppCommandCatalog.descriptor(for: .captureFullScreen)

                Button(region.localizedTitle) {
                    ScreenshotManager.shared.startCapture(mode: .region)
                }
                .commandShortcut(region.shortcut)

                if currentExperience == .pro {
                    Button(captureWindow.localizedTitle) {
                        ScreenshotManager.shared.startCapture(mode: .window)
                    }
                    .commandShortcut(captureWindow.shortcut)

                    Button(captureFullScreen.localizedTitle) {
                        ScreenshotManager.shared.startCapture(mode: .fullscreen)
                    }
                    .commandShortcut(captureFullScreen.shortcut)
                }
            }
            // 切换语言 + 设置命令：均放在 App 菜单中「关于 Memozia」下方，
            // 切换语言在「设置」上方（与菜单栏状态图标菜单同构）
            CommandGroup(replacing: .appSettings) {
                Menu("切换语言") {
                    // 跟随系统（默认勾选）：空代码 = 恢复系统级语言解析
                    Button {
                        MenuBarController.applyInterfaceLanguage("")
                    } label: {
                        if interfaceLanguage.isEmpty {
                            Label("跟随系统", systemImage: "checkmark")
                        } else {
                            Text("跟随系统")
                        }
                    }
                    Divider()
                    // 语言名称用该语言的自称（Text(String 变量) 走 verbatim，不作为本地化 key）
                    ForEach(MenuBarController.availableLanguages, id: \.code) { lang in
                        Button {
                            MenuBarController.applyInterfaceLanguage(lang.code)
                        } label: {
                            if interfaceLanguage == lang.code {
                                Label(lang.nativeName, systemImage: "checkmark")
                            } else {
                                Text(lang.nativeName)
                            }
                        }
                    }
                }

                Button(AppCommandCatalog.descriptor(for: .openSettings).localizedTitle) {
                    NotificationCenter.default.post(name: .menuBarOpenSettings, object: nil)
                }
                .commandShortcut(AppCommandCatalog.descriptor(for: .openSettings).shortcut)
            }
            CommandGroup(after: .appInfo) {
                if AppUpdateService.shared.isStarted {
                    Button("检查更新…") { AppUpdateService.shared.checkForUpdates() }
                        .disabled(!AppUpdateService.shared.canCheckForUpdates
                                  || AppUpdateService.shared.isPreparingToInstall)
                }
            }
            // 帮助菜单
            CommandGroup(replacing: .help) {
                Button(AppCommandCatalog.descriptor(for: .openHelp).localizedTitle) {
                    NotificationCenter.default.post(name: .openHelp, object: nil)
                }
                .commandShortcut(AppCommandCatalog.descriptor(for: .openHelp).shortcut)
            }
        }
        #endif
    }
}

#if os(macOS)
/// 按命令描述应用应用菜单快捷键：组合键只在 `AppCommandCatalog` 里写一次，
/// 菜单不再各自硬编码 `.keyboardShortcut("n", ...)` 这类字面量
private extension View {
    @ViewBuilder
    func commandShortcut(_ shortcut: CommandShortcut) -> some View {
        if let keys = shortcut.keyEquivalent {
            self.keyboardShortcut(KeyEquivalent(keys.key), modifiers: keys.modifiers)
        } else {
            self
        }
    }
}
#endif
