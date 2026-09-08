import Foundation

/// Section 7.1 data model, applied as numbered migrations so an existing database
/// upgrades in place rather than being discarded (Section 11.1 covers migration).
enum Migrations {
    /// Each entry runs once, in order, inside its own transaction.
    private static let all: [(version: Int, sql: String)] = [
        (1, """
        -- Section 7.1 app_group. The id is a redacted storage key, never a raw path.
        CREATE TABLE IF NOT EXISTS app_group (
            id            TEXT PRIMARY KEY,
            display_name  TEXT NOT NULL,
            bundle_id     TEXT,
            first_seen    INTEGER NOT NULL,
            last_seen     INTEGER NOT NULL
        );

        -- Section 7.1 sample_2s. Raw interval samples, kept for two hours so a
        -- current incident can be inspected at full resolution.
        CREATE TABLE IF NOT EXISTS raw_sample (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id     TEXT NOT NULL,
            app_group_id   TEXT NOT NULL REFERENCES app_group(id) ON DELETE CASCADE,
            pid            INTEGER NOT NULL,
            timestamp      INTEGER NOT NULL,
            cpu_percent    REAL,
            energy_nj      INTEGER,
            memory_bytes   INTEGER,
            disk_bytes     INTEGER,
            wakeups        REAL
        );
        CREATE INDEX IF NOT EXISTS raw_sample_time ON raw_sample(timestamp);

        -- Section 7.1 bucket_1m, generalised: granularity distinguishes the 1m and
        -- 15m tiers so both retention windows live in one table.
        CREATE TABLE IF NOT EXISTS bucket (
            app_group_id        TEXT NOT NULL REFERENCES app_group(id) ON DELETE CASCADE,
            bucket_start        INTEGER NOT NULL,
            granularity         TEXT NOT NULL,
            session_id          TEXT NOT NULL,
            energy_nj_sum       INTEGER NOT NULL DEFAULT 0,
            cpu_percent_sum     REAL NOT NULL DEFAULT 0,
            cpu_percent_max     REAL NOT NULL DEFAULT 0,
            memory_bytes_avg    INTEGER NOT NULL DEFAULT 0,
            memory_bytes_max    INTEGER NOT NULL DEFAULT 0,
            disk_bytes_sum      INTEGER NOT NULL DEFAULT 0,
            sample_count        INTEGER NOT NULL DEFAULT 0,
            -- Section 3: coverage travels with the aggregate, so a bucket built from
            -- partly unreadable processes is not shown as if it were complete.
            coverage_confidence REAL NOT NULL DEFAULT 0,
            PRIMARY KEY (app_group_id, bucket_start, granularity)
        );
        CREATE INDEX IF NOT EXISTS bucket_lookup ON bucket(granularity, bucket_start);

        -- Section 7.1 battery_sample. NULL means unavailable; it never means zero.
        CREATE TABLE IF NOT EXISTS battery_sample (
            timestamp                 INTEGER PRIMARY KEY,
            session_id                TEXT NOT NULL,
            percentage                REAL,
            power_source              TEXT NOT NULL,
            is_charging               INTEGER NOT NULL,
            time_remaining_seconds    REAL,
            accessible_energy_nj      INTEGER,
            inaccessible_process_count INTEGER
        );

        -- Section 7.1 insight_event, written by the Section 8.3 rule engine.
        CREATE TABLE IF NOT EXISTS insight_event (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            app_group_id  TEXT REFERENCES app_group(id) ON DELETE CASCADE,
            type          TEXT NOT NULL,
            started_at    INTEGER NOT NULL,
            ended_at      INTEGER,
            severity      TEXT NOT NULL,
            evidence_json TEXT,
            acknowledged  INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS insight_time ON insight_event(started_at);

        -- Section 7.1 capability. Local diagnostics only; Appendix F is explicit that
        -- the OS build and hardware identifier stay out of any outbound telemetry.
        CREATE TABLE IF NOT EXISTS capability (
            collector      TEXT NOT NULL,
            os_build       TEXT NOT NULL,
            hardware_model TEXT NOT NULL,
            available      INTEGER NOT NULL,
            reason         TEXT NOT NULL,
            last_validated INTEGER NOT NULL,
            PRIMARY KEY (collector, os_build, hardware_model)
        );
        """),
        (2, """
        -- Section 7.1 / 3.2: observed duration was reconstructed at read time as
        -- `sample_count * 2`, hardcoding the foreground cadence. Sampling modes run
        -- from 1 to 15 seconds depending on visibility and power state, so a bucket
        -- built from menu-bar or battery-idle samples reported a duration up to
        -- 7.5x shorter than what was actually observed — and average watts, which
        -- divides energy by that duration, came out just as far wrong. Recording
        -- the real interval on write removes the assumption entirely.
        ALTER TABLE bucket ADD COLUMN interval_seconds_sum REAL NOT NULL DEFAULT 0;

        -- Existing rows predate this column and have no way to recover their true
        -- interval, so they are backfilled with the old assumption rather than left
        -- at 0 — a 0 duration would divide-by-zero every historical average watts
        -- calculation for data recorded before this migration runs.
        UPDATE bucket SET interval_seconds_sum = sample_count * 2
        WHERE interval_seconds_sum = 0 AND sample_count > 0;
        """),
        (3, """
        -- Section 3 / Appendix F: "an unavailable reading is not a low reading."
        -- Every aggregate column here (energy, CPU, memory, disk) was written as
        -- `value ?? 0` when a process could not be read for that cycle, then
        -- averaged by dividing the sum by `sample_count` — the *total* number of
        -- contributing samples, unreadable ones included. A process unreadable
        -- half the time therefore had its true average silently cut in half
        -- rather than computed from the half that was actually measured, and a
        -- process unreadable *every* time reported a confident zero instead of
        -- an unknown value. `sample_count` alone cannot distinguish these cases,
        -- so each metric gets its own count of samples that actually contributed
        -- a real value to it.
        ALTER TABLE bucket ADD COLUMN energy_sample_count INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE bucket ADD COLUMN cpu_sample_count    INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE bucket ADD COLUMN memory_sample_count INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE bucket ADD COLUMN disk_sample_count   INTEGER NOT NULL DEFAULT 0;

        -- Existing rows predate per-metric counts and cannot recover which
        -- specific samples were readable. Assuming every sample was readable is
        -- the same behaviour these rows already had before this migration — no
        -- new average is invented, and no previously-reported number moves — so
        -- old history keeps reading exactly as it always has rather than being
        -- retroactively marked unavailable for a distinction it never recorded.
        UPDATE bucket SET
            energy_sample_count = sample_count,
            cpu_sample_count    = sample_count,
            memory_sample_count = sample_count,
            disk_sample_count   = sample_count
        WHERE energy_sample_count = 0 AND sample_count > 0;
        """),
    ]

    static func apply(to database: Database) throws {
        var version = 0
        try database.prepare("PRAGMA user_version").query { version = Int($0.int(0)) }

        for migration in all where migration.version > version {
            try database.transaction {
                try database.execute(migration.sql)
            }
            // PRAGMA user_version does not accept a bound parameter.
            try database.execute("PRAGMA user_version = \(migration.version)")
        }
    }
}
