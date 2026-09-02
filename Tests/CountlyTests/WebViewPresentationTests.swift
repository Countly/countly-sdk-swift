//
//  WebViewPresentationTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

#if os(iOS) || os(visionOS) || os(macOS)

import XCTest
import WebKit
@testable import Countly

/// Putting a content page on screen and listening to what it asks for.
///
/// Feedback widgets and content are both a web page in an overlay window above the
/// whole application, and the page talks back by navigating to a sentinel URL. That
/// makes this the one part of the SDK where a bug is visible to the user rather
/// than only on the wire: a page that never appears, never closes, or covers the
/// application with an invisible rectangle.
///
/// These drive a real `WKWebView` on the simulator. `about:blank` loads with no
/// network, and navigations are driven from JavaScript, which is exactly how a real
/// content page reaches the SDK.
final class WebViewPresentationTests: CountlyBaseTestCase {

    private var manager: WebViewManager?

    /// The page a manager is showing.
    ///
    /// Named rather than accessed directly because `WebViewManager.webView` and its
    /// `WKNavigationDelegate` methods share a name, and the compiler cannot tell
    /// them apart at a call site.
    private func page(of manager: WebViewManager) -> WKWebView? {
        manager.webView
    }

    override func tearDown() {
        if let manager { onMain { manager.close() } }
        manager = nil
        super.tearDown()
    }

    /// Runs `work` on the main thread and waits for it.
    ///
    /// Inline when already there: XCTest runs these cases on the main thread, and
    /// `DispatchQueue.main.sync` from the main thread deadlocks the runner rather
    /// than failing, which looks like a hung test rather than a broken one.
    @discardableResult
    private func onMain<T>(_ work: () -> T) -> T {
        if Thread.isMainThread { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    /// Presents `about:blank` and waits for the page to be reported as visible.
    ///
    /// Content reports itself shown from JavaScript, so the manager is told this is
    /// a feedback widget, for which loading is the signal that it appeared.
    @discardableResult
    private func present(_ countly: CountlyInstance,
                         url: String = "https://example.com/feedback/survey",
                         frame: CGRect? = nil,
                         appear: (() -> Void)? = nil,
                         dismiss: (() -> Void)? = nil) -> WebViewManager {
        let manager = WebViewManager(core: core(of: countly))
        self.manager = manager

        onMain {
            manager.present(url: URL(string: url), frame: frame, appear: appear, dismiss: dismiss)
            // Loaded from a string rather than the network: the page only has to
            // exist for the navigation delegate to become reachable.
            self.page(of: manager)?.loadHTMLString("<html><body>ok</body></html>",
                                                   baseURL: URL(string: "https://example.com/"))
        }
        return manager
    }

    /// Navigates the page to `url`, which is how a content page reaches the SDK.
    private func navigate(_ manager: WebViewManager, to url: String) {
        var finished = false
        onMain {
            guard let page = self.page(of: manager) else {
                finished = true
                return
            }
            // Percent encoded before it goes into the script: an action URL carries
            // JSON, whose quotes and braces would otherwise break out of the
            // JavaScript string literal and the navigation would never happen. A
            // real page encodes it for the same reason, and the SDK decodes it.
            let encoded = url.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~:/?#[]@!$&'()*+,;="))
            ) ?? url
            page.evaluateJavaScript("window.location.href = \"\(encoded)\";") { _, _ in
                finished = true
            }
        }
        TestUtils.waitUntil("the navigation is attempted", timeout: TestUtils.webKitTimeout) { finished }
        // The policy decision lands on a later main-thread turn.
        TestUtils.pump(0.3)
    }

    /// Replaces the page with markup of the suite's choosing, so a test can decide
    /// what the widget "drew" and assert on where the SDK then puts it.
    private func loadHTML(_ manager: WebViewManager, _ html: String) {
        onMain { self.page(of: manager)?.loadHTMLString(html, baseURL: nil) }
        // The measurement runs from `didFinish`, so the load has to complete first.
        TestUtils.pump(1.0)
    }

    private func waitForLoad(_ manager: WebViewManager) {
        TestUtils.waitUntil("the page finishes loading", timeout: TestUtils.webKitTimeout) {
            guard let page = self.page(of: manager) else { return false }
            return !page.isLoading
        }
    }

    // MARK: - Presentation

    /// The page is hidden until it loads, so a blank rectangle never flashes over
    /// the application, and the overlay is placed where it was asked to be.
    func testPresentingPutsAHiddenWebViewInAnOverlayWindow() {
        let countly = startInstance()
        let manager = present(countly)

        XCTAssertNotNil(page(of: manager))
        waitForLoad(manager)
    }

    /// A widget reports itself visible as soon as it loads, because it renders
    /// immediately and never sends a shown event of its own.
    func testAWidgetIsReportedVisibleOnceItLoads() {
        let countly = startInstance()

        let appeared = expectation(description: "the page is reported visible")
        appeared.assertForOverFulfill = false
        present(countly, appear: { appeared.fulfill() })

        wait(for: [appeared], timeout: TestUtils.webKitTimeout)
    }

    /// A URL that could not be built is not presented, and must not leave a window
    /// behind.
    func testAMissingURLPresentsNothing() {
        let countly = startInstance()
        let manager = WebViewManager(core: core(of: countly))
        self.manager = manager

        onMain { manager.present(url: nil, appear: nil, dismiss: nil) }

        XCTAssertNil(page(of: manager))
    }

    // MARK: - Closing

    /// The dismissal is reported exactly once however many times the page asks, or
    /// a host application's callback fires repeatedly for one closing.
    func testTheDismissalIsReportedExactlyOnce() {
        let countly = startInstance()

        var dismissals = 0
        let manager = present(countly, dismiss: { dismissals += 1 })
        waitForLoad(manager)

        onMain {
            manager.close()
            manager.close()
            manager.close()
        }
        TestUtils.pump(0.3)

        XCTAssertEqual(dismissals, 1)
        XCTAssertNil(page(of: manager), "closing releases the web view")
    }

    /// A page that asks to be closed is taken off screen.
    func testAPageCanCloseItself() {
        let countly = startInstance()

        let dismissed = expectation(description: "the page is dismissed")
        dismissed.assertForOverFulfill = false
        let manager = present(countly, dismiss: { dismissed.fulfill() })
        waitForLoad(manager)

        navigate(manager, to: "https://countly_action_event?close=1")

        wait(for: [dismissed], timeout: TestUtils.webKitTimeout)
    }

    /// A closing call to action carries both its event and the close, and the event
    /// must not be thrown away by the close.
    func testAClosingCallToActionStillRecordsItsEvent() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let manager = present(countly)
        waitForLoad(manager)

        let events = "[{\"key\":\"cta_tapped\",\"segmentation\":{\"id\":\"7\"}}]"
        navigate(manager, to: "https://countly_action_event?action=event&event=\(events)&close=1")

        TestUtils.waitUntil("the event reaches the queue", timeout: TestUtils.webKitTimeout) {
            !self.recordedEvents(of: countly).filter { $0["key"] as? String == "cta_tapped" }.isEmpty
        }

        let recorded = recordedEvents(of: countly).first { $0["key"] as? String == "cta_tapped" }
        XCTAssertEqual((recorded?["segmentation"] as? [String: Any])?["id"] as? String, "7")
    }

