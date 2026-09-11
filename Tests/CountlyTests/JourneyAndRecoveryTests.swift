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

    /// Writes breadcrumbs into the store an instance of this name will read, which
    /// is what a run that died without a teardown leaves behind.
    ///
    /// A crash is not a halt: the process stops, nothing runs, and the file is
    /// simply still there on the next launch. Halting the SDK deliberately clears
    /// the breadcrumbs, so it cannot stand in for one.
    private func leaveBreadcrumbsBehind(_ crumbs: [String], forInstanceNamed name: String) {
        let store = CrashLogStore(namespace: StorageNamespace(instanceName: name), logger: nil)
        for crumb in crumbs { store.append(crumb) }
        // The store writes on its own queue; reading it back is what guarantees the
        // writes have landed before the instance starts. Compared against the
        // escaped form, because the store replaces the line separator on the way in.
        let expected = (crumbs.last ?? "").replacingOccurrences(of: "\n", with: "\\n")
        TestUtils.waitUntil("the breadcrumbs reach disk") {
            (store.readAll() ?? "").contains(expected)
        }
    }

    /// The crash report of a run that ended is the point of writing breadcrumbs to
    /// disk at all: the next launch picks them up and attaches them to the first
    /// report it makes.
    func testBreadcrumbsFromARunThatCrashedAreAttachedToTheNextReport() {
        let name = uniqueInstanceName()
        leaveBreadcrumbsBehind(["opened the cart", "tapped checkout"], forInstanceNamed: name)

        let countly = start(baseConfig(instanceName: name))
        countly.crashes.recordError("crashed last time", isFatal: false, stackTrace: [])

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("the new launch should have reported a crash")
            return
        }
        let logs = crash["_logs"] as? String ?? ""
        XCTAssertTrue(logs.contains("opened the cart"), "logs were: \(logs)")
        XCTAssertTrue(logs.contains("tapped checkout"), "logs were: \(logs)")
    }

    /// They are attached once and then cleared, so they do not follow the user
    /// through every report for the rest of the installation.
    func testRecoveredBreadcrumbsAreAttachedOnlyOnce() {
        let name = uniqueInstanceName()
        leaveBreadcrumbsBehind(["from the previous run"], forInstanceNamed: name)

        let countly = start(baseConfig(instanceName: name))
        countly.crashes.recordError("first", isFatal: false, stackTrace: [])
        countly.crashes.clearCrashBreadcrumbs()
        countly.crashes.recordError("second", isFatal: false, stackTrace: [])

        let reports = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .compactMap { $0["crash"] as? [String: Any] }
        XCTAssertEqual(reports.count, 2)
        XCTAssertTrue((reports[0]["_logs"] as? String ?? "").contains("from the previous run"))
        XCTAssertNil(reports[1]["_logs"], "the second report should carry no breadcrumbs")
    }

    /// The recovered set is held to the same limit as a live one, so a run that
    /// logged thousands of breadcrumbs does not produce an enormous first report.
    /// The newest are the ones nearest the crash, so those are what is kept.
    func testRecoveredBreadcrumbsAreHeldToTheBreadcrumbLimit() {
        let name = uniqueInstanceName()
        leaveBreadcrumbsBehind((0..<20).map { "step-\($0)" }, forInstanceNamed: name)

        let config = baseConfig(instanceName: name)
        config.sdkInternalLimits.maxBreadcrumbCount = 3
        let countly = start(config)
        countly.crashes.recordError("after recovery", isFatal: false, stackTrace: [])

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("the new launch should have reported a crash")
            return
        }
        let lines = (crash["_logs"] as? String ?? "").split(separator: "\n")
        XCTAssertLessThanOrEqual(lines.count, 3)
        XCTAssertTrue(lines.last?.contains("step-19") == true,
                      "the newest breadcrumb is kept, lines were: \(lines)")
    }

    /// Halting the SDK deliberately is not a crash, and it clears the breadcrumbs
    /// rather than leaving them for a launch that has nothing to do with them.
    func testAnOrdinaryHaltLeavesNoBreadcrumbsToRecover() {
        let name = uniqueInstanceName()

        let first = start(baseConfig(instanceName: name))
        first.crashes.addCrashBreadcrumb("should not survive a teardown")
        first.halt()

        let store = CrashLogStore(namespace: StorageNamespace(instanceName: name), logger: nil)
        XCTAssertNil(store.readAll())
    }

    /// A breadcrumb carrying a newline would read back as several, so the
    /// separator is escaped rather than carried through.
    func testABreadcrumbWithANewlineStaysOneBreadcrumb() {
        let name = uniqueInstanceName()
        leaveBreadcrumbsBehind(["line one\nline two"], forInstanceNamed: name)

        let countly = start(baseConfig(instanceName: name))
        countly.crashes.recordError("after recovery", isFatal: false, stackTrace: [])

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("the new launch should have reported a crash")
            return
        }
        let lines = (crash["_logs"] as? String ?? "").split(separator: "\n")
        XCTAssertEqual(lines.count, 1, "one breadcrumb should read back as one line")
    }
}
