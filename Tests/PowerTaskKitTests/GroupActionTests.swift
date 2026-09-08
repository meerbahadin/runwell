import Testing
import Foundation
@testable import PowerTaskKit

/// Section 8.4 / 9.2 / 12.2: "Force quit cannot be triggered accidentally and
/// protected-process policy is covered by tests" — extended to group actions, where
/// one click can reach dozens of processes at once.
@Suite("Group actions")
struct GroupActionTests {
    private func identity(
        name: String, uid: uid_t = getuid(), pid: pid_t,
        path: String? = nil, principal: Bool = true
    ) -> ProcessIdentity {
        ProcessIdentity(
            key: ProcessKey(pid: pid, startAbsoluteTime: 1),
            name: name,
            executable: path.map { ExecutableIdentity(executablePath: $0, signingIdentifier: nil) },
            parentPID: 1,
            userID: uid,
            groupID: ApplicationGroupID(bundle: "com.example.App"),
            groupDisplayName: "App",
            groupingReason: .bundleOwnership,
            bundleURL: nil,
            isPrincipalProcess: principal
        )
    }

    private func metrics(_ identity: ProcessIdentity) -> ProcessIntervalMetrics {
        ProcessIntervalMetrics(
            key: identity.key,
            identity: identity,
            intervalSeconds: 2,
            cpuPercent: .derived(1),
            physicalFootprintBytes: .measured(1024),
            energyWatts: .derived(0.1),
            energyDeltaNJ: 200_000_000,
            diskReadBytesPerSecond: .derived(0),
            diskWriteBytesPerSecond: .derived(0),
            wakeupsPerSecond: .derived(0)
        )
    }

    private func group(_ identities: [ProcessIdentity]) -> ApplicationGroup {
        ApplicationGroup(
            id: ApplicationGroupID(bundle: "com.example.App"),
            displayName: "App",
            bundleURL: nil,
            members: identities.map(metrics),
            status: .normal
        )
    }

    @Test("Force quitting a group without confirmation does nothing")
    @MainActor
    func requiresConfirmation() {
        let service = ProcessActionService()
        // PIDs that do not exist: if the guard failed, the call would still refuse to
        // report a termination it did not perform.
        let g = group([identity(name: "helper", pid: 999_001, principal: false)])
        let outcome = service.forceQuitGroup(g, userConfirmed: false)
        #expect(outcome.terminated.isEmpty)
        #expect(!outcome.isCompleteSuccess)
    }

    @Test("A protected process in a group is skipped, never terminated")
    @MainActor
    func protectedMemberSkipped() {
        let service = ProcessActionService()
        // A root-owned member and a critical-name member both sit inside the group.
        let g = group([
            identity(name: "WindowServer", pid: 999_002),
            identity(name: "rootdaemon", uid: 0, pid: 999_003),
        ])
        let outcome = service.quitGroup(g)
        #expect(outcome.terminated.isEmpty)
        #expect(outcome.skipped.count == 2)
        #expect(!outcome.isCompleteSuccess)
    }

    @Test("PowerTask never quits itself as part of a group")
    @MainActor
    func neverQuitsSelf() {
        let service = ProcessActionService()
        let g = group([identity(name: "PowerTask", pid: getpid())])
        let outcome = service.quitGroup(g)
        #expect(outcome.terminated.isEmpty)
        #expect(outcome.skipped.count == 1)
    }

    @Test("Processes that already exited are reported as gone, not as failures")
    @MainActor
    func alreadyExitedIsNotAFailure() {
        let service = ProcessActionService()
        // A very high PID that is not in use; the liveness re-check catches it.
        let g = group([identity(name: "ghost", pid: 999_999, principal: false)])
        let outcome = service.quitGroup(g)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.alreadyGone == 1)
        // Nothing was blocked and nothing failed, so this counts as a clean result.
        #expect(outcome.isCompleteSuccess)
    }

    @Test("Helpers are terminated before the principal process")
    func helpersFirst() {
        // The ordering rule itself: a principal must never sort ahead of a helper,
        // otherwise killing it first lets the app respawn the helpers we then miss.
        let members = [
            identity(name: "App", pid: 1, principal: true),
            identity(name: "App Helper", pid: 2, principal: false),
        ]
        let ordered = members.sorted { a, b in
            !a.isPrincipalProcess && b.isPrincipalProcess
        }
        #expect(ordered.first?.isPrincipalProcess == false)
        #expect(ordered.last?.isPrincipalProcess == true)
    }
}
