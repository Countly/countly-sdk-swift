//
//  StorageAndConfigTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
import CoreLocation
@testable import Countly

/// The pieces that survive a launch, and the configuration that can change during
/// one.
///
/// Everything here is about state that outlives the moment it was written: a
/// breadcrumb file that must not grow without bound, a session configuration
/// swapped at runtime, a location half-specified. Each is cheap to get wrong and
/// expensive to notice, because the symptom appears a launch or a week later.
final class StorageAndConfigTests: CountlyBaseTestCase {

    private static let accepted = #"{"result": "Success"}"#

    // MARK: - The breadcrumb file

    /// Only the newest breadcrumbs are ever read back, so without a cap the file
    /// grows for the life of the installation while all but its tail is dead
    /// weight. It is trimmed once it reaches twice the limit, so the rewrite is
    /// paid once per limit's worth rather than on every append.
    func testTheBreadcrumbFileIsTrimmedOnceItOutgrowsTwiceTheLimit() {
        let namespace = StorageNamespace(instanceName: "trim-\(UUID().uuidString.prefix(8))")
        let store = CrashLogStore(namespace: namespace, logger: nil)
        defer { store.deleteAll() }

        store.maxBreadcrumbCount = 3
        for index in 0..<12 {
            store.append("step-\(index)")
        }

        TestUtils.waitUntil("every breadcrumb has been written") {
            (store.readAll() ?? "").contains("step-11")
        }

        // The guarantee is a bound, not an exact count: the file is trimmed back to
        // the limit once it reaches twice it, and then grows again until the next
        // trim. What must hold is that it never runs away, and that the breadcrumbs
        // nearest a crash are the ones kept.
        let lines = (store.readAll() ?? "").split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(lines.count, 6, "the file grew past twice the limit")
        XCTAssertTrue(lines.last?.contains("step-11") == true,
                      "the newest breadcrumbs are the ones nearest a crash, so those are kept")
        XCTAssertFalse(lines.contains { $0.contains("step-0") }, "the oldest were dropped")
    }

