//
//  WebViewManager.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

#if os(iOS) || os(visionOS) || os(macOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import WebKit

/// Presents server-rendered content and feedback widgets, and interprets what the
/// page asks the SDK to do.
///
/// The page talks back through navigation attempts to a sentinel URL rather than
/// a script bridge, because the same pages are rendered by every Countly SDK and
/// a URL is the one channel every platform's web view exposes identically.
///
/// One manager presents one page. It is shared between content and feedback, so
/// behavior that only applies to content is gated on `isFeedbackWidget`.
///
/// Deliberately internal, and worth keeping that way. `webView` is `private(set)`
/// so the test suite can assert against the real object rather than a projection
/// that would drift from it; that is only safe while the class itself is out of
/// reach. Making this `public` would take the web view's whole API along with it.
final class WebViewManager: NSObject {

    private static let module = "WebView"

    /// Prefix of the sentinel URL the page navigates to when it wants something.
    private static let actionURLPrefix = "https://countly_action_event"

    /// Marker that means "open this in the browser, not in the web view".
    private static let externalLinkMarker = "cly_x_int=1"

    /// Schemes the web view renders itself. Everything else is the system's.
    private static let webSchemes: Set<String> = ["http", "https"]

    /// Schemes never handed to the system, whatever the page asks.
    ///
    /// `file` and `content` reach the device's own storage, `javascript` and `data`
    /// execute or inject, and the rest are historic Android intent smuggling
    /// vectors. A content page is remote input, so these are refused rather than
    /// forwarded. Mirrors the block list Android applies in
    /// `Utils.isWebContentSchemeAllowed`.
    private static let refusedSchemes: Set<String> = [
        "file", "content", "javascript", "data", "blob", "jar", "zip", "intent", "about",
    ]

    /// Parameters whose values may themselves contain an unescaped `&`.
    private static let reservedKeys = ["action", "event", "resize_me", "close", "link"]

    private unowned let core: SDKCore

    private var window: OverlayWindow?
    private var backgroundView: PassThroughBackgroundView?
    /// Readable inside the module so the test suite can assert on where the page
    /// actually ended up, which is the thing a resize bug shows up in. The class
    /// itself is internal, so this widens nothing the outside can see.
    private(set) var webView: WKWebView?

    private var appearBlock: (() -> Void)?
    private var dismissBlock: (() -> Void)?

    private var hasAppeared = false
    private var isClosed = false

    /// Set when the presented page is a feedback widget rather than content.
    private var isFeedbackWidget = false

    /// Set when content is pinned to the portrait layout.
    private var isPinnedToPortrait = false

    /// The placement as the server sent it, before any safe area shift.
    ///
    /// The shift is applied again on every appearance, resize and rotation, and it
    /// is additive, so it has to be computed from this rather than from the frame
    /// already on screen. Re-applying it to the live frame walks the page off the
    /// bottom of the display one rotation at a time.
    private var baseWebViewFrame: CGRect?

    /// The server's placement for each orientation, under `"p"` and `"l"`, for a
    /// content the server placed. Consulted again on every rotation: the server
    /// laid the content out for both orientations, and only one of them was in
    /// effect when it was first shown.
    private var serverPlacement: [String: Any] = [:]

    /// Set when the caller supplied a frame, which means the server placed this
    /// page deliberately rather than asking for one that fills the screen.
    ///
    /// A placed page must survive a re-layout. Only a page with no placement of its
    /// own, which is every feedback widget, is re-filled when the interface resizes.
    private var hasExplicitPlacement = false

    /// Whether the current frame is one the page asked for through `resize_me`.
    ///
    /// Distinguished from a frame the server gave, because the two behave
    /// differently when the surface changes: the server's is a proportion of the
    /// surface and the page re-lays it out when told the new size, while the page's
    /// own is a size that has to be kept and moved back against its edge.
    private var frameRequestedByPage = false

    /// The surface the current frame was placed against.
    private var surfaceAtPlacement: CGSize = .zero

    /// What the SDK is showing, kept so its placement can be worked out again when
    /// the surface changes. A widget's frame is derived from the surface, so a
    /// surface that resizes invalidates it.
    private var presentedWidgetType: FeedbackWidgetType?
    private var presentedWidgetPosition: String?

    /// Whether the frame on screen is one `WidgetLayout` produced.
    ///
    /// Only such a frame may be recomputed when the surface changes, because only
    /// such a frame is a function of the surface. A frame the caller passed in, or
    /// one the page asked for through `resize_me`, is somebody else's decision and
    /// recomputing it would throw that decision away: a banner the server placed at
    /// 435x144 would silently become a 480x650 widget box on the first window
    /// resize.
    private var isSDKPlacedWidget = false

    /// Whether a feedback widget is laid out as a card the SDK sizes and places.
    ///
    /// Only on macOS. A phone is the viewport the widget pages were authored for,
    /// so on iOS, tvOS and visionOS a widget fills the surface exactly as the
    /// Objective-C SDK presents it, and the page lays itself out inside that. The
    /// card layout exists for a desktop, where a screen-sized page drifts into a
    /// corner and a screen-sized panel blocks the whole desktop.
    private static var usesCardLayoutForWidgets: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    /// Whether the presented page fills the surface rather than being a card the
    /// SDK sizes. Such a page states no size of its own, so nothing waits for one
    /// and a placement that came with it means nothing.
    private var fillsSurface: Bool { isFeedbackWidget && !Self.usesCardLayoutForWidgets }

    /// The deadline that shows a widget which never stated its size.
    private var pendingFirstFit: DispatchWorkItem?

    /// Set while a visible page is held off screen for a rotation, until it has
    /// been fitted to the new orientation or the wait for that ran out.
    private var isConcealedForRotation = false

    /// The deadline by which a rotated page is shown whether or not it asked for a
    /// new size.
    private var pendingRotationReveal: DispatchWorkItem?

    /// Corner radius used when the window will not say what its own is.
    ///
    /// Only reached when the frame view has no radius on its layer. Erring large is
    /// deliberate: rounding more than the window does costs a sliver of the page at
    /// each corner, while rounding less leaves the square wedges outside the window
    /// that the mask exists to remove.
    static let fallbackWindowCornerRadius: CGFloat = 16

    /// Width of the border strip the overlay hands back for window resizing.
    ///
    /// Wide enough to catch the pointer on the window's edge, narrow enough that it
    /// does not eat clicks on anything the page puts near its border.
    static let windowResizeEdgeMargin: CGFloat = 4

    /// How many times this page has been fitted, bounded by `maximumFits`.
    private var fitCount = 0

    /// The height the card was last measured at.
    ///
    /// Kept because the surface changing does not change how tall the card is. A
    /// re-layout that forgets it hands the widget back the maximum its type allows,
    /// so a window drag undoes the fit and the gap under the card returns for as
    /// long as the drag lasts.
    private var measuredCardHeight: CGFloat = 0

    /// The last surface size the page was told about, so it is not told twice.
    private var lastReportedSurface: CGSize?

    #if os(macOS)
    /// Observers for the host window moving or resizing.
    ///
    /// The overlay is a window of its own, so nothing about the application's window
    /// reaches it: `viewDidLayout` fires for the panel, and the panel does not
    /// change when the window behind it does. Without these a widget laid out for
    /// the window keeps the size and position the window had when it appeared, and
    /// content shown on one screen stays there after the window is dragged to
    /// another.
    private var surfaceObservers: [NSObjectProtocol] = []

    /// What the surface was when the placement was last worked out, so a
    /// notification that changed nothing relevant costs nothing.
    private var lastKnownSurfaceSize: CGSize = .zero
    private var lastKnownSurfaceFrame: CGRect = .zero
    #endif

    /// Fires when a content page has not reported itself shown in time.
    private var stallTimer: Timer?

    /// Fires when a content page has not reported `[CLY]_content_shown` within
    /// `contentShownDeadline` of being presented, whatever else happened to it.
    private var contentShownDeadlineTimer: Timer?

    /// How long a content page has to report itself shown before it is closed.
    ///
    /// Absolute and armed once per presentation, unlike the stall timer, which
    /// watches a single load and is re-armed on progress. A page that loads,
    /// verifies good and is revealed may still have drawn nothing, and this is
    /// the only detector that outlives the reveal. Closing is the only action it
    /// takes: reloading a page the user can see would flash it away. The same
    /// sixty seconds the Objective-C SDK uses; settable so a test does not wait
    /// that long.
    static var contentShownDeadline: TimeInterval = 60

    /// How many times a load has been retried after a critical resource failed.
    private var resourceRetryCount = 0

    /// How many reloads a failed critical resource is worth before the page is
    /// given up on. One transient hiccup is common; three in a row is a real
    /// failure.
    private static let maxResourceRetries = 3

    /// Base of the linear backoff between resource retries, in seconds.
    private static let resourceRetryBaseDelay: TimeInterval = 1.0

    /// Used when the configured stall timeout is not a usable positive number.
    private static let defaultStallTimeout: TimeInterval = 1.0

    /// When the current navigation started, so the load can be timed.
    private var loadStartedAt: Date?

    /// The reload a failure scheduled, held so a load that succeeds in the delay
    /// window can cancel it. Non-nil also means "a retry is already scheduled", so
    /// several failures from one page load coalesce into one.
    private var pendingReload: DispatchWorkItem?

    /// Message names the injected scripts post back on.
    private enum ScriptMessage {
        static let resourceLoadError = "resourceLoadError"
        static let resourceVerifyResult = "resourceVerifyResult"
        static let widgetCommand = "widgetCommand"
        static let cardSize = "cardSize"
    }

    /// Forwards the page's own replies out to the SDK.
    ///
    /// A widget answers the surface message with
    /// `window.parent.postMessage(payload, parentOrigin)`. In a single frame web
    /// view `window.parent === window`, so that reply lands back on the page's own
    /// `message` listeners and never reaches `window.webkit.messageHandlers` at
    /// all. Nothing is dropped and nothing errors; the SDK simply never hears it,
    /// which is why the surface message looked unanswered.
    ///
    /// This listens for the same event the page posts to itself and hands anything
    /// carrying `cly_widget_command` to the native side. The payload arrives as an
    /// object from some templates and as a JSON string from others, so both are
    /// accepted.
    private static let widgetBridgeScript = """
    (function () {
        if (window.__countlyWidgetBridge) { return; }
        window.__countlyWidgetBridge = true;
        window.addEventListener('message', function (event) {
            var data = event.data;
            try {
                if (typeof data === 'string') { data = JSON.parse(data); }
            } catch (e) { return; }
            if (!data || !data.cly_widget_command) { return; }
            try {
                window.webkit.messageHandlers.\(ScriptMessage.widgetCommand).postMessage(JSON.stringify(data));
            } catch (e) {}
        });
    })()
    """

    init(core: SDKCore) {
        self.core = core
        super.init()
    }

    deinit {
        Self.gate.release(self)
    }

    /// One overlay at a time across content and feedback widgets.
    ///
    /// The Android SDK refuses a second presentation while any content or feedback
    /// overlay is up, and this does the same: two overlays would fight for the
    /// same edge of the same screen, and the second would land on top of a page
    /// the user is in the middle of answering. The refused caller hears about it
    /// at once through its dismiss callback so nothing upstream waits on it, and a
    /// content zone simply fetches again after its interval.
    ///
    /// Process wide rather than per instance, as Android's flag is: the screen is
    /// shared whatever instance is drawing on it.
    static let gate = PresentationGate()

    final class PresentationGate {
        private let lock = NSLock()
        private weak var holder: WebViewManager?

        /// Claims the gate for `manager`, or reports who holds it.
        func claim(_ manager: WebViewManager) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if let holder, holder !== manager, !holder.isClosed { return false }
            holder = manager
            return true
        }

