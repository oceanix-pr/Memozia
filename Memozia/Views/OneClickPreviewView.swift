import SwiftUI

// MARK: - 一键处理计划（纯数据，可离线单测）

/// 「一键处理」将要执行的步骤计划。
///
/// 为什么要先出计划再入队：旧实现点一下就把「转写 → 画面 → 总结 → 拆解待办」整串投出去，
/// 其中「转写」会清空既有片段重建——用户手动改过的转写会被无声覆盖；已完成且不想重跑的
/// 步骤也会被重复执行（云端大模型按次计费）。这里把「跑什么 / 跳过什么 / 涉及哪些云端数据」
/// 显式列出来由用户确认，替代黑盒执行。
struct OneClickPlan: Equatable {

    /// 单个步骤的计划结果
    struct Item: Equatable, Identifiable {
        let kind: TaskKind
        /// 是否本次执行
        let willRun: Bool
        /// 跳过原因（willRun == false 时非空）
        let skipReason: SkipReason?

        var id: TaskKind { kind }
    }

    enum SkipReason: Equatable {
        /// 该步骤此前已完成，默认跳过
        case alreadyCompleted
    }

    /// 会送往云端模型的原始媒体范围（文本走 PII 脱敏，图片与视频帧不做文本脱敏）
    enum CloudScope: Equatable {
        case image
        case videoFrames
    }

    var items: [Item] = []
    /// 是否需要在执行前额外确认（存在手动编辑且本次会覆盖）
    var requiresManualEditConfirmation = false
    /// 云端数据范围（无则为 nil）
    var cloudScope: CloudScope?

    var runItems: [Item] { items.filter(\.willRun) }
    var skipItems: [Item] { items.filter { !$0.willRun } }
    var hasWork: Bool { items.contains { $0.willRun } }
}

// MARK: - 计划计算

extension OneClickPlan {

    /// 计划输入：全部来自条目当前状态与当前大模型配置，便于单测直接构造。
    /// 「已完成」由调用方按**产物**判定（转写状态 / 画面产物 / 总结密文 / todos.json 存在），
    /// 不依赖队列写入的处理状态字段——用户在详情页直接生成的结果不会改那些字段。
    struct Inputs: Equatable {
        /// 条目是否为录音/录屏（false = 快捷笔记）
        var isRecording: Bool
        /// 录音是否带视频源（录屏或导入视频）
        var hasVideo: Bool
        /// 转写已完成
        var transcriptCompleted: Bool
        /// 转写存在手动编辑（录音侧 `transcriptModifiedAt`）
        var transcriptManuallyEdited: Bool
        /// 画面分析产物已存在
        var visualCompleted: Bool
        /// 总结已存在
        var summaryCompleted: Bool
        /// 待办文档已存在
        var todoCompleted: Bool
        /// 音频文件存在（不存在则无法转写）
        var audioFileExists: Bool
        /// 笔记为图片笔记（总结会把图片/识别文字送模型）
        var isImageNote: Bool
        /// 当前大模型配置为云端（本地模型不出本机）
        var usesCloudLLM: Bool
        /// 用户显式要求「重新转写」（覆盖已有转写）
        var forceRetranscribe: Bool

        /// 副本：仅改写「重新转写」开关，其余输入不变
        func withForceRetranscribe(_ value: Bool) -> Inputs {
            var copy = self
            copy.forceRetranscribe = value
            return copy
        }
    }

    /// 由条目状态推导计划。
    ///
    /// 规则：
    /// - 已完成的步骤默认跳过；仅「转写」提供显式重做开关（其余步骤的重做走各自页面）
    /// - 转写仅在音频文件存在时才有意义；已有手动编辑且本次要重转时要求额外确认
    /// - 云端图片/视频帧范围单独提示（与 AGENTS 的隐私口径一致：不宣称图片/帧做过文本脱敏）
    static func make(_ inputs: Inputs) -> OneClickPlan {
        var plan = OneClickPlan()

        if inputs.isRecording {
            if inputs.audioFileExists {
                let willTranscribe = !inputs.transcriptCompleted || inputs.forceRetranscribe
                plan.items.append(Item(
                    kind: .transcription,
                    willRun: willTranscribe,
                    skipReason: willTranscribe ? nil : .alreadyCompleted
                ))
                // 只在「本次真的会覆盖已有转写」时才要求额外确认
                plan.requiresManualEditConfirmation = willTranscribe && inputs.transcriptManuallyEdited
            }
            if inputs.hasVideo {
                plan.items.append(Item(
                    kind: .visualAnalysis,
                    willRun: !inputs.visualCompleted,
                    skipReason: inputs.visualCompleted ? .alreadyCompleted : nil
                ))
            }
        }

        let willSummarize = !inputs.summaryCompleted
        plan.items.append(Item(
            kind: .summary,
            willRun: willSummarize,
            skipReason: willSummarize ? nil : .alreadyCompleted
        ))
        plan.items.append(Item(
            kind: .todoExtraction,
            willRun: !inputs.todoCompleted,
            skipReason: inputs.todoCompleted ? .alreadyCompleted : nil
        ))

        if inputs.usesCloudLLM {
            let visualRuns = plan.items.contains { $0.kind == .visualAnalysis && $0.willRun }
            if inputs.isRecording {
                // 录屏/视频条目：画面分析会把关键帧送模型（图片不参与文本脱敏）
                if inputs.hasVideo, visualRuns { plan.cloudScope = .videoFrames }
            } else if inputs.isImageNote, willSummarize {
                // 图片笔记：总结会把图片（视觉模型）或识别文字送模型
                plan.cloudScope = .image
            }
        }
        return plan
    }
}

