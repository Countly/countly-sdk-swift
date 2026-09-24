//
//  ViewsTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The `[CLY]_view` events that describe which screens someone saw and for how
/// long.
///
/// A view is reported as two events with the same ID: one when it opens, carrying
/// `visit: 1`, and one when it closes, carrying the duration. The server pairs them
/// by ID, so the ID, the pairing and the duration are what these check, along with
/// the segmentation rules that decide what else travels with them.
final class ViewsTests: CountlyBaseTestCase {

    /// Views are recorded as events, so a threshold of one keeps every view event
    /// in its own request and makes the queue read in the order things happened.
    private func viewInstance(_ adjust: @escaping (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        startInstance {
            $0.eventSendThreshold = 1
            adjust($0)
        }
    }

    /// Every `[CLY]_view` event in the queue, oldest first.
    private func viewEvents(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["key"] as? String == ReservedEventKey.view }
    }

    // MARK: - Starting a view

    func testStartingAViewReportsItsNameAndMarksItAVisit() {
        let countly = viewInstance()

        let viewID = countly.views.startView("Home")

        XCTAssertNotNil(viewID)
        let events = viewEvents(of: countly)
        XCTAssertEqual(events.count, 1)

        let segmentation = (events[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[SegKey.name] as? String, "Home")
        XCTAssertEqual(TestUtils.int(segmentation[SegKey.visit]), 1)
        XCTAssertNotNil(segmentation[SegKey.segment], "the platform travels with every view")
        XCTAssertEqual(events[0]["id"] as? String, viewID,
                       "the event ID is the view ID, which is how the close is paired with the open")
    }

    func testAViewWithNoNameIsNotStarted() {
        let countly = viewInstance()

        XCTAssertNil(countly.views.startView(""))
        XCTAssertTrue(viewEvents(of: countly).isEmpty)
    }

    /// Custom segmentation travels with the view, but the keys the SDK owns are
    /// its own: a caller cannot overwrite `name` and make one screen report as
    /// another.
    func testCustomSegmentationTravelsButReservedKeysAreStrippedFromIt() {
        let countly = viewInstance()

        countly.views.startView("Cart", segmentation: [
            "items": 3,
            SegKey.name: "Impostor",
            SegKey.visit: 0,
        ])

        let segmentation = (viewEvents(of: countly)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(segmentation["items"]), 3)
        XCTAssertEqual(segmentation[SegKey.name] as? String, "Cart")
        XCTAssertEqual(TestUtils.int(segmentation[SegKey.visit]), 1)
    }

    // MARK: - Stopping a view

    func testStoppingAViewByIDReportsItsDurationAgainstTheSameID() {
        let countly = viewInstance()

        guard let viewID = countly.views.startView("Home") else {
            XCTFail("the view should have started")
            return
        }
        TestUtils.pump(1.1)
        countly.views.stopView(id: viewID)

        let events = viewEvents(of: countly)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[1]["id"] as? String, viewID)

        let duration = TestUtils.double(events[1]["dur"]) ?? 0
        XCTAssertGreaterThanOrEqual(duration, 1)

        let closing = (events[1]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(closing[SegKey.name] as? String, "Home")
        XCTAssertNil(closing[SegKey.visit], "only the opening event is a visit")
    }

    func testStoppingAViewByNameClosesIt() {
        let countly = viewInstance()

        countly.views.startView("Settings")
        TestUtils.pump(1.1)
        countly.views.stopView(name: "Settings")

        let events = viewEvents(of: countly)
        XCTAssertEqual(events.count, 2)
        XCTAssertGreaterThanOrEqual(TestUtils.double(events[1]["dur"]) ?? 0, 1)
    }

    func testStoppingAViewThatWasNeverStartedRecordsNothing() {
        let countly = viewInstance()

        countly.views.stopView(name: "Ghost")
        countly.views.stopView(id: "not-a-real-view-id")

        XCTAssertTrue(viewEvents(of: countly).isEmpty)
    }

    func testStopAllViewsClosesEveryOpenView() {
        let countly = viewInstance()

        countly.views.startView("A")
        countly.views.startView("B")
        TestUtils.pump(1.1)
        countly.views.stopAllViews()

        let closings = viewEvents(of: countly).filter { $0["dur"] != nil && (TestUtils.double($0["dur"]) ?? 0) > 0 }
        XCTAssertEqual(closings.count, 2)
        XCTAssertEqual(Set(closings.compactMap { ($0["segmentation"] as? [String: Any])?[SegKey.name] as? String }),
                       ["A", "B"])
    }

    // MARK: - Auto stopped views

    /// An auto stopped view closes itself when the next view opens, which is what
    /// makes a navigation stack report a duration per screen rather than leaving
    /// every screen but the last one open forever.
    func testAnAutoStoppedViewClosesWhenTheNextOneStarts() {
        let countly = viewInstance()

        countly.views.startAutoStoppedView("First")
        TestUtils.pump(1.1)
        countly.views.startAutoStoppedView("Second")

        let events = viewEvents(of: countly)
        XCTAssertEqual(events.count, 3, "first opens, first closes, second opens")

        let names = events.map { ($0["segmentation"] as? [String: Any])?[SegKey.name] as? String }
        XCTAssertEqual(names, ["First", "First", "Second"])
        XCTAssertGreaterThanOrEqual(TestUtils.double(events[1]["dur"]) ?? 0, 1)
    }

    /// A regular view stays open across a navigation, which is the whole
    /// difference between the two starts.
    func testARegularViewStaysOpenWhenTheNextOneStarts() {
        let countly = viewInstance()

        countly.views.startView("First")
        countly.views.startView("Second")

        let events = viewEvents(of: countly)
        XCTAssertEqual(events.count, 2, "two opens and no close")
        XCTAssertTrue(events.allSatisfy { ($0["dur"] as? NSNumber)?.doubleValue ?? 0 == 0 })
    }

    // MARK: - Pause and resume

    /// A pause closes the view on the server with the time so far, and a resume
    /// starts counting again, so the total the server sees excludes the pause.
    func testPausingReportsTheTimeSoFarAndResumingDoesNotDoubleCountIt() {
        let countly = viewInstance()

        guard let viewID = countly.views.startView("Article") else {
            XCTFail("the view should have started")
            return
        }

        let start = Date()
        TestUtils.pump(1.1)
        countly.views.pauseView(id: viewID)
        let pauseBegan = Date()
        TestUtils.pump(1.1)
        countly.views.resumeView(id: viewID)
        let paused = Date().timeIntervalSince(pauseBegan)
        TestUtils.pump(1.1)
        countly.views.stopView(id: viewID)
        let elapsed = Date().timeIntervalSince(start)

        let durations = viewEvents(of: countly).compactMap { TestUtils.double($0["dur"]) }.filter { $0 > 0 }
        XCTAssertEqual(durations.count, 2, "one duration for the pause and one for the stop")

        // Compared against the wall clock actually observed rather than a fixed
        // ceiling: a loaded runner stretches every wait, and a fixed bound would
        // then fail for a reason that has nothing to do with pausing. What has to
        // hold is that the reported total covers the two active spans and excludes
        // the paused one.
        let total = durations.reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, 2)
        XCTAssertLessThan(total, elapsed - paused + 1,
                          "the paused span must not be counted, elapsed: [\(elapsed)], paused: [\(paused)]")
    }

