//
//  MultiInstanceTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Several SDKs in one process, and the lifecycle of any one of them.
///
/// This is the feature that separates this SDK from the one it was ported from:
/// the reference keeps its logger, clock, queue and device ID in process-wide
/// singletons, so a second instance is not possible. Here every one of those is per
/// instance, and what these check is that no state at all leaks across the
/// boundary.
final class MultiInstanceTests: CountlyBaseTestCase {

    // MARK: - The registry

    func testAskingForTheSameNameTwiceReturnsTheSameInstance() {
        let first = Countly.instance(named: "registry-stability")
        let second = Countly.instance(named: "registry-stability")

        XCTAssertTrue(first === second)
    }

    /// Getting a handle must never start the SDK. An accidental reference cannot
    /// be allowed to begin collecting data.
    func testGettingAnInstanceNeverStartsIt() {
        let countly = Countly.instance(named: "never-auto-started")

        XCTAssertFalse(countly.isStarted)
    }

    func testGetInstanceNeverCreatesOne() {
        XCTAssertNil(Countly.getInstance(named: "definitely-never-created-\(UUID().uuidString)"))
    }

    func testAnEmptyOrMissingNameIsTheDefaultInstance() {
        XCTAssertTrue(Countly.instance(named: "") === Countly.shared)
        XCTAssertTrue(Countly.instance(named: nil) === Countly.shared)
    }

    func testListingInstancesExcludesTheDefaultOne() {
        _ = Countly.instance(named: "listed-instance")

        XCTAssertTrue(Countly.listInstances().contains("listed-instance"))
        XCTAssertFalse(Countly.listInstances().contains(Countly.defaultInstanceName))
    }

    // MARK: - Isolation

