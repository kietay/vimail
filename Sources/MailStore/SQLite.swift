import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        if let sql { return "SQLite error \(code): \(message) [\(sql.prefix(160))]" }
        return "SQLite error \(code): \(message)"
    }
}

/// A value bound to a statement parameter.
public enum SQLValue: Sendable, Hashable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public protocol SQLBindable {
    var sqlValue: SQLValue { get }
}

extension Int: SQLBindable { public var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { public var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { public var sqlValue: SQLValue { .double(self) } }
extension String: SQLBindable { public var sqlValue: SQLValue { .text(self) } }
extension Bool: SQLBindable { public var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { public var sqlValue: SQLValue { .blob(self) } }
extension SQLValue: SQLBindable { public var sqlValue: SQLValue { self } }
extension Date: SQLBindable {
    /// Dates are stored as integer milliseconds since 1970, like Gmail's `internalDate`.
    public var sqlValue: SQLValue { .int(Int64((timeIntervalSince1970 * 1000).rounded())) }
}
extension Optional: SQLBindable where Wrapped: SQLBindable {
    public var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A result row. Only valid inside the mapping closure.
public struct SQLRow {
    let statement: OpaquePointer

    public func isNull(_ index: Int32) -> Bool { sqlite3_column_type(statement, index) == SQLITE_NULL }
    public func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }
    public func int64(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
    public func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }
    public func bool(_ index: Int32) -> Bool { sqlite3_column_int64(statement, index) != 0 }

    public func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    public func optionalString(_ index: Int32) -> String? {
        isNull(index) ? nil : string(index)
    }

    public func date(_ index: Int32) -> Date {
        Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, index)) / 1000)
    }

    public func optionalDate(_ index: Int32) -> Date? {
        isNull(index) ? nil : date(index)
    }

    public func data(_ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

/// A thin wrapper over one SQLite connection. Not thread-safe: each instance is confined to one
/// serial queue by `MailStore`, hence `@unchecked Sendable`.
public final class SQLiteDatabase: @unchecked Sendable {
    let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    public init(path: String, readOnly: Bool = false) throws {
        var pointer: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_NOMUTEX
        let result = sqlite3_open_v2(path, &pointer, flags, nil)
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            if let pointer { sqlite3_close_v2(pointer) }
            throw SQLiteError(code: result, message: message, sql: nil)
        }
        handle = pointer
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        for statement in cache.values { sqlite3_finalize(statement) }
        sqlite3_close_v2(handle)
    }

    private func error(_ code: Int32, _ sql: String?) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    /// Runs one or more statements without parameters.
    public func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &message)
        if result != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(message)
            throw SQLiteError(code: result, message: text, sql: sql)
        }
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = cache[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &statement, nil)
        guard result == SQLITE_OK, let statement else { throw error(result, sql) }
        cache[sql] = statement
        return statement
    }

    private func bind(_ values: [SQLValue], to statement: OpaquePointer, sql: String) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null: result = sqlite3_bind_null(statement, index)
            case .int(let int): result = sqlite3_bind_int64(statement, index, int)
            case .double(let double): result = sqlite3_bind_double(statement, index, double)
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .blob(let data):
                result = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), SQLITE_TRANSIENT)
                }
            }
            if result != SQLITE_OK { throw error(result, sql) }
        }
    }

    /// Runs a statement that returns no rows.
    public func run(_ sql: String, _ values: [SQLBindable] = []) throws {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement) }
        try bind(values.map(\.sqlValue), to: statement, sql: sql)
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { result = sqlite3_step(statement) }
        if result != SQLITE_DONE { throw error(result, sql) }
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ values: [SQLBindable] = [], _ map: (SQLRow) throws -> T) throws -> [T] {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement) }
        try bind(values.map(\.sqlValue), to: statement, sql: sql)
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try map(SQLRow(statement: statement)))
            } else if result == SQLITE_DONE {
                break
            } else {
                throw error(result, sql)
            }
        }
        return rows
    }

    public func first<T>(_ sql: String, _ values: [SQLBindable] = [], _ map: (SQLRow) throws -> T) throws -> T? {
        try query(sql, values, map).first
    }

    public func scalar(_ sql: String, _ values: [SQLBindable] = []) throws -> Int {
        try first(sql, values) { $0.int(0) } ?? 0
    }

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` in an IMMEDIATE transaction, rolling back on error.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}
