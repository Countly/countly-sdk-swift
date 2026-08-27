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
final class RequestQueueStore {

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
    var storedRequestsLimit: Int = 1000

    /// Requests older than this are dropped. Zero disables age based dropping.
    var requestDropAgeHours: Int = 0

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

    /// Appends a request, dropping older ones if the queue is over its limit.
    ///
    /// - Parameters:
    ///   - queryString: The request body, without the app version.
    ///   - appVersion: Stamped onto the request now rather than at send time, so
    ///     a request queued before an app update still reports the version it was
    ///     produced under.
    ///   - trackingEnabled: When the server has switched tracking off, the
    ///     request is discarded instead of queued.
    func enqueue(_ queryString: String, appVersion: String, trackingEnabled: Bool) {
        guard trackingEnabled else {
            logger?.d(Self.module, "enqueue", "request is not queued, reason: SDK tracking is disabled from server config, queryStringLength: [\(queryString.count)]")
            return
        }

        guard !queryString.isEmpty else {
            logger?.d(Self.module, "enqueue", "request is not queued, reason: query string is nil or empty")
            return
        }

        let stamped = queryString + "&\(QS.appVersion)=\(appVersion)"

        lock.lock()
        defer { lock.unlock() }

        if requests.count >= storedRequestsLimit {
            removeOldAgeRequestsLocked()

            if requests.count >= storedRequestsLimit {
                // Drop at most one loop limit's worth per pass, plus the one slot
                // this request needs.
                let exceeded = requests.count - storedRequestsLimit
                let removeCount = min(min(exceeded, Self.removalLoopLimit) + 1, requests.count)
                logger?.d(Self.module, "enqueue", "request queue size: [\(requests.count)] exceeded the limit: [\(storedRequestsLimit)], the first [\(removeCount)] request(s) will be dropped")
                requests.removeFirst(removeCount)
            }
        }

        requests.append(stamped)
        logger?.v(Self.module, "enqueue", "request is queued, queryStringLength: [\(stamped.count)], queueSize: [\(requests.count)]")
    }

    /// Removes the request at the head of the queue, but only if it still is the
    /// one the caller sent. A request that moved is left alone.
    func removeHead(_ queryString: String) {
        lock.lock()
        defer { lock.unlock() }

        guard requests.first == queryString else { return }
        requests.removeFirst()
        logger?.d(Self.module, "removeHead", "request at the head of the queue is removed, remainingRequestCount: [\(requests.count)]")
    }

    /// Drops every queued request.
    func flush() {
        lock.lock()
        defer { lock.unlock() }

        if !requests.isEmpty {
            logger?.d(Self.module, "flush", "request queue is being flushed, [\(requests.count)] queued request(s) will be dropped")
        }
        requests.removeAll()
    }

    /// Rewrites queued requests that carry the temporary device ID so they report
    /// the real one, which is how data recorded before a real ID was known still
    /// lands on the right user.
    func replaceTemporaryDeviceIDs(with deviceID: String, typeValue: Int) {
        lock.lock()
        defer { lock.unlock() }

        logger?.d(Self.module, "replaceTemporaryDeviceIDs", "replacing the temporary device ID in the queued requests, queuedRequestCount: [\(requests.count)]")

        let temporaryID = "&\(QS.deviceID)=\(TemporaryDeviceID.value)"
        let realID = "&\(QS.deviceID)=\(deviceID.urlEscaped)"
        let temporaryType = "&\(QS.deviceIDType)=\(DeviceIDType.temporary.wireValue)"
        let realType = "&\(QS.deviceIDType)=\(typeValue)"

        isBeingModified = true
        for index in requests.indices where requests[index].contains(temporaryID) {
            logger?.v(Self.module, "replaceTemporaryDeviceIDs", "a queued request with the temporary device ID is replaced with the real device ID, requestIndex: [\(index)]")
            requests[index] = requests[index]
                .replacingOccurrences(of: temporaryID, with: realID)
                .replacingOccurrences(of: temporaryType, with: realType)
        }
        isBeingModified = false
    }

