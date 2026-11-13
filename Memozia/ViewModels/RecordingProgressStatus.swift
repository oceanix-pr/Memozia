import Foundation
/// 单个处理任务的进度状态。
///
/// 文字转写与说话人区分是两条独立流水线，各自用一个状态表达：两边的阶段划分与可计量程度
/// 不同（例如说话人分离的核心推理没有进度回调），所以**状态层面**不做“总百分比”折算。
/// 若界面只放一条进度条（见 `RecordingViewModel.mergedProgress`），在展示层按串行顺序 1:1 折算。
/// `fraction == nil` 表示无法准确计量。
struct ProcessingProgressStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// 未开始（说话人区分未开启时也停在此态）
        case idle
        /// 准备中（模型加载/下载）
        case preparing
        /// 进行中
        case running
        /// 已完成
        case completed
        /// 已跳过（失败但已降级，不影响另一条流水线）
        case skipped
        /// 失败
        case failed
    }

    var phase: Phase = .idle
    /// 0...1；nil 表示无法准确计量
    var fraction: Float?
    /// 阶段文案
    var detail: String = ""

    static let idle = ProcessingProgressStatus()

    /// 是否正在推进（准备中/进行中）：用于挑选当前该展示哪条流水线的文案
    var isActive: Bool {
        phase == .preparing || phase == .running
    }
}
