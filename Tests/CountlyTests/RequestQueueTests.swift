//
//  RequestQueueTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import SQLite3
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

    // MARK: - The database

    /// Every request is a row, written as it is queued and deleted as it is sent,
    /// so the next launch finds exactly the queue in its order. A named instance
    /// keeps no `Countly.dat`: no other SDK reads its data.
    func testEveryRequestIsARowAndTheQueueComesBackInOrder() {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        for index in 0..<5 {
            enqueue(first, "app_key=k&n=\(index)")
        }
        first.removeHead(first.head ?? "")
        first.saveSync()

        XCTAssertEqual(TestUtils.names(databaseRows(namespace)), ["1", "2", "3", "4"])
        let second = openStore(namespace)
        XCTAssertEqual(TestUtils.names(second.snapshot), ["1", "2", "3", "4"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyQueueFileURL(namespace).path), "a named instance wrote a Countly.dat")

        enqueue(second, "app_key=k&n=5")
        second.saveSync()
        XCTAssertEqual(TestUtils.names(openStore(namespace).snapshot).last, "5", "a request queued after a restart went ahead of older ones")
    }

    /// Every change reaches the database on its own, without a save, so a process
    /// killed a moment later loses nothing.
    func testAChangeReachesTheDatabaseWithoutASave() {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        enqueue(store, "app_key=k&n=0")
        enqueue(store, "app_key=k&n=1")
        store.removeHead(store.head ?? "")

        TestUtils.waitUntil("the change is committed without a save") {
            TestUtils.names(self.databaseRows(namespace)) == ["1"]
        }
    }

    /// A rewrite of every request lands in one transaction: a restart reads every
    /// request rewritten, and nothing twice.
    func testARewriteOfTheWholeQueueLandsAllAtOnce() {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        for index in 0..<3 {
            enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=\(index)")
        }
        store.saveSync()

        store.replaceTemporaryDeviceIDs(with: "real-id", typeValue: 1)
        store.saveSync()

        let reloaded = openStore(namespace).snapshot.map(TestUtils.parseQuery)
        XCTAssertEqual(reloaded.map { $0["n"] as? String }, ["0", "1", "2"])
        XCTAssertTrue(reloaded.allSatisfy { $0["device_id"] as? String == "real-id" && $0["t"] as? String == "1" })
    }

    /// A transaction that fails, here because another connection holds the write
    /// lock, is made again by the next sync, so nothing that failed to land is lost
    /// once the database takes writes again.
    func testATransactionThatFailsIsMadeAgainByTheNextSync() throws {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=0")
        store.saveSync()

        var blocker: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL(namespace).path, &blocker, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(blocker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        enqueue(store, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=1")
        store.replaceTemporaryDeviceIDs(with: "real-id", typeValue: 1)
        store.saveSync()
        XCTAssertEqual(databaseRows(namespace).count, 1, "the lock was meant to refuse the transaction")

        sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil)
        sqlite3_close_v2(blocker)
        store.saveSync()

        let reloaded = openStore(namespace).snapshot.map(TestUtils.parseQuery)
        XCTAssertEqual(reloaded.map { $0["n"] as? String }, ["0", "1"])
        XCTAssertTrue(reloaded.allSatisfy { $0["device_id"] as? String == "real-id" }, "the rewrite never reached the database")
    }

    /// A database that cannot be read, a protected file on a locked device for
    /// instance, is never replaced: the queue runs in memory meanwhile, and once the
    /// file opens its requests go in front of the ones queued meanwhile.
    func testADatabaseThatCannotBeReadLosesNothing() throws {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        enqueue(first, "app_key=k&n=0")
        enqueue(first, "app_key=k&n=1")
        first.saveSync()

        let restoreDatabase = try makeDatabaseUnreadable(namespace)

        let locked = openStore(namespace)
        XCTAssertEqual(locked.count, 0)
        enqueue(locked, "app_key=k&n=2")
        locked.saveSync()
        XCTAssertEqual(locked.count, 1)

        try restoreDatabase()
        XCTAssertEqual(TestUtils.names(databaseRows(namespace)), ["0", "1"], "the unreadable database was written over")
        locked.saveSync()

        XCTAssertEqual(TestUtils.names(locked.snapshot), ["0", "1", "2"])
        XCTAssertEqual(TestUtils.names(databaseRows(namespace)), ["0", "1", "2"])
    }

    /// Changes meant for the whole queue while the database could not be read reach
    /// its requests too once it opens: a flush drops them, a real device ID replaces
    /// the temporary one in them.
    func testWholeQueueChangesMadeWhileTheDatabaseCannotBeReadReachItsRequests() throws {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        enqueue(first, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=0")
        enqueue(first, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=1")
        first.saveSync()

        let restoreDatabase = try makeDatabaseUnreadable(namespace)

        let locked = openStore(namespace)
        enqueue(locked, "app_key=k&device_id=\(TemporaryDeviceID.value)&t=9&n=2")
        locked.replaceTemporaryDeviceIDs(with: "real-id", typeValue: 1)
        enqueue(locked, "app_key=k&device_id=real-id&t=1&n=3")
        locked.removeDifferentAppKeys(than: "k")

        try restoreDatabase()
        locked.saveSync()

        let queue = locked.snapshot.map(TestUtils.parseQuery)
        XCTAssertEqual(queue.map { $0["n"] as? String }, ["0", "1", "2", "3"])
        XCTAssertTrue(queue.allSatisfy { $0["device_id"] as? String == "real-id" }, "a request read later kept the temporary device ID")

        locked.flush()
        enqueue(locked, "app_key=k&n=after-the-flush")
        locked.saveSync()
        XCTAssertEqual(TestUtils.names(openStore(namespace).snapshot), ["after-the-flush"])
    }

    /// Requests queued while the database cannot be read outlive the process: a
    /// synchronous save writes them to the pending file, and the next launch puts
    /// them after the database's queue.
    func testRequestsQueuedWhileTheDatabaseCannotBeReadOutliveTheProcess() throws {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        enqueue(first, "app_key=k&n=0")
        first.saveSync()

        let restoreDatabase = try makeDatabaseUnreadable(namespace)

        let locked = openStore(namespace)
        enqueue(locked, "app_key=k&n=1")
        locked.saveSync()
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFileURL(namespace).path),
                      "nothing was saved while the database could not be read")

        try restoreDatabase()
        XCTAssertEqual(TestUtils.names(openStore(namespace).snapshot), ["0", "1"])
    }

    /// A launch that cannot read the database either leaves the pending file of an
    /// earlier such launch alone, so its requests are still folded in once the
    /// database opens.
    func testAPendingFileFromAnEarlierLaunchIsNotWrittenOver() throws {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        enqueue(first, "app_key=k&n=0")
        first.saveSync()

        let restoreDatabase = try makeDatabaseUnreadable(namespace)
        var earlierLaunch: RequestQueueStore? = RequestQueueStore(namespace: namespace, logger: nil)
        earlierLaunch.map { enqueue($0, "app_key=k&n=1") }
        earlierLaunch?.saveSync()
        earlierLaunch = nil

        let laterLaunch = openStore(namespace)
        enqueue(laterLaunch, "app_key=k&n=2")
        laterLaunch.saveSync()

        try restoreDatabase()
        laterLaunch.saveSync()
        XCTAssertEqual(TestUtils.names(laterLaunch.snapshot), ["0", "1", "2"], "the earlier launch's requests were lost")
    }

    /// The queue limit applies to the merged queue once the database opens, so the
    /// oldest requests go first whichever side they came from.
    func testTheLimitAppliesToTheMergedQueueOnceTheDatabaseOpens() throws {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        for index in 0..<3 {
            enqueue(first, "app_key=k&n=\(index)")
        }
        first.saveSync()

        let restoreDatabase = try makeDatabaseUnreadable(namespace)

        let locked = openStore(namespace)
        locked.storedRequestsLimit = 3
        enqueue(locked, "app_key=k&n=3")
        enqueue(locked, "app_key=k&n=4")

        try restoreDatabase()
        locked.saveSync()
        XCTAssertEqual(TestUtils.names(locked.snapshot), ["2", "3", "4"])
    }

    /// A request a drain was sending when the database's queue went in front of it
    /// is still removed once the server accepted it, rather than sent twice.
    func testARequestInFlightWhenTheDatabaseOpensIsStillRemoved() throws {
        let namespace = makeNamespace()
        let first = openStore(namespace)
        enqueue(first, "app_key=k&n=0")
        first.saveSync()

        let restoreDatabase = try makeDatabaseUnreadable(namespace)

        let locked = openStore(namespace)
        enqueue(locked, "app_key=k&n=1")
        let inFlight = try XCTUnwrap(locked.head)

        try restoreDatabase()
        locked.saveSync()
        XCTAssertEqual(TestUtils.names(locked.snapshot), ["0", "1"])

        locked.removeHead(inFlight)
        XCTAssertEqual(TestUtils.names(locked.snapshot), ["0"])
    }

    /// A corrupt database costs the queue it held, never the ability to queue: it is
    /// set aside, and a new one is started empty.
    func testACorruptDatabaseIsSetAsideAndANewOneStartsEmpty() throws {
        let namespace = makeNamespace()
        var first: RequestQueueStore? = RequestQueueStore(namespace: namespace, logger: nil)
        first.map { enqueue($0, "app_key=k&n=0") }
        first?.saveSync()
        first = nil

        try corruptDatabase(namespace)

        let store = openStore(namespace)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFiles(namespace).setAside.path), "the corrupt database was not kept aside")

        enqueue(store, "app_key=k&n=1")
        store.saveSync()
        XCTAssertEqual(TestUtils.names(openStore(namespace).snapshot), ["1"])
    }

    /// The crash handler can interrupt the write queue in the middle of a
    /// transaction, so a crash on that thread leaves the database alone and writes
    /// the queue to the pending file, which the next launch folds in.
    func testACrashOnTheWriteQueueLandsInThePendingFile() {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        enqueue(store, "app_key=k&n=0")
        enqueue(store, "app_key=k&n=1")
        store.saveSync()

        var rowsAtTheCrash: [String] = []
        var nextLaunch: [String] = []
        let crashed = expectation(description: "the crash handler ran on the write queue")
        store.save {
            // What the crash handler does: remove what was sent, queue the report, save synchronously.
            store.removeHead(store.head ?? "")
            self.enqueue(store, "app_key=k&n=crash")
            store.saveSync()
            rowsAtTheCrash = self.databaseRows(namespace)
            nextLaunch = RequestQueueStore(namespace: namespace, logger: nil).snapshot
            crashed.fulfill()
        }
        wait(for: [crashed], timeout: TestUtils.asyncTimeout)

        XCTAssertEqual(TestUtils.names(rowsAtTheCrash), ["0", "1"], "the crash handler touched the database")
        XCTAssertEqual(TestUtils.names(nextLaunch), ["1", "crash"], "the next launch did not fold in the pending file")

        store.saveSync()
        XCTAssertEqual(TestUtils.names(databaseRows(namespace)), ["1", "crash"])
        XCTAssertEqual(TestUtils.names(openStore(namespace).snapshot), ["1", "crash"], "a pending file already folded in was folded in again")
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL(namespace).path), "a pending file already folded in was left behind")
    }

    /// A flush is how pending data is discarded on request, so it is all or
    /// nothing on disk as well, and clearing the storage leaves nothing behind.
    func testAFlushAndAClearLeaveNothingBehind() {
        let namespace = makeNamespace()
        let store = openStore(namespace)
        for index in 0..<3 {
            enqueue(store, "app_key=k&n=\(index)")
        }
        store.flush()
        store.saveSync()

        XCTAssertEqual(databaseRows(namespace).count, 0)
        XCTAssertEqual(openStore(namespace).count, 0)

        store.deleteFile()
        for file in RequestQueueDatabase.sqliteFiles(of: databaseURL(namespace)) + [legacyQueueFileURL(namespace), pendingFileURL(namespace)] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) was left behind")
        }
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
