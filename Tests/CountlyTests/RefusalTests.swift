//
//  RefusalTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The calls the SDK declines, and the states in which it declines everything.
///
/// Almost every public method starts with a short stack of guards: an empty key,
/// a missing consent, a temporary device ID, a switch the server turned off. Each
/// one exists because acting anyway would put something on the wire that cannot be
/// attributed, cannot be aggregated, or should never have left the device. They are
/// individually dull and collectively most of the SDK's behaviour, so they are
/// asserted rather than assumed.
final class RefusalTests: CountlyBaseTestCase {

    private static let accepted = #"{"result": "Success"}"#

    /// Every event the instance produced.
    private func events(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
    }

    private func viewEvents(of instance: CountlyInstance) -> [[String: Any]] {
        events(of: instance).filter { $0["key"] as? String == ReservedEventKey.view }
    }

    // MARK: - Empty identifiers

    /// An empty name or ID identifies nothing, so every call that takes one refuses
    /// rather than acting on the wrong thing or on everything.
    func testEveryCallTakingAnIdentifierRefusesAnEmptyOne() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.views.stopView(name: "")
        countly.views.stopView(id: "")
        countly.views.pauseView(id: "")
        countly.views.resumeView(id: "")
        countly.views.addSegmentation(toViewWithID: "", segmentation: ["a": 1])
        countly.views.addSegmentation(toViewWithName: "", segmentation: ["a": 1])
        countly.events.startEvent("")
        countly.events.endEvent("")
        countly.events.cancelEvent("")
        countly.performance.startCustomTrace("")
        countly.performance.endCustomTrace("", metrics: nil)
        countly.performance.cancelCustomTrace("")

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    /// Naming a view or trace that does not exist is a caller mistake, not a reason
    /// to invent one.
    func testActingOnSomethingThatDoesNotExistRefuses() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.views.addSegmentation(toViewWithID: "no-such-view", segmentation: ["a": 1])
        countly.views.addSegmentation(toViewWithName: "NoSuchView", segmentation: ["a": 1])
        countly.views.stopView(id: "no-such-view")
        countly.views.pauseView(id: "no-such-view")
        countly.views.resumeView(id: "no-such-view")

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    /// Segmentation added to a view is only useful while that view is open; adding
    /// it after the view closed has nowhere to go.
    func testSegmentationAddedAfterAViewClosedIsRefused() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        guard let viewID = countly.views.startView("Checkout") else {
            XCTFail("the view should have started")
            return
        }
        countly.views.stopView(id: viewID)
        let before = requestQueue(of: countly).count

        countly.views.addSegmentation(toViewWithID: viewID, segmentation: ["late": "yes"])

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    // MARK: - Consent

