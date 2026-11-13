import SwiftUI

// MARK: - 系统一次性提示（阻塞层）单一出口
//
// 背景：此前「数据解密失败」「加密保护未生效」「部分改动未能保存」各自持有
// 一个 `@State` 布尔量 + 一个 `.alert`，三份形态完全相同（标题 + 一段说明 + 「知道了」），
// 只是载荷不同。这类提示属于「必须让用户看到、且不能自动消失」的阻塞层，
// 与顶部非模态横幅（syncResultBanner）、常驻状态条（录音告警 / 临时模式）不是一回事，
// 因此这里只做**通道合并**，不改变任何一条提示的强度与生命周期。
//
// 合并收益：
// 1. 3 个布尔 → 1 个载荷，展示与否由 `notice != nil` 派生，不再出现
//    「标记已置位但内容为空」或「两个 alert 同帧竞争只弹一个」的隐患；
// 2. 新增同类一次性系统提示只需要在枚举里加一个 case，不再复制粘贴 alert；
// 3. 文案与标题集中在一处，便于统一校对（这些文案都涉及数据安全，必须说清后果）。
//
// 取舍说明：本通道采取「后一条覆盖前一条」。三条提示分别发生在启动解密、
// 加密回退、写库失败三个时点，正常使用下不会同时出现；若后续出现同帧多条的场景，
// 再引入待办队列，而不是现在为未证实的场景增加状态。
enum SystemNotice: String, Identifiable {
    /// 解密失败：密钥被改或被删，内容显示为空但原始数据仍在
    case decryptionFailed
    /// 加密未生效：为避免丢数据已回退明文落盘
    case encryptionIneffective
    /// 保存失败：界面已改但可能重启回退（常见原因磁盘写满）
    case saveFailed

    var id: String { rawValue }

    /// 弹窗标题：直接说明结论，不用「提示」「警告」这类无信息量的词
    var title: String {
        switch self {
        case .decryptionFailed: return "数据解密失败"
        case .encryptionIneffective: return "加密保护未生效"
        case .saveFailed: return "部分改动未能保存"
        }
    }

    /// 说明正文：必须包含「发生了什么 / 数据实际状态 / 用户该做什么」三部分，
    /// 避免只报错不给处置线索（诚实反馈原则）
    var message: String {
        switch self {
        case .decryptionFailed:
            return "部分加密内容无法解密，加密密钥可能已更改或 Keychain 中的密钥被删除。对应内容将显示为空，但原始数据仍保留在磁盘与数据库中。请勿删除 Keychain 中的密钥，否则已加密的数据将无法恢复。"
        case .encryptionIneffective:
            return "本次运行中有内容加密失败（Keychain 不可用或被锁定），为避免丢数据已以明文保存，这些内容仍可正常读写但不受加密保护。请确认钥匙串访问正常后重新启动应用。"
        case .saveFailed:
            return "保存到本地数据库时出错（常见原因是磁盘已写满）。当前界面上的改动可能在重启后丢失，请检查磁盘剩余空间后重试；本次运行的详细原因已记入应用日志（category: Persistence）。"
        }
    }

    /// 是否每次启动最多提示一次。三条都设为 true：
    /// 反复弹同一个阻塞框会训练用户无脑点掉，反而压低提示的效力。
    var isReportedOncePerLaunch: Bool { true }
}

// MARK: - 呈现层

/// 把 `SystemNotice` 挂到视图链上的唯一样式。
/// 单独抽成 modifier 而不是直接写 `.alert`，是为了让 RootView 的 body 链条
/// 保持「一层一件事」，也方便预览与单元测试单独构造。
private struct SystemNoticeLayer: ViewModifier {
    @Binding var notice: SystemNotice?

    private var isPresented: Binding<Bool> {
        Binding(
            get: { notice != nil },
            set: { newValue in
                // 关闭时统一切回 nil：展示状态由载荷派生，不会残留
                if !newValue { notice = nil }
            }
        )
    }

    func body(content: Content) -> some View {
        content.alert(
            notice?.title ?? "",
            isPresented: isPresented,
            presenting: notice
        ) { _ in
            Button("知道了", role: .cancel) {}
        } message: { presented in
            Text(presented.message)
        }
    }
}

extension View {
    /// 统一的系统一次性提示通道（阻塞层，不自动消失）
    func systemNoticeLayer(_ notice: Binding<SystemNotice?>) -> some View {
        modifier(SystemNoticeLayer(notice: notice))
    }
}
