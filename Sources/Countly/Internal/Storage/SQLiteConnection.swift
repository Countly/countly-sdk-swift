//
//  SQLiteConnection.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import SQLite3

/// An SQLite result code other than success, with the connection's message.
struct SQLiteError: Error {
    let code: Int32
    let message: String

    /// Whether the file is not a database SQLite can read.
    var isCorruption: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }
}

/// One SQLite connection, with its statements prepared once and reused.
///
/// Not safe to share between threads by itself: `RequestQueueDatabase` owns the only
/// one, and its confinement covers this too.
final class SQLiteConnection {

    /// A value bound to a statement's parameter.
    enum Value {
        case integer(Int64)
        case text(String)
    }

    /// The columns of the row a query stands on.
    struct Row {
        fileprivate let statement: OpaquePointer

        /// The integer in `column`.
        func integer(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        /// The text in `column`, `nil` for a null.
        func text(_ column: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, column) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, column))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }
    }

    /// Makes SQLite copy bound text, since a Swift string's bytes live only for the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// Opens, or creates, the database at `path` for reading and writing.
    init(path: String) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let error = Self.error(result, handle)
            sqlite3_close_v2(handle)
            throw error
        }
        self.handle = handle
        sqlite3_extended_result_codes(handle, 1)
        sqlite3_busy_timeout(handle, 1000)
    }

    deinit {
        close()
    }

    /// Finalizes every statement and closes the connection. Closing twice is harmless.
    func close() {
        for statement in statements.values {
            sqlite3_finalize(statement)
        }
        statements.removeAll()
        sqlite3_close_v2(handle)
        handle = nil
    }

    /// Runs SQL that binds nothing, ignoring any rows it returns.
    func execute(_ sql: String) throws {
        try check(sqlite3_exec(handle, sql, nil, nil, nil))
    }

    /// Runs one statement to completion with `values` bound in order.
    func run(_ sql: String, _ values: Value...) throws {
        let statement = try prepared(sql)
        defer { sqlite3_reset(statement) }
        try bind(values, to: statement)

        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error(result) }
    }

    /// Reads every row a query returns.
    func rows<Item>(_ sql: String, _ read: (Row) -> Item) throws -> [Item] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }
        guard let statement else { return [] }

        var results: [Item] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            results.append(read(Row(statement: statement)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error(result) }
        return results
    }

    /// The integer in the first column of the first row a query returns, zero when it
    /// returns none.
    func integer(_ sql: String) throws -> Int64 {
        try rows(sql) { $0.integer(0) }.first ?? 0
    }

    /// Runs `body` as one write transaction, committed when it returns and rolled
    /// back when anything in it throws.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// A statement prepared on first use and kept for the life of the connection.
    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let statement = statements[sql] {
            return statement
        }
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        guard let statement else { throw SQLiteError(code: SQLITE_MISUSE, message: "no statement in [\(sql)]") }
        statements[sql] = statement
        return statement
    }

    /// Binds `values` to the parameters of `statement`, in order.
    private func bind(_ values: [Value], to statement: OpaquePointer) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number):
                try check(sqlite3_bind_int64(statement, index, number))
            case .text(let text):
                // By length rather than as a C string, so a NUL inside the text survives.
                try check(text.utf8CString.withUnsafeBufferPointer { characters in
                    sqlite3_bind_text(statement, index, characters.baseAddress, Int32(characters.count - 1), Self.transient)
                })
            }
        }
    }

    /// Throws unless `result` is `SQLITE_OK`.
    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else { throw error(result) }
    }

    /// The error for `result`, with the connection's message.
    private func error(_ result: Int32) -> SQLiteError {
        Self.error(result, handle)
    }

    /// The error for `result`, with the message of `handle` when there is one.
    private static func error(_ result: Int32, _ handle: OpaquePointer?) -> SQLiteError {
        SQLiteError(code: result, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? String(cString: sqlite3_errstr(result)))
    }
}
