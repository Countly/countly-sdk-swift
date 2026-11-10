//
//  KeyValueStore.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Small persisted values: the device ID, cached remote config, the automatic
/// view tracking state, the health check counters.
///
/// Backed by `UserDefaults`. Every key goes through the instance's namespace, so
/// the default instance reads and writes exactly the keys earlier Countly SDKs
/// used and a named instance cannot see them.
final class KeyValueStore {

    private let namespace: StorageNamespace
    private let defaults: UserDefaults
    private weak var logger: Logger?

    private static let module = "KeyValueStore"

    /// Guards `isClosed` and nothing else. Never held across a `UserDefaults`
    /// call: those post their change notification synchronously on the writing
    /// thread, and an observer waiting on another thread would then deadlock
    /// against a write or an erasure on that thread.
    private let closeLock = NSLock()

    /// Set by `close()` and never reset. A restart builds a new store, so any write
    /// reaching this one afterwards comes from the halted instance, such as a
    /// completion that was still in flight, and would overwrite what the next
    /// start reads or put back what was erased.
    private var isClosed = false

    init(namespace: StorageNamespace, defaults: UserDefaults = .standard, logger: Logger?) {
        self.namespace = namespace
        self.defaults = defaults
        self.logger = logger
    }

    // MARK: - Device ID

    var deviceID: String? {
        get { defaults.string(forKey: namespace.key(PersistencyKey.storedDeviceID)) }
        set { set(newValue, PersistencyKey.storedDeviceID) }
    }

    /// The SDK generated UUID, kept separate from the active device ID so that
    /// switching to a custom ID and back returns the same generated value.
    var generatedUUID: String? {
        get { defaults.string(forKey: namespace.key(PersistencyKey.storedNSUUID)) }
        set { set(newValue, PersistencyKey.storedNSUUID) }
    }

    /// Whether the active device ID was supplied by the host application.
    var isCustomDeviceID: Bool {
        get { defaults.bool(forKey: namespace.key(PersistencyKey.isCustomDeviceID)) }
        set { set(newValue, PersistencyKey.isCustomDeviceID) }
    }

    /// The device ID in use before temporary device ID mode was entered at
    /// runtime, which leaving the mode without a new ID returns to. `nil` when the
    /// mode started at init with no earlier ID.
    var preTemporaryDeviceID: String? {
        get { defaults.string(forKey: namespace.key(PersistencyKey.preTemporaryDeviceID)) }
        set { set(newValue, PersistencyKey.preTemporaryDeviceID) }
    }

    /// Whether ``preTemporaryDeviceID`` was supplied by the host application.
    var preTemporaryIsCustomDeviceID: Bool {
        get { defaults.bool(forKey: namespace.key(PersistencyKey.preTemporaryIsCustomDeviceID)) }
        set { set(newValue, PersistencyKey.preTemporaryIsCustomDeviceID) }
    }

    // MARK: - Push

    /// Whether the user has granted notification permission, so the SDK can tell
    /// a first grant from a repeat launch.
    var notificationPermission: Bool {
        get { defaults.bool(forKey: namespace.key(PersistencyKey.notificationPermission)) }
        set { set(newValue, PersistencyKey.notificationPermission) }
    }

    /// The device ID the last push token was sent for, so the token can be taken
    /// back from that user when they leave. `nil` once it was cleared.
    var pushTokenDeviceID: String? {
        get { defaults.string(forKey: namespace.key(PersistencyKey.pushTokenDeviceID)) }
        set { set(newValue, PersistencyKey.pushTokenDeviceID) }
    }

    /// Notification taps that arrived before the SDK started, each with its
    /// notification ID, tapped button and time, until they are recorded.
    var pendingPushActions: [[String: Any]] {
        get { defaults.array(forKey: namespace.key(PersistencyKey.pendingPushActions)) as? [[String: Any]] ?? [] }
        set { set(newValue.isEmpty ? nil : newValue, PersistencyKey.pendingPushActions) }
    }

    // MARK: - Remote config

    /// Cached remote config values, archived because they hold arbitrary JSON.
    var remoteConfig: [String: Any] {
        get { unarchiveDictionary(PersistencyKey.remoteConfig) }
        set { archive(newValue, PersistencyKey.remoteConfig) }
    }

    // MARK: - Server behavior settings

    var serverConfig: [String: Any]? {
        get { defaults.dictionary(forKey: namespace.key(PersistencyKey.serverConfig)) }
        set { set(newValue, PersistencyKey.serverConfig) }
    }

    // MARK: - Events

    /// The event queue: the events recorded and not yet moved into a request,
    /// each as the JSON it is sent as. Written on every change, so recorded events
    /// survive the application being closed or killed before they are sent.
    var recordedEvents: [String] {
        get { defaults.stringArray(forKey: namespace.key(PersistencyKey.recordedEvents)) ?? [] }
        set { _ = write(newValue.isEmpty ? nil : newValue, PersistencyKey.recordedEvents, function: "recordedEvents") }
    }

    // MARK: - Health check

    /// Error and warning counters carried across launches.
    ///
    /// Never logged at error or warning level: the health tracker owns these
    /// counters, and logging at those levels here would repopulate the very
    /// numbers this write is clearing.
    var healthCheckState: [String: Any]? {
        get { defaults.dictionary(forKey: namespace.key(PersistencyKey.healthCheckState)) }
        set { set(newValue, PersistencyKey.healthCheckState) }
    }

