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
        public var memoryPressureBytes: UInt64
        /// An app must also be in the top decile of footprint (Section 8.3).
        public var memoryTopDecileFraction: Double

        public init(
            sustainedEnergyWatts: Double = 2.0,
            backgroundCPUPercent: Double = 15,
            backgroundEnergyWatts: Double = 0.5,
            wakeupsPerSecond: Double = 150,
            memoryPressureBytes: UInt64 = 2 * 1024 * 1024 * 1024,
            memoryTopDecileFraction: Double = 0.1
        ) {
            self.sustainedEnergyWatts = sustainedEnergyWatts
            self.backgroundCPUPercent = backgroundCPUPercent
            self.backgroundEnergyWatts = backgroundEnergyWatts
            self.wakeupsPerSecond = wakeupsPerSecond
            self.memoryPressureBytes = memoryPressureBytes
            self.memoryTopDecileFraction = memoryTopDecileFraction
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

    public init(thresholds: Thresholds = .init()) {
        self.thresholds = thresholds
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

        public var activeInsights: [Insight] {
            raised.values.sorted { $0.startedAt < $1.startedAt }
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

        // Section 8.3 memory rule: "top decile" needs the distribution, not just the
        // one app, so the cutoff is computed once per cycle.
        let footprints = snapshot.groups.compactMap(\.totalFootprintBytes.value).sorted(by: >)
        let decileIndex = max(0, Int(Double(footprints.count) * thresholds.memoryTopDecileFraction) - 1)
        let topDecileCutoff = footprints.isEmpty ? UInt64.max : footprints[min(decileIndex, footprints.count - 1)]
        let totalFootprint = footprints.reduce(UInt64(0), &+)
        let systemUnderMemoryPressure = totalFootprint >= thresholds.memoryPressureBytes

        for group in snapshot.groups {
            let isForeground = foregroundGroupIDs.contains(group.id)

            for rule in InsightRule.allCases where rule.isAvailable {
                let key = "\(rule.rawValue):\(group.id.storageKey)"
                guard !state.muted.contains(key) else { continue }

                let evidence = self.evidence(
                    for: rule, group: group, isForeground: isForeground,
                    topDecileCutoff: topDecileCutoff,
                    systemUnderMemoryPressure: systemUnderMemoryPressure
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

        return newlyRaised
    }

    /// Returns the evidence string when a rule's condition is met, or nil when it is
    /// not. Returning the evidence rather than a bare Bool means an insight can never
    /// be raised without the numbers that justify it.
    private func evidence(
        for rule: InsightRule,
        group: ApplicationGroup,
        isForeground: Bool,
        topDecileCutoff: UInt64,
        systemUnderMemoryPressure: Bool
    ) -> String? {
        switch rule {
        case .sustainedEnergy:
            // Section 3: an unavailable reading is not a low reading. A rule must
            // never fire, or fail to fire, on a value that was never measured.
            guard let watts = group.totalEnergyWatts.value,
                  watts >= thresholds.sustainedEnergyWatts else { return nil }
            return String(format: "Averaged %.2f W, above the %.2f W threshold for this Mac.",
                          watts, thresholds.sustainedEnergyWatts)

        case .hiddenBackgroundLoad:
            guard !isForeground else { return nil }
            if let cpu = group.totalCPUPercent.value, cpu >= thresholds.backgroundCPUPercent {
                return String(format: "Used %.1f%% CPU while not in front.", cpu)
            }
            if let watts = group.totalEnergyWatts.value, watts >= thresholds.backgroundEnergyWatts {
                return String(format: "Used %.2f W while not in front.", watts)
            }
            return nil

        case .memoryPressure:
            guard systemUnderMemoryPressure,
                  let bytes = group.totalFootprintBytes.value,
                  bytes >= topDecileCutoff else { return nil }
            let mb = Double(bytes) / 1_048_576
            return mb >= 1024
                ? String(format: "Holding %.1f GB, among the largest on this Mac.", mb / 1024)
                : String(format: "Holding %.0f MB, among the largest on this Mac.", mb)

        case .wakeupStorm:
            guard let wakeups = group.totalWakeupsPerSecond.value,
                  wakeups >= thresholds.wakeupsPerSecond else { return nil }
            return String(format: "Woke the processor %.0f times per second.", wakeups)

        case .sleepPrevention:
            // Section 5.9: no validated source yet, so this never fires rather than
            // guessing from an unrelated signal.
            return nil
        }
    }
}
