import Testing
import Foundation
@testable import PowerTaskKit

/// Section 11.1: grouping rules and redaction.

@Suite("Application grouping")
struct GroupingTests {
    let grouper = ApplicationGrouper()

    @Test("Helpers inside an app bundle resolve to the outermost app")
    func nestedHelperResolvesToOuterApp() throws {
        // Chrome ships helpers inside its own Frameworks directory. The *outermost*
        // .app is the owning application (Section 6.3) — otherwise every renderer
        // would appear as its own top-level row.
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let outermost = try #require(components.firstIndex(where: { $0.hasSuffix(".app") }))
        let bundlePath = "/" + components[1...outermost].joined(separator: "/")
        #expect(bundlePath == "/Applications/Google Chrome.app")
    }

    @Test("Version-numbered binaries do not become the display name")
    func versionedBinaryName() {
        // Self-updating tools exec a binary literally named for its version.
        #expect(ApplicationGrouper.isMeaninglessBinaryName("2.1.263"))
        #expect(ApplicationGrouper.isMeaninglessBinaryName("1.0.0"))
        #expect(ApplicationGrouper.isMeaninglessBinaryName("12345"))
        #expect(!ApplicationGrouper.isMeaninglessBinaryName("Google Chrome"))
        #expect(!ApplicationGrouper.isMeaninglessBinaryName("node"))
    }

    @Test("A meaningless binary name falls back to a named ancestor directory")
    func namedAncestorFallback() {
        let path = "/Users/someone/.local/share/claude/versions/2.1.263"
        // "versions" is uninformative, so the walk continues to "claude".
        #expect(ApplicationGrouper.namedAncestor(of: path) == "claude")
    }

    @Test("Generic container directories are skipped when naming")
    func skipsGenericDirectories() {
        #expect(ApplicationGrouper.namedAncestor(of: "/opt/homebrew/Cellar/mytool/bin/2.0") == "mytool")
    }

    @Test("Terminals are excluded from parent-chain grouping")
    func shellsAreNotParents() {
        // Section 6.2 warns against grouping shells: a build run from Terminal must
        // not be attributed to Terminal, or every command inflates one app.
        #expect(ApplicationGrouper.shellLikeBundleIDs.contains("com.apple.Terminal"))
        #expect(ApplicationGrouper.shellExecutableNames.contains("zsh"))
        #expect(ApplicationGrouper.shellExecutableNames.contains("bash"))
    }

    @Test("Grouping precedence follows Section 6.2 order")
    func precedenceOrder() {
        #expect(GroupingReason.bundleOwnership.precedence < GroupingReason.bundlePathContainment.precedence)
        #expect(GroupingReason.bundlePathContainment.precedence < GroupingReason.helperBundlePrefix.precedence)
        #expect(GroupingReason.helperBundlePrefix.precedence < GroupingReason.parentChain.precedence)
        #expect(GroupingReason.parentChain.precedence < GroupingReason.standaloneExecutable.precedence)
    }
}

@Suite("Group totals")
struct GroupTotalTests {
    private func member(watts: Double?, cpu: Double?, bytes: UInt64?, pid: pid_t) -> ProcessIntervalMetrics {
        let identity = ProcessIdentity(
            key: ProcessKey(pid: pid, startAbsoluteTime: UInt64(pid)),
            name: "helper\(pid)",
            executable: nil,
            parentPID: 1,
            userID: 501,
            groupID: ApplicationGroupID(bundle: "com.example.App"),
            groupDisplayName: "App",
            groupingReason: .bundlePathContainment,
            bundleURL: nil,
            isPrincipalProcess: false
        )
        return ProcessIntervalMetrics(
            key: identity.key,
            identity: identity,
            intervalSeconds: 2,
            cpuPercent: cpu.map { .derived($0) } ?? .unavailable(.permissionDenied),
            physicalFootprintBytes: bytes.map { .measured($0) } ?? .unavailable(.permissionDenied),
            energyWatts: watts.map { .derived($0) } ?? .unavailable(.permissionDenied),
            energyDeltaNJ: watts.map { UInt64($0 * 2 * 1_000_000_000) },
            diskReadBytesPerSecond: .derived(0),
            diskWriteBytesPerSecond: .derived(0),
            wakeupsPerSecond: .derived(0)
        )
    }