    /// Adding segmentation to a view is view tracking, so it answers to the same
    /// consent the view itself does.
    func testAddingSegmentationNeedsViewConsent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }
        countly.consent.giveConsent(for: .viewTracking)

        guard let viewID = countly.views.startView("Open") else {
            XCTFail("the view should have started")
            return
        }
        countly.consent.cancelConsent(for: .viewTracking)
        countly.views.addSegmentation(toViewWithID: viewID, segmentation: ["late": "yes"])

        // Withdrawing view consent closes the open views, so nothing further is
        // recorded against them.
        countly.views.stopView(id: viewID)
        let closing = viewEvents(of: countly).filter { (TestUtils.double($0["dur"]) ?? 0) > 0 }
        XCTAssertTrue(closing.allSatisfy {
            (($0["segmentation"] as? [String: Any])?["late"]) == nil
        })
    }

    // MARK: - Stopping everything

    /// Stopping every view has to close every one of them, not just the newest, or
    /// the older ones stay open on the server forever.
    func testStoppingAllViewsClosesEveryOpenOne() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.views.startView("A")
        countly.views.startView("B")
        countly.views.startView("C")
        TestUtils.pump(1.1)
        countly.views.stopAllViews(segmentation: ["reason": "logout"])

        let closings = viewEvents(of: countly).filter { (TestUtils.double($0["dur"]) ?? 0) > 0 }
        XCTAssertEqual(closings.count, 3)
        for closing in closings {
            XCTAssertEqual((closing["segmentation"] as? [String: Any])?["reason"] as? String, "logout")
        }
    }

    /// Stopping all views with nothing open is a no-op rather than an error, which
    /// is what lets an application call it on logout without checking first.
    func testStoppingAllViewsWithNothingOpenIsHarmless() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.views.stopAllViews()

        XCTAssertTrue(viewEvents(of: countly).isEmpty)
    }

    // MARK: - Terminating and modifying

    /// Once the application is terminating no new request may start: the process is
    /// going away and a request begun now would be cut off mid-flight.
    func testTheQueueIsNotDrainedWhileTerminating() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: Self.accepted)

        let countly = startInstance { $0.eventSendThreshold = 1 }
        core(of: countly).isTerminating = true

        countly.events.recordEvent("during-termination")
        TestUtils.pump(0.3)

        XCTAssertFalse(requestQueue(of: countly).isEmpty,
                       "the request is kept for the next launch rather than started now")
    }

    /// While the queue is being rewritten, which happens when a device ID or app
    /// key changes, the drain has to stand off: sending a request that is about to
    /// be rewritten would send the old form.
    func testTheQueueIsNotDrainedWhileItIsBeingRewritten() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: Self.accepted)

        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("queued")

        // Rewriting is what a device ID change does, and it holds the flag for the
        // duration. Observed through the public call that performs one.
        countly.requestQueue.replaceAllAppKeysInQueueWithCurrentAppKey()

        TestUtils.waitUntil("the queue drains once the rewrite is done") {
            self.requestQueue(of: countly).isEmpty
        }
    }

    // MARK: - Custom headers

    /// A header with no name cannot be sent, and must not take the rest of the
    /// batch down with it.
    func testAHeaderWithNoNameIsSkippedWithoutLosingTheOthers() {
        let countly = startInstance()

        countly.addCustomNetworkRequestHeaders(["": "ignored", "X-Tenant": "acme"])

        let headers = core(of: countly).config.urlSessionConfiguration
            .httpAdditionalHeaders as? [String: String]
        XCTAssertEqual(headers?["X-Tenant"], "acme")
        XCTAssertNil(headers?[""])
    }

    func testPassingNoHeadersAtAllIsHarmless() {
        let countly = startInstance()

        countly.addCustomNetworkRequestHeaders(nil)
        countly.addCustomNetworkRequestHeaders([:])
    }

    // MARK: - A host that cannot be turned into a URL

    /// A host that cannot form a URL leaves the crash report in the queue rather
    /// than dropping it: the host may be fixed on a later launch, and trapping
    /// while the application is already crashing is the worst possible moment.
    func testACrashIsQueuedWhenTheServerURLCannotBeBuilt() {
        let countly = startInstance {
            $0.features = [.crashReporting]
            // Reachable only through a host that survives validation but cannot be
            // turned into a URL.
            $0.host = "https://exa mple.com"
        }

        reportAutoDetectedCrash(on: countly)

        XCTAssertEqual(requestQueue(of: countly).filter { $0.contains("crash=") }.count, 1)
    }

    // MARK: - Flush runnables after a failure

    /// The flush runnables only fire when the queue drained with nothing having
    /// failed. A partial drain is not the server having seen everything, so a
    /// feature waiting on that must not be told it has.
    func testFlushRunnablesDoNotFireWhenARequestFailed() throws {
        try skipUnlessNetworkIsInterceptable()

        // The first request is accepted and the second is refused, so the drain
        // stops part way.
        var answered = 0
        MockURLProtocol.respond { _ in
            answered += 1
            return answered == 1 ? (200, Data(Self.accepted.utf8)) : (500, Data())
        }

        let countly = startInstance { $0.eventSendThreshold = 1 }

        var fired = false
        countly.requestQueue.addQueueFlushRunnable { fired = true }

        countly.events.recordEvent("first")
        countly.events.recordEvent("second")
        TestUtils.pump(0.6)

        XCTAssertFalse(fired, "the queue did not drain cleanly, so nothing may act as though it had")
    }

    // MARK: - Orientation

    /// The orientation event is only recorded when the orientation actually
    /// changed: reporting it on every foreground would flood the dashboard with a
    /// value that did not move.
    func testTheOrientationIsOnlyReportedWhenItChanges() throws {
        #if !os(iOS)
        throw XCTSkip("orientation is only reported where the interface has one")
        #else
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let views = core(of: countly).modules.views

        views.recordOrientation()
        let afterFirst = events(of: countly).filter {
            $0["key"] as? String == ReservedEventKey.orientation
        }.count

        views.recordOrientation()
        views.recordOrientation()

        let afterRepeats = events(of: countly).filter {
            $0["key"] as? String == ReservedEventKey.orientation
        }.count
        XCTAssertEqual(afterRepeats, afterFirst, "an unchanged orientation is not an event")
        #endif
    }

    /// The orientation describes the person using the device, so it answers to user
    /// details consent rather than to view tracking.
    func testTheOrientationNeedsUserDetailsConsent() throws {
        #if !os(iOS)
        throw XCTSkip("orientation is only reported where the interface has one")
        #else
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }
        countly.consent.giveConsent(for: .viewTracking)

        core(of: countly).modules.views.recordOrientation()

        XCTAssertTrue(events(of: countly).filter {
            $0["key"] as? String == ReservedEventKey.orientation
        }.isEmpty)
        #endif
    }

    /// Orientation tracking is on by default but can be switched off, for an
    /// application that does not want the extra events.
    func testOrientationTrackingCanBeSwitchedOff() throws {
        #if !os(iOS)
        throw XCTSkip("orientation is only reported where the interface has one")
        #else
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.enableOrientationTracking = false
        }

        core(of: countly).modules.views.recordOrientation()

        XCTAssertTrue(events(of: countly).filter {
            $0["key"] as? String == ReservedEventKey.orientation
        }.isEmpty)
        #endif
    }
}
