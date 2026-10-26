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

    private func open() throws -> OpaquePointer {
        if let database { return database }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var db: OpaquePointer?
        guard sqlite3_open(fileURL.path, &db) == SQLITE_OK, let db else { throw StoreError.operationFailed }
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, "PRAGMA journal_mode=DELETE; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS interest_state (id INTEGER PRIMARY KEY CHECK(id=1), schema_version INTEGER NOT NULL, payload BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw StoreError.operationFailed
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        database = db
        return db
    }

    func load() throws -> LocalInterestState {
        if let current { return current }
        let db = try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT schema_version, payload FROM interest_state WHERE id=1", -1, &statement, nil) == SQLITE_OK else { throw StoreError.operationFailed }
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE {
            let state = LocalInterestState()
            current = state
            return state
        }
        guard result == SQLITE_ROW, sqlite3_column_int(statement, 0) == 1,
              let bytes = sqlite3_column_blob(statement, 1) else { throw StoreError.unsupportedOrCorrupt }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
        let state = try JSONDecoder().decode(LocalInterestState.self, from: data)
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

    private func write(_ state: LocalInterestState) throws {
        let db = try open()
        let data = try JSONEncoder().encode(state)
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw StoreError.operationFailed }
        var committed = false
        defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO interest_state(id,schema_version,payload) VALUES(1,1,?)", -1, &statement, nil) == SQLITE_OK else { throw StoreError.operationFailed }
        defer { sqlite3_finalize(statement) }
        let result = data.withUnsafeBytes { bytes -> Int32 in
            guard sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK else { return SQLITE_ERROR }
            return sqlite3_step(statement)
        }
        guard result == SQLITE_DONE, sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw StoreError.operationFailed }
        committed = true
        current = state
    }

    enum StoreError: Error { case operationFailed, unsupportedOrCorrupt }
}
