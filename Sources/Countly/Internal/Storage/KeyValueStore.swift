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

    // MARK: - Push

    /// Whether the user has granted notification permission, so the SDK can tell
    /// a first grant from a repeat launch.
    var notificationPermission: Bool {
        get { defaults.bool(forKey: namespace.key(PersistencyKey.notificationPermission)) }
        set { set(newValue, PersistencyKey.notificationPermission) }
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

    /// Removes everything this instance owns. Used by `halt(clearStorage: true)`.
    func clearAll() {
        let keys = [
            PersistencyKey.storedDeviceID,
            PersistencyKey.storedNSUUID,
            PersistencyKey.isCustomDeviceID,
            PersistencyKey.notificationPermission,
            PersistencyKey.remoteConfig,
            PersistencyKey.serverConfig,
            PersistencyKey.healthCheckState,
        ] + Self.legacyKeys
        for key in keys {
            defaults.removeObject(forKey: namespace.key(key))
        }
        logger?.d(Self.module, "clearAll", "stored key value state is cleared, keyCount: [\(keys.count)]")
    }

    // MARK: - Helpers

    private func set(_ value: Any?, _ key: String) {
        let namespacedKey = namespace.key(key)
        if let value {
            defaults.set(value, forKey: namespacedKey)
        } else {
            defaults.removeObject(forKey: namespacedKey)
        }
    }

    private func archive(_ value: [String: Any], _ key: String) {
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
            defaults.set(data, forKey: namespace.key(key))
        } catch {
            logger?.d(Self.module, "archive", "value could not be archived and will not be stored, key: [\(key)], error: [\(error.localizedDescription)]")
        }
    }

    private func unarchiveDictionary(_ key: String) -> [String: Any] {
        guard let data = defaults.data(forKey: namespace.key(key)) else { return [:] }
        do {
            let value = try CountlyArchive.decodeRoot(from: data)
            return value as? [String: Any] ?? [:]
        } catch {
            logger?.d(Self.module, "unarchive", "stored value could not be read back and will be treated as empty, key: [\(key)], error: [\(error.localizedDescription)]")
            return [:]
        }
    }
}