    // MARK: - Actions from the page

    func testAPageCanRecordSeveralEventsAtOnce() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let manager = present(countly)
        waitForLoad(manager)

        let events = """
        [{"key":"one","segmentation":{"a":"1"}},{"key":"two","segmentation":{"b":"2"}}]
        """
        navigate(manager, to: "https://countly_action_event?action=event&event=\(events)")

        TestUtils.waitUntil("both events reach the queue", timeout: TestUtils.webKitTimeout) {
            let keys = self.recordedEvents(of: countly).compactMap { $0["key"] as? String }
            return keys.contains("one") && keys.contains("two")
        }
    }

    /// A content event with no segmentation is dropped: the segmentation is what
    /// identifies which content and which element the event belongs to, so without
    /// it the event cannot be attributed to anything.
    func testAContentEventWithoutSegmentationIsSkipped() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let manager = present(countly)
        waitForLoad(manager)

        let events = """
        [{"key":"no_segmentation"},{"key":"","segmentation":{"a":"1"}},\
        {"key":"kept","segmentation":{"a":"1"}}]
        """.replacingOccurrences(of: "\\\n", with: "")
        navigate(manager, to: "https://countly_action_event?action=event&event=\(events)")

        TestUtils.waitUntil("the usable event reaches the queue", timeout: TestUtils.webKitTimeout) {
            self.recordedEvents(of: countly).contains { $0["key"] as? String == "kept" }
        }

        let keys = recordedEvents(of: countly).compactMap { $0["key"] as? String }
        XCTAssertEqual(keys.filter { $0 == "no_segmentation" }.count, 0)
        XCTAssertEqual(keys.filter { $0 == "kept" }.count, 1)
    }

    /// The page reporting that it is showing content is proof it did not stall, so
    /// that is what marks a content, as opposed to a feedback widget, as visible.
    func testAPageReportingItIsShownIsWhatMarksContentVisible() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let appeared = expectation(description: "the content is reported visible")
        appeared.assertForOverFulfill = false
        // Not a feedback widget path, so loading alone does not report appearance.
        let manager = present(countly,
                              url: "https://example.com/o/sdk/content",
                              appear: { appeared.fulfill() })
        waitForLoad(manager)

        let events = """
        [{"key":"[CLY]_content_shown","segmentation":{"a":"1"}}]
        """
        navigate(manager, to: "https://countly_action_event?action=event&event=\(events)")

        wait(for: [appeared], timeout: TestUtils.webKitTimeout)
    }

    /// An events payload that is not an array is ignored rather than crashing or
    /// recording nonsense.
    func testAMalformedEventsPayloadIsIgnored() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let manager = present(countly)
        waitForLoad(manager)

        navigate(manager, to: "https://countly_action_event?action=event&event=not-json")
        navigate(manager, to: "https://countly_action_event?action=event&event={\"not\":\"an array\"}")

        XCTAssertTrue(recordedEvents(of: countly).isEmpty)
    }

    func testAnUnknownActionIsIgnored() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let manager = present(countly)
        waitForLoad(manager)

        navigate(manager, to: "https://countly_action_event?action=dance")

        XCTAssertTrue(recordedEvents(of: countly).isEmpty)
        XCTAssertNotNil(page(of: manager), "an unknown action must not close the page")
    }

    /// A page that only pins its origin still covers the space it was given, rather
    /// than collapsing to nothing and becoming an invisible touch trap over the
    /// whole application.
    func testAResizeRequestMovesTheWebView() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        let before = onMain { self.page(of: manager)?.frame }
        let geometry = "{\"p\":{\"x\":10,\"y\":20,\"w\":100,\"h\":50},\"l\":{\"x\":10,\"y\":20,\"w\":100,\"h\":50}}"
        navigate(manager, to: "https://countly_action_event?action=resize_me&resize_me=\(geometry)")

        let after = onMain { self.page(of: manager)?.frame }
        XCTAssertNotEqual(before, after, "the page asked to be resized and was not")
        XCTAssertEqual(after?.width, 100)
        XCTAssertEqual(after?.height, 50)
    }

    /// A page describing only the other orientation still wants to be resized;
    /// ignoring it leaves a banner-sized content at full-screen size, swallowing
    /// every touch until it is closed.
    func testAResizeWithOnlyTheOtherOrientationStillApplies() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        let before = onMain { self.page(of: manager)?.frame }
        // Only the landscape block, on a portrait simulator.
        let geometry = "{\"l\":{\"x\":0,\"y\":0,\"w\":120,\"h\":60}}"
        navigate(manager, to: "https://countly_action_event?action=resize_me&resize_me=\(geometry)")

        let after = onMain { self.page(of: manager)?.frame }
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after?.width, 120)
    }

    /// The frame the page is given already clears the safe area, so a scroll view
    /// insetting for it a second time makes a page that exactly fills its slot
    /// taller than the slot: it scrolls, and its buttons are cut off at the bottom.
    #if !os(macOS)
    func testTheScrollViewDoesNotInsetForTheSafeAreaASecondTime() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        let behavior = onMain { self.page(of: manager)?.scrollView.contentInsetAdjustmentBehavior }
        XCTAssertEqual(behavior, .never)
    }
    #endif

    func testAMalformedResizeRequestIsIgnored() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        let before = onMain { self.page(of: manager)?.frame }
        navigate(manager, to: "https://countly_action_event?action=resize_me&resize_me=not-json")

        XCTAssertEqual(onMain { self.page(of: manager)?.frame }, before)
    }

    // MARK: - External links

    /// A link marked external never loads inside the widget: it belongs to the
    /// browser, and loading it in place would strand the user inside the overlay.
    ///
    /// The host's URL handler stands in for the browser here, and not only to keep
    /// the assertion tight. Without it the SDK reaches `NSWorkspace.open`, and the
    /// test genuinely asks the machine to launch a browser on every run: the address
    /// below does not resolve, so Launch Services answers `-50` over and over. A
    /// unit test must not depend on, or disturb, what is installed on the host.
    func testALinkMarkedExternalIsNotLoadedInPlace() {
        var handed: URL?
        let countly = startInstance {
            $0.content.contentURLHandler = { url in
                handed = url
                // Claiming the URL stops the SDK before it reaches the system opener.
                return true
            }
        }

        let manager = present(countly)
        waitForLoad(manager)

        navigate(manager, to: "https://example.com/somewhere?cly_x_int=1")

        // The page is still the one that was presented, not the external address.
        let current = onMain { self.page(of: manager)?.url?.absoluteString ?? "" }
        XCTAssertFalse(current.contains("somewhere"))

        // And it was handed off rather than merely dropped, which is the half the
        // assertion above cannot see.
        TestUtils.waitUntil("the link is handed to the host", timeout: TestUtils.webKitTimeout) {
            handed != nil
        }
        XCTAssertEqual(handed?.absoluteString, "https://example.com/somewhere?cly_x_int=1")
    }

    /// A link action with no scheme is not a link, and must not be handed to the
    /// system as one.
    func testALinkActionWithoutASchemeIsIgnored() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        navigate(manager, to: "https://countly_action_event?action=link&link=not-a-url")

        XCTAssertNotNil(page(of: manager))
    }

    // MARK: - A page that never renders

    /// A content page whose scripts failed renders nothing and would otherwise sit
    /// over the application forever. The deadline is what catches it: the page has
    /// to report itself shown within it, and a page that does not is reloaded and
    /// eventually taken down.
    func testAContentPageThatNeverReportsItselfShownIsTakenDown() {
        let countly = startInstance {
            $0.content.enableContentReloadOnStall = true
            $0.content.contentReloadOnStallTimeout = 300
        }

        let dismissed = expectation(description: "the stalled page is taken down")
        dismissed.assertForOverFulfill = false
        // A content path, not a widget: widgets report themselves shown by loading,
        // so the deadline is content only.
        present(countly, url: "https://example.com/o/sdk/content", dismiss: { dismissed.fulfill() })

        wait(for: [dismissed], timeout: TestUtils.webKitTimeout)
    }

    /// A feedback widget renders as soon as it loads and never sends a shown event,
    /// so the deadline must not apply to it or every widget would be dismissed.
    func testAWidgetIsNotSubjectToTheStallDeadline() {
        let countly = startInstance {
            $0.content.enableContentReloadOnStall = true
            $0.content.contentReloadOnStallTimeout = 300
        }

        var dismissed = false
        let manager = present(countly, dismiss: { dismissed = true })
        waitForLoad(manager)
        TestUtils.pump(1.0)

        XCTAssertFalse(dismissed, "a widget has no shown event to wait for")
    }

    /// Reporting the page shown cancels the deadline, which is the whole point of
    /// the event: it is proof the page did not stall.
    func testReportingShownCancelsTheDeadline() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.content.enableContentReloadOnStall = true
            $0.content.contentReloadOnStallTimeout = 800
        }

        var dismissed = false
        let manager = present(countly,
                              url: "https://example.com/o/sdk/content",
                              dismiss: { dismissed = true })
        waitForLoad(manager)

        let events = """
        [{"key":"[CLY]_content_shown","segmentation":{"a":"1"}}]
        """
        navigate(manager, to: "https://countly_action_event?action=event&event=\(events)")

        // Well past the deadline it would have fired at.
        TestUtils.pump(1.2)
        XCTAssertFalse(dismissed, "the page reported itself shown, so it must not be taken down")
    }

    /// A timeout of zero reads like "no timeout" and would otherwise arm a deadline
    /// that fires on the next run loop turn, dismissing every page before it could
    /// load. It is floored instead.
    func testAZeroStallTimeoutIsFlooredRatherThanTakenLiterally() {
        let countly = startInstance {
            $0.content.enableContentReloadOnStall = true
            $0.content.contentReloadOnStallTimeout = 0
        }

        var dismissed = false
        let manager = present(countly,
                              url: "https://example.com/o/sdk/content",
                              dismiss: { dismissed = true })
        waitForLoad(manager)
        TestUtils.pump(0.8)

        XCTAssertFalse(dismissed, "a zero timeout must not dismiss the page immediately")
    }

    /// Without the switch there is no deadline at all, which is the default: an
    /// application that has not asked for reloads keeps whatever the page does.
    func testWithoutTheReloadSwitchThereIsNoDeadline() {
        let countly = startInstance { $0.content.enableContentReloadOnStall = false }

        var dismissed = false
        let manager = present(countly,
                              url: "https://example.com/o/sdk/content",
                              dismiss: { dismissed = true })
        waitForLoad(manager)
        TestUtils.pump(1.0)

        XCTAssertFalse(dismissed)
    }
    #if os(iOS) || os(visionOS)
    /// A page pinned to portrait keeps its layout when the interface rotates, which
    /// is what `disableRotation` is for.
    func testAPagePinnedToPortraitIgnoresAnInterfaceSizeChange() {
        let countly = startInstance { $0.content.disableRotation = true }

        let manager = present(countly, url: "https://example.com/o/sdk/content")
        waitForLoad(manager)

        let before = onMain { self.page(of: manager)?.frame }
        // The controller reports a size change the way a rotation does.
        onMain {
            (manager.webView?.window?.rootViewController as? WebViewController)?
                .viewWillTransition(to: CGSize(width: 667, height: 375),
                                    with: DummyTransitionCoordinator())
        }
        TestUtils.pump(0.2)

        XCTAssertEqual(onMain { self.page(of: manager)?.frame }, before)
    }
    #endif

    // MARK: - Reading the queue

    private func recordedEvents(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
    }

    // MARK: - Which monitor the overlay lands on

    /// The panel's rect is a position on the desktop, and the desktop spans every
    /// display, so the origin is what decides which monitor content appears on.
    ///
    /// This was zeroed, on the reasoning that the geometry a content page sends is
    /// relative to the overlay rather than to the desktop. That is true of the
    /// page's coordinates and false of the window's: a zero origin is not "wherever
    /// the application is", it is a specific point on whichever display owns the
    /// global origin. On a single-monitor machine the two coincide and nothing looks
    /// wrong, which is why it survived. With a second monitor content opened on the
    /// primary display while the application was on the other one.
    #if os(macOS)
    func testTheOverlayFrameKeepsTheOriginOfTheScreenTheApplicationIsOn() throws {
        guard let screen = ScreenReader.activeScreen else {
            throw XCTSkip("no screen attached, so there is no placement to assert")
        }

        // Deliberately the whole rect and not just the size. Asserting the size
        // alone is what let the origin be dropped in the first place.
        XCTAssertEqual(ScreenReader.overlayFrame, screen.visibleFrame,
                       "the overlay frame is the active screen's visible frame, origin included")
    }

    /// `screenBounds` stays origin-less on purpose, because its callers want a size:
    /// the reported device metrics, and view frames whose coordinates start at zero
    /// whatever desktop position their window has. The two must not be conflated
    /// again, so the difference between them is asserted rather than assumed.
    func testScreenBoundsReportsASizeWhileTheOverlayFrameReportsAPosition() throws {
        guard let screen = ScreenReader.activeScreen else {
            throw XCTSkip("no screen attached")
        }

        XCTAssertEqual(ScreenReader.screenBounds.origin, .zero)
        XCTAssertEqual(ScreenReader.screenBounds.size, screen.visibleFrame.size,
                       "the two agree on size and differ only in origin")
        XCTAssertEqual(ScreenReader.overlayFrame.size, screen.visibleFrame.size)
    }

    /// The behaviour the two above exist to protect: a freshly built overlay sits on
    /// the screen the application is on, not on some other one.
    func testANewOverlayLandsOnTheScreenTheApplicationIsOn() throws {
        guard let screen = ScreenReader.activeScreen else {
            throw XCTSkip("no screen attached")
        }
        let overlay = OverlayWindow()
        defer { overlay.close() }

        // `NSWindow` may inset the frame it was asked for, so intersection is the
        // honest assertion: whatever AppKit did with the rect, it stayed on this
        // screen. On one monitor this always holds; on two it is the whole point.
        XCTAssertTrue(screen.frame.intersects(overlay.frame),
                      "the overlay opened away from the application's screen")
    }
    #endif


    // MARK: - A placed page keeps its placement

    /// The server places content deliberately: it returns a rect, and a banner that
    /// was laid out as 435x144 in the corner has to stay 435x144 in the corner.
    ///
    /// Regression test. A re-layout used to replace that rect with one filling the
    /// whole window, because the fill is what a feedback widget wants and the two
    /// shared a path. On iOS the re-layout only runs on rotation so it was never
    /// seen; on macOS `viewDidLayout` runs during the presentation itself, so a
    /// placed banner was blown up to the full screen before it was ever displayed.
    func testAPageTheServerPlacedIsNotResizedToFillTheWindow() {
        let countly = startInstance()
        let placement = CGRect(x: 16, y: 40, width: 435, height: 144)

        let manager = present(countly, frame: placement)
        waitForLoad(manager)

        // The size change the platform delivers on its own during presentation, and
        // again on any later layout pass.
        onMain { manager.simulateInterfaceSizeChangeForTesting() }
        TestUtils.pump(0.3)

        guard let size = onMain({ self.page(of: manager)?.frame.size }) else {
            XCTFail("the page should still be present")
            return
        }
        XCTAssertEqual(size.width, placement.width, accuracy: 1,
                       "the placed page was resized to fill the window")
        XCTAssertEqual(size.height, placement.height, accuracy: 1,
                       "the placed page was resized to fill the window")
    }

    /// The counterpart: a page with no placement of its own still fills the window
    /// and must keep doing so, which is what distinguishes it from a placed page.
    func testAPageWithNoPlacementStillFillsTheWindow() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        let container = onMain { manager.containerSizeForTesting }
        onMain { manager.simulateInterfaceSizeChangeForTesting() }
        TestUtils.pump(0.3)

        guard let size = onMain({ self.page(of: manager)?.frame.size }) else {
            XCTFail("the page should still be present")
            return
        }
        XCTAssertEqual(size.width, container.width, accuracy: 1,
                       "a page with no placement fills the window")
    }


    // MARK: - A link that also asks to close

    /// A call to action that opens something and dismisses itself carries `close`
    /// inside the link, not beside it: the page appends it to the address, so the
    /// URL reads `mailto:a@b.com?close=1`.
    ///
    /// Regression test. Only a top-level `close` parameter used to be honoured, so
    /// the mail client opened and the content stayed on screen behind it forever.
    /// The query parser is not at fault and is deliberately left alone: it splits on
    /// `&close=`, and this is a `?close=` that belongs to the URL.
    func testALinkCarryingCloseInsideItDismissesTheContent() {
        let countly = startInstance()
        var handed: URL?
        core(of: countly).config.content.contentURLHandler = { url in
            handed = url
            return true
        }

        var dismissed = false
        let manager = present(countly, dismiss: { dismissed = true })
        waitForLoad(manager)

        navigate(manager, to: "https://countly_action_event?cly_x_action_event=1&action=link&link=mailto:a@b.com?close=1")

        TestUtils.waitUntil("the content is taken down", timeout: TestUtils.webKitTimeout) { dismissed }

        // And the flag is Countly's, so it does not travel on to the mail client.
        XCTAssertEqual(handed?.absoluteString, "mailto:a@b.com")
    }

    /// The same link without the flag opens and leaves the content up, which is what
    /// makes the flag mean something.
    func testALinkWithoutCloseLeavesTheContentUp() {
        let countly = startInstance()
        var handed: URL?
        core(of: countly).config.content.contentURLHandler = { url in
            handed = url
            return true
        }

        var dismissed = false
        let manager = present(countly, dismiss: { dismissed = true })
        waitForLoad(manager)

        navigate(manager, to: "https://countly_action_event?cly_x_action_event=1&action=link&link=mailto:a@b.com")

        TestUtils.waitUntil("the link is handed over", timeout: TestUtils.webKitTimeout) { handed != nil }
        TestUtils.pump(0.4)

        XCTAssertEqual(handed?.absoluteString, "mailto:a@b.com")
        XCTAssertFalse(dismissed, "nothing asked for the content to close")
    }


    // MARK: - Resizing

    /// The page's geometry is applied exactly as given. The SDK adds no placement
    /// rule of its own: whatever the page or the server asked for is what it gets.
    func testAResizeIsAppliedExactlyAsThePageAskedFor() {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/content")
        waitForLoad(manager)

        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":16,"y":40,"w":400,"h":300},"p":{"x":16,"y":40,"w":400,"h":300}}"#)
        TestUtils.pump(0.5)

        guard let frame = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the page should have been placed")
            return
        }
        XCTAssertEqual(frame.origin.x, 16, accuracy: 1)
        XCTAssertEqual(frame.origin.y, 40, accuracy: 1)
    }




    // MARK: - Measuring what a widget actually drew

    /// A widget page is handed the whole window and never asks to be resized, so on
    /// a screen far larger than it was drawn for it lays out against a viewport it
    /// was never designed for. Rather than pick a size, the SDK asks the page how
    /// big it made itself and places it there, so the answer comes from the page's
    /// own CSS.
    func testAWidgetIsPlacedWhereItActuallyDrewItself() throws {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/feedback/nps")
        waitForLoad(manager)

        let container = onMain { manager.containerSizeForTesting }
        try XCTSkipUnless(container.width > 400 && container.height > 300,
                          "this window is too small for the measurement to differ from a fill")

        // A page whose content is a fixed box, which is what a widget with a
        // `max-width` card looks like to the measurement.
        loadHTML(manager, """
        <html><body style="margin:0">
          <div style="position:absolute;left:40px;top:60px;width:300px;height:200px;background:#333"></div>
        </body></html>
        """)

        TestUtils.waitUntil("the widget is placed where it drew itself",
                            timeout: TestUtils.webKitTimeout) {
            (onMain { manager.placedFrameForTesting?.width } ?? 0) <= 320
        }

        guard let frame = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the widget should have been placed")
            return
        }
        XCTAssertEqual(frame.width, 300, accuracy: 2)
        XCTAssertEqual(frame.height, 200, accuracy: 2)
        XCTAssertEqual(frame.origin.x, 40, accuracy: 2)
        XCTAssertEqual(frame.origin.y, 60, accuracy: 2)
    }

    /// A page that genuinely fills is left exactly as it was. The measurement exists
    /// to catch a widget adrift in a huge viewport, and it must not shrink a page
    /// that meant to cover the window.
    func testAWidgetThatFillsTheWindowIsLeftAlone() {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/feedback/nps")
        waitForLoad(manager)

        let container = onMain { manager.containerSizeForTesting }

        loadHTML(manager, """
        <html><body style="margin:0">
          <div style="width:100%;height:100%;background:#333"></div>
        </body></html>
        """)
        TestUtils.pump(1.0)

        guard let frame = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the page should still be present")
            return
        }
        XCTAssertEqual(frame.width, container.width, accuracy: 1,
                       "a page that fills should keep the whole window")
    }

}

