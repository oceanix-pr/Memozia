import Foundation
import Testing
@testable import Memozia

@Suite @MainActor
struct UpdateInstallationCoordinatorTests {
    @Test func independentUpdaterConfigurationRequiresConfirmedInstallation() {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String
                == "https://raw.githubusercontent.com/oceanix-pr/Memozia/updates/stable/appcast.xml")
        let key = info["SUPublicEDKey"] as? String ?? ""
        #expect(Data(base64Encoded: key)?.count == 32)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
    }

    @Test func activeCaptureDoesNotSaveOrStopWorker() async {
        let coordinator = UpdateInstallationCoordinator()
        var saved = false
        do {
            try await coordinator.prepare(isBusy: { true }, save: { saved = true },
                                          stopWorker: { Issue.record("must not stop"); return true },
                                          flush: { Issue.record("must not flush"); return true })
            Issue.record("busy installation was allowed")
        } catch {}
        #expect(!saved)
        #expect(coordinator.state == .idle)
    }

    @Test func failedFlushRestoresIdleAndPreventsInstallation() async {
        let coordinator = UpdateInstallationCoordinator()
        do {
            try await coordinator.prepare(isBusy: { false }, save: {}, stopWorker: { true }, flush: { false })
            Issue.record("failed mirror write was ignored")
        } catch {}
        #expect(coordinator.state == .idle)
    }

    @Test func newWorkDuringAwaitCancelsInstallation() async {
        let coordinator = UpdateInstallationCoordinator()
        var busy = false
        do {
            try await coordinator.prepare(isBusy: { busy }, save: {}, stopWorker: { true },
                                          flush: { busy = true; return true })
            Issue.record("late work was ignored")
        } catch {}
        #expect(coordinator.state == .idle)
    }

    @Test func successfulBarrierSavesBeforeAndAfterFlush() async throws {
        let coordinator = UpdateInstallationCoordinator()
        var steps: [String] = []
        try await coordinator.prepare(isBusy: { false }, save: { steps.append("save") },
                                      stopWorker: { steps.append("worker"); return true },
                                      flush: { steps.append("flush"); return true })
        #expect(steps == ["save", "worker", "flush", "save"])
        #expect(coordinator.state == .ready)
    }

    @Test func workerRefusalPreventsFlushAndAllowsRetry() async {
        let coordinator = UpdateInstallationCoordinator()
        do {
            try await coordinator.prepare(isBusy: { false }, save: {}, stopWorker: { false },
                                          flush: { Issue.record("must not flush"); return true })
            Issue.record("live worker was ignored")
        } catch {}
        #expect(coordinator.state == .idle)
    }
}
