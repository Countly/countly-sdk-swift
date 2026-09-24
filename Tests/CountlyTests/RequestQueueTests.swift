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

    /// Namespaces the stores built here own, deleted afterwards so no queue file
    /// is left in the application container between runs.
    private var namespaces: [StorageNamespace] = []

    override func tearDown() {
        for namespace in namespaces {
            RequestQueueStore(namespace: namespace, logger: nil).deleteFile()
            KeyValueStore(namespace: namespace, logger: nil).clearAll()
        }
        namespaces.removeAll()
        super.tearDown()
    }

    /// A store on a namespace of its own, so no two tests can see each other's
    /// queue file.
    private func makeStore(_ suffix: String = #function) -> RequestQueueStore {
        let namespace = StorageNamespace(instanceName: "rq-\(suffix)-\(UUID().uuidString.prefix(8))")
        namespaces.append(namespace)
        return RequestQueueStore(namespace: namespace, logger: nil)
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
        let namespace = StorageNamespace(instanceName: "rq-persist-\(UUID().uuidString.prefix(8))")
        namespaces.append(namespace)

        let first = RequestQueueStore(namespace: namespace, logger: nil)
        first.enqueue("app_key=k&n=0", appVersion: "1.0", trackingEnabled: true)
        first.enqueue("app_key=k&n=1", appVersion: "1.0", trackingEnabled: true)
        first.saveSync()

        let second = RequestQueueStore(namespace: namespace, logger: nil)
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

    // MARK: - Removing one request by marker

    /// The immediate crash report is appended to the tail and delivered out of
    /// band, so the copy that proved deliverable is never the head. `removeHead`
    /// would silently do nothing for it.
    func testARequestCanBeRemovedFromAnywhereInTheQueue() {
        let store = makeStore()

        store.appendVerbatim("a=1&crash=first")
        store.appendVerbatim("a=1&crash=second")
        store.appendVerbatim("a=1&crash=third")

        store.removeFirst(containing: "&crash=second")
        XCTAssertEqual(store.snapshot, ["a=1&crash=first", "a=1&crash=third"])

        // Removing what is no longer there leaves the queue alone rather than
        // dropping the head as a guess.
        store.removeFirst(containing: "&crash=second")
        XCTAssertEqual(store.snapshot, ["a=1&crash=first", "a=1&crash=third"])
    }

    /// Two matching requests are two deliveries, so removing one has to leave the
    /// other behind.
    func testRemovingADuplicatedRequestTakesOnlyOneCopy() {
        let store = makeStore()

        store.appendVerbatim("same=1")
        store.appendVerbatim("other=2")
        store.appendVerbatim("same=1")

        store.removeFirst(containing: "same=1")
        XCTAssertEqual(store.snapshot, ["other=2", "same=1"])
    }

    /// The crash report is delivered while it sits in the queue, so a device ID
    /// or app key rewrite can edit the stored copy before the removal runs. The
    /// marker has to be a part of the request those rewrites never touch.
    func testARequestIsStillRemovableAfterTheQueueWasRewritten() {
        let store = makeStore()

        store.appendVerbatim("app_key=old&device_id=\(TemporaryDeviceID.value)&crash=payload")
        store.replaceTemporaryDeviceIDs(with: "real-id", typeValue: 0)
        store.replaceAllAppKeys(with: "new")

        store.removeFirst(containing: "&crash=payload")
        XCTAssertTrue(store.snapshot.isEmpty,
                      "the rewritten copy should still be removable, found: [\(store.snapshot)]")
    }

}
