//
//  LifecycleTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// What the SDK does when the application changes state rather than when it calls
/// an API.
///
/// Backgrounding, foregrounding and termination are the moments the SDK has the
/// least control over and the most to lose: the process may not come back, so
/// anything held in memory has to reach disk, and anything the server is waiting
/// for has to be closed rather than abandoned.
final class LifecycleTests: CountlyBaseTestCase {

    /// Drives the SDK through a state change the way the operating system would.
    private func core(_ instance: CountlyInstance) -> SDKCore { core(of: instance) }

    // MARK: - Termination

    /// The last thing the process does is flush, because there is no later.
    func testTerminationPushesEverythingHeldInMemoryOntoTheQueue() {
        let countly = startInstance { $0.eventSendThreshold = 100 }

        countly.events.recordEvent("recorded-just-before-the-end")
        XCTAssertTrue(requestQueue(of: countly).isEmpty, "still batched in memory")

        core(countly).modules.sessions.suspend()

        XCTAssertFalse(requestQueue(of: countly).isEmpty,
                       "the batch should have reached the queue rather than dying with the process")
    }

    /// A view still open when the application ends has to be closed, or the server
    /// never learns how long the user spent on the last screen they saw.
    func testAnOpenViewIsClosedWhenTheApplicationEnds() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.views.startView("LastScreen")
        TestUtils.pump(1.1)
        core(countly).modules.views.applicationWillTerminate()

