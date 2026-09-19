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
            quarterHourBucketDays: 30,
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
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let base = support.appendingPathComponent("Runwell", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("history.sqlite")
        adoptLegacyDatabase(from: support, to: url)
        return url
    }

    /// The app was called PowerTask before, and its history sits under that name.
    /// Recorded battery history is not reproducible — it is a record of time that has
    /// already passed — so the rename moves it rather than starting empty.
    ///
    /// Moves only when there is nothing at the destination, so a later launch can
    /// never overwrite newer data with the stale copy left behind by an earlier one.
    private static func adoptLegacyDatabase(from support: URL, to destination: URL) {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else { return }
        let legacy = support
            .appendingPathComponent("PowerTask", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        guard manager.fileExists(atPath: legacy.path) else { return }

        // SQLite keeps its write-ahead log and shared-memory file beside the
        // database; moving the database alone can strand committed transactions.
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: legacy.path + suffix)
            guard manager.fileExists(atPath: source.path) else { continue }
            let target = URL(fileURLWithPath: destination.path + suffix)
            // A failure here is not fatal: the app continues with an empty history
            // rather than refusing to start.
            try? manager.moveItem(at: source, to: target)
        }
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
        let session = snapshot.sessionID.rawValue.uuidString
        // How much of the machine this sample could see — see EnergyCoverage.
        let coverageConfidence = snapshot.coverage.coverageConfidence

        try database.transaction {
            let upsertGroup = try database.prepare("""
                INSERT INTO app_group (id, display_name, bundle_id, first_seen, last_seen,
                                       storage_key)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen,
                                              display_name = excluded.display_name,
                                              storage_key = excluded.storage_key
                """)
            // Section 3 / Appendix F: each metric's sum and max/avg only ever
            // advance on a sample that actually carried that value — an
            // unavailable reading contributes nothing, not a zero, to any of
            // these. `energy_sample_count` etc. record how many samples a metric's
            // average is genuinely computed over, which need not equal
            // `sample_count` when one signal drops out while others keep reading.
            // A metric's own count reaching zero is what lets the read path say
            // "unavailable" rather than reporting a confident average of nothing.
            let insertBucket = try database.prepare("""
                INSERT INTO bucket (app_group_id, bucket_start, granularity, session_id,
                                    energy_nj_sum, cpu_percent_sum, cpu_percent_max,
                                    memory_bytes_avg, memory_bytes_max,
                                    disk_bytes_sum, sample_count, coverage_confidence,
                                    interval_seconds_sum,
                                    energy_sample_count, cpu_sample_count,
                                    memory_sample_count, disk_sample_count)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(app_group_id, bucket_start, granularity) DO UPDATE SET
                    energy_nj_sum    = CASE WHEN ?13 THEN energy_nj_sum + excluded.energy_nj_sum
                                             ELSE energy_nj_sum END,
                    energy_sample_count = energy_sample_count + excluded.energy_sample_count,
                    cpu_percent_sum  = CASE WHEN ?14 THEN cpu_percent_sum + excluded.cpu_percent_sum
                                             ELSE cpu_percent_sum END,
                    cpu_percent_max  = CASE WHEN ?14 THEN MAX(cpu_percent_max, excluded.cpu_percent_max)
                                             ELSE cpu_percent_max END,
                    cpu_sample_count = cpu_sample_count + excluded.cpu_sample_count,
                    memory_bytes_avg = CASE WHEN ?15 THEN
                        (memory_bytes_avg * memory_sample_count + excluded.memory_bytes_avg)
                        / (memory_sample_count + 1)
                        ELSE memory_bytes_avg END,
                    memory_bytes_max = CASE WHEN ?15 THEN MAX(memory_bytes_max, excluded.memory_bytes_max)
                                             ELSE memory_bytes_max END,
                    memory_sample_count = memory_sample_count + excluded.memory_sample_count,
                    disk_bytes_sum   = CASE WHEN ?16 THEN disk_bytes_sum + excluded.disk_bytes_sum
                                             ELSE disk_bytes_sum END,
                    disk_sample_count = disk_sample_count + excluded.disk_sample_count,
                    sample_count     = sample_count + 1,
                    -- Seconds actually covered by a sample that carried real
                    -- energy, which is what averageWatts (energy / this) divides
                    -- by. Counting seconds from unreadable samples too — as this
                    -- used to — dilutes the average with time no energy was ever
                    -- attributed to, the same silent-zero problem as the sums
                    -- above, just showing up in the denominator instead.
                    interval_seconds_sum = CASE WHEN ?13
                        THEN interval_seconds_sum + excluded.interval_seconds_sum
                        ELSE interval_seconds_sum END
                """)

            for group in snapshot.groups {
                let id = group.id.storageID
                try upsertGroup
                    .bind(1, id).bind(2, group.displayName)
                    .bind(3, group.id.bundleIdentifier)
                    .bind(4, timestamp).bind(5, timestamp)
                    // The readable identity the digest was made from, kept once per
                    // application instead of once per history row.
                    .bind(6, group.id.storageKey)
                    .run()

                let energyMetric = group.totalEnergyDelta
                let energy = Int64(energyMetric.value ?? 0)
                let energyAvailable = energyMetric.isAvailable

                let cpuMetric = group.totalCPUPercent
                let cpu = cpuMetric.value ?? 0
                let cpuAvailable = cpuMetric.isAvailable

                let memoryMetric = group.totalFootprintBytes
                let memory = Int64(memoryMetric.value ?? 0)
                let memoryAvailable = memoryMetric.isAvailable

                // Bytes over the interval, not a rate: summing rates across buckets
                // of different lengths would be meaningless.
                let interval = group.members.first?.intervalSeconds ?? 0
                let diskMetric = group.totalDiskBytesPerSecond
                let disk = diskMetric.value.map { Int64($0 * interval) } ?? 0
                let diskAvailable = diskMetric.isAvailable

                // Section 7.2 / Appendix F: a row is omitted only when Runwell
                // positively measured this app doing no attributable work —
                // energy, CPU and disk all readable and all zero. An *unreadable*
                // metric still writes its row, because "we could not see this" is
                // information the read path must keep; only "we looked, and there
                // was nothing" is safely reconstructable from an absent row.
                //
                // Memory residency alone never earns a row. Every one of the 67,687
                // all-zero rows in a full day's real usage carried a live memory
                // figure — they are idle-but-resident daemons — and no UI reads
                // historical memory at all (BucketRow.peakMemoryBytes has no
                // consumer), so those rows cost 45% of the table to preserve a
                // number nothing displays.
                //
                // What makes this safe rather than a relocated lie: every bucket
                // read is a SUM/MAX aggregate over a window, to which a row of
                // zeros contributes exactly what no row contributes. `battery_sample`
                // is written once per cycle independently of this loop and is the
                // record of which minutes Runwell was running at all, so an absent
                // row inside a covered minute means idle, and outside one means the
                // app was not sampling. Verified against a day of real data: total
                // attributed energy is identical with and without these rows.
                let measuredIdle = energyAvailable && cpuAvailable && diskAvailable
                    && energy == 0 && cpu == 0 && disk == 0
                if measuredIdle { continue }

                // Section 3: confidence travels with the value, so a bucket built from
                // partly unreadable processes can be shown as such rather than implying
                // the same certainty as a fully measured one.
                //
                // This is the snapshot's real coverage, not the per-metric constant
                // that used to land here. `totalEnergyWatts.confidence` traces back to
                // a literal 0.85 in MetricEngine, so every row ever written stored
                // exactly 0.85 — a column whose stated purpose is to vary with how
                // much of the machine was readable, that never varied. Coverage is
                // a property of the sample as a whole, so it comes from the sample.
                let confidence = energyAvailable ? coverageConfidence : 0

                // Only the 1m tier is written live. The 15m tier is derived from it
                // by `rollUpQuarterHours()` on the retention pass: writing both here
                // doubled every row touch, and the 15m tier is retained 13x longer
                // than the 1m tier, so it dominated long-run size. Rolling up means
                // a quarter-hour costs one row per active app instead of fifteen.
                let start = minute
                let granularity = "1m"
                do {
                    try insertBucket
                        .bind(1, id).bind(2, start).bind(3, granularity).bind(4, session)
                        .bind(5, energyAvailable ? energy : 0)
                        .bind(6, cpuAvailable ? cpu : 0)
                        .bind(7, cpuAvailable ? cpu : 0)
                        .bind(8, memoryAvailable ? memory : 0)
                        .bind(9, memoryAvailable ? memory : 0)
                        .bind(10, diskAvailable ? disk : 0)
                        .bind(11, confidence)
                        // Only counts toward observed duration when energy was
                        // actually attributed to it — see the write below.
                        .bind(12, energyAvailable ? interval : 0)
                        .bind(13, energyAvailable ? Int64(1) : Int64(0))
                        .bind(14, cpuAvailable ? Int64(1) : Int64(0))
                        .bind(15, memoryAvailable ? Int64(1) : Int64(0))
                        .bind(16, diskAvailable ? Int64(1) : Int64(0))
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
        /// Section 3 / Appendix F: nil means Runwell could never read this app's
        /// energy over the whole window, not that it used none. Previously an
        /// unreadable process was summed as 0 J and reported as a confident,
        /// silently wrong average of 0 W.
        public let energyNJ: UInt64?
        public let averageCPUPercent: Double?
        public let peakMemoryBytes: UInt64?
        public let confidence: Double
        /// The application's bundle identifier, when it had one. Section 7.1 keeps
        /// paths out of the database, so this is what a caller resolves an icon
        /// from — it is an identifier, not a location.
        public let bundleID: String?
        /// Seconds this application was actually observed, from its sample count —
        /// not the length of the window, since an app may have started partway in.
        public let observedSeconds: Double

        public var energyJoules: Double? { energyNJ.map { Double($0) / 1_000_000_000 } }

        /// Average power while the app was observed. Watts are the one energy unit
        /// people already read off appliances, so this is the number the UI leads
        /// with rather than a joule total that means nothing without a duration.
        /// Nil, not 0, when energy was never readable across the window — a caller
        /// must not print an em dash's worth of information as a real number.
        public var averageWatts: Double? {
            guard let energyJoules, observedSeconds > 0 else { return nil }
            return energyJoules / observedSeconds
        }
    }

    /// A window of history with each application's share of it. Section 3.1: the
    /// denominator is what Runwell could measure, never the battery pack, so the
    /// share must be presented as a share of measured application energy.
    public struct EnergyBreakdown: Sendable {
        public let rows: [BucketRow]
        public let totalEnergyNJ: UInt64
        public let windowSeconds: Double

        /// The share of the machine's processes these rows were measured from, or nil
        /// when nothing in the window carried a coverage figure.
        ///
        /// Section 3.1: application energy does not cover total discharge, and the
        /// gap is not small. `ri_energy_nj` is only readable for processes the user
        /// owns, so `kernel_task`, `WindowServer` and the other root-owned daemons —
        /// which dominate real draw — are invisible. Measured against physical
        /// battery discharge over a full day, these totals accounted for roughly an
        /// eighth of the energy the machine actually used. That gap is permanent and
        /// cannot be closed without privileges Runwell does not have, so it is
        /// disclosed rather than hidden: Appendix F forbids presenting a partial
        /// total as if it were the whole.
        public let coverage: Double?

        /// True when enough of the machine was unreadable that these totals should
        /// not be read as the machine's full energy use.
        public var isPartial: Bool { (coverage ?? 1) < 0.95 }

        /// This application's portion of all measured application energy. An
        /// app whose own energy was never readable across the window has no
        /// share to report — 0 here means "excluded from the total", the same
        /// way an app that used no measurable energy would read, which is the
        /// correct visual (no bar) even though the underlying reason differs.
        public func share(of row: BucketRow) -> Double {
            guard totalEnergyNJ > 0, let energyNJ = row.energyNJ else { return 0 }
            return Double(energyNJ) / Double(totalEnergyNJ)
        }
    }

    // MARK: - Insights

    /// Records a raised insight, and closes it when the condition lapses.
    ///
    /// Section 7.1's `insight_event` table has existed since the first migration but
    /// nothing wrote to it, so every condition the app detected vanished the moment
    /// it scrolled off screen. Duration is what makes an insight worth keeping: an
    /// app drawing 18 W for four hours is a different story from one doing it for
    /// twenty seconds, and live readings cannot tell them apart.
    public func recordInsightsRaised(_ insights: [Insight], at wallClock: Date = Date()) throws {
        guard !insights.isEmpty else { return }
        try database.transaction {
            for insight in insights {
                // The app_group row may not exist yet if this is the first cycle the
                // app appeared in; the foreign key requires it.
                try database.prepare("""
                    INSERT INTO app_group (id, display_name, bundle_id, first_seen, last_seen)
                    VALUES (?, ?, NULL, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET last_seen = excluded.last_seen
                    """)
                    .bind(1, insight.appGroupID.storageID)
                    .bind(2, insight.appName)
                    .bind(3, Int64(insight.startedAt.timeIntervalSince1970))
                    .bind(4, Int64(wallClock.timeIntervalSince1970))
                    .run()

                // One open row per rule per app: re-raising a condition that is
                // already open would double-count the same episode.
                try database.prepare("""
                    INSERT INTO insight_event
                        (app_group_id, type, started_at, ended_at, severity, evidence_json)
                    SELECT ?, ?, ?, NULL, ?, ?
                    WHERE NOT EXISTS (
                        SELECT 1 FROM insight_event
                        WHERE app_group_id = ? AND type = ? AND ended_at IS NULL
                    )
                    """)
                    .bind(1, insight.appGroupID.storageID)
                    .bind(2, insight.rule.rawValue)
                    .bind(3, Int64(insight.startedAt.timeIntervalSince1970))
                    .bind(4, insight.severity.rawValue)
                    .bind(5, insight.evidence)
                    .bind(6, insight.appGroupID.storageID)
                    .bind(7, insight.rule.rawValue)
                    .run()
            }
        }
    }

    /// Closes any open episode that is no longer live, so a stored insight has an
    /// end as well as a beginning.
    public func closeInsights(stillOpen liveIDs: Set<String>, at wallClock: Date = Date()) throws {
        var rows: [(Int64, String, String)] = []
        try database.prepare("""
            SELECT id, app_group_id, type FROM insight_event WHERE ended_at IS NULL
            """).query { row in
                rows.append((row.int(0), row.string(1), row.string(2)))
            }
        let stale = rows.filter { !liveIDs.contains("\($0.2):\($0.1)") }
        guard !stale.isEmpty else { return }
        try database.transaction {
            for (id, _, _) in stale {
                try database.prepare("UPDATE insight_event SET ended_at = ? WHERE id = ?")
                    .bind(1, Int64(wallClock.timeIntervalSince1970))
                    .bind(2, id)
                    .run()
            }
        }
    }

    /// One stored episode: a condition that held for a period, with its duration.
    public struct InsightEpisode: Sendable, Identifiable {
        public let id: Int64
        public let appName: String
        public let rule: InsightRule
        public let severity: InsightSeverity
        public let started: Date
        /// Nil while the condition is still live.
        public let ended: Date?
        public let evidence: String

        /// Measured against now while still open, so a live episode's duration grows.
        public func duration(now: Date = Date()) -> TimeInterval {
            (ended ?? now).timeIntervalSince(started)
        }
    }

    /// Episodes overlapping a window, longest first — the answer to "what has been
    /// draining my battery this week", which live readings cannot give.
    public func insightHistory(from: Date, to: Date, limit: Int = 20) throws -> [InsightEpisode] {
        var episodes: [InsightEpisode] = []
        try database.prepare("""
            SELECT e.id, g.display_name, e.type, e.severity, e.started_at, e.ended_at,
                   COALESCE(e.evidence_json, '')
            FROM insight_event e
            JOIN app_group g ON g.id = e.app_group_id
            WHERE e.started_at < ? AND (e.ended_at IS NULL OR e.ended_at >= ?)
            ORDER BY COALESCE(e.ended_at, ?) - e.started_at DESC
            LIMIT ?
            """)
            .bind(1, Int64(to.timeIntervalSince1970))
            .bind(2, Int64(from.timeIntervalSince1970))
            .bind(3, Int64(to.timeIntervalSince1970))
            .bind(4, Int64(limit))
            .query { row in
                guard let rule = InsightRule(rawValue: row.string(2)),
                      let severity = InsightSeverity(rawValue: row.string(3)) else { return }
                let endedAt = row.int(5)
                episodes.append(InsightEpisode(
                    id: row.int(0),
                    appName: row.string(1),
                    rule: rule,
                    severity: severity,
                    started: Date(timeIntervalSince1970: TimeInterval(row.int(4))),
                    ended: endedAt > 0 ? Date(timeIntervalSince1970: TimeInterval(endedAt)) : nil,
                    evidence: row.string(6)
                ))
            }
        return episodes
    }

    /// Total measured energy per application between two dates, biggest first.
    /// This is the query that answers "what drained my battery this afternoon".
    public func topEnergyConsumers(
        from: Date, to: Date, granularity: String = "1m", limit: Int = 20
    ) throws -> [BucketRow] {
        var rows: [BucketRow] = []
        try database.prepare("""
            SELECT b.app_group_id, g.display_name, MIN(b.bucket_start),
                   -- NULL, not a summed zero, when nothing in this window ever had
                   -- a readable value for the metric — SUM(energy_sample_count) = 0
                   -- means every contributing sample for this app was unreadable,
                   -- and energy_nj_sum itself is 0 in every one of those rows too,
                   -- so there is nothing to distinguish without the count.
                   CASE WHEN SUM(b.energy_sample_count) > 0 THEN SUM(b.energy_nj_sum) END,
                   -- A weighted average across buckets, not an average of averages:
                   -- summing the numerator and denominator separately means a bucket
                   -- built from more samples counts for more, matching what actually
                   -- happened rather than treating a 1-sample bucket and a
                   -- 400-sample bucket as equally representative.
                   CASE WHEN SUM(b.cpu_sample_count) > 0
                        THEN SUM(b.cpu_percent_sum) / SUM(b.cpu_sample_count) END,
                   CASE WHEN SUM(b.memory_sample_count) > 0 THEN MAX(b.memory_bytes_max) END,
                   AVG(b.coverage_confidence),
                   SUM(b.interval_seconds_sum), g.bundle_id
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
                // The real seconds this app was observed, summed from what each
                // contributing sample actually covered. Previously this multiplied
                // the sample count by 2 — the foreground interval — regardless of
                // which sampling mode produced the samples; menu-bar (5s), battery
                // idle (10s) and Low Power Mode (15s) samples were all undercounted
                // by the same fixed factor, so average watts (energy / duration)
                // came out up to 7.5x too high for anything recorded outside the
                // foreground window.
                let observedSeconds = max(0, row.double(7))
                rows.append(BucketRow(
                    id: row.string(0),
                    displayName: row.string(1),
                    start: Date(timeIntervalSince1970: TimeInterval(row.int(2))),
                    energyNJ: row.isNull(3) ? nil : UInt64(max(0, row.int(3))),
                    averageCPUPercent: row.isNull(4) ? nil : row.double(4),
                    peakMemoryBytes: row.isNull(5) ? nil : UInt64(max(0, row.int(5))),
                    confidence: row.double(6),
                    bundleID: row.string(8),
                    observedSeconds: observedSeconds
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

        // Coverage for the window, weighted by how many samples carried each figure
        // so a brief unreadable spell does not count the same as a long one. Only
        // rows with a readable energy sample contribute, since coverage describes
        // the energy total this accompanies.
        var coverage: Double?
        try database.prepare("""
            SELECT SUM(coverage_confidence * energy_sample_count), SUM(energy_sample_count)
            FROM bucket
            WHERE granularity = ? AND bucket_start >= ? AND bucket_start < ?
              AND energy_sample_count > 0
            """)
            .bind(1, granularity)
            .bind(2, Int64(from.timeIntervalSince1970))
            .bind(3, Int64(to.timeIntervalSince1970))
            .query { row in
                guard !row.isNull(0), !row.isNull(1) else { return }
                let samples = row.double(1)
                if samples > 0 { coverage = row.double(0) / samples }
            }

        return EnergyBreakdown(
            rows: rows,
            totalEnergyNJ: UInt64(max(0, total)),
            windowSeconds: to.timeIntervalSince(from),
            coverage: coverage
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

    /// A calendar day's battery sessions, with the day's totals.
    ///
    /// Sessions alone read badly across sleep. macOS dark-wakes every 15–20 minutes
    /// with the lid closed, and each wake is a separate run of samples with a long
    /// gap on either side, so `batterySessions` correctly reports dozens of
    /// fragments a minute or less long — a real day produced 93 such gaps in three
    /// days. A list of "On battery for 0m" rows is accurate and useless. Grouping by
    /// day restores the thing a reader actually wants: how much battery that day
    /// cost, and over how long.
    public struct BatteryDay: Sendable, Identifiable {
        public let id: Date
        /// Local midnight for the day these sessions fall in.
        public var date: Date { id }
        public let sessions: [BatterySession]

        /// Battery actually used across the day's runs. Summed per session rather
        /// than taken from first and last reading, so recharges in between do not
        /// cancel out the discharge either side of them.
        public var percentageUsed: Double {
            sessions.reduce(0) { $0 + $1.percentageUsed }
        }

        /// Time the machine was on battery *and* being sampled. Appendix F: the gaps
        /// between dark-wakes were not observed, so they are not claimed as
        /// measured time — this is why it is named `observed` and not `duration`.
        public var observedDuration: TimeInterval {
            sessions.reduce(0) { $0 + $1.duration }
        }

        /// Wall-clock span from the first run's start to the last run's end.
        public var span: TimeInterval {
            guard let first = sessions.first, let last = sessions.last else { return 0 }
            return last.end.timeIntervalSince(first.start)
        }

        /// True when the day's runs are mostly gap — a lid-closed day, where the
        /// span is real but the observed time behind it is small.
        public var isFragmented: Bool {
            sessions.count > 2 && observedDuration < span * 0.5
        }

        /// Discharge rate over observed time. Nil when too little was observed for
        /// an extrapolation to mean anything, rather than dividing by a few seconds
        /// and reporting a confident absurdity.
        public var percentagePerHour: Double? {
            guard observedDuration >= 600, percentageUsed > 0 else { return nil }
            return percentageUsed / (observedDuration / 3600)
        }
    }

    /// Groups discharge runs by the calendar day they start in.
    public func batteryDays(
        from: Date, to: Date, maximumGap: TimeInterval = 600
    ) throws -> [BatteryDay] {
        let sessions = try batterySessions(from: from, to: to, maximumGap: maximumGap)
        // Uses the store's UTC calendar only for bucketing keys elsewhere; days are a
        // user-facing concept, so this one is deliberately the local calendar.
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let grouped = Dictionary(grouping: sessions) { local.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { day in
            BatteryDay(id: day, sessions: grouped[day]!.sorted { $0.start < $1.start })
        }
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
    /// Builds the 15m tier from completed 1m buckets.
    ///
    /// Runs on the retention pass rather than on every sample: the tiers used to be
    /// written together on each cycle, which doubled write volume and, because the
    /// 15m tier outlives the 1m tier by 13x, accounted for most of the long-run
    /// database size.
    ///
    /// Only quarter-hours that have fully elapsed are rolled up, so a bucket is
    /// built once from complete data instead of being rewritten as minutes arrive.
    /// The aggregation mirrors what the live upsert did column for column —
    /// including the sample-weighted memory average, which a plain AVG() would get
    /// wrong whenever the contributing minutes had different sample counts.
    ///
    /// `INSERT OR REPLACE` makes this idempotent: re-rolling a window that was
    /// already built rewrites it with the same values rather than double-counting.
    public func rollUpQuarterHours(now: Date = Date()) throws {
        let cutoff = Int64(now.timeIntervalSince1970) / 900 * 900
        try database.execute("""
            INSERT OR REPLACE INTO bucket (
                app_group_id, bucket_start, granularity, session_id,
                energy_nj_sum, cpu_percent_sum, cpu_percent_max,
                memory_bytes_avg, memory_bytes_max, disk_bytes_sum,
                sample_count, coverage_confidence, interval_seconds_sum,
                energy_sample_count, cpu_sample_count, memory_sample_count,
                disk_sample_count)
            SELECT
                app_group_id,
                bucket_start / 900 * 900,
                '15m',
                MIN(session_id),
                SUM(energy_nj_sum),
                SUM(cpu_percent_sum),
                MAX(cpu_percent_max),
                CASE WHEN SUM(memory_sample_count) > 0
                     THEN SUM(memory_bytes_avg * memory_sample_count)
                          / SUM(memory_sample_count)
                     ELSE 0 END,
                MAX(memory_bytes_max),
                SUM(disk_bytes_sum),
                SUM(sample_count),
                CASE WHEN SUM(energy_sample_count) > 0
                     THEN SUM(coverage_confidence * energy_sample_count)
                          / SUM(energy_sample_count)
                     ELSE 0 END,
                SUM(interval_seconds_sum),
                SUM(energy_sample_count),
                SUM(cpu_sample_count),
                SUM(memory_sample_count),
                SUM(disk_sample_count)
            FROM bucket
            WHERE granularity = '1m' AND bucket_start < \(cutoff)
            GROUP BY app_group_id, bucket_start / 900
            """)
    }

    public func prune(now: Date = Date()) throws {
        let seconds = { (days: Int) in Int64(now.timeIntervalSince1970) - Int64(days) * 86_400 }
        let rawCutoff = Int64(now.timeIntervalSince1970) - Int64(retention.rawSampleHours) * 3_600

        // Before anything is deleted. The 15m tier is derived from 1m rows, and this
        // method drops 1m rows past their (much shorter) retention — so rolling up
        // afterwards would silently lose every quarter-hour whose minutes had just
        // aged out, with no way to reconstruct them.
        try rollUpQuarterHours(now: now)

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

        // Deleting rows frees pages for reuse but never shrinks the file, so a
        // database that spiked once stayed large forever — only "Delete All History"
        // ever reclaimed anything. Incremental vacuum returns freed pages a bounded
        // chunk at a time, which keeps this cheap enough to run on every pass
        // instead of blocking on a full VACUUM's whole-file rewrite.
        try? database.execute("PRAGMA incremental_vacuum(256)")
    }

    /// A hard ceiling on file size, checked after retention has run.
    ///
    /// Time-based retention alone bounds nothing: it assumes a roughly constant
    /// number of applications per interval, and a day of real use recorded 698
    /// groups with 312 active per minute. If growth outruns the tiers again, the
    /// oldest 1m buckets are dropped a day at a time until the file is back under
    /// the limit — the 1m tier first because it is the largest and the shortest
    /// lived, and the 15m rollups covering that time already exist.
    ///
    /// Returns true when it had to drop anything, so the caller can surface that
    /// rather than let history silently disappear.
    @discardableResult
    public func enforceSizeLimit(_ limitBytes: Int64, now: Date = Date()) throws -> Bool {
        func fileSize() -> Int64 {
            guard let pages = try? database.pageCount(),
                  let size = try? database.pageSize() else { return 0 }
            return pages * size
        }
        guard fileSize() > limitBytes else { return false }

        var dropped = false
        // Never drop below a day of minute detail: past that the tier is not what is
        // large, and deleting it would cost the app its recent-history view for no
        // meaningful saving.
        for days in stride(from: retention.minuteBucketDays - 1, through: 1, by: -1) {
            let cutoff = Int64(now.timeIntervalSince1970) - Int64(days) * 86_400
            let before = fileSize()
            try database.execute(
                "DELETE FROM bucket WHERE granularity = '1m' AND bucket_start < \(cutoff)")
            // Only count an iteration as a loss if it actually removed rows: the
            // first pass often deletes nothing (retention has just run the same
            // cutoff), and reporting trimmed history the user still has is its own
            // kind of lie.
            if database.changes() > 0 { dropped = true }
            try? database.execute("PRAGMA incremental_vacuum(4096)")

            let after = fileSize()
            if after <= limitBytes { break }
            // If deleting a day of the largest tier freed nothing, freeing pages is
            // not working on this database and no further iteration will help — it
            // would just delete the rest of the minute history for no saving at all.
            // That is exactly what shipped: on a database with auto_vacuum = NONE
            // this loop removed 88% of recorded history and the file never moved.
            if after >= before { break }
        }
        return dropped
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
        // `try?` on the outer expression already collapses "file missing" and
        // "attribute unreadable" to nil; the previous `size ?? 0` on an
        // already-non-optional Int64 was dead code that hid the double-optional
        // chain rather than resolving it.
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64)
            .flatMap { $0 } ?? 0
        return Statistics(
            bucketRows: try count("bucket"),
            batterySamples: try count("battery_sample"),
            applications: try count("app_group"),
            fileSizeBytes: size,
            earliest: earliest
        )
    }
}
