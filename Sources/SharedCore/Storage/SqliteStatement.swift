import Foundation

#if canImport(SQLite3)
import SQLite3
#endif

private let sqliteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1),
    to: sqlite3_destructor_type.self
)

public final class SqliteStatement {
    fileprivate var handle: OpaquePointer?
    private let db: OpaquePointer
    private var finalized = false

    public enum StepResult: Sendable {
        case row
        case done
    }

    public init(db: OpaquePointer, sql: String) throws {
        self.db = db
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TraceError.storageFailed(reason: "prepare failed (rc=\(rc)): \(msg) -- SQL: \(sql)")
        }
        self.handle = stmt
    }

    deinit {
        if !finalized, let h = handle {
            sqlite3_finalize(h)
        }
    }

    public func step() throws -> StepResult {
        let rc = sqlite3_step(handle)
        switch rc {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default:
            let msg = String(cString: sqlite3_errmsg(db))
            throw TraceError.storageFailed(reason: "step failed (rc=\(rc)): \(msg)")
        }
    }

    public func reset() throws {
        let rc = sqlite3_reset(handle)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TraceError.storageFailed(reason: "reset failed (rc=\(rc)): \(msg)")
        }
    }

    public func clearBindings() throws {
        let rc = sqlite3_clear_bindings(handle)
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TraceError.storageFailed(reason: "clear_bindings failed (rc=\(rc)): \(msg)")
        }
    }

    public func finalize() throws {
        guard !finalized, let h = handle else { return }
        let rc = sqlite3_finalize(h)
        finalized = true
        handle = nil
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TraceError.storageFailed(reason: "finalize failed (rc=\(rc)): \(msg)")
        }
    }

    public func bind(text: String, at index: Int32) throws {
        let rc = sqlite3_bind_text(handle, index, text, -1, sqliteTransient)
        try check(rc, "bind text")
    }

    public func bind(int64: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(handle, index, int64), "bind int64")
    }

    public func bind(int: Int, at index: Int32) throws {
        try bind(int64: Int64(int), at: index)
    }

    public func bind(double: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(handle, index, double), "bind double")
    }

    public func bindNull(at index: Int32) throws {
        try check(sqlite3_bind_null(handle, index), "bind null")
    }

    public func bind(optionalText: String?, at index: Int32) throws {
        if let t = optionalText { try bind(text: t, at: index) } else { try bindNull(at: index) }
    }

    public func bind(optionalInt64: Int64?, at index: Int32) throws {
        if let v = optionalInt64 { try bind(int64: v, at: index) } else { try bindNull(at: index) }
    }

    public func bind(optionalDouble: Double?, at index: Int32) throws {
        if let v = optionalDouble { try bind(double: v, at: index) } else { try bindNull(at: index) }
    }

    public func bind(blob bytes: UnsafeRawPointer?, byteCount: Int, at index: Int32) throws {
        let rc: Int32
        if let bytes, byteCount > 0 {
            rc = sqlite3_bind_blob(handle, index, bytes, Int32(byteCount), sqliteTransient)
        } else {
            rc = sqlite3_bind_zeroblob(handle, index, 0)
        }
        try check(rc, "bind blob")
    }

    public func bind(data: Data, at index: Int32) throws {
        try data.withUnsafeBytes { raw in
            try bind(blob: raw.baseAddress, byteCount: raw.count, at: index)
        }
    }

    public func columnInt64(at index: Int32) -> Int64 {
        sqlite3_column_int64(handle, index)
    }

    public func columnInt(at index: Int32) -> Int {
        Int(sqlite3_column_int64(handle, index))
    }

    public func columnDouble(at index: Int32) -> Double {
        sqlite3_column_double(handle, index)
    }

    public func columnOptionalDouble(at index: Int32) -> Double? {
        if sqlite3_column_type(handle, index) == SQLITE_NULL { return nil }
        return sqlite3_column_double(handle, index)
    }

    public func columnOptionalInt64(at index: Int32) -> Int64? {
        if sqlite3_column_type(handle, index) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(handle, index)
    }

    public func columnText(at index: Int32) -> String? {
        guard let cString = sqlite3_column_text(handle, index) else { return nil }
        if sqlite3_column_type(handle, index) == SQLITE_NULL { return nil }
        return String(cString: cString)
    }

    public func columnTextRequired(at index: Int32) -> String {
        columnText(at: index) ?? ""
    }

    public func columnBlob(at index: Int32) -> Data {
        let byteCount = Int(sqlite3_column_bytes(handle, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(handle, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private func check(_ rc: Int32, _ context: String) throws {
        guard rc == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw TraceError.storageFailed(reason: "\(context) failed (rc=\(rc)): \(msg)")
        }
    }
}
