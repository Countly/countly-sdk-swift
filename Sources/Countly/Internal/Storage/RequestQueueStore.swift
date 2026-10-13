//
//  RequestQueueStore.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// The persisted request queue: every request the SDK has produced but not yet
/// had accepted by the server.
///
/// Data must never be lost, so every change reaches disk right after it is made:
/// the write queue hands the whole queue to `RequestQueueDatabase`, which commits
/// what changed as one SQLite transaction. See there for the files, and for how the
/// queue of countly-sdk-ios comes in.
///
/// Reachable from the crash signal handler, so every log line here stays at debug
/// or lower. Error and warning logging re-enters the health tracker, which uses
/// dispatch primitives that are not async-signal-safe.
///
/// Unchecked `Sendable`: the queue is guarded by the lock, and the database is only
/// touched on the write queue.
final class RequestQueueStore: @unchecked Sendable {

    private static let module = "RequestQueue"

    /// How many requests are dropped at most in one overflow pass. Bounds the
    /// work done on the calling thread when a queue is far over its limit.
    private static let removalLoopLimit = 100

    private weak var logger: Logger?

    /// Guards the queue and every property below it. A plain lock rather than a
    /// queue because the crash path needs a synchronous write with no hop, and a
    /// recursive one because the crash handler can interrupt a thread holding it.
    private let lock = NSRecursiveLock()

    /// The queue, oldest first, and always in sequence order: a request is only
    /// ever appended under a new sequence, rewritten in place, or removed.
    private var entries: [QueuedRequest] = []
    private var nextSequence: Int64 = 1

    /// Whether the database could not be read yet. The queue then holds only what
    /// was recorded since, and the database's queue goes in front of it once a sync
    /// opens it.
    private var isDetached = false

    /// Changes meant for the whole queue that were made while detached. They are
    /// made on the database's queue as well once it opens, since its requests were
    /// not in memory to receive them.
    private var detachedChanges: [(inout [QueuedRequest]) -> Void] = []

    /// The head of the queue when the database's queue went in front of it. A drain
    /// may have been sending it, and its removal is still honoured.
    private var headDisplacedByAttach: String?

    /// Counts the merges with the database's queue. A merge renumbers the requests
    /// queued meanwhile, so a sequence read before one no longer names its request.
    private var attachEpoch = 0

    /// Whether a sync is queued that has not taken its copy of the queue yet, and
    /// so carries every change made meanwhile as well.
    private var isSyncScheduled = false

    /// Set once the store is closed by a halt or its files are deleted, so nothing
    /// that reaches it afterwards, a sync queued before or a send that completes
    /// late, can write the files again.
    private var isClosed = false

    /// What the crash handler records about the database in a pending file: the
    /// lineage token the queue was last committed under, and the highest sequence
    /// known to be on disk. Kept here because the crash handler must not touch the
    /// database object, whose state the operation it interrupted may be changing.
    private var durableLineage: String?
    private var durableMaxSequence: Int64 = 0

    /// The token of a pending file whose requests the queue holds, until a sync
    /// commits it and the next load knows the file is folded in.
    private var pendingFileToken: String?

    /// The token the last sync committed. A pending file left under it holds nothing
    /// the queue does not, so it may be written over.
    private var committedPendingFileToken: String?

    /// Maximum number of requests kept. Older ones are dropped past this.
    ///
    /// Reported on change: the queue drops against the value it holds, not against
    /// the one in the developer config, and a report of lost requests is answered
    /// by knowing which of the two the queue was actually running on.
    var storedRequestsLimit: Int = 1000 {
        didSet {
            logger?.d(Self.module, "storedRequestsLimit", "the request queue limit is set, previousValue: [\(oldValue)], newValue: [\(storedRequestsLimit)], queuedRequestCount: [\(count)]")
        }
    }

    /// Requests older than this are dropped. Zero disables age based dropping.
    var requestDropAgeHours: Int = 0 {
        didSet {
            logger?.d(Self.module, "requestDropAgeHours", "the request drop age is set, previousValue: [\(oldValue)], newValue: [\(requestDropAgeHours)], ageBasedDroppingEnabled: [\(requestDropAgeHours > 0)]")
        }
    }

    /// Runs every database operation, one at a time.
    private let writeQueue = DispatchQueue(label: "ly.count.requestqueue.write", qos: .utility)

