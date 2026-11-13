import Foundation
import Observation

/// 更新安装的落盘屏障。所有状态和依赖都在 MainActor；失败后恢复可操作状态。
/// 首版只在任务自然结束后安装，不取消用户的录音或处理任务。
@MainActor
@Observable
final class UpdateInstallationCoordinator {
    enum State: Equatable { case idle, preparing, ready }
    enum PreparationError: Error { case busy, persistence, worker }

    private(set) var state: State = .idle
    var isPreparing: Bool { state != .idle }

    func prepare(
        isBusy: () -> Bool,
        save: () throws -> Void,
        stopWorker: () async -> Bool,
        flush: () async -> Bool
    ) async throws {
        guard state == .idle else { throw PreparationError.busy }
        guard !isBusy() else { throw PreparationError.busy }
        state = .preparing
        var succeeded = false
        defer { if !succeeded { state = .idle } }
        try save()
        guard await stopWorker() else { throw PreparationError.worker }
        guard await flush() else { throw PreparationError.persistence }
        // await 期间可能有已排队的 UI/热键回调提交工作，安装前再次确认。
        guard !isBusy() else { throw PreparationError.busy }
        try save()
        state = .ready
        succeeded = true
    }
}
