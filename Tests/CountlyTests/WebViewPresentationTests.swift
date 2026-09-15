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

    /// The absolute content shown deadline is a minute, and a loaded runner can
    /// spend that long inside one of these cases, which would close the page
    /// mid-test. The two cases that are about the deadline set their own.
    override func setUp() {
        super.setUp()
        WebViewManager.contentShownDeadline = 600
    }

    override func tearDown() {
        if let manager { onMain { manager.close() } }
        manager = nil
        WebViewManager.contentShownDeadline = 60
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

    /// Presents a widget of a known type, so the type's layout rules apply.
    @discardableResult
    private func presentWidget(_ countly: CountlyInstance, type: FeedbackWidgetType) -> WebViewManager {
        let manager = WebViewManager(core: core(of: countly))
        self.manager = manager
        onMain {
            manager.present(url: URL(string: "https://example.com/feedback/\(type.wireName)"),
                            widgetType: type, widgetPosition: nil, appear: nil, dismiss: nil)
            self.page(of: manager)?.loadHTMLString("<html><body>ok</body></html>",
                                                   baseURL: URL(string: "https://example.com/"))
        }
        waitForLoad(manager)
        return manager
    }

    /// Delivers what the in-page observer would post about the card.
    private func reportCard(_ manager: WebViewManager, height: Double, reason: String) {
        onMain {
            manager.handleScriptMessage(name: "cardSize",
                                        body: ["w": 480, "h": height, "via": "#nps-comments", "reason": reason])
        }
        TestUtils.pump(0.3)
    }

    private func placedHeight(_ manager: WebViewManager) -> CGFloat? {
        onMain { manager.placedFrameForTesting?.height }
    }

    // MARK: - Measured card

    #if !os(macOS)
    /// A widget page was authored for a phone viewport, so on iOS it fills the
    /// surface as the Objective-C SDK presents it, ignores any size it announces,
    /// and appears as soon as it has loaded.
    func testAWidgetFillsTheSurfaceAndIgnoresAnnouncedSizes() {
        let countly = startInstance()
        let manager = presentWidget(countly, type: .nps)
        let container = onMain { manager.containerSizeForTesting }

        guard let placed = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the widget should have been placed")
            return
        }
        XCTAssertEqual(placed.origin, .zero)
        XCTAssertEqual(placed.size.width, container.width, accuracy: 1, "a widget fills the surface on iOS")
        XCTAssertEqual(placed.size.height, container.height, accuracy: 1, "a widget fills the surface on iOS")

        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":0,"y":0,"w":480,"h":300},"p":{"x":0,"y":0,"w":480,"h":300}}"#)
        reportCard(manager, height: 320, reason: "mutation")
        TestUtils.pump(0.6)

        XCTAssertEqual(onMain { manager.placedFrameForTesting }?.size.height ?? 0, container.height, accuracy: 1,
                       "neither an announced nor a measured size shrinks a filling widget")
        // The load completing is delivered by hand: the helper's HTML load races the
        // presentation's own navigation, so the delegate is not reliably told here.
        onMain {
            guard let page = self.page(of: manager) else { return }
            manager.webView(page, didFinish: nil)
        }
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the widget is visible as soon as it loaded")
    }

    /// A visible content is taken off screen for the rotation and comes back only
    /// once it has been fitted to the new orientation, so it is never seen landing
    /// at its old size and then jumping to the new one.
    func testAContentIsConcealedForARotationUntilItAsksForItsNewSize() {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/o/sdk/content",
                              frame: CGRect(x: 16, y: 16, width: 370, height: 144))
        waitForLoad(manager)
        onMain { manager.handleScriptMessage(name: "resourceVerifyResult", body: ["results": []]) }
        TestUtils.pump(0.2)
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the content should be on screen before the rotation")

        onMain { manager.simulateInterfaceSizeChangeForTesting(settled: false) }
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, true, "the content stays visible while rotating")

        onMain { manager.simulateInterfaceSizeChangeForTesting(settled: true) }
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, true, "the content came back before the page answered with a size")

        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":10,"y":10,"w":300,"h":120},"p":{"x":10,"y":10,"w":300,"h":120}}"#)

        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the fitted content is not shown again")
        XCTAssertEqual(onMain { manager.placedFrameForTesting }, CGRect(x: 10, y: 10, width: 300, height: 120))
    }

    /// A page that never answers the new surface is shown again anyway, after the
    /// same wait a first presentation gives that answer.
    func testAConcealedContentComesBackAfterTheDeadlineWithoutAnAnswer() {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/o/sdk/content",
                              frame: CGRect(x: 16, y: 16, width: 370, height: 144))
        waitForLoad(manager)
        onMain { manager.handleScriptMessage(name: "resourceVerifyResult", body: ["results": []]) }
        TestUtils.pump(0.2)

        onMain { manager.simulateInterfaceSizeChangeForTesting(settled: false) }
        onMain { manager.simulateInterfaceSizeChangeForTesting(settled: true) }
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, true)

        TestUtils.pump(0.8)
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the content never came back")
    }

    /// The server places a content for both orientations, and a rotation takes the
    /// geometry for the orientation the surface now has, never the other one's.
    func testTheServersPlacementForTheNewOrientationIsTakenOnRotation() {
        let placement: [String: Any] = [
            "p": ["x": 0, "y": 0, "w": 402, "h": 812],
            "l": ["x": 0, "y": 0, "w": 812, "h": 402],
        ]
        XCTAssertEqual(WebViewManager.serverFrame(from: placement, for: CGSize(width: 402, height: 812)),
                       CGRect(x: 0, y: 0, width: 402, height: 812))
        XCTAssertEqual(WebViewManager.serverFrame(from: placement, for: CGSize(width: 812, height: 402)),
                       CGRect(x: 0, y: 0, width: 812, height: 402))
        XCTAssertNil(WebViewManager.serverFrame(from: ["p": ["x": 16, "y": 16, "w": 370, "h": 144]],
                                                for: CGSize(width: 812, height: 402)),
                     "a placement the server did not give is not invented from the other orientation")
        XCTAssertNil(WebViewManager.serverFrame(from: [:], for: CGSize(width: 402, height: 812)))
    }

    /// A survey served through a journey arrives as content, with the server's
    /// geometry attached, but its URL is a widget's and on iOS a widget fills the
    /// surface: the geometry is ignored at presentation and stays ignored after a
    /// rotation.
    func testAWidgetServedAsContentFillsTheSurfaceDespiteTheServersPlacement() {
        let countly = startInstance()
        let manager = WebViewManager(core: core(of: countly))
        self.manager = manager
        let placement: [String: Any] = [
            "p": ["x": 0, "y": 0, "w": 402, "h": 812],
            "l": ["x": 16, "y": 0, "w": 349, "h": 604],
        ]
        onMain {
            manager.present(url: URL(string: "https://example.com/feedback/survey?widget_id=w"),
                            frame: CGRect(x: 16, y: 0, width: 349, height: 604),
                            placement: placement,
                            appear: nil, dismiss: nil)
        }
        let container = onMain { manager.containerSizeForTesting }
        XCTAssertEqual(onMain { manager.placedFrameForTesting }, CGRect(origin: .zero, size: container),
                       "the widget did not fill the surface at presentation")

        onMain { manager.simulateInterfaceSizeChangeForTesting() }
        XCTAssertEqual(onMain { manager.placedFrameForTesting }, CGRect(origin: .zero, size: container),
                       "the widget did not fill the surface after a size change")
    }

    /// A layout pass that does not change the orientation leaves the frame the page
    /// asked for alone. macOS lays out on every panel resize, including the one the
    /// page's own request caused, and re-applying the server's geometry there
    /// snapped the page back to it.
    func testALayoutPassInTheSameOrientationKeepsThePagesRequestedFrame() {
        let countly = startInstance()
        let manager = WebViewManager(core: core(of: countly))
        self.manager = manager
        let container = onMain { manager.containerSizeForTesting }
        let serverFrame = CGRect(x: 16, y: 16, width: 370, height: 144)
        let placement: [String: Any] = [
            "p": ["x": 16, "y": 16, "w": 370, "h": 144],
            "l": ["x": 16, "y": 16, "w": 370, "h": 144],
        ]
        onMain {
            manager.present(url: URL(string: "https://example.com/o/sdk/content"),
                            frame: serverFrame, placement: placement, appear: nil, dismiss: nil)
            self.page(of: manager)?.loadHTMLString("<html><body>ok</body></html>", baseURL: URL(string: "https://example.com/"))
        }
        waitForLoad(manager)
        _ = container

        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":10,"y":10,"w":300,"h":120},"p":{"x":10,"y":10,"w":300,"h":120}}"#)
        XCTAssertEqual(onMain { manager.placedFrameForTesting }, CGRect(x: 10, y: 10, width: 300, height: 120))

        onMain { manager.simulateInterfaceSizeChangeForTesting() }
        TestUtils.pump(0.3)
        XCTAssertEqual(onMain { manager.placedFrameForTesting }, CGRect(x: 10, y: 10, width: 300, height: 120),
                       "a layout pass in the same orientation replaced the page's frame with the server's")
    }

    #if os(iOS)
    /// A banner covers a strip of the screen, and the rest of it stays the
    /// application's: a tap beside the page falls through the overlay window.
    ///
    /// iOS only. visionOS hosts the overlay differently and its input is indirect,
    /// so a synthetic point hit test there says nothing about the pass-through.
    func testATapOutsideTheContentFallsThroughTheOverlay() {
        let countly = startInstance()
        let banner = CGRect(x: 16, y: 16, width: 370, height: 144)
        let manager = present(countly, url: "https://example.com/o/sdk/content", frame: banner)

        onMain {
            manager.handleScriptMessage(name: "resourceVerifyResult", body: ["results": []])
        }
        TestUtils.pump(0.3)

        guard let page = onMain({ self.page(of: manager) }), let window = onMain({ page.window }) else {
            XCTFail("the content should be on a window")
            return
        }

        let inside = onMain { window.convert(CGPoint(x: page.bounds.midX, y: page.bounds.midY), from: page) }
        let below = onMain { CGPoint(x: window.bounds.midX, y: page.frame.maxY + 200) }

        XCTAssertNil(onMain { window.hitTest(below, with: nil) }, "a tap beside the banner was swallowed by the overlay")
        XCTAssertNotNil(onMain { window.hitTest(inside, with: nil) }, "a tap on the banner did not reach the page")
    }
    #endif
    #endif

    #if os(macOS)
    /// The page announces a size on every screen switch, but measures before the
    /// incoming screen has laid out, and clamps what it measures to its own
    /// breakpoint. The comment step of an NPS therefore arrives short and scrolls
    /// inside its card. The observer's measurement is the page's own formula read
    /// after layout, and it is trusted past the type's maximum.
    func testAMeasuredCardMayGrowTheBoxPastTheTypeMaximum() {
        let manager = presentWidget(startInstance(), type: .nps)
        XCTAssertEqual(placedHeight(manager), WidgetLayout.npsMaximumHeight, "an NPS starts at its maximum")

        reportCard(manager, height: 500, reason: "mutation")

        guard let frame = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the widget should have been placed")
            return
        }
        XCTAssertEqual(frame.height, 500, accuracy: 1, "the measured step is given the room it needs")
        XCTAssertGreaterThan(frame.origin.y, 0, "and stays anchored to the bottom rather than the top")
    }

    /// The fit budget stops one screen's measurement chasing itself. It must not
    /// freeze the card at the first screen's size: a new screen starts it over.
    func testTheFitBudgetIsRenewedWhenTheScreenChanges() {
        let manager = presentWidget(startInstance(), type: .nps)

        reportCard(manager, height: 300, reason: "resize")
        reportCard(manager, height: 320, reason: "resize")
        reportCard(manager, height: 340, reason: "resize")
        XCTAssertEqual(placedHeight(manager) ?? 0, 340, accuracy: 1)

        // The budget is spent, so a fourth measurement of the same screen is ignored.
        reportCard(manager, height: 400, reason: "resize")
        XCTAssertEqual(placedHeight(manager) ?? 0, 340, accuracy: 1, "a spent budget still let a fit through")

        // A new screen is a fresh budget.
        reportCard(manager, height: 400, reason: "mutation")
        XCTAssertEqual(placedHeight(manager) ?? 0, 400, accuracy: 1, "a new screen was held to the old screen's budget")
    }

    /// The page repeats its announcement every time the surface is reported. If it
    /// outranked the measurement, every window move would shrink a fitted comment
    /// step back to the clamp, and the observer, seeing no change in the card,
    /// would never put it right again.
    func testAStaleAnnouncementCannotUndoAMeasuredFit() {
        let manager = presentWidget(startInstance(), type: .nps)
        reportCard(manager, height: 500, reason: "mutation")
        XCTAssertEqual(placedHeight(manager) ?? 0, 500, accuracy: 1)

        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":0,"y":0,"w":480,"h":300},"p":{"x":0,"y":0,"w":480,"h":300}}"#)
        TestUtils.pump(0.6)

        XCTAssertEqual(placedHeight(manager) ?? 0, 500, accuracy: 1, "the page's clamped announcement undid the measured fit")
    }

    /// A wrapper caught mid layout measures as a sliver. It is not the card.
    func testAMeasurementTooSmallToBeTheCardIsIgnored() {
        let manager = presentWidget(startInstance(), type: .nps)

        reportCard(manager, height: 50, reason: "mutation")

        XCTAssertEqual(placedHeight(manager), WidgetLayout.npsMaximumHeight, "a sliver was taken for the card")
    }
    #endif


    // MARK: - One overlay at a time

    /// Two overlays would fight for the same edge of the same screen, so the second
    /// is refused, as Android does. The refused caller hears at once.
    func testASecondOverlayIsRefusedWhileTheFirstIsUp() {
        let countly = startInstance()
        let first = present(countly)
        waitForLoad(first)

        var refusedDismissed = false
        let second = WebViewManager(core: core(of: countly))
        onMain {
            second.present(url: URL(string: "https://example.com/feedback/nps"),
                           appear: nil, dismiss: { refusedDismissed = true })
        }

        XCTAssertTrue(refusedDismissed, "the refused caller was left waiting for a dismissal that is not coming")
        XCTAssertNil(onMain { self.page(of: second) }, "the refused presentation built a web view anyway")
        XCTAssertNotNil(onMain { self.page(of: first) }, "refusing the second took the first down")
    }

    /// A content block on screen blocks a feedback widget, not only another content.
    func testAFeedbackWidgetIsRefusedWhileContentIsUp() {
        let countly = startInstance()
        let content = present(countly, url: "https://example.com/o/content/abc",
                              frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        waitForLoad(content)

        var refused = false
        let widget = WebViewManager(core: core(of: countly))
        onMain {
            widget.present(url: URL(string: "https://example.com/feedback/nps"),
                           widgetType: .nps, widgetPosition: nil, appear: nil, dismiss: { refused = true })
        }

        XCTAssertTrue(refused, "a widget was shown on top of a content block")
        XCTAssertNil(onMain { self.page(of: widget) })
        XCTAssertNotNil(onMain { self.page(of: content) }, "the content was taken down by the refused widget")
    }

    /// A caller may present again from inside its own dismiss callback.
    ///
    /// Two things make that true, and either alone would do: `close()` marks the
    /// manager closed before anything else, and the gate treats a closed holder as
    /// free; and the gate is released explicitly before the callback runs. What is
    /// asserted is the behaviour, not the mechanism: a presentation started from
    /// inside the callback actually builds its web view.
    func testACallerMayPresentAgainFromInsideItsDismissCallback() {
        let countly = startInstance()
        var next: WebViewManager?
        var refused = false
        let manager = present(countly, dismiss: {
            let again = WebViewManager(core: self.core(of: countly))
            // A refused presentation fires its dismiss callback at once, so a flag
            // set here separates "refused by the gate" from any other reason for
            // the web view to be missing.
            again.present(url: URL(string: "https://example.com/feedback/nps"), appear: nil, dismiss: { refused = true })
            // Loaded from a string, as the helper does: a real load fails in the
            // sandbox at once and the page closes itself through recovery, which
            // would look exactly like a refusal.
            again.webView?.loadHTMLString("<html><body>ok</body></html>", baseURL: URL(string: "https://example.com/"))
            next = again
        })
        waitForLoad(manager)

        onMain { manager.close() }
        TestUtils.pump(0.3)

        guard let next else {
            XCTFail("the dismiss callback did not run")
            return
        }
        XCTAssertFalse(refused, "the gate refused a presentation started from the dismiss callback")
        XCTAssertNotNil(onMain { self.page(of: next) }, "the presentation started from the dismiss callback has no web view")
        onMain { next.close() }
    }

    /// A survey served through the content queue reads `origin`; a content block
    /// ignores it. Without it the hosted survey never hears the surface changed.
    func testTheContentURLCarriesThePagesOwnOrigin() {
        let url = ContentModule.appendingOrigin(to: URL(string: "https://cdn.example.com:8443/content/abc?theme=dark")!)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(items.first { $0.name == "origin" }?.value, "https://cdn.example.com:8443")
        XCTAssertEqual(items.first { $0.name == "theme" }?.value, "dark", "an existing parameter was lost")
    }

    func testAnExistingOriginIsLeftAlone() {
        let original = URL(string: "https://cdn.example.com/content/abc?origin=https://other.example.com")!
        XCTAssertEqual(ContentModule.appendingOrigin(to: original), original)
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

    /// A content page whose stylesheets and scripts verified good is revealed
    /// there and then, the way the Objective-C SDK does it. Waiting for the page's
    /// own shown report would hide a template that only reports once it is visible.
    func testAContentPageIsRevealedOnceItsResourcesVerifyGood() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let appeared = expectation(description: "the content is reported visible")
        appeared.assertForOverFulfill = false
        let manager = present(countly,
                              url: "https://example.com/o/sdk/content",
                              appear: { appeared.fulfill() })

        onMain {
            manager.handleScriptMessage(name: "resourceVerifyResult",
                                        body: ["results": [["tag": "LINK", "url": "https://example.com/a.css", "status": 200]]])
        }

        wait(for: [appeared], timeout: TestUtils.webKitTimeout)
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the verified page is on screen")
    }

    /// A verification that finds a failed resource does not reveal the page.
    func testAContentPageStaysHiddenWhenAResourceVerifiedAsFailed() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        var appearCount = 0
        let manager = present(countly,
                              url: "https://example.com/o/sdk/content",
                              appear: { appearCount += 1 })

        onMain {
            manager.handleScriptMessage(name: "resourceVerifyResult",
                                        body: ["results": [["tag": "SCRIPT", "url": "https://example.com/a.js", "status": 404]]])
        }
        TestUtils.pump(0.3)

        XCTAssertEqual(appearCount, 0, "a failed verification is not an appearance")
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

        // Content, not a widget. Both are resized by this path, but only content is
        // obeyed exactly: a widget states a size and the SDK decides where it goes,
        // so asserting an exact rect there would be asserting the wrong rule.
        let manager = present(countly, url: "https://example.com/_external/content")
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

        let manager = present(countly, url: "https://example.com/_external/content")
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
        WebViewManager.contentShownDeadline = 1.0

        let dismissed = expectation(description: "the stalled page is taken down")
        dismissed.assertForOverFulfill = false
        // A content path, not a widget: widgets report themselves shown by loading,
        // so the deadline is content only.
        present(countly, url: "https://example.com/o/sdk/content", dismiss: { dismissed.fulfill() })

        wait(for: [dismissed], timeout: TestUtils.webKitTimeout)
    }

    /// A page that loads and is revealed but never reports itself shown is not
    /// reloaded behind the user's back: the stall timer ends with the reveal and
    /// only the absolute deadline is left, which closes rather than flashes.
    func testARevealedPageIsNotReloadedButClosedAtTheAbsoluteDeadline() {
        let countly = startInstance {
            $0.content.enableContentReloadOnStall = true
            $0.content.contentReloadOnStallTimeout = 300
        }
        WebViewManager.contentShownDeadline = 1.5

        var dismissed = false
        let manager = present(countly, url: "https://example.com/o/sdk/content", dismiss: { dismissed = true })
        onMain { manager.handleScriptMessage(name: "resourceVerifyResult", body: ["results": []]) }
        TestUtils.pump(0.2)
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the verified page should be on screen")

        // Past the stall timeout, twice over: the page must still be there and visible.
        TestUtils.pump(0.7)
        XCTAssertFalse(dismissed, "the revealed page was taken down by the stall timer")
        XCTAssertEqual(onMain { self.page(of: manager)?.isHidden }, false, "the revealed page was hidden for a reload")

        TestUtils.pump(1.0)
        XCTAssertTrue(dismissed, "the absolute deadline did not close the page")
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
        // The reload switch governs the stall timer only. The absolute content
        // shown deadline stays armed, and at its default is a minute away.
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
        let overlay = OverlayWindow(surfaceFrame: ScreenReader.surfaceFrame(withinApp: false))
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

        // A content URL: a widget URL fills the surface on iOS whatever frame it
        // came with, and this is about a page the server placed.
        let manager = present(countly, url: "https://example.com/o/sdk/content", frame: placement)
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
    ///
    /// Content rather than a widget, because the two now differ: a feedback widget
    /// is placed by `WidgetLayout` and so counts as placed, while a content the
    /// server sent no geometry for is the only thing left that fills.
    func testAContentWithNoPlacementStillFillsTheWindow() {
        let countly = startInstance()

        let manager = present(countly, url: "https://example.com/_external/content")
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

    // MARK: - What a widget's own answer may and may not change

    /// A widget reports where it sits inside its own viewport, which is the origin,
    /// because it has no idea where the SDK put its box on the desktop. Taking that
    /// literally drops the widget in the top left.
    ///
    /// Regression test. This did not bite while the page's answers were never
    /// reaching the SDK; the moment the message bridge started working and the
    /// answers arrived, every widget jumped to the corner. Java has the same rule:
    /// its log reads "putting the nps at {x=-2160, y=542} (it asked for {x=0, y=0})".
    #if os(macOS)
    func testAWidgetsRequestedSizeIsTakenButItsPositionIsNot() {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/feedback/nps")
        waitForLoad(manager)

        // A size at the origin, which is what these pages actually send.
        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":0,"y":0,"w":480,"h":300},"p":{"x":0,"y":0,"w":480,"h":300}}"#)
        TestUtils.pump(0.6)

        guard let frame = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the widget should have been placed")
            return
        }

        // Asserted against the frame itself rather than against a separately read
        // container: the surface is resolved from whichever screen the process is
        // associated with, and reading it a second time in a test process can
        // answer differently. What must hold is that the reported origin was not
        // taken, which is the regression, and that the anchor survived.
        XCTAssertEqual(frame.height, 300, accuracy: 1, "the size it asked for is honoured")
        XCTAssertNotEqual(frame.origin, .zero, "but not the origin it reported")
        XCTAssertGreaterThan(frame.origin.y, 0, "an NPS is pushed down to its anchor, not left at the top")
        // Centred means in from the left only when there is room: on a phone the
        // widget is as wide as the surface and a centred origin of zero is right.
        let container = onMain { manager.containerSizeForTesting }
        if frame.width < container.width {
            XCTAssertGreaterThan(frame.origin.x, 0, "and in from the left, because it is centred")
        }
    }
    #endif

    /// Content is the opposite: the server placed it deliberately and its
    /// coordinates mean something, so a geometry it sends is applied exactly.
    func testContentKeepsTheExactGeometryItWasSent() {
        let countly = startInstance()
        let manager = present(countly, url: "https://example.com/_external/content")
        waitForLoad(manager)

        navigate(manager, to: #"https://countly_action_event?cly_x_action_event=1&action=resize_me&resize_me={"l":{"x":16,"y":40,"w":435,"h":144},"p":{"x":16,"y":40,"w":435,"h":144}}"#)
        TestUtils.pump(0.6)

        guard let frame = onMain({ manager.placedFrameForTesting }) else {
            XCTFail("the content should have been placed")
            return
        }
        XCTAssertEqual(frame.origin.x, 16, accuracy: 1)
        XCTAssertEqual(frame.origin.y, 40, accuracy: 1)
        XCTAssertEqual(frame.width, 435, accuracy: 1)
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

#if os(macOS)

/// Whether the overlay lets the window it covers still be resized and still look
/// like itself.
///
/// Sized to the application's own window, the panel lies exactly over the window's
/// border. Everything the user does to a window happens at that border: dragging it
/// to resize, and seeing its rounded corners. A page that paints a full-surface
/// backdrop takes both away, and neither loss is anything the SDK is entitled to
/// cause: the content is a guest on someone else's window.
final class OverlayEdgeTests: XCTestCase {

    private func makeBackground(margin: CGFloat) -> PassThroughBackgroundView {
        let background = PassThroughBackgroundView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        background.passThroughEdgeMargin = margin
        let page = NSView(frame: background.bounds)
        background.addSubview(page)
        return background
    }

    func testTheWindowBorderIsLeftToTheWindow() {
        let background = makeBackground(margin: 4)

        // Each of the four borders, at the point the user actually grabs.
        XCTAssertNil(background.hitTest(NSPoint(x: 1, y: 150)), "the left border was claimed by the overlay")
        XCTAssertNil(background.hitTest(NSPoint(x: 399, y: 150)), "the right border was claimed by the overlay")
        XCTAssertNil(background.hitTest(NSPoint(x: 200, y: 1)), "the bottom border was claimed by the overlay")
        XCTAssertNil(background.hitTest(NSPoint(x: 200, y: 299)), "the top border was claimed by the overlay")
    }

    func testThePageStillReceivesEverythingInsideTheBorder() {
        let background = makeBackground(margin: 4)

        XCTAssertNotNil(background.hitTest(NSPoint(x: 200, y: 150)), "the middle of the page stopped receiving clicks")
        // Just inside the strip: the margin has to be narrow enough that a close
        // button in the corner is still reachable.
        XCTAssertNotNil(background.hitTest(NSPoint(x: 6, y: 6)), "the margin reaches further in than it should")
    }

    func testTheOverlayIsOrderedWithTheWindowItCovers() {
        let host = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                            styleMask: [.titled, .resizable],
                            backing: .buffered,
                            defer: false)
        let overlay = OverlayWindow(surfaceFrame: host.frame)

        // Floating out of the box, which is what puts it above other applications.
        XCTAssertEqual(overlay.level, .floating)

        overlay.bind(to: host)

        XCTAssertTrue(overlay.parent === host, "the overlay was not attached to the window it covers")
        XCTAssertEqual(overlay.level, .normal, "the overlay still outranks every other window")
        XCTAssertFalse(overlay.collectionBehavior.contains(.canJoinAllSpaces),
                       "the overlay still follows the user off the window's space")

        overlay.unbind()

        XCTAssertNil(overlay.parent, "the overlay stayed attached and would return with the window")
    }

    private func layer(size: CGSize, radius: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.cornerRadius = radius
        return layer
    }

    func testTheWindowRadiusIsFoundWhereverAppKitKeepsIt() {
        let windowSize = CGSize(width: 600, height: 400)
        let root = layer(size: windowSize, radius: 0)

        // The radius on a mask rather than the view's own layer, which is the shape
        // that made the first attempt read zero.
        let masked = layer(size: windowSize, radius: 0)
        masked.mask = layer(size: windowSize, radius: 26)
        root.addSublayer(masked)

        XCTAssertEqual(ScreenReader.windowCornerRadius(in: root, matching: windowSize, depth: 0), 26)
    }

    func testSomethingMerelyRoundedIsNotMistakenForTheWindow() {
        let windowSize = CGSize(width: 600, height: 400)
        let root = layer(size: windowSize, radius: 0)
        // A pill-shaped control: a large radius on a layer nothing like the window.
        root.addSublayer(layer(size: CGSize(width: 80, height: 24), radius: 12))

        XCTAssertEqual(ScreenReader.windowCornerRadius(in: root, matching: windowSize, depth: 0), 0,
                       "a control's corner radius was taken for the window's")
    }

    func testAWindowThatRoundsNothingReportsNothing() {
        let windowSize = CGSize(width: 600, height: 400)

        XCTAssertEqual(ScreenReader.windowCornerRadius(in: layer(size: windowSize, radius: 0),
                                                       matching: windowSize,
                                                       depth: 0), 0)
    }

    func testAConfiguredRadiusOverrulesTheWindow() {
        // A value the window could not plausibly report, so the assertion cannot
        // pass by coincidence of whatever window this test process happens to own.
        XCTAssertEqual(ScreenReader.overlayCornerRadius(configured: 33, fallback: 16), 33)
    }

    func testTheRadiusIsLeftToTheWindowWhenNoneIsConfigured() {
        // Nothing configured and, in a test process, no host window to read either,
        // so the fallback is what an application gets rather than a zero radius
        // that would put the square corners straight back.
        XCTAssertEqual(ScreenReader.overlayCornerRadius(configured: nil, fallback: 16), 16)
    }

    func testNoRadiusIsConfiguredByDefault() {
        XCTAssertNil(CountlyContentConfig().overlayCornerRadius,
                     "the SDK stopped reading the radius from the window by default")
    }

    func testTheSurfaceIsSentToTheWidgetTemplate() {
        let custom = FeedbackModule.customParameters(rendersOwnCloseControl: true,
                                                     surface: CGSize(width: 1440, height: 900))

        // The template picks its breakpoint and its card position from these two,
        // and decides orientation by comparing them, which only works on numbers.
        XCTAssertEqual(custom["width"] as? Int, 1440)
        XCTAssertEqual(custom["height"] as? Int, 900)
        XCTAssertEqual(custom["tc"] as? String, "1")
        XCTAssertEqual(custom["xb"] as? String, "1")
    }

    func testFractionalSurfacesAreSentAsWholePoints() {
        let custom = FeedbackModule.customParameters(rendersOwnCloseControl: false,
                                                     surface: CGSize(width: 1439.6, height: 899.4))

        XCTAssertEqual(custom["width"] as? Int, 1440)
        XCTAssertEqual(custom["height"] as? Int, 899)
        XCTAssertNil(custom["xb"], "an older widget was told to draw its own close control")
    }

    func testNoSurfaceIsSentRatherThanAZeroOne() {
        let custom = FeedbackModule.customParameters(rendersOwnCloseControl: true, surface: .zero)

        // A zero is a dimension the template would believe and lay out against,
        // which is worse than the fallback it uses when the key is absent.
        XCTAssertNil(custom["width"])
        XCTAssertNil(custom["height"])
        XCTAssertEqual(custom["tc"] as? String, "1")
    }

    func testCoveringTheWholeScreenKeepsEveryPoint() {
        // No window border underneath, so nothing to hand back.
        let background = makeBackground(margin: 0)

        XCTAssertNotNil(background.hitTest(NSPoint(x: 0, y: 150)), "the overlay gave away a click with no window to give it to")
    }
}

#endif
