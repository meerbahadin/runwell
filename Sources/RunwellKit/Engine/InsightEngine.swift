import Foundation

/// Section 4.1 / 8.3. Produces deterministic, explainable messages from sustained
/// conditions.
///
/// The engine is stateful on purpose: every rule in Section 8.3 requires a condition
/// to *hold* for a period, so a single spike must never raise an insight. It tracks
/// when each condition began and only raises once the required duration has passed.
public struct InsightEngine: Sendable {
    /// Section 8.3 thresholds. "Device-calibrated" for energy: a fanless Air and a
    /// 16-inch Pro do not share a sensible watt threshold, so the baseline scales with
    /// core count rather than being a fixed constant.
    public struct Thresholds: Sendable {
        public var sustainedEnergyWatts: Double
        public var backgroundCPUPercent: Double
        public var backgroundEnergyWatts: Double
        public var wakeupsPerSecond: Double
        /// Behind the kernel pressure gate, an app must *also* be in the top decile
        /// of footprint (Section 8.3) and hold a materially large amount, so that a
        /// rank alone can never make a small process look like a cause.
        public var memoryTopDecileFraction: Double
        /// Absolute floor for the memory rule. The decile is a rank, not a size: on a
        /// machine where everything is small, the top decile is still small, and
        /// naming it would be a false accusation.
        public var memoryMinimumFootprintBytes: UInt64

        public init(
            sustainedEnergyWatts: Double = 2.0,
            backgroundCPUPercent: Double = 15,
            backgroundEnergyWatts: Double = 0.5,
            wakeupsPerSecond: Double = 150,
            memoryTopDecileFraction: Double = 0.1,
            memoryMinimumFootprintBytes: UInt64 = 1024 * 1024 * 1024
        ) {
            self.sustainedEnergyWatts = sustainedEnergyWatts
            self.backgroundCPUPercent = backgroundCPUPercent
            self.backgroundEnergyWatts = backgroundEnergyWatts
            self.wakeupsPerSecond = wakeupsPerSecond
            self.memoryTopDecileFraction = memoryTopDecileFraction
            self.memoryMinimumFootprintBytes = memoryMinimumFootprintBytes
        }

        /// Section 8.3 "device-calibrated threshold". More cores means more headroom
        /// before a given wattage is remarkable.
        public static func calibrated(for capabilities: CapabilitySet) -> Thresholds {
            var thresholds = Thresholds()
            let cores = max(4, capabilities.logicalProcessorCount)
            thresholds.sustainedEnergyWatts = 1.0 + Double(cores) / 8.0
            thresholds.backgroundCPUPercent = Double(cores) * 1.5
            thresholds.wakeupsPerSecond = 100 + Double(cores) * 5
            return thresholds
        }
    }

    public var thresholds: Thresholds
    /// Reads the kernel pressure level. Injected so tests can drive the gate
    /// directly instead of trying to put the whole machine under real pressure.
    private let pressureSource: @Sendable () -> IntervalMetric<MemoryPressureLevel>

    public init(
        thresholds: Thresholds = .init(),
        pressureSource: @escaping @Sendable () -> IntervalMetric<MemoryPressureLevel> = {
            MemoryPressureCollector().read()
        }
    ) {
        self.thresholds = thresholds
        self.pressureSource = pressureSource
    }

    /// When each (rule, app) condition was first seen continuously true. Cleared the
    /// moment the condition lapses, so an intermittent spike never accumulates.
    public struct State: Sendable {
        var conditionStartedAt: [String: Date] = [:]
        var raised: [String: Insight] = [:]
        /// Rules the user has muted for an app (Section 8.4 "Ignore alerts"), which
        /// suppresses the alert while leaving collection untouched.
        var muted: Set<String> = []

        public init() {}

