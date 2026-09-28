//
//  LegacyStorageMigrationTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Proves this SDK is a drop-in replacement for `countly-sdk-ios` at the storage
/// level: an application that swaps the Objective-C SDK for this one keeps its
/// device ID, its queued requests, its cached remote config, its behavior
/// settings and its health counters.
///
/// The fixtures were not written by Swift. `Countly.dat` and the remote config
/// archive below are the bytes an Objective-C program produced with the exact
/// code `CountlyPersistency` uses (`archivedDataWithRootObject:` over an
/// `NSMutableArray` of query strings, and archived `CountlyRCData` objects), so
/// the decode path is tested against the real legacy format rather than against
/// what Swift thinks that format is.
final class LegacyStorageMigrationTests: CountlyBaseTestCase {

    /// `[NSKeyedArchiver archivedDataWithRootObject:@{kCountlyQueuedRequestsPersistencyKey: queuedRequests}]`
    /// with three requests: a `begin_session`, an `events` request, and one held
    /// under `CLYTemporaryDeviceID`.
    private static let legacyQueueFile = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGpCwwVFhwdHh8mVSRudWxs0w0ODxASFFdOUy5rZXlzWk5TLm9iamVjdHNWJGNsYXNzoRGAAqETgAOACF8QJGtDb3VudGx5UXVldWVkUmVxdWVzdHNQZXJzaXN0ZW5jeUtledIODxcboxgZGoAEgAWABoAHXxCqYXBwX2tleT1sZWdhY3lLZXkmZGV2aWNlX2lkPUxFR0FDWS1ERVZJQ0UtMSZ0aW1lc3RhbXA9MTcwMDAwMDAwMDAwMCZob3VyPTEwJmRvdz0xJnR6PTE4MCZzZGtfdmVyc2lvbj0yNS40LjAmc2RrX25hbWU9b2JqYy1uYXRpdmUtaW9zJmJlZ2luX3Nlc3Npb249MSZtZXRyaWNzPSU3QiU3RCZhdj0xLjBfEMlhcHBfa2V5PWxlZ2FjeUtleSZkZXZpY2VfaWQ9TEVHQUNZLURFVklDRS0xJnRpbWVzdGFtcD0xNzAwMDAwMDAxMDAwJmhvdXI9MTAmZG93PTEmdHo9MTgwJnNka192ZXJzaW9uPTI1LjQuMCZzZGtfbmFtZT1vYmpjLW5hdGl2ZS1pb3MmZXZlbnRzPSU1QiU3QiUyMmtleSUyMiUzQSUyMmxlZ2FjeSUyMiUyQyUyMmNvdW50JTIyJTNBMSU3RCU1RCZhdj0xLjBfELVhcHBfa2V5PWxlZ2FjeUtleSZkZXZpY2VfaWQ9Q0xZVGVtcG9yYXJ5RGV2aWNlSUQmdD05JnRpbWVzdGFtcD0xNzAwMDAwMDAyMDAwJmhvdXI9MTAmZG93PTEmdHo9MTgwJnNka192ZXJzaW9uPTI1LjQuMCZzZGtfbmFtZT1vYmpjLW5hdGl2ZS1pb3MmZW5kX3Nlc3Npb249MSZzZXNzaW9uX2R1cmF0aW9uPTUmYXY9MS4w0iAhIiNaJGNsYXNzbmFtZVgkY2xhc3Nlc15OU011dGFibGVBcnJheaMiJCVXTlNBcnJheVhOU09iamVjdNIgIScoXE5TRGljdGlvbmFyeaInJQAIABEAGgAkACkAMgA3AEkATABRAFMAXQBjAGoAcgB9AIQAhgCIAIoAjACOALUAugC+AMAAwgDEAMYBcwI/AvcC/AMHAxADHwMjAysDNAM5A0YAAAAAAAACAQAAAAAAAAApAAAAAAAAAAAAAAAAAAADSQ==")!