    /// Marks this store's write queue. One key per store, so no store takes another
    /// store's queue for its own.
    private let writeQueueKey = DispatchSpecificKey<Bool>()

    private let database: RequestQueueDatabase

    /// Reads the queue from disk. Called once per instance at init.
    init(namespace: StorageNamespace, logger: Logger?) {
        self.logger = logger
        database = RequestQueueDatabase(namespace: namespace, logger: logger)
        writeQueue.setSpecific(key: writeQueueKey, value: true)

        if let loaded = database.attach(skippingPendingFile: nil) {
            entries = loaded.queue
            nextSequence = loaded.nextSequence
            durableLineage = loaded.lineage
            durableMaxSequence = loaded.durableMaxSequence
            pendingFileToken = loaded.pendingFileToken
        } else {
            isDetached = true
        }

        // The load only reads, so whatever it decided to write is left to this sync.
        lock.lock()
        scheduleSyncLocked()
        lock.unlock()
    }

    // MARK: - Queue operations

    /// Number of requests waiting to be sent.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// The request that will be sent next, or `nil` when the queue is empty.
    var head: String? {
        lock.lock()
        defer { lock.unlock() }
        return entries.first?.request
    }

    /// The request that will be sent next, with what still identifies it once a
    /// bulk rewrite has changed its text. What the drain sends and later removes.
    var headEntry: QueuedHead? {
        lock.lock()
        defer { lock.unlock() }
        guard let first = entries.first else { return nil }
        return QueuedHead(request: first.request, sequence: first.sequence, attachEpoch: attachEpoch)
    }

    /// Whether any queued request matches `predicate`, read under the lock.
    func containsRequest(where predicate: (String) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { predicate($0.request) }
    }