    /// Two instances reporting to two app keys must not see each other's requests.
    /// A leak here would send one tenant's data to the other's dashboard.
    func testTwoInstancesKeepSeparateRequestQueues() {
        let firstConfig = baseConfig()
        firstConfig.appKey = "app-one"
        firstConfig.eventSendThreshold = 1
        let first = start(firstConfig)

        let secondConfig = baseConfig()
        secondConfig.appKey = "app-two"
        secondConfig.eventSendThreshold = 1
        let second = start(secondConfig)

        first.events.recordEvent("only-in-the-first")
        second.events.recordEvent("only-in-the-second")

        let firstQueue = requestQueue(of: first).map(TestUtils.parseQuery)
        let secondQueue = requestQueue(of: second).map(TestUtils.parseQuery)

        XCTAssertTrue(firstQueue.allSatisfy { $0["app_key"] as? String == "app-one" })
        XCTAssertTrue(secondQueue.allSatisfy { $0["app_key"] as? String == "app-two" })

        let firstKeys = firstQueue.compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }.compactMap { $0["key"] as? String }
        XCTAssertEqual(firstKeys, ["only-in-the-first"])
    }

    func testTwoInstancesKeepSeparateDeviceIDs() {
        let firstConfig = baseConfig()
        firstConfig.deviceID = "user-one"
        let first = start(firstConfig)

        let secondConfig = baseConfig()
        secondConfig.deviceID = "user-two"
        let second = start(secondConfig)

        XCTAssertEqual(first.deviceID.current, "user-one")
        XCTAssertEqual(second.deviceID.current, "user-two")

        first.deviceID.changeWithMerge("user-one-renamed")
        XCTAssertEqual(second.deviceID.current, "user-two",
                       "changing one instance's identity must not touch the other's")
    }

    func testTwoInstancesKeepSeparateConsent() {
        let firstConfig = baseConfig()
        firstConfig.requiresConsent = true
        let first = start(firstConfig)

        let secondConfig = baseConfig()
        secondConfig.requiresConsent = true
        let second = start(secondConfig)

        first.consent.giveAllConsents()

        XCTAssertTrue(first.consent.hasConsent(for: .events))
        XCTAssertFalse(second.consent.hasConsent(for: .events))
    }

    /// The clock is per instance for a specific reason: it never repeats a
    /// timestamp, so a burst on a shared clock would push another instance's
    /// timestamps into the future.
    func testABurstOnOneInstanceDoesNotPushTheOthersClockForward() {
        let busy = startInstance { $0.eventSendThreshold = 1000 }
        let quiet = startInstance { $0.eventSendThreshold = 1 }

        let before = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<3000 {
            busy.events.recordEvent("burst-\(index)")
        }

        quiet.events.recordEvent("after-the-burst")

        guard let request = TestUtils.request(requestQueue(of: quiet), at: 0) else { return }
        let timestamp = Int64(TestUtils.int(TestUtils.events(in: request)[0]["timestamp"]) ?? 0)

        XCTAssertLessThan(timestamp - before, 60_000,
                          "the quiet instance's clock should be near real time, not dragged forward")
    }

    // MARK: - Lifecycle

    func testStartingAnAlreadyStartedInstanceIsIgnored() {
        let config = baseConfig()
        let countly = start(config)
        countly.events.recordEvent("before")
        let before = requestQueue(of: countly).count

        countly.start(with: config)

        XCTAssertTrue(countly.isStarted)
        XCTAssertEqual(requestQueue(of: countly).count, before,
                       "a restart would have torn down a queue that is still in flight")
    }

    func testCallsBeforeStartAreIgnoredRatherThanCrashing() {
        let countly = Countly.instance(named: "used-before-start-\(UUID().uuidString.prefix(8))")

        XCTAssertFalse(countly.isStarted)
        countly.events.recordEvent("too early")
        countly.views.startView("Too early")
        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.save()
        countly.sessions.beginSession()

        XCTAssertFalse(countly.isStarted)
    }

    func testHaltStopsTheInstanceAndCallsAfterwardsAreIgnored() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("before the halt")

        countly.halt()

        XCTAssertFalse(countly.isStarted)
        countly.events.recordEvent("after the halt")
    }

    /// A halt with `clearStorage` has to leave the next start looking like a first
    /// install, which is what makes it usable for a "delete my data" flow.
    func testHaltWithClearStorageLeavesNothingBehind() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = "to-be-erased"
        firstConfig.eventSendThreshold = 1000
        let first = start(firstConfig)
        first.events.recordEvent("to-be-erased")
        first.halt(clearStorage: true)

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = "a-fresh-start"
        let second = start(secondConfig)

        XCTAssertEqual(second.deviceID.current, "a-fresh-start",
                       "the erased device ID must not come back")
        XCTAssertTrue(requestQueue(of: second).isEmpty,
                      "the erased queue must not come back")
    }

    /// An ordinary halt is not a delete: the queue is written out so the data is
    /// still sent on the next launch.
    func testAnOrdinaryHaltKeepsWhatWasQueued() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.eventSendThreshold = 1
        let first = start(firstConfig)
        first.events.recordEvent("must survive")
        XCTAssertFalse(requestQueue(of: first).isEmpty)
        first.halt()

        let second = start(baseConfig(instanceName: name))

        XCTAssertFalse(requestQueue(of: second).isEmpty,
                       "an ordinary halt must not lose data the server has not accepted")
    }

    // MARK: - Configuration validation

    func testAnInstanceWithNoAppKeyOrHostDoesNotStart() {
        let noAppKey = Countly.instance(named: "no-app-key-\(UUID().uuidString.prefix(8))")
        let missingKey = CountlyConfig()
        missingKey.host = Self.host
        noAppKey.start(with: missingKey)
        XCTAssertFalse(noAppKey.isStarted)

        let noHost = Countly.instance(named: "no-host-\(UUID().uuidString.prefix(8))")
        let missingHost = CountlyConfig()
        missingHost.appKey = Self.appKey
        noHost.start(with: missingHost)
        XCTAssertFalse(noHost.isStarted)
    }

    func testAHostWithTrailingSlashesIsNormalised() {
        let config = baseConfig()
        config.host = "https://example.com//"

        XCTAssertEqual(config.normalizedHost, "https://example.com")
    }

    // MARK: - Overriding the configuration at runtime

    func testChangingTheHostAffectsWhereTheNextRequestGoes() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.setNewHost("https://elsewhere.count.ly")
        countly.events.recordEvent("to the new host")

        TestUtils.waitUntil("a request reaches the new host") {
            MockURLProtocol.requests.contains { $0.url.host == "elsewhere.count.ly" }
        }
    }

    /// Requests already queued keep the app key they were recorded under, because
    /// they belong to that dashboard application. Re-attributing them is a separate,
    /// explicit call.
    func testChangingTheAppKeyLeavesQueuedRequestsAlone() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("under the old key")

        countly.setNewAppKey("a-different-key")
        countly.events.recordEvent("under the new key")

        let keys = requestQueue(of: countly).map { TestUtils.parseQuery($0)["app_key"] as? String }
        XCTAssertTrue(keys.contains(Self.appKey))
        XCTAssertTrue(keys.contains("a-different-key"))
    }

    func testAnEmptyHostOrAppKeyIsRefused() {
        let countly = startInstance()

        countly.setNewHost("")
        countly.setNewAppKey("")

        XCTAssertEqual(core(of: countly).config.normalizedHost, Self.host)
        XCTAssertEqual(core(of: countly).config.appKey, Self.appKey)
    }
}