        /// Gives the gate up, if `manager` is the one holding it.
        func release(_ manager: WebViewManager) {
            lock.lock(); defer { lock.unlock() }
            if holder === manager { holder = nil }
        }
    }

    // MARK: - Presentation

    /// Puts a page on screen.
    ///
    /// - Parameters:
    ///   - url: The page to load.
    ///   - frame: Where to place it. Defaults to filling the overlay.
    ///   - appear: Called once the page has loaded and is visible.
    ///   - dismiss: Called once the page has been taken off screen.
    ///   - refused: Called instead of `dismiss` when another overlay is on screen
    ///     and the page is not shown at all. Without it `dismiss` is called.
    func present(url: URL?,
                 frame: CGRect? = nil,
                 placement: [String: Any] = [:],
                 widgetType: FeedbackWidgetType? = nil,
                 widgetPosition: String? = nil,
                 appear: (() -> Void)?,
                 dismiss: (() -> Void)?,
                 refused: (() -> Void)? = nil) {
        guard let url else {
            core.logger.e(Self.module, "present", "web view presentation is dropped, the URL could not be built")
            return
        }

        isFeedbackWidget = url.path.contains(Endpoint.feedback)

        guard Self.gate.claim(self) else {
            core.logger.i(Self.module, "present", "another content or feedback overlay is already being shown, skipping this presentation, isFeedbackWidget: [\(isFeedbackWidget)]")
            // Told now rather than never: the caller's bookkeeping runs off this
            // callback, and a caller that waited for a dismissal that is not
            // coming would hold its own state open indefinitely.
            isClosed = true
            if let refused {
                refused()
            } else {
                dismiss?()
            }
            return
        }

        presentedWidgetType = widgetType
        presentedWidgetPosition = widgetPosition
        serverPlacement = placement
        isPinnedToPortrait = !isFeedbackWidget && core.config.content.disableRotation

        // Host and path only: the query string carries the app key and device ID.
        core.logger.i(Self.module, "present", "web view presentation requested, host: [\(url.host ?? "")], path: [\(url.path)], isFeedbackWidget: [\(isFeedbackWidget)], pinnedToPortrait: [\(isPinnedToPortrait)]")
        core.logger.v(Self.module, "present", "web view presentation detail, url: [\(url.absoluteString)], appearCallbackProvided: [\(appear != nil)], dismissCallbackProvided: [\(dismiss != nil)]")

        appearBlock = appear
        dismissBlock = dismiss
        hasAppeared = false
        isClosed = false
        resourceRetryCount = 0
        cancelPendingReload()

        #if os(macOS)
        let overlayWindow = OverlayWindow(surfaceFrame: ScreenReader.surfaceFrame(withinApp: core.config.content.showWidgetsWithinApp))
        #else
        let overlayWindow = OverlayWindow()
        #endif
        let controller = WebViewController()
        #if !os(macOS)
        // The overlay is a window of its own, so the presentation style only
        // matters where a controller can be presented modally at all.
        controller.modalPresentationStyle = .overFullScreen
        #endif
        controller.sizeChangeHandler = { [weak self] settled in
            self?.handleInterfaceSizeChange(reportToPage: settled)
        }
        overlayWindow.rootViewController = controller

        #if os(macOS)
        observeSurfaceChanges()
        #endif

        let background = PassThroughBackgroundView(frame: controller.view.bounds)
        #if os(macOS)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.clear.cgColor
        background.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        if core.config.content.showWidgetsWithinApp {
            shapeOverlayToHostWindow(overlayWindow, background: background)
        }
        #else
        background.backgroundColor = .clear
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        controller.contentView = background

        let configuration = WKWebViewConfiguration()
        // A non-persistent store keeps widget answers and content state out of the
        // host application's cookie jar.
        configuration.websiteDataStore = .nonPersistent()

        if core.config.content.disableZoom {
            configuration.userContentController.addUserScript(Self.disableZoomScript)
        }

        // Held weakly through a proxy: `WKUserContentController` retains its
        // message handlers, and the controller is reachable from the web view this
        // object owns, so registering directly would be a cycle nothing breaks.
        let proxy = ScriptMessageProxy(target: self)
        configuration.userContentController.addUserScript(Self.resourceErrorScript)
        configuration.userContentController.add(proxy, name: ScriptMessage.resourceLoadError)
        configuration.userContentController.add(proxy, name: ScriptMessage.resourceVerifyResult)
        configuration.userContentController.add(proxy, name: ScriptMessage.widgetCommand)
        configuration.userContentController.add(proxy, name: ScriptMessage.cardSize)

        // A widget is laid out by the SDK, because unlike a content page it never
        // says where it wants to go and the server never says either. See
        // `WidgetLayout`, which is the same placement the Java SDK applies.
        // `containerSize`, never the background view's own bounds. The background
        // view is built at screen size, but the surface a page is laid out against
        // is whatever `showWidgetsWithinApp` says, and `applySafeAreaPlacement`
        // converts the result against that same surface. Measuring here against the
        // screen and converting there against the window put a widget laid out for
        // a 2130 tall screen at the bottom of a 1023 tall window, which is to say
        // ten points below it.
        let surface = containerSize
        // A widget fills the surface on this platform whatever placement came with
        // it. Journeys serve surveys and NPS widgets as content, with the server's
        // own geometry attached, and that geometry is laid out for a card, not for a
        // page authored to fill a phone: in landscape it arrived as 349x604 for an
        // 812x402 screen. The Objective-C SDK fills the window for every widget URL
        // on rotation, and filling from the start keeps the two placements agreeing.
        if fillsSurface, let frame {
            core.logger.d(Self.module, "present", "the placement that came with the widget is ignored, a widget fills the surface on this platform, ignoredFrame: [\(frame.logValue)]")
        }
        // The placement to honour, once a page that ignores one has discarded it.
        let placedFrame = fillsSurface ? nil : frame
        let targetFrame: CGRect
        if let placedFrame {
            targetFrame = placedFrame
        } else if isFeedbackWidget, Self.usesCardLayoutForWidgets {
            isSDKPlacedWidget = true
            targetFrame = WidgetLayout.resolve(type: widgetType,
                                               position: widgetPosition,
                                               surface: surface)
            core.logger.d(Self.module, "present", "the widget is placed by the SDK, widgetType: [\(widgetType?.wireName ?? "unknown")], appearancePosition: [\(widgetPosition ?? "none")], frame: [\(targetFrame.logValue)], surface: [\(surface.logValue)]")
        } else {
            // Content the server sent no geometry for, and a feedback widget on a
            // platform without the card layout: both fill the surface and are
            // refilled on rotation.
            targetFrame = CGRect(origin: .zero, size: surface)
        }
        baseWebViewFrame = targetFrame
        // A widget the SDK placed is placed, so a layout pass must not refill it.
        hasExplicitPlacement = placedFrame != nil || isSDKPlacedWidget
        frameRequestedByPage = false
        surfaceAtPlacement = surface
        core.logger.d(Self.module, "present", "the presentation frames were computed, webViewFrame: [\(targetFrame.logValue)], surface: [\(surface.logValue)], backgroundFrame: [\(background.bounds.logValue)]")

        let web = WKWebView(frame: targetFrame, configuration: configuration)
        web.navigationDelegate = self
        #if os(macOS)
        // `WKWebView.scrollView` is iOS only, and an NSView is transparent unless
        // it is told to draw. The page's own background still shows through.
        web.setValue(false, forKey: "drawsBackground")
        web.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        #else
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.bounces = false
        // The frame this view is given already clears the safe area, so letting the
        // scroll view inset for it a second time makes a page that exactly fills its
        // slot taller than the slot: it scrolls, and whatever sits at the bottom of
        // the page is cut in half by the edge of the view.
        web.scrollView.contentInsetAdjustmentBehavior = .never
        // Native backstop for the viewport directives the disable zoom script
        // writes. Only the gesture is touched, never the zoom scales, which
        // interact with the page's own initial scale.
        if core.config.content.disableZoom {
            web.scrollView.pinchGestureRecognizer?.isEnabled = false
        }
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        // Hidden until the page loads, so a blank rectangle never flashes over the
        // application.
        web.isHidden = true

        background.addSubview(web)

        self.window = overlayWindow
        self.backgroundView = background
        self.webView = web

        overlayWindow.isHidden = false
        web.load(URLRequest(url: url))

        armStallTimerIfNeeded()
        armContentShownDeadline()
    }

    #if os(macOS)
    /// Shapes the overlay like the window it covers, and orders it with that window.
    ///
    /// Sized to the application's own window, the overlay inherits that window's
    /// rounded corners. Without the mask a page painting a full-surface backdrop
    /// draws square corners over the window's curved ones, and the mismatch shows as
    /// four dark wedges outside the window. The application's own value wins: a
    /// window it has given a custom shape is one nothing the SDK can read will
    /// describe correctly.
    private func shapeOverlayToHostWindow(_ overlayWindow: OverlayWindow,
                                          background: PassThroughBackgroundView) {
        let configured = core.config.content.overlayCornerRadius
        let radius = ScreenReader.overlayCornerRadius(configured: configured,
                                                      fallback: Self.fallbackWindowCornerRadius)
        background.layer?.cornerRadius = radius
        background.layer?.masksToBounds = true
        background.passThroughEdgeMargin = Self.windowResizeEdgeMargin

        // Ordered with the window it covers rather than above the whole desktop, so
        // bringing another application forward puts it in front of the content the
        // way it would in front of any other window.
        overlayWindow.bind(to: ScreenReader.hostWindow)

        let source: String
        if configured != nil {
            source = "configuration"
        } else if radius == Self.fallbackWindowCornerRadius {
            source = "fallback"
        } else {
            source = "window"
        }
        core.logger.d(Self.module, "present", "the overlay is bound to the host window, cornerRadius: [\(radius)], source: [\(source)]")
    }

    /// Follows the application's window, so what the SDK draws stays where it
    /// belongs when that window is resized or dragged.
    ///
    /// Every window is observed rather than only the host: which window counts as
    /// the host can change while content is up, and the notifications are cheap.
    /// The work itself is skipped unless the surface actually moved.
    private func observeSurfaceChanges() {
        let recompute: (Notification) -> Void = { [weak self] _ in
            self?.surfaceDidChange()
        }

        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            surfaceObservers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    recompute(note)
                })
        }
    }

    /// Re-derives the placement after the surface moved or changed size.
    private func surfaceDidChange() {
        guard !isClosed, webView != nil else { return }

        let surface = containerSize
        guard surface != lastKnownSurfaceSize || ScreenReader.surfaceFrame(withinApp: core.config.content.showWidgetsWithinApp) != lastKnownSurfaceFrame else {
            return
        }

        lastKnownSurfaceSize = surface
        lastKnownSurfaceFrame = ScreenReader.surfaceFrame(withinApp: core.config.content.showWidgetsWithinApp)

        // A widget's frame is a function of the surface, so it is worked out again.
        // Content was placed by the server against the surface it reported at fetch
        // time; re-deriving that here would invent coordinates the server never
        // sent, so it keeps its frame and is only re-converted to the new position.
        if isSDKPlacedWidget {
            // The card's measured height is carried across: the surface changed, the
            // card did not, and resolving without it would hand back the type's
            // maximum and undo the fit on every step of a window drag.
            let frame = WidgetLayout.resolve(type: presentedWidgetType,
                                             position: presentedWidgetPosition,
                                             surface: surface,
                                             requestedHeight: measuredCardHeight,
                                             boundedByTypeMaximum: false)
            core.logger.d(Self.module, "surfaceDidChange", "the surface changed and the widget is laid out again, widgetType: [\(presentedWidgetType?.wireName ?? "unknown")], frame: [\(frame.logValue)], surface: [\(surface.logValue)], measuredCardHeight: [\(measuredCardHeight.logValue)]")
            baseWebViewFrame = frame

            // Measured again once the drag settles: a different width can reflow the
            // card to a different height. The budget is renewed for the new surface,
            // and the tolerance stops it as soon as the answer stops moving.
            fitCount = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.measureDelay) { [weak self] in
                self?.measureAndFitCard()
            }
        } else if frameRequestedByPage, let current = baseWebViewFrame {
            // A size, not a proportion: kept, moved back against its edge, clamped.
            let moved = WidgetLayout.reanchor(current, from: surfaceAtPlacement, to: surface)
            core.logger.d(Self.module, "surfaceDidChange", "the surface changed and the page-sized frame is re-anchored, from: [\(current.logValue)], to: [\(moved.logValue)], surface: [\(surface.logValue)]")
            baseWebViewFrame = moved
            surfaceAtPlacement = surface
        } else {
            core.logger.d(Self.module, "surfaceDidChange", "the surface changed and the page keeps the frame it was given, because the SDK did not choose it, frame: [\(baseWebViewFrame?.logValue ?? "none")], surface: [\(surface.logValue)]")
        }

        applySafeAreaPlacement()

        // Both kinds: the room available changed, and either may want to react.
        reportSurfaceToPage()
    }
    #endif

    /// Takes the page off screen and reports the dismissal once.
    func close() {
        guard !isClosed else { return }
        isClosed = true

        #if os(macOS)
        for observer in surfaceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        surfaceObservers.removeAll()
        #endif

        core.logger.d(Self.module, "close", "web view is being closed")

        let finish = { [weak self] in
            guard let self else { return }
            // Invalidated here rather than above: a `Timer` has to be invalidated on
            // the thread that scheduled it, and `close()` accepts calls from any.
            self.cancelStallTimer()
            self.cancelContentShownDeadline()
            self.pendingReload?.cancel()
            self.pendingReload = nil
            self.pendingRotationReveal?.cancel()
            self.pendingRotationReveal = nil
            self.webView?.stopLoading()
            self.webView?.navigationDelegate = nil
            let controller = self.webView?.configuration.userContentController
            controller?.removeScriptMessageHandler(forName: ScriptMessage.resourceLoadError)
            controller?.removeScriptMessageHandler(forName: ScriptMessage.resourceVerifyResult)
            controller?.removeScriptMessageHandler(forName: ScriptMessage.widgetCommand)
            controller?.removeScriptMessageHandler(forName: ScriptMessage.cardSize)
            controller?.removeAllUserScripts()
            self.webView?.removeFromSuperview()
            self.webView = nil
            #if os(macOS)
            // Before hiding it: a parent holds its children on screen, so an
            // attached panel would return with the window it was left on.
            self.window?.unbind()
            #endif
            self.window?.isHidden = true
            self.window?.rootViewController = nil
            self.window = nil
            self.backgroundView = nil

            // Released before the caller is told, so a caller may present again
            // from inside its own dismiss callback.
            Self.gate.release(self)
            let dismiss = self.dismissBlock
            self.dismissBlock = nil
            dismiss?()
        }

        onMainThread(finish)
    }

    /// How long a widget is held back waiting for the page to state its size.
    ///
    /// Short enough not to be felt, long enough for a page that is going to answer
    /// to have answered: the answer is a `postMessage` round trip inside a page that
    /// has already loaded, not a network call.
    private static let firstFitDeadline: TimeInterval = 0.35

    /// Below this in either dimension the measurement is a wrapper, not a card.
    private static let minimumCardSide: CGFloat = 120

    /// Below this a requested size is not a layout, it is a disappearance.
    private static let minimumUsableSide: CGFloat = 8

    /// A difference this small is layout noise rather than a fit worth making.
    private static let fitTolerance: CGFloat = 4

    /// A page that keeps reporting a different size is not converging, so the SDK
    /// stops rather than resizing the window indefinitely.
    private static let maximumFits = 3

    /// How long after placement the card is measured, giving the page a moment to
    /// lay itself out at the size it was just given.
    private static let measureDelay: TimeInterval = 0.16

    /// How long a visible page takes to slide to a new frame. Matches the
    /// Objective-C SDK's resize animation.
    private static let placementAnimationDuration: TimeInterval = 0.3

    /// How long a page fades back in after a rotation.
    private static let revealAnimationDuration: TimeInterval = 0.2

    /// Waits for the page's first `resize_me` before showing it, so the card is
    /// placed once rather than placed and then moved in front of the user.
    private func awaitFirstFitThenAppear() {
        guard !hasAppeared, pendingFirstFit == nil else { return }

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.hasAppeared else { return }
            self.pendingFirstFit = nil
            self.core.logger.d(Self.module, "awaitFirstFitThenAppear", "the page did not ask for a size within the deadline, so it is shown at the size its type allows")
            self.reportAppearance()
        }
        pendingFirstFit = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFitDeadline, execute: deadline)
    }

    /// Called when the page states its size, so it can be shown at once rather than
    /// waiting out the deadline.
    private func firstFitArrived() {
        guard let pending = pendingFirstFit else { return }
        pending.cancel()
        pendingFirstFit = nil
        core.logger.d(Self.module, "firstFitArrived", "the page asked for its size before the deadline, so it is shown already fitted")
        reportAppearance()
    }

    private func reportAppearance() {
        guard !hasAppeared else { return }
        // A pending reload is cancelled by this flag alone: the scheduled block
        // checks it before reloading, so a load that succeeded during the delay
        // window is never wiped by the retry the earlier failure scheduled.
        hasAppeared = true
        // The load this timer watched is over once the page is on screen. Only the
        // absolute content shown deadline outlives the reveal.
        cancelStallTimer()
        applySafeAreaPlacement()
        webView?.isHidden = false

        // Released once fired, the way the dismissal block is. It captures the
        // presenting module, which holds this manager, so keeping it would be a
        // cycle that only unwinds if a dismissal happens to arrive.
        let appear = appearBlock
        appearBlock = nil
        appear?()
    }

    // MARK: - Recovery

    /// Arms the deadline by which a content page has to report itself shown.
    ///
    /// A page whose scripts failed renders nothing and would otherwise sit over the
    /// application forever. Feedback widgets never report the shown event, so the
    /// deadline is content only.
    private func armStallTimerIfNeeded() {
        guard !isFeedbackWidget, core.config.content.enableContentReloadOnStall else { return }

        // Floored: a zero or negative value, which reads like "no timeout", would
        // otherwise arm a timer that fires on the next run loop turn and dismiss
        // every page before it could load.
        let configured = TimeInterval(core.config.content.contentReloadOnStallTimeout) / 1000.0
        let timeout = configured > 0 ? configured : Self.defaultStallTimeout
        stallTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.attemptRecovery(reason: "the content did not report itself shown in time")
        }
    }

    /// Cancels the stall deadline once the page is on screen or says it is showing
    /// something.
    private func cancelStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
    }

    /// Arms the absolute deadline for `[CLY]_content_shown`. Content only: a
    /// feedback widget never reports the event, so arming it there would close
    /// every widget a minute in.
    private func armContentShownDeadline() {
        guard !isFeedbackWidget else { return }
        contentShownDeadlineTimer?.invalidate()
        contentShownDeadlineTimer = Timer.scheduledTimer(withTimeInterval: Self.contentShownDeadline, repeats: false) { [weak self] _ in
            guard let self, !self.isClosed else { return }
            self.core.logger.w(Self.module, "contentShownDeadline", "the content never reported that it is shown, the web view is dismissed, deadlineSeconds: [\(Self.contentShownDeadline.logSeconds)], wasRevealed: [\(self.hasAppeared)]")
            self.close()
        }
    }

    private func cancelContentShownDeadline() {
        contentShownDeadlineTimer?.invalidate()
        contentShownDeadlineTimer = nil
    }

    // MARK: - Layout

    /// Moves the page clear of whatever the reported size had taken out of it.
    ///
    /// The size the server laid this page out against had the hardware cutout
    /// subtracted from it, so the page fits only once it has been pushed past that
    /// cutout. Always computed from `baseWebViewFrame`, never from the live frame.
    private func applySafeAreaPlacement() {
        guard let webView, let base = baseWebViewFrame else { return }

        let offset = ContentGeometry.placementOffset(displayOption: core.config.content.webViewDisplayOption)
        let placed = base.offsetBy(dx: offset.x, dy: offset.y)

        #if os(macOS)
        // The panel is shrunk to the page rather than the page being positioned
        // inside a screen sized panel.
        //
        // A `UIWindow` whose hit test returns nil lets the touch fall through to the
        // window beneath it, so on iOS a screen sized overlay costs the application
        // nothing. AppKit has no such rule: a borderless panel owns every point in
        // its frame whatever `hitTest` answers, so a screen sized panel makes the
        // whole desktop unclickable while a 435x144 banner is up. Sizing the panel
        // to the page is what leaves the rest of the screen alone.
        guard let window else { return }
        let screenArea = ScreenReader.surfaceFrame(withinApp: core.config.content.showWidgetsWithinApp)
        core.logger.d(Self.module, "applySafeAreaPlacement", "the presentation surface was resolved, \(ScreenReader.surfaceDescription(withinApp: core.config.content.showWidgetsWithinApp))")
        // `placed` is measured from the top of that area, because the background
        // view is flipped; an AppKit window is placed from the bottom of the screen.
        let target = CGRect(x: screenArea.origin.x + placed.origin.x,
                            y: screenArea.origin.y + screenArea.height - placed.origin.y - placed.height,
                            width: placed.width,
                            height: placed.height)

        // Compared against the window, not the web view: the web view always fills
        // the panel here, so comparing its frame would never settle and every layout
        // pass would schedule another.
        guard target != window.frame else { return }

        core.logger.d(Self.module, "applySafeAreaPlacement", "the panel is sized to the page so the rest of the screen stays interactive, baseFrame: [\(base.logValue)], offset: [\(offset.logValue)], pageFrame: [\(placed.logValue)], panelFrame: [\(target.logValue)], screenArea: [\(screenArea.logValue)]")

        // Applied a turn later, never inline.
        //
        // This runs from `viewDidLayout`, and resizing a window lays its content out
        // again, so setting the frame here starts a layout pass inside the one that
        // is already running. AppKit calls that out with "not legal to call
        // -layoutSubtreeIfNeeded on a view which is already being laid out" and the
        // behaviour past that point is its own business. Deferring keeps the resize
        // outside the pass; the equality guard above stops the next pass repeating it.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, let webView = self.webView else { return }
            guard target != window.frame else { return }

            window.setFrame(target, display: true)
            webView.frame = CGRect(origin: .zero, size: target.size)
            self.backgroundView?.frame = CGRect(origin: .zero, size: target.size)
        }
        #else
        guard placed != webView.frame else { return }

        core.logger.d(Self.module, "applySafeAreaPlacement", "the page is placed clear of the safe area, baseFrame: [\(base.logValue)], offset: [\(offset.logValue)], frame: [\(placed.logValue)], safeAreaInsets: [\(ContentGeometry.safeAreaDescription)]")

        // A page the user can already see slides to its new frame, the way the
        // Objective-C SDK moves it when the page asks for a size. Snapping it after
        // a rotation, or when a `resize_me` arrives, reads as a glitch. A page still
        // hidden is simply put where it belongs: animating a frame nobody can see
        // would only show as a slide the moment it is revealed. Inside a rotation
        // this nests in the transition's own animation and follows its timing.
        guard !webView.isHidden else {
            webView.frame = placed
            return
        }
        UIView.animate(withDuration: Self.placementAnimationDuration,
                       delay: 0,
                       options: [.beginFromCurrentState, .curveEaseInOut]) {
            webView.frame = placed
        }
        #endif
    }

    /// The space a resize is measured against, for the suite's assertions.
    var containerSizeForTesting: CGSize { containerSize }

    /// The frame the page was last placed at, before any panel conversion.
    var placedFrameForTesting: CGRect? { baseWebViewFrame }

    /// Drives the re-layout the platform would deliver, so the suite can assert on
    /// what a layout pass does to a placed page without waiting for a real one.
    func simulateInterfaceSizeChangeForTesting(settled: Bool = true) {
        handleInterfaceSizeChange(reportToPage: settled)
    }

    /// Re-lays the page out after a rotation, unless it is pinned to portrait.
    ///
    /// `reportToPage` is false for the pass that runs inside the rotation animation:
    /// the page is told its new room once the transition has settled, so it answers
    /// a single `resize_me` against final numbers rather than one per pass.
    private func handleInterfaceSizeChange(reportToPage: Bool) {
        guard !isPinnedToPortrait else { return }
        guard backgroundView != nil, webView != nil else { return }

        #if !os(macOS)
        // The first pass of a rotation takes a visible page off screen. Left on
        // screen it would be seen rotating at its old size, landing, and then
        // jumping again when the page asks for its landscape size. It comes back
        // once that answer has been applied, or the wait for it ran out.
        if !reportToPage { concealForRotation() }
        #endif

        // A page the server placed keeps its placement. macOS calls this from
        // `viewDidLayout`, which runs during the presentation itself, so filling
        // here would throw the server's coordinates away before the page had even
        // been seen: a 435x144 banner became the whole 3840x2130 screen. Only a
        // page that asked to fill, which is every feedback widget, is re-filled.
        // Only a change of orientation, not any layout pass. macOS runs this from
        // `viewDidLayout`, which fires on every panel resize including the one the
        // page's own `resize_me` caused, and re-applying the server's geometry there
        // undid the size the page had just asked for.
        let orientationChanged = Self.orientationDiffers(surfaceAtPlacement, containerSize)

        if hasExplicitPlacement {
            if orientationChanged, let placed = Self.serverFrame(from: serverPlacement, for: containerSize) {
                // The server laid the content out for this orientation too, so its
                // geometry is applied straight away rather than the other
                // orientation's frame being kept or squeezed. A full-screen survey
                // shown in portrait was otherwise 402 wide on an 812 wide screen
                // after a rotation, since the page was only asked for a size after
                // the fact. The page is still told the new room and may refine this.
                core.logger.d(Self.module, "handleInterfaceSizeChange", "the interface size changed and the server's placement for the new orientation is applied, frame: [\(placed.logValue)], containerSize: [\(containerSize.logValue)]")
                baseWebViewFrame = placed
                frameRequestedByPage = false
                surfaceAtPlacement = containerSize
            } else if frameRequestedByPage, let current = baseWebViewFrame, containerSize != surfaceAtPlacement {
                let moved = WidgetLayout.reanchor(current, from: surfaceAtPlacement, to: containerSize)
                core.logger.d(Self.module, "handleInterfaceSizeChange", "the interface size changed and the page-sized frame is re-anchored, from: [\(current.logValue)], to: [\(moved.logValue)]")
                baseWebViewFrame = moved
                surfaceAtPlacement = containerSize
            } else {
                core.logger.d(Self.module, "handleInterfaceSizeChange", "the interface size changed, the page keeps the placement the server gave it, frame: [\(baseWebViewFrame?.logValue ?? "none")]")
            }
        } else {
            let filled = CGRect(origin: .zero, size: containerSize)
            core.logger.d(Self.module, "handleInterfaceSizeChange", "the interface size changed and the page is re-laid out, frame: [\(filled.logValue)], containerSize: [\(containerSize.logValue)]")
            baseWebViewFrame = filled
        }
        applySafeAreaPlacement()

        guard reportToPage else { return }
        reportSurfaceToPage()
        #if !os(macOS)
        awaitRefitThenReveal()
        #endif
    }

    #if !os(macOS)
    /// Hides a page the user can see for the length of a rotation.
    private func concealForRotation() {
        guard let webView, hasAppeared, !webView.isHidden, !isConcealedForRotation else { return }
        isConcealedForRotation = true
        webView.isHidden = true
        core.logger.d(Self.module, "concealForRotation", "the page is held off screen while the interface rotates")
    }

    /// Brings a concealed page back once it has answered the new surface with a
    /// size, or after the same wait a first presentation allows for that answer.
    private func awaitRefitThenReveal() {
        guard isConcealedForRotation else { return }

        // A widget fills the surface and never states a size, so there is nothing
        // to wait for: it is back as soon as it has been re-filled.
        if fillsSurface {
            revealAfterRotation(reason: "the widget fills the surface")
            return
        }

        pendingRotationReveal?.cancel()
        let deadline = DispatchWorkItem { [weak self] in
            self?.revealAfterRotation(reason: "the page did not ask for a size within the deadline")
        }
        pendingRotationReveal = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.firstFitDeadline, execute: deadline)
    }

    /// Fades a page concealed for a rotation back in at its new frame.
    private func revealAfterRotation(reason: String) {
        pendingRotationReveal?.cancel()
        pendingRotationReveal = nil
        guard isConcealedForRotation else { return }
        isConcealedForRotation = false
        guard let webView, !isClosed else { return }

        core.logger.d(Self.module, "revealAfterRotation", "the page is shown again after the rotation, reason: [\(reason)], frame: [\(webView.frame.logValue)]")
        webView.alpha = 0
        webView.isHidden = false
        UIView.animate(withDuration: Self.revealAnimationDuration) {
            webView.alpha = 1
        }
    }
    #endif

    /// Whether two surfaces are of different orientation. Always false on macOS: a
    /// window has no orientation to rotate into, a resize is handled by
    /// `surfaceDidChange`, and the server's geometry is never re-applied there.
    private static func orientationDiffers(_ from: CGSize, _ to: CGSize) -> Bool {
        #if os(macOS)
        return false
        #else
        return (from.height >= from.width) != (to.height >= to.width)
        #endif
    }

    /// The frame the server's placement gives a content on a surface of `container`,
    /// taken from the entry for that surface's orientation. Nil when the server
    /// said nothing for it: the other orientation's frame is not a substitute, since
    /// its coordinates were measured against a surface of the other shape.
    static func serverFrame(from placement: [String: Any], for container: CGSize) -> CGRect? {
        let key = container.width > container.height ? "l" : "p"
        guard let geometry = placement[key] as? [String: Any], !geometry.isEmpty else { return nil }
        return CGRect(contentGeometry: geometry, container: container)
    }

    /// The space a page's `{x, y, w, h}` is measured against.
    ///
    /// Not the background view's own size on macOS. There the panel is shrunk to
    /// the page so the rest of the screen stays clickable, and the background view
    /// shrinks with it, so reading it back would measure the next request against
    /// the page rather than the screen and walk the page into a corner one resize
    /// at a time. The screen is the space the server placed against and the space
    /// every request means.
    private var containerSize: CGSize {
        #if os(macOS)
        return ContentGeometry.windowSize(displayOption: core.config.content.webViewDisplayOption,
                                          withinApp: core.config.content.showWidgetsWithinApp)
        #else
        // The window, less the insets the display option removes, which is the
        // same space the content module reports to the server and the Objective-C
        // SDK lays out against. Never the background view: that view spans the
        // whole screen, insets included, so a frame filled from it after a rotation
        // was a screen tall and then shifted down by the notch, off the bottom.
        // Reading the window also answers before the overlay's first layout pass,
        // when the background view still measures zero.
        var size = ContentGeometry.windowSize(displayOption: core.config.content.webViewDisplayOption)
        if isPinnedToPortrait, size.width > size.height {
            size = CGSize(width: size.height, height: size.width)
        }
        return size
        #endif
    }

    /// Applies a size the page asked for, in the page's own coordinate space.
    private func resize(with parameters: [String: Any]) {
        guard backgroundView != nil, webView != nil else { return }

        // The page states a card size, and a widget that fills the surface has no
        // card: the Objective-C SDK gives widgets no resize channel either.
        if fillsSurface {
            core.logger.d(Self.module, "resize", "a feedback widget fills the surface on this platform, the size the page asked for is ignored, asked: [\(parameters.keys.sorted())]")
            return
        }

        let container = containerSize

        // The page describes where it wants to sit as a fraction of the screen,
        // under the key matching the current orientation.
        let isPortrait = container.height >= container.width
        let preferred = isPortrait ? "p" : "l"
        let fallback = isPortrait ? "l" : "p"

        // A page that only describes one orientation still wants to be resized.
        // Ignoring the request leaves the view at whatever frame the presentation
        // computed, which for a banner-sized content is the whole screen, and it
        // then covers and swallows every touch until it is closed.
        guard let geometry = (parameters[preferred] as? [String: Any])
                ?? (parameters[fallback] as? [String: Any]) else { return }

        let usedFallback = parameters[preferred] == nil
        var frame = CGRect(contentGeometry: geometry, container: container)

        // A page that asks to be a sliver is asking to be invisible.
        //
        // The geometry is applied as sent, so a reply carrying a zero or near zero
        // dimension leaves a view too small to see and no error anywhere: the page
        // is placed, loaded and reported, and nothing appears. Refusing the request
        // leaves whatever it had, which is at worst the wrong size and at best
        // exactly right, and either beats a page nobody can see.
        guard frame.width >= Self.minimumUsableSide, frame.height >= Self.minimumUsableSide else {
            core.logger.w(Self.module, "resize", "the page asked for a size too small to be visible and keeps the one it has, asked: [\(frame.logValue)], containerSize: [\(container.logValue)]")
            return
        }

        // A reply that hands the surface back is not an answer.
        //
        // These templates echo the viewport they were given rather than reporting
        // the card they drew: told 3840x2130, they reply 3840x2130. Treating that
        // as a requested size clamps it to the type's maximum every time and
        // undoes the measurement, which is the real answer. Ignored, so the
        // measured card stands.
        if isFeedbackWidget, frame.size == container {
            core.logger.d(Self.module, "resize", "the widget echoed the surface back rather than stating a card size, so the size it was given stands, surface: [\(container.logValue)]")
            return
        }

        // A widget states a size, not a position.
        //
        // The page reports where it sits in its own viewport, which is `0,0`: it
        // has no idea where the SDK put its box on the desktop. Applying that
        // literally drops every widget in the top left the moment it answers, which
        // is what happened here as soon as the message bridge started working and
        // the answers began arriving at all.
        //
        // So the size is taken and the position is worked out again by
        // `WidgetLayout`, which is the same thing the Java SDK does: its log reads
        // "putting the nps at {x=-2160, y=542, w=480, h=414} (it asked for {x=0,
        // y=0, w=480, h=414})". Content is untouched, because the server placed it
        // deliberately and its coordinates mean something.
        if isFeedbackWidget {
            // A measurement, once there is one, outranks what the page announces.
            //
            // The announcement is the same formula clamped to the page's breakpoint
            // and, on a screen switch, taken before the incoming screen has laid
            // out. The page repeats it every time the surface is reported, so
            // honouring it here would shrink a fitted box back to the clamp each
            // time the window moved, and the observer, seeing no change in the
            // card itself, would have no reason to put it right again.
            let hasMeasurement = measuredCardHeight > 0
            let anchored = WidgetLayout.resolve(type: presentedWidgetType,
                                                position: presentedWidgetPosition,
                                                surface: container,
                                                requestedHeight: hasMeasurement ? measuredCardHeight : frame.height,
                                                boundedByTypeMaximum: !hasMeasurement)
            core.logger.d(Self.module, "resize", "the widget asked for a size, so the size is taken and the position is kept, asked: [\(frame.logValue)], measuredCardHeight: [\(measuredCardHeight.logValue)], placed: [\(anchored.logValue)]")
            frame = anchored
        }

        core.logger.d(Self.module, "resize", "the page asked to be resized, orientation: [\(isPortrait ? "portrait" : "landscape")], orientationKey: [\(usedFallback ? fallback : preferred)], usedFallbackOrientation: [\(usedFallback)], x: [\(frame.origin.x.logValue)], y: [\(frame.origin.y.logValue)], width: [\(frame.width.logValue)], height: [\(frame.height.logValue)]")
        core.logger.d(Self.module, "resize", "resize container detail, containerSize: [\(container.logValue)], resizeGeometry: [\(parameters)]")

        baseWebViewFrame = frame
        hasExplicitPlacement = true
        frameRequestedByPage = true
        surfaceAtPlacement = container
        // A content page has said where it wants to be, so the SDK stops deciding.
        // A widget only stated a size, and the SDK still owns where that size goes,
        // so it stays SDK placed and is re-anchored when the surface changes.
        isSDKPlacedWidget = isFeedbackWidget && Self.usesCardLayoutForWidgets
        applySafeAreaPlacement()

        // If the widget was being held back for exactly this, show it now.
        firstFitArrived()
        #if !os(macOS)
        // Likewise a page held off screen for a rotation.
        revealAfterRotation(reason: "the page asked for its size")
        #endif
    }

    // MARK: - Actions

    /// Runs whatever the page asked for.
    private func handleAction(_ parameters: [String: Any]) {
        let link = parameters["link"] as? String

        // `close` arrives one of two ways, and both mean the same thing.
        //
        // Usually it is a parameter of its own. On a link action it is instead
        // carried inside the link, as in `link=mailto:a@b.com?close=1`, because the
        // page appends it to the address it wants opened. The query parser is right
        // to leave it there: it splits on `&close=`, and that one is a `?close=`
        // belonging to the URL. So the link is asked as well, or a call to action
        // that opens something and dismisses itself only ever does the first half.
        let closeParameter = (parameters["close"] as? String).map(Self.isTruthy) ?? false
        let closeInLink = link.map(Self.closeRequested(in:)) ?? false

        // The action runs first: a closing call to action carries both its event
        // and `close`, and returning early would throw the event away.
        defer {
            if closeParameter || closeInLink {
                core.logger.d(Self.module, "handleAction", "the content asked to be closed, asOwnParameter: [\(closeParameter)], carriedInTheLink: [\(closeInLink)]")
                close()
            }
        }

        guard let action = parameters["action"] as? String else { return }

        core.logger.d(Self.module, "handleAction", "a content action was received, action: [\(action)]")
        core.logger.d(Self.module, "handleAction", "content action detail, action: [\(action)], queryParameters: [\(parameters)]")

        switch action {
        case "event":
            if let eventsJSON = parameters["event"] as? String {
                recordEvents(fromJSON: eventsJSON)
            }
        case "link":
            if let link {
                // Countly's own flag never reaches the target: a mail client or a
                // deep link handler has no use for it, and it would show up as a
                // stray parameter in whatever the link opens.
                openExternalLink(Self.withoutCloseParameter(link))
            }
        case "resize_me":
            if let resizeJSON = parameters["resize_me"] as? String,
               let geometry = CountlyJSON.object(from: Data(resizeJSON.utf8), logger: core.logger) as? [String: Any] {
                resize(with: geometry)
            }
        default:
            core.logger.d(Self.module, "handleAction", "unknown content action, it will be ignored, action: [\(action)]")
        }
    }

    /// Records the events a content page reports.
    private func recordEvents(fromJSON json: String) {
        guard let events = CountlyJSON.object(from: Data(json.utf8), logger: core.logger) as? [[String: Any]] else {
            core.logger.e(Self.module, "recordEvents", "the content events payload is nil or not an array, ignoring the action")
            core.logger.d(Self.module, "recordEvents", "unparsable content events detail, jsonLength: [\(json.count)], json: [\(json)]")
            return
        }

        core.logger.d(Self.module, "recordEvents", "content events payload detail, events: [\(events)]")

        var skipped = 0
        for event in events {
            guard let key = event["key"] as? String, !key.isEmpty else {
                core.logger.v(Self.module, "recordEvents", "skipping a content event, reason: the event key is nil or empty")
                skipped += 1
                continue
            }

            // The page sends segmentation under either name depending on its age.
            let segmentation = (event["sg"] as? [String: Any]) ?? (event["segmentation"] as? [String: Any])
            guard let segmentation else {
                core.logger.v(Self.module, "recordEvents", "skipping a content event, reason: the event has no segmentation, key: [\(key)]")
                skipped += 1
                continue
            }

            // The page reporting that it is showing content is proof it did not
            // stall, so the deadline is dropped.
            if key == "[CLY]_content_shown" {
                core.logger.d(Self.module, "recordEvents", "the page reported that the content is shown, cancelling the content shown deadline")
                cancelStallTimer()
                cancelContentShownDeadline()
                reportAppearance()
            }

            core.logger.d(Self.module, "recordEvents", "recording a content event, key: [\(key)], segmentationKeys: [\(segmentation.keys.sorted())]")
            core.modules.events.recordEvent(key, segmentation: core.modules.content.withGlobalSegmentation(segmentation))
        }

        if skipped > 0 {
            core.logger.d(Self.module, "recordEvents", "some content events were dropped, droppedCount: [\(skipped)], recordedCount: [\(events.count - skipped)]")
        } else {
            core.logger.i(Self.module, "recordEvents", "content events recorded, recordedCount: [\(events.count)]")
        }

        core.modules.events.addEventsToRequestQueue()
        core.requestQueueStore.saveSync()
        core.network.proceedOnQueue()
    }

    /// Hands a link to the host application, or to the browser.
    private func openExternalLink(_ urlString: String) {
        core.logger.d(Self.module, "openExternalLink", "an external link was requested by the content, linkLength: [\(urlString.count)]")
        core.logger.d(Self.module, "openExternalLink", "external link detail, link: [\(urlString)]")

        var url = URL(string: urlString)
        if url == nil {
            // A decoded link may hold characters URL rejects, such as a space that
            // came from a `%20`.
            let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
            url = encoded.flatMap { URL(string: $0) }
        }

        guard let url else {
            core.logger.w(Self.module, "openExternalLink", "the external link could not be parsed as a URL and will be ignored")
            return
        }

        if let handler = core.config.content.contentURLHandler, handler(url) {
            core.logger.i(Self.module, "openExternalLink", "the URL was handled by the app's content URL handler, host: [\(url.host ?? "")], path: [\(url.path)]")
            core.logger.d(Self.module, "openExternalLink", "app content URL handler detail, url: [\(url.absoluteString)]")
            return
        }

        let allowedSchemes = core.config.content.allowedLinkSchemes
        guard LinkSchemePolicy.isAllowed(scheme: url.scheme, allowedSchemes: allowedSchemes, alsoRefused: Self.refusedSchemes) else {
            core.logger.w(Self.module, "openExternalLink", "the link is not opened, its scheme is not allowed, scheme: [\(url.scheme ?? "")], allowedSchemeCount: [\(allowedSchemes.count)]")
            return
        }

        #if os(macOS)
        // AppKit answers synchronously and has no completion handler.
        let opened = NSWorkspace.shared.open(url)
        core.logger.i(Self.module, "openExternalLink", "the URL was handed to the system browser, host: [\(url.host ?? "")], path: [\(url.path)], opened: [\(opened)]")
        #else
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            self?.core.logger.i(Self.module, "openExternalLink", "the URL was handed to the browser, host: [\(url.host ?? "")], path: [\(url.path)], opened: [\(success)]")
            self?.core.logger.d(Self.module, "openExternalLink", "browser link detail, url: [\(url.absoluteString)], opened: [\(success)]")
        }
        #endif
    }

    // MARK: - Action URL parsing

    /// Splits the sentinel URL's query string into parameters.
    ///
    /// A plain split on `&` does not work: `link` carries an unescaped URL that may
    /// have its own query string, and a decoded `event` or `resize_me` JSON may
    /// contain an `&` inside a string. So the query is consumed from the right,
    /// taking at each step the rightmost reserved marker whose value is valid for
    /// its key. A marker whose value does not validate is ordinary text inside an
    /// enclosing value and gets absorbed by it.
    ///
    /// The documented limitation is that a value literally containing
    /// `&<reserved key>=<valid value>` can still be mis-split.
    static func parseActionQuery(_ urlString: String) -> [String: Any] {
        var result: [String: Any] = [:]

        let decoded = urlString.removingPercentEncoding ?? urlString
        guard let questionMark = decoded.firstIndex(of: "?") else { return result }

        let query = Array(decoded[decoded.index(after: questionMark)...])
        var end = query.count

        while end > 0 {
            var chosenIndex = -1
            var chosenKey: String?
            var chosenValue: String?
            var searchFrom = end

            while searchFrom > 0 {
                var marker = -1
                var markerKey: String?

                for key in reservedKeys {
                    let needle = Array("&\(key)=")
                    if let location = lastIndex(of: needle, in: query, before: searchFrom),
                       location > marker,
                       location + needle.count <= end {
                        marker = location
                        markerKey = key
                    }
                }

                guard marker >= 0, let markerKey else { break }

                let valueStart = marker + markerKey.count + 2
                let value = String(query[valueStart..<end])

                if isReservedValue(value, validFor: markerKey) {
                    chosenIndex = marker
                    chosenKey = markerKey
                    chosenValue = value
                    break
                }

                searchFrom = marker
            }

            guard chosenIndex >= 0, let chosenKey, let chosenValue else { break }
            result[chosenKey] = chosenValue
            end = chosenIndex
        }

        // Whatever is left at the front is the plain identifier parameter.
        let head = String(query[0..<end])
        for pair in head.split(separator: "&", omittingEmptySubsequences: true) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex..<equals])
            let value = String(pair[pair.index(after: equals)...])
            result[key] = value
        }

        return result
    }

    /// Rightmost occurrence of `needle` in `haystack` starting before `limit`.
    private static func lastIndex(of needle: [Character], in haystack: [Character], before limit: Int) -> Int? {
        guard needle.count <= limit else { return nil }
        var index = limit - needle.count
        while index >= 0 {
            if Array(haystack[index..<(index + needle.count)]) == needle { return index }
            index -= 1
        }
        return nil
    }

    /// Whether a value is plausible for its key, which is what tells a real
    /// parameter from text that happens to look like one.
    private static func isReservedValue(_ value: String, validFor key: String) -> Bool {
        switch key {
        case "event":
            return CountlyJSON.object(from: Data(value.utf8), logger: nil) is [Any]
        case "resize_me":
            return CountlyJSON.object(from: Data(value.utf8), logger: nil) is [String: Any]
        case "close":
            return value == "0" || value == "1"
        case "action":
            return value == "event" || value == "link" || value == "resize_me"
        case "link":
            return hasURIScheme(value)
        default:
            return false
        }
    }

    /// Whether a flag value means yes.
    ///
    /// Accepts the same spellings the other SDKs' pages send, not just `1`: a page
    /// sending `close=true` would otherwise leave content on screen forever.
    private static func isTruthy(_ value: String) -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes": return true
        default: return false
        }
    }

    /// Whether the value starts with a URI scheme, which covers both `https` links
    /// and custom-scheme deep links.
    static func hasURIScheme(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else { return false }

        for (offset, character) in value[value.startIndex..<colon].enumerated() {
            let isValid: Bool
            if offset == 0 {
                isValid = character.isLetter && character.isASCII
            } else {
                isValid = (character.isLetter || character.isNumber) && character.isASCII
                    || character == "+" || character == "-" || character == "."
            }
            if !isValid { return false }
        }
        return true
    }

    // MARK: - Critical resource failures

    /// Acts on a reply the page sent to itself, forwarded by the bridge.
    ///
    /// The same `resize_me` an action URL would carry, arriving by the other route
    /// the widget templates use. Routed into the same handler so a page that
    /// answers this way is placed exactly like one that navigates.
    private func handleWidgetCommand(_ body: Any) {
        let payload: [String: Any]?
        if let text = body as? String {
            payload = CountlyJSON.object(from: Data(text.utf8), logger: core.logger) as? [String: Any]
        } else {
            payload = body as? [String: Any]
        }

        guard let payload else {
            core.logger.d(Self.module, "handleWidgetCommand", "a widget command arrived that could not be read, ignoring it")
            return
        }

        core.logger.d(Self.module, "handleWidgetCommand", "the page replied, isFeedbackWidget: [\(isFeedbackWidget)], keys: [\(payload.keys.sorted())]")
        core.logger.v(Self.module, "handleWidgetCommand", "page reply detail, payload: [\(payload)]")

        if let geometry = payload["resize_me"] as? [String: Any] {
            resize(with: geometry)
        }

        // Only a widget may dismiss itself this way. The bridge is installed only
        // for widgets, but the guard stays: a `close` arriving on this route for a
        // content page would take it off screen the moment it appeared, and that
        // failure is silent and looks exactly like content never being served.
        if isFeedbackWidget,
           let closeValue = payload["close"], Self.isTruthy(String(describing: closeValue)) {
            core.logger.d(Self.module, "handleWidgetCommand", "the page asked to be closed")
            close()
        }
    }

    /// Reports a stylesheet or script that failed to load.
    ///
    /// Two mechanisms, because neither sees everything: the capturing `error`
    /// listener catches transport level failures (DNS, refused connection, a
    /// blocked host) but not HTTP status codes, and the `PerformanceObserver`
    /// catches a 404 or a 502, which the browser considers a successful load.
    /// `favicon.ico` is excluded because the system requests it whether the page
    /// references one or not.
    private static let resourceErrorScript: WKUserScript = {
        let source = """
        (function () {
          function report(tag, url) {
            window.webkit.messageHandlers.\(ScriptMessage.resourceLoadError).postMessage({ tag: tag, url: url });
          }
          function isCritical(el) {
            if (!el || !el.tagName) { return false; }
            if (el.tagName === 'SCRIPT') { return true; }
            // Only a stylesheet is critical. A preload hint, an icon, a manifest or
            // an alternate can all fail without the page being any less usable, and
            // dismissing content over a missing favicon is worse than the favicon.
            return el.tagName === 'LINK' && (el.rel || '').toLowerCase() === 'stylesheet';
          }
          window.addEventListener('error', function (e) {
            if (!isCritical(e.target)) { return; }
            var url = e.target.src || e.target.href;
            if (!url || url.indexOf('favicon.ico') !== -1) { return; }
            report(e.target.tagName, url);
          }, true);
          // `initiatorType` is 'link' for every kind of link element, so the
          // stylesheet URLs are resolved from the document to tell them apart.
          function stylesheetURLs() {
            var out = [];
            var nodes = document.querySelectorAll('link[rel="stylesheet"]');
            for (var i = 0; i < nodes.length; i++) { if (nodes[i].href) { out.push(nodes[i].href); } }
            return out;
          }
          if (window.PerformanceObserver) {
            var observer = new PerformanceObserver(function (list) {
              // Re-read per batch rather than cached: this observer is installed at
              // document start, when the document has no link elements yet.
              var stylesheets = stylesheetURLs();
              list.getEntries().forEach(function (entry) {
                if (!entry.responseStatus || entry.responseStatus < 400) { return; }
                if (entry.name && entry.name.indexOf('favicon.ico') !== -1) { return; }
                if (entry.initiatorType === 'script') { report('SCRIPT', entry.name); }
                else if (entry.initiatorType === 'link' && stylesheets.indexOf(entry.name) !== -1) { report('LINK', entry.name); }
              });
            });
            observer.observe({ type: 'resource', buffered: true });
          }
        })();
        """
        // Main frame only: a failed asset in some third party iframe is not a
        // reason to reload the page the SDK is presenting, and injecting into every
        // subframe reports the same failure several times.
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }()

    /// Asks the page to re-request every stylesheet and script with `HEAD` and
    /// report the status codes.
    ///
    /// A fallback for the systems where `PerformanceResourceTiming` carries no
    /// status code, which is where the observer above is inert and an HTTP error is
    /// invisible: the browser counts a 404 as a successful load. The script itself
    /// checks for that and answers immediately where the observer suffices, so on a
    /// current system this costs one evaluation and no requests.
    ///
    /// The result comes back through a message handler rather than the evaluation
    /// callback because `evaluateJavaScript` cannot return a promise.
    private func verifyResourceStatuses() {
        // Never for a widget: `didFinish` marks a widget as appeared on the very
        // next line, and a failure after that is non fatal by design, so every
        // request this makes would be answered into a decision nothing acts on.
        guard !isFeedbackWidget, !isClosed, let webView else { return }

        let source = """
        (function () {
          // The observer already reports a 4xx for everything, including resources
          // served from the in-session cache, wherever PerformanceResourceTiming
          // carries a status. Only where it does not, which is iOS before 16.4, is
          // there a gap worth a second request per asset.
          if (typeof PerformanceResourceTiming !== 'undefined' &&
              'responseStatus' in PerformanceResourceTiming.prototype) {
            window.webkit.messageHandlers.\(ScriptMessage.resourceVerifyResult).postMessage({ results: [] });
            return;
          }
          var urls = [];
          document.querySelectorAll('link[rel="stylesheet"]').forEach(function (l) { if (l.href) { urls.push({ tag: 'LINK', url: l.href }); } });
          document.querySelectorAll('script[src]').forEach(function (s) { urls.push({ tag: 'SCRIPT', url: s.src }); });
          if (urls.length === 0) {
            window.webkit.messageHandlers.\(ScriptMessage.resourceVerifyResult).postMessage({ results: [] });
            return;
          }
          Promise.all(urls.map(function (r) {
            return fetch(r.url, { method: 'HEAD' })
              .then(function (response) { return { tag: r.tag, url: r.url, status: response.status }; })
              .catch(function () { return { tag: r.tag, url: r.url, status: 0 }; });
          })).then(function (results) {
            window.webkit.messageHandlers.\(ScriptMessage.resourceVerifyResult).postMessage({ results: results });
          });
        })();
        """

        webView.evaluateJavaScript(source) { [weak self] _, error in
            guard let self, let error else { return }
            self.core.logger.d(Self.module, "verifyResourceStatuses", "the resource verification script could not be injected, continuing without verification, error: [\(error.localizedDescription)]")
            self.revealVerifiedContent()
        }
    }

    /// Shows a content page whose load verified good, or could not be verified.
    ///
    /// The page's own `[CLY]_content_shown` report is not waited for. A hidden web
    /// view is a hidden document to the page, and a template that reports itself
    /// shown only once it is visible would otherwise never be revealed at all. The
    /// stall deadline stays armed, so a page that renders nothing is still caught.
    private func revealVerifiedContent() {
        guard !isFeedbackWidget, !isClosed, !hasAppeared else { return }
        core.logger.d(Self.module, "revealVerifiedContent", "the load verified good, revealing the content")
        reportAppearance()
    }

    /// Receives both injected scripts' messages.
    func handleScriptMessage(name: String, body: Any) {
        switch name {
        case ScriptMessage.widgetCommand:
            handleWidgetCommand(body)

        case ScriptMessage.cardSize:
            guard let box = body as? [String: Any],
                  let width = (box["w"] as? NSNumber)?.doubleValue,
                  let height = (box["h"] as? NSNumber)?.doubleValue else { return }
            applyMeasuredCard(width: width, height: height,
                              via: box["via"] as? String ?? "?",
                              reason: box["reason"] as? String ?? "?")

        case ScriptMessage.resourceLoadError:
            guard let payload = body as? [String: Any] else { return }
            let tag = payload["tag"] as? String ?? "?"
            attemptRecovery(reason: "\(tag) failed to load")

        case ScriptMessage.resourceVerifyResult:
            guard let payload = body as? [String: Any],
                  let results = payload["results"] as? [[String: Any]] else { return }

            // Only a status the server actually returned counts. A rejected fetch
            // reports 0, and cross origin assets without CORS headers reject
            // exactly like an unreachable host does, so treating 0 as a failure
            // would dismiss every page served off a plain CDN.
            let failure = results.first { result in
                ((result["status"] as? NSNumber)?.intValue ?? 0) >= 400
            }

            guard let failure else {
                core.logger.d(Self.module, "handleScriptMessage", "every stylesheet and script verified good, resourceCount: [\(results.count)]")
                cancelPendingReload(rearmDeadline: true)
                revealVerifiedContent()
                return
            }

            let tag = failure["tag"] as? String ?? "?"
            let status = (failure["status"] as? NSNumber)?.intValue ?? 0
            attemptRecovery(reason: "\(tag) verified as failed with status \(status)")

        default:
            break
        }
    }

    /// Reloads a page that has not managed to show itself, or gives up on it.
    ///
    /// The single answer to "this page never became visible", whichever detector
    /// noticed: the deadline passing, a stylesheet or script failing to load, or
    /// one verifying as a 4xx. They share one retry budget, one coalescing flag and
    /// one backoff, because they are one problem and reloading twice for two
    /// symptoms of it wipes the load that was about to succeed.
    ///
    /// Once the page is visible nothing here fires: the injected listeners stay live
    /// for the whole page life, so a lazily loaded resource failing afterwards would
    /// otherwise flash the page away, re-fire its on-load event, or dismiss content
    /// the user is part way through.
    private func attemptRecovery(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.attemptRecovery(reason: reason) }
            return
        }

        guard !isClosed else { return }

        if hasAppeared {
            core.logger.d(Self.module, "attemptRecovery", "a failure arrived after the page was already visible, treating it as non fatal, reason: [\(reason)]")
            return
        }

        // Reload on stall is a content zone setting and has nothing to say about a
        // widget, so a widget always takes the retry path. It must never take the
        // "leave it alone" path either: the page carries its own close control, so
        // a widget whose script failed has no close button, no deadline and no
        // native dismiss, and would sit full screen over the application swallowing
        // every touch until the process is killed.
        guard isFeedbackWidget || core.config.content.enableContentReloadOnStall else {
            core.logger.d(Self.module, "attemptRecovery", "reload on stall is disabled, the page is being dismissed, reason: [\(reason)]")
            close()
            return
        }

        guard pendingReload == nil else {
            core.logger.d(Self.module, "attemptRecovery", "a reload is already scheduled for this load, the failure is ignored, reason: [\(reason)]")
            return
        }

        guard resourceRetryCount < Self.maxResourceRetries else {
            core.logger.w(Self.module, "attemptRecovery", "the reload attempts are exhausted, the page is being dismissed, attempt: [\(resourceRetryCount)], reason: [\(reason)]")
            close()
            return
        }

        resourceRetryCount += 1
        cancelStallTimer()

        let delay = Self.resourceRetryBaseDelay * TimeInterval(resourceRetryCount)
        core.logger.d(Self.module, "attemptRecovery", "scheduling a reload, attempt: [\(resourceRetryCount)], maxAttempts: [\(Self.maxResourceRetries)], delay: [\(delay.logSeconds)], reason: [\(reason)]")

        let reload = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingReload = nil

            guard !self.isClosed, !self.hasAppeared else { return }
            self.webView?.reload()
            // Re-armed, so a reload that stalls in turn still has a deadline. Without
            // this the recovery attempt itself would leave the overlay with none.
            self.armStallTimerIfNeeded()
        }
        pendingReload = reload
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reload)
    }

    /// Cancels a scheduled reload and re-arms the deadline instead.
    ///
    /// Called whenever the page proves it is making progress. Without it a page
    /// slower than the stall deadline is destroyed by the reload that deadline
    /// scheduled, moments before it would have shown itself, and its on-load
    /// reporting fires again on the replacement.
    private func cancelPendingReload(rearmDeadline: Bool = false) {
        guard let pending = pendingReload else { return }
        pending.cancel()
        pendingReload = nil

        core.logger.d(Self.module, "cancelPendingReload", "the page made progress, the scheduled reload is cancelled")
        if rearmDeadline { armStallTimerIfNeeded() }
    }

    /// Turns off pinch and double-tap zoom while leaving the page's own viewport
    /// width and initial scale alone.
    private static let disableZoomScript: WKUserScript = {
        let source = """
        var meta = document.querySelector('meta[name=viewport]');
        if (!meta) { meta = document.createElement('meta'); meta.name = 'viewport'; document.head.appendChild(meta); }
        var content = meta.getAttribute('content') || 'width=device-width, initial-scale=1.0';
        if (content.indexOf('user-scalable') === -1) { content += ', user-scalable=no'; }
        if (content.indexOf('maximum-scale') === -1) { content += ', maximum-scale=1.0'; }
        meta.setAttribute('content', content);
        """
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }()
}

