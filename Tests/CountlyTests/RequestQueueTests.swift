//
//  RequestQueueTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The queue that makes the SDK survive a dead network, a crash and a restart.
///
/// Everything the SDK produces goes through here, and nothing is removed until the
/// server has accepted it, so the queue's rules about ordering, overflow and
/// rewriting are the difference between losing data and merely delaying it. These
/// exercise the store directly, because the behaviours are about the queue itself
/// rather than about any one feature.
final class RequestQueueTests: CountlyBaseTestCase {

    /// Namespaces the stores built here own. Their queue files go with the stores
    /// in the base class's `tearDown`, their user defaults here.
    private var namespaces: [StorageNamespace] = []

    override func tearDown() {
        for namespace in namespaces {
            KeyValueStore(namespace: namespace, logger: nil).clearAll()
        }
        namespaces.removeAll()
        super.tearDown()
    }

    /// A namespace of its own, so no two tests can see each other's queue files.
    private func makeNamespace(_ suffix: String = #function) -> StorageNamespace {
        let namespace = StorageNamespace(instanceName: "rq-\(suffix)-\(UUID().uuidString.prefix(8))")
        namespaces.append(namespace)
        return namespace
    }

    /// A store on a namespace of its own.
    private func makeStore(_ suffix: String = #function) -> RequestQueueStore {
        openStore(makeNamespace(suffix))
    }

    private func enqueue(_ store: RequestQueueStore, _ queryString: String) {
        store.enqueue(queryString, appVersion: "1.0", trackingEnabled: true)
    }

    // MARK: - Ordering