    /// `[NSKeyedArchiver archivedDataWithRootObject:cachedRemoteConfig]` where the
    /// values are `CountlyRCData`: `theme` = "dark" (current), `seats` = [1, 2]
    /// (stale), `flags` = {nested: true} (current), `empty` = NSNull (current).
    private static let legacyRemoteConfigArchive = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGvEBcLDBscHR4fJSorLDI2OkA4QkVJS05SU1UkbnVsbNMNDg8QFRpXTlMua2V5c1pOUy5vYmplY3RzViRjbGFzc6QREhMUgAKAA4AEgAWkFhcYGYAGgAyAEYAUgBZVc2VhdHNVZmxhZ3NVZW1wdHlVdGhlbWXTICEPIiMkVXZhbHVlXxASaXNDdXJyZW50VXNlcnNEYXRhgAcIgAvSDg8mKaInKIAIgAmAChABEALSLS4vMFokY2xhc3NuYW1lWCRjbGFzc2VzV05TQXJyYXmiLzFYTlNPYmplY3TSLS4zNF1Db3VudGx5UkNEYXRhojUxXUNvdW50bHlSQ0RhdGHTICEPNzgkgA0JgAvTDQ4POz0/oTyADqE+gA+AEFZuZXN0ZWQJ0i0uQ0RcTlNEaWN0aW9uYXJ5okMx0yAhD0Y4JIASCYAL0Q9KgBPSLS5MTVZOU051bGyiTDHTICEPTzgkgBUJgAtUZGFya9ItLlRVXxATTlNNdXRhYmxlRGljdGlvbmFyeaNUQzEACAARABoAJAApADIANwBJAEwAUQBTAG0AcwB6AIIAjQCUAJkAmwCdAJ8AoQCmAKgAqgCsAK4AsAC2ALwAwgDIAM8A1QDqAOwA7QDvAPQA9wD5APsA/QD/AQEBBgERARoBIgElAS4BMwFBAUQBUgFZAVsBXAFeAWUBZwFpAWsBbQFvAXYBdwF8AYkBjAGTAZUBlgGYAZsBnQGiAakBrAGzAbUBtgG4Ab0BwgHYAAAAAAAAAgEAAAAAAAAAVgAAAAAAAAAAAAAAAAAAAdw=")!

    private static let legacyDeviceID = "LEGACY-DEVICE-1"

    private var seededNamespaces: [StorageNamespace] = []

    override func setUp() {
        super.setUp()
        // Nothing may leave the device, so the queue keeps whatever it loaded and
        // the assertions on it cannot race the drain.
        MockURLProtocol.fail { _ in .notConnectedToInternet }
    }

    override func tearDown() {
        for namespace in seededNamespaces {
            RequestQueueStore(namespace: namespace, logger: nil).deleteFile()
            KeyValueStore(namespace: namespace, logger: nil).clearAll()
        }
        seededNamespaces.removeAll()
        super.tearDown()
    }

    // MARK: - Seeding what the Objective-C SDK left behind

    /// Writes the fixtures under the exact key strings and file name the
    /// Objective-C SDK used, only namespaced so tests do not touch the real default
    /// store of the test host.
    private func seedLegacyStorage(_ namespace: StorageNamespace, isCustomDeviceID: Bool) throws {
        seededNamespaces.append(namespace)
        let defaults = UserDefaults.standard

        try Self.legacyQueueFile.write(to: legacyQueueFileURL(namespace), options: .atomic)

        defaults.set(Self.legacyDeviceID, forKey: namespace.key("kCountlyStoredDeviceIDKey"))
        defaults.set(isCustomDeviceID, forKey: namespace.key("kCountlyIsCustomDeviceIDKey"))
        defaults.set(Self.legacyDeviceID, forKey: namespace.key("kCountlyStoredNSUUIDKey"))
        defaults.set(true, forKey: namespace.key("kCountlyNotificationPermissionKey"))
        defaults.set(Self.legacyRemoteConfigArchive, forKey: namespace.key("kCountlyRemoteConfigKey"))
        defaults.set(["v": 1, "t": 1_700_000_000, "c": ["tracking": true, "rqs": 7, "eqs": 3]] as [String: Any],
                     forKey: namespace.key("kCountlyServerConfigPersistencyKey"))
        defaults.set(["LErr": 3, "LWar": 5, "RStatC": 500, "REMsg": "boom", "BReq": 1, "CBReq": 2] as [String: Any],
                     forKey: namespace.key("kCountlyHealthCheckStatePersistencyKey"))
    }

    // MARK: - Tests

