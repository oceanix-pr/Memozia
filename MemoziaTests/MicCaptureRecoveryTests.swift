import Foundation
import Testing
@testable import Memozia

@MainActor
struct MicCaptureRecoveryTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition(), "恢复状态应在有界时间内推进")
    }

    @Test func packetTimeoutRetriesAndNextAttemptCanRecover() async throws {
        var attempts: [MicCaptureRecovery.Attempt] = []
        var timeouts: [Int] = []
        var failures = 0
        var recovered = 0
        let recovery = MicCaptureRecovery(
            backoff: [.milliseconds(5)], totalBudget: .seconds(1), packetTimeout: .milliseconds(25),
            attempt: { attempts.append($0); return true }, onStarted: { _ in },
            onPacketTimeout: { timeouts.append($0) }, onFailed: { _ in failures += 1 },
            onRecovered: { recovered += 1 }
        )
        #expect(recovery.start())
        try await waitUntil { attempts.count == 2 }
        #expect(timeouts == [1])
        recovery.confirmWrite(attempts[0])
        #expect(!recovery.isConfirmed, "旧 tap 的迟到写入不能确认新尝试")
        recovery.confirmWrite(attempts[1])
        #expect(recovery.isConfirmed)
        #expect(recovered == 1)
        #expect(failures == 0)
    }

    @Test func lateWriteAfterFinalTimeoutClearsFailureWithoutNewNotification() async throws {
        var token: MicCaptureRecovery.Attempt?
        var failures = 0
        var recovered = 0
        let recovery = MicCaptureRecovery(
            backoff: [], totalBudget: .seconds(1), packetTimeout: .milliseconds(20),
            attempt: { token = $0; return true }, onStarted: { _ in },
            onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 },
            onRecovered: { recovered += 1 }
        )
        recovery.start()
        try await waitUntil { failures == 1 }
        recovery.confirmWrite(try #require(token))
        recovery.confirmWrite(try #require(token))
        #expect(recovery.isConfirmed)
        #expect(recovered == 1, "恢复只结算一次；静音全零缓冲成功写入也使用此确认入口")
    }

    @Test func startFailuresAndPacketTimeoutShareAttemptLimit() async throws {
        var attempts = 0
        var timeouts: [Int] = []
        var failedAt: Int?
        let recovery = MicCaptureRecovery(
            backoff: [.milliseconds(5), .milliseconds(5)], totalBudget: .seconds(1),
            packetTimeout: .milliseconds(20),
            attempt: { _ in attempts += 1; return attempts > 1 }, onStarted: { _ in },
            onPacketTimeout: { timeouts.append($0) }, onFailed: { failedAt = $0 }, onRecovered: {}
        )
        #expect(!recovery.start())
        try await waitUntil { failedAt != nil }
        #expect(attempts == 3)
        #expect(timeouts == [2, 3])
        #expect(failedAt == 3)
    }

    @Test func budgetIncludesAllPacketWaitsAndBackoffs() async throws {
        var attempts = 0
        var failures = 0
        let recovery = MicCaptureRecovery(
            backoff: Array(repeating: .milliseconds(5), count: 20),
            totalBudget: .milliseconds(80), packetTimeout: .milliseconds(50),
            attempt: { _ in attempts += 1; return true }, onStarted: { _ in },
            onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 }, onRecovered: {}
        )
        recovery.start()
        try await waitUntil { failures == 1 }
        #expect(attempts <= 2, "首包超时不能重置总预算")
    }

    @Test func stopAndNewRecoveryInvalidateOldWritesAndTimers() async throws {
        var tokens: [MicCaptureRecovery.Attempt] = []
        var failures = 0
        var recovered = 0
        let recovery = MicCaptureRecovery(
            backoff: [], totalBudget: .seconds(1), packetTimeout: .milliseconds(25),
            attempt: { tokens.append($0); return true }, onStarted: { _ in },
            onPacketTimeout: { _ in }, onFailed: { _ in failures += 1 },
            onRecovered: { recovered += 1 }
        )
        recovery.start()
        recovery.start()
        recovery.confirmWrite(tokens[0])
        #expect(!recovery.isConfirmed)
        recovery.cancel()
        recovery.confirmWrite(tokens[1])
        try await Task.sleep(for: .milliseconds(60))
        #expect(failures == 0)
        #expect(recovered == 0)
        #expect(tokens.count == 2)
    }

    @Test func microphoneFailureReportsSystemTrackSeparately() {
        let microphoneOnly = MeetingRecorderService.microphoneRecoveryFailureMessage(systemAudio: .unused)
        let mixed = MeetingRecorderService.microphoneRecoveryFailureMessage(systemAudio: .active)
        #expect(mixed == microphoneOnly + "\n" + String(localized: "系统音频采集仍在运行。"))
        #expect(MeetingRecorderService.microphoneRecoveryFailureMessage(systemAudio: .interrupted)
                == microphoneOnly + "\n" + String(localized: "系统音频当前未正常采集。"))
        #expect(MeetingRecorderService.microphoneRecoveryFailureMessage(systemAudio: .recovering)
                == microphoneOnly + "\n" + String(localized: "系统音频尚未确认恢复。"))
    }

    @Test func startupConfigurationChangePreservesWaiterAndSkipsOldPacketWait() async throws {
        var attempts: [MicCaptureRecovery.Attempt] = []
        var timeouts = 0
        var recovered = 0
        let recovery = MicCaptureRecovery(
            backoff: [.milliseconds(5)], totalBudget: .seconds(1), packetTimeout: .milliseconds(200),
            attempt: { attempts.append($0); return true }, onStarted: { _ in },
            onPacketTimeout: { _ in timeouts += 1 }, onFailed: { _ in }, onRecovered: { recovered += 1 }
        )
        let startup = Task { try await recovery.startAndWait() }
        try await waitUntil { attempts.count == 1 }
        #expect(recovery.invalidateAttempt())
        #expect(!recovery.invalidateAttempt(), "重复配置通知只使同一尝试失效一次")
        try await waitUntil { attempts.count == 2 }
        #expect(timeouts == 0, "实际格式变化应提前重试，不能等旧 tap 首包超时")
        #expect(attempts[0].recoveryID == attempts[1].recoveryID)
        recovery.confirmWrite(attempts[0])
        #expect(!recovery.isConfirmed)
        recovery.confirmWrite(attempts[1])
        try await startup.value
        #expect(recovered == 1)
    }

    @Test func repeatedConfigurationChangesCannotRefreshBudget() async throws {
        var attempts = 0
        var packetTimeouts = 0
        var exhausted = 0
        var recovery: MicCaptureRecovery?
        recovery = MicCaptureRecovery(
            backoff: Array(repeating: .milliseconds(15), count: 20),
            totalBudget: .milliseconds(80), packetTimeout: .milliseconds(20),
            attempt: { _ in
                attempts += 1
                recovery?.invalidateAttempt()
                recovery?.invalidateAttempt()
                return true
            }, onStarted: { _ in }, onPacketTimeout: { _ in packetTimeouts += 1 },
            onFailed: { _ in }, onRecovered: {}, onBudgetExhausted: { _ in exhausted += 1 }
        )
        let controller = try #require(recovery)
        await #expect(throws: MicCaptureRecovery.Failure.budgetExhausted) { try await controller.startAndWait() }
        #expect(attempts > 1 && attempts < controller.maxAttempts)
        #expect(packetTimeouts == 0)
        #expect(exhausted == 1)
        recovery = nil
    }

    @Test func retryRequiresRemainingPacketObservationWindow() async throws {
        var attempts = 0
        var packetTimeouts = 0
        let recovery = MicCaptureRecovery(
            backoff: [.milliseconds(5)], totalBudget: .milliseconds(60), packetTimeout: .milliseconds(40),
            attempt: { _ in attempts += 1; return true }, onStarted: { _ in },
            onPacketTimeout: { _ in packetTimeouts += 1 }, onFailed: { _ in }, onRecovered: {}
        )
        await #expect(throws: MicCaptureRecovery.Failure.budgetExhausted) { try await recovery.startAndWait() }
        #expect(attempts == 1, "预算不足时不能启动一个只剩几毫秒首包等待的新尝试")
        #expect(packetTimeouts == 1)
    }

    @Test func slowSynchronousPreparationReportsBudgetRatherThanPacketTimeout() async throws {
        var packetTimeouts = 0
        var budgetExhaustions = 0
        let recovery = MicCaptureRecovery(
            backoff: [], totalBudget: .milliseconds(20), packetTimeout: .milliseconds(10),
            attempt: { _ in
                // 模拟 prepare/start 中同步的蓝牙协商；不涉及真实硬件。
                Thread.sleep(forTimeInterval: 0.04)
                return true
            }, onStarted: { _ in }, onPacketTimeout: { _ in packetTimeouts += 1 },
            onFailed: { _ in }, onRecovered: {}, onBudgetExhausted: { _ in budgetExhaustions += 1 }
        )
        await #expect(throws: MicCaptureRecovery.Failure.budgetExhausted) { try await recovery.startAndWait() }
        #expect(packetTimeouts == 0)
        #expect(budgetExhaustions == 1)
    }
}
