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
/// Data must never be lost, so every change reaches disk right after it is made,
/// one file per request: the write queue hands the whole queue to
/// `RequestQueueFiles`, which brings the files in line with it. See there for the
/// layout, and for the `Countly.dat` mirror that keeps the default instance's
/// queue readable by countly-sdk-ios: an application can move to this SDK and
/// back again without losing a queued request.
///
/// Reachable from the crash signal handler, so every log line here stays at debug
/// or lower. Error and warning logging re-enters the health tracker, which uses
/// dispatch primitives that are not async-signal-safe.
///
/// Unchecked `Sendable`: the queue is guarded by the lock, and every write goes
/// through the write queue.
final class RequestQueueStore: @unchecked Sendable {

    private static let module = "RequestQueue"

    /// How many requests are dropped at most in one overflow pass. Bounds the
    /// work done on the calling thread when a queue is far over its limit.
    private static let removalLoopLimit = 100

    private weak var logger: Logger?

    /// Guards the queue and the counters and flags below it. A plain lock rather
    /// than a queue because the crash path needs a synchronous write with no hop.
    private let lock = NSRecursiveLock()
    private var entries: [QueuedRequest] = []
    private var nextSequence: UInt64 = 1

    /// How many times the whole queue changed at once: requests rewritten in place,
    /// or all of them dropped. Such a change reaches disk as a new generation
    /// rather than file by file.
    private var rewriteCount = 0

    /// Whether a sync is queued that has not taken its copy of the queue yet, and
    /// so carries every change made meanwhile as well.
    private var isSyncScheduled = false

    /// Set once the files are deleted, so a sync queued before that cannot write
    /// them back.
    private var isDeleted = false

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

    /// Set while a bulk rewrite of the queue is in progress, so the connection
    /// manager does not start sending a request that is about to be rewritten.
    private(set) var isBeingModified: Bool = false

    /// Runs every file operation, one at a time.
    private let writeQueue = DispatchQueue(label: "ly.count.requestqueue.write", qos: .utility)

    /// Marks this store's write queue. One key per store, so no store takes another
    /// store's queue for its own.
    private let writeQueueKey = DispatchSpecificKey<Bool>()

    private let files: RequestQueueFiles

    /// Reads the queue from disk. Called once per instance at init.
    ///
    /// - Parameter mirrorsLegacyFile: Whether `Countly.dat` is kept current for the
    ///   Objective-C SDK. Defaults to the default instance, whose data is the only
    ///   data that SDK reads.
    init(namespace: StorageNamespace, logger: Logger?, mirrorsLegacyFile: Bool? = nil) {
        self.logger = logger
        files = RequestQueueFiles(namespace: namespace,
                                  mirrorsLegacyFile: mirrorsLegacyFile ?? namespace.isDefault,
                                  writeQueue: writeQueue,
                                  logger: logger)
        writeQueue.setSpecific(key: writeQueueKey, value: true)
        (entries, nextSequence) = files.load()

        // The load only reads, so whatever it found to write is left to this sync.
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

    /// Adds a request at the tail. The caller holds the lock.
    private func appendLocked(_ request: String) {
        entries.append(QueuedRequest(sequence: nextSequence, request: request))
        nextSequence += 1
        scheduleSyncLocked()
    }

    /// Removes the request at the head of the queue, but only if it still is the
    /// one the caller sent. A request that moved is left alone.
    func removeHead(_ queryString: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let first = entries.first, first.request == queryString else {
            logger?.d(Self.module, "removeHead", "the request that was sent is no longer at the head of the queue and nothing is removed, queryStringLength: [\(queryString.count)], queuedRequestCount: [\(entries.count)]")
            return
        }
        entries.removeFirst()
        scheduleSyncLocked()
        logger?.d(Self.module, "removeHead", "request at the head of the queue is removed, remainingRequestCount: [\(entries.count)]")
    }

    /// Drops every queued request.
    ///
    /// All at once on disk too, as a new generation: a flush is how pending data
    /// is discarded when a user asks for it, and a process killed part way must
    /// not send the rest.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        if !entries.isEmpty {
            logger?.d(Self.module, "flush", "the request queue is being emptied and everything still in it is dropped, droppedRequestCount: [\(entries.count)]")
        }
        entries.removeAll()
        rewriteCount += 1
        scheduleSyncLocked()
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

        var replacedCount = 0
        isBeingModified = true
        for index in entries.indices where entries[index].request.contains(temporaryID) {
            entries[index].request = entries[index].request
                .replacingOccurrences(of: temporaryID, with: realID)
                .replacingOccurrences(of: temporaryType, with: realType)
            replacedCount += 1
        }
        isBeingModified = false

