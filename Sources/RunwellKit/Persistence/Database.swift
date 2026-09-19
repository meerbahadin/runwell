import Foundation
import SQLite3

/// A minimal SQLite wrapper. Section 2.3 chose SQLite for explicit retention and
/// batch writes; this binds the system library directly so the app carries no
/// third-party dependency (Section 9.1).
///
/// Not an actor: it is owned by HistoryStore, which is the actor that serializes
/// access. Callers outside this file never touch a statement handle.
final class Database {
    private var handle: OpaquePointer?

    /// SQLITE_TRANSIENT tells SQLite to copy a bound string rather than borrow it.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum DatabaseError: LocalizedError {
        case open(String)
        case statement(String)

        var errorDescription: String? {
            switch self {
            case .open(let m): "Could not open the history database: \(m)"
            case .statement(let m): "History database error: \(m)"
            }
        }
    }

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            throw DatabaseError.open(message)
        }
        handle = db
        // Section 7.2: WAL is considered only after power-loss and size testing, so
        // this stays on the default journal with synchronous writes until that test
        // is done. NORMAL rather than FULL keeps the write cost within the Section
        // 10.1 disk budget while still surviving an app crash.
        try execute("PRAGMA journal_mode = DELETE")
        try execute("PRAGMA synchronous = NORMAL")
        try execute("PRAGMA foreign_keys = ON")
        // Lets retention hand freed pages back to the filesystem incrementally.
        // Without this the file only ever grows: deleted rows free pages for reuse
        // inside the database but never shrink it, so a size spike is permanent
        // until the user clears everything. Set before any table exists on a new
        // database, since changing auto_vacuum later requires a full VACUUM.
        try execute("PRAGMA auto_vacuum = INCREMENTAL")
        try adoptIncrementalVacuum()
    }

    /// The pragma above is silently ignored on a database that already has tables,
    /// which is every database created before it was added. Those files reported
    /// `auto_vacuum = 0` and so never reclaimed a single page: `incremental_vacuum`
    /// is a no-op there, which in turn meant the retention size ceiling deleted
    /// history in a loop while the file size never moved. Converting needs a full
    /// VACUUM, so do it once, here, and only when the mode is actually wrong.
    private func adoptIncrementalVacuum() throws {
        var mode: Int64 = 0
        try prepare("PRAGMA auto_vacuum").query { mode = $0.int(0) }
        // 0 = NONE, 1 = FULL, 2 = INCREMENTAL. FULL also needs converting: it
        // reclaims on every commit, which is the write cost this app avoided.
        guard mode != 2 else { return }
        // VACUUM rewrites the whole file, so it cannot run inside a transaction and
        // needs free disk space roughly equal to the database. A failure here is not
        // fatal — the app works, it just keeps the old growth behaviour — so it must
        // not prevent the database from opening.
        try? execute("PRAGMA auto_vacuum = INCREMENTAL")
        try? execute("VACUUM")
    }

    /// Rows changed by the most recent statement. The size ceiling uses this to
    /// tell "deleted a day of history" apart from "matched nothing".
    func changes() -> Int {
        Int(sqlite3_changes(handle))
    }

    /// Page accounting, for the retention size ceiling.
    func pageCount() throws -> Int64 {
        var value: Int64 = 0
        try prepare("PRAGMA page_count").query { value = $0.int(0) }
        return value
    }

    func pageSize() throws -> Int64 {
        var value: Int64 = 0
        try prepare("PRAGMA page_size").query { value = $0.int(0) }
        return value
    }

    deinit { sqlite3_close_v2(handle) }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.statement(lastErrorMessage)
        }
    }

    /// Runs `body` inside a transaction, rolling back if it throws. Section 7.2:
    /// database writes are batched and wrapped in short transactions.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DatabaseError.statement(lastErrorMessage)
        }
        return Statement(stmt, database: self)
    }

    /// A prepared statement. Reset and reused across a batch rather than recompiled
    /// per row, which is where most of the write cost would otherwise go.
    final class Statement {
        private let stmt: OpaquePointer
        private unowned let database: Database

        init(_ stmt: OpaquePointer, database: Database) {
            self.stmt = stmt
            self.database = database
        }

        deinit { sqlite3_finalize(stmt) }

        @discardableResult
        func bind(_ index: Int32, _ value: Int64?) -> Statement {
            if let value { sqlite3_bind_int64(stmt, index, value) }
            else { sqlite3_bind_null(stmt, index) }
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: Double?) -> Statement {
            if let value { sqlite3_bind_double(stmt, index, value) }
            else { sqlite3_bind_null(stmt, index) }
            return self
        }

        @discardableResult
        func bind(_ index: Int32, _ value: String?) -> Statement {
            if let value { sqlite3_bind_text(stmt, index, value, -1, Database.transient) }
            else { sqlite3_bind_null(stmt, index) }
            return self
        }

        /// Runs a statement that returns no rows, then resets it for reuse.
        func run() throws {
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw DatabaseError.statement(database.lastErrorMessage)
            }
        }

        /// Steps through result rows, handing each to `body`.
        func query(_ body: (Row) -> Void) throws {
            defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW: body(Row(stmt))
                case SQLITE_DONE: return
                default: throw DatabaseError.statement(database.lastErrorMessage)
                }
            }
        }
    }

    /// One result row. Column values are read positionally.
    struct Row {
        private let stmt: OpaquePointer
        init(_ stmt: OpaquePointer) { self.stmt = stmt }

        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
        func optionalInt(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
        func string(_ i: Int32) -> String {
            sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
        }
    }
}
