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
/// Data must never be lost, so the queue survives process death by being written
/// to a file in the application support directory (caches on tvOS). The file
/// format is a keyed archive of `[key: [String]]`, byte compatible with what
/// earlier Countly SDKs wrote, so the default instance picks up a queue left
/// behind by a previous SDK version rather than dropping it.
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

    private let namespace: StorageNamespace
    private weak var logger: Logger?

    /// Guards `requests`. A plain lock rather than a queue because the crash path
    /// needs a synchronous write with no hop.
    private let lock = NSRecursiveLock()
    private var requests: [String] = []

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

    /// Reads the queue from disk. Called once per instance at init.
    init(namespace: StorageNamespace, logger: Logger?) {
        self.namespace = namespace
        self.logger = logger
        writeQueue.setSpecific(key: Self.writeQueueKey, value: true)
        load()
    }

    // MARK: - Queue operations

    /// Number of requests waiting to be sent.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }

    /// The request that will be sent next, or `nil` when the queue is empty.
    var head: String? {
        lock.lock()
        defer { lock.unlock() }
        return requests.first
    }

    /// A copy of the whole queue, oldest first.
    ///
    /// Taken under the lock so a caller iterating it cannot observe a queue that a
    /// drain or an overflow trim is rewriting underneath it.
    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
        requests.append(stamped)
        logger?.d(Self.module, "enqueue", "request is stored in the queue, queryStringLength: [\(stamped.count)], queuedRequestCount: [\(requests.count)], storedRequestsLimit: [\(storedRequestsLimit)]")
        return stamped
    }

    /// Makes room for one more request, dropping the oldest when the queue is at
    /// its limit. The caller holds the lock.
    private func trimToLimitLocked() {
        guard requests.count >= storedRequestsLimit else { return }

        removeOldAgeRequestsLocked()
        guard requests.count >= storedRequestsLimit else { return }

        let exceeded = requests.count - storedRequestsLimit
        let removeCount = min(min(exceeded, Self.removalLoopLimit) + 1, requests.count)
        logger?.d(Self.module, "trimToLimitLocked", "the oldest queued requests are dropped because the queue is over its limit, queuedRequestCount: [\(requests.count)], storedRequestsLimit: [\(storedRequestsLimit)], droppedRequestCount: [\(removeCount)], exceededBy: [\(exceeded)]")
        requests.removeFirst(removeCount)
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
        requests.append(queryString)
        logger?.d(Self.module, "appendVerbatim", "a request was stored verbatim, queryStringLength: [\(queryString.count)], queuedRequestCount: [\(requests.count)]")
    }

    /// Removes the request at the head of the queue, but only if it still is the
    /// one the caller sent. A request that moved is left alone.
    func removeHead(_ queryString: String) {
        lock.lock()
        defer { lock.unlock() }

        guard requests.first == queryString else {
            logger?.d(Self.module, "removeHead", "the request that was sent is no longer at the head of the queue and nothing is removed, queryStringLength: [\(queryString.count)], queuedRequestCount: [\(requests.count)]")
            return
        }
        requests.removeFirst()
        logger?.d(Self.module, "removeHead", "request at the head of the queue is removed, remainingRequestCount: [\(requests.count)]")
    }

    /// Drops every queued request.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        if !requests.isEmpty {
            logger?.d(Self.module, "flush", "the request queue is being emptied and everything still in it is dropped, droppedRequestCount: [\(requests.count)]")
        }
        requests.removeAll()
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
        for index in requests.indices where requests[index].contains(temporaryID) {
            requests[index] = requests[index]
                .replacingOccurrences(of: temporaryID, with: realID)
                .replacingOccurrences(of: temporaryType, with: realType)
            replacedCount += 1
        }
        isBeingModified = false

        logger?.d(Self.module, "replaceTemporaryDeviceIDs", "queued requests carrying the temporary device ID now carry the real one, replacedRequestCount: [\(replacedCount)], queuedRequestCount: [\(requests.count)], deviceIDType: [\(typeValue)]")
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
        for index in requests.indices {
            guard let existing = Self.appKey(in: requests[index]) else {
                withoutAppKeyCount += 1
                continue
            }
            guard existing != escaped else { continue }
            requests[index] = requests[index].replacingOccurrences(
                of: "\(QS.appKey)=\(existing)",
                with: "\(QS.appKey)=\(escaped)")
            replacedCount += 1
        }
        isBeingModified = false

        logger?.d(Self.module, "replaceAllAppKeys", "queued requests recorded under another app key now carry the current one, replacedRequestCount: [\(replacedCount)], requestsWithoutAnAppKey: [\(withoutAppKeyCount)], queuedRequestCount: [\(requests.count)]")
    }

    /// Drops queued requests recorded under a different app key.
    func removeDifferentAppKeys(than appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let before = requests.count
        let escaped = appKey.urlEscaped
        isBeingModified = true
        requests = requests.filter { Self.appKey(in: $0) == escaped }
        isBeingModified = false

        if before > requests.count {
            logger?.d(Self.module, "removeDifferentAppKeys", "queued requests recorded under another app key are dropped, droppedRequestCount: [\(before - requests.count)], remainingRequestCount: [\(requests.count)]")
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

        let before = requests.count
        isBeingModified = true
        requests = requests.filter { !isOldRequestInternal($0) }
        isBeingModified = false

        if before > requests.count {
            logger?.d(Self.module, "removeOldAgeRequests", "queued requests past the configured drop age are dropped, droppedRequestCount: [\(before - requests.count)], requestDropAgeHours: [\(requestDropAgeHours)], remainingRequestCount: [\(requests.count)]")
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

    /// Serializes writes to the backing file.
    ///
    /// Snapshot and write have to stay in the same order: two saves racing on a
    /// concurrent queue can land in the opposite order to their snapshots, which
    /// either loses a request queued between them or resurrects one already sent.
    private let writeQueue = DispatchQueue(label: "ly.count.requestqueue.write", qos: .utility)

    /// Writes the queue to disk off the calling thread.
    ///
    /// Held against suspension for the length of the write. This is the write that
    /// records a request as sent, so a process suspended between the response and
    /// this landing rolls the queue back and sends the request again.
    func save(completion: (@Sendable () -> Void)? = nil) {
        BackgroundTaskGuard.shared.begin()
        writeQueue.async { [weak self] in
            self?.saveSync()
            BackgroundTaskGuard.shared.end()
            completion?()
        }
    }

    /// Writes the queue to disk on the calling thread. Used when the process is
    /// about to end, where an async write would not survive.
    func saveSync() {
        // Routed through the same queue as the async path so an in-flight write
        // cannot overtake this one, and so a flush is never undone by a save that
        // snapshotted before it.
        if !isOnWriteQueue {
            writeQueue.sync { writeSnapshot() }
            return
        }
        writeSnapshot()
    }

    private var isOnWriteQueue: Bool {
        DispatchQueue.getSpecific(key: Self.writeQueueKey) != nil
    }

    private static let writeQueueKey = DispatchSpecificKey<Bool>()

    private func writeSnapshot() {
        lock.lock()
        let snapshot = requests
        lock.unlock()

        let payload: [String: Any] = [PersistencyKey.queuedRequests: snapshot]

        let data: Data
        do {
            data = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "saveSync", "the request queue could not be archived and nothing is written, the queue stays in memory only, requestCount: [\(snapshot.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return
        }

        do {
            try data.write(to: fileURL, options: .atomic)
            logger?.d(Self.module, "saveSync", "request queue is written to the persistent storage file, dataSize: [\(data.count)], requestCount: [\(snapshot.count)]")
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "saveSync", "writing the request queue to the persistent storage file failed, the queue stays in memory only, requestCount: [\(snapshot.count)], dataSize: [\(data.count)], path: [\(fileURL.path)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
        }
    }

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Nothing to read is how every first launch starts, so the two are
            // told apart: a file that exists and will not open is the incident.
            let failure = error as NSError
            if FileManager.default.fileExists(atPath: fileURL.path) {
                logger?.d(Self.module, "load", "the persistent storage file exists but could not be opened, the queue starts empty, path: [\(fileURL.path)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            } else {
                logger?.d(Self.module, "load", "no persistent storage file yet, the queue starts empty, path: [\(fileURL.path)]")
            }
            return
        }

        do {
            let root = try CountlyArchive.decodeRoot(from: data)

            if let dictionary = root as? [String: Any],
               let stored = dictionary[PersistencyKey.queuedRequests] as? [String] {
                requests = stored
                logger?.d(Self.module, "load", "persistent storage file is loaded, dataSize: [\(data.count)], restoredRequestCount: [\(requests.count)]")
            } else {
                logger?.d(Self.module, "load", "the persistent storage file does not hold a request queue and will be treated as empty, dataSize: [\(data.count)], rootType: [\(root.map { "\(type(of: $0))" } ?? "none")]")
            }
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "load", "persistent storage file could not be read and will be treated as empty, dataSize: [\(data.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
        }
    }

    /// Deletes the backing file. Used by `halt(clearStorage: true)`.
    ///
    /// Serialized with the writes, so a save that snapshotted before the caller
    /// asked for the data to be erased cannot re-create the file afterwards.
    func deleteFile() {
        writeQueue.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                logger?.d(Self.module, "deleteFile", "there is no persistent storage file of the request queue to delete, path: [\(fileURL.path)]")
                return
            }

            do {
                try FileManager.default.removeItem(at: fileURL)
                logger?.d(Self.module, "deleteFile", "the persistent storage file of the request queue is deleted, path: [\(fileURL.path)]")
            } catch {
                let failure = error as NSError
                logger?.d(Self.module, "deleteFile", "the persistent storage file of the request queue was not deleted, path: [\(fileURL.path)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            }
        }
    }

    private lazy var fileURL: URL = {
        StorageLocation.directoryURL(logger: logger)
            .appendingPathComponent(namespace.fileName("Countly", extension: "dat"))
    }()
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
