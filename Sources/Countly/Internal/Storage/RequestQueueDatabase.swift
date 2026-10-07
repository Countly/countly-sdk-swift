//
//  RequestQueueDatabase.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import SQLite3

/// One queued request and its place in the queue.
struct QueuedRequest: Codable {

    /// Only ever grows, so sorting by it is the queue order. Also the request's row
    /// in the database.
    let sequence: Int64
    var request: String
}

/// The queue as `RequestQueueDatabase.attach(skippingPendingFile:)` decided it.
struct LoadedQueue {

    /// The queue, oldest first.
    let queue: [QueuedRequest]

    /// The first sequence that neither a row nor a request in `queue` uses.
    let nextSequence: Int64

    /// The lineage token of the database `queue` was read from, `nil` for a database
    /// that has not committed a queue yet.
    let lineage: String?

    /// The highest sequence the next load finds without the pending file.
    let durableMaxSequence: Int64

    /// The token of a pending file whose requests `queue` holds, which the next sync
    /// commits.
    let pendingFileToken: String?
}

/// The request queue on disk.
///
/// One SQLite database per instance, `CountlyRequests.sqlite` in the storage
/// directory, named per instance like every other file, with the `-wal` and `-shm`
/// files SQLite keeps next to it. Two tables:
///
/// - `requests(seq INTEGER PRIMARY KEY, body TEXT NOT NULL)`: one row per queued
///   request, in queue order.
/// - `meta(key TEXT PRIMARY KEY, value TEXT)`: the lineage token, the token of the
///   last pending file folded in, and the digest of the last `Countly.dat` merged.
///
/// The schema version is `PRAGMA user_version`. The migration file for going back to
/// countly-sdk-ios reads this schema too.
///
/// Every sync writes what changed since the last commit, by sequence, as one
/// transaction. Memory is the truth: a transaction that fails is simply made again
/// by the next sync.
///
/// **Coming from countly-sdk-ios.** `Countly.dat` is where earlier Countly SDKs keep
/// their queue. One found at load was written after the rows: on the first launch
/// after that SDK, or on one after going back to it without the migration file. Its
/// requests go after the rows, and the file is removed once they are committed. Its
/// digest is committed with them, so a file whose removal failed is not added twice.
///
/// **What is never lost.** A database that cannot be opened, a protected file on a
/// locked device for instance, is left alone for a later attach. One that is corrupt,
/// or written under a later schema, is set aside as `.corrupt` and a new one started.
/// The crash handler can interrupt this object in the middle of a transaction, so a
/// crash on the write queue's own thread writes the queue to the pending file instead,
/// which the next load folds in.
///
/// Confined to the store's write queue, apart from the first attach, which runs
/// before anything else can reach it, and `writePendingFile`, which touches nothing
/// but that file. That confinement is what makes the unchecked `Sendable` true.
final class RequestQueueDatabase: @unchecked Sendable {

    /// The files of one namespace's queue.
    struct Files {

        /// `CountlyRequests.sqlite`, with the `-wal` and `-shm` SQLite keeps next to it.
        let database: URL

        /// `Countly.dat`, where earlier Countly SDKs keep their queue.
        let legacy: URL

        /// Where the queue goes when the database cannot take it.
        let pending: URL

        /// Where a database this SDK cannot use is kept.
        let setAside: URL

        /// The files of `namespace`'s queue in `directory`.
        init(namespace: StorageNamespace, directory: URL) {
            database = directory.appendingPathComponent(namespace.fileName("CountlyRequests", extension: "sqlite"))
            legacy = directory.appendingPathComponent(namespace.fileName("Countly", extension: "dat"))
            pending = directory.appendingPathComponent(namespace.fileName("CountlyRequests", extension: "pending"))
            setAside = URL(fileURLWithPath: database.path + ".corrupt")
        }
    }

    private static let module = "RequestQueue"

    /// The version of the schema this SDK writes and reads.
    static let schemaVersion: Int64 = 1

    /// The `meta` key of the token that tells one database's history from another's.
    static let lineageKey = "lineage"

    /// The `meta` key of the token of the last pending file folded in.
    static let pendingTokenKey = "pending_token"

    /// The `meta` key of the SHA-256 of the last `Countly.dat` merged.
    static let legacyDigestKey = "legacy_digest"

    /// How many free pages an emptied queue leaves before they are given back, since
    /// giving them back costs a commit of its own.
    private static let freePageThreshold: Int64 = 256

