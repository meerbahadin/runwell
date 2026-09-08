import Testing
import Foundation
@testable import RunwellKit

/// Section 8.3 rules and Section 11.1: the sustained-window logic is the part that
/// must not misfire, since an alert that cries wolf is worse than none.
@Suite("Insight rules")
struct InsightEngineTests {
    private func group(
        name: String, watts: Double?, cpu: Double = 0,
        memoryBytes: UInt64 = 1_000_000, wakeups: Double = 0,
        pid: pid_t = 1, userID: uid_t? = nil
    ) -> ApplicationGroup {
        let identity = ProcessIdentity(
            key: ProcessKey(pid: pid, startAbsoluteTime: 1),
            name: name, executable: nil, parentPID: 1, userID: userID ?? getuid(),
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

    private func snapshot(
        _ groups: [ApplicationGroup],
        assertions: [SleepAssertionCollector.Assertion]? = nil,
        displayAsleep: Bool = false
    ) -> SamplerSnapshot {
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
            skippedCycles: 0, isFirstSample: false,
            sleepAssertions: assertions, displayIsAsleep: displayAsleep
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

    @Test("Every rule has a validated source")
    func everyRuleIsEvidenced() {
        // Section 5.9's gate was lifted once IOPMCopyAssertionsByProcess proved to be
        // a supported, unprivileged, pid-attributed source. Whether a given Mac can
        // actually supply each signal is the capability probe's call at runtime, not
        // a compile-time property of the rule.
        let unavailable = InsightRule.allCases.filter { !$0.isAvailable }
        #expect(unavailable.isEmpty)
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
        #expect(insight?.message == "Chrome is using a lot of power.")
    }

    /// The field report: Chrome drew 18 W with no notification, because low-priority
    /// wakeup notices had already consumed the spacing window. The engine must still
    /// raise the energy warning — suppression is the notifier's decision, not the
    /// engine's, and the warning has to exist for the notifier to prefer it.
    @Test("A high-energy warning is raised alongside lower-priority notices")
    func energyWarningSurvivesAlongsideNotices() {
        let engine = InsightEngine(thresholds: .init(sustainedEnergyWatts: 2.5))
        var state = InsightEngine.State()
        let now = Date()
        // Chrome well over the energy threshold, plus noisy wakeup neighbours.
        let busy = snapshot([
            group(name: "Chrome", watts: 18, wakeups: 1834),
            group(name: "Telegram", watts: 0, wakeups: 240),
            group(name: "Code", watts: 0, wakeups: 411),
        ])

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(120))

        let energy = raised.first { $0.rule == .sustainedEnergy && $0.appName == "Chrome" }
        #expect(energy != nil)
        // Severity is what lets the notifier preempt a spacing window for this.
        #expect(energy?.severity == .warning)
        // Chrome is hot on both counts, but gets one row: the measured power reading
        // outranks the wakeup proxy, so the user is not told twice about one app.
        #expect(!raised.contains { $0.rule == .wakeupStorm && $0.appName == "Chrome" })
        #expect(raised.filter { $0.appName == "Chrome" }.count == 1)
        // Apps that are only noisy still get their own row.
        #expect(raised.contains { $0.rule == .wakeupStorm && $0.appName == "Telegram" })
    }

    /// The overview showed Chrome twice — once for wakeups, once for power — which
    /// is one app's story told two ways. One app, one row.
    @Test("An app that trips several rules is listed once")
    func oneRowPerApp() {
        let engine = InsightEngine(thresholds: .init(sustainedEnergyWatts: 2.5),
                                   pressureSource: { .measured(.warning) })
        var state = InsightEngine.State()
        let now = Date()
        // Hot on energy, wakeups and memory at the same time.
        let busy = snapshot([
            group(name: "Chrome", watts: 18, cpu: 90,
                  memoryBytes: 4 * 1024 * 1024 * 1024, wakeups: 1834),
        ])

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state,
                            now: now.addingTimeInterval(180))

        #expect(state.activeInsights.count == 1)
        // Measured power is the most direct statement of cost, so it is the one shown.
        #expect(state.activeInsights.first?.rule == .sustainedEnergy)
    }

    // MARK: - Section 5.9 sleep prevention

    private func assertion(pid: pid_t, name: String = "video call in progress")
        -> SleepAssertionCollector.Assertion {
        .init(pid: pid, kind: .systemSleep, name: name)
    }

    /// The case the rule exists for: an app still holding the machine awake after
    /// the screen has gone dark, which is what empties a battery in a closed bag.
    @Test("An app holding an assertion with the screen off is named")
    func assertionWithScreenOffFires() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let snap = snapshot(
            [group(name: "Zoom", watts: 0, pid: 42)],
            assertions: [assertion(pid: 42)], displayAsleep: true)

        _ = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state, now: now)
        // Past the rule's five-minute window.
        let raised = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(400))

        let sleep = raised.first { $0.rule == .sleepPrevention }
        #expect(sleep?.appName == "Zoom")
        // The system's own words for the assertion travel with the claim.
        #expect(sleep?.evidence.contains("video call in progress") == true)
    }

    /// An assertion held while the user is working is the feature working. Firing
    /// here would make the rule noise during every video call.
    @Test("An assertion while the screen is on is not an insight")
    func assertionWithScreenOnStaysSilent() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let snap = snapshot(
            [group(name: "Zoom", watts: 0, pid: 42)],
            assertions: [assertion(pid: 42)], displayAsleep: false)

        _ = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(400))

        #expect(raised.allSatisfy { $0.rule != .sleepPrevention })
    }

    /// powerd holds an assertion whenever the display is on. Blaming macOS for macOS
    /// is noise the user can do nothing about.
    @Test("A system-owned process is never blamed for keeping the Mac awake")
    func systemProcessIsNotBlamed() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let snap = snapshot(
            [group(name: "powerd", watts: 0, pid: 355, userID: 0)],
            assertions: [assertion(pid: 355, name: "Prevent sleep while display is on")],
            displayAsleep: true)

        _ = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(400))

        #expect(raised.allSatisfy { $0.rule != .sleepPrevention })
    }

    /// Section 4: an unreadable interface is unknown, not "nothing is holding one".
    @Test("An unreadable assertion source raises nothing")
    func unreadableAssertionsRaiseNothing() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let snap = snapshot([group(name: "Zoom", watts: 0, pid: 42)],
                            assertions: nil, displayAsleep: true)

        _ = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(400))

        #expect(raised.allSatisfy { $0.rule != .sleepPrevention })
    }

    /// A brief assertion around finishing a task is normal; the rule waits.
    @Test("A short-lived assertion does not raise an insight")
    func briefAssertionDoesNotFire() {
        let engine = InsightEngine()
        var state = InsightEngine.State()
        let now = Date()
        let snap = snapshot(
            [group(name: "Handbrake", watts: 0, pid: 42)],
            assertions: [assertion(pid: 42)], displayAsleep: true)

        _ = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state, now: now)
        // Two minutes: well short of the five the rule requires.
        let raised = engine.evaluate(snapshot: snap, foregroundGroupIDs: [], state: &state,
                                     now: now.addingTimeInterval(120))

        #expect(raised.allSatisfy { $0.rule != .sleepPrevention })
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

    // MARK: - Section 8.3 memory rule

    /// The gate is the kernel's verdict, so tests drive it directly rather than
    /// trying to put the host machine under real memory pressure.
    private func engine(pressure: IntervalMetric<MemoryPressureLevel>) -> InsightEngine {
        InsightEngine(thresholds: .init(), pressureSource: { pressure })
    }

    /// A busy-but-healthy Mac: plenty of large apps, no pressure. This is the case
    /// the footprint-sum gate could never express — a rank always selects someone,
    /// so the rule named the top decile of a perfectly fine system.
    private var busyButHealthy: [ApplicationGroup] {
        var groups = [
            group(name: "Teams", watts: 0, memoryBytes: 1_600 * 1_048_576),
            group(name: "Claude", watts: 0, memoryBytes: 583 * 1_048_576),
            group(name: "Maccy", watts: 0, memoryBytes: 152 * 1_048_576),
            group(name: "Finder", watts: 0, memoryBytes: 133 * 1_048_576),
            group(name: "loginwindow", watts: 0, memoryBytes: 51 * 1_048_576),
        ]
        for i in 0..<40 {
            groups.append(group(name: "helper\(i)", watts: 0, memoryBytes: 20 * 1_048_576))
        }
        return groups
    }

    @Test("A healthy system raises no memory insight, however large the apps")
    func normalPressureRaisesNothing() {
        let engine = engine(pressure: .measured(.normal))
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot(busyButHealthy)

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        // Well past the rule's 60-second window: duration is not what is holding it back.
        let raised = engine.evaluate(
            snapshot: busy, foregroundGroupIDs: [], state: &state, now: now.addingTimeInterval(120))

        #expect(raised.allSatisfy { $0.rule != .memoryPressure })
        #expect(state.activeInsights.allSatisfy { $0.rule != .memoryPressure })
    }

    @Test("Under real pressure the largest app is named")
    func pressureNamesTheLargestApp() {
        let engine = engine(pressure: .measured(.warning))
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot(busyButHealthy)

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(
            snapshot: busy, foregroundGroupIDs: [], state: &state, now: now.addingTimeInterval(120))

        let memory = raised.filter { $0.rule == .memoryPressure }
        #expect(memory.count == 1)
        #expect(memory.first?.appName == "Teams")
        #expect(memory.first?.evidence.contains("elevated") == true)
    }

    /// The bug from the field: a 51 MB process called "a major contributor to memory
    /// pressure" purely for placing in the top decile of a long process list.
    @Test("A small app is never named, even in the top decile under pressure")
    func smallAppIsNotBlamed() {
        let engine = engine(pressure: .measured(.critical))
        var state = InsightEngine.State()
        let now = Date()
        // Everything is small: the top decile exists, but nothing here is a cause.
        let small = snapshot((0..<40).map {
            group(name: "small\($0)", watts: 0, memoryBytes: UInt64(60 - $0) * 1_048_576)
        })

        _ = engine.evaluate(snapshot: small, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(
            snapshot: small, foregroundGroupIDs: [], state: &state, now: now.addingTimeInterval(120))

        #expect(raised.allSatisfy { $0.rule != .memoryPressure })
    }

    @Test("An unreadable pressure level raises nothing rather than assuming")
    func unavailablePressureRaisesNothing() {
        let engine = engine(pressure: .unavailable(.notSupportedOnThisOS))
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot(busyButHealthy)

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        let raised = engine.evaluate(
            snapshot: busy, foregroundGroupIDs: [], state: &state, now: now.addingTimeInterval(120))

        #expect(raised.allSatisfy { $0.rule != .memoryPressure })
    }

    @Test("Pressure returning to normal withdraws the insight")
    func pressureLapseWithdrawsInsight() {
        var level: IntervalMetric<MemoryPressureLevel> = .measured(.warning)
        let box = LevelBox(level)
        let engine = InsightEngine(thresholds: .init(), pressureSource: { box.value })
        var state = InsightEngine.State()
        let now = Date()
        let busy = snapshot(busyButHealthy)

        _ = engine.evaluate(snapshot: busy, foregroundGroupIDs: [], state: &state, now: now)
        _ = engine.evaluate(
            snapshot: busy, foregroundGroupIDs: [], state: &state, now: now.addingTimeInterval(120))
        #expect(state.activeInsights.contains { $0.rule == .memoryPressure })

        level = .measured(.normal)
        box.value = level
        _ = engine.evaluate(
            snapshot: busy, foregroundGroupIDs: [], state: &state, now: now.addingTimeInterval(180))
        #expect(state.activeInsights.allSatisfy { $0.rule != .memoryPressure })
    }
}

/// Lets a test flip the pressure level between cycles.
private final class LevelBox: @unchecked Sendable {
    var value: IntervalMetric<MemoryPressureLevel>
    init(_ value: IntervalMetric<MemoryPressureLevel>) { self.value = value }
}