    /// The server reconstructs a session from a sequence, so a later request must
    /// never overtake an earlier one.
    func testRequestsComeBackOutInTheOrderTheyWentIn() {
        let store = makeStore()

        for index in 0..<5 {
            enqueue(store, "app_key=k&n=\(index)")
        }

        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.snapshot.map { TestUtils.parseQuery($0)["n"] as? String },
                       ["0", "1", "2", "3", "4"])
        XCTAssertEqual(TestUtils.parseQuery(store.head ?? "")["n"] as? String, "0")
    }

    /// The head is only removed once the server has accepted *that* request. If it
    /// has moved in the meantime, removing blindly would drop somebody else's.
    func testTheHeadIsOnlyRemovedWhenItIsStillTheHead() {
        let store = makeStore()
        enqueue(store, "app_key=k&n=0")
        enqueue(store, "app_key=k&n=1")

        guard let head = store.head else {
            XCTFail("the queue should not be empty")
            return
        }

        store.removeHead("app_key=k&n=1&av=1.0")
        XCTAssertEqual(store.count, 2, "a request that is not at the head is left alone")

        store.removeHead(head)
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(TestUtils.parseQuery(store.head ?? "")["n"] as? String, "1")
    }

    // MARK: - The app version stamp

    /// The app version is stamped when the request is queued rather than when it
    /// is sent, so a request produced before an update still reports the version it
    /// was actually produced under.
    func testTheAppVersionIsStampedAtQueueTimeNotAtSendTime() {
        let store = makeStore()

        store.enqueue("app_key=k&n=0", appVersion: "1.0", trackingEnabled: true)
        store.enqueue("app_key=k&n=1", appVersion: "2.0", trackingEnabled: true)

        let versions = store.snapshot.map { TestUtils.parseQuery($0)["av"] as? String }
        XCTAssertEqual(versions, ["1.0", "2.0"])
    }

    // MARK: - Refusing to queue

    func testAnEmptyRequestIsNotQueued() {
        let store = makeStore()
        enqueue(store, "")
        XCTAssertEqual(store.count, 0)
    }

    /// When the server has switched tracking off, the request is discarded rather
    /// than queued: it would never be allowed out, and keeping it would just crowd
    /// out requests made after tracking is switched back on.
    func testNothingIsQueuedWhileTrackingIsDisabled() {
        let store = makeStore()

        store.enqueue("app_key=k&n=0", appVersion: "1.0", trackingEnabled: false)

        XCTAssertEqual(store.count, 0)
    }

    // MARK: - Overflow

    /// Past the limit the oldest requests go, because the newest data is the data
    /// most likely to still matter.
    func testTheOldestRequestsAreDroppedWhenTheQueueIsFull() {
        let store = makeStore()
        store.storedRequestsLimit = 5

        for index in 0..<8 {
            enqueue(store, "app_key=k&n=\(index)")
        }

        XCTAssertLessThanOrEqual(store.count, 5)

        let remaining = store.snapshot.compactMap { Int(TestUtils.parseQuery($0)["n"] as? String ?? "") }
        XCTAssertEqual(remaining.last, 7, "the newest request is always kept")
        XCTAssertFalse(remaining.contains(0), "the oldest went first")
    }

    // MARK: - Age based dropping

    func testRequestsPastTheDropAgeAreRemoved() {
        let store = makeStore()
        store.requestDropAgeHours = 1

        let now = Date().timeIntervalSince1970
        let old = Int64((now - 7200) * 1000)
        let fresh = Int64(now * 1000)

        enqueue(store, "app_key=k&timestamp=\(old)&n=old")
        enqueue(store, "app_key=k&timestamp=\(fresh)&n=fresh")

        store.removeOldAgeRequests()

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(TestUtils.parseQuery(store.head ?? "")["n"] as? String, "fresh")
    }

    /// Age based dropping is opt in. With it off, nothing is ever dropped for being
    /// old, however long the device was offline.
    func testWithoutADropAgeNothingIsDroppedForBeingOld() {
        let store = makeStore()
        store.requestDropAgeHours = 0

        let ancient = Int64((Date().timeIntervalSince1970 - 86_400 * 365) * 1000)
        enqueue(store, "app_key=k&timestamp=\(ancient)&n=ancient")

        store.removeOldAgeRequests()

        XCTAssertEqual(store.count, 1)
        XCTAssertFalse(store.isOldRequest(store.head ?? ""))
    }

    // MARK: - App key rewriting

    /// An application that changes its app key can either re-attribute what it
    /// already queued or throw it away. Both are offered because both are
    /// legitimate: one keeps the data, the other keeps the separation.
    func testReplacingAppKeysReAttributesEveryQueuedRequest() {
        let store = makeStore()
        enqueue(store, "app_key=old&n=0")
        enqueue(store, "app_key=other&n=1")
        enqueue(store, "app_key=new&n=2")

        store.replaceAllAppKeys(with: "new")

        let keys = store.snapshot.map { TestUtils.parseQuery($0)["app_key"] as? String }
        XCTAssertEqual(keys, ["new", "new", "new"])
        XCTAssertEqual(store.count, 3, "nothing is lost, only re-attributed")
    }

    func testRemovingDifferentAppKeysDropsTheForeignRequests() {
        let store = makeStore()
        enqueue(store, "app_key=old&n=0")
        enqueue(store, "app_key=new&n=1")
        enqueue(store, "app_key=other&n=2")

        store.removeDifferentAppKeys(than: "new")

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(TestUtils.parseQuery(store.head ?? "")["n"] as? String, "1")
    }

    func testAppKeyRewritingLeavesAnEmptyQueueAlone() {
        let store = makeStore()

        store.replaceAllAppKeys(with: "new")
        store.removeDifferentAppKeys(than: "new")

        XCTAssertEqual(store.count, 0)
    }

    // MARK: - Temporary device ID rewriting

    /// Leaving temporary mode has to rewrite both the ID and its type. Rewriting
    /// only the ID would leave every held request claiming to come from a
    /// temporary identity that no longer exists.
    func testLeavingTemporaryModeRewritesTheIDAndItsType() {
        let store = makeStore()
        enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=\(DeviceIDType.temporary.wireValue)&n=0")
        enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=\(DeviceIDType.temporary.wireValue)&n=1")

        store.replaceTemporaryDeviceIDs(with: "real-user",
                                        typeValue: DeviceIDType.developerSupplied.wireValue)

        for request in store.snapshot.map(TestUtils.parseQuery) {
            XCTAssertEqual(request["device_id"] as? String, "real-user")
            XCTAssertEqual(request["t"] as? String, "\(DeviceIDType.developerSupplied.wireValue)")
        }
    }

    func testRewritingTemporaryIDsLeavesRealOnesAlone() {
        let store = makeStore()
        enqueue(store, "app_key=k&device_id=already-real&t=0&n=0")

        store.replaceTemporaryDeviceIDs(with: "someone-else", typeValue: 0)

        XCTAssertEqual(TestUtils.parseQuery(store.head ?? "")["device_id"] as? String, "already-real")
    }

    // MARK: - Persistence

    /// The queue exists to survive process death, so a store built on the same
    /// namespace has to find what the previous one left behind.
    func testTheQueueSurvivesBeingReadBackFromDisk() {
        let namespace = makeNamespace()

        let first = openStore(namespace)
        enqueue(first, "app_key=k&n=0")
        enqueue(first, "app_key=k&n=1")
        first.saveSync()

        let second = openStore(namespace)
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(second.snapshot.map { TestUtils.parseQuery($0)["n"] as? String }, ["0", "1"])
    }

    func testFlushingEmptiesTheQueue() {
        let store = makeStore()
        enqueue(store, "app_key=k&n=0")

        store.flush()

        XCTAssertEqual(store.count, 0)
        XCTAssertNil(store.head)
    }

    // MARK: - One file per request

    /// The generation directories of a namespace, lowest first. More than one
    /// after a rewrite means the rewrite did not clean up after itself.
    private func generationDirectories(_ namespace: StorageNamespace) -> [URL] {
        let root = requestDirectory(namespace)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { Int($0) }.sorted().map { root.appendingPathComponent("\($0)") }
    }

    /// Sets the POSIX permissions of a file or directory.
    private func setPermissions(_ permissions: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Every request is a file of its own, written as it is queued and deleted as
    /// it is sent, so the next launch finds exactly the queue in its order. A named
    /// instance keeps no `Countly.dat`: no other SDK reads its data.
    func testEveryRequestIsAFileAndTheQueueComesBackInOrder() {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        for index in 0..<5 {
            enqueue(first, "app_key=k&n=\(index)")
        }
        first.removeHead(first.head ?? "")
        first.saveSync()

        XCTAssertEqual(requestFiles(namespace).count, 4)
        let second = openStore(namespace)
        XCTAssertEqual(second.snapshot.map { TestUtils.parseQuery($0)["n"] as? String }, ["1", "2", "3", "4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFileURL(namespace).path), "a named instance wrote a Countly.dat")

        enqueue(second, "app_key=k&n=5")
        second.saveSync()
        XCTAssertEqual(openStore(namespace).snapshot.last.map { TestUtils.parseQuery($0)["n"] as? String },
                       "5", "a request queued after a restart went ahead of older ones")
    }

    /// A rewrite of every request lands as one switch: after it only the new
    /// generation is on disk, and a restart reads every request rewritten.
    func testARewriteOfTheWholeQueueLandsAllAtOnce() {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        for index in 0..<3 {
            enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=\(index)")
        }
        store.saveSync()

        store.replaceTemporaryDeviceIDs(with: "real-id", typeValue: 1)
        store.saveSync()

        XCTAssertEqual(generationDirectories(namespace).count, 1)
        let reloaded = openStore(namespace).snapshot.map(TestUtils.parseQuery)
        XCTAssertEqual(reloaded.count, 3)
        XCTAssertTrue(reloaded.allSatisfy { $0["device_id"] as? String == "real-id" && $0["t"] as? String == "1" })
    }

    /// A file that reads but is broken costs that one request, never the queue. A
    /// file that cannot be read at all, a protected one on a locked device for
    /// instance, costs nothing: it stays where it is and a later launch reads it.
    func testABrokenRequestFileCostsOnlyThatRequestAndAnUnreadableOneIsKept() throws {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        for index in 0..<3 {
            enqueue(store, "app_key=k&n=\(index)")
        }
        store.saveSync()

        let files = requestFiles(namespace)
        try Data([0xFF, 0xFE, 0xFD]).write(to: files[1])
        try setPermissions(0o000, files[2])
        defer { try? setPermissions(0o644, files[2]) }

        let locked = openStore(namespace)
        XCTAssertEqual(locked.snapshot.map { TestUtils.parseQuery($0)["n"] as? String }, ["0"])
        enqueue(locked, "app_key=k&n=3")
        locked.saveSync()
        XCTAssertEqual(requestFiles(namespace).count, 3, "the broken file stays, or the unreadable one is gone")

        try setPermissions(0o644, files[2])
        XCTAssertEqual(openStore(namespace).snapshot.map { TestUtils.parseQuery($0)["n"] as? String }, ["0", "2", "3"])
    }

    /// A write that fails is made again by the next sync, a single request and a
    /// rewrite of the whole queue alike, so a disk that refused writes for a while
    /// loses nothing once it takes them again.
    func testAWriteThatFailsIsMadeAgainByTheNextSync() throws {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=0")
        store.saveSync()

        let root = requestDirectory(namespace)
        let generation = try XCTUnwrap(generationDirectories(namespace).last)
        try setPermissions(0o555, generation)
        try setPermissions(0o555, root)
        defer {
            try? setPermissions(0o755, root)
            try? setPermissions(0o755, generation)
        }

        enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=1")
        store.replaceTemporaryDeviceIDs(with: "real-id", typeValue: 1)
        store.saveSync()
        XCTAssertEqual(requestFiles(namespace).count, 1, "the directories were meant to refuse the writes")

        try setPermissions(0o755, root)
        try setPermissions(0o755, generation)
        store.saveSync()

        let reloaded = openStore(namespace).snapshot.map(TestUtils.parseQuery)
        XCTAssertEqual(reloaded.map { $0["n"] as? String }, ["0", "1"])
        XCTAssertTrue(reloaded.allSatisfy { $0["device_id"] as? String == "real-id" }, "the rewrite never reached disk")
        XCTAssertEqual(generationDirectories(namespace).count, 1)
    }

    /// A state file that cannot be read, cut short by a power loss or written by a
    /// later SDK, is no reason to touch a request file: the newest generation is
    /// read instead, and new requests join it.
    func testAStateFileThatCannotBeReadLosesNoRequest() throws {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        for index in 0..<3 {
            enqueue(store, "app_key=k&n=\(index)")
        }
        store.saveSync()

        try Data().write(to: requestDirectory(namespace).appendingPathComponent("state.json"))

        let reloaded = openStore(namespace)
        XCTAssertEqual(reloaded.snapshot.map { TestUtils.parseQuery($0)["n"] as? String }, ["0", "1", "2"])
        enqueue(reloaded, "app_key=k&n=3")
        reloaded.saveSync()
        XCTAssertEqual(requestFiles(namespace).count, 4, "a request file was removed on the word of a state file that could not be read")
    }

    /// A flush is how pending data is discarded on request, so it is all or
    /// nothing on disk as well, and clearing the storage leaves nothing behind.
    func testAFlushAndAClearLeaveNothingBehind() {
        let namespace = makeNamespace()
        let store = openStore(namespace, mirrorsLegacyFile: true)
        for index in 0..<3 {
            enqueue(store, "app_key=k&n=\(index)")
        }
        store.flush()
        store.saveSync()

        XCTAssertEqual(requestFiles(namespace).count, 0)
        XCTAssertEqual(generationDirectories(namespace).count, 1)
        XCTAssertEqual(openStore(namespace, mirrorsLegacyFile: true).count, 0)

        store.deleteFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestDirectory(namespace).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFileURL(namespace).path))
    }

    // MARK: - Through the SDK

    /// The queue-facing public API is thin, but it is what an application reaches
    /// for after changing its app key, so it is worth checking it reaches the
    /// store at all.
    func testTheRequestQueueAPIReportsAndClearsTheQueue() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("one")
        countly.events.recordEvent("two")

        XCTAssertEqual(countly.requestQueue.count, requestQueue(of: countly).count)
        XCTAssertGreaterThan(countly.requestQueue.count, 0)

        countly.requestQueue.flushQueues()
        XCTAssertEqual(countly.requestQueue.count, 0)
    }

    /// Changing the app key at runtime has to reach the queued requests, which is
    /// the whole point of offering the two rewrites on the public API.
    func testChangingTheAppKeyCanReAttributeOrDropWhatIsAlreadyQueued() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("under-the-old-key")
        XCTAssertGreaterThan(countly.requestQueue.count, 0)

        countly.setNewAppKey("the-new-key")
        countly.requestQueue.replaceAllAppKeysInQueueWithCurrentAppKey()

        for request in requestQueue(of: countly).map(TestUtils.parseQuery) {
            XCTAssertEqual(request["app_key"] as? String, "the-new-key")
        }

        countly.requestQueue.removeDifferentAppKeysFromQueue()
        XCTAssertGreaterThan(countly.requestQueue.count, 0,
                             "everything now carries the current key, so nothing is foreign")
    }
}