// MARK: - 预览载荷

/// 一键处理预览的展示载荷：目标条目与状态快照必须成对出现。
///
/// 由 `.sheet(item:)` 承载——只有载荷非 nil 才展示 sheet，从结构上排除
/// 「展示标记已置位、内容 state 尚未提交」时内容闭包读到空值的时序问题。
struct OneClickPreviewPayload: Identifiable {
    let item: ListItem
    let inputs: OneClickPlan.Inputs

    var id: String { item.id }
}

// MARK: - 预览视图

/// 一键处理预览：列出将执行 / 将跳过的步骤，显式确认后才入队
struct OneClickPreviewView: View {
    /// 条目标题（展示在预览顶部，避免用户点错条目）
    let entryTitle: String
    /// 基础输入（不含「重新转写」开关）
    let inputs: OneClickPlan.Inputs
    /// 确认回调：传入用户确认后的最终计划
    let onConfirm: (OneClickPlan) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var forceRetranscribe = false

    private var plan: OneClickPlan {
        OneClickPlan.make(inputs.withForceRetranscribe(forceRetranscribe))
    }

    /// 只有存在「转写」这一步时才提供重做开关
    private var canForceRetranscribe: Bool {
        inputs.isRecording && inputs.audioFileExists
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("已完成的步骤默认跳过；需要覆盖已有结果时，可在下方显式重新转写。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    if canForceRetranscribe {
                        Toggle("重新转写（覆盖已有转写）", isOn: $forceRetranscribe)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }

                    if plan.requiresManualEditConfirmation {
                        warningRow(
                            icon: "exclamationmark.triangle.fill",
                            color: .orange,
                            text: "已有转写包含手动编辑，重新转写会覆盖这些修改；开始前会自动把现有转写备份为 transcript.backup.md。"
                        )
                    }

                    if let scope = plan.cloudScope {
                        cloudScopeRow(scope)
                    }

                    stepList(title: "将执行", items: plan.runItems, isRun: true)
                    if !plan.skipItems.isEmpty {
                        stepList(title: "将跳过", items: plan.skipItems, isRun: false)
                    }

                    if !plan.hasWork {
                        Text("所有步骤都已完成，没有需要重新执行的内容。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
        #if os(macOS)
        .frame(width: 460, height: 440)
        #endif
    }

    // MARK: 部件

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("一键处理预览")
                .font(.headline)
            Text(entryTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("开始处理") {
                onConfirm(plan)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!plan.hasWork)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 云端数据范围提示：按实际送入云端的媒体类型分别说明（图片/视频帧不做文本脱敏）
    @ViewBuilder
    private func cloudScopeRow(_ scope: OneClickPlan.CloudScope) -> some View {
        if scope == .image {
            warningRow(
                icon: "cloud.fill",
                color: .blue,
                text: "数据范围：会把笔记图片发送给云端大模型（图片不做文本脱敏）。"
            )
        } else {
            warningRow(
                icon: "cloud.fill",
                color: .blue,
                text: "数据范围：会把视频关键帧发送给云端大模型（画面不做文本脱敏）。"
            )
        }
    }

    @ViewBuilder
    private func warningRow(icon: String, color: Color, text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.callout)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func stepList(title: LocalizedStringKey, items: [OneClickPlan.Item], isRun: Bool) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(for: item.kind))
                            .font(.caption)
                            .foregroundStyle(isRun ? Color.accentColor : Color.secondary)
                            .frame(width: 16)
                        Text(item.kind.displayName)
                            .font(.callout)
                            .foregroundStyle(isRun ? .primary : .secondary)
                        Spacer()
                        if !isRun {
                            Text("已完成")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// 步骤图标（与队列面板保持同一套语义）
    static func icon(for kind: TaskKind) -> String {
        switch kind {
        case .modelDownload:   return "arrow.down.circle"
        case .transcription:   return "waveform"
        case .visualAnalysis:  return "rectangle.stack.badge.play"
        case .summary:         return "sparkles"
        case .title:           return "wand.and.stars"
        case .todoExtraction:  return "checklist"
        }
    }
}
