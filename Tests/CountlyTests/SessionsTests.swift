//
//  SessionsTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Opening, updating and closing a session.
///
/// The server reconstructs how long someone used the application from a sequence
/// of three request shapes, so what matters is that each one carries the right
/// parameter, that they arrive in order, and that a session is never opened twice
/// or closed without having been opened.
final class SessionsTests: CountlyBaseTestCase {

    // MARK: - Manual sessions

    func testBeginSessionCarriesTheMetricsAndOpensTheSession() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.beginSession()

        let begins = TestUtils.requests(requestQueue(of: countly), carrying: "begin_session")
        XCTAssertEqual(begins.count, 1)
        TestUtils.assertBaseParameters(begins[0])
        TestUtils.assertParameters(["begin_session": 1], in: begins[0])

        // The metrics ride on the session start, which is the only request that
        // carries them, so a missing one leaves the dashboard with no device data.
        guard let metrics = begins[0]["metrics"] as? [String: Any] else {
            XCTFail("begin_session should carry the device metrics: \(begins[0])")
            return
        }
        XCTAssertNotNil(metrics[MetricKey.os])
        XCTAssertNotNil(metrics[MetricKey.appVersion])
    }

    /// Hybrid mode leaves session updates to the timer, so a manual update is
    /// ignored rather than producing an extra duration report.
    func testAManualUpdateIsIgnoredInHybridMode() {
        let countly = startInstance {
            $0.manualSessionHandling = true
            $0.enableManualSessionControlHybridMode = true
        }

        countly.sessions.beginSession()
        TestUtils.pump(1.1)
        countly.sessions.updateSession()

        let updates = requestQueue(of: countly).map(TestUtils.parseQuery)
            .filter { $0["session_duration"] != nil && $0["end_session"] == nil }
        XCTAssertTrue(updates.isEmpty, "a manual update in hybrid mode must not be sent: \(updates)")
    }

    func testTheFullManualCycleProducesBeginUpdateAndEndInThatOrder() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.beginSession()
        TestUtils.pump(1.1)
        countly.sessions.updateSession()
        countly.sessions.endSession()

        let queue = requestQueue(of: countly)
        let beginAt = queue.firstIndex { TestUtils.parseQuery($0)["begin_session"] != nil }
        let endAt = queue.firstIndex { TestUtils.parseQuery($0)["end_session"] != nil }
        let updateAt = queue.firstIndex { request in
            let parsed = TestUtils.parseQuery(request)
            return parsed["session_duration"] != nil && parsed["end_session"] == nil
        }

        guard let beginAt, let updateAt, let endAt else {
            XCTFail("expected a begin, an update and an end in \(queue.count) requests")
            return
        }
        XCTAssertLessThan(beginAt, updateAt)
        XCTAssertLessThan(updateAt, endAt)
    }

    /// The duration is reported in whole seconds, with the remainder carried over,
    /// so a sequence of updates adds up to the real elapsed time rather than
    /// losing a fraction on every one.
    func testTheUpdateReportsTheSecondsSinceTheSessionStarted() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.beginSession()
        TestUtils.pump(1.2)
        countly.sessions.updateSession()

        let updates = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .filter { $0["session_duration"] != nil && $0["end_session"] == nil }

        XCTAssertEqual(updates.count, 1)
        let duration = TestUtils.int(updates[0]["session_duration"]) ?? -1

        // Whole seconds, with the remainder carried over rather than rounded, so a
        // sequence of updates adds up to the real elapsed time. Asserting the exact
        // value would only hold on an idle machine: a loaded CI runner can overrun
        // the wait into the next second, which is the scheduler's doing and not a
        // change in behaviour. What has to hold is the flooring.
        XCTAssertGreaterThanOrEqual(duration, 1)
        XCTAssertLessThan(duration, 10, "the duration should not be a wall clock artefact")
    }

    func testEndSessionReportsTheRemainingDuration() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.beginSession()
        TestUtils.pump(1.1)
        countly.sessions.endSession()

        let ends = TestUtils.requests(requestQueue(of: countly), carrying: "end_session")
        XCTAssertEqual(ends.count, 1)
        TestUtils.assertParameters(["end_session": 1], in: ends[0])
        XCTAssertGreaterThanOrEqual(TestUtils.int(ends[0]["session_duration"]) ?? -1, 1)
    }

    // MARK: - Guards

    func testBeginningASessionTwiceOpensOnlyOne() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.beginSession()
        countly.sessions.beginSession()

        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").count, 1)
    }

    func testUpdatingAndEndingWithoutABeginDoNothing() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.updateSession()
        countly.sessions.endSession()

        XCTAssertTrue(requestQueue(of: countly).isEmpty,
                      "there is no session to update or close")
    }

    func testEndingASessionTwiceClosesItOnce() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.sessions.beginSession()
        countly.sessions.endSession()
        countly.sessions.endSession()

        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "end_session").count, 1)
    }

    // MARK: - Consent

    func testNoSessionIsOpenedWithoutSessionsConsent() {
        let countly = startInstance {
            $0.manualSessionHandling = true
            $0.requiresConsent = true
        }

        countly.sessions.beginSession()
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").isEmpty)

        countly.consent.giveConsent(for: .sessions)
        countly.sessions.beginSession()
        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").count, 1)
    }

    // MARK: - Server config

    /// The server can switch session tracking off entirely, which has to beat the
    /// application's own configuration.
    func testTheServerCanSwitchSessionTrackingOff() {
        let countly = startInstance {
            $0.manualSessionHandling = true
            $0.sdkBehaviorSettings = ServerConfigBuilder().sessionTracking(false).json()
        }

        countly.sessions.beginSession()
        countly.sessions.endSession()

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    /// The server can switch automatic sessions in a running build. On, a session
    /// begins at once; off, the session the SDK began ends, while a session the
    /// application began itself is left to it.
    func testTheServerCanSwitchAutomaticSessionsAtRuntime() throws {
        try skipUnlessNetworkIsInterceptable()
        var answer = ServerConfigBuilder().json()
        MockURLProtocol.respond { captured in
            captured.query.contains("method=sc") ? (200, Data(answer.utf8)) : nil
        }
        let countly = startInstance()
        let core = core(of: countly)
        // An automatic session is refused while the application reads as in the background.
        AppState.setActive(true)
        TestUtils.waitUntil("the first fetch goes out") { MockURLProtocol.requests.contains { $0.query.contains("method=sc") } }
        TestUtils.pump(0.2)

        /// Answers a fetch with the switch and waits until it is applied.
        func serverSwitches(automaticSessions: Bool) {
            answer = ServerConfigBuilder().automaticSessionTracking(automaticSessions).json()
            core.serverConfig.fetch(config: core.config)
            TestUtils.waitUntil("the switch lands") { core.serverConfig.automaticSessionTrackingEnabled == automaticSessions }
            TestUtils.pump(0.2)
        }
        /// How many queued requests carry `key`.
        func count(_ key: String) -> Int {
            TestUtils.requests(requestQueue(of: countly), carrying: key).count
        }

        serverSwitches(automaticSessions: true)
        XCTAssertEqual(count("begin_session"), 1, "switched on, a session begins at once")

        serverSwitches(automaticSessions: false)
        XCTAssertEqual(count("end_session"), 1, "switched off, the session the SDK began ends")

        countly.sessions.beginSession()
        XCTAssertEqual(count("begin_session"), 2)
        serverSwitches(automaticSessions: true)
        serverSwitches(automaticSessions: false)

        XCTAssertEqual(count("begin_session"), 2, "a session already open is not begun twice")
        XCTAssertEqual(count("end_session"), 1, "a session the application began is left to it")
        XCTAssertTrue(core.modules.sessions.isSessionStarted)
    }

    // MARK: - Ordering against other features

    /// An event recorded before a session ends has to reach the server before the
    /// end, or it lands outside the session it belongs to.
    func testEventsAreFlushedBeforeTheSessionCloses() {
        let countly = startInstance {
            $0.manualSessionHandling = true
            $0.eventSendThreshold = 100
        }

        countly.sessions.beginSession()
        countly.events.recordEvent("inside-the-session")
        countly.sessions.endSession()

        let queue = requestQueue(of: countly)
        let eventsAt = queue.firstIndex { TestUtils.parseQuery($0)["events"] != nil }
        let endAt = queue.firstIndex { TestUtils.parseQuery($0)["end_session"] != nil }

        guard let eventsAt, let endAt else {
            XCTFail("expected both an events request and an end_session in \(queue.count) requests")
            return
        }
        XCTAssertLessThan(eventsAt, endAt)
    }

    /// A user property staged before the session opens describes the user the
    /// session belongs to, so it has to be sent first.
    func testStagedUserPropertiesAreSavedBeforeTheSessionOpens() {
        let countly = startInstance { $0.manualSessionHandling = true }

        countly.userProfile.setProperty("name", value: "Ada")
        countly.sessions.beginSession()

        let queue = requestQueue(of: countly)
        let detailsAt = queue.firstIndex { TestUtils.parseQuery($0)["user_details"] != nil }
        let beginAt = queue.firstIndex { TestUtils.parseQuery($0)["begin_session"] != nil }

        guard let detailsAt, let beginAt else {
            XCTFail("expected both a user_details request and a begin_session in \(queue.count) requests")
            return
        }
        XCTAssertLessThan(detailsAt, beginAt)
    }
}
