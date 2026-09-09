import Testing
import Foundation
@testable import RunwellKit

/// Migration 4 rekeys every history row from a filesystem-path primary key to a
/// fixed digest. The risk it carries is orphaning: if a rewritten `app_group.id`
/// stops matching the `bucket.app_group_id` rows that reference it, history silently
/// disappears from every read, since both readers join through that key.
@Suite("Migrations")
struct MigrationTests {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("runwell-mig-\(UUID().uuidString).sqlite")
    }

    /// Builds a database in the pre-migration-4 shape: long path keys, no
    /// `storage_key` column, `user_version` pinned to 3.
    private func makeVersion3Database(at url: URL) throws -> Database {
        let database = try Database(path: url.path)
        try database.execute("""
            CREATE TABLE app_group (
                id TEXT PRIMARY KEY, display_name TEXT NOT NULL, bundle_id TEXT,
                first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL);
            CREATE TABLE bucket (
                app_group_id TEXT NOT NULL REFERENCES app_group(id) ON DELETE CASCADE,
                bucket_start INTEGER NOT NULL, granularity TEXT NOT NULL,
                session_id TEXT NOT NULL,
                energy_nj_sum INTEGER NOT NULL DEFAULT 0,
                cpu_percent_sum REAL NOT NULL DEFAULT 0,
                cpu_percent_max REAL NOT NULL DEFAULT 0,
                memory_bytes_avg INTEGER NOT NULL DEFAULT 0,
                memory_bytes_max INTEGER NOT NULL DEFAULT 0,
                disk_bytes_sum INTEGER NOT NULL DEFAULT 0,
                sample_count INTEGER NOT NULL DEFAULT 0,
                coverage_confidence REAL NOT NULL DEFAULT 0,
                interval_seconds_sum REAL NOT NULL DEFAULT 0,
                energy_sample_count INTEGER NOT NULL DEFAULT 0,
                cpu_sample_count INTEGER NOT NULL DEFAULT 0,
                memory_sample_count INTEGER NOT NULL DEFAULT 0,
                disk_sample_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (app_group_id, bucket_start, granularity));
            CREATE TABLE raw_sample (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                app_group_id TEXT NOT NULL, pid INTEGER NOT NULL,
                timestamp INTEGER NOT NULL, cpu_percent REAL, energy_nj INTEGER,
                memory_bytes INTEGER, disk_bytes INTEGER, wakeups REAL);
            CREATE TABLE insight_event (
                id INTEGER PRIMARY KEY AUTOINCREMENT, app_group_id TEXT,
                type TEXT NOT NULL, started_at INTEGER NOT NULL, ended_at INTEGER,
                severity TEXT NOT NULL, evidence_json TEXT,
                acknowledged INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE battery_sample (
                timestamp INTEGER PRIMARY KEY, session_id TEXT NOT NULL,
                percentage REAL, power_source TEXT NOT NULL,
                is_charging INTEGER NOT NULL, time_remaining_seconds REAL,
                accessible_energy_nj INTEGER, inaccessible_process_count INTEGER);
            CREATE TABLE capability (
                collector TEXT NOT NULL, os_build TEXT NOT NULL,
                hardware_model TEXT NOT NULL, available INTEGER NOT NULL,
                reason TEXT NOT NULL, last_validated INTEGER NOT NULL,
                PRIMARY KEY (collector, os_build, hardware_model));
            PRAGMA user_version = 3;
            """)
        return database
    }

    /// The keys that motivated the migration: a deeply nested simulator runtime, a
    /// plain system daemon path, and a short bundle id, so the test covers both the
    /// pathological and the ordinary case.
    private let keys = [
        "executable:/Library/Developer/CoreSimulator/Volumes/iOS_23F77/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 26.5.simruntime/Contents/Resources/RuntimeRoot/System/Library/PrivateFrameworks/MobileAssetDaemon.framework/XPCServices/com.apple.MobileAsset.DownloadService.Builtin.xpc/com.apple.MobileAsset.DownloadService.Builtin",
        "executable:/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/HIServices.framework/Versions/A/XPCServices/com.apple.hiservices-xpcservice.xpc/Contents/MacOS/com.apple.hiservices-xpcservice",
        "bundle:com.google.Chrome",
    ]

    @Test("Migration 4 rekeys history without orphaning any row")
    func rekeyPreservesHistory() throws {
        let url = temporaryURL()
        let database = try makeVersion3Database(at: url)
        for (index, key) in keys.enumerated() {
            try database.prepare("""
                INSERT INTO app_group (id, display_name, bundle_id, first_seen, last_seen)
                VALUES (?, ?, NULL, 0, 0)
                """).bind(1, key).bind(2, "App\(index)").run()
            try database.prepare("""
                INSERT INTO bucket (app_group_id, bucket_start, granularity, session_id,
                    energy_nj_sum, sample_count, energy_sample_count, interval_seconds_sum)
                VALUES (?, 60, '1m', 's', ?, 1, 1, 2)
                """).bind(1, key).bind(2, Int64((index + 1) * 1000)).run()
        }

        try Migrations.apply(to: database)

        // Every id is now a 16-character digest, and every bucket row still resolves.
        var ids: [String] = []
        try database.prepare("SELECT id FROM app_group").query { ids.append($0.string(0)) }
        #expect(ids.allSatisfy { $0.count == 16 })
        #expect(Set(ids) == Set(keys.map { ApplicationGroupID.digest(of: $0) }))

        var orphaned = 0
        try database.prepare("""
            SELECT COUNT(*) FROM bucket b
            LEFT JOIN app_group g ON g.id = b.app_group_id WHERE g.id IS NULL
            """).query { orphaned = Int($0.int(0)) }
        #expect(orphaned == 0)

        // The readable identity survives, moved to its own column.
        var storageKeys: [String] = []
        try database.prepare("SELECT storage_key FROM app_group ORDER BY display_name")
            .query { storageKeys.append($0.string(0)) }
        #expect(Set(storageKeys) == Set(keys))

        // And the energy each app reported is unchanged.
        var totals: [String: Int64] = [:]
        try database.prepare("""
            SELECT g.display_name, SUM(b.energy_nj_sum) FROM bucket b
            JOIN app_group g ON g.id = b.app_group_id GROUP BY b.app_group_id
            """).query { totals[$0.string(0)] = $0.int(1) }
        #expect(totals == ["App0": 1000, "App1": 2000, "App2": 3000])
    }

    /// The digest must match what the write path will produce, or newly recorded
    /// samples would land on a different row than the migrated history.
    @Test("Migrated ids match what the write path generates")
    func digestMatchesWritePath() throws {
        let id = ApplicationGroupID(bundle: "com.google.Chrome")
        #expect(id.storageID == ApplicationGroupID.digest(of: id.storageKey))
        #expect(id.storageID.count == 16)
    }
}