    /// The default instance has to land on the same file and keys, or nothing
    /// below would apply to a real migration.
    func testTheDefaultInstanceReadsTheObjectiveCSDKsFileAndKeys() {
        let namespace = StorageNamespace.default

        XCTAssertEqual(legacyQueueFileURL(namespace).lastPathComponent, "Countly.dat")
        XCTAssertEqual(namespace.key(PersistencyKey.storedDeviceID), "kCountlyStoredDeviceIDKey")
        XCTAssertEqual(namespace.key(PersistencyKey.storedNSUUID), "kCountlyStoredNSUUIDKey")
        XCTAssertEqual(namespace.key(PersistencyKey.isCustomDeviceID), "kCountlyIsCustomDeviceIDKey")
        XCTAssertEqual(namespace.key(PersistencyKey.remoteConfig), "kCountlyRemoteConfigKey")
        XCTAssertEqual(namespace.key(PersistencyKey.serverConfig), "kCountlyServerConfigPersistencyKey")
        XCTAssertEqual(namespace.key(PersistencyKey.healthCheckState), "kCountlyHealthCheckStatePersistencyKey")
        XCTAssertEqual(namespace.key(PersistencyKey.notificationPermission), "kCountlyNotificationPermissionKey")
        XCTAssertEqual(PersistencyKey.queuedRequests, "kCountlyQueuedRequestsPersistencyKey")
        XCTAssertEqual(TemporaryDeviceID.value, "CLYTemporaryDeviceID")

        // Same directory rule as CountlyPersistency.storageDirectoryURL.
        let directory = StorageLocation.directoryURL(logger: nil)
        #if os(tvOS)
        XCTAssertTrue(directory.path.contains("/Caches"))
        #else
        XCTAssertTrue(directory.path.contains("/Application Support"))
        #endif
        #if os(macOS)
        XCTAssertEqual(directory.lastPathComponent, Bundle.main.bundleIdentifier)
        #endif
    }

    /// The queue file written by `CountlyPersistency.saveToFileSync` loads with
    /// every request intact and in order.
    func testAQueueFileWrittenByTheObjectiveCSDKIsLoadedIntact() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let store = openStore(namespace)

        XCTAssertEqual(store.count, 3, "requests queued by the previous SDK were lost")
        let timestamps = store.snapshot.map { TestUtils.parseQuery($0)["timestamp"] as? String }
        XCTAssertEqual(timestamps, ["1700000000000", "1700000001000", "1700000002000"], "queue order changed on load")
        XCTAssertEqual(TestUtils.parseQuery(store.snapshot[0])["device_id"] as? String, Self.legacyDeviceID)
        XCTAssertEqual(TestUtils.parseQuery(store.snapshot[0])["begin_session"] as? String, "1")
        XCTAssertEqual(TestUtils.parseQuery(store.snapshot[2])["device_id"] as? String, TemporaryDeviceID.value)

