import Testing
import Foundation
@testable import PowerTaskKit

/// Section 8.3 rules and Section 11.1: the sustained-window logic is the part that
/// must not misfire, since an alert that cries wolf is worse than none.
@Suite("Insight rules")
struct InsightEngineTests {
    private func group(
        name: String, watts: Double?, cpu: Double = 0,
        memoryBytes: UInt64 = 1_000_000, wakeups: Double = 0
    ) -> ApplicationGroup {
        let identity = ProcessIdentity(
            key: ProcessKey(pid: 1, startAbsoluteTime: 1),
            name: name, executable: nil, parentPID: 1, userID: getuid(),
            groupID: ApplicationGroupID(bundle: "com.example.\(name)"),
            groupDisplayName: name, groupingReason: .bundleOwnership,
            bundleURL: nil, isPrincipalProcess: true
        )
        let metrics = ProcessIntervalMetrics(
            key: identity.key, identity: identity, intervalSeconds: 2,
            cpuPercent: .derived(cpu),
            physicalFootprintBytes: .measured(memoryBytes),
            energyWatts: watts.map { .derived($0) } ?? .unavailable(.permissionDenied),
            energyDeltaNJ: watts.map { UInt64($0 * 2 * 1e9) },
            diskReadBytesPerSecond: .derived(0),
            diskWriteBytesPerSecond: .derived(0),
            wakeupsPerSecond: .derived(wakeups)
        )
        return ApplicationGroup(
            id: identity.groupID, displayName: name, bundleURL: nil,
            members: [metrics], status: .normal
        )
    }

    private func snapshot(_ groups: [ApplicationGroup]) -> SamplerSnapshot {
        SamplerSnapshot(
            sessionID: SampleSessionID(), groups: groups,
            coverage: EnergyCoverage(groups: groups, accessibleEnergyNJ: 1_000_000, inaccessibleProcessCount: 0),
            battery: BatterySnapshot(
                percentage: .measured(80), powerSource: .battery, isCharging: false,
                isCharged: false, isPresent: true,
                timeRemaining: .unavailable(.awaitingSecondSample),
                capturedAt: MonotonicInstant.now()),
            capabilities: CapabilitySet(statuses: [:], osBuild: "t", hardwareModel: "t",
                                        logicalProcessorCount: 8, hasBattery: true),
            mode: .foreground, cycleDuration: .milliseconds(30),
            skippedCycles: 0, isFirstSample: false
        )
    }

    @Test("A brief spike does not raise an insight")
    func spikeDoesNotFire() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let hot = snapshot([group(name: "Chrome", watts: 5)])

        // Ten seconds of high energy: well short of the 60 the rule requires.
        _ = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(10))
        #expect(raised.isEmpty)
        #expect(state.activeInsights.isEmpty)
    }

    @Test("A sustained condition raises exactly once")
    func sustainedFires() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let hot = snapshot([group(name: "Chrome", watts: 5)])

        _ = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state, now: now)
        let first = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state,
                                    now: now.addingTimeInterval(61))
        #expect(first.count >= 1)
        #expect(first.contains { $0.rule == .sustainedEnergy })

        // Still true a cycle later, but it is the same condition — not a new alert.
        let second = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(63))
        #expect(!second.contains { $0.rule == .sustainedEnergy })
    }

    @Test("An interruption resets the clock")
    func interruptionResets() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let hot = snapshot([group(name: "Chrome", watts: 5)])
        let cool = snapshot([group(name: "Chrome", watts: 0.01)])

        _ = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state, now: now)
        // Drops out at 50s, so the streak restarts rather than carrying over.
        _ = engine.evaluate(snapshot: cool, foregroundGroupIDs: [], state: &state,
                            now: now.addingTimeInterval(50))
        let raised = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(70))
        #expect(!raised.contains { $0.rule == .sustainedEnergy })
    }

    @Test("An unavailable reading never triggers a rule")
    func unavailableDoesNotFire() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        // Section 3: unavailable is unknown, not low and not high.
        let unknown = snapshot([group(name: "Locked", watts: nil)])
        _ = engine.evaluate(snapshot: unknown, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: unknown, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(120))
        #expect(!raised.contains { $0.rule == .sustainedEnergy })
    }

    @Test("A foreground app is not reported as background activity")
    func foregroundExempt() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot([group(name: "Xcode", watts: 0.1, cpu: 90)])
        let id = busy.groups[0].id

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [id], state: &state, now: now)
        let raised = engine.evaluate(snapshot: busy, foregroundGroupIDs: [id], state: &state,
                                     now: now.addingTimeInterval(130))
        #expect(!raised.contains { $0.rule == .hiddenBackgroundLoad })
    }

    @Test("The same load in the background is reported")
    func backgroundFires() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot([group(name: "Xcode", watts: 0.1, cpu: 90)])

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(130))
        #expect(raised.contains { $0.rule == .hiddenBackgroundLoad })
    }

    @Test("Muting a rule suppresses it for that app only")
    func mutingWorks() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let hot = snapshot([group(name: "Chrome", watts: 5)])
        let target = Insight(rule: .sustainedEnergy, appGroupID: hot.groups[0].id,
                             appName: "Chrome", startedAt: now, severity: .warning, evidence: "")
        state.mute(target)

        _ = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(120))
        #expect(!raised.contains { $0.rule == .sustainedEnergy })
    }

    @Test("Sleep prevention stays gated until it can be evidenced")
    func sleepPreventionGated() {
        // Section 5.9: specified, but no validated assertion source yet.
        #expect(InsightRule.sleepPrevention.isAvailable == false)
    }

    @Test("Every insight carries the numbers that justify it")
    func evidenceRecorded() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let hot = snapshot([group(name: "Chrome", watts: 5)])
        _ = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: hot, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(61))
        let insight = raised.first { $0.rule == .sustainedEnergy }
        #expect(insight?.evidence.contains("W") == true)
        #expect(insight?.message == "Chrome has used high measured energy for the last minute.")
    }

    @Test("A heavy workload raises many insights at once")
    func manySimultaneousInsights() {
        // The condition that produced a wall of notifications: several apps crossing
        // a threshold in the same cycle. The engine is right to raise them all — the
        // rate limiting belongs in the notifier, not here, so that the app can still
        // show every one of them.
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot([
            group(name: "A", watts: 6), group(name: "B", watts: 6),
            group(name: "C", watts: 6), group(name: "D", watts: 6),
        ])
        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(61))
        #expect(raised.filter { $0.rule == .sustainedEnergy }.count == 4)
    }

    @Test("Thresholds scale with the machine")
    func calibration() {
        let small = InsightEngine.Thresholds.calibrated(for: CapabilitySet(
            statuses: [:], osBuild: "t", hardwareModel: "t",
            logicalProcessorCount: 8, hasBattery: true))
        let large = InsightEngine.Thresholds.calibrated(for: CapabilitySet(
            statuses: [:], osBuild: "t", hardwareModel: "t",
            logicalProcessorCount: 16, hasBattery: true))
        // Section 8.3: a device-calibrated threshold, not one constant for all Macs.
        #expect(large.sustainedEnergyWatts > small.sustainedEnergyWatts)
    }
}
