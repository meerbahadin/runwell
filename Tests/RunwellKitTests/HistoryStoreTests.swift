import Testing
import Foundation
@testable import RunwellKit

/// Section 7 and the Section 12.2 acceptance criterion: "History survives relaunch,
/// respects retention and does not bridge invalid deltas across session boundaries."
@Suite("History store")
struct HistoryStoreTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("powertask-test-\(UUID().uuidString).sqlite")
    }

    private func identity(name: String, pid: pid_t = 1) -> ProcessIdentity {
        ProcessIdentity(
            key: ProcessKey(pid: pid, startAbsoluteTime: 1),
            name: name, executable: nil, parentPID: 1, userID: getuid(),
            groupID: ApplicationGroupID(bundle: "com.example.\(name)"),
            groupDisplayName: name, groupingReason: .bundleOwnership,
            bundleURL: nil, isPrincipalProcess: true
        )
    }

    private func snapshot(
        app: String, energyNJ: UInt64, cpu: Double = 10, percentage: Double = 80,
        onBattery: Bool = true, first: Bool = false, intervalSeconds: Double = 2,
        disk: Double = 100, inaccessibleCount: Int = 3
    ) -> SamplerSnapshot {
        let id = identity(name: app)
        let metrics = ProcessIntervalMetrics(
            key: id.key, identity: id, intervalSeconds: intervalSeconds,
            cpuPercent: .derived(cpu),
            physicalFootprintBytes: .measured(2048),
            energyWatts: .derived(Double(energyNJ) / intervalSeconds / 1_000_000_000),
            energyDeltaNJ: energyNJ,
            diskReadBytesPerSecond: .derived(disk),
            diskWriteBytesPerSecond: .derived(0),
            wakeupsPerSecond: .derived(1)
        )
        let group = ApplicationGroup(
            id: id.groupID, displayName: app, bundleURL: nil,
            members: [metrics], status: .normal
        )
        let battery = BatterySnapshot(
            percentage: .measured(percentage),
            powerSource: onBattery ? .battery : .wallPower,
            isCharging: false, isCharged: false, isPresent: true,
            timeRemaining: .unavailable(.awaitingSecondSample),
            capturedAt: MonotonicInstant.now()
        )
        return SamplerSnapshot(
            sessionID: SampleSessionID(), groups: [group],
            coverage: EnergyCoverage(groups: [group], accessibleEnergyNJ: energyNJ,
                                     inaccessibleProcessCount: inaccessibleCount),
            battery: battery,
            capabilities: CapabilitySet(statuses: [:], osBuild: "test", hardwareModel: "test",
                                        logicalProcessorCount: 8, hasBattery: true),
            mode: .foreground, cycleDuration: .milliseconds(50),
            skippedCycles: 0, isFirstSample: first
        )
    }

    /// A sample where the process could not actually be read — permission denied
    /// is the common real cause. Every metric is `.unavailable`, not a measured
    /// zero, which is exactly the distinction the zero-as-unavailable regression
    /// tests below depend on.
    private func unreadableSnapshot(app: String, intervalSeconds: Double = 2) -> SamplerSnapshot {
        let id = identity(name: app)
        let metrics = ProcessIntervalMetrics(
            key: id.key, identity: id, intervalSeconds: intervalSeconds,
            cpuPercent: .unavailable(.permissionDenied),
            physicalFootprintBytes: .unavailable(.permissionDenied),
            energyWatts: .unavailable(.permissionDenied),
            energyDeltaNJ: nil,
            diskReadBytesPerSecond: .unavailable(.permissionDenied),
            diskWriteBytesPerSecond: .unavailable(.permissionDenied),
            wakeupsPerSecond: .unavailable(.permissionDenied)
        )
        let group = ApplicationGroup(
            id: id.groupID, displayName: app, bundleURL: nil,
            members: [metrics], status: .normal
        )
        let battery = BatterySnapshot(
            percentage: .measured(80), powerSource: .battery,
            isCharging: false, isCharged: false, isPresent: true,
            timeRemaining: .unavailable(.awaitingSecondSample),
            capturedAt: MonotonicInstant.now()
        )
        return SamplerSnapshot(
            sessionID: SampleSessionID(), groups: [group],
            coverage: EnergyCoverage(groups: [group], accessibleEnergyNJ: 0, inaccessibleProcessCount: 1),
            battery: battery,
            capabilities: CapabilitySet(statuses: [:], osBuild: "test", hardwareModel: "test",
                                        logicalProcessorCount: 8, hasBattery: true),
            mode: .foreground, cycleDuration: .milliseconds(50),
            skippedCycles: 0, isFirstSample: false
        )
    }

    // MARK: - Section 7.1 insight persistence

    private func insight(
        _ rule: InsightRule, app: String, at started: Date,
        severity: InsightSeverity = .warning
    ) -> Insight {
        Insight(rule: rule, appGroupID: ApplicationGroupID(bundle: "com.example.\(app)"),
                appName: app, startedAt: started, severity: severity,
                evidence: "Drawing 18.0 W.")
    }

    /// The table existed from the first migration but nothing wrote to it, so every
    /// condition vanished when it scrolled off screen.
    @Test("A raised insight is stored and read back with its duration")
    func insightPersisted() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)

        let started = Date().addingTimeInterval(-3600)
        try await store.recordInsightsRaised([insight(.sustainedEnergy, app: "Chrome", at: started)])
        // The condition lapses an hour later.
        try await store.closeInsights(stillOpen: [], at: started.addingTimeInterval(3600))

        let episodes = try await store.insightHistory(
            from: started.addingTimeInterval(-60), to: Date())
        #expect(episodes.count == 1)
        #expect(episodes.first?.appName == "Chrome")
        #expect(episodes.first?.ended != nil)
        #expect(episodes.first.map { $0.duration() == 3600 } == true)
    }

    /// A condition that stays true is one episode, not one per cycle: the engine
    /// re-reports a live insight on every evaluation.
    @Test("Re-raising a live condition does not start a second episode")
    func liveConditionIsOneEpisode() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)

        let started = Date().addingTimeInterval(-600)
        let live = insight(.sustainedEnergy, app: "Chrome", at: started)
        for _ in 0..<5 {
            try await store.recordInsightsRaised([live])
        }

        let episodes = try await store.insightHistory(
            from: started.addingTimeInterval(-60), to: Date())
        #expect(episodes.count == 1)
        // Still open, so it has no end yet.
        #expect(episodes.first?.ended == nil)
    }

    @Test("Samples accumulate into buckets and read back")
    func writeAndRead() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)

        let now = Date()
        try await store.record(snapshot(app: "Chrome", energyNJ: 1_000_000_000), at: now)
        try await store.record(snapshot(app: "Chrome", energyNJ: 2_000_000_000), at: now)

        let rows = try await store.topEnergyConsumers(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        #expect(rows.count == 1)
        // Two cycles in the same minute must sum, not overwrite.
        #expect(rows.first?.energyNJ == 3_000_000_000)
        #expect(rows.first?.displayName == "Chrome")
    }

    @Test("The first sample of a session is not persisted")
    func firstSampleSkipped() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        // Section 3.2: nothing before it, so there is no valid interval to record.
        try await store.record(snapshot(app: "Chrome", energyNJ: 5_000_000_000, first: true))
        let rows = try await store.topEnergyConsumers(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        #expect(rows.isEmpty)
    }

    @Test("History survives reopening the database")
    func survivesRelaunch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date()
        do {
            let store = try HistoryStore(url: url)
            try await store.record(snapshot(app: "Xcode", energyNJ: 4_000_000_000), at: now)
        }
        // A second store over the same file is the relaunch case from Section 12.2.
        let reopened = try HistoryStore(url: url)
        let rows = try await reopened.topEnergyConsumers(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        #expect(rows.first?.energyNJ == 4_000_000_000)
    }

    @Test("Retention deletes buckets past their window")
    func retention() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()
        let old = now.addingTimeInterval(-10 * 86_400)   // beyond the 7-day 1m tier

        try await store.record(snapshot(app: "Old", energyNJ: 1_000_000_000), at: old)
        try await store.record(snapshot(app: "New", energyNJ: 1_000_000_000), at: now)
        try await store.prune(now: now)

        let rows = try await store.topEnergyConsumers(
            from: old.addingTimeInterval(-86_400), to: now.addingTimeInterval(3600))
        #expect(rows.map(\.displayName) == ["New"])
    }

    @Test("Clearing history empties every table")
    func clearHistory() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        try await store.record(snapshot(app: "Chrome", energyNJ: 1_000_000_000))
        try await store.deleteAllHistory()

        let stats = try await store.statistics(url: url)
        #expect(stats.bucketRows == 0)
        #expect(stats.batterySamples == 0)
        #expect(stats.applications == 0)
    }

    @Test("A discharge run becomes a battery session")
    func batterySessions() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let start = Date().addingTimeInterval(-3600)

        // 100% down to 85% over ten minutes on battery.
        for step in 0..<10 {
            try await store.record(
                snapshot(app: "Chrome", energyNJ: 1_000_000_000,
                         percentage: 100 - Double(step) * 1.5, onBattery: true),
                at: start.addingTimeInterval(Double(step) * 60))
        }
        let sessions = try await store.batterySessions(
            from: start.addingTimeInterval(-60), to: Date())
        #expect(sessions.count == 1)
        #expect(sessions.first?.percentageUsed ?? 0 > 13)
    }

    @Test("A gap in sampling splits sessions rather than joining them")
    func gapSplitsSessions() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let start = Date().addingTimeInterval(-7200)

        for step in 0..<3 {
            try await store.record(snapshot(app: "A", energyNJ: 1_000_000_000,
                                            percentage: 100 - Double(step)),
                                   at: start.addingTimeInterval(Double(step) * 60))
        }
        // An hour with the collector not running: the two runs must not be bridged.
        for step in 0..<3 {
            try await store.record(snapshot(app: "A", energyNJ: 1_000_000_000,
                                            percentage: 80 - Double(step)),
                                   at: start.addingTimeInterval(3600 + Double(step) * 60))
        }
        let sessions = try await store.batterySessions(from: start.addingTimeInterval(-60), to: Date())
        #expect(sessions.count == 2)
    }

    @Test("Shares are a fraction of all measured energy, not just the listed rows")
    func shareDenominator() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()

        // Three apps at 3:1:1. The top row must read 60%, not 100%.
        try await store.record(snapshot(app: "Big", energyNJ: 3_000_000_000), at: now)
        try await store.record(snapshot(app: "Small1", energyNJ: 1_000_000_000), at: now)
        try await store.record(snapshot(app: "Small2", energyNJ: 1_000_000_000), at: now)

        let breakdown = try await store.energyBreakdown(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600), limit: 1)
        #expect(breakdown.rows.count == 1)
        let share = breakdown.share(of: breakdown.rows[0])
        #expect(abs(share - 0.6) < 0.001)
    }

    @Test("Average power is energy over the time actually observed")
    func averageWatts() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()

        // One 2-second sample carrying 2 J: an average of exactly 1 watt.
        try await store.record(snapshot(app: "Steady", energyNJ: 2_000_000_000), at: now)
        let breakdown = try await store.energyBreakdown(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        #expect(abs((breakdown.rows.first?.averageWatts ?? 0) - 1.0) < 0.001)
    }

    /// Regression test: observed duration used to be reconstructed at read time as
    /// `sampleCount * 2`, hardcoding the foreground cadence regardless of which
    /// sampling mode actually produced each sample. A single 10-second sample (the
    /// battery-idle interval) carrying 10 J is 1 watt on average — the old formula
    /// would have called it `1 * 2 = 2` observed seconds, reporting 5 watts, 5x high.
    @Test("Average power is correct for samples outside the foreground interval")
    func averageWattsOutsideForeground() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()

        try await store.record(
            snapshot(app: "Backgrounded", energyNJ: 10_000_000_000, intervalSeconds: 10),
            at: now)
        let breakdown = try await store.energyBreakdown(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        #expect(abs((breakdown.rows.first?.averageWatts ?? 0) - 1.0) < 0.001)
    }

    /// Mixed-mode history — some samples recorded while foregrounded, some while
    /// backgrounded — must sum actual observed seconds across the mix, not assume
    /// a single interval for the whole bucket.
    @Test("Average power over a mix of sampling intervals sums true observed seconds")
    func averageWattsMixedIntervals() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()

        // 2s foreground sample: 2 J. Then a 10s battery-idle sample: 10 J.
        // Total: 12 J over 12 true seconds = exactly 1 watt.
        try await store.record(
            snapshot(app: "Mixed", energyNJ: 2_000_000_000, intervalSeconds: 2), at: now)
        try await store.record(
            snapshot(app: "Mixed", energyNJ: 10_000_000_000, intervalSeconds: 10),
            at: now.addingTimeInterval(2))
        let breakdown = try await store.energyBreakdown(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        #expect(abs((breakdown.rows.first?.averageWatts ?? 0) - 1.0) < 0.001)
    }

    // MARK: - Section 3 / Appendix F: unavailable is not zero

    /// Regression test: an app that was never readable across a window used to be
    /// summed as 0 J and reported as "barely any power — 0.00 W", a specific and
    /// wrong claim rather than an honest "could not measure".
    @Test("An app never readable in a window reports no energy, not zero")
    func neverReadableReportsNilEnergy() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()

        try await store.record(unreadableSnapshot(app: "Sandboxed"), at: now)
        let breakdown = try await store.energyBreakdown(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))

        let row = try #require(breakdown.rows.first { $0.displayName == "Sandboxed" })
        #expect(row.energyNJ == nil)
        #expect(row.averageWatts == nil)
        #expect(row.averageCPUPercent == nil)
        #expect(row.peakMemoryBytes == nil)
        // An unmeasurable app has no share of what could be measured, not a
        // fabricated one — the visual is "no bar", the same as genuinely zero
        // usage, but the underlying number is honestly absent.
        #expect(breakdown.share(of: row) == 0)
    }

    /// An app unreadable for part of a window, then readable, must report the
    /// average of the samples that were actually readable — not have its true
    /// average silently diluted by treating the unreadable half as measured zeros.
    @Test("Average power is computed only from the samples that were readable")
    func partiallyReadableAveragesOnlyReadableSamples() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let now = Date()

        // One unreadable 2s cycle, then one readable 2s cycle carrying 2 J (1 W).
        // The old formula divided by total sample_count (2), halving the true
        // average to 0.5 W; the fix divides only by the one readable sample.
        try await store.record(unreadableSnapshot(app: "Flaky"), at: now)
        try await store.record(
            snapshot(app: "Flaky", energyNJ: 2_000_000_000, intervalSeconds: 2),
            at: now.addingTimeInterval(2))

        let breakdown = try await store.energyBreakdown(
            from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(3600))
        let row = try #require(breakdown.rows.first { $0.displayName == "Flaky" })
        #expect(abs((row.averageWatts ?? 0) - 1.0) < 0.001)
    }

    @Test("Charging samples do not count as a discharge session")
    func chargingIsNotDischarge() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try HistoryStore(url: url)
        let start = Date().addingTimeInterval(-600)
        for step in 0..<5 {
            try await store.record(snapshot(app: "A", energyNJ: 1_000_000_000,
                                            percentage: 50 + Double(step), onBattery: false),
                                   at: start.addingTimeInterval(Double(step) * 60))
        }
        let sessions = try await store.batterySessions(from: start.addingTimeInterval(-60), to: Date())
        #expect(sessions.isEmpty)
    }

    // MARK: - Idle-row omission and real coverage (2026-09-09 baseline findings)

    /// A day of real usage produced 167k bucket rows, 45% of which recorded that an
    /// idle daemon did nothing. Those rows are omitted now — but only when Runwell
    /// positively measured the app doing nothing.
    @Test("A measured-idle app writes no bucket row")
    func measuredIdleWritesNoRow() async throws {
        let url = temporaryURL()
        let store = try HistoryStore(url: url)
        // Not the first sample: that is skipped for a different reason.
        try await store.record(snapshot(app: "Busy", energyNJ: 1_000, cpu: 5))
        try await store.record(snapshot(app: "Idle", energyNJ: 0, cpu: 0, disk: 0))

        let stats = try await store.statistics(url: url)
        // Only the 1m tier is written live now; 15m is rolled up on the retention
        // pass. Busy writes its minute row, Idle writes nothing.
        #expect(stats.bucketRows == 1)

        let rows = try await store.topEnergyConsumers(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        #expect(rows.map(\.displayName) == ["Busy"])
    }

    /// The Appendix F half of the same guard: unreadable is not idle. An app whose
    /// metrics could not be read must keep its row, or "we could not see this"
    /// becomes indistinguishable from "we saw nothing happen".
    @Test("An unreadable app still writes a row, unlike a measured-idle one")
    func unreadableStillWritesRow() async throws {
        let url = temporaryURL()
        let store = try HistoryStore(url: url)
        try await store.record(unreadableSnapshot(app: "Blocked"))

        let stats = try await store.statistics(url: url)
        #expect(stats.bucketRows == 1)  // the minute row is preserved
    }

    /// Omitting idle rows must not move any number the UI shows. Both bucket read
    /// paths are SUM/MAX aggregates, to which a row of zeros contributes exactly
    /// what an absent row does.
    @Test("Omitting idle rows leaves aggregates unchanged")
    func idleOmissionPreservesAggregates() async throws {
        let store = try HistoryStore(url: temporaryURL())
        try await store.record(snapshot(app: "Busy", energyNJ: 4_000, cpu: 8))
        try await store.record(snapshot(app: "Idle", energyNJ: 0, cpu: 0, disk: 0))

        let breakdown = try await store.energyBreakdown(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        #expect(breakdown.totalEnergyNJ == 4_000)
    }

    /// Every row ever written stored exactly 0.85, a literal from MetricEngine, in a
    /// column whose whole purpose is to vary with how much of the machine was
    /// readable. It must now reflect the sample's real coverage.
    @Test("Stored coverage reflects real readable share, not a constant")
    func coverageIsNotHardcoded() async throws {
        let store = try HistoryStore(url: temporaryURL())
        // 1 readable group of 1 process, 3 inaccessible -> 1/4 = 0.25.
        try await store.record(snapshot(app: "Busy", energyNJ: 1_000, cpu: 5))

        let rows = try await store.topEnergyConsumers(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        #expect(rows.count == 1)
        #expect(abs(rows[0].confidence - 0.25) < 0.001)
        #expect(rows[0].confidence != 0.85)
    }

    /// Full coverage is the honest 1.0, not a discounted constant.
    @Test("Full coverage stores 1.0")
    func fullCoverageIsOne() async throws {
        let store = try HistoryStore(url: temporaryURL())
        try await store.record(
            snapshot(app: "Busy", energyNJ: 1_000, cpu: 5, inaccessibleCount: 0))

        let rows = try await store.topEnergyConsumers(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        #expect(abs(rows[0].confidence - 1.0) < 0.001)
    }


    /// Section 3.1: the breakdown must carry the share of the machine it was
    /// measured from, so the UI can say these totals are not the whole picture.
    @Test("Energy breakdown reports the coverage it was measured at")
    func breakdownCarriesCoverage() async throws {
        let store = try HistoryStore(url: temporaryURL())
        // 1 readable process, 3 unreadable -> 0.25 coverage.
        try await store.record(snapshot(app: "Busy", energyNJ: 1_000, cpu: 5))

        let breakdown = try await store.energyBreakdown(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        let coverage = try #require(breakdown.coverage)
        #expect(abs(coverage - 0.25) < 0.001)
        #expect(breakdown.isPartial)
    }

    /// Full coverage must not nag: the disclosure is for genuinely partial totals.
    @Test("Full coverage is not reported as partial")
    func fullCoverageIsNotPartial() async throws {
        let store = try HistoryStore(url: temporaryURL())
        try await store.record(
            snapshot(app: "Busy", energyNJ: 1_000, cpu: 5, inaccessibleCount: 0))

        let breakdown = try await store.energyBreakdown(
            from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(3600))
        #expect(breakdown.isPartial == false)
    }


    // MARK: - Quarter-hour rollup and size ceiling

    /// The 15m tier used to be accumulated live alongside 1m. Rolling it up must
    /// produce the same totals the dual write did, or historical quarter-hours would
    /// silently change value.
    @Test("Rolled-up 15m buckets match the sum of their minutes")
    func rollUpMatchesMinutes() async throws {
        let store = try HistoryStore(url: temporaryURL())
        // Three samples inside one quarter-hour, at distinct minutes.
        let base = Date(timeIntervalSince1970: TimeInterval(1_000_000 / 900 * 900))
        for offset in [0.0, 60.0, 120.0] {
            try await store.record(
                snapshot(app: "Busy", energyNJ: 1_000, cpu: 6),
                at: base.addingTimeInterval(offset))
        }
        // Roll up from a point after that quarter-hour has fully elapsed.
        try await store.rollUpQuarterHours(now: base.addingTimeInterval(1_800))

        let minutes = try await store.energyBreakdown(
            from: base, to: base.addingTimeInterval(900), granularity: "1m")
        let quarter = try await store.energyBreakdown(
            from: base, to: base.addingTimeInterval(900), granularity: "15m")
        #expect(minutes.totalEnergyNJ == 3_000)
        #expect(quarter.totalEnergyNJ == minutes.totalEnergyNJ)
        #expect(quarter.rows.count == 1)
        #expect(quarter.rows[0].observedSeconds == minutes.rows[0].observedSeconds)
    }

    /// Rolling up twice must not double-count: the retention pass runs hourly and
    /// will revisit the same completed quarter-hours.
    @Test("Rolling up twice is idempotent")
    func rollUpIsIdempotent() async throws {
        let store = try HistoryStore(url: temporaryURL())
        let base = Date(timeIntervalSince1970: TimeInterval(1_000_000 / 900 * 900))
        try await store.record(snapshot(app: "Busy", energyNJ: 5_000, cpu: 6), at: base)

        try await store.rollUpQuarterHours(now: base.addingTimeInterval(1_800))
        try await store.rollUpQuarterHours(now: base.addingTimeInterval(1_800))

        let quarter = try await store.energyBreakdown(
            from: base, to: base.addingTimeInterval(900), granularity: "15m")
        #expect(quarter.totalEnergyNJ == 5_000)
    }

    /// A quarter-hour still in progress must not be rolled up, or it would be
    /// written from partial data and then rewritten as later minutes arrive.
    @Test("An in-progress quarter-hour is not rolled up")
    func rollUpSkipsIncompleteWindow() async throws {
        let store = try HistoryStore(url: temporaryURL())
        let base = Date(timeIntervalSince1970: TimeInterval(1_000_000 / 900 * 900))
        try await store.record(snapshot(app: "Busy", energyNJ: 5_000, cpu: 6), at: base)

        // "Now" is inside the same quarter-hour the sample landed in.
        try await store.rollUpQuarterHours(now: base.addingTimeInterval(60))

        let quarter = try await store.energyBreakdown(
            from: base, to: base.addingTimeInterval(900), granularity: "15m")
        #expect(quarter.rows.isEmpty)
    }


    /// The retention pass must roll up before it deletes: 1m rows expire long before
    /// the 15m tier does, so rolling up afterwards would lose every quarter-hour
    /// whose minutes had just aged out.
    @Test("Prune rolls up before deleting expired minutes")
    func pruneRollsUpBeforeDeleting() async throws {
        let policy = HistoryStore.RetentionPolicy(
            rawSampleHours: 2, minuteBucketDays: 7, quarterHourBucketDays: 30,
            insightDays: 90, identityDaysAfterLastSeen: 30)
        let store = try HistoryStore(url: temporaryURL(), retention: policy)

        // A sample from 8 days ago: past 1m retention, inside 15m retention.
        let old = Date().addingTimeInterval(-8 * 86_400)
        try await store.record(snapshot(app: "Busy", energyNJ: 9_000, cpu: 4), at: old)
        try await store.prune()

        // The minute row is gone, but its energy survives in the rolled-up tier.
        let minutes = try await store.energyBreakdown(
            from: old.addingTimeInterval(-900), to: old.addingTimeInterval(900),
            granularity: "1m")
        let quarter = try await store.energyBreakdown(
            from: old.addingTimeInterval(-900), to: old.addingTimeInterval(900),
            granularity: "15m")
        #expect(minutes.totalEnergyNJ == 0)
        #expect(quarter.totalEnergyNJ == 9_000)
    }

}
