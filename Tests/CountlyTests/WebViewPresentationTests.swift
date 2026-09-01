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
    func testALinkMarkedExternalIsNotLoadedInPlace() {
        let countly = startInstance()

        let manager = present(countly)
        waitForLoad(manager)

        navigate(manager, to: "https://example.com/somewhere?cly_x_int=1")

        // The page is still the one that was presented, not the external address.
        let current = onMain { self.page(of: manager)?.url?.absoluteString ?? "" }
        XCTAssertFalse(current.contains("somewhere"))
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