#if os(iOS) || os(visionOS)
/// The minimum a `viewWillTransition` needs, since the real one only exists during
/// an actual rotation.
private final class DummyTransitionCoordinator: NSObject, UIViewControllerTransitionCoordinator {
    var isAnimated: Bool { false }
    var presentationStyle: UIModalPresentationStyle { .none }
    var initiallyInteractive: Bool { false }
    var isInterruptible: Bool { false }
    var isInteractive: Bool { false }
    var isCancelled: Bool { false }
    var transitionDuration: TimeInterval { 0 }
    var percentComplete: CGFloat { 1 }
    var completionVelocity: CGFloat { 0 }
    var completionCurve: UIView.AnimationCurve { .linear }
    var containerView: UIView { UIView() }
    var targetTransform: CGAffineTransform { .identity }

    func viewController(forKey key: UITransitionContextViewControllerKey) -> UIViewController? { nil }
    func view(forKey key: UITransitionContextViewKey) -> UIView? { nil }

    func animate(alongsideTransition animation: ((UIViewControllerTransitionCoordinatorContext) -> Void)?,
                 completion: ((UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool {
        completion?(self)
        return true
    }

    func animateAlongsideTransition(in view: UIView?,
                                    animation: ((UIViewControllerTransitionCoordinatorContext) -> Void)?,
                                    completion: ((UIViewControllerTransitionCoordinatorContext) -> Void)?) -> Bool {
        completion?(self)
        return true
    }

    #if !os(visionOS)
    // Deprecated everywhere and unavailable on visionOS, but still part of the
    // protocol on the platforms that have it.
    func notifyWhenInteractionEnds(_ handler: @escaping (UIViewControllerTransitionCoordinatorContext) -> Void) {}
    #endif

    func notifyWhenInteractionChanges(_ handler: @escaping (UIViewControllerTransitionCoordinatorContext) -> Void) {}
}
#endif

#endif
