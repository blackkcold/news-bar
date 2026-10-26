import CSQLite
import Foundation

/// A bounded, versioned document in SQLite. Transactions are atomic; stale epochs
/// and out-of-order revisions can never overwrite the current privacy tombstone.
actor LocalInterestStore {
    private let fileURL: URL
    private var database: OpaquePointer?
    private var current: LocalInterestState?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.newsbar.app/Interest/interest.sqlite")
    }

    deinit { if let database { sqlite3_close(database) } }

    private func error(_ db: OpaquePointer) -> StoreError {
        let code = sqlite3_extended_errcode(db)
        return code == SQLITE_NOTADB || code == SQLITE_CORRUPT ? .notADatabase : .operationFailed
    }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        let opened = sqlite3_open(fileURL.path, &db)
        guard opened == SQLITE_OK, let db else {
            let code = db.map { sqlite3_extended_errcode($0) } ?? opened
            if let db { sqlite3_close(db) }
            throw code == SQLITE_NOTADB || code == SQLITE_CORRUPT ? StoreError.notADatabase : StoreError.operationFailed
        }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS interest_state (id INTEGER PRIMARY KEY CHECK(id=1), schema_version INTEGER NOT NULL, payload BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            let failure = error(db)
            sqlite3_close(db)
            throw failure
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        database = db
        return db
    }

    func load() throws -> LocalInterestState {
        if let current { return current }
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT schema_version, payload FROM interest_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw error(db) }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            let state = LocalInterestState()
            current = state
            return state
        }
        guard result == SQLITE_ROW else { throw error(db) }
        guard sqlite3_column_int(statement, 0) == 1, let bytes = sqlite3_column_blob(statement, 1) else {
            throw StoreError.unsupportedOrCorrupt
        }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        let state: LocalInterestState
        do {
            state = try JSONDecoder().decode(LocalInterestState.self, from: data)
        } catch {
            throw StoreError.unsupportedOrCorrupt
        }
        guard state.schemaVersion == 1 else { throw StoreError.unsupportedOrCorrupt }
        current = state
        return state
    }

    func save(_ state: LocalInterestState) throws {
        let previous = try load()
        guard state.consentEpoch == previous.consentEpoch, state.revision >= previous.revision else { return }
        try write(state)
    }

    func reset(_ state: LocalInterestState) throws {
        let previous = try load()
        guard state.revision > previous.revision else { return }
        try write(state)
    }

    /// Application-owned recovery for damaged or unknown-schema documents.
    /// Unlike `reset`, this does not need to decode the old payload first, so an
    /// explicit clear can still succeed.
    ///
    /// Only a confirmed SQLITE_NOTADB/SQLITE_CORRUPT file is deleted and
    /// recreated. An ordinary I/O/lock/permission failure is rethrown untouched,
    /// so a transient write error can never destroy the existing library.
    func recover(_ state: LocalInterestState) throws {
        do {
            try write(state)
        } catch StoreError.notADatabase {
            if let database { sqlite3_close(database) }
            database = nil
            current = nil
            try FileManager.default.removeItem(at: fileURL)
            try write(state)
        }
    }

    private func write(_ state: LocalInterestState) throws {
        let db = try open()
        let data = try JSONEncoder().encode(state)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw error(db) }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO interest_state(id,schema_version,payload) VALUES(1,1,?)", -1, &statement, nil) == SQLITE_OK else { throw error(db) }
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { bytes -> Int32 in
            guard sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { return SQLITE_MISUSE }
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error(db) }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw error(db) }
        committed = true
        current = state
    }

    enum StoreError: Error {
        case operationFailed
        /// Valid SQLite file whose payload/schema cannot be decoded.
        case unsupportedOrCorrupt
        /// Confirmed SQLITE_NOTADB / SQLITE_CORRUPT: only this is deletable.
        case notADatabase
    }
}
