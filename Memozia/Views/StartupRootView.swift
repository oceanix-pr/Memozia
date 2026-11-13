import SwiftUI
import SwiftData
#if canImport(AppKit)
import AppKit
#endif

/// 启动根视图：把「轻量启动界面 → 主界面」的切换集中到一处。
///
/// 关键点：启动阶段（worker 握手 / 取数据库独占锁 / 建容器）完全不依赖 SwiftData，
/// 因此可以先把窗口显示出来给用户**可见进度**；只有拿到可用容器后才对内容视图
/// 动态注入 `.modelContainer(_:)`。绝不回退到「主线程同步等待」那种无窗口的启动方式。
///
/// 三种收尾状态：
/// - `.ready`：已持锁并打开可写容器 → 进入主界面；
/// - `.transientReady`：用户二次确认后以临时（内存）模式继续 → 进入主界面并常驻不落盘提示；
/// - `.databaseBusy` / `.persistentStoreFailed`：独立降级界面，提供「重试」「退出应用」
///   （以及需要二次确认的「以临时模式继续」）。
struct StartupRootView: View {
    let coordinator: StartupCoordinator

    var body: some View {
        // 外层用固定结构的 ZStack 包裹：bootstrap 只应触发一次，且**不能**因为
        // 内部阶段切换（进度 → 主界面 / 降级界面）改变了子树结构而被取消。
        // 直接把 .task 挂在会切换类型的子树上时，SwiftUI 可能视其身份变化而取消任务。
        ZStack {
            content
        }
        .frame(minWidth: 420, minHeight: 300)
        .task { await coordinator.bootstrapIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .ready(let container):
            mainContent(container: container, isTransient: false)
        case .transientReady(let container):
            mainContent(container: container, isTransient: true)
        case .databaseBusy(let reason):
            StartupBlockedView(
                presentation: .databaseBusy(reason),
                onRetry: { Task { await coordinator.retry() } },
                onContinueTransient: { Task { await coordinator.continueInTransientMode() } },
                onQuit: { Self.quitApplication() }
            )
        case .persistentStoreFailed(let description):
            StartupBlockedView(
                presentation: .persistentStoreFailed(description),
                onRetry: { Task { await coordinator.retry() } },
                onContinueTransient: { Task { await coordinator.continueInTransientMode() } },
                onQuit: { Self.quitApplication() }
            )
        case .starting, .waitingForWorker, .openingDatabase:
            StartupProgressView(phase: coordinator.phase)
        }
    }

    private func mainContent(container: ModelContainer, isTransient: Bool) -> some View {
        PermissionPreparedRootView(isTransient: isTransient)
            .frame(minWidth: 700, minHeight: 500)
            #if os(macOS)
            .frame(idealWidth: 1100, idealHeight: 700)
            #endif
            .modelContainer(container)
    }

    /// 退出应用：走标准终止流程（AppDelegate 会收尾录音、flush 镜像、必要时拉起 worker）
    private static func quitApplication() {
        #if os(macOS)
        NSApp.terminate(nil)
        #endif
    }
}

/// 新版已安装且独占可写数据库后，先处理旧签名的授权，再开放主界面。
private struct PermissionPreparedRootView: View {
    let isTransient: Bool
    @State private var prepared = false
    @State private var dismissedNotice = false

    var body: some View {
        Group {
            if prepared {
                RootView(persistence: isTransient ? .readOnlyTransient : .readWrite)
                    .safeAreaInset(edge: .top) {
                        if !dismissedNotice, let message = UpdatePermissionRepair.shared.outcome.message {
                            HStack(alignment: .top, spacing: 10) {
                                Label(message, systemImage: "info.circle")
                                    .font(.callout)
                                Spacer()
                                Button { dismissedNotice = true } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("关闭")
                            }
                            .padding(12)
                            .background(.bar)
                        }
                    }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在清理旧版本系统授权…")
                }
            }
        }
        .task {
            UpdatePermissionRepair.shared.configureSession(isPersistent: !isTransient)
            await UpdatePermissionRepair.shared.prepareIfNeeded()
            prepared = true
        }
    }
}

/// 启动进度界面：只依赖 SwiftUI，不触碰 SwiftData，保证进程一起来就能显示
struct StartupProgressView: View {
    let phase: StartupPhase

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 240)
    }

    private var title: String {
        switch phase {
        case .waitingForWorker:
            return String(localized: "正在等待后台任务收尾…")
        case .openingDatabase:
            return String(localized: "正在打开数据库…")
        default:
            return String(localized: "正在启动 Memozia…")
        }
    }

    private var detail: String {
        switch phase {
        case .waitingForWorker:
            return String(localized: "上次运行仍有后台任务在收尾，正在等待它保存进度并让出数据库。")
        case .openingDatabase:
            return String(localized: "正在获取数据库独占权并打开本地数据库。")
        default:
            return String(localized: "正在准备启动环境。")
        }
    }
}

/// 启动被阻断界面（数据库不可用 / 持久化容器失败）：
/// 提供「重试」「退出应用」，以及需要二次确认的「以临时模式继续」
struct StartupBlockedView: View {
    enum Presentation {
        case databaseBusy(DatabaseBusyReason)
        case persistentStoreFailed(String)
    }

    let presentation: Presentation
    let onRetry: @MainActor () -> Void
    let onContinueTransient: @MainActor () -> Void
    let onQuit: @MainActor () -> Void

    @State private var showTransientConfirmation = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("重试") { onRetry() }
                    .keyboardShortcut(.defaultAction)
                Button("以临时模式继续…") { showTransientConfirmation = true }
                Button("退出应用") { onQuit() }
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(minWidth: 520, minHeight: 300)
        .confirmationDialog(
            "以临时模式继续？",
            isPresented: $showTransientConfirmation,
            titleVisibility: .visible
        ) {
            Button("以临时模式继续", role: .destructive) { onContinueTransient() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("临时模式不会保存任何改动：新建录音、新建快捷笔记、导入与删除都会被禁用，应用退出后本次所有内容都会丢失。仅建议在需要临时查看现有内容时使用。")
        }
    }

    private var title: String {
        switch presentation {
        case .databaseBusy:
            return String(localized: "数据库暂时不可用")
        case .persistentStoreFailed:
            return String(localized: "数据库初始化失败")
        }
    }

    private var message: String {
        switch presentation {
        case .databaseBusy(.heldByOtherProcess):
            return String(localized: "后台任务进程仍占用数据库，为避免两个进程同时写入损坏数据，本次未打开数据库。\n可稍等片刻后重试；若反复出现，可在「活动监视器」中结束 Memozia 的后台进程后重试。")
        case .databaseBusy(.lockFileUnavailable(let code)):
            return String(format: String(localized: "无法在数据文件夹中创建数据库锁文件（常见原因：磁盘已满、该文件夹无写入权限）。\n请检查磁盘剩余空间与文件夹权限后重试。（错误码 %d）"), code)
        case .persistentStoreFailed(let description):
            return String(format: String(localized: "数据库初始化失败，应用无法以正常模式启动。\n请检查磁盘空间或数据文件夹权限后重试。\n详细原因：%@"), description)
        }
    }
}
