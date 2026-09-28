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

    /// The mirror token of the database state `queue` was read from, `nil` while a
    /// take over waits for its first commit.
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
/// - `meta(key TEXT PRIMARY KEY, value TEXT)`: the mirror token, and the token of
///   the last pending file folded in.
///
/// The schema version is `PRAGMA user_version`.
///
/// Every sync writes what changed since the last commit, by sequence, as one
/// transaction. Memory is the truth: a transaction that fails is simply made again
/// by the next sync.
///
/// **Going back to countly-sdk-ios.** For the instances that mirror it, `Countly.dat`
/// holds the queue as well, archived exactly as `CountlyPersistency` archives it plus
/// the database's mirror token, a moment after each commit and at every synchronous
/// save. That SDK saves back only its queue, so a `Countly.dat` without the
/// database's token is newer than the database, and its queue is taken over. A byte
/// digest of the file cannot stand in for the token: that SDK archives every empty
/// queue to the same bytes. A take over commits under a new token, which reaches
/// `Countly.dat` before the transaction that stores it: one cut short leaves a file
/// that no database names, and the next load takes it over again.
///
/// **What is never lost.** A database that cannot be opened, a protected file on a
/// locked device for instance, is left alone for a later attach. One that is corrupt,
/// or written under a later schema, is set aside as `.corrupt`, and a new one takes
/// over whatever `Countly.dat` holds. The crash handler can interrupt this object in
/// the middle of a transaction, so a crash on the write queue's own thread writes the
/// queue to the pending file instead, which the next load folds in.
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

    /// The `meta` key of the token the rows are committed under.
    static let mirrorTokenKey = "mirror_token"

    /// The `meta` key of the token of the last pending file folded in.
    static let pendingTokenKey = "pending_token"

    /// How long the mirror waits for further changes before it is written, so a
    /// drain of many requests rewrites it a few times rather than once each.
    private static let mirrorDelay: TimeInterval = 1

    /// How many free pages an emptied queue leaves before they are given back, since
    /// giving them back costs a commit of its own.
    private static let freePageThreshold: Int64 = 256

    let files: Files

    private let mirrorsLegacyFile: Bool
    private let writeQueue: DispatchQueue
    private weak var logger: Logger?

    /// `nil` before the first attach, and after a database set aside could not be
    /// replaced by a new one yet.
    private var connection: SQLiteConnection?

    /// Whether an attach has decided what the queue is. Until then a sync would take
    /// the store's queue for all of it.
    private var isAttached = false

    /// The rows as last committed, in sequence order.
    private var committed: [QueuedRequest] = []

    /// The mirror token the rows are committed under. `nil` until a take over, or a
    /// database set aside, is first committed: the next sync then replaces every row
    /// under a new token.
    private var lineage: String?

    /// Whether `Countly.dat` is behind the committed rows.
    private var isMirrorDirty = false
    private var isMirrorScheduled = false

    /// - Parameter mirrorsLegacyFile: Whether `Countly.dat` is kept current for the
    ///   Objective-C SDK. Only the default instance's data is where that SDK looks.
    init(namespace: StorageNamespace, mirrorsLegacyFile: Bool, writeQueue: DispatchQueue, logger: Logger?) {
        files = Files(namespace: namespace, directory: StorageLocation.directoryURL(logger: logger))
        self.mirrorsLegacyFile = mirrorsLegacyFile
        self.writeQueue = writeQueue
        self.logger = logger
    }

    // MARK: - Loading

    /// Opens the database and decides what the queue is: the rows, or the queue in
    /// `Countly.dat` when that is the newer of the two, with a pending file folded in.
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

        let storedLineage = contents.meta[Self.mirrorTokenKey]
        var queue: [QueuedRequest]
        if let requests = requestsToTakeOver(legacy, storedLineage: storedLineage) {
            queue = requests.enumerated().map { QueuedRequest(sequence: Int64($0.offset + 1), request: $0.element) }
            lineage = nil
            logger?.d(Self.module, "attach", "the queue is taken over from the legacy file, legacyRequestCount: [\(queue.count)], databaseHadAToken: [\(storedLineage != nil)], mirrorsLegacyFile: [\(mirrorsLegacyFile)]")
        } else {
            queue = contents.rows
            lineage = storedLineage
            tidyLegacyFile(legacy, rows: contents.rows)
            logger?.d(Self.module, "attach", "the queue is loaded from the database, restoredRequestCount: [\(queue.count)], mirrorIsBehind: [\(isMirrorDirty)]")
        }

        let durableMaxSequence = queue.last?.sequence ?? 0
        var nextSequence = max(durableMaxSequence, contents.rows.last?.sequence ?? 0) + 1
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
                for request in Self.requests(of: unsaved, notIn: queue) {
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

        return LoadedQueue(queue: queue,
                           nextSequence: nextSequence,
                           lineage: lineage,
                           durableMaxSequence: durableMaxSequence,
                           pendingFileToken: foldedToken)
    }

    /// The requests of `pending` that `queue` does not hold, oldest first.
    ///
    /// Counted by body rather than by sequence: a crash between a take over's write of
    /// `Countly.dat` and its commit leaves a file whose requests the next take over
    /// brings back under other sequences, and a request's body carries its
    /// timestamp, so two different ones do not match.
    private static func requests(of pending: [QueuedRequest], notIn queue: [QueuedRequest]) -> [String] {
        var held: [String: Int] = [:]
        for entry in queue {
            held[entry.request, default: 0] += 1
        }
        var missing: [String] = []
        for entry in pending {
            if let count = held[entry.request], count > 0 {
                held[entry.request] = count - 1
            } else {
                missing.append(entry.request)
            }
        }
        return missing
    }

    /// The requests to take over from `Countly.dat`, or `nil` when the rows are the
    /// newer queue.
    ///
    /// A database without a token has never committed a queue, so whatever
    /// `Countly.dat` holds is taken over, the default instance's mirror of a database
    /// set aside included. One with a token takes over only a file that does not carry
    /// it: written by the Objective-C SDK, or by a take over cut short.
    private func requestsToTakeOver(_ legacy: StoredFile<LegacyQueue>, storedLineage: String?) -> [String]? {
        switch legacy {
        case .found(let file):
            return storedLineage == nil || file.token != storedLineage ? file.requests : nil
        case .absent, .unreadable:
            return storedLineage == nil ? [] : nil
        }
    }

    /// Brings `Countly.dat` in line with rows that are the newer queue: the mirror is
    /// written again if it holds anything else, and an instance that does not mirror
    /// removes the file a take over left behind.
    private func tidyLegacyFile(_ legacy: StoredFile<LegacyQueue>, rows: [QueuedRequest]) {
        guard mirrorsLegacyFile else {
            removeItem(files.legacy, "the legacy file of a queue taken over earlier")
            return
        }
        if case .found(let file) = legacy, file.requests.elementsEqual(rows.map(\.request)) { return }
        isMirrorDirty = true
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
    /// - Returns: The mirror token the rows are committed under, or `nil` when nothing
    ///   could be committed, which the next sync makes up for.
    func sync(_ queue: [QueuedRequest], pendingToken: String?) -> String? {
        guard isAttached else { return nil }

        if connection == nil {
            guard let reopened = openSettingAsideUnusable("sync", openConnection) else { return nil }
            connection = reopened
        }

        let result = lineage == nil
            ? commitWholeQueue(queue, pendingToken, isRetry: false)
            : commitChanges(queue, pendingToken)
        if result != nil, pendingToken != nil {
            removeItem(files.pending, "a pending file whose requests are committed")
        }
        scheduleMirror()
        return result
    }

    /// Writes the difference between the committed rows and `queue`.
    private func commitChanges(_ queue: [QueuedRequest], _ pendingToken: String?) -> String? {
        guard let connection, let lineage else { return nil }

        let changes = Self.changes(from: committed, to: queue)
        let changesRows = !changes.removed.isEmpty || !changes.written.isEmpty
        guard changesRows || pendingToken != nil else { return lineage }

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
                if let pendingToken {
                    try Self.setMeta(Self.pendingTokenKey, pendingToken, in: connection)
                }
            }
        } catch {
            return recover(from: error, queue, pendingToken, isRetry: false)
        }

        committed = queue
        if changesRows, mirrorsLegacyFile {
            isMirrorDirty = true
        }
        if queue.isEmpty, !changes.removed.isEmpty {
            releaseFreePages(connection)
        }
        logger?.d(Self.module, "sync", "the queue's changes are committed, removedCount: [\(changes.removed.count)], writtenCount: [\(changes.written.count)], requestCount: [\(queue.count)]")
        return lineage
    }

    /// Replaces every row with `queue` under a new token, which `Countly.dat` gets
    /// first.
    private func commitWholeQueue(_ queue: [QueuedRequest], _ pendingToken: String?, isRetry: Bool) -> String? {
        guard let connection else { return nil }

        let token = UUID().uuidString
        guard stampLegacyFile(queue, token: token) else {
            logger?.d(Self.module, "sync", "the queue is not committed under a new token, since the legacy file could not take the token, it is tried again on the next sync, requestCount: [\(queue.count)]")
            return nil
        }

        do {
            try connection.transaction {
                try connection.run("DELETE FROM requests")
                for entry in queue {
                    try Self.insert(entry, into: connection)
                }
                try Self.setMeta(Self.mirrorTokenKey, token, in: connection)
                if let pendingToken {
                    try Self.setMeta(Self.pendingTokenKey, pendingToken, in: connection)
                }
            }
        } catch {
            return recover(from: error, queue, pendingToken, isRetry: isRetry)
        }

        committed = queue
        lineage = token
        isMirrorDirty = false
        if !mirrorsLegacyFile {
            removeItem(files.legacy, "the legacy file of the queue just taken over")
        }
        logger?.d(Self.module, "sync", "the whole queue is committed under a new token, requestCount: [\(queue.count)]")
        return token
    }

    /// Handles a transaction that failed. A database that turns out corrupt is set
    /// aside and the whole queue written into a new one; anything else is left for
    /// the next sync.
    private func recover(from error: Error, _ queue: [QueuedRequest], _ pendingToken: String?, isRetry: Bool) -> String? {
        guard Self.isUnusable(error), !isRetry else {
            logger?.d(Self.module, "sync", "the transaction failed and is made again by the next sync, requestCount: [\(queue.count)], \(Self.describe(error))")
            return nil
        }

        logger?.d(Self.module, "sync", "the database turned out corrupt and is set aside, the queue is written into a new one, requestCount: [\(queue.count)], \(Self.describe(error))")
        lineage = nil
        guard setAsideUnusableDatabase(), let reopened = openSettingAsideUnusable("sync", openConnection) else { return nil }
        connection = reopened
        return commitWholeQueue(queue, pendingToken, isRetry: true)
    }

    /// Writes one row, replacing a row under the same sequence.
    private static func insert(_ entry: QueuedRequest, into connection: SQLiteConnection) throws {
        try connection.run("INSERT OR REPLACE INTO requests (seq, body) VALUES (?, ?)", .integer(entry.sequence), .text(entry.request))
    }

    /// Sets one `meta` value.
    private static func setMeta(_ key: String, _ value: String, in connection: SQLiteConnection) throws {
        try connection.run("INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)", .text(key), .text(value))
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

    // MARK: - Mirror

    /// Makes sure no `Countly.dat` is taken over once a commit under `token` lands, by
    /// writing `queue` and the token into it.
    ///
    /// An instance that mirrors the file gets it written whether or not it exists.
    /// One that does not mirror only has one an earlier SDK or a take over cut short
    /// left, and removes it once the commit lands. The file is never removed instead:
    /// it can hold the very queue being taken over, and a commit that then failed
    /// would leave that queue nowhere on disk.
    ///
    /// - Returns: Whether the commit can go ahead.
    private func stampLegacyFile(_ queue: [QueuedRequest], token: String) -> Bool {
        guard mirrorsLegacyFile || FileManager.default.fileExists(atPath: files.legacy.path) else { return true }
        return writeLegacyFile(queue.map(\.request), token: token)
    }

    /// Writes the mirror now if the committed rows changed since it was last written.
    func writeMirrorNow() {
        guard mirrorsLegacyFile, isMirrorDirty, let lineage else { return }
        if writeLegacyFile(committed.map(\.request), token: lineage) {
            isMirrorDirty = false
        }
    }

    /// Writes the mirror a moment from now, held against suspension until then.
    private func scheduleMirror() {
        guard mirrorsLegacyFile, isMirrorDirty, !isMirrorScheduled, lineage != nil else { return }
        isMirrorScheduled = true
        BackgroundTaskGuard.shared.begin()
        writeQueue.asyncAfter(deadline: .now() + Self.mirrorDelay) { [weak self] in
            self?.isMirrorScheduled = false
            self?.writeMirrorNow()
            BackgroundTaskGuard.shared.end()
        }
    }

    /// Archives `requests` into `Countly.dat` the way `CountlyPersistency` does, with
    /// the token added.
    private func writeLegacyFile(_ requests: [String], token: String) -> Bool {
        let payload: [String: Any] = [
            PersistencyKey.queuedRequests: requests,
            PersistencyKey.queueMirrorToken: token,
        ]

        do {
            let data = try CountlyArchive.encodeRoot(payload)
            try data.write(to: files.legacy, options: .atomic)
            logger?.d(Self.module, "writeMirror", "the queue is written to the legacy file the Objective-C SDK reads, requestCount: [\(requests.count)], dataSize: [\(data.count)]")
            return true
        } catch {
            logger?.d(Self.module, "writeMirror", "the legacy file could not be written, it is tried again on the next change, requestCount: [\(requests.count)], \(Self.describe(error))")
            return false
        }
    }

    /// The queue `Countly.dat` holds, and the token of the database it mirrors, `nil`
    /// when the Objective-C SDK wrote it.
    private struct LegacyQueue {
        let requests: [String]
        let token: String?
    }

    /// Reads `Countly.dat`. A file with no queue under the key was written by neither
    /// SDK, and is never taken over in place of rows.
    private func readLegacyFile() -> StoredFile<LegacyQueue> {
        read(files.legacy) { data in
            guard let root = try CountlyArchive.decodeRoot(from: data) as? [String: Any],
                  let stored = root[PersistencyKey.queuedRequests] as? [Any] else { return nil }
            return LegacyQueue(requests: stored.compactMap { $0 as? String },
                               token: root[PersistencyKey.queueMirrorToken] as? String)
        }
    }

    // MARK: - Pending file

    /// The queue as it stood when the database could not take it, and what was known
    /// about the database then.
    private struct PendingFile: Codable {
        let token: String

        /// The mirror token the queue's rows were committed under, `nil` when a take
        /// over had not been committed yet or the database could not be read.
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

    /// Removes the database, the mirror, the pending file and a database set aside.
    func deleteEverything() {
        connection?.close()
        connection = nil
        committed.removeAll()
        lineage = nil
        isMirrorDirty = false

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