    let files: Files

    private weak var logger: Logger?

    /// `nil` before the first attach, and after a database set aside could not be
    /// replaced by a new one yet.
    private var connection: SQLiteConnection?

    /// Whether an attach has decided what the queue is. Until then a sync would take
    /// the store's queue for all of it.
    private var isAttached = false

    /// The rows as last committed, in sequence order.
    private var committed: [QueuedRequest] = []

    /// The lineage token the rows are committed under. `nil` until a new database, or
    /// one started in place of a corrupt one, first commits: the next sync then writes
    /// every row under a new token.
    private var lineage: String?

    /// The digest of a `Countly.dat` whose requests the queue holds, until a sync
    /// commits it and the file can go.
    private var mergedLegacyDigest: String?

    /// Builds the object. Nothing is read until `attach(skippingPendingFile:)`.
    init(namespace: StorageNamespace, logger: Logger?) {
        files = Files(namespace: namespace, directory: StorageLocation.directoryURL(logger: logger))
        self.logger = logger
    }

    // MARK: - Loading

    /// Opens the database and decides what the queue is: the rows, with a pending file
    /// folded in and a `Countly.dat` merged after them.
    ///
    /// Nothing is written but the schema of a new database and the removal of files
    /// already folded in. The first sync commits whatever was decided, so a launch cut
    /// short before it decides the same again.
    ///
    /// - Parameter ownToken: The token of a pending file this process wrote itself,
    ///   whose requests the store's queue already holds. It is not folded in again.
    /// - Returns: `nil` when the database, or a `Countly.dat` that exists, cannot be read
    ///   now. Nothing is decided then, and a later attach tries again.
    func attach(skippingPendingFile ownToken: String?) -> LoadedQueue? {
        // The database first: on a locked device it is what fails, and Countly.dat need not be decoded then.
        guard let contents = openSettingAsideUnusable("attach", readContents) else { return nil }
        let legacy = readLegacyFile()
        if case .unreadable = legacy {
            logger?.d(Self.module, "attach", "the legacy file exists but cannot be read now, nothing is decided until it can, path: [\(files.legacy.lastPathComponent)]")
            return nil
        }

        connection = contents.connection
        isAttached = true
        committed = contents.rows
        lineage = contents.meta[Self.lineageKey]

        var queue = contents.rows
        let durableMaxSequence = contents.rows.last?.sequence ?? 0
        var nextSequence = durableMaxSequence + 1
        var foldedToken: String?

        switch readPendingFile() {
        case .found(let pending) where pending.token == ownToken:
            foldedToken = pending.token
        case .found(let pending) where pending.token == contents.meta[Self.pendingTokenKey]:
            removeItem(files.pending, "a pending file already folded in")
        case .found(let pending):
            // Written from the queue these rows were committed from, so it is newer than all of them.
            let replacesTheRows = lineage != nil && pending.lineage == lineage
            if replacesTheRows {
                queue = pending.queue
            } else {
                let unsaved = pending.queue.filter { $0.sequence > pending.durableMaxSequence }
                for request in Self.requests(of: unsaved.map(\.request), notIn: queue) {
                    queue.append(QueuedRequest(sequence: nextSequence, request: request))
                    nextSequence += 1
                }
            }
            nextSequence = max(nextSequence, (queue.last?.sequence ?? 0) + 1)
            foldedToken = pending.token
            logger?.d(Self.module, "attach", "the pending file is folded into the queue, pendingRequestCount: [\(pending.queue.count)], replacesTheRows: [\(replacesTheRows)], queuedRequestCount: [\(queue.count)]")
        case .absent:
            removeItem(files.pending, "a pending file that does not decode")
        case .unreadable:
            break
        }

        switch legacy {
        case .found(let file) where file.digest == contents.meta[Self.legacyDigestKey]:
            removeItem(files.legacy, "a legacy file whose requests are already in the database")
        case .found(let file):
            let added = Self.requests(of: file.requests, notIn: queue)
            for request in added {
                queue.append(QueuedRequest(sequence: nextSequence, request: request))
                nextSequence += 1
            }
            mergedLegacyDigest = file.digest
            logger?.d(Self.module, "attach", "the queue in the legacy file is added after the database's, legacyRequestCount: [\(file.requests.count)], addedRequestCount: [\(added.count)], queuedRequestCount: [\(queue.count)]")
        case .absent:
            removeItem(files.legacy, "a legacy file that holds no queue")
        case .unreadable:
            break
        }

        logger?.d(Self.module, "attach", "the queue is loaded, restoredRequestCount: [\(queue.count)], databaseRowCount: [\(contents.rows.count)]")
        return LoadedQueue(queue: queue,
                           nextSequence: nextSequence,
                           lineage: lineage,
                           durableMaxSequence: durableMaxSequence,
                           pendingFileToken: foldedToken)
    }