        let closings = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["key"] as? String == ReservedEventKey.view }
            .filter { (TestUtils.double($0["dur"]) ?? 0) > 0 }

        XCTAssertEqual(closings.count, 1)
        XCTAssertEqual((closings[0]["segmentation"] as? [String: Any])?[SegKey.name] as? String,
                       "LastScreen")
    }

    // MARK: - Background and foreground

    /// Backgrounding closes the open views so their durations are reported, and
    /// foregrounding starts them again so the user's screen keeps being timed.
    func testViewsAreClosedOnBackgroundAndStartedAgainOnForeground() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let views = core(countly).modules.views

        countly.views.startView("Article")
        TestUtils.pump(1.1)

        views.applicationDidEnterBackground()
        views.applicationWillEnterForeground()

        let viewEvents = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["key"] as? String == ReservedEventKey.view }

        let names = viewEvents.compactMap { ($0["segmentation"] as? [String: Any])?[SegKey.name] as? String }
        XCTAssertEqual(names, ["Article", "Article", "Article"],
                       "the view opens, closes on background, and opens again on foreground")
        XCTAssertGreaterThan(TestUtils.double(viewEvents[1]["dur"]) ?? 0, 0,
                             "the middle event is the close and carries the duration")
    }

    /// A view restarted on foreground keeps the segmentation it was carrying, or
    /// the second half of the same screen would arrive with less context than the
    /// first.
    func testARestartedViewKeepsItsSegmentation() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let views = core(countly).modules.views

        countly.views.startView("Article", segmentation: ["id": "42"])
        views.applicationDidEnterBackground()
        views.applicationWillEnterForeground()

        let opened = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["key"] as? String == ReservedEventKey.view }
            .filter { (($0["segmentation"] as? [String: Any])?[SegKey.visit]) != nil }

        XCTAssertEqual(opened.count, 2)
        for event in opened {
            XCTAssertEqual((event["segmentation"] as? [String: Any])?["id"] as? String, "42")
        }
    }

    /// The restart is opt out, for an application that manages its own views and
    /// does not want the SDK reopening them.
    func testTheViewRestartCanBeSwitchedOff() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.disableViewRestartForManualRecording = true
        }
        let views = core(countly).modules.views

        countly.views.startView("Article")
        views.applicationDidEnterBackground()
        views.applicationWillEnterForeground()

        let opened = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["key"] as? String == ReservedEventKey.view }
            .filter { (($0["segmentation"] as? [String: Any])?[SegKey.visit]) != nil }

        XCTAssertEqual(opened.count, 1, "the view should not have been reopened")
    }

    // MARK: - The session update timer

    /// The timer is what keeps a long session alive on the server. It reports the
    /// elapsed time and flushes whatever has accumulated since the last tick.
    func testTheUpdateTimerReportsTheElapsedTimeAndFlushesEvents() {
        // Hybrid mode is manual sessions plus the automatic update timer, which is
        // exactly what this needs: a session the test opens, kept alive by the
        // timer the SDK owns.
        let countly = startInstance {
            $0.manualSessionHandling = true
            $0.enableManualSessionControlHybridMode = true
            $0.eventSendThreshold = 100
            $0.updateSessionPeriod = 1
        }

        countly.sessions.beginSession()
        countly.events.recordEvent("recorded-between-ticks")

        TestUtils.waitUntil("the timer ticks") {
            !TestUtils.requests(self.requestQueue(of: countly), carrying: "events").isEmpty
        }

        let updates = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .filter { $0["session_duration"] != nil && $0["end_session"] == nil }
        XCTAssertFalse(updates.isEmpty, "the timer should have reported the session duration")
    }

    /// A tick landing after a suspend would reopen work the SDK has just finished,
    /// so the timer does nothing while suspended.
    func testTheUpdateTimerDoesNothingWhileSuspended() {
        let countly = startInstance {
            $0.manualSessionHandling = true
            $0.enableManualSessionControlHybridMode = true
            $0.updateSessionPeriod = 1
        }

        countly.sessions.beginSession()
        countly.suspend()
        let afterSuspend = requestQueue(of: countly).count
        TestUtils.pump(1.5)

        XCTAssertEqual(requestQueue(of: countly).count, afterSuspend,
                       "nothing should have been produced while suspended")
    }

    // MARK: - Automatic view tracking state

    /// Automatic and manual view tracking are mutually exclusive: while the SDK is
    /// naming screens itself, a manual call would produce a second, competing view
    /// for the same screen, so manual calls are refused until it is switched off.
    func testManualViewCallsAreRefusedWhileAutomaticTrackingIsOn() throws {
        #if !(os(iOS) || os(tvOS))
        throw XCTSkip("automatic view tracking is implemented on iOS and tvOS only, as in the reference SDK")
        #else
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.enableAutomaticViewTracking = true
        }
        let views = core(countly).modules.views

        // Switched on from the main queue as the SDK finishes configuring.
        TestUtils.waitUntil("automatic view tracking is active") { views.isAutoViewTrackingActive }

        XCTAssertNil(countly.views.startView("Manual"),
                     "a manual view must not compete with the automatic one")

        views.stopAutoViewTracking()
        XCTAssertFalse(views.isAutoViewTrackingActive)

        XCTAssertNotNil(countly.views.startView("Manual"),
                        "manual calls are allowed again once automatic tracking is off")
        #endif
    }

    /// Turning it on needs both the server's permission and the user's, so an
    /// application cannot switch it on against either.
    func testAutomaticViewTrackingCannotBeTurnedOnWithoutConsent() throws {
        #if !(os(iOS) || os(tvOS))
        throw XCTSkip("automatic view tracking is implemented on iOS and tvOS only, as in the reference SDK")
        #else
        let countly = startInstance {
            $0.requiresConsent = true
            $0.enableAutomaticViewTracking = true
        }
        let views = core(countly).modules.views

        views.startAutoViewTracking()
        XCTAssertFalse(views.isAutoViewTrackingActive)

        countly.consent.giveConsent(for: .viewTracking)
        views.startAutoViewTracking()
        XCTAssertTrue(views.isAutoViewTrackingActive)
        #endif
    }

    /// The exclusion list is set at init and can be extended afterwards, because a
    /// screen worth excluding is not always known before the SDK starts.
    func testTheExclusionListCanBeExtendedAfterStart() {
        let countly = startInstance { $0.automaticViewTrackingExclusionList = ["First"] }

        // Nothing observable to assert on off UIKit, where the matcher itself is
        // not compiled: what matters here is that the call is accepted at any point
        // after start rather than only through the configuration.
        countly.views.addAutoViewTrackingExclusionList(["Second", "Third"])
        countly.views.addAutoViewTrackingExclusionList([])
    }

    // MARK: - Consent turned on by the server

    /// The server can require consent from a build that shipped without it. The
    /// state has to be resent, because the server's view of what it may keep just
    /// changed.
    func testConsentBeingRequiredMidSessionResendsTheState() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startInstance { $0.requiresConsent = false }
        let before = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        MockURLProtocol.respond(pathContaining: "/o/sdk",
                                json: ServerConfigBuilder().consentRequired(true).json())
        core(countly).serverConfig.fetch(config: core(countly).config)

        TestUtils.waitUntil("the behaviour settings arrive and consent is resent") {
            core(countly).serverConfig.consentRequired
                && TestUtils.requests(self.requestQueue(of: countly), carrying: "consent").count > before
        }
    }
}
