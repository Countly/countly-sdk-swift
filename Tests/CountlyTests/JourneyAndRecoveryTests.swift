//
//  JourneyAndRecoveryTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Two features that only exist because of something that happened earlier.
///
/// A journey trigger reacts to an event the server has just been told about, so it
/// has to wait for that event to arrive and then ask again, retrying because the
/// server may still be working out what to show. Breadcrumb recovery reaches back
/// further still: to a run that crashed before it could report anything.
final class JourneyAndRecoveryTests: CountlyBaseTestCase {

    private static let accepted = #"{"result": "Success"}"#

    // MARK: - Journey triggers

    /// An event named as a journey trigger is flushed on the spot rather than
    /// batched, and once the server confirms it the SDK asks what to show. Batching
    /// it would mean asking about a journey the server has not been told to start.
    func testAJourneyTriggerEventIsFlushedAndFollowedByAContentFetch() throws {
        try skipUnlessNetworkIsInterceptable()

        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(Self.accepted.utf8)) : nil
        }

        let countly = startInstance {
            // High enough that only the trigger's own force-flush can send it.
            $0.eventSendThreshold = 100
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .journeyTriggerEvents(["purchase"])
                .json()
        }

        countly.events.recordEvent("purchase")

        TestUtils.waitUntil("the trigger event is sent and the content fetch follows") {
            MockURLProtocol.requests.contains { $0.path.contains("/o/sdk/content") }
        }
    }

    /// An ordinary event is not a trigger and must not force a flush, or the
    /// batching that makes events cheap would stop working.
    func testAnOrdinaryEventDoesNotTriggerAContentFetch() throws {
        try skipUnlessNetworkIsInterceptable()

        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(Self.accepted.utf8)) : nil
        }

        let countly = startInstance {
            $0.eventSendThreshold = 100
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .journeyTriggerEvents(["purchase"])
                .json()
        }

        countly.events.recordEvent("something-else")
        TestUtils.pump(0.5)

        XCTAssertTrue(MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }.isEmpty)
    }

    /// A view named as a journey trigger behaves the same way an event does, which
    /// is how a journey can be started by someone arriving on a screen.
    func testAJourneyTriggerViewAlsoLeadsToAContentFetch() throws {
        try skipUnlessNetworkIsInterceptable()

        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(Self.accepted.utf8)) : nil
        }

        let countly = startInstance {
            $0.eventSendThreshold = 100
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .journeyTriggerViews(["Checkout"])
                .json()
        }

        countly.views.startView("Checkout")

        TestUtils.waitUntil("the trigger view is sent and the content fetch follows") {
            MockURLProtocol.requests.contains { $0.path.contains("/o/sdk/content") }
        }
    }

    /// The server may still be working out the journey's next step, so a fetch that
    /// comes back with nothing is retried rather than given up on.
    func testAJourneyFetchIsRetriedWhenItComesBackEmpty() throws {
        try skipUnlessNetworkIsInterceptable()

        // The content endpoint never answers, so every attempt fails and the retry
        // path is the only way a second request appears.
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(Self.accepted.utf8)) : nil
        }

        let countly = startInstance()
        core(of: countly).modules.content.refreshContentZoneForJourneyTrigger()

        TestUtils.waitUntil("the journey fetch is retried") {
            MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }.count >= 2
        }
    }

    /// Two triggers close together run one retry series, not two: the second
    /// trigger arrives while the first is still asking and is skipped.
    func testASecondTriggerDuringTheRetrySeriesStartsNoSecondSeries() throws {
        try skipUnlessNetworkIsInterceptable()

        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(Self.accepted.utf8)) : nil
        }

        let countly = startInstance()
        let content = core(of: countly).modules.content
        content.refreshContentZoneForJourneyTrigger()
        content.refreshContentZoneForJourneyTrigger()

        TestUtils.waitUntil("the retry series ran to its end") {
            MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }.count >= 3
        }
        TestUtils.pump(1.5)

        XCTAssertEqual(MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }.count, 3,
                       "one series of three attempts, the second trigger must not add its own")
    }

    func testTheJourneyRefreshIsSkippedWhenTheServerDisablesIt() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: Self.accepted)

        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().unknown("rcz", false).json()
        }

        core(of: countly).modules.content.refreshContentZoneForJourneyTrigger()
        TestUtils.pump(0.4)

        XCTAssertTrue(MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }.isEmpty)
    }

    // MARK: - Breadcrumbs across launches

    /// Breadcrumbs belong to the run that recorded them. A run that ends without a
    /// crash report leaves nothing behind for the next run's first crash.
    func testBreadcrumbsDoNotOutliveTheirRun() {
        let name = uniqueInstanceName()

        let first = start(baseConfig(instanceName: name))
        first.crashes.addCrashBreadcrumb("from the previous run")
        first.halt()

        let countly = start(baseConfig(instanceName: name))
        countly.crashes.recordError("in the new run", isFatal: false, stackTrace: ["0 MyApp 0x1 boom"])

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("the new run should have reported a crash")
            return
        }
        XCTAssertNil(crash["_logs"], "the previous run's breadcrumbs must not reach this report")
    }
}