    /// The requests of `requests` that `queue` does not hold, in their order.
    ///
    /// Counted by body rather than by sequence, since the requests come from another
    /// file with sequences of its own. A request's body carries its timestamp, so two
    /// different ones do not match.
    private static func requests(of requests: [String], notIn queue: [QueuedRequest]) -> [String] {
        var held: [String: Int] = [:]
        for entry in queue {
            held[entry.request, default: 0] += 1
        }
        var missing: [String] = []
        for request in requests {
            if let count = held[request], count > 0 {
                held[request] = count - 1
            } else {
                missing.append(request)
            }
        }
        return missing
    }

    /// What an open database holds.
    private struct Contents {
        let connection: SQLiteConnection
        let rows: [QueuedRequest]
        let meta: [String: String]
    }

    /// Opens the database and reads every row and every `meta` value.
    private func readContents() throws -> Contents {
        let connection = try openConnection()
        let rows = try connection.rows("SELECT seq, body FROM requests ORDER BY seq") {
            QueuedRequest(sequence: $0.integer(0), request: $0.text(1) ?? "")
        }
        let pairs = try connection.rows("SELECT key, value FROM meta") { ($0.text(0) ?? "", $0.text(1)) }
        var meta: [String: String] = [:]
        for (key, value) in pairs {
            meta[key] = value
        }
        return Contents(connection: connection, rows: rows, meta: meta)
    }

