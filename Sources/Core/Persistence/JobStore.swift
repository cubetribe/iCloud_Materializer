import Foundation
import SQLite3

actor JobStore {
    private let databaseURL: URL
    private var db: OpaquePointer?

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            throw PipelineError.persistenceFailed("Unable to open SQLite database at \(databaseURL.path)")
        }
        try Self.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            job_id TEXT PRIMARY KEY,
            phase TEXT NOT NULL,
            phase_detail TEXT,
            source_path TEXT NOT NULL,
            destination_path TEXT NOT NULL,
            current_path TEXT,
            total_discovered INTEGER NOT NULL,
            total_downloaded INTEGER NOT NULL,
            total_copied INTEGER NOT NULL,
            total_failed INTEGER NOT NULL,
            planned_chunks INTEGER NOT NULL DEFAULT 0,
            processed_chunks INTEGER NOT NULL DEFAULT 0,
            estimated_remaining INTEGER NOT NULL,
            throughput REAL NOT NULL,
            throughput_bytes REAL NOT NULL DEFAULT 0,
            total_expected_bytes INTEGER NOT NULL DEFAULT 0,
            copied_bytes INTEGER NOT NULL DEFAULT 0,
            active_worker_count INTEGER NOT NULL DEFAULT 0,
            estimated_remaining_seconds REAL,
            started_at REAL,
            finished_at REAL,
            last_error TEXT
        );
        """, db: db)
        try Self.ensureColumns(
            in: "jobs",
            definitions: [
                "phase_detail": "TEXT",
                "planned_chunks": "INTEGER NOT NULL DEFAULT 0",
                "processed_chunks": "INTEGER NOT NULL DEFAULT 0",
                "throughput_bytes": "REAL NOT NULL DEFAULT 0",
                "total_expected_bytes": "INTEGER NOT NULL DEFAULT 0",
                "copied_bytes": "INTEGER NOT NULL DEFAULT 0",
                "active_worker_count": "INTEGER NOT NULL DEFAULT 0",
                "estimated_remaining_seconds": "REAL"
            ],
            db: db
        )
        try Self.execute("""
        CREATE TABLE IF NOT EXISTS items (
            job_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            kind TEXT NOT NULL,
            size INTEGER NOT NULL,
            hidden INTEGER NOT NULL,
            ubiquitous INTEGER NOT NULL,
            local_ready INTEGER NOT NULL,
            download_status TEXT,
            symlink_destination TEXT,
            state TEXT NOT NULL,
            last_error TEXT,
            PRIMARY KEY (job_id, relative_path)
        );
        """, db: db)
        try Self.execute("""
        CREATE TABLE IF NOT EXISTS chunks (
            job_id TEXT NOT NULL,
            chunk_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            anchor_relative_path TEXT,
            expected_bytes INTEGER NOT NULL,
            state TEXT NOT NULL,
            recovery_mode TEXT NOT NULL,
            last_error TEXT,
            relative_paths_json TEXT NOT NULL,
            PRIMARY KEY (job_id, chunk_id)
        );
        """, db: db)
        try Self.execute("""
        CREATE TABLE IF NOT EXISTS failures (
            job_id TEXT NOT NULL,
            failure_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            reason TEXT NOT NULL,
            message TEXT NOT NULL,
            recovery_mode TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (job_id, failure_id)
        );
        """, db: db)
        try Self.execute("""
        CREATE TABLE IF NOT EXISTS events (
            job_id TEXT NOT NULL,
            event_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            level TEXT NOT NULL,
            message TEXT NOT NULL,
            path TEXT,
            PRIMARY KEY (job_id, event_id)
        );
        """, db: db)
    }

    func close() throws {
        guard let db else { return }
        let result = sqlite3_close(db)
        guard result == SQLITE_OK else {
            throw PipelineError.persistenceFailed(Self.lastErrorMessage(db: db))
        }
        self.db = nil
    }

    func saveJobSnapshot(_ snapshot: JobSnapshot) throws {
        guard db != nil else {
            throw PipelineError.persistenceFailed("Database connection is closed.")
        }
        let sql = """
        INSERT OR REPLACE INTO jobs
        (job_id, phase, phase_detail, source_path, destination_path, current_path, total_discovered, total_downloaded, total_copied, total_failed, planned_chunks, processed_chunks, estimated_remaining, throughput, throughput_bytes, total_expected_bytes, copied_bytes, active_worker_count, estimated_remaining_seconds, started_at, finished_at, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let startedAt = snapshot.startedAt?.timeIntervalSince1970
        let finishedAt = snapshot.finishedAt?.timeIntervalSince1970
        try prepareAndStep(sql) { statement in
            bind(snapshot.jobID.uuidString, to: 1, in: statement)
            bind(snapshot.phase.rawValue, to: 2, in: statement)
            bind(snapshot.phaseDetail, to: 3, in: statement)
            bind(snapshot.sourcePath, to: 4, in: statement)
            bind(snapshot.destinationPath, to: 5, in: statement)
            bind(snapshot.currentPath, to: 6, in: statement)
            sqlite3_bind_int64(statement, 7, sqlite3_int64(snapshot.totalDiscovered))
            sqlite3_bind_int64(statement, 8, sqlite3_int64(snapshot.totalDownloaded))
            sqlite3_bind_int64(statement, 9, sqlite3_int64(snapshot.totalCopied))
            sqlite3_bind_int64(statement, 10, sqlite3_int64(snapshot.totalFailed))
            sqlite3_bind_int64(statement, 11, sqlite3_int64(snapshot.plannedChunks))
            sqlite3_bind_int64(statement, 12, sqlite3_int64(snapshot.processedChunks))
            sqlite3_bind_int64(statement, 13, sqlite3_int64(snapshot.estimatedRemainingCount))
            sqlite3_bind_double(statement, 14, snapshot.throughputItemsPerSecond)
            sqlite3_bind_double(statement, 15, snapshot.throughputBytesPerSecond)
            sqlite3_bind_int64(statement, 16, sqlite3_int64(snapshot.totalExpectedBytes))
            sqlite3_bind_int64(statement, 17, sqlite3_int64(snapshot.copiedBytes))
            sqlite3_bind_int64(statement, 18, sqlite3_int64(snapshot.activeWorkerCount))
            bind(snapshot.estimatedRemainingSeconds, to: 19, in: statement)
            bind(startedAt, to: 20, in: statement)
            bind(finishedAt, to: 21, in: statement)
            bind(snapshot.lastError, to: 22, in: statement)
        }
    }

    func saveItems(jobID: UUID, items: [ScannedItem]) throws {
        guard db != nil else {
            throw PipelineError.persistenceFailed("Database connection is closed.")
        }
        let sql = """
        INSERT OR REPLACE INTO items
        (job_id, relative_path, kind, size, hidden, ubiquitous, local_ready, download_status, symlink_destination, state, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try Self.execute("BEGIN TRANSACTION;", db: db)
        defer { try? Self.execute("COMMIT;", db: db) }
        for item in items {
            try prepareAndStep(sql) { statement in
                bind(jobID.uuidString, to: 1, in: statement)
                bind(item.relativePath, to: 2, in: statement)
                bind(item.kind.rawValue, to: 3, in: statement)
                sqlite3_bind_int64(statement, 4, sqlite3_int64(item.expectedSize))
                sqlite3_bind_int(statement, 5, item.isHidden ? 1 : 0)
                sqlite3_bind_int(statement, 6, item.isUbiquitous ? 1 : 0)
                sqlite3_bind_int(statement, 7, item.isLocalReady ? 1 : 0)
                bind(item.downloadStatusRaw, to: 8, in: statement)
                bind(item.symlinkDestination, to: 9, in: statement)
                bind(item.state.rawValue, to: 10, in: statement)
                bind(item.lastError, to: 11, in: statement)
            }
        }
    }

    func saveChunks(jobID: UUID, chunks: [ChunkManifest]) throws {
        guard db != nil else {
            throw PipelineError.persistenceFailed("Database connection is closed.")
        }
        let sql = """
        INSERT OR REPLACE INTO chunks
        (job_id, chunk_id, kind, anchor_relative_path, expected_bytes, state, recovery_mode, last_error, relative_paths_json)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let encoder = JSONEncoder()
        try Self.execute("BEGIN TRANSACTION;", db: db)
        defer { try? Self.execute("COMMIT;", db: db) }
        for chunk in chunks {
            let relativePathsJSON = try String(decoding: encoder.encode(chunk.relativePaths), as: UTF8.self)
            try prepareAndStep(sql) { statement in
                bind(jobID.uuidString, to: 1, in: statement)
                bind(chunk.id.uuidString, to: 2, in: statement)
                bind(chunk.kind.rawValue, to: 3, in: statement)
                bind(chunk.anchorRelativePath, to: 4, in: statement)
                sqlite3_bind_int64(statement, 5, sqlite3_int64(chunk.expectedBytes))
                bind(chunk.state.rawValue, to: 6, in: statement)
                bind(chunk.recoveryMode.rawValue, to: 7, in: statement)
                bind(chunk.lastError, to: 8, in: statement)
                bind(relativePathsJSON, to: 9, in: statement)
            }
        }
    }

    func saveFailure(jobID: UUID, failure: FailureRecord) throws {
        guard db != nil else {
            throw PipelineError.persistenceFailed("Database connection is closed.")
        }
        let sql = """
        INSERT OR REPLACE INTO failures
        (job_id, failure_id, relative_path, reason, message, recovery_mode, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try prepareAndStep(sql) { statement in
            bind(jobID.uuidString, to: 1, in: statement)
            bind(failure.id.uuidString, to: 2, in: statement)
            bind(failure.relativePath, to: 3, in: statement)
            bind(failure.reason.rawValue, to: 4, in: statement)
            bind(failure.message, to: 5, in: statement)
            bind(failure.recoveryMode.rawValue, to: 6, in: statement)
            sqlite3_bind_double(statement, 7, failure.createdAt.timeIntervalSince1970)
        }
    }

    func appendEvent(jobID: UUID, entry: LogEntry) throws {
        guard db != nil else {
            throw PipelineError.persistenceFailed("Database connection is closed.")
        }
        let sql = """
        INSERT OR REPLACE INTO events
        (job_id, event_id, created_at, level, message, path)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        try prepareAndStep(sql) { statement in
            bind(jobID.uuidString, to: 1, in: statement)
            bind(entry.id.uuidString, to: 2, in: statement)
            sqlite3_bind_double(statement, 3, entry.createdAt.timeIntervalSince1970)
            bind(entry.level.rawValue, to: 4, in: statement)
            bind(entry.message, to: 5, in: statement)
            bind(entry.path, to: 6, in: statement)
        }
    }

    func loadSnapshot(jobID: UUID) throws -> JobSnapshot? {
        guard db != nil else {
            throw PipelineError.persistenceFailed("Database connection is closed.")
        }
        let sql = """
        SELECT phase, phase_detail, source_path, destination_path, current_path, total_discovered, total_downloaded, total_copied, total_failed, planned_chunks, processed_chunks, estimated_remaining, throughput, throughput_bytes, total_expected_bytes, copied_bytes, active_worker_count, estimated_remaining_seconds, started_at, finished_at, last_error
        FROM jobs WHERE job_id = ? LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PipelineError.persistenceFailed(Self.lastErrorMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }
        bind(jobID.uuidString, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }
        let phase = JobPhase(rawValue: string(at: 0, in: statement) ?? JobPhase.idle.rawValue) ?? .idle
        return JobSnapshot(
            jobID: jobID,
            phase: phase,
            phaseDetail: string(at: 1, in: statement),
            sourcePath: string(at: 2, in: statement) ?? "",
            destinationPath: string(at: 3, in: statement) ?? "",
            currentPath: string(at: 4, in: statement),
            totalDiscovered: Int(sqlite3_column_int64(statement, 5)),
            totalDownloaded: Int(sqlite3_column_int64(statement, 6)),
            totalCopied: Int(sqlite3_column_int64(statement, 7)),
            totalFailed: Int(sqlite3_column_int64(statement, 8)),
            plannedChunks: Int(sqlite3_column_int64(statement, 9)),
            processedChunks: Int(sqlite3_column_int64(statement, 10)),
            estimatedRemainingCount: Int(sqlite3_column_int64(statement, 11)),
            throughputItemsPerSecond: sqlite3_column_double(statement, 12),
            throughputBytesPerSecond: sqlite3_column_double(statement, 13),
            totalExpectedBytes: sqlite3_column_int64(statement, 14),
            copiedBytes: sqlite3_column_int64(statement, 15),
            activeWorkerCount: Int(sqlite3_column_int64(statement, 16)),
            estimatedRemainingSeconds: double(at: 17, in: statement),
            startedAt: date(at: 18, in: statement),
            finishedAt: date(at: 19, in: statement),
            lastError: string(at: 20, in: statement)
        )
    }

    private static func execute(_ sql: String, db: OpaquePointer?) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw PipelineError.persistenceFailed(lastErrorMessage(db: db))
        }
    }

    private static func ensureColumns(
        in tableName: String,
        definitions: [String: String],
        db: OpaquePointer?
    ) throws {
        let existingColumns = try tableColumns(for: tableName, db: db)
        for (columnName, definition) in definitions where !existingColumns.contains(columnName) {
            try execute("ALTER TABLE \(tableName) ADD COLUMN \(columnName) \(definition);", db: db)
        }
    }

    private static func tableColumns(for tableName: String, db: OpaquePointer?) throws -> Set<String> {
        let sql = "PRAGMA table_info(\(tableName));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PipelineError.persistenceFailed(lastErrorMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: name))
            }
        }
        return columns
    }

    private func prepareAndStep(_ sql: String, binder: (OpaquePointer?) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw PipelineError.persistenceFailed(Self.lastErrorMessage(db: db))
        }
        defer { sqlite3_finalize(statement) }
        try binder(statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PipelineError.persistenceFailed(Self.lastErrorMessage(db: db))
        }
    }

    private func bind(_ value: String?, to index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private static func lastErrorMessage(db: OpaquePointer?) -> String {
        String(cString: sqlite3_errmsg(db))
    }

    private func string(at index: Int32, in statement: OpaquePointer?) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private func date(at index: Int32, in statement: OpaquePointer?) -> Date? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }

    private func double(at index: Int32, in statement: OpaquePointer?) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
