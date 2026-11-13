import Foundation
import Testing
@testable import Memozia

@Suite @MainActor
struct UpdatePermissionRepairTests {
    private func snapshot(identity: String = "147:new-code", isAdHoc: Bool = true,
                          canReset: Bool = true, prior: Bool = true, busy: Bool = false) -> UpdatePermissionRepair.Snapshot {
        .init(identity: identity, isAdHoc: isAdHoc, canReset: canReset,
              hasPriorInstallation: prior, hasCaptureResources: busy)
    }

    @Test func upgradedAdHocIdentityResetsOnceAndRecordsOnlyAfterSuccess() async {
        var identity: String? = "146:old-code"
        var calls = 0
        let repair = UpdatePermissionRepair(snapshot: { snapshot() }, rememberedIdentity: { identity },
            rememberIdentity: { identity = $0 }, runReset: {
                #expect(identity == "146:old-code")
                calls += 1
                return .success
            })
        #expect(await repair.prepareIfNeeded() == .reset)
        #expect(identity == "147:new-code")
        #expect(await repair.prepareIfNeeded() == .reset)
        #expect(calls == 1 && !repair.needsPreparation)
    }

    @Test func firstUpgradeFromPreRepairReleaseAlsoResets() async {
        var identity: String?
        var calls = 0
        let repair = UpdatePermissionRepair(snapshot: { snapshot() }, rememberedIdentity: { identity },
            rememberIdentity: { identity = $0 }, runReset: { calls += 1; return .success })
        #expect(await repair.prepareIfNeeded() == .reset)
        #expect(calls == 1 && identity == "147:new-code")
    }

    @Test func freshInstallSameBuildAndStableSignatureDoNotRevokePermissions() async {
        for configuration in [snapshot(prior: false), snapshot(isAdHoc: false), snapshot()] {
            var identity: String? = configuration.hasPriorInstallation && configuration.isAdHoc ? "147:new-code" : nil
            let repair = UpdatePermissionRepair(snapshot: { configuration }, rememberedIdentity: { identity },
                rememberIdentity: { identity = $0 }, runReset: {
                    Issue.record("must not reset fresh install, same identity, or stable signing")
                    return .failed(1)
                })
            #expect(await repair.prepareIfNeeded() == .notNeeded)
            #expect(identity == "147:new-code")
        }
    }

    @Test func testsWorkersMissingConsentAndTransientSessionsNeverRunReset() async {
        for persistent in [true, false] {
            let repair = UpdatePermissionRepair(snapshot: { snapshot(canReset: !persistent) }, rememberedIdentity: { nil },
                rememberIdentity: { _ in Issue.record("must not write a marker") },
                runReset: { Issue.record("must not touch TCC"); return .success }, persistentSession: persistent)
            #expect(await repair.prepareIfNeeded() == .notNeeded)
        }
    }

    @Test func activeCaptureAndWrongBundleArePreserved() async {
        let busy = UpdatePermissionRepair(snapshot: { snapshot(busy: true) }, rememberedIdentity: { "old" },
            rememberIdentity: { _ in Issue.record("must not mark complete") },
            runReset: { Issue.record("must not interrupt capture"); return .success })
        #expect(await busy.prepareIfNeeded() == .failed)
        let foreign = UpdatePermissionRepair(snapshot: {
            var value = snapshot()
            value.bundleID = "another.app"
            return value
        }, rememberedIdentity: { "old" }, rememberIdentity: { _ in Issue.record("wrong bundle") },
            runReset: { Issue.record("must not reset another app"); return .success })
        #expect(await foreign.prepareIfNeeded() == .notNeeded)
    }

    @Test func failureIsVisibleDoesNotMarkCompleteAndRetriesNextLaunch() async {
        for error in [TCCResetCommand.Result.failed(1), .timedOut, .cancelled, .launchFailed] {
            var marker: String? = "old"
            var attempts = 0
            let first = UpdatePermissionRepair(snapshot: { snapshot() }, rememberedIdentity: { marker },
                rememberIdentity: { marker = $0 }, runReset: { attempts += 1; return error })
            #expect(await first.prepareIfNeeded() == .failed)
            #expect(first.outcome.message != nil && marker == "old")
            #expect(await first.prepareIfNeeded() == .failed && attempts == 1)
            let next = UpdatePermissionRepair(snapshot: { snapshot() }, rememberedIdentity: { marker },
                rememberIdentity: { marker = $0 }, runReset: { attempts += 1; return .success })
            #expect(await next.prepareIfNeeded() == .reset)
            #expect(marker == "147:new-code" && attempts == 2)
        }
    }

    @Test func concurrentStartupAndCaptureShareOneResetTask() async {
        var marker: String?
        var calls = 0
        let repair = UpdatePermissionRepair(snapshot: { snapshot() }, rememberedIdentity: { marker },
            rememberIdentity: { marker = $0 }, runReset: {
                calls += 1
                try? await Task.sleep(for: .milliseconds(30))
                return .success
            })
        let first = Task { await repair.prepareIfNeeded() }
        await Task.yield()
        let second = Task { await repair.prepareIfNeeded() }
        let firstOutcome = await first.value
        let secondOutcome = await second.value
        #expect(firstOutcome == .reset && secondOutcome == .reset)
        #expect(calls == 1)
    }

    @Test func commandIsRestrictedToOurBundleAndProcessTimeoutReturnsPromptly() async {
        #expect(TCCResetCommand.executable.path == "/usr/bin/tccutil")
        #expect(TCCResetCommand.arguments == ["reset", "All", "app.memozia"])
        // 仅验证进程等待器，绝不在测试中调用真实 tccutil 或清理用户授权。
        let start = ContinuousClock.now
        let result = await TCCResetCommand.execute(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                   arguments: ["10"], timeout: 0.05)
        #expect(result == .timedOut)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(await TCCResetCommand.execute(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                              arguments: [], timeout: 1) == .success)
    }

    @Test func missingSigningIdentityNeverResetsOrMarksSuccess() async {
        let repair = UpdatePermissionRepair(snapshot: {
            var value = snapshot()
            value.identity = nil
            return value
        }, rememberedIdentity: { "old" }, rememberIdentity: { _ in Issue.record("must not mark complete") },
            runReset: { Issue.record("must not reset an unknown identity"); return .success })
        #expect(await repair.prepareIfNeeded() == .failed)
    }

    @Test func processCancellationStopsWaitingWithoutExecutingTCC() async throws {
        let start = ContinuousClock.now
        let task = Task {
            await TCCResetCommand.execute(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 10)
        }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func signedTestHostIdentityCanBeReadWithoutChangingPermissions() throws {
        let identity = try #require(UpdatePermissionRepair.signingIdentity())
        #expect(!identity.hash.isEmpty)
        #expect(identity.hash.allSatisfy { $0.isHexDigit })
    }

    @Test func debugBuildNeverResetsPermissionsOrChangesReleaseMarker() async {
        let repair = UpdatePermissionRepair(snapshot: {
            var value = snapshot()
            value.isUnnotarizedDistribution = false
            return value
        }, rememberedIdentity: { "146:release-code" },
            rememberIdentity: { _ in Issue.record("must not change the release marker from a debug build") },
            runReset: { Issue.record("must not reset permissions from a debug build"); return .success })
        #expect(!repair.needsPreparation)
        #expect(await repair.prepareIfNeeded() == .notNeeded)
    }
}