    /// Opens the database file, configured, with the schema in place.
    private func openConnection() throws -> SQLiteConnection {
        let connection = try SQLiteConnection(path: files.database.path)
        // Takes effect only while the database has no tables yet.
        try connection.execute("PRAGMA auto_vacuum = INCREMENTAL")
        try connection.execute("PRAGMA journal_mode = WAL")
        // FULL syncs the log at every commit. NORMAL leaves the last commits to the
        // next checkpoint, so a power loss or a kernel panic can take them back.
        try connection.execute("PRAGMA synchronous = FULL")
        // Apple's fsync leaves writes in the drive's cache, and in WAL mode only a
        // checkpoint whose sync did not land can corrupt the database.
        try connection.execute("PRAGMA checkpoint_fullfsync = ON")
        try connection.execute("PRAGMA journal_size_limit = 1048576")

        let version = try connection.integer("PRAGMA user_version")
        if version > Self.schemaVersion {
            throw SchemaError(version: version)
        }
        if version < Self.schemaVersion {
            try connection.transaction {
                try connection.execute("CREATE TABLE IF NOT EXISTS requests (seq INTEGER PRIMARY KEY, body TEXT NOT NULL)")
                try connection.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
                try connection.execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
        return connection
    }

    /// Runs `open`, and when the database turns out to be unusable, sets it aside and
    /// runs `open` once more on a new one. A database that could not be set aside is
    /// tried again by the next call.
    ///
    /// - Returns: `nil` when no database can be opened now.
    private func openSettingAsideUnusable<Opened>(_ function: String, _ open: () throws -> Opened) -> Opened? {
        do {
            return try open()
        } catch let error where Self.isUnusable(error) {
            logger?.d(Self.module, function, "the database cannot be used and is set aside, a new one is started, \(Self.describe(error))")
            guard setAsideUnusableDatabase() else { return nil }
            do {
                return try open()
            } catch {
                logger?.d(Self.module, function, "a new database could not be started yet, the queue stays in memory, \(Self.describe(error))")
                return nil
            }
        } catch {
            logger?.d(Self.module, function, "the database cannot be opened now, the queue stays in memory until a later sync opens it, \(Self.describe(error))")
            return nil
        }
    }

    /// A database written under a schema later than this SDK knows.
    private struct SchemaError: Error {
        let version: Int64
    }

    /// Whether an error means the file is no database this SDK can use, which no
    /// later attempt changes.
    private static func isUnusable(_ error: Error) -> Bool {
        if error is SchemaError { return true }
        return (error as? SQLiteError)?.isCorruption ?? false
    }

    // MARK: - Syncing

    /// Brings the rows in line with `queue`, the store's whole queue as it is now, in
    /// one transaction.
    ///
    /// - Parameter pendingToken: The token of a pending file whose requests `queue`
    ///   holds. Committed with the rows, so the next load does not fold it in again.
    /// - Returns: The lineage token the rows are committed under, or `nil` when nothing
    ///   could be committed, which the next sync makes up for.
    func sync(_ queue: [QueuedRequest], pendingToken: String?) -> String? {
        guard isAttached else { return nil }

        if connection == nil {
            guard let reopened = openSettingAsideUnusable("sync", openConnection) else { return nil }
            connection = reopened
        }

        let legacyDigest = mergedLegacyDigest
        let result = lineage == nil
            ? commitWholeQueue(queue, pendingToken, legacyDigest, isRetry: false)
            : commitChanges(queue, pendingToken, legacyDigest)
        guard result != nil else { return nil }

        if pendingToken != nil {
            removeItem(files.pending, "a pending file whose requests are committed")
        }
        if legacyDigest != nil {
            mergedLegacyDigest = nil
            removeItem(files.legacy, "a legacy file whose requests are committed")
        }
        return result
    }

    /// Writes the difference between the committed rows and `queue`.
    private func commitChanges(_ queue: [QueuedRequest], _ pendingToken: String?, _ legacyDigest: String?) -> String? {
        guard let connection, let lineage else { return nil }

        let changes = Self.changes(from: committed, to: queue)
        let changesRows = !changes.removed.isEmpty || !changes.written.isEmpty
        guard changesRows || pendingToken != nil || legacyDigest != nil else { return lineage }

        do {
            try connection.transaction {
                if queue.isEmpty {
                    try connection.run("DELETE FROM requests")
                } else {
                    for sequence in changes.removed {
                        try connection.run("DELETE FROM requests WHERE seq = ?", .integer(sequence))
                    }
                }
                for entry in changes.written {
                    try Self.insert(entry, into: connection)
                }
                try Self.setMeta(pendingToken: pendingToken, legacyDigest: legacyDigest, in: connection)
            }
        } catch {
            return recover(from: error, queue, pendingToken, legacyDigest, isRetry: false)
        }

        committed = queue
        if queue.isEmpty, !changes.removed.isEmpty {
            releaseFreePages(connection)
        }
        logger?.d(Self.module, "sync", "the queue's changes are committed, removedCount: [\(changes.removed.count)], writtenCount: [\(changes.written.count)], requestCount: [\(queue.count)]")
        return lineage
    }

    /// Replaces every row with `queue` under a new lineage token.
    private func commitWholeQueue(_ queue: [QueuedRequest], _ pendingToken: String?, _ legacyDigest: String?, isRetry: Bool) -> String? {
        guard let connection else { return nil }

        let token = UUID().uuidString
        do {
            try connection.transaction {
                try connection.run("DELETE FROM requests")
                for entry in queue {
                    try Self.insert(entry, into: connection)
                }
                try Self.setMeta(Self.lineageKey, token, in: connection)
                try Self.setMeta(pendingToken: pendingToken, legacyDigest: legacyDigest, in: connection)
            }
        } catch {
            return recover(from: error, queue, pendingToken, legacyDigest, isRetry: isRetry)
        }

        committed = queue
        lineage = token
        logger?.d(Self.module, "sync", "the whole queue is committed under a new lineage, requestCount: [\(queue.count)]")
        return token
    }

    /// Handles a transaction that failed. A database that turns out corrupt is set
    /// aside and the whole queue written into a new one; anything else is left for
    /// the next sync.
    private func recover(from error: Error, _ queue: [QueuedRequest], _ pendingToken: String?, _ legacyDigest: String?, isRetry: Bool) -> String? {
        guard Self.isUnusable(error), !isRetry else {
            logger?.d(Self.module, "sync", "the transaction failed and is made again by the next sync, requestCount: [\(queue.count)], \(Self.describe(error))")
            return nil
        }

        logger?.d(Self.module, "sync", "the database turned out corrupt and is set aside, the queue is written into a new one, requestCount: [\(queue.count)], \(Self.describe(error))")
        lineage = nil
        guard setAsideUnusableDatabase(), let reopened = openSettingAsideUnusable("sync", openConnection) else { return nil }
        connection = reopened
        return commitWholeQueue(queue, pendingToken, legacyDigest, isRetry: true)
    }

    /// Writes one row, replacing a row under the same sequence.
    private static func insert(_ entry: QueuedRequest, into connection: SQLiteConnection) throws {
        try connection.run("INSERT OR REPLACE INTO requests (seq, body) VALUES (?, ?)", .integer(entry.sequence), .text(entry.request))
    }

    /// Sets one `meta` value.
    private static func setMeta(_ key: String, _ value: String, in connection: SQLiteConnection) throws {
        try connection.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", .text(key), .text(value))
    }

    /// Records the pending file and the `Countly.dat` whose requests a commit holds.
    private static func setMeta(pendingToken: String?, legacyDigest: String?, in connection: SQLiteConnection) throws {
        if let pendingToken {
            try setMeta(pendingTokenKey, pendingToken, in: connection)
        }
        if let legacyDigest {
            try setMeta(legacyDigestKey, legacyDigest, in: connection)
        }
    }

    /// The sequences to delete and the rows to write for `committed` to become
    /// `queue`, walking both in sequence order.
    private static func changes(from committed: [QueuedRequest], to queue: [QueuedRequest]) -> (removed: [Int64], written: [QueuedRequest]) {
        var removed: [Int64] = []
        var written: [QueuedRequest] = []
        var old = 0
        var new = 0
        while old < committed.count || new < queue.count {
            if new == queue.count || (old < committed.count && committed[old].sequence < queue[new].sequence) {
                removed.append(committed[old].sequence)
                old += 1
            } else if old == committed.count || queue[new].sequence < committed[old].sequence {
                written.append(queue[new])
                new += 1
            } else {
                if committed[old].request != queue[new].request {
                    written.append(queue[new])
                }
                old += 1
                new += 1
            }
        }
        return (removed, written)
    }

    /// Gives the pages an emptied queue no longer uses back to the file system, once
    /// there are enough of them to be worth the commit that takes.
    private func releaseFreePages(_ connection: SQLiteConnection) {
        do {
            guard try connection.integer("PRAGMA freelist_count") > Self.freePageThreshold else { return }
            try connection.execute("PRAGMA incremental_vacuum")
        } catch {
            logger?.d(Self.module, "sync", "the free pages of the emptied queue could not be released, they are reused by later requests, \(Self.describe(error))")
        }
    }

    // MARK: - Countly.dat

    /// The queue `Countly.dat` holds, and the SHA-256 of the file.
    private struct LegacyQueue {
        let requests: [String]
        let digest: String
    }

    /// Reads `Countly.dat`. A file with no queue under the key was written by neither
    /// SDK, and nothing is taken from it.
    private func readLegacyFile() -> StoredFile<LegacyQueue> {
        read(files.legacy) { data in
            guard let root = try CountlyArchive.decodeRoot(from: data) as? [String: Any],
                  let stored = root[PersistencyKey.queuedRequests] as? [Any] else { return nil }
            return LegacyQueue(requests: stored.compactMap { $0 as? String }, digest: data.sha256Hex)
        }
    }

    // MARK: - Pending file

    /// The queue as it stood when the database could not take it, and what was known
    /// about the database then.
    private struct PendingFile: Codable {
        let token: String

        /// The lineage token the queue's rows were committed under, `nil` when the
        /// database had not committed a queue yet or could not be read.
        let lineage: String?

        /// The highest sequence that was on disk for sure. Requests after it were not
        /// committed anywhere.
        let durableMaxSequence: Int64

        let queue: [QueuedRequest]
    }

    /// Writes `queue` to the pending file: for the crash handler on the write queue's
    /// own thread, and for a database that cannot be read yet. Touches nothing but the
    /// file, and nothing this object tracks.
    ///
    /// A pending file whose requests the queue does not hold, left by a launch that
    /// could not read the database either, is kept rather than written over, and so
    /// is one that cannot be read.
    ///
    /// - Parameters:
    ///   - durableMaxSequence: The highest sequence known to be on disk.
    ///   - ownTokens: The tokens of pending files the queue holds.
    /// - Returns: The token the file carries, or `nil` when it was not written.
    func writePendingFile(_ queue: [QueuedRequest], lineage: String?, durableMaxSequence: Int64, replacing ownTokens: Set<String>) -> String? {
        switch readPendingFile() {
        case .found(let existing) where !ownTokens.contains(existing.token):
            logger?.d(Self.module, "writePendingFile", "a pending file with requests the queue does not hold is kept, and the queue is not written, requestCount: [\(queue.count)]")
            return nil
        case .unreadable:
            logger?.d(Self.module, "writePendingFile", "a pending file that cannot be read is kept, and the queue is not written, requestCount: [\(queue.count)]")
            return nil
        case .found, .absent:
            break
        }

        let file = PendingFile(token: UUID().uuidString, lineage: lineage, durableMaxSequence: durableMaxSequence, queue: queue)
        do {
            try PropertyListEncoder().encode(file).write(to: files.pending, options: .atomic)
            logger?.d(Self.module, "writePendingFile", "the queue is written to the pending file for the next launch to fold in, requestCount: [\(queue.count)]")
            return file.token
        } catch {
            logger?.d(Self.module, "writePendingFile", "the pending file could not be written, requestCount: [\(queue.count)], \(Self.describe(error))")
            return nil
        }
    }

    /// Reads the pending file. One that cannot be read now is left for a later launch.
    private func readPendingFile() -> StoredFile<PendingFile> {
        read(files.pending) { try PropertyListDecoder().decode(PendingFile.self, from: $0) }
    }

    // MARK: - Files

    /// A file this object reads, told apart as absent or of no use, present but not
    /// readable now, and read.
    private enum StoredFile<Contents> {
        case absent
        case unreadable
        case found(Contents)
    }

    /// Reads `url` and decodes it with `decode`, which answers `nil` for contents of no
    /// use to this SDK.
    private func read<Contents>(_ url: URL, _ decode: (Data) throws -> Contents?) -> StoredFile<Contents> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .absent
        }

        do {
            if let contents = try decode(data) {
                return .found(contents)
            }
            logger?.d(Self.module, "read", "a file holds nothing this SDK can use, path: [\(url.lastPathComponent)], dataSize: [\(data.count)]")
        } catch {
            logger?.d(Self.module, "read", "a file could not be decoded, path: [\(url.lastPathComponent)], dataSize: [\(data.count)], \(Self.describe(error))")
        }
        return .absent
    }

