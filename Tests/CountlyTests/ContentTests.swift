//
//  ContentTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Asking the server whether there is anything to show, and when.
///
/// The content zone is a polling loop with a lot of state around it: it must not
/// start twice, must stop when told, must not ask while a content is already on
/// screen, and must not ask at all in the states where the SDK does not know who
/// the user is. The presentation itself is a web view and belongs to a UI test;
/// what these cover is the fetching and the state machine around it.
final class ContentTests: CountlyBaseTestCase {

    /// Every test here asserts on what reached the transport, so the whole suite
    /// needs a transport it can see.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessNetworkIsInterceptable()
    }

    /// A content zone with no initial delay, so a fetch happens as soon as the zone
    /// is entered rather than several seconds later.
    ///
    /// The delay exists so content does not land on top of an application's first
    /// screen; the test process has been alive far longer than that by the time a
    /// test runs, which is what makes the delay zero here.
    private func contentInstance(_ adjust: @escaping (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        startInstance {
            $0.content.zoneTimerInterval = 30
            adjust($0)
        }
    }

    /// The content fetches the SDK has made.
    private func fetches() -> [MockURLProtocol.Captured] {
        MockURLProtocol.requests.filter { $0.path.contains("/o/sdk/content") }
    }

    private func waitForFetch(_ description: String = "a content fetch goes out") {
        TestUtils.waitUntil(description) { !self.fetches().isEmpty }
    }

    // MARK: - The request

    /// The fetch describes the device well enough for the server to pick a content
    /// that fits it: the screen it has to fit on, the language to show it in, and
    /// the kind of device it is.
    func testTheFetchDescribesTheScreenLanguageAndDeviceType() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()

        guard let request = fetches().last else { return }
        let parsed = TestUtils.parseQuery(request.query)

        TestUtils.assertBaseParameters(parsed)
        XCTAssertEqual(parsed["method"] as? String, "queue")
        XCTAssertNotNil(parsed["resolution"], "the server needs the screen to fit the content to")
        XCTAssertNotNil(parsed["la"], "the language the content should be in")
        XCTAssertNil(parsed["preview"], "an ordinary zone fetch is not a preview")
    }

    /// The server matches on the language alone, so a full locale would match
    /// nothing.
    func testTheFetchSendsTheLanguageWithoutTheRegion() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()

        let language = TestUtils.parseQuery(fetches().last?.query ?? "")["la"] as? String ?? ""
        XCTAssertFalse(language.contains("_"))
        XCTAssertFalse(language.contains("-"))
    }

    /// A preview asks for one specific content by ID and says so, which is how the
    /// server knows to serve it whether or not the user qualifies for it.
    func testAPreviewNamesItsContentAndSaysItIsAPreview() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.previewContent("content-42")
        waitForFetch()

        let parsed = TestUtils.parseQuery(fetches().last?.query ?? "")
        XCTAssertEqual(parsed["content_id"] as? String, "content-42")
        XCTAssertEqual(parsed["preview"] as? String, "true")
    }

    /// The fetch is an instant request on the read endpoint, not a queued report:
    /// content nobody is waiting for is not worth queueing.
    func testTheFetchDoesNotGoThroughTheRequestQueue() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()

        XCTAssertTrue(requestQueue(of: countly).allSatisfy { !$0.contains("method=queue") })
    }

    // MARK: - Zone lifecycle

    /// Entering twice must not start a second polling loop: the first timer would
    /// be replaced and left running with nothing holding it.
    func testEnteringTheZoneTwiceDoesNotStartASecondLoop() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()
        let afterFirst = fetches().count

        countly.content.enterContentZone()
        TestUtils.pump(0.4)

        XCTAssertEqual(fetches().count, afterFirst,
                       "the second enter should have been refused, not started another fetch")
    }

    /// Exiting and re-entering is legitimate, and has to actually work: the zone is
    /// released so the next enter is accepted.
    func testExitingReleasesTheZoneSoItCanBeEnteredAgain() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()
        let afterFirst = fetches().count

        countly.content.exitContentZone()
        countly.content.enterContentZone()

        TestUtils.waitUntil("the second visit fetches") { self.fetches().count > afterFirst }
    }

    // MARK: - Gates

    func testNothingIsFetchedWithoutContentConsent() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance { $0.requiresConsent = true }

        countly.content.enterContentZone()
        countly.content.previewContent("content-42")
        TestUtils.pump(0.4)

        XCTAssertTrue(fetches().isEmpty)
    }

    func testConsentReleasesTheZone() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance { $0.requiresConsent = true }

        countly.content.enterContentZone()
        TestUtils.pump(0.2)
        XCTAssertTrue(fetches().isEmpty)

        countly.consent.giveConsent(for: .content)
        countly.content.enterContentZone()

        waitForFetch("the zone fetches once consent arrives")
    }

    /// In temporary mode the SDK does not know who the user is, so it must not ask
    /// what to show them.
    func testNothingIsFetchedInTemporaryDeviceIDMode() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance { $0.temporaryDeviceIDMode = true; $0.deviceID = nil }

        countly.content.enterContentZone()
        TestUtils.pump(0.4)

        XCTAssertTrue(fetches().isEmpty)
    }

    func testNothingIsFetchedWhileTheServerHasNetworkingOff() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().networking(false).json()
        }

        countly.content.enterContentZone()
        TestUtils.pump(0.4)

        XCTAssertTrue(fetches().isEmpty)
    }

    // MARK: - Answers

    /// A response with no content is the ordinary case: most of the time there is
    /// nothing to show, and the zone simply tries again on the next tick.
    func testAnEmptyAnswerIsNotAnError() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()

        // The zone is still live and will ask again, rather than having torn itself
        // down over a perfectly normal answer.
        countly.content.exitContentZone()
    }

    func testAMalformedAnswerIsSurvived() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "not json at all")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()
        countly.content.exitContentZone()
    }

    func testAFailedFetchIsSurvived() {
        // No handler for the content path, so the fetch fails at the transport level.
        let countly = contentInstance()

        countly.content.enterContentZone()
        TestUtils.pump(0.4)
        countly.content.exitContentZone()
    }

    // MARK: - Presenting what the server sent

    /// A response carrying an `html` address is a content to show, and showing it
    /// is the whole point of the zone. The page itself cannot load without a
    /// server, so the load fails and the SDK takes the content back off screen,
    /// which is the path that matters here: a content that cannot load must not be
    /// left as an invisible rectangle over the application.
    func testAContentInTheResponseIsPresentedAndTornDownWhenItCannotLoad() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("content is presented in a web view, which tvOS and watchOS have no WebKit for")
        #else
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: """
        {"html": "https://example.invalid/content.html",
         "geo": {"p": {"x": 0, "y": 0, "w": 200, "h": 100},
                 "l": {"x": 0, "y": 0, "w": 200, "h": 100}}}
        """)

        let countly = contentInstance()
        countly.content.enterContentZone()
        waitForFetch()

        // Presented, then taken down again once the page fails to load. Either way
        // the zone must end up able to accept another enter rather than stuck
        // thinking a content is on screen.
        TestUtils.pump(1.0)
        countly.content.exitContentZone()
        countly.content.enterContentZone()
        TestUtils.pump(0.3)
        #endif
    }

    /// A response whose `html` is not a usable address is not presented, and must
    /// not leave the zone believing something is on screen.
    func testAContentWithAnUnusableAddressIsNotPresented() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("content is presented in a web view, which tvOS and watchOS have no WebKit for")
        #else
        MockURLProtocol.respond(pathContaining: "/o/sdk/content",
                                json: #"{"html": "", "geo": {}}"#)

        let countly = contentInstance()
        countly.content.enterContentZone()
        waitForFetch()
        TestUtils.pump(0.5)

        // The zone is still usable: exiting and re-entering fetches again.
        let before = fetches().count
        countly.content.exitContentZone()
        countly.content.enterContentZone()
        TestUtils.waitUntil("the zone still works") { self.fetches().count > before }
        #endif
    }

    /// A preview shows the content whether or not the user qualifies for it, which
    /// is what makes it a preview.
    func testAPreviewPresentsTheContentItAskedFor() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("content is presented in a web view, which tvOS and watchOS have no WebKit for")
        #else
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: """
        {"html": "https://example.invalid/preview.html", "geo": {}}
        """)

        let countly = contentInstance()
        countly.content.previewContent("content-42")
        waitForFetch()
        TestUtils.pump(1.0)
        #endif
    }

    /// While a content is on screen the zone stops asking for another one, because
    /// there is only one slot and a second answer would be thrown away.
    func testNothingIsFetchedWhileAContentIsOnScreen() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("content is presented in a web view, which tvOS and watchOS have no WebKit for")
        #else
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: """
        {"html": "https://example.invalid/content.html", "geo": {}}
        """)

        let countly = contentInstance()
        countly.content.enterContentZone()
        waitForFetch()

        // A second enter while the first answer is being presented is refused.
        countly.content.enterContentZone()
        TestUtils.pump(0.4)
        #endif
    }

    // MARK: - Refreshing

    /// A refresh waits for the request queue to drain first, because asking about a
    /// user state the server has not seen yet would get an answer based on stale
    /// data.
    func testARefreshWaitsForTheQueueToDrainBeforeFetching() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(#"{"result": "Success"}"#.utf8)) : nil
        }

        let countly = contentInstance { $0.eventSendThreshold = 100 }
        countly.events.recordEvent("something the server has not seen")

        countly.content.refreshContentZone()

        waitForFetch("the refresh fetches once the queue has drained")
    }

    /// Several refreshes before one flush would otherwise each append a runnable
    /// and all fire together, producing a burst of fetches whose extra answers are
    /// thrown away.
    func testRepeatedRefreshesAreCoalescedIntoOne() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(#"{"result": "Success"}"#.utf8)) : nil
        }

        let countly = contentInstance { $0.eventSendThreshold = 100 }
        countly.events.recordEvent("something")

        countly.content.refreshContentZone()
        countly.content.refreshContentZone()
        countly.content.refreshContentZone()

        waitForFetch()
        TestUtils.pump(0.4)

        XCTAssertEqual(fetches().count, 1, "three refreshes should produce one fetch")
    }

    func testARefreshIsSkippedWhenTheServerDisablesIt() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = contentInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().unknown("rcz", false).json()
        }

        countly.content.refreshContentZone()
        TestUtils.pump(0.4)

        XCTAssertTrue(fetches().isEmpty)
    }

    // MARK: - Configuration

    /// Polling every second or two is never what an integration means, and the
    /// cost is paid by the server, so an interval at or below the minimum is
    /// ignored and the previous one kept.
    func testAZoneTimerIntervalBelowTheMinimumIsIgnored() {
        let config = CountlyContentConfig()
        XCTAssertEqual(config.zoneTimerInterval, 30)

        config.zoneTimerInterval = 1
        XCTAssertEqual(config.zoneTimerInterval, 30, "the previous value is kept")

        config.zoneTimerInterval = 15
        XCTAssertEqual(config.zoneTimerInterval, 30, "the minimum itself is not enough")

        config.zoneTimerInterval = 60
        XCTAssertEqual(config.zoneTimerInterval, 60, "a sensible interval is accepted")
    }

    /// Halting must take the zone down with it, or a timer keeps polling for an
    /// instance that no longer exists.
    func testHaltingStopsTheZone() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()

        countly.content.enterContentZone()
        waitForFetch()

        countly.halt()
        let afterHalt = fetches().count
        TestUtils.pump(0.4)

        XCTAssertEqual(fetches().count, afterHalt)
    }

    // MARK: - Behavior settings

    /// Only the server's own zone settings move a zone the application entered.
    /// A refresh that changes anything else leaves the zone polling, and one that
    /// switches the zone on enters it afresh.
    func testOnlyAnAnswerChangingTheZoneSettingsMovesAZoneTheApplicationEntered() {
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: "{}")
        let countly = contentInstance()
        let core = core(of: countly)
        countly.content.enterContentZone()
        waitForFetch()
        let afterEnter = fetches().count

        var answer = ServerConfigBuilder().sessionUpdateInterval(120).json()
        MockURLProtocol.respond { captured in
            captured.query.contains("method=sc") ? (200, Data(answer.utf8)) : nil
        }
        core.serverConfig.fetch(config: core.config)
        TestUtils.waitUntil("the unrelated answer is applied") { core.config.updateSessionPeriod == 120 }
        TestUtils.pump(0.3)

        countly.content.enterContentZone()
        TestUtils.pump(0.4)
        XCTAssertEqual(fetches().count, afterEnter, "the answer left the zone, so a second enter was accepted")

        answer = ServerConfigBuilder().sessionUpdateInterval(120).enterContentZone(true).json()
        core.serverConfig.fetch(config: core.config)

        TestUtils.waitUntil("the server's zone setting enters the zone afresh") { self.fetches().count > afterEnter }
    }

    // MARK: - Closing from another thread

    /// Taking content off screen touches the view hierarchy, so it has to happen on
    /// the main thread. Exiting the zone is a public call an application can make
    /// from wherever it likes, most obviously from a network or database callback,
    /// so the hop has to be inside the SDK rather than assumed of the caller.
    ///
    /// The path being exercised is the one where `closeShownContent` is *not*
    /// already on the main thread, which is the branch a main-thread-only test
    /// never reaches.
    func testExitingTheZoneFromABackgroundThreadStillTakesContentDown() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("content is presented in a web view, which tvOS and watchOS have no WebKit for")
        #else
        MockURLProtocol.respond(pathContaining: "/o/sdk/content", json: """
        {"html": "https://example.invalid/content.html",
         "geo": {"p": {"x": 0, "y": 0, "w": 200, "h": 100},
                 "l": {"x": 0, "y": 0, "w": 200, "h": 100}}}
        """)

        let countly = contentInstance()
        countly.content.enterContentZone()
        waitForFetch()
        TestUtils.pump(1.0)

        let exited = expectation(description: "the exit call returns off the main thread")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread, "the point of this test is the non-main path")
            countly.content.exitContentZone()
            exited.fulfill()
        }
        wait(for: [exited], timeout: TestUtils.asyncTimeout)

        // The teardown was handed to the main queue, so it lands a turn later.
        TestUtils.pump(0.5)

        // The zone must be free again rather than stuck believing something is on
        // screen, which is the failure a dropped hop actually produces.
        let before = fetches().count
        countly.content.enterContentZone()
        TestUtils.waitUntil("the zone accepts another entry after the background exit") {
            self.fetches().count > before
        }
        #endif
    }

}