    func testPausingAViewThatDoesNotExistDoesNothing() {
        let countly = viewInstance()

        countly.views.pauseView(id: "nope")
        countly.views.resumeView(id: "nope")

        XCTAssertTrue(viewEvents(of: countly).isEmpty)
    }

    // MARK: - Global segmentation

    func testGlobalSegmentationIsAddedToEveryView() {
        let countly = viewInstance { $0.globalViewSegmentation = ["build": "beta"] }

        countly.views.startView("One")
        countly.views.startView("Two")

        for event in viewEvents(of: countly) {
            let segmentation = (event["segmentation"] as? [String: Any]) ?? [:]
            XCTAssertEqual(segmentation["build"] as? String, "beta")
        }
    }

    func testSetGlobalViewSegmentationReplacesAndUpdateMerges() {
        let countly = viewInstance()

        countly.views.setGlobalViewSegmentation(["a": 1, "b": 2])
        countly.views.updateGlobalViewSegmentation(["b": 3, "c": 4])
        countly.views.startView("Merged")

        var segmentation = (viewEvents(of: countly)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(segmentation["a"]), 1)
        XCTAssertEqual(TestUtils.int(segmentation["b"]), 3, "update overwrites an existing key")
        XCTAssertEqual(TestUtils.int(segmentation["c"]), 4)

        countly.views.setGlobalViewSegmentation(["only": "this"])
        countly.views.startView("Replaced")

        segmentation = (viewEvents(of: countly).last?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertNil(segmentation["a"], "set replaces the whole set rather than merging into it")
        XCTAssertEqual(segmentation["only"] as? String, "this")
    }

    /// A view's own segmentation is more specific than the global one, so it wins.
    func testAViewsOwnSegmentationBeatsTheGlobalOne() {
        let countly = viewInstance { $0.globalViewSegmentation = ["source": "global"] }

        countly.views.startView("Specific", segmentation: ["source": "local"])

        let segmentation = (viewEvents(of: countly)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation["source"] as? String, "local")
    }

    // MARK: - Adding segmentation to a live view

    func testSegmentationAddedWhileAViewIsOpenAppearsOnItsClose() {
        let countly = viewInstance()

        guard let viewID = countly.views.startView("Checkout") else {
            XCTFail("the view should have started")
            return
        }
        countly.views.addSegmentation(toViewWithID: viewID, segmentation: ["step": "payment"])
        countly.views.stopView(id: viewID)

        let events = viewEvents(of: countly)
        XCTAssertEqual(events.count, 2)

        let opening = (events[0]["segmentation"] as? [String: Any]) ?? [:]
        let closing = (events[1]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertNil(opening["step"], "the open had already gone out when the segmentation was added")
        XCTAssertEqual(closing["step"] as? String, "payment")
    }

    func testSegmentationCanBeAddedByViewName() {
        let countly = viewInstance()

        countly.views.startView("Profile")
        countly.views.addSegmentation(toViewWithName: "Profile", segmentation: ["tab": "photos"])
        countly.views.stopView(name: "Profile")

        let closing = (viewEvents(of: countly).last?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(closing["tab"] as? String, "photos")
    }

    // MARK: - The first view of a session

    /// `start: 1` marks the screen someone landed on, which the dashboard uses for
    /// the entry-page report. A view opened before the session exists is not that
    /// screen.
    func testOnlyTheFirstViewInsideASessionIsMarkedAsTheStart() {
        let countly = viewInstance { $0.manualSessionHandling = true }

        countly.views.startView("BeforeTheSession")
        countly.sessions.beginSession()
        countly.views.startView("Landing")
        countly.views.startView("Second")

        let events = viewEvents(of: countly)
        let starts = events.filter { (($0["segmentation"] as? [String: Any])?[SegKey.start]) != nil }

        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual((starts[0]["segmentation"] as? [String: Any])?[SegKey.name] as? String, "Landing")
    }

    // MARK: - Consent and server config

    func testNoViewIsRecordedWithoutViewTrackingConsent() {
        let countly = viewInstance {
            $0.requiresConsent = true
        }

        XCTAssertNil(countly.views.startView("Blocked"))
        XCTAssertTrue(viewEvents(of: countly).isEmpty)

        countly.consent.giveConsent(for: .viewTracking)
        XCTAssertNotNil(countly.views.startView("Allowed"))
        XCTAssertEqual(viewEvents(of: countly).count, 1)
    }

    func testTheServerCanSwitchViewTrackingOff() {
        let countly = viewInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().viewTracking(false).json()
        }

        XCTAssertNil(countly.views.startView("Suppressed"))
        XCTAssertTrue(viewEvents(of: countly).isEmpty)
    }

    // MARK: - Limits

    func testViewNamesAndSegmentationRespectTheConfiguredLimits() {
        let countly = viewInstance {
            $0.sdkInternalLimits.maxKeyLength = 6
            $0.sdkInternalLimits.maxValueSize = 4
        }

        countly.views.startView("a-name-that-is-far-too-long",
                                segmentation: ["a-long-segmentation-key": "a-long-value"])

        let segmentation = (viewEvents(of: countly)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[SegKey.name] as? String, "a-name",
                       "the view name is capped by the key limit")
        XCTAssertEqual(segmentation["a-long"] as? String, "a-lo")
    }

    // MARK: - IDs held across a background and foreground cycle

    /// Names of the view events for one screen, oldest first.
    private func events(named name: String, of instance: CountlyInstance) -> [[String: Any]] {
        viewEvents(of: instance).filter { ($0["segmentation"] as? [String: Any])?[SegKey.name] as? String == name }
    }

    /// Foregrounding reopens a view under a fresh ID, but the host still holds the
    /// one it was given. Stopping with it has to close the reopened view, or the
    /// screen stays open and is reopened on every later foreground.
    func testAViewIDStillStopsTheViewAfterABackgroundAndForeground() {
        let countly = viewInstance()
        let views = core(of: countly).modules.views

        guard let heldID = countly.views.startView("Article") else {
            XCTFail("the view should have started")
            return
        }
        views.applicationDidEnterBackground()
        views.applicationWillEnterForeground()

        countly.views.stopView(id: heldID)
        views.applicationDidEnterBackground()
        views.applicationWillEnterForeground()

        XCTAssertEqual(events(named: "Article", of: countly).count, 4,
                       "start, close on background, reopen on foreground, stop, and nothing reopened after it")
    }

    /// The held ID keeps working over any number of cycles, not only the first.
    func testAViewIDFollowsTheViewThroughSeveralCycles() {
        let countly = viewInstance()
        let views = core(of: countly).modules.views

        guard let heldID = countly.views.startView("Article") else {
            XCTFail("the view should have started")
            return
        }
        for _ in 0..<3 {
            views.applicationDidEnterBackground()
            views.applicationWillEnterForeground()
        }
        countly.views.addSegmentation(toViewWithID: heldID, segmentation: ["read": "yes"])
        countly.views.stopView(id: heldID)

        let last = events(named: "Article", of: countly).last
        XCTAssertEqual((last?["segmentation"] as? [String: Any])?["read"] as? String, "yes",
                       "segmentation added with the held ID should reach the reopened view's end event")
    }

    // MARK: - Consent withdrawal

    /// Withdrawing view consent closes every open view, manual ones included, so
    /// none of them later reports a duration that covers time the user opted out.
    func testWithdrawingViewConsentClosesManualViews() {
        let countly = viewInstance {
            $0.requiresConsent = true
            $0.consents = [.viewTracking]
        }
        let views = core(of: countly).modules.views

        countly.views.startView("Home")
        countly.consent.cancelConsent(for: .viewTracking)
        countly.consent.giveConsent(for: .viewTracking)
        views.applicationDidEnterBackground()
        views.applicationWillEnterForeground()

        XCTAssertEqual(events(named: "Home", of: countly).count, 2,
                       "the view is started, closed by the withdrawal, and never reopened")
    }

    // MARK: - Screens that report themselves

    /// The SwiftUI modifier's segmentation reaches the end event as well, which is
    /// the one carrying the duration.
    func testAReportedViewCarriesItsSegmentationOntoTheEndEvent() {
        let countly = viewInstance()

        let id = countly.views.startReportedView("Paywall", segmentation: ["plan": "pro"])
        XCTAssertNotNil(id)
        countly.views.stopReportedView(id: id ?? "", segmentation: ["plan": "pro"])

        let paywall = events(named: "Paywall", of: countly)
        XCTAssertEqual(paywall.count, 2)
        XCTAssertEqual((paywall.last?["segmentation"] as? [String: Any])?["plan"] as? String, "pro")
        XCTAssertNotNil(paywall.last?["dur"], "the end event is the one with the duration")
    }

    /// A reported view another path already closed is not stopped a second time.
    func testStoppingAReportedViewThatIsAlreadyClosedDoesNothing() {
        let countly = viewInstance()

        let id = countly.views.startReportedView("Paywall", segmentation: nil) ?? ""
        countly.views.stopAllViews()
        countly.views.stopReportedView(id: id, segmentation: nil)

        XCTAssertEqual(events(named: "Paywall", of: countly).count, 2, "one start and one end, not a second end")
    }

}