    // MARK: - Lifecycle

    /// Keys this SDK never writes but an earlier Countly SDK did.
    ///
    /// The default instance uses the empty namespace, so it reads and writes the
    /// exact key strings `countly-sdk-ios` used. An application migrating from it
    /// carries that SDK's leftovers, and one of them holds a real device
    /// identifier, so an erasure that only cleared what this SDK writes would leave
    /// it behind for good.
    private static let legacyKeys = [
        "kCountlyStarRatingStatusKey",
        "kCountlyWatchParentDeviceIDKey",
        "kCountlyStartedEventsPersistencyKey",
    ]

    /// Refuses every write from now on, keeping what is stored. Used by every halt,
    /// so the halted instance cannot write over what the next start reads.
    func close() {
        closeLock.lock()
        isClosed = true
        closeLock.unlock()
    }

    /// Closes the store and removes everything this instance owns. Used by
    /// `halt(clearStorage: true)`.
    func clearAll() {
        let keys = [
            PersistencyKey.storedDeviceID,
            PersistencyKey.storedNSUUID,
            PersistencyKey.isCustomDeviceID,
            PersistencyKey.notificationPermission,
            PersistencyKey.remoteConfig,
            PersistencyKey.serverConfig,
            PersistencyKey.healthCheckState,
            PersistencyKey.recordedEvents,
            PersistencyKey.preTemporaryDeviceID,
            PersistencyKey.preTemporaryIsCustomDeviceID,
            PersistencyKey.pushTokenDeviceID,
            PersistencyKey.pendingPushActions,
        ] + Self.legacyKeys

        // Closed before the removal: a write already past its check takes itself
        // back once it sees the flag, so nothing written outlives the erasure.
        close()

        // Counted before the removal, because an erasure that was asked for and
        // found nothing to erase is a different answer to "was my data deleted"
        // than one that cleared a stored device ID.
        let clearedKeys = keys.filter { defaults.object(forKey: namespace.key($0)) != nil }
        for key in keys {
            defaults.removeObject(forKey: namespace.key(key))
        }

        logger?.d(Self.module, "clearAll", "stored key value state is cleared, keyCount: [\(keys.count)], clearedKeyCount: [\(clearedKeys.count)], clearedKeys: [\(clearedKeys.joined(separator: ", "))]")
    }

    // MARK: - Helpers

    /// Never logs at error or warning level, whatever goes wrong: the health
    /// tracker persists its counters through here from its own queue, and those
    /// two levels would count the write as another incident.
    private func set(_ value: Any?, _ key: String) {
        guard write(value, key, function: "set") else { return }

        if let value {
            logger?.d(Self.module, "set", "a value is written to the key value store, key: [\(key)], valueType: [\(type(of: value))]")
        } else {
            logger?.d(Self.module, "set", "a key is removed from the key value store, key: [\(key)]")
        }
    }

    /// Whether `close()` has run.
    private var closed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return isClosed
    }

    /// Stores `value` under `key`, or removes the key for `nil`, unless the store
    /// is closed.
    ///
    /// The flag is checked on both sides of the write rather than held across it,
    /// because `UserDefaults` runs change observers inside the write. A write that
    /// raced `clearAll()` and landed after the erasure removes itself again.
    ///
    /// - Returns: Whether the value was kept.
    private func write(_ value: Any?, _ key: String, function: String) -> Bool {
        let namespacedKey = namespace.key(key)
        guard !closed else {
            logger?.d(Self.module, function, "the write is dropped, the store is closed by a halt, key: [\(key)]")
            return false
        }

        defaults.set(value, forKey: namespacedKey)

        guard !closed else {
            defaults.removeObject(forKey: namespacedKey)
            logger?.d(Self.module, function, "the write is taken back, the store was closed by a halt while it ran, key: [\(key)]")
            return false
        }
        return true
    }

    private func archive(_ value: [String: Any], _ key: String) {
        do {
            let data = try CountlyArchive.encodeRoot(value)
            guard write(data, key, function: "archive") else { return }
            logger?.d(Self.module, "archive", "value is archived into the key value store, key: [\(key)], entryCount: [\(value.count)], dataSize: [\(data.count)]")
        } catch {
            let failure = error as NSError
            logger?.e(Self.module, "archive", "value could not be archived and is not stored, key: [\(key)], entryCount: [\(value.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
        }
    }

    private func unarchiveDictionary(_ key: String) -> [String: Any] {
        guard let data = defaults.data(forKey: namespace.key(key)) else {
            logger?.d(Self.module, "unarchive", "nothing is archived under this key yet, key: [\(key)]")
            return [:]
        }

        do {
            let value = try CountlyArchive.decodeRoot(from: data)
            guard let dictionary = value as? [String: Any] else {
                logger?.w(Self.module, "unarchive", "the archived value is not a dictionary and will be treated as empty, key: [\(key)], dataSize: [\(data.count)]")
                return [:]
            }
            logger?.d(Self.module, "unarchive", "archived value is read back from the key value store, key: [\(key)], entryCount: [\(dictionary.count)], dataSize: [\(data.count)]")
            return dictionary
        } catch {
            let failure = error as NSError
            logger?.w(Self.module, "unarchive", "stored value could not be read back and will be treated as empty, key: [\(key)], dataSize: [\(data.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return [:]
        }
    }
}