        /// One row per app. Several rules firing for one app are several ways of
        /// saying "this app is costing you battery", and listing them all turned the
        /// overview into a wall the user has to deduplicate by eye. The
        /// highest-priority rule speaks for the app; the rest stay in `raised` so
        /// nothing is lost if that condition lapses.
        public var activeInsights: [Insight] {
            Dictionary(grouping: raised.values, by: { $0.appGroupID.storageKey })
                .values
                .compactMap { forApp in
                    forApp.max { a, b in
                        if a.rule.priority != b.rule.priority {
                            return a.rule.priority < b.rule.priority
                        }
                        // Same rule priority: the longer-running condition is the
                        // one that has proven itself.
                        return a.startedAt > b.startedAt
                    }
                }
                .sorted { $0.startedAt < $1.startedAt }
        }

        /// Section 8.4 "Ignore alerts": suppresses one rule for one app. Metric
        /// collection continues — only the alert is silenced.
        public mutating func mute(_ insight: Insight) {
            muted.insert(insight.id)
            raised[insight.id] = nil
        }

        public mutating func unmuteAll() {
            muted.removeAll()
        }

        public var mutedCount: Int { muted.count }
    }

    /// Evaluates every rule against one cycle and returns the insights that are newly
    /// raised, so the caller can notify only on transitions rather than every cycle.
    @discardableResult
    public func evaluate(
        snapshot: SamplerSnapshot,
        foregroundGroupIDs: Set<ApplicationGroupID>,
        state: inout State,
        now: Date = Date()
    ) -> [Insight] {
        var newlyRaised: [Insight] = []
        var seenKeys: Set<String> = []

        // Section 8.3 memory rule. The gate is the kernel's own verdict: when the
        // system is not under pressure there is no pressure to attribute, and the
        // rule stays silent no matter how the footprints are distributed. An
        // unreadable level is unknown, not "normal" and not "under pressure", so it
        // also stays silent (Section 3).
        // Section 5.9. Assertions matter only once the screen is dark: one held
        // while the user is working is the feature working as intended.
        let blamedByAssertion: [pid_t: SleepAssertionCollector.Assertion]
        if snapshot.displayIsAsleep, let assertions = snapshot.sleepAssertions {
            blamedByAssertion = Dictionary(
                assertions.filter(\.kind.isSystemLevel).map { ($0.pid, $0) },
                uniquingKeysWith: { first, _ in first })
        } else {
            blamedByAssertion = [:]
        }

        let pressureLevel = pressureSource()
        let systemUnderMemoryPressure = pressureLevel.value?.isUnderPressure ?? false

        // "Top decile" needs the distribution, not just the one app, so the cutoff is
        // computed once per cycle. It only narrows an already-open gate.
        let footprints = snapshot.groups.compactMap(\.totalFootprintBytes.value).sorted(by: >)
        let decileIndex = max(0, Int(Double(footprints.count) * thresholds.memoryTopDecileFraction) - 1)
        let topDecileCutoff = footprints.isEmpty ? UInt64.max : footprints[min(decileIndex, footprints.count - 1)]

        for group in snapshot.groups {
            let isForeground = foregroundGroupIDs.contains(group.id)

            for rule in InsightRule.allCases where rule.isAvailable {
                let key = "\(rule.rawValue):\(group.id.storageKey)"
                guard !state.muted.contains(key) else { continue }

                let evidence = self.evidence(
                    for: rule, group: group, isForeground: isForeground,
                    topDecileCutoff: topDecileCutoff,
                    pressureLevel: pressureLevel.value,
                    systemUnderMemoryPressure: systemUnderMemoryPressure,
                    assertions: blamedByAssertion
                )

                guard let evidence else {
                    // Condition not met: reset the clock and withdraw any live insight.
                    state.conditionStartedAt[key] = nil
                    state.raised[key] = nil
                    continue
                }

                seenKeys.insert(key)
                let started = state.conditionStartedAt[key] ?? now
                state.conditionStartedAt[key] = started

                // Section 8.3: the condition must hold for the rule's full duration.
                guard now.timeIntervalSince(started) >= rule.sustainedFor else { continue }

                if state.raised[key] == nil {
                    let insight = Insight(
                        rule: rule, appGroupID: group.id, appName: group.displayName,
                        startedAt: started,
                        severity: rule == .sustainedEnergy ? .warning : .info,
                        evidence: evidence
                    )
                    state.raised[key] = insight
                    newlyRaised.append(insight)
                }
            }
        }

        // An app that exited stops being a live condition.
        for key in state.raised.keys where !seenKeys.contains(key) {
            state.raised[key] = nil
            state.conditionStartedAt[key] = nil
        }

        // Only report transitions the user will actually see. A newly raised rule
        // that loses to a higher-priority one for the same app is not worth a
        // notification, since the overview will not show it either.
        let visible = Set(state.activeInsights.map(\.id))
        return newlyRaised.filter { visible.contains($0.id) }
    }