    /// Removes the database, the pending file, `Countly.dat` and a database set aside.
    func deleteEverything() {
        connection?.close()
        connection = nil
        committed.removeAll()
        lineage = nil
        mergedLegacyDigest = nil

        for url in Self.sqliteFiles(of: files.database) + Self.sqliteFiles(of: files.setAside) + [files.pending, files.legacy] {
            removeItem(url, "a file of the request queue")
        }
    }

    /// Moves a database this SDK cannot use out of the way as `.corrupt`, with its
    /// `-wal` and `-shm`, replacing one set aside before.
    ///
    /// Fails if any of the three stays where it was: a log left next to a new
    /// database would be played into it.
    private func setAsideUnusableDatabase() -> Bool {
        connection?.close()
        connection = nil

        for (source, target) in zip(Self.sqliteFiles(of: files.database), Self.sqliteFiles(of: files.setAside)) {
            removeItem(target, "a database set aside earlier")
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            do {
                try FileManager.default.moveItem(at: source, to: target)
            } catch {
                guard removeItem(source, "a database that could not be set aside") else { return false }
            }
        }
        return true
    }

    /// A database file and the `-wal` and `-shm` files SQLite keeps next to it.
    static func sqliteFiles(of database: URL) -> [URL] {
        ["", "-wal", "-shm"].map { URL(fileURLWithPath: database.path + $0) }
    }

    /// Removes a file, treating one that is already gone as removed.
    @discardableResult
    private func removeItem(_ url: URL, _ what: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            logger?.d(Self.module, "removeItem", "\(what) could not be removed, path: [\(url.lastPathComponent)], \(Self.describe(error))")
            return false
        }
    }

    /// An error in the terms the log lines use.
    private static func describe(_ error: Error) -> String {
        if let error = error as? SQLiteError {
            return "sqliteCode: [\(error.code)], error: [\(error.message)]"
        }
        if let error = error as? SchemaError {
            return "schemaVersion: [\(error.version)], knownSchemaVersion: [\(schemaVersion)]"
        }
        let failure = error as NSError
        return "errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]"
    }
}