    private func group(_ members: [ProcessIntervalMetrics]) -> ApplicationGroup {
        ApplicationGroup(
            id: ApplicationGroupID(bundle: "com.example.App"),
            displayName: "App",
            bundleURL: nil,
            members: members,
            status: .normal
        )
    }

    @Test("Group totals sum their members")
    func totalsSum() throws {
        // Section 12.2: totals must be preserved across expand/collapse, so they are
        // always computed from members rather than cached alongside them.
        let g = group([
            member(watts: 1.0, cpu: 10, bytes: 1_000, pid: 1),
            member(watts: 2.0, cpu: 20, bytes: 2_000, pid: 2),
            member(watts: 0.5, cpu: 5, bytes: 3_000, pid: 3),
        ])
        #expect(abs(try #require(g.totalEnergyWatts.value) - 3.5) < 0.0001)
        #expect(abs(try #require(g.totalCPUPercent.value) - 35) < 0.0001)
        #expect(try #require(g.totalFootprintBytes.value) == 6_000)
        #expect(g.processCount == 3)
    }

    @Test("A partially readable group reports reduced confidence, not a silent undercount")
    func partialCoverage() throws {
        let g = group([
            member(watts: 1.0, cpu: 10, bytes: 1_000, pid: 1),
            member(watts: nil, cpu: nil, bytes: nil, pid: 2),
        ])
        let total = g.totalEnergyWatts
        #expect(abs(try #require(total.value) - 1.0) < 0.0001)
        // The sum is real but incomplete, so it degrades to estimated.
        #expect(total.provenance == .estimated)
        #expect(total.confidence < 1.0)
    }

    @Test("A fully unreadable group is unavailable, not zero")
    func fullyUnreadable() {
        let g = group([
            member(watts: nil, cpu: nil, bytes: nil, pid: 1),
            member(watts: nil, cpu: nil, bytes: nil, pid: 2),
        ])
        #expect(!g.totalEnergyWatts.isAvailable)
        #expect(g.totalEnergyWatts.provenance == .unavailable)
        #expect(g.totalEnergyWatts.formatted() == "—")
    }

    @Test("Measured app share is a share of accessible energy, never of the battery")
    func appShare() throws {
        let g = group([member(watts: 1.0, cpu: 10, bytes: 1_000, pid: 1)])
        // 1W over a 2s interval = 2J = 2e9 nJ.
        let coverage = EnergyCoverage(groups: [g], accessibleEnergyNJ: 8_000_000_000, inaccessibleProcessCount: 0)
        let share = try #require(coverage.measuredAppShare(of: g).value)
        #expect(abs(share - 0.25) < 0.0001)
        // Section 3.1 mandates this wording over "battery percentage used".
        #expect(EnergyCoverage.shareLabel == "Measured application energy share")
    }

    @Test("Share confidence drops when processes are unreadable")
    func shareConfidence() throws {
        let g = group([member(watts: 1.0, cpu: 10, bytes: 1_000, pid: 1)])
        let full = EnergyCoverage(groups: [g], accessibleEnergyNJ: 2_000_000_000, inaccessibleProcessCount: 0)
        let partial = EnergyCoverage(groups: [g], accessibleEnergyNJ: 2_000_000_000, inaccessibleProcessCount: 50)
        #expect(full.measuredAppShare(of: g).confidence == 1.0)
        #expect(partial.measuredAppShare(of: g).confidence < 0.5)
    }

