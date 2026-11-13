import Foundation

extension MainActor {
    /// MainActor.assumeIsolated 的安全替代：只做主线程检查，不做 executor 运行时断言。
    ///
    /// macOS 26 的 MainActor 改用自定义 executor（CFMainExecutor / DispatchMainExecutor），
    /// 在无 Swift Task 上下文的纯 AppKit / GCD 同步回调路径（Apple Event reopen、
    /// NSMenu sendAction、AVPlayer periodic observer 等）上，assumeIsolated 内部的
    /// swift_task_isCurrentExecutorWithFlagsImpl 断言存在缺陷：轻则误判触发断言失败，
    /// 重则读取被污染的 executor 指针直接 EXC_BAD_ACCESS（睡眠唤醒后重新激活时尤甚）。
    /// AppKit/GCD 保证这些回调在主线程同步执行，故用 Thread.isMainThread 断言
    /// + unsafeBitCast 直接执行闭包，完全绕开有缺陷的 executor 检查。
    @available(*, noasync)
    nonisolated static func assumeOnMainThread<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        precondition(Thread.isMainThread)
        return try withoutActuallyEscaping(body) {
            try unsafeBitCast($0, to: (() throws -> T).self)()
        }
    }
}
