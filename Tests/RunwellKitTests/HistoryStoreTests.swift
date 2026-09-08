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
        onBattery: Bool = true, first: Bool = false
    ) -> SamplerSnapshot {
        let id = identity(name: app)
        let metrics = ProcessIntervalMetrics(
            key: id.key, identity: id, intervalSeconds: 2,
            cpuPercent: .derived(cpu),
            physicalFootprintBytes: .measured(2048),
            energyWatts: .derived(Double(energyNJ) / 2 / 1_000_000_000),
            energyDeltaNJ: energyNJ,
            diskReadBytesPerSecond: .derived(100),
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
            coverage: EnergyCoverage(groups: [group], accessibleEnergyNJ: energyNJ, inaccessibleProcessCount: 3),
            battery: battery,
            capabilities: CapabilitySet(statuses: [:], osBuild: "test", hardwareModel: "test",
                                        logicalProcessorCount: 8, hasBattery: true),
            mode: .foreground, cycleDuration: .milliseconds(50),
            skippedCycles: 0, isFirstSample: first
        )
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
}