// MARK: - Navigation

extension WebViewManager: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url?.absoluteString else {
            core.logger.d(Self.module, "decidePolicyFor", "the navigation action carries no URL, allowing it")
            decisionHandler(.allow)
            return
        }

        // An explicitly external link never loads inside the widget.
        if url.contains(Self.externalLinkMarker) {
            core.logger.d(Self.module, "decidePolicyFor", "the navigation action is marked as external, it will be opened outside the web view")
            openExternalLink(url)
            decisionHandler(.cancel)
            return
        }

        if url.hasPrefix(Self.actionURLPrefix) {
            let parameters = Self.parseActionQuery(url)
            core.logger.d(Self.module, "decidePolicyFor", "action event URL parsed, parameterCount: [\(parameters.count)]")
            handleAction(parameters)
            decisionHandler(.cancel)
            return
        }

        // A scheme the web view cannot render is a request for the system to take
        // over: `mailto:`, `tel:`, `sms:`, or an application's own deep link. Left
        // to `.allow` the navigation simply fails, the mail client never opens, and
        // a `close` travelling with it is never seen, so the content stays on screen
        // with nothing having happened.
        if let scheme = navigationAction.request.url?.scheme?.lowercased(),
           !Self.webSchemes.contains(scheme) {
            guard !Self.refusedSchemes.contains(scheme) else {
                core.logger.w(Self.module, "decidePolicyFor", "the navigation is refused, the scheme is not one a content page may hand to the system, scheme: [\(scheme)]")
                decisionHandler(.cancel)
                return
            }

            core.logger.i(Self.module, "decidePolicyFor", "the navigation uses a scheme the web view cannot render and is handed to the system, scheme: [\(scheme)]")
            // `close` is the SDK's, not the scheme handler's. `mailto:` accepts only
            // `subject`, `body`, `cc`, `bcc` and `to`, and Mail can refuse the whole
            // URL over an unknown header rather than ignoring it, so the compose
            // window never opens. Stripped for every scheme, because an application
            // deep link has no reason to receive it either.
            let external = Self.withoutCloseParameter(url)
            if external != url {
                core.logger.d(Self.module, "decidePolicyFor", "the SDK's close parameter is removed before the link is handed over, handedURL: [\(external)]")
            }
            openExternalLink(external)

            if Self.closeRequested(in: url) {
                core.logger.d(Self.module, "decidePolicyFor", "the link that was handed to the system also asked for the content to be closed")
                close()
            }

            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    /// The URL without the SDK's own `close` parameter.
    ///
    /// Rebuilt by hand rather than through `URLComponents`, which reports no query
    /// for the opaque schemes this is used with and would drop the rest of the URL
    /// on the way back out.
    static func withoutCloseParameter(_ urlString: String) -> String {
        guard let mark = urlString.firstIndex(where: { $0 == "?" || $0 == "&" }) else { return urlString }

        let head = String(urlString[urlString.startIndex..<mark])
        let kept = urlString[urlString.index(after: mark)...]
            .split(separator: "&", omittingEmptySubsequences: false)
            .filter { pair in
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return !(parts.count == 2 && parts[0] == "close")
            }

        guard !kept.isEmpty else { return head }
        return head + String(urlString[mark]) + kept.joined(separator: "&")
    }

    /// Whether a URL carries a truthy `close` in its query.
    ///
    /// Reads the raw string rather than `URLComponents`, which does not expose a
    /// query for the opaque schemes this is used with: `mailto:a@b.com?close=1` has
    /// no host and no path, and `URLComponents.queryItems` comes back nil for it.
    static func closeRequested(in urlString: String) -> Bool {
        guard let mark = urlString.firstIndex(where: { $0 == "?" || $0 == "&" }) else { return false }

        for pair in urlString[urlString.index(after: mark)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "close" else { continue }
            return isTruthy(String(parts[1]))
        }
        return false
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let headers = http?.allHeaderFields ?? [:]

        // Host and path only, and no header names: both a response header and a URL
        // query string can carry an identifier.
        core.logger.d(Self.module, "decidePolicyForResponse", "navigation response received, host: [\(response.url?.host ?? "")], path: [\(response.url?.path ?? "")], mimeType: [\(response.mimeType ?? "")], statusCode: [\(statusCode)], headerCount: [\(headers.count)]")
        core.logger.v(Self.module, "decidePolicyForResponse", "navigation response detail, url: [\(response.url?.absoluteString ?? "")], statusCode: [\(statusCode)], headers: [\(headers)]")

        // An error page is not content. Rendering it puts the server's 404 body over
        // the application with no close control on it, so the navigation is refused
        // and the overlay taken down instead.
        if statusCode >= 400 {
            core.logger.e(Self.module, "decidePolicyForResponse", "cancelling the navigation and dismissing the web view because of an HTTP error status, statusCode: [\(statusCode)], path: [\(response.url?.path ?? "")], reason: [http-error]")
            decisionHandler(.cancel)
            // Deferred rather than closed here: this runs inside WebKit's own policy
            // callback, and tearing the web view down underneath it is not safe.
            DispatchQueue.main.async { [weak self] in self?.close() }
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadStartedAt = Date()
        core.logger.d(Self.module, "didStartProvisionalNavigation", "the navigation started, host: [\(webView.url?.host ?? "")], path: [\(webView.url?.path ?? "")], reloadOnStall: [\(core.config.content.enableContentReloadOnStall)]")
        core.logger.v(Self.module, "didStartProvisionalNavigation", "started navigation detail, url: [\(webView.url?.absoluteString ?? "")]")
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        core.logger.d(Self.module, "didReceiveServerRedirect", "a server redirect was received for the provisional navigation, host: [\(webView.url?.host ?? "")], path: [\(webView.url?.path ?? "")]")
        core.logger.v(Self.module, "didReceiveServerRedirect", "server redirect detail, url: [\(webView.url?.absoluteString ?? "")]")
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        core.logger.d(Self.module, "didReceiveChallenge", "an authentication challenge was received and the default handling is performed, host: [\(challenge.protectionSpace.host)], authenticationMethod: [\(challenge.protectionSpace.authenticationMethod)]")
        completionHandler(.performDefaultHandling, nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        core.logger.e(Self.module, "webContentProcessDidTerminate", "the web content process terminated, host: [\(webView.url?.host ?? "")], path: [\(webView.url?.path ?? "")]")
        core.logger.v(Self.module, "webContentProcessDidTerminate", "terminated web content process detail, url: [\(webView.url?.absoluteString ?? "")]")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let duration = loadStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        core.logger.d(Self.module, "didFinish", "the page finished loading, host: [\(webView.url?.host ?? "")], path: [\(webView.url?.path ?? "")], duration: [\(duration.logSeconds)]")
        core.logger.v(Self.module, "didFinish", "finished navigation detail, url: [\(webView.url?.absoluteString ?? "")]")

        // The load completing is progress, whatever the deadline thought. The
        // deadline is re-armed rather than dropped, because content still has to
        // report itself shown and a page that loads but never renders is exactly
        // what it exists to catch.
        cancelPendingReload(rearmDeadline: true)
        verifyResourceStatuses()

        // Both kinds of page are told, because both resize.
        //
        // A widget answers with the size it wants; a content page reflows against
        // the room it is given. Neither can know the viewport on its own: the page
        // is handed a web view, not a window.
        //
        // Order matters: the bridge has to be listening before the page is asked
        // anything, or its answer arrives with nothing to catch it.
        installWidgetBridge()
        reportSurfaceToPage()

        // A feedback widget renders itself as soon as it loads and never reports a
        // shown event, so loading is the only signal it has appeared.
        //
        // Revealed a moment later rather than now: the surface was just reported and
        // the page answers it with a `resize_me`, so showing immediately would put
        // the card on screen at the full box and then visibly jump it to its real
        // size. Waiting for that answer means one placement and no movement. The
        // deadline is what covers a page that never answers.
        if isFeedbackWidget, !isSDKPlacedWidget {
            // No card to fit: the page fills the surface and is shown as it loads.
            core.logger.d(Self.module, "webView(didFinish:)", "the feedback widget fills the surface and is shown as soon as it has loaded")
            reportAppearance()
        } else if isFeedbackWidget {
            installCardObserver()
            awaitFirstFitThenAppear()

            // Measured a moment later so the page has laid itself out at the size it
            // was just given. If it answered the surface message in the meantime,
            // that answer wins and this finds nothing worth changing.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.measureDelay) { [weak self] in
                self?.measureAndFitCard()
            }
        }
    }

    /// Tells the page how much room it has.
    ///
    /// The page cannot know: it is handed a web view, not a window, and nothing in
    /// the DOM says how big the SDK intends the card to be. Given the viewport it
    /// answers with a `resize_me` carrying the size it actually wants, which is the
    /// only way the SDK learns a widget needs 414 points rather than the 450 its
    /// type allows. Without this the box is always the type's maximum and a shorter
    /// card floats inside it.
    ///
    /// The message shape is the one every Countly SDK sends and every widget page
    /// listens for.
    /// Measures the card the page actually drew.
    ///
    /// The page states its size through `resize_me` when it states one at all, and
    /// a rating widget never does while an NPS sometimes does not. Without a second
    /// route the box stays at the maximum its type allows and a shorter card floats
    /// inside it, which is the gap that shows up on a large screen.
    ///
    /// The selector list, its order and the guards are `FxSurfaces.java` in
    /// `countly-sdk-java`, which measures these same templates on a desktop. Worth
    /// keeping identical: the obvious heuristics do not work here. Every one of
    /// these templates wraps its card in a *transparent* wrapper, so anything that
    /// looks for a painted background returns nothing on a perfectly good page, and
    /// a bounding box union picks up the wrapper and reports the whole viewport.
    /// Measures the card the way the page itself does.
    ///
    /// This is `calculateHeight` from the widget templates, minus the clamp: the
    /// active screen's container plus the modal's top padding. The template reports
    /// that number held to its breakpoint's maximum, so the clamped figure is what
    /// the SDK is told and the unclamped one is what the step actually needs. The
    /// active screen is the one with a box; the others are `display: none`.
    ///
    /// The screens are looked for before `#widget-body`, which is only a wrapper
    /// in the survey template and is absent from the NPS one, and before the class
    /// based fallbacks that cover the rating widget, whose markup is different.
    private static let cardMeasurementFunction = """
    function __clyMeasureCard() {
        var body = document.body;
        if (!body) { return null; }
        var el = null, via = null;
        var screens = body.querySelectorAll('[id^="nps-"], [id^="ias-"]');
        for (var i = 0; i < screens.length; i++) {
            var r0 = screens[i].getBoundingClientRect();
            if (r0.width > 0 && r0.height > 0) { el = screens[i]; via = '#' + screens[i].id; break; }
        }
        var padding = 0;
        var modal = body.querySelector('.modal-content');
        if (el && modal) { padding = parseFloat(window.getComputedStyle(modal).paddingTop) || 0; }
        if (!el) {
            var fallbacks = ['#widget-body', '.modal-content', '[class*="survey-widget"]',
                             '[class*="countly-ratings"]', '[class*="cly-"]', '.smiley-container'];
            for (var j = 0; j < fallbacks.length && !el; j++) {
                var c = body.querySelector(fallbacks[j]);
                if (!c) { continue; }
                var rc = c.getBoundingClientRect();
                if (rc.width > 0 && rc.height > 0) { el = c; via = fallbacks[j]; }
            }
        }
        if (!el) {
            var best = null, bestArea = 0;
            var all = body.querySelectorAll('*');
            for (var k = 0; k < all.length; k++) {
                var rect = all[k].getBoundingClientRect();
                var area = rect.width * rect.height;
                if (area > bestArea) { bestArea = area; best = all[k]; }
            }
            if (!best) { return null; }
            el = best; via = 'largest';
        }
        var r = el.getBoundingClientRect();
        var h = (el.offsetHeight || r.height) + padding;
        if (r.width <= 0 || h <= 0) { return null; }
        return { w: r.width, h: h, via: via };
    }
    """

    private static let measureCardScript = """
    (function () {
        \(cardMeasurementFunction)
        return __clyMeasureCard();
    })()
    """

    /// Watches the card and reports its size whenever that changes.
    ///
    /// The page does announce a size on every screen switch, but it measures in the
    /// same call that starts the incoming screen's fade, before that screen has laid
    /// out, so what it announces for the comment step is a stale number. Waiting on
    /// the announcement alone leaves the step in a box a few dozen points short with
    /// its content scrolling inside it.
    ///
    /// Three sources, because none sees everything: `ResizeObserver` for the card
    /// changing size, `MutationObserver` for a screen being swapped in, and a cheap
    /// interval for whatever neither catches. A report crosses into native only when
    /// the numbers change, and then at once rather than batched: a screen swap is one
    /// change, and following it in the same frame is what reads as smooth.
    ///
    /// `reason` tells native whether the change came with a mutation, which is how it
    /// knows a new screen is up and the fit budget starts over.
    private static let cardObserverScript = """
    (function () {
        if (window.__countlyCardObserver) { return; }
        window.__countlyCardObserver = true;
        \(cardMeasurementFunction)
        var last = null;
        function report(reason) {
            var m = __clyMeasureCard();
            if (!m) { return; }
            var key = Math.round(m.w) + 'x' + Math.round(m.h) + '@' + m.via;
            if (key === last) { return; }
            last = key;
            m.reason = reason;
            try { window.webkit.messageHandlers.\(ScriptMessage.cardSize).postMessage(m); } catch (e) {}
        }
        if (window.ResizeObserver) {
            var ro = new ResizeObserver(function () { report('resize'); });
            var targets = document.querySelectorAll('[id^="nps-"], [id^="ias-"], #widget-body, .modal-content');
            for (var i = 0; i < targets.length; i++) { ro.observe(targets[i]); }
        }
        if (window.MutationObserver && document.body) {
            new MutationObserver(function () { report('mutation'); })
                .observe(document.body, { childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class'] });
        }
        setInterval(function () { report('poll'); }, 250);
        report('initial');
    })()
    """

    /// Fits the box to the card the page drew, when the page never said how big it
    /// wanted to be.
    private func measureAndFitCard() {
        guard isSDKPlacedWidget, !isClosed, let webView else { return }
        guard fitCount < Self.maximumFits else { return }

        webView.evaluateJavaScript(Self.measureCardScript) { [weak self] result, _ in
            guard let self, self.isSDKPlacedWidget, !self.isClosed else { return }

            guard let box = result as? [String: Any],
                  let width = (box["w"] as? NSNumber)?.doubleValue,
                  let height = (box["h"] as? NSNumber)?.doubleValue else {
                self.core.logger.d(Self.module, "measureAndFitCard", "the card could not be measured, so the widget keeps the size its type allows")
                return
            }

            guard self.applyMeasuredCard(width: width, height: height,
                                         via: box["via"] as? String ?? "?",
                                         reason: "measure") else { return }

            // Measured again, because one pass does not converge.
            //
            // The card was measured inside the box it had at the time. Shrinking
            // the box to the card reflows the page, and the card settles at a
            // different height again, leaving the same gap one size smaller. Java
            // allows three fits per page load for exactly this; running the
            // measurement once ported the limit without the loop it was limiting.
            //
            // This terminates: `fitCount` caps it, and the tolerance stops it as
            // soon as two passes agree within a few points, which is what
            // convergence looks like.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.measureDelay) { [weak self] in
                self?.measureAndFitCard()
            }
        }
    }

    /// Fits the box to a measured card. Returns whether the box changed.
    ///
    /// - Parameter reason: what prompted the measurement. `mutation` means the page
    ///   changed its content, which is a new screen, and a new screen gets a fresh
    ///   fit budget: the cap exists to stop one screen's measurement chasing
    ///   itself, not to freeze the card at the first screen's size.
    @discardableResult
    private func applyMeasuredCard(width: CGFloat, height: CGFloat, via: String, reason: String) -> Bool {
        guard isSDKPlacedWidget, !isClosed else { return false }

        // Under the floor is a wrapper caught mid layout, not a card.
        guard width >= Self.minimumCardSide, height >= Self.minimumCardSide else {
            core.logger.d(Self.module, "applyMeasuredCard", "the measurement is too small to be the card and is ignored, measured: [\(width.logValue)x\(height.logValue)], reason: [\(reason)]")
            return false
        }

        if reason == "mutation" { fitCount = 0 }
        guard fitCount < Self.maximumFits else {
            core.logger.d(Self.module, "applyMeasuredCard", "the fit budget for this screen is spent, so the measurement is ignored, measured: [\(width.logValue)x\(height.logValue)], reason: [\(reason)]")
            return false
        }

        let current = baseWebViewFrame?.height ?? 0
        guard abs(current - height) > Self.fitTolerance else { return false }

        // Not held to the type's maximum: this is the page's own formula read after
        // layout, and a step taller than the maximum needs the room or it scrolls.
        let fitted = WidgetLayout.resolve(type: presentedWidgetType,
                                          position: presentedWidgetPosition,
                                          surface: containerSize,
                                          requestedHeight: height,
                                          boundedByTypeMaximum: false)

        // A type with a fixed box, the rating widget, resolves to the same frame
        // whatever was measured. That is not a fit, and counting it against the
        // budget or logging it as one would misreport what happened.
        guard fitted != baseWebViewFrame else { return false }

        fitCount += 1
        measuredCardHeight = height

        core.logger.i(Self.module, "applyMeasuredCard", "the box is fitted to the card the page drew, measuredCard: [\(width.logValue)x\(height.logValue)], via: [\(via)], reason: [\(reason)], from: [\(current.logValue)], to: [\(fitted.height.logValue)], fit: [\(fitCount)]")

        baseWebViewFrame = fitted
        applySafeAreaPlacement()
        firstFitArrived()
        return true
    }

    private func installCardObserver() {
        webView?.evaluateJavaScript(Self.cardObserverScript) { [weak self] _, error in
            guard let error else { return }
            self?.core.logger.w(Self.module, "installCardObserver", "the card cannot be watched, so a screen the page mis-measures keeps the wrong size, error: [\(error.localizedDescription)]")
        }
    }

    private func installWidgetBridge() {
        webView?.evaluateJavaScript(Self.widgetBridgeScript) { [weak self] _, error in
            guard let error else { return }
            self?.core.logger.w(Self.module, "installWidgetBridge", "the page's replies cannot be forwarded, so a size it asks for will not be seen, error: [\(error.localizedDescription)]")
        }
    }

    private func reportSurfaceToPage() {
        guard let webView else { return }

        let size = surfaceSizeForPage()

        // Only when it changed.
        //
        // This is called from the layout pass, and resizing the panel *is* a layout
        // pass, so reporting unconditionally makes a loop: tell the page, the page
        // answers, the answer resizes the panel, the resize re-tells the page. The
        // widget then oscillates between the size its type allows and the size its
        // card measured, several times a second, and never settles. The page only
        // needs telling when the room it has is genuinely different.
        guard size != lastReportedSurface else { return }
        lastReportedSurface = size
        core.logger.d(Self.module, "reportSurfaceToPage", "the page is told how much room it has, so it can ask for the size it wants, width: [\(size.width.logValue)], height: [\(size.height.logValue)]")

        let script = "window.postMessage({type: 'resize', width: \(size.width), height: \(size.height)}, '*');"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            self?.core.logger.w(Self.module, "reportSurfaceToPage", "the surface could not be reported to the page, so it will size itself against the viewport it was given, error: [\(error.localizedDescription)]")
        }
    }

    /// The size reported to the page, transposed for a page pinned to portrait the
    /// same way the resolution sent to the server is.
    private func surfaceSizeForPage() -> CGSize {
        let size = containerSize
        guard isPinnedToPortrait, size.width > size.height else { return size }
        return CGSize(width: size.height, height: size.width)
    }



    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !Self.isCancellation(error) else {
            core.logger.d(Self.module, "didFail", "the navigation was cancelled rather than failing, the page is left as it is")
            return
        }
        let failure = error as NSError
        core.logger.d(Self.module, "didFail", "the page failed to load after being committed and the web view is dismissed, error: [\(failure.localizedDescription)], domain: [\(failure.domain)], code: [\(failure.code)], reason: [navigation-failure]")
        close()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !Self.isCancellation(error) else {
            core.logger.d(Self.module, "didFailProvisionalNavigation", "the navigation was cancelled rather than failing, the page is left as it is")
            return
        }
        let failure = error as NSError
        core.logger.d(Self.module, "didFailProvisionalNavigation", "the page failed to start loading and the web view is dismissed, error: [\(failure.localizedDescription)], domain: [\(failure.domain)], code: [\(failure.code)], reason: [navigation-failure]")
        close()
    }

    /// Whether a navigation failure is the SDK's own `.cancel` coming back.
    ///
    /// Every action event URL is answered with `decisionHandler(.cancel)`, and
    /// WebKit reports that as a failed navigation carrying `NSURLErrorCancelled`.
    /// Tearing the page down for it would close a content the page was only asking
    /// to resize. The reference dismisses on every error and has the same bug.
    private static func isCancellation(_ error: Error) -> Bool {
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled
    }
}