        if replacedCount > 0 {
            rewriteCount += 1
            scheduleSyncLocked()
        }
        logger?.d(Self.module, "replaceTemporaryDeviceIDs", "queued requests carrying the temporary device ID now carry the real one, replacedRequestCount: [\(replacedCount)], queuedRequestCount: [\(entries.count)], deviceIDType: [\(typeValue)]")
    }

    /// Rewrites queued requests recorded under a different app key so they report
    /// the current one.
    func replaceAllAppKeys(with appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let escaped = appKey.urlEscaped
        var replacedCount = 0
        var withoutAppKeyCount = 0
        isBeingModified = true
        for index in entries.indices {
            guard let existing = Self.appKey(in: entries[index].request) else {
                withoutAppKeyCount += 1
                continue
            }
            guard existing != escaped else { continue }
            entries[index].request = entries[index].request.replacingOccurrences(
                of: "\(QS.appKey)=\(existing)",
                with: "\(QS.appKey)=\(escaped)")
            replacedCount += 1
        }
        isBeingModified = false

        if replacedCount > 0 {
            rewriteCount += 1
            scheduleSyncLocked()
        }
        logger?.d(Self.module, "replaceAllAppKeys", "queued requests recorded under another app key now carry the current one, replacedRequestCount: [\(replacedCount)], requestsWithoutAnAppKey: [\(withoutAppKeyCount)], queuedRequestCount: [\(entries.count)]")
    }

    /// Drops queued requests recorded under a different app key.
    func removeDifferentAppKeys(than appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let before = entries.count
        let escaped = appKey.urlEscaped
        isBeingModified = true
        entries = entries.filter { Self.appKey(in: $0.request) == escaped }
        isBeingModified = false

        if before > entries.count {
            scheduleSyncLocked()
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
        guard requestDropAgeHours > 0, isOldRequestInternal(queryString) else { return false }

        // Only the single request path says this. The bulk drop below runs the
        // same check over the whole queue and reports one count instead.
        logger?.d(Self.module, "isOldRequest", "a queued request is past the configured drop age, requestAgeHours: [\((queryString.requestAgeSeconds / 3600.0).logSeconds)], requestDropAgeHours: [\(requestDropAgeHours)], queryStringLength: [\(queryString.count)]")
        return true
    }

    private func removeOldAgeRequestsLocked() {
        guard requestDropAgeHours > 0 else { return }

        let before = entries.count
        isBeingModified = true
        entries.removeAll { isOldRequestInternal($0.request) }
        isBeingModified = false

        if before > entries.count {
            scheduleSyncLocked()
            logger?.d(Self.module, "removeOldAgeRequests", "queued requests past the configured drop age are dropped, droppedRequestCount: [\(before - entries.count)], requestDropAgeHours: [\(requestDropAgeHours)], remainingRequestCount: [\(entries.count)]")
        }
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

    private func isOldRequestInternal(_ queryString: String) -> Bool {
        queryString.requestAgeSeconds / 3600.0 >= Double(requestDropAgeHours)
    }

    // MARK: - Persistence

    /// Queues a sync unless one is queued already, which then carries this change
    /// as well. The caller holds the lock.
    private func scheduleSyncLocked() {
        guard !isSyncScheduled else { return }
        isSyncScheduled = true
        writeQueue.async { [self] in syncNow() }
    }

    /// Hands the queue as it is now to the files. Runs on the write queue.
    private func syncNow() {
        lock.lock()
        isSyncScheduled = false
        let queue = entries
        let rewrites = rewriteCount
        let deleted = isDeleted
        lock.unlock()

        guard !deleted else { return }
        files.sync(queue, rewriteCount: rewrites)
    }

    /// Brings the files in line with every change so far, off the calling thread.
    ///
    /// Held against suspension until then. This is what records a request as
    /// sent, so a process suspended before it lands sends the request again.
    func save() {
        BackgroundTaskGuard.shared.begin()
        writeQueue.async { [self] in
            syncNow()
            BackgroundTaskGuard.shared.end()
        }
    }

    /// Writes every change so far to disk on the calling thread, the mirror
    /// included. Used when the process is about to end, where an asynchronous
    /// write would not survive.
    func saveSync() {
        guard DispatchQueue.getSpecific(key: writeQueueKey) == nil else {
            // Only the crash handler lands here, and waiting on this queue from itself would hang.
            lock.lock()
            let queue = entries
            let deleted = isDeleted
            lock.unlock()
            if !deleted {
                files.writeFromCrashHandler(queue)
            }
            return
        }

        writeQueue.sync { [self] in
            syncNow()
            files.writeMirrorNow()
        }
    }

    /// Deletes every file of the queue, the mirror included. Used by
    /// `halt(clearStorage: true)`.
    ///
    /// A change made before the caller asked for the data to be erased cannot
    /// re-create a file afterwards: every sync from then on is skipped.
    func deleteFile() {
        lock.lock()
        isDeleted = true
        lock.unlock()

        writeQueue.sync { [files] in files.deleteEverything() }
        logger?.d(Self.module, "deleteFile", "the request files and the legacy file of the request queue are deleted")
    }
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
