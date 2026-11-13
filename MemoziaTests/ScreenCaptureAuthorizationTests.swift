#if os(macOS)
import Foundation
import ScreenCaptureKit
import Testing
@testable import Memozia

struct ScreenCaptureAuthorizationTests {
    @Test("等待实际授权结果，不把尚未完成的申请判为拒绝")
    func waitsForAuthorizationResult() async throws {
        let entered = LockedBox(false)
        let gate = AsyncStream<Bool>.makeStream()
        let task = Task {
            try await ScreenCaptureAuthorization.load {
                entered.value = true
                for await value in gate.stream { return value }
                return false
            }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered.value, ContinuousClock.now < deadline { await Task.yield() }
        #expect(entered.value)
        gate.continuation.yield(true)
        gate.continuation.finish()
        #expect(try await task.value)
    }

    @Test("仅将系统明确拒绝映射为权限错误，保留其他失败")
    func distinguishesDenialFromSystemErrors() async throws {
        await #expect(throws: ScreenCaptureAuthorization.Failure.denied) {
            try await ScreenCaptureAuthorization.load { () -> Bool in
                throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
            }
        }
        let expected = NSError(domain: "CaptureTransport", code: 42)
        do {
            _ = try await ScreenCaptureAuthorization.load { () -> Bool in throw expected }
            Issue.record("系统错误不能转为成功")
        } catch {
            #expect((error as NSError).domain == expected.domain)
            #expect((error as NSError).code == expected.code)
        }
    }

    @Test("系统不响应取消时，取消和超时仍立即结束等待，迟到结果不恢复启动")
    func cancellationAndTimeoutDoNotWaitForLateResults() async throws {
        for cancel in [false, true] {
            let pending = LockedBox<CheckedContinuation<Bool, Never>?>(nil)
            let task = Task {
                try await ScreenCaptureAuthorization.load(timeout: cancel ? 10 : 0.03) {
                    await withCheckedContinuation { pending.value = $0 }
                }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while pending.value == nil, ContinuousClock.now < deadline { await Task.yield() }
            try #require(pending.value != nil)
            if cancel { task.cancel() }
            do {
                _ = try await task.value
                Issue.record("取消或超时后不得返回成功")
            } catch {
                if cancel { #expect(error is CancellationError) }
                else { #expect(error as? ScreenCaptureAuthorization.Failure == .timedOut) }
            }
            pending.value?.resume(returning: true)
        }
    }
    @Test("调用前已取消时不触发新的系统权限申请")
    func alreadyCancelledDoesNotRequestAuthorization() async {
        let entered = LockedBox(false)
        let gate = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in gate.stream { break }
            return try await ScreenCaptureAuthorization.load {
                entered.value = true
                return true
            }
        }
        task.cancel()
        gate.continuation.finish()
        do { _ = try await task.value; Issue.record("取消后不能继续申请权限") }
        catch { #expect(error is CancellationError) }
        #expect(!entered.value)
    }

    @Test("旧授权请求迟到失败不能释放新录音的启动预约")
    func stoppedAuthorizationCannotClearNextStart() async throws {
        let requests = LockedBox<[CheckedContinuation<SCShareableContent, any Error>]>([])
        let capture = SystemAudioCaptureService(loadContent: {
            try await withCheckedThrowingContinuation { continuation in
                var pending = requests.value
                pending.append(continuation)
                requests.value = pending
            }
        })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Authorization-\(UUID()).wav")
        let old = Task { try await capture.start(to: url) }
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.value.count < 1, ContinuousClock.now < firstDeadline { await Task.yield() }
        try #require(requests.value.count == 1)
        _ = await capture.stop()
        let next = Task { try await capture.start(to: url) }
        let secondDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while requests.value.count < 2, ContinuousClock.now < secondDeadline { await Task.yield() }
        try #require(requests.value.count == 2)
        requests.value[0].resume(throwing: CocoaError(.userCancelled))
        do { try await old.value; Issue.record("旧请求不应启动采集") } catch {}
        #expect(capture.hasResourcesPreventingUpdate, "新一轮仍在等待授权，旧请求不得释放其资源状态")
        requests.value[1].resume(throwing: CocoaError(.userCancelled))
        do { try await next.value; Issue.record("失败请求不应启动采集") } catch {}
        #expect(!capture.hasResourcesPreventingUpdate)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
#endif