        // What this SDK writes back has to be readable by a second load too, so a
        // migrated queue survives more than one launch.
        store.saveSync()
        XCTAssertEqual(openStore(namespace).count, 3)
    }

    /// A full start on top of the Objective-C SDK's storage: the developer supplied
    /// device ID stays, the config's ID does not replace it, and the held requests
    /// are still there afterwards.
    func testStartingOverTheObjectiveCSDKsStorageKeepsTheDeveloperSuppliedIdentity() throws {
        let name = uniqueInstanceName()
        let namespace = StorageNamespace(instanceName: name)
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let config = baseConfig(instanceName: name)
        config.deviceID = "id-the-new-integration-passes"
        let countly = start(config)

        XCTAssertEqual(countly.deviceID.current, Self.legacyDeviceID, "the stored identity was replaced, this splits the user's history")
        XCTAssertEqual(countly.deviceID.type, .developerSupplied)
        XCTAssertEqual(countly.deviceID.type?.wireValue, 0, "same `t` the Objective-C SDK reported for a custom ID")
        XCTAssertFalse(countly.deviceID.isTemporaryIDMode)

        let queue = requestQueue(of: countly)
        XCTAssertGreaterThanOrEqual(queue.count, 3)
        let legacyInQueue = queue.filter { TestUtils.parseQuery($0)["sdk_name"] as? String == "objc-native-ios" }
        XCTAssertEqual(legacyInQueue.count, 3, "requests queued by the previous SDK were dropped at start")
        XCTAssertEqual(TestUtils.parseQuery(queue[0])["begin_session"] as? String, "1", "the legacy queue no longer comes first")
    }

    /// An SDK generated identity: the stored ID equals the stored UUID and the
    /// custom flag is off. It has to come back as the same string and be reported
    /// with the same `t` value the Objective-C SDK used on iOS for it.
    func testStartingOverTheObjectiveCSDKsStorageKeepsTheGeneratedIdentity() throws {
        let name = uniqueInstanceName()
        let namespace = StorageNamespace(instanceName: name)
        try seedLegacyStorage(namespace, isCustomDeviceID: false)

        let config = baseConfig(instanceName: name)
        config.deviceID = nil
        let countly = start(config)

        XCTAssertEqual(countly.deviceID.current, Self.legacyDeviceID)
        XCTAssertEqual(countly.deviceID.type, .sdkGenerated)
        XCTAssertEqual(countly.deviceID.type?.wireValue, 1)
    }

    /// Everything else in `UserDefaults`: the remote config cache written as
    /// archived `CountlyRCData`, the behavior settings dictionary, the health
    /// counters and the notification permission flag.
    func testStartingOverTheObjectiveCSDKsStorageKeepsCachedState() throws {
        let name = uniqueInstanceName()
        let namespace = StorageNamespace(instanceName: name)
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let countly = start(baseConfig(instanceName: name))
        let core = core(of: countly)

        // Remote config, including the stale marker and a nil value.
        XCTAssertEqual(countly.remoteConfig.getValue("theme").value as? String, "dark")
        XCTAssertTrue(countly.remoteConfig.getValue("theme").isCurrentUsersData)
        XCTAssertEqual((countly.remoteConfig.getValue("seats").value as? [Any])?.compactMap(TestUtils.int), [1, 2])
        XCTAssertFalse(countly.remoteConfig.getValue("seats").isCurrentUsersData, "another user's value now reads as this one's")
        XCTAssertEqual((countly.remoteConfig.getValue("flags").value as? [String: Any])?["nested"] as? Bool, true)
        XCTAssertNil(countly.remoteConfig.getValue("empty").value)
        XCTAssertEqual(countly.remoteConfig.getAllValues().count, 4)

        // Behavior settings the previous SDK cached are applied before any fetch.
        XCTAssertEqual(core.serverConfig.requestQueueSize, 7)
        XCTAssertEqual(core.serverConfig.eventQueueSize, 3)
        XCTAssertTrue(core.serverConfig.trackingEnabled)

        // Health counters and the push flag are read through the same store.
        let store = KeyValueStore(namespace: namespace, logger: nil)
        XCTAssertEqual(store.healthCheckState?["LErr"] as? Int, 3)
        XCTAssertEqual(store.healthCheckState?["REMsg"] as? String, "boom")
        XCTAssertTrue(store.notificationPermission)
        XCTAssertEqual(store.deviceID, Self.legacyDeviceID)
        XCTAssertTrue(store.isCustomDeviceID)
    }

    // MARK: - Going back to the Objective-C SDK

    /// A store that keeps `Countly.dat` current, as the default instance does. The
    /// tests run on named namespaces so they never touch the test host's own file.
    private func mirroringStore(_ namespace: StorageNamespace) -> RequestQueueStore {
        openStore(namespace, mirrorsLegacyFile: true)
    }

    /// The queue as `CountlyPersistency` reads it: the one key, nothing else.
    private func queueAsTheObjectiveCSDKReadsIt(_ namespace: StorageNamespace) throws -> [String]? {
        let data = try Data(contentsOf: legacyQueueFileURL(namespace))
        let root = try CountlyArchive.decodeRoot(from: data) as? [String: Any]
        return root?[PersistencyKey.queuedRequests] as? [String]
    }

    /// Writes `Countly.dat` the way `CountlyPersistency.saveToFileSync` does, with
    /// no key but the queue.
    private func writeAsTheObjectiveCSDK(_ requests: [String], _ namespace: StorageNamespace) throws {
        let data = try NSKeyedArchiver.archivedData(withRootObject: [PersistencyKey.queuedRequests: requests],
                                                    requiringSecureCoding: false)
        try data.write(to: legacyQueueFileURL(namespace), options: .atomic)
    }

    /// Replaces the queue `Countly.dat` holds and keeps every other key, the token
    /// included.
    private func rewriteMirror(_ requests: [String], token: String? = nil, _ namespace: StorageNamespace) throws {
        let data = try Data(contentsOf: legacyQueueFileURL(namespace))
        var root = try XCTUnwrap(CountlyArchive.decodeRoot(from: data) as? [String: Any])
        root[PersistencyKey.queuedRequests] = requests
        if let token {
            root[PersistencyKey.queueMirrorToken] = token
        }
        try CountlyArchive.encodeRoot(root).write(to: legacyQueueFileURL(namespace), options: .atomic)
    }

    /// An application that goes back to the Objective-C SDK finds, in the file that
    /// SDK reads, exactly the queue this one had: what was sent is gone, what was
    /// recorded since is there, and the order is the queue's.
    func testTheObjectiveCSDKFindsTheQueueAfterADowngrade() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let store = mirroringStore(namespace)
        XCTAssertEqual(store.count, 3)
        store.removeHead(try XCTUnwrap(store.head))
        store.enqueue("app_key=k&n=recorded-by-swift", appVersion: "1.0", trackingEnabled: true)
        store.saveSync()

        XCTAssertEqual(try queueAsTheObjectiveCSDKReadsIt(namespace), store.snapshot,
                       "the Objective-C SDK would send a different queue than this one holds")
        XCTAssertEqual(requestFiles(namespace).count, 3, "one file per request")
        XCTAssertEqual(mirroringStore(namespace).snapshot, store.snapshot, "a restart reads the same queue from the request files")
    }

    /// After a downgrade the Objective-C SDK owns the queue, and it writes the file
    /// back without this SDK's token. Coming back to this SDK takes that queue
    /// over, rather than resending what the Objective-C SDK already sent.
    func testAQueueTheObjectiveCSDKWroteAfterADowngradeIsTakenOverOnTheWayBack() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let beforeDowngrade = mirroringStore(namespace)
        XCTAssertEqual(beforeDowngrade.count, 3)
        beforeDowngrade.saveSync()

        try writeAsTheObjectiveCSDK(["app_key=k&n=queued-by-objc"], namespace)

        let afterUpgrade = mirroringStore(namespace)
        XCTAssertEqual(afterUpgrade.snapshot, ["app_key=k&n=queued-by-objc"])
        afterUpgrade.saveSync()
        XCTAssertEqual(requestFiles(namespace).count, 1, "the request files of the earlier run are still there")
        XCTAssertEqual(mirroringStore(namespace).snapshot, ["app_key=k&n=queued-by-objc"],
                       "taken over once, then read back from the request files")
    }

    /// The Objective-C SDK writes the same bytes for every empty queue, so the
    /// empty queue it leaves after a downgrade looks exactly like one this SDK took
    /// over before. It is taken over all the same: the requests this SDK still has
    /// on disk were sent by that SDK, and must not be sent twice.
    func testAnEmptyQueueTheObjectiveCSDKLeftAfterADowngradeIsTakenOver() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        seededNamespaces.append(namespace)
        try writeAsTheObjectiveCSDK([], namespace)

        let beforeDowngrade = mirroringStore(namespace)
        beforeDowngrade.enqueue("app_key=k&n=0", appVersion: "1.0", trackingEnabled: true)
        beforeDowngrade.enqueue("app_key=k&n=1", appVersion: "1.0", trackingEnabled: true)
        beforeDowngrade.saveSync()
        XCTAssertEqual(try queueAsTheObjectiveCSDKReadsIt(namespace)?.count, 2)

        try writeAsTheObjectiveCSDK([], namespace)

        let afterUpgrade = mirroringStore(namespace)
        XCTAssertEqual(afterUpgrade.count, 0, "requests the Objective-C SDK already sent came back")
        afterUpgrade.saveSync()
        XCTAssertEqual(requestFiles(namespace).count, 0)
    }

    /// A take over cut short after it wrote the mirror but before its state leaves
    /// a mirror whose token no state has. That mirror holds the queue the take over
    /// was writing, so the next load takes it over.
    func testAMirrorWithATokenNoStateHasIsTakenOver() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let store = mirroringStore(namespace)
        store.saveSync()
        try rewriteMirror(["app_key=k&n=written-by-a-take-over"], token: "a-state-never-written", namespace)

        XCTAssertEqual(mirroringStore(namespace).snapshot, ["app_key=k&n=written-by-a-take-over"])
    }

    /// A take over killed before it finished leaves request files but no state, and
    /// is simply done again from the Objective-C SDK's file, which it never
    /// touched: nothing is lost and nothing appears twice.
    func testATakeOverCutShortIsDoneAgainFromTheUntouchedSource() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let partial = requestDirectory(namespace).appendingPathComponent("1")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("app_key=legacyKey&half-written".utf8).write(to: partial.appendingPathComponent("00000000000000000001.req"))

        let store = mirroringStore(namespace)
        let timestamps = store.snapshot.map { TestUtils.parseQuery($0)["timestamp"] as? String }
        XCTAssertEqual(timestamps, ["1700000000000", "1700000001000", "1700000002000"])
        store.saveSync()
        XCTAssertEqual(requestFiles(namespace).count, 3)
        XCTAssertEqual(mirroringStore(namespace).count, 3)
    }

    /// The mirror follows the queue on its own, a moment after it changes, so an
    /// application killed without ever saving still leaves the Objective-C SDK the
    /// queue as it was.
    func testTheMirrorFollowsTheQueueWithoutASave() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let store = mirroringStore(namespace)
        store.removeHead(try XCTUnwrap(store.head))
        store.enqueue("app_key=k&n=unsaved", appVersion: "1.0", trackingEnabled: true)

        TestUtils.waitUntil("the mirror catches up without a save") {
            (try? self.queueAsTheObjectiveCSDKReadsIt(namespace)) == store.snapshot
        }
    }

    /// A mirror left behind the request files, by a process killed before it
    /// caught up, is brought up to date by the next launch, which can be the last
    /// one before a downgrade.
    func testAMirrorLeftBehindTheRequestFilesIsBroughtUpToDate() throws {
        let namespace = StorageNamespace(instanceName: uniqueInstanceName())
        try seedLegacyStorage(namespace, isCustomDeviceID: true)

        let store = mirroringStore(namespace)
        let beforeTheSend = store.snapshot
        store.removeHead(try XCTUnwrap(store.head))
        store.saveSync()
        try rewriteMirror(beforeTheSend, namespace)

        let nextLaunch = mirroringStore(namespace)
        XCTAssertEqual(nextLaunch.count, 2)
        nextLaunch.saveSync()
        XCTAssertEqual(try queueAsTheObjectiveCSDKReadsIt(namespace), nextLaunch.snapshot,
                       "the Objective-C SDK would send a request that was already sent")
    }

    /// The remote config cache is written the way the Objective-C SDK archives it,
    /// so an application going back to that SDK finds `CountlyRCData` objects
    /// rather than dictionaries its `getValue` would crash on. A cache held as
    /// dictionaries is rewritten on load, and the class name is the archive's
    /// alone, so a process holding that SDK too keeps its own class.
    func testTheRemoteConfigCacheIsWrittenAsTheObjectiveCSDKArchivesIt() throws {
        let name = uniqueInstanceName()
        let namespace = StorageNamespace(instanceName: name)
        seededNamespaces.append(namespace)
        let dictionaryShaped: [String: Any] = ["theme": ["v": "dark", "c": true], "seats": ["v": 2, "c": false]]
        UserDefaults.standard.set(try NSKeyedArchiver.archivedData(withRootObject: dictionaryShaped, requiringSecureCoding: false),
                                  forKey: namespace.key(PersistencyKey.remoteConfig))

        let countly = start(baseConfig(instanceName: name))
        XCTAssertEqual(countly.remoteConfig.getValue("theme").value as? String, "dark")

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: namespace.key(PersistencyKey.remoteConfig)))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let classNames = (plist?["$objects"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["$classname"] as? String }
        XCTAssertTrue(classNames.contains("CountlyRCData"), "archived under a class name the Objective-C SDK does not have: \(classNames)")
        XCTAssertNil(NSClassFromString("CountlyRCData"), "the SDK claims the Objective-C SDK's class name for the whole process")

        let root = try CountlyArchive.decodeRoot(from: data) as? [String: Any]
        let theme = try XCTUnwrap(root?["theme"] as? ArchivedRCData)
        XCTAssertEqual(theme.value as? String, "dark")
        XCTAssertTrue(theme.isCurrentUsersData)
        XCTAssertEqual((root?["seats"] as? ArchivedRCData)?.isCurrentUsersData, false, "the stale marker was lost")
    }
}
