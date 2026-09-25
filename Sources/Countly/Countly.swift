//
//  Countly.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if canImport(UserNotifications)
import UserNotifications
#endif

/// Entry point of the SDK and registry of its instances.
///
/// Most applications only ever need `Countly.shared`. An application that reports
/// to more than one app key or server, or that hosts more than one tenant, uses
/// `Countly.instance(named:)` to get a second, fully independent SDK.
///
/// Getting an instance never starts it. Starting is always an explicit
/// `start(with:)` by the caller, so an accidental reference cannot begin
/// collecting data.
public enum Countly {

    /// Registry key of the default instance.
    ///
    /// The `[CLY]_` prefix is reserved, so an application choosing its own names
    /// cannot collide with it.
    public static let defaultInstanceName = StorageNamespace.defaultInstanceName

    private static let lock = NSLock()
    nonisolated(unsafe) private static var instances: [String: CountlyInstance] = [:]

    // MARK: - Access

    /// The default instance.
    ///
    /// Its data lives under the same paths and keys earlier Countly SDKs used, so
    /// an application upgrading from one keeps its device ID and its queued
    /// requests.
    public static var shared: CountlyInstance {
        instance(named: defaultInstanceName)
    }

    /// The instance under this name, created uninitialized if it does not exist.
    ///
    /// A natural choice of name is the app key, which gives one isolated instance
    /// per dashboard application. Passing `nil` or an empty name returns the
    /// default instance.
    public static func instance(named name: String?) -> CountlyInstance {
        var key = defaultInstanceName
        if let name, !name.isEmpty {
            key = name
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = instances[key] { return existing }

        let created = CountlyInstance(name: key)
        instances[key] = created
        return created
    }

    /// The instance under this name, or `nil` when it does not exist.
    ///
    /// Unlike `instance(named:)` this never creates one, which is what a caller
    /// checking whether an instance was set up should use.
    public static func getInstance(named name: String) -> CountlyInstance? {
        lock.lock()
        defer { lock.unlock() }
        return instances[name]
    }

    /// Every named instance, excluding the default one.
    public static func listInstances() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return instances.keys.filter { $0 != defaultInstanceName }.sorted()
    }

    /// Halts every instance.
    ///
    /// Intended for tests and for tearing an application down deliberately.
    /// Halting the default instance leaves it started-but-empty, so anything still
    /// holding a reference to it will find its calls ignored until it is started
    /// again.
    ///
    /// - Parameter clearStorage: When `true`, every instance's persisted data is
    ///   erased as well.
    public static func haltAllInstances(clearStorage: Bool = false) {
        lock.lock()
        let all = Array(instances.values)
        lock.unlock()

        for instance in all {
            instance.halt(clearStorage: clearStorage)
        }
    }

    /// Stops a named instance and drops it from the registry.
    ///
    /// The next `instance(named:)` under the same name hands back a fresh,
    /// unstarted instance. Stored data is kept: deregistering must not throw away
    /// what the instance recorded but has not sent yet, so a caller who wants it
    /// gone calls `halt(clearStorage: true)` on the instance first. The default
    /// instance cannot be removed; `halt()` resets it.
    public static func removeInstance(named name: String?) {
        guard let name, !name.isEmpty, name != defaultInstanceName else {
            Logger.print("[Warning] [Countly] removeInstance, the default instance can not be removed, use halt() to reset it, the call is ignored")
            return
        }

        // Deregistered under the same lock `instance(named:)` creates under, and
        // before the halt, so a concurrent creation gets a fresh object rather than
        // the one being torn down.
        lock.lock()
        let removed = instances.removeValue(forKey: name)
        lock.unlock()

        guard let removed else {
            Logger.print("[Debug] [Countly] removeInstance, no instance is registered under the name, nothing to remove, name: [\(name)]")
            return
        }

        // Outside the lock: the halt does real work and must not block creation.
        removed.halt(clearStorage: false)
    }

    // MARK: - Push notification plumbing

    #if os(iOS) || os(visionOS) || os(macOS)
    /// Hands the SDK the device token.
    ///
    /// The SDK takes this callback over automatically and always calls the host
    /// application's own implementation afterwards, so this only has to be called
    /// when `CountlyConfig.disableAutomaticPushHandling` is set. Calling it anyway
    /// is harmless.
    public static func didRegisterForRemoteNotifications(deviceToken: Data) {
        PushRuntime.shared.didRegisterForRemoteNotifications(deviceToken: deviceToken)
    }

    /// Tells the SDK registration failed.
    ///
    /// As with the success callback, this is taken over automatically unless
    /// `CountlyConfig.disableAutomaticPushHandling` is set. The SDK reports an
    /// empty token, which stops the server trying to reach a device that cannot
    /// receive anything.
    public static func didFailToRegisterForRemoteNotifications(error: Error) {
        PushRuntime.shared.didFailToRegisterForRemoteNotifications()
    }

    #if canImport(UserNotifications)
    /// Reports a notification the user acted on, as if the SDK had received the
    /// response itself. Needed only when something else owns the
    /// `UNUserNotificationCenter` delegate, or to replay a tap that arrived before
    /// `start(with:)`. A response without a Countly payload is ignored.
    public static func handleNotificationResponse(_ response: UNNotificationResponse) {
        PushRuntime.shared.handle(response: response)
    }
    #endif
    #endif
}