#if os(iOS) || os(visionOS)
/// Hosts the overlay content and reports interface size changes.
final class WebViewController: UIViewController {

    /// Called when the interface size changes, which is the reliable rotation
    /// signal: the device orientation notification also fires for face up and face
    /// down, which do not change the layout.
    ///
    /// Called twice per rotation. First inside the transition's animation, with
    /// `false`, so the page's new frame animates together with the application
    /// instead of snapping into place once the rotation has finished. Then from the
    /// completion, with `true`, when the window and its safe area have settled: a
    /// frame worked out mid-transition from insets that had not yet changed is
    /// corrected there, and the page is told about its new room only then.
    var sizeChangeHandler: ((_ settled: Bool) -> Void)?

    var contentView: UIView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let contentView {
                contentView.frame = view.bounds
                view.addSubview(contentView)
            }
        }
    }

    override func loadView() {
        view = PassThroughBackgroundView(frame: ScreenReader.screenBounds)
        view.backgroundColor = .clear
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.sizeChangeHandler?(false)
        }, completion: { [weak self] _ in
            self?.sizeChangeHandler?(true)
        })
    }
}
#endif

/// Forwards `WKScriptMessage`s to a `WebViewManager` without retaining it.
///
/// `WKUserContentController` holds its message handlers strongly, and the manager
/// owns the web view that owns the controller, so registering the manager itself
/// would make a cycle that nothing ever breaks.
private final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {

    private weak var target: WebViewManager?

    init(target: WebViewManager) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.handleScriptMessage(name: message.name, body: message.body)
    }
}

#endif