    /// Rewrites queued requests recorded under a different app key so they report
    /// the current one.
    func replaceAllAppKeys(with appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        logger?.d(Self.module, "replaceAllAppKeys", "replacing different app keys in the queued requests, queuedRequestCount: [\(requests.count)]")

        let escaped = appKey.urlEscaped
        isBeingModified = true
        for index in requests.indices {
            guard let existing = Self.appKey(in: requests[index]), existing != escaped else { continue }
            logger?.v(Self.module, "replaceAllAppKeys", "a queued request with a different app key is replaced with the current app key, requestIndex: [\(index)]")
            requests[index] = requests[index].replacingOccurrences(
                of: "\(QS.appKey)=\(existing)",
                with: "\(QS.appKey)=\(escaped)")
        }
        isBeingModified = false
    }

    /// Drops queued requests recorded under a different app key.
    func removeDifferentAppKeys(than appKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let before = requests.count
        let escaped = appKey.urlEscaped
        isBeingModified = true
        requests = requests.filter { request in
            let isSame = Self.appKey(in: request) == escaped
            if !isSame {
                logger?.v(Self.module, "removeDifferentAppKeys", "a queued request with a different app key will be dropped")
            }
            return isSame
        }
        isBeingModified = false

        if before > requests.count {
            logger?.w(Self.module, "removeDifferentAppKeys", "dropped [\(before - requests.count)] queued request(s) with a different app key, remainingRequestCount: [\(requests.count)]")
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
        guard requestDropAgeHours > 0 else { return false }
        return isOldRequestInternal(queryString)
    }

    private func removeOldAgeRequestsLocked() {
        guard requestDropAgeHours > 0 else { return }

        let before = requests.count
        isBeingModified = true
        requests = requests.filter { !isOldRequestInternal($0) }
        isBeingModified = false

        if before > requests.count {
            logger?.d(Self.module, "removeOldAgeRequests", "dropped [\(before - requests.count)] old age queued request(s), requestDropAgeHours: [\(requestDropAgeHours)], remainingRequestCount: [\(requests.count)]")
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
        let ageHours = queryString.requestAgeSeconds / 3600.0
        let isOld = ageHours >= Double(requestDropAgeHours)
        if isOld {
            logger?.v(Self.module, "isOldRequest", "a queued request exceeded the request drop age and will be dropped, requestAgeHours: [\(String(format: "%.2f", ageHours))], requestDropAgeHours: [\(requestDropAgeHours)]")
        }
        return isOld
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
    func save(completion: (() -> Void)? = nil) {
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

        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: payload, requiringSecureCoding: false)
            let success = (try? data.write(to: fileURL, options: .atomic)) != nil
            logger?.d(Self.module, "saveSync", "request queue is written to the persistent storage file, success: [\(success)], dataSize: [\(data.count)], requestCount: [\(snapshot.count)]")
        } catch {
            logger?.d(Self.module, "saveSync", "writing the request queue to the persistent storage file failed, requestCount: [\(snapshot.count)], error: [\(error.localizedDescription)]")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()

            if let dictionary = root as? [String: Any],
               let stored = dictionary[PersistencyKey.queuedRequests] as? [String] {
                requests = stored
                logger?.d(Self.module, "load", "persistent storage file is loaded, dataSize: [\(data.count)], restoredRequestCount: [\(requests.count)]")
            }
        } catch {
            logger?.d(Self.module, "load", "persistent storage file could not be read and will be treated as empty, error: [\(error.localizedDescription)]")
        }
    }

    /// Deletes the backing file. Used by `halt(clearStorage: true)`.
    ///
    /// Serialized with the writes, so a save that snapshotted before the caller
    /// asked for the data to be erased cannot re-create the file afterwards.
    func deleteFile() {
        writeQueue.sync {
            try? FileManager.default.removeItem(at: fileURL)
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