    /// A copy of the whole queue, oldest first.
    ///
    /// Taken under the lock so a caller iterating it cannot observe a queue that a
    /// drain or an overflow trim is rewriting underneath it.
    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries.map(\.request)
    }

    /// Appends a request, dropping older ones if the queue is over its limit.
    ///
    /// - Parameters:
    ///   - queryString: The request body, without the app version.
    ///   - appVersion: Stamped onto the request now rather than at send time, so
    ///     a request queued before an app update still reports the version it was
    ///     produced under.
    ///   - trackingEnabled: When the server has switched tracking off, the
    ///     request is discarded instead of queued.
    /// - Returns: The request exactly as stored, app version included, or `nil`
    ///   when it was refused.
    @discardableResult
    func enqueue(_ queryString: String, appVersion: String, trackingEnabled: Bool) -> String? {
        guard trackingEnabled else {
            logger?.d(Self.module, "enqueue", "request is not stored in the queue, reason: tracking is disabled by behavior settings, queryStringLength: [\(queryString.count)]")
            return nil
        }

        guard !queryString.isEmpty else {
            logger?.d(Self.module, "enqueue", "request is not stored in the queue, reason: it reached the store with an empty query string")
            return nil
        }

        let stamped = queryString + "&\(QS.appVersion)=\(appVersion)"

        lock.lock()
        defer { lock.unlock() }

        trimToLimitLocked()
        appendLocked(stamped)
        logger?.d(Self.module, "enqueue", "request is stored in the queue, queryStringLength: [\(stamped.count)], queuedRequestCount: [\(entries.count)], storedRequestsLimit: [\(storedRequestsLimit)]")
        return stamped
    }

    /// Makes room for one more request, dropping the oldest when the queue is at
    /// its limit. The caller holds the lock.
    private func trimToLimitLocked() {
        guard entries.count >= storedRequestsLimit else { return }

        removeOldAgeRequestsLocked()
        guard entries.count >= storedRequestsLimit else { return }

        let exceeded = entries.count - storedRequestsLimit
        let removeCount = min(min(exceeded, Self.removalLoopLimit) + 1, entries.count)
        logger?.d(Self.module, "trimToLimitLocked", "the oldest queued requests are dropped because the queue is over its limit, queuedRequestCount: [\(entries.count)], storedRequestsLimit: [\(storedRequestsLimit)], droppedRequestCount: [\(removeCount)], exceededBy: [\(exceeded)]")
        entries.removeFirst(removeCount)
        scheduleSyncLocked()
    }

    /// Appends a request under the next sequence. The caller holds the lock.
    private func appendLocked(_ request: String) {
        entries.append(QueuedRequest(sequence: nextSequence, request: request))
        nextSequence += 1
        scheduleSyncLocked()
    }

    /// Appends a request exactly as given, skipping the app version stamping and
    /// the tracking check `enqueue` applies.
    ///
    /// The size and age trimming still applies. See ``RequestQueueAPI/store(_:)``
    /// for why this path exists.
    func appendVerbatim(_ queryString: String) {
        guard !queryString.isEmpty else {
            logger?.d(Self.module, "appendVerbatim", "an empty request was not stored")
            return
        }

        lock.lock()
        defer { lock.unlock() }

        trimToLimitLocked()
        appendLocked(queryString)
        logger?.d(Self.module, "appendVerbatim", "a request was stored verbatim, queryStringLength: [\(queryString.count)], queuedRequestCount: [\(entries.count)]")
    }

    /// Removes the request at the head of the queue, but only if it still is the
    /// one the caller sent. A request that moved is left alone, apart from one the
    /// database's queue was put in front of after a drain read it.
    func removeHead(_ queryString: String) {
        lock.lock()
        defer { lock.unlock() }
        removeHeadLocked(queryString)
    }

    /// Removes the request the drain took with `headEntry`, found by its sequence,
    /// so one a bulk rewrite changed while it was being sent is removed too rather
    /// than sent a second time in its rewritten form.
    func removeHead(_ head: QueuedHead) {
        lock.lock()
        defer { lock.unlock() }

        // A merge with the database renumbered the queue since the head was taken,
        // so only its text can still find it.
        guard head.attachEpoch == attachEpoch,
              let index = entries.firstIndex(where: { $0.sequence == head.sequence }) else {
            removeHeadLocked(head.request)
            return
        }

        let rewritten = entries[index].request != head.request
        headDisplacedByAttach = nil
        entries.remove(at: index)
        scheduleSyncLocked()
        logger?.d(Self.module, "removeHead", "request at the head of the queue is removed, rewrittenWhileSent: [\(rewritten)], remainingRequestCount: [\(entries.count)]")
    }

    /// `removeHead(_:)` by text. The caller holds the lock.
    private func removeHeadLocked(_ queryString: String) {
        let displaced = headDisplacedByAttach
        headDisplacedByAttach = nil

        let index: Int
        if entries.first?.request == queryString {
            index = 0
        } else if queryString == displaced, let found = entries.firstIndex(where: { $0.request == queryString }) {
            index = found
        } else {
            logger?.d(Self.module, "removeHead", "the request that was sent is no longer at the head of the queue and nothing is removed, queryStringLength: [\(queryString.count)], queuedRequestCount: [\(entries.count)]")
            return
        }
        entries.remove(at: index)
        scheduleSyncLocked()
        logger?.d(Self.module, "removeHead", "request at the head of the queue is removed, remainingRequestCount: [\(entries.count)]")
    }

    /// Drops every queued request.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        if !entries.isEmpty {
            logger?.d(Self.module, "flush", "the request queue is being emptied and everything still in it is dropped, droppedRequestCount: [\(entries.count)]")
        }
        changeWholeQueueLocked(replacingEarlierChanges: true) { $0.removeAll() }
    }

    /// Rewrites queued requests that carry the temporary device ID so they report
    /// the real one, which is how data recorded before a real ID was known still
    /// lands on the right user.
    func replaceTemporaryDeviceIDs(with deviceID: String, typeValue: Int) {
        lock.lock()
        defer { lock.unlock() }

        let temporaryID = "&\(QS.deviceID)=\(TemporaryDeviceID.value)"
        let realID = "&\(QS.deviceID)=\(deviceID.urlEscaped)"
        let temporaryType = "&\(QS.deviceIDType)=\(DeviceIDType.temporary.wireValue)"
        let realType = "&\(QS.deviceIDType)=\(typeValue)"

        let replacedCount = changeWholeQueueLocked { queue -> Int in
            var replacedCount = 0
            for index in queue.indices where queue[index].request.contains(temporaryID) {
                queue[index].request = queue[index].request
                    .replacingOccurrences(of: temporaryID, with: realID)
                    .replacingOccurrences(of: temporaryType, with: realType)
                replacedCount += 1
            }
            return replacedCount
        }

        logger?.d(Self.module, "replaceTemporaryDeviceIDs", "queued requests carrying the temporary device ID now carry the real one, replacedRequestCount: [\(replacedCount)], queuedRequestCount: [\(entries.count)], deviceIDType: [\(typeValue)]")
    }

    /// Rewrites queued requests recorded under a different app key so they report
    /// the current one.
    func replaceAllAppKeys(with appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let escaped = appKey.urlEscaped
        let counts = changeWholeQueueLocked { queue -> (replaced: Int, withoutAppKey: Int) in
            var replacedCount = 0
            var withoutAppKeyCount = 0
            for index in queue.indices {
                guard let existing = Self.appKey(in: queue[index].request) else {
                    withoutAppKeyCount += 1
                    continue
                }
                guard existing != escaped else { continue }
                queue[index].request = queue[index].request.replacingOccurrences(
                    of: "\(QS.appKey)=\(existing)",
                    with: "\(QS.appKey)=\(escaped)")
                replacedCount += 1
            }
            return (replacedCount, withoutAppKeyCount)
        }

        logger?.d(Self.module, "replaceAllAppKeys", "queued requests recorded under another app key now carry the current one, replacedRequestCount: [\(counts.replaced)], requestsWithoutAnAppKey: [\(counts.withoutAppKey)], queuedRequestCount: [\(entries.count)]")
    }

    /// Drops queued requests recorded under a different app key.
    func removeDifferentAppKeys(than appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let before = entries.count
        let escaped = appKey.urlEscaped
        changeWholeQueueLocked { $0.removeAll { Self.appKey(in: $0.request) != escaped } }

        if before > entries.count {
            logger?.d(Self.module, "removeDifferentAppKeys", "queued requests recorded under another app key are dropped, droppedRequestCount: [\(before - entries.count)], remainingRequestCount: [\(entries.count)]")
        }
    }

    /// Drops queued requests older than `requestDropAgeHours`.
    func removeOldAgeRequests() {
        lock.lock()
        defer { lock.unlock() }
        removeOldAgeRequestsLocked()
    }

    /// Whether a request is past the configured drop age. Always `false` when age
    /// based dropping is off.
    func isOldRequest(_ queryString: String) -> Bool {
        guard requestDropAgeHours > 0, Self.isOld(queryString, dropAgeHours: requestDropAgeHours) else { return false }

        // Only the single request path says this. The bulk drop below runs the
        // same check over the whole queue and reports one count instead.
        logger?.d(Self.module, "isOldRequest", "a queued request is past the configured drop age, requestAgeHours: [\((queryString.requestAgeSeconds / 3600.0).logSeconds)], requestDropAgeHours: [\(requestDropAgeHours)], queryStringLength: [\(queryString.count)]")
        return true
    }

    /// Drops the requests past the drop age. Not kept for the database's queue while
    /// that has not been read: merging applies the drop to all of it. The caller holds
    /// the lock.
    private func removeOldAgeRequestsLocked() {
        let dropAgeHours = requestDropAgeHours
        guard dropAgeHours > 0 else { return }

        let before = entries.count
        entries.removeAll { Self.isOld($0.request, dropAgeHours: dropAgeHours) }

        if before > entries.count {
            scheduleSyncLocked()
            logger?.d(Self.module, "removeOldAgeRequests", "queued requests past the configured drop age are dropped, droppedRequestCount: [\(before - entries.count)], requestDropAgeHours: [\(requestDropAgeHours)], remainingRequestCount: [\(entries.count)]")
        }
    }

    /// Makes a change meant for the whole queue, and keeps it for the database's
    /// queue while that has not been read yet, since its requests are not in memory
    /// to receive it. The caller holds the lock.
    ///
    /// - Parameter replacingEarlierChanges: Whether the change leaves nothing of what
    ///   the changes kept before it did, as a flush does, so they can go.
    @discardableResult
    private func changeWholeQueueLocked<Result>(replacingEarlierChanges: Bool = false,
                                                _ change: @escaping (inout [QueuedRequest]) -> Result) -> Result {
        let result = change(&entries)
        if isDetached {
            if replacingEarlierChanges {
                detachedChanges.removeAll()
            }
            detachedChanges.append { _ = change(&$0) }
        }
        scheduleSyncLocked()
        return result
    }

    /// The app key a queued request carries.
    ///
    /// Read by slicing rather than by parsing the query: the queue can hold a
    /// thousand requests and every bulk operation touches all of them. `app_key`
    /// is always the first parameter `queryEssentials` emits, so the prefix is a
    /// safe anchor.
    private static func appKey(in request: String) -> String? {
        let marker = QS.appKey + "="
        guard request.hasPrefix(marker) else {
            // The slow path decodes, so it is re-escaped to keep both paths
            // answering in the same form as the value they are compared against.
            return request.valueForQueryStringKey(QS.appKey)?.urlEscaped
        }
        let value = request.dropFirst(marker.count)
        return String(value.prefix(while: { $0 != "&" }))
    }

    /// Whether a request is at least `dropAgeHours` old.
    private static func isOld(_ request: String, dropAgeHours: Int) -> Bool {
        request.requestAgeSeconds / 3600.0 >= Double(dropAgeHours)
    }

    // MARK: - Persistence

    /// Queues a sync unless one is queued already, which then carries this change
    /// as well. The caller holds the lock.
    private func scheduleSyncLocked() {
        guard !isSyncScheduled, !isClosed else { return }
        isSyncScheduled = true
        writeQueue.async { [weak self] in self?.syncNow() }
    }

    /// Hands the queue as it is now to the database, opening it first if it could
    /// not be read so far. Runs on the write queue.
    private func syncNow() {
        lock.lock()
        isSyncScheduled = false
        let closed = isClosed
        let detached = isDetached
        let ownPendingToken = pendingFileToken
        lock.unlock()

        guard !closed else { return }

        if detached {
            guard let loaded = database.attach(skippingPendingFile: ownPendingToken) else {
                savePendingFile(onlyWhenNotEmpty: true)
                return
            }
            lock.lock()
            mergeLocked(loaded)
            lock.unlock()
        }

        lock.lock()
        let queue = entries
        let pendingToken = pendingFileToken
        lock.unlock()

        guard let committedLineage = database.sync(queue, pendingToken: pendingToken) else { return }

        lock.lock()
        durableLineage = committedLineage
        durableMaxSequence = max(durableMaxSequence, queue.last?.sequence ?? 0)
        if let pendingToken {
            committedPendingFileToken = pendingToken
        }
        if pendingFileToken == pendingToken {
            pendingFileToken = nil
        }
        lock.unlock()
    }

    /// Puts the database's queue, now that it could be read, in front of what was
    /// queued meanwhile, with the whole-queue changes made meanwhile made on it too.
    /// The caller holds the lock.
    private func mergeLocked(_ loaded: LoadedQueue) {
        var queue = loaded.queue
        for change in detachedChanges {
            change(&queue)
        }
        detachedChanges.removeAll()

        if !queue.isEmpty {
            headDisplacedByAttach = entries.first?.request
        }
        let queuedMeanwhile = entries.count
        var sequence = loaded.nextSequence
        for entry in entries {
            queue.append(QueuedRequest(sequence: sequence, request: entry.request))
            sequence += 1
        }

        entries = queue
        nextSequence = sequence
        attachEpoch += 1
        isDetached = false
        durableLineage = loaded.lineage
        durableMaxSequence = loaded.durableMaxSequence
        if let token = loaded.pendingFileToken {
            pendingFileToken = token
        }
        logger?.d(Self.module, "syncNow", "the database could be read at last and its queue goes in front of the requests queued meanwhile, databaseRequestCount: [\(queue.count - queuedMeanwhile)], queuedMeanwhileCount: [\(queuedMeanwhile)]")

        // The limits saw only the requests in memory, so the merged queue gets them now.
        removeOldAgeRequestsLocked()
        if entries.count > storedRequestsLimit {
            let droppedCount = entries.count - storedRequestsLimit
            entries.removeFirst(droppedCount)
            logger?.d(Self.module, "syncNow", "the oldest requests of the merged queue are dropped because it is over its limit, droppedRequestCount: [\(droppedCount)], storedRequestsLimit: [\(storedRequestsLimit)]")
        }
    }

    /// Writes every change so far to disk off the calling thread.
    ///
    /// Held against suspension for the length of the write. This is the write that
    /// records a request as sent, so a process suspended before it lands rolls the
    /// queue back and sends the request again.
    ///
    /// - Parameter completion: Called on the write queue once the write is done. It
    ///   must not call `saveSync()`, which on the write queue is the crash path.
    func save(completion: (@Sendable () -> Void)? = nil) {
        BackgroundTaskGuard.shared.begin()
        writeQueue.async { [weak self] in
            self?.syncNow()
            BackgroundTaskGuard.shared.end()
            completion?()
        }
    }

    /// Writes every change so far to disk on the calling thread. Used when the
    /// process is about to end, where an asynchronous write would not survive.
    func saveSync() {
        guard DispatchQueue.getSpecific(key: writeQueueKey) == nil else {
            // Only the crash handler lands here, and waiting on this queue from itself would hang.
            writeFromCrashHandler()
            return
        }

        // Routed through the write queue so an in-flight write cannot overtake this
        // one, and so a flush is never undone by a sync that copied the queue before it.
        writeQueue.sync { [self] in syncNow() }
    }

    /// Saves the queue into the pending file, for the crash handler on the write
    /// queue's own thread, where the database is not touched.
    private func writeFromCrashHandler() {
        savePendingFile(onlyWhenNotEmpty: false)

        // Should the process go on after all, the next sync commits the token.
        lock.lock()
        scheduleSyncLocked()
        lock.unlock()
    }

    /// Saves the queue into the pending file, for the next launch to fold in: from the
    /// crash handler, and from every sync while the database cannot be read.
    private func savePendingFile(onlyWhenNotEmpty: Bool) {
        lock.lock()
        let queue = entries
        let lineage = durableLineage
        let durable = durableMaxSequence
        let ownTokens = Set([pendingFileToken, committedPendingFileToken].compactMap { $0 })
        let closed = isClosed
        lock.unlock()

        guard !closed, !(onlyWhenNotEmpty && queue.isEmpty),
              let token = database.writePendingFile(queue, lineage: lineage, durableMaxSequence: durable, replacing: ownTokens) else { return }

        lock.lock()
        pendingFileToken = token
        lock.unlock()
    }

    /// Writes the queue one last time and closes the store. Used by every halt that
    /// keeps the data.
    ///
    /// A change that reaches the store afterwards, such as a send that completes
    /// once the halt is over, stays in memory. Written, it would land in the files
    /// the next start has already read, and a removal could empty the queue that
    /// start is still sending from.
    func close() {
        writeQueue.sync { [self] in
            syncNow()
            lock.lock()
            isClosed = true
            lock.unlock()
        }
    }

    /// Deletes every file of the queue, a `Countly.dat` not merged yet included.
    /// Used by `halt(clearStorage: true)`.
    ///
    /// A change made before the caller asked for the data to be erased cannot
    /// re-create a file afterwards: every sync from then on is skipped.
    func deleteFile() {
        lock.lock()
        isClosed = true
        lock.unlock()

        writeQueue.sync { [database] in database.deleteEverything() }
        logger?.d(Self.module, "deleteFile", "the database, the pending file and the legacy file of the request queue are deleted")
    }
}

/// A request the drain took from the head of the queue, with what identifies it
/// once a bulk rewrite has changed its text.
struct QueuedHead {

    /// The request as it was when the drain took it, which is what is sent.
    let request: String

    /// The request's place in the queue, kept by a rewrite.
    let sequence: Int64

    /// The merges with the database before it was taken, since a merge renumbers.
    let attachEpoch: Int
}

/// Where the SDK is allowed to keep files.
enum StorageLocation {

    /// Application support on every platform except tvOS, which only guarantees
    /// caches as writable.
    static func directoryURL(logger: Logger?) -> URL {
        #if os(tvOS)
        let directory = FileManager.SearchPathDirectory.cachesDirectory
        #else
        let directory = FileManager.SearchPathDirectory.applicationSupportDirectory
        #endif

        var url = FileManager.default.urls(for: directory, in: .userDomainMask).last
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        #if os(macOS)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            url = url.appendingPathComponent(bundleIdentifier)
        }
        #endif

        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } catch {
                logger?.e("Storage", "directoryURL", "storage directory can not be created, path: [\(url.path)], error: [\(error.localizedDescription)]")
            }
        }

        return url
    }
}