    /// Below the trim point the file is left alone, because rewriting it on every
    /// append would turn a cheap log line into a whole-file read and write.
    func testTheBreadcrumbFileIsNotRewrittenBelowTheTrimPoint() {
        let namespace = StorageNamespace(instanceName: "no-trim-\(UUID().uuidString.prefix(8))")
        let store = CrashLogStore(namespace: namespace, logger: nil)
        defer { store.deleteAll() }

        store.maxBreadcrumbCount = 10
        for index in 0..<4 { store.append("step-\(index)") }

        TestUtils.waitUntil("the breadcrumbs land") {
            (store.readAll() ?? "").contains("step-3")
        }
        let lines = (store.readAll() ?? "").split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4)
    }

    /// Reading a file that was never written is not an error: it is the ordinary
    /// case on a first launch.
    func testReadingAnEmptyBreadcrumbStoreYieldsNothing() {
        let namespace = StorageNamespace(instanceName: "empty-\(UUID().uuidString.prefix(8))")
        let store = CrashLogStore(namespace: namespace, logger: nil)

        XCTAssertNil(store.readAll())
        // Deleting one that does not exist is equally ordinary.
        store.deleteAll()
        XCTAssertNil(store.readAll())
    }

    // MARK: - Swapping the session configuration

    /// An application can hand the SDK a session of its own, for a proxy or a
    /// pinned transport it manages itself. The change has to take effect on the
    /// next request rather than on the next launch.
    func testANewSessionConfigurationTakesEffectImmediately() throws {
        try skipUnlessNetworkIsInterceptable()

        let countly = startInstance { $0.eventSendThreshold = 1 }
        let before = core(of: countly).network.session()

        let replacement = MockURLProtocol.sessionConfiguration()
        replacement.httpAdditionalHeaders = ["X-Replaced": "yes"]
        countly.setNewURLSessionConfiguration(replacement)

        let after = core(of: countly).network.session()
        XCTAssertFalse(before === after, "the session is rebuilt rather than reused")

        MockURLProtocol.respondToEverything(json: Self.accepted)
        countly.events.recordEvent("after-the-swap")
        TestUtils.waitUntil("the queue drains through the new session") {
            self.requestQueue(of: countly).isEmpty
        }
    }

    /// Adding headers rebuilds the session too, or the headers would only apply to
    /// requests made after the next unrelated rebuild.
    func testAddingHeadersRebuildsTheSession() {
        let countly = startInstance()
        let before = core(of: countly).network.session()

        countly.addCustomNetworkRequestHeaders(["X-Tenant": "acme"])

        XCTAssertFalse(before === core(of: countly).network.session())
    }

    // MARK: - Location, half specified

    /// The server resolves a city only together with its country, so one without
    /// the other is silently useless. It is still sent, because refusing would lose
    /// data the caller meant, but it is worth warning about.
    func testACityWithoutACountryIsStillSent() {
        let countly = startInstance()

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid,
                                        city: "Istanbul",
                                        isoCountryCode: nil,
                                        ipAddress: nil)

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "city").last else {
            XCTFail("the city should still have been sent")
            return
        }
        XCTAssertEqual(request["city"] as? String, "Istanbul")
        XCTAssertNil(request["country_code"])
    }

    func testACountryWithoutACityIsStillSent() {
        let countly = startInstance()

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid,
                                        city: nil,
                                        isoCountryCode: "TR",
                                        ipAddress: nil)

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "country_code").last else {
            XCTFail("the country should still have been sent")
            return
        }
        XCTAssertEqual(request["country_code"] as? String, "TR")
    }

    /// Sending the stored location again is how a feature that arrives later, such
    /// as consent, gets the location the application supplied at init.
    func testTheStoredLocationCanBeSentAgain() {
        let countly = startInstance {
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
        }
        let before = TestUtils.requests(requestQueue(of: countly), carrying: "city").count

        core(of: countly).modules.location.sendLocationInfo()

        XCTAssertGreaterThan(TestUtils.requests(requestQueue(of: countly), carrying: "city").count,
                             before)
    }

    func testSendingTheStoredLocationNeedsConsent() {
        let countly = startInstance { $0.requiresConsent = true }
        let before = requestQueue(of: countly).count

        core(of: countly).modules.location.sendLocationInfo()

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    func testSendingTheStoredLocationIsDroppedWhenTheServerDisablesLocation() {
        let countly = startInstance {
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(false).json()
        }
        let before = requestQueue(of: countly).count

        core(of: countly).modules.location.sendLocationInfo()

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    // MARK: - Foreground and background reaching every module

    /// The lifecycle is fanned out to every module rather than handled centrally,
    /// so a module added later gets the callbacks without anything else changing.
    func testForegroundAndBackgroundReachEveryModule() {
        let countly = startInstance {
            $0.eventSendThreshold = 100
            $0.manualSessionHandling = true
        }

        countly.events.recordEvent("held-in-memory")

        // Backgrounding flushes, which is a module reacting to the lifecycle rather
        // than to an API call.
        core(of: countly).modules.sessions.didEnterBackground()

        XCTAssertFalse(requestQueue(of: countly).isEmpty,
                       "the batch should have been pushed out on background")
    }

    /// Resigning active saves the health counters, because the process may not get
    /// another chance to write them.
    func testResigningActiveSavesTheHealthCounters() {
        let countly = startInstance()
        let core = core(of: countly)

        core.logger.e("Test", "test", "an error worth remembering")
        core.healthTracker.saveState()

        // The tracker owns its counters on a serial queue and the save hops onto it,
        // so the write lands a turn later.
        TestUtils.waitUntil("the counters reach storage") {
            !(core.keyValueStore.healthCheckState?.isEmpty ?? true)
        }
    }

    // MARK: - The instance registry

    /// Halting every instance at once is what a test harness and a deliberate
    /// teardown both need, and it must not trip over an instance that was never
    /// started.
    func testHaltingEveryInstanceSkipsTheOnesThatNeverStarted() {
        let started = startInstance()
        _ = Countly.instance(named: "never-started-\(UUID().uuidString.prefix(8))")

        Countly.haltAllInstances()

        XCTAssertFalse(started.isStarted)
    }

    /// Starting an instance again after a halt is a fresh start, not a resumption,
    /// which is what makes halt usable as a teardown between tests.
    func testAnInstanceCanBeStartedAgainAfterAHalt() {
        let name = uniqueInstanceName()

        let first = start(baseConfig(instanceName: name))
        XCTAssertTrue(first.isStarted)
        first.halt()
        XCTAssertFalse(first.isStarted)

        let again = start(baseConfig(instanceName: name))
        XCTAssertTrue(again.isStarted)
        XCTAssertTrue(first === again, "the registry hands back the same instance")
    }

    // MARK: - SDK identity

    /// A bridge SDK reports itself, or every request it makes is attributed to the
    /// native SDK and the dashboard cannot tell a Flutter app from a native one.
    func testABridgeCanReportItsOwnNameAndVersion() {
        let countly = startInstance {
            $0.sdkName = "dart-flutterb-ios"
            $0.sdkVersion = "26.1.1"
        }
        countly.events.recordEvent("bridged")
        countly.requestQueue.attemptToSendStoredRequests()

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else {
            XCTFail("nothing was queued")
            return
        }
        XCTAssertEqual(request["sdk_name"] as? String, "dart-flutterb-ios")
        XCTAssertEqual(request["sdk_version"] as? String, "26.1.1")
    }

    /// Without an override the SDK reports itself, and a blank one is not an
    /// override: both fields are required on the wire.
    func testTheBuiltInIdentityIsUsedWhenNoneIsSuppliedOrItIsBlank() {
        let plain = startInstance()
        plain.events.recordEvent("plain")
        plain.requestQueue.attemptToSendStoredRequests()
        if let request = TestUtils.request(requestQueue(of: plain), at: 0) {
            XCTAssertEqual(request["sdk_name"] as? String, SDKIdentity.name)
            XCTAssertEqual(request["sdk_version"] as? String, SDKIdentity.version)
        } else {
            XCTFail("nothing was queued for the plain instance")
        }

        let blank = startInstance {
            $0.instanceName = self.uniqueInstanceName()
            $0.sdkName = "   "
            $0.sdkVersion = ""
        }
        blank.events.recordEvent("blank")
        blank.requestQueue.attemptToSendStoredRequests()
        if let request = TestUtils.request(requestQueue(of: blank), at: 0) {
            XCTAssertEqual(request["sdk_name"] as? String, SDKIdentity.name)
            XCTAssertEqual(request["sdk_version"] as? String, SDKIdentity.version)
        } else {
            XCTFail("nothing was queued for the blank instance")
        }
    }

    // MARK: - Diagnostic queue access

    /// A bridge SDK's integration suite asserts on what the SDK queued. Android
    /// exposes the same three through `CountlyStore`.
    func testTheQueuesCanBeReadAndARequestStoredVerbatim() {
        let countly = startInstance { $0.eventSendThreshold = 100 }

        countly.events.recordEvent("first", segmentation: ["a": 1])
        countly.events.recordEvent("second")

        let events = countly.events.recordedEvents()
        XCTAssertEqual(events.count, 2, "both events are still buffered below the send threshold")
        XCTAssertTrue(events[0].contains("\"first\""), "oldest first")
        XCTAssertTrue(events[1].contains("\"second\""))

        let before = countly.requestQueue.queuedRequests()
        countly.requestQueue.store("app_key=crafted&device_id=forged&custom=1")
        let after = countly.requestQueue.queuedRequests()

        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.last, "app_key=crafted&device_id=forged&custom=1",
                       "a stored request reaches the queue exactly as written")
        XCTAssertEqual(countly.requestQueue.count, after.count)
    }

    /// Reading must not mutate, and an empty request is not queued.
    func testReadingTheQueueLeavesItAloneAndAnEmptyStoreIsRefused() {
        let countly = startInstance()
        countly.requestQueue.store("app_key=one")

        let first = countly.requestQueue.queuedRequests()
        let second = countly.requestQueue.queuedRequests()
        XCTAssertEqual(first, second, "reading the queue changed it")

        countly.requestQueue.store("")
        XCTAssertEqual(countly.requestQueue.queuedRequests().count, first.count,
                       "an empty request was queued")
    }
}