    /// Returns the evidence string when a rule's condition is met, or nil when it is
    /// not. Returning the evidence rather than a bare Bool means an insight can never
    /// be raised without the numbers that justify it.
    private func evidence(
        for rule: InsightRule,
        group: ApplicationGroup,
        isForeground: Bool,
        topDecileCutoff: UInt64,
        pressureLevel: MemoryPressureLevel?,
        systemUnderMemoryPressure: Bool,
        assertions: [pid_t: SleepAssertionCollector.Assertion]
    ) -> String? {
        switch rule {
        case .sustainedEnergy:
            // Section 3: an unavailable reading is not a low reading. A rule must
            // never fire, or fail to fire, on a value that was never measured.
            guard let watts = group.totalEnergyWatts.value,
                  watts >= thresholds.sustainedEnergyWatts else { return nil }
            // Plain units first, the threshold second: "18 W" is the fact, and the
            // comparison is what makes it meaningful.
            return String(format: "Drawing %.1f W — about %.0f× what's normal for this Mac.",
                          watts, watts / thresholds.sustainedEnergyWatts)

        case .hiddenBackgroundLoad:
            guard !isForeground else { return nil }
            if let cpu = group.totalCPUPercent.value, cpu >= thresholds.backgroundCPUPercent {
                return String(format: "Using %.0f%% of the processor while you're not using it.", cpu)
            }
            if let watts = group.totalEnergyWatts.value, watts >= thresholds.backgroundEnergyWatts {
                return String(format: "Drawing %.1f W while you're not using it.", watts)
            }
            return nil

        case .memoryPressure:
            guard systemUnderMemoryPressure,
                  let level = pressureLevel,
                  let bytes = group.totalFootprintBytes.value,
                  bytes >= topDecileCutoff,
                  bytes >= thresholds.memoryMinimumFootprintBytes else { return nil }
            let mb = Double(bytes) / 1_048_576
            let held = mb >= 1024
                ? String(format: "%.1f GB", mb / 1024)
                : String(format: "%.0f MB", mb)
            // The evidence names the kernel level, so the claim arrives with the
            // system-wide fact that justifies singling this app out.
            return "Holding \(held) while system memory pressure is \(level.label.lowercased())."


        case .wakeupStorm:
            guard let wakeups = group.totalWakeupsPerSecond.value,
                  wakeups >= thresholds.wakeupsPerSecond else { return nil }
            // Wakeups are a proxy for battery cost. When the energy counter already
            // says what this app costs, the proxy adds a second row about the same
            // app without adding information — so it defers to the measurement.
            if let watts = group.totalEnergyWatts.value,
               watts >= thresholds.sustainedEnergyWatts { return nil }
            // The mechanism stays, but framed as the cost it imposes: constant tiny
            // wake-ups stop the chip from idling, which is where battery goes.
            return String(format: "Interrupting the processor %.0f times a second, "
                          + "which stops it from idling.", wakeups)

        case .sleepPrevention:
            // The system's own processes hold assertions as a matter of course —
            // powerd keeps one whenever the display is on — and blaming macOS for
            // macOS is noise the user can do nothing about.
            guard !group.members.contains(where: { $0.identity.userID == 0 }) else { return nil }
            guard let assertion = group.members.lazy
                .compactMap({ assertions[$0.key.pid] }).first else { return nil }
            // The assertion's own description, so the claim arrives in the system's
            // words rather than ours.
            return "Holding a power assertion (\(assertion.name)) while the screen is off."
        }
    }
}