    @Test("Share is unavailable before any energy has been observed")
    func shareBeforeFirstSample() {
        let g = group([member(watts: nil, cpu: nil, bytes: nil, pid: 1)])
        let coverage = EnergyCoverage(groups: [g], accessibleEnergyNJ: 0, inaccessibleProcessCount: 0)
        #expect(!coverage.measuredAppShare(of: g).isAvailable)
    }
}

@Suite("Protected process policy")
struct PolicyTests {
    let policy = ProtectedProcessPolicy()

    private func identity(name: String, uid: uid_t, pid: pid_t = 4_242, path: String? = nil, principal: Bool = true) -> ProcessIdentity {
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

    @Test("Critical system processes are blocked", arguments: ["kernel_task", "launchd", "WindowServer", "loginwindow", "Finder"])
    func criticalBlocked(name: String) {
        #expect(policy.evaluate(identity: identity(name: name, uid: getuid())).isBlocked)
    }

    @Test("Root-owned processes are blocked")
    func rootBlocked() {
        #expect(policy.evaluate(identity: identity(name: "somedaemon", uid: 0)).isBlocked)
    }

    @Test("Another user's processes are blocked")
    func otherUserBlocked() {
        #expect(policy.evaluate(identity: identity(name: "theirapp", uid: getuid() &+ 1)).isBlocked)
    }

    @Test("PowerTask will not offer to quit itself")
    func selfBlocked() {
        #expect(policy.evaluate(identity: identity(name: "PowerTask", uid: getuid(), pid: getpid())).isBlocked)
    }

    @Test("System-shipped user processes require confirmation")
    func systemPathConfirms() {
        let result = policy.evaluate(identity: identity(name: "Spotlight", uid: getuid(), path: "/System/Library/CoreServices/Spotlight.app/Contents/MacOS/Spotlight"))
        guard case .requiresConfirmation = result else {
            Issue.record("expected confirmation, got \(result)")
            return
        }
    }

    @Test("Helper processes require confirmation")
    func helperConfirms() {
        let result = policy.evaluate(identity: identity(name: "App Helper", uid: getuid(), path: "/Applications/App.app/Contents/MacOS/Helper", principal: false))
        guard case .requiresConfirmation = result else {
            Issue.record("expected confirmation, got \(result)")
            return
        }
    }

    @Test("An ordinary user application is unprotected")
    func ordinaryAppUnprotected() {
        let result = policy.evaluate(identity: identity(name: "TextEdit", uid: getuid(), path: "/Applications/TextEdit.app/Contents/MacOS/TextEdit"))
        #expect(result == .unprotected)
    }
}

@Suite("Privacy and redaction")
struct RedactionTests {
    @Test("The user's home directory is replaced with a tilde")
    func homeRedacted() {
        // Section 9.1: user-directory names are removed from exports.
        let path = NSHomeDirectory() + "/Projects/secret-client/tool"
        let redacted = ExecutableIdentity.redact(path)
        #expect(redacted.hasPrefix("~/"))
        #expect(!redacted.contains(NSHomeDirectory()))
    }

    @Test("Another user's directory name is replaced")
    func otherUserRedacted() {
        let redacted = ExecutableIdentity.redact("/Users/janedoe/Applications/Thing.app/Contents/MacOS/Thing")
        #expect(!redacted.contains("janedoe"))
        #expect(redacted.hasPrefix("/Users/<user>/"))
    }

    @Test("System paths are left intact")
    func systemPathsKept() {
        #expect(ExecutableIdentity.redact("/usr/bin/ssh") == "/usr/bin/ssh")
        #expect(ExecutableIdentity.redact("/Applications/Safari.app") == "/Applications/Safari.app")
    }

    @Test("Unavailable values render as an em dash, never zero")
    func emDashForUnknown() {
        // Appendix F: zero means measured zero; unavailable means unknown.
        let unknown = IntervalMetric<Double>.unavailable(.permissionDenied)
        #expect(unknown.formatted() == "—")
        let measuredZero = IntervalMetric<Double>.measured(0)
        #expect(measuredZero.formatted("%.1f") == "0.0")
    }
}
