import Foundation

/// Section 7. Writes samples and aggregates; prunes according to retention policy.
///
/// Section 9.1 governs what may be stored: bundle identifiers and display names stay
/// local, executable paths are redacted before they reach a row, and command-line
/// arguments are never collected at all.
public actor HistoryStore {
    private let database: Database
    private let retention: RetentionPolicy
    private let calendar: Calendar

    /// Section 7.2. Every tier is configurable, and history can be switched off.
    public struct RetentionPolicy: Sendable, Equatable {
        public var rawSampleHours: Int
        public var minuteBucketDays: Int
        public var quarterHourBucketDays: Int
        public var insightDays: Int
        public var identityDaysAfterLastSeen: Int

        public static let `default` = RetentionPolicy(
            rawSampleHours: 2,
            minuteBucketDays: 7,
            quarterHourBucketDays: 90,
            insightDays: 90,
            identityDaysAfterLastSeen: 30
        )

        public init(
            rawSampleHours: Int, minuteBucketDays: Int, quarterHourBucketDays: Int,
            insightDays: Int, identityDaysAfterLastSeen: Int
        ) {
            self.rawSampleHours = rawSampleHours
            self.minuteBucketDays = minuteBucketDays
            self.quarterHourBucketDays = quarterHourBucketDays
            self.insightDays = insightDays
            self.identityDaysAfterLastSeen = identityDaysAfterLastSeen
        }
    }

    /// Where the database lives. Application Support, not a shared or synced location.
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("PowerTask", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("history.sqlite")
    }

    public init(url: URL, retention: RetentionPolicy = .default) throws {
        self.database = try Database(path: url.path)
        self.retention = retention
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        self.calendar = calendar
        try Migrations.apply(to: database)
    }

    // MARK: - Writing

    /// Records one sampler cycle. Section 7.2: writes are batched inside a short
    /// transaction, and this is called from a background context, never the main actor.
    ///
    /// `wallClock` is the timestamp the row is filed under. Monotonic time drives the
    /// deltas (Section 3.2); wall clock only says when the interval happened.
    public func record(_ snapshot: SamplerSnapshot, at wallClock: Date = Date()) throws {
        // Section 3.2 / 7.3: the first sample after a session boundary has no valid
        // interval behind it, so there is nothing truthful to persist yet.
        guard !snapshot.isFirstSample else { return }

        let timestamp = Int64(wallClock.timeIntervalSince1970)
        let minute = timestamp - (timestamp % 60)
        let quarterHour = timestamp - (timestamp % 900)
        let session = snapshot.sessionID.rawValue.uuidString

        try database.transaction {
            let upsertGroup = try database.prepare("""
                INSERT INTO app_group (id, display_name, bundle_id, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen,
                                              display_name = excluded.display_name
                """)
            let insertBucket = try database.prepare("""
                INSERT INTO bucket (app_group_id, bucket_start, granularity, session_id,
                                    energy_nj_sum, cpu_percent_sum, cpu_percent_max,
                                    memory_bytes_avg, memory_bytes_max,
                                    disk_bytes_sum, sample_count, coverage_confidence)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?)
                ON CONFLICT(app_group_id, bucket_start, granularity) DO UPDATE SET
                    energy_nj_sum    = energy_nj_sum + excluded.energy_nj_sum,
                    cpu_percent_sum  = cpu_percent_sum + excluded.cpu_percent_sum,
                    cpu_percent_max  = MAX(cpu_percent_max, excluded.cpu_percent_max),
                    memory_bytes_avg = (memory_bytes_avg * sample_count + excluded.memory_bytes_avg)
                                       / (sample_count + 1),
                    memory_bytes_max = MAX(memory_bytes_max, excluded.memory_bytes_max),
                    disk_bytes_sum   = disk_bytes_sum + excluded.disk_bytes_sum,
                    sample_count     = sample_count + 1
                """)

            for group in snapshot.groups {
                let id = group.id.storageKey
                try upsertGroup
                    .bind(1, id).bind(2, group.displayName)
                    .bind(3, group.id.bundleIdentifier)
                    .bind(4, timestamp).bind(5, timestamp)
                    .run()

                let energy = Int64(group.totalEnergyDeltaNJ)
                let cpu = group.totalCPUPercent.value ?? 0
                let memory = Int64(group.totalFootprintBytes.value ?? 0)
                // Bytes over the interval, not a rate: summing rates across buckets
                // of different lengths would be meaningless.
                let interval = group.members.first?.intervalSeconds ?? 0
                let disk = group.totalDiskBytesPerSecond.value.map { Int64($0 * interval) } ?? 0
                // Section 3: confidence travels with the value, so a bucket built from
                // partly unreadable processes can be shown as such rather than implying
                // the same certainty as a fully measured one.
                let confidence = group.totalEnergyWatts.confidence

                for (start, granularity) in [(minute, "1m"), (quarterHour, "15m")] {
                    try insertBucket
                        .bind(1, id).bind(2, start).bind(3, granularity).bind(4, session)
                        .bind(5, energy).bind(6, cpu).bind(7, cpu)
                        .bind(8, memory).bind(9, memory)
                        .bind(10, disk).bind(11, confidence)
                        .run()
                }
            }

            // Section 7.1 battery_sample. Stored per cycle so a discharge curve can be
            // drawn later; an unavailable field is stored NULL, never zero.
            let battery = snapshot.battery
            if battery.isPresent {
                // Timestamp is the primary key at one-second resolution, so a
                // diagnostic burst (Section 5.1, one second) or two cycles landing in
                // the same second must overwrite rather than abort the transaction and
                // take the bucket writes down with them.
                try database.prepare("""
                    INSERT INTO battery_sample
                        (timestamp, session_id, percentage, power_source, is_charging,
                         time_remaining_seconds, accessible_energy_nj, inaccessible_process_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(timestamp) DO UPDATE SET
                        percentage                 = excluded.percentage,
                        power_source               = excluded.power_source,
                        is_charging                = excluded.is_charging,
                        time_remaining_seconds     = excluded.time_remaining_seconds,
                        accessible_energy_nj       = excluded.accessible_energy_nj,
                        inaccessible_process_count = excluded.inaccessible_process_count
                    """)
                    .bind(1, timestamp).bind(2, session)
                    .bind(3, battery.percentage.value)
                    .bind(4, battery.powerSource == .wallPower ? "ac" : "battery")
                    .bind(5, Int64(battery.isCharging ? 1 : 0))
                    .bind(6, battery.timeRemaining.value)
                    .bind(7, Int64(snapshot.coverage.accessibleEnergyNJ))
                    .bind(8, Int64(snapshot.coverage.inaccessibleProcessCount))
                    .run()
            }
        }
    }

    // MARK: - Reading

    /// One application's energy over a window, for the History timeline.
    public struct BucketRow: Sendable, Identifiable {
        public let id: String
        public let displayName: String
        public let start: Date
        public let energyNJ: UInt64
        public let averageCPUPercent: Double
        public let peakMemoryBytes: UInt64
        public let confidence: Double
        /// Seconds this application was actually observed, from its sample count —
        /// not the length of the window, since an app may have started partway in.
        public let observedSeconds: Double

        public var energyJoules: Double { Double(energyNJ) / 1_000_000_000 }

        /// Average power while the app was observed. Watts are the one energy unit
        /// people already read off appliances, so this is the number the UI leads
        /// with rather than a joule total that means nothing without a duration.
        public var averageWatts: Double {
            guard observedSeconds > 0 else { return 0 }
            return energyJoules / observedSeconds
        }
    }

    /// A window of history with each application's share of it. Section 3.1: the
    /// denominator is what PowerTask could measure, never the battery pack, so the
    /// share must be presented as a share of measured application energy.
    public struct EnergyBreakdown: Sendable {
        public let rows: [BucketRow]
        public let totalEnergyNJ: UInt64
        public let windowSeconds: Double

        /// This application's portion of all measured application energy.
        public func share(of row: BucketRow) -> Double {
            guard totalEnergyNJ > 0 else { return 0 }
            return Double(row.energyNJ) / Double(totalEnergyNJ)
        }
    }

    /// Total measured energy per application between two dates, biggest first.
    /// This is the query that answers "what drained my battery this afternoon".
    public func topEnergyConsumers(
        from: Date, to: Date, granularity: String = "1m", limit: Int = 20
    ) throws -> [BucketRow] {
        var rows: [BucketRow] = []
        try database.prepare("""
            SELECT b.app_group_id, g.display_name, MIN(b.bucket_start),
                   SUM(b.energy_nj_sum), AVG(b.cpu_percent_sum / b.sample_count),
                   MAX(b.memory_bytes_max), AVG(b.coverage_confidence),
                   SUM(b.sample_count)
            FROM bucket b
            JOIN app_group g ON g.id = b.app_group_id
            WHERE b.granularity = ? AND b.bucket_start >= ? AND b.bucket_start < ?
            GROUP BY b.app_group_id
            ORDER BY SUM(b.energy_nj_sum) DESC
            LIMIT ?
            """)
            .bind(1, granularity)
            .bind(2, Int64(from.timeIntervalSince1970))
            .bind(3, Int64(to.timeIntervalSince1970))
            .bind(4, Int64(limit))
            .query { row in
                // Each sample covers one collection interval; the bucket tier says
                // which. This is how long the app was actually watched.
                let sampleCount = Double(max(0, row.int(7)))
                rows.append(BucketRow(
                    id: row.string(0),
                    displayName: row.string(1),
                    start: Date(timeIntervalSince1970: TimeInterval(row.int(2))),
                    energyNJ: UInt64(max(0, row.int(3))),
                    averageCPUPercent: row.double(4),
                    peakMemoryBytes: UInt64(max(0, row.int(5))),
                    confidence: row.double(6),
                    observedSeconds: sampleCount * 2
                ))
            }
        return rows
    }

    /// Top consumers plus the total they are a share of. The total covers every
    /// application in the window, not just the ones returned, so a share is never
    /// inflated by the display limit.
    public func energyBreakdown(
        from: Date, to: Date, granularity: String = "1m", limit: Int = 12
    ) throws -> EnergyBreakdown {
        let rows = try topEnergyConsumers(from: from, to: to, granularity: granularity, limit: limit)
        var total: Int64 = 0
        try database.prepare("""
            SELECT SUM(energy_nj_sum) FROM bucket
            WHERE granularity = ? AND bucket_start >= ? AND bucket_start < ?
            """)
            .bind(1, granularity)
            .bind(2, Int64(from.timeIntervalSince1970))
            .bind(3, Int64(to.timeIntervalSince1970))
            .query { if !$0.isNull(0) { total = $0.int(0) } }

        return EnergyBreakdown(
            rows: rows,
            totalEnergyNJ: UInt64(max(0, total)),
            windowSeconds: to.timeIntervalSince(from)
        )
    }

    /// A battery reading for the History chart.
    public struct BatteryPoint: Sendable {
        public let timestamp: Date
        public let percentage: Double?
        public let onBattery: Bool
        public let isCharging: Bool
    }

    public func batteryHistory(from: Date, to: Date) throws -> [BatteryPoint] {
        var points: [BatteryPoint] = []
        try database.prepare("""
            SELECT timestamp, percentage, power_source, is_charging
            FROM battery_sample
            WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp
            """)
            .bind(1, Int64(from.timeIntervalSince1970))
            .bind(2, Int64(to.timeIntervalSince1970))
            .query { row in
                points.append(BatteryPoint(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row.int(0))),
                    percentage: row.optionalDouble(1),
                    onBattery: row.string(2) == "battery",
                    isCharging: row.int(3) == 1
                ))
            }
        return points
    }

    /// Section 7.3. A discharge run between unplug and replug — the natural unit for
    /// "what used my battery last time I was unplugged".
    public struct BatterySession: Sendable, Identifiable {
        public let id: Int
        public let start: Date
        public let end: Date
        public let startPercentage: Double
        public let endPercentage: Double
        public var percentageUsed: Double { max(0, startPercentage - endPercentage) }
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Splits battery samples into discharge runs. A run ends when the power source
    /// changes or a gap longer than `maximumGap` appears — a gap means the collector
    /// was not running, so the two sides must not be joined into one session.
    public func batterySessions(
        from: Date, to: Date, maximumGap: TimeInterval = 600
    ) throws -> [BatterySession] {
        let points = try batteryHistory(from: from, to: to)
        var sessions: [BatterySession] = []
        var current: [BatteryPoint] = []

        func flush() {
            guard let first = current.first, let last = current.last,
                  let startPercent = first.percentage, let endPercent = last.percentage,
                  last.timestamp > first.timestamp else { current = []; return }
            sessions.append(BatterySession(
                id: sessions.count, start: first.timestamp, end: last.timestamp,
                startPercentage: startPercent, endPercentage: endPercent
            ))
            current = []
        }

        for point in points {
            guard point.onBattery, !point.isCharging else { flush(); continue }
            if let previous = current.last,
               point.timestamp.timeIntervalSince(previous.timestamp) > maximumGap {
                flush()
            }
            current.append(point)
        }
        flush()
        return sessions
    }

    // MARK: - Retention

    /// Section 7.2. Called on a slow cadence, not every cycle.
    public func prune(now: Date = Date()) throws {
        let seconds = { (days: Int) in Int64(now.timeIntervalSince1970) - Int64(days) * 86_400 }
        let rawCutoff = Int64(now.timeIntervalSince1970) - Int64(retention.rawSampleHours) * 3_600

        try database.transaction {
            try database.execute("DELETE FROM raw_sample WHERE timestamp < \(rawCutoff)")
            try database.execute(
                "DELETE FROM bucket WHERE granularity = '1m' AND bucket_start < \(seconds(retention.minuteBucketDays))")
            try database.execute(
                "DELETE FROM bucket WHERE granularity = '15m' AND bucket_start < \(seconds(retention.quarterHourBucketDays))")
            try database.execute(
                "DELETE FROM battery_sample WHERE timestamp < \(seconds(retention.quarterHourBucketDays))")
            try database.execute(
                "DELETE FROM insight_event WHERE started_at < \(seconds(retention.insightDays))")
            // Section 7.2: identities outlive their samples so old history keeps its
            // labels, but only for a bounded window after the app was last seen.
            try database.execute("""
                DELETE FROM app_group
                WHERE last_seen < \(seconds(retention.identityDaysAfterLastSeen))
                  AND id NOT IN (SELECT DISTINCT app_group_id FROM bucket)
                """)
        }
    }

    /// Section 9.1: the user can clear all history while keeping live monitoring.
    public func deleteAllHistory() throws {
        try database.transaction {
            for table in ["raw_sample", "bucket", "battery_sample", "insight_event", "app_group"] {
                try database.execute("DELETE FROM \(table)")
            }
        }
        // Reclaim the space rather than leaving it allocated: "clear my history"
        // should shrink the file, not just hide the rows.
        try database.execute("VACUUM")
    }

    public struct Statistics: Sendable {
        public let bucketRows: Int
        public let batterySamples: Int
        public let applications: Int
        public let fileSizeBytes: Int64
        public let earliest: Date?
    }

    public func statistics(url: URL) throws -> Statistics {
        func count(_ table: String) throws -> Int {
            var n = 0
            try database.prepare("SELECT COUNT(*) FROM \(table)").query { n = Int($0.int(0)) }
            return n
        }
        var earliest: Date?
        try database.prepare("SELECT MIN(bucket_start) FROM bucket").query { row in
            if !row.isNull(0) { earliest = Date(timeIntervalSince1970: TimeInterval(row.int(0))) }
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return Statistics(
            bucketRows: try count("bucket"),
            batterySamples: try count("battery_sample"),
            applications: try count("app_group"),
            fileSizeBytes: size ?? 0,
            earliest: earliest
        )
    }
}
