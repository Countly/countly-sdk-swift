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

    /// Set when the caller supplied a frame, which means the server placed this
    /// page deliberately rather than asking for one that fills the screen.
    ///
    /// A placed page must survive a re-layout. Only a page with no placement of its
    /// own, which is every feedback widget, is re-filled when the interface resizes.
    private var hasExplicitPlacement = false

    /// Fires when a content page has not reported itself shown in time.
    private var stallTimer: Timer?

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
    }

    init(core: SDKCore) {
        self.core = core
        super.init()
    }

    // MARK: - Presentation

    /// Puts a page on screen.
    ///
    /// - Parameters:
    ///   - url: The page to load.
    ///   - frame: Where to place it. Defaults to filling the overlay.
    ///   - appear: Called once the page has loaded and is visible.
    ///   - dismiss: Called once the page has been taken off screen.
    func present(url: URL?,
                 frame: CGRect? = nil,
                 appear: (() -> Void)?,
                 dismiss: (() -> Void)?) {
        guard let url else {
            core.logger.e(Self.module, "present", "web view presentation is dropped, the URL could not be built")
            return
        }

        isFeedbackWidget = url.path.contains(Endpoint.feedback)
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

        let overlayWindow = OverlayWindow()
        let controller = WebViewController()
        #if !os(macOS)
        // The overlay is a window of its own, so the presentation style only
        // matters where a controller can be presented modally at all.
        controller.modalPresentationStyle = .overFullScreen
        #endif
        controller.sizeChangeHandler = { [weak self] in
            self?.handleInterfaceSizeChange()
        }
        overlayWindow.rootViewController = controller

        let background = PassThroughBackgroundView(frame: controller.view.bounds)
        #if os(macOS)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.clear.cgColor
        background.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        #else
        background.backgroundColor = .clear
        background.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        background.reportPortraitSizeOnly = isPinnedToPortrait
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

        let targetFrame = frame ?? background.bounds
        baseWebViewFrame = targetFrame
        hasExplicitPlacement = frame != nil
        core.logger.d(Self.module, "present", "the presentation frames were computed, webViewFrame: [\(targetFrame.logValue)], backgroundFrame: [\(background.bounds.logValue)]")

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
    }

    /// Takes the page off screen and reports the dismissal once.
    func close() {
        guard !isClosed else { return }
        isClosed = true

        core.logger.d(Self.module, "close", "web view is being closed")

        let finish = { [weak self] in
            guard let self else { return }
            // Invalidated here rather than above: a `Timer` has to be invalidated on
            // the thread that scheduled it, and `close()` accepts calls from any.
            self.cancelStallTimer()
            self.pendingReload?.cancel()
            self.pendingReload = nil
            self.webView?.stopLoading()
            self.webView?.navigationDelegate = nil
            let controller = self.webView?.configuration.userContentController
            controller?.removeScriptMessageHandler(forName: ScriptMessage.resourceLoadError)
            controller?.removeScriptMessageHandler(forName: ScriptMessage.resourceVerifyResult)
            controller?.removeAllUserScripts()
            self.webView?.removeFromSuperview()
            self.webView = nil
            self.window?.isHidden = true
            self.window?.rootViewController = nil
            self.window = nil
            self.backgroundView = nil

            let dismiss = self.dismissBlock
            self.dismissBlock = nil
            dismiss?()
        }

        onMainThread(finish)
    }

    private func reportAppearance() {
        guard !hasAppeared else { return }
        // A pending reload is cancelled by this flag alone: the scheduled block
        // checks it before reloading, so a load that succeeded during the delay
        // window is never wiped by the retry the earlier failure scheduled.
        hasAppeared = true
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

    /// Cancels the stall deadline once the page says it is showing something.
    private func cancelStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
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
        let screenArea = ScreenReader.overlayFrame
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
        window.setFrame(target, display: true)
        webView.frame = CGRect(origin: .zero, size: target.size)
        backgroundView?.frame = CGRect(origin: .zero, size: target.size)
        #else
        guard placed != webView.frame else { return }

        core.logger.d(Self.module, "applySafeAreaPlacement", "the page is placed clear of the safe area, baseFrame: [\(base.logValue)], offset: [\(offset.logValue)], frame: [\(placed.logValue)], safeAreaInsets: [\(ContentGeometry.safeAreaDescription)]")
        webView.frame = placed
        #endif
    }

    /// Drives the re-layout the platform would deliver, so the suite can assert on
    /// what a layout pass does to a placed page without waiting for a real one.
    func simulateInterfaceSizeChangeForTesting() {
        handleInterfaceSizeChange()
    }

    /// Re-lays the page out after a rotation, unless it is pinned to portrait.
    private func handleInterfaceSizeChange() {
        guard !isPinnedToPortrait else { return }
        guard let backgroundView, webView != nil else { return }

        // A page the server placed keeps its placement. macOS calls this from
        // `viewDidLayout`, which runs during the presentation itself, so filling
        // here would throw the server's coordinates away before the page had even
        // been seen: a 435x144 banner became the whole 3840x2130 screen. Only a
        // page that asked to fill, which is every feedback widget, is re-filled.
        guard !hasExplicitPlacement else {
            core.logger.d(Self.module, "handleInterfaceSizeChange", "the interface size changed, the page keeps the placement the server gave it, frame: [\(baseWebViewFrame?.logValue ?? "none")]")
            applySafeAreaPlacement()
            return
        }

        let filled = CGRect(origin: .zero, size: backgroundView.effectiveSize)
        core.logger.d(Self.module, "handleInterfaceSizeChange", "the interface size changed and the page is re-laid out, frame: [\(filled.logValue)]")
        baseWebViewFrame = filled
        applySafeAreaPlacement()
    }

    /// Applies a size the page asked for, in the page's own coordinate space.
    private func resize(with parameters: [String: Any]) {
        guard let backgroundView, webView != nil else { return }

        // The page describes where it wants to sit as a fraction of the screen,
        // under the key matching the current orientation.
        let isPortrait = backgroundView.effectiveSize.height >= backgroundView.effectiveSize.width
        let preferred = isPortrait ? "p" : "l"
        let fallback = isPortrait ? "l" : "p"

        // A page that only describes one orientation still wants to be resized.
        // Ignoring the request leaves the view at whatever frame the presentation
        // computed, which for a banner-sized content is the whole screen, and it
        // then covers and swallows every touch until it is closed.
        guard let geometry = (parameters[preferred] as? [String: Any])
                ?? (parameters[fallback] as? [String: Any]) else { return }

        let usedFallback = parameters[preferred] == nil
        let frame = CGRect(contentGeometry: geometry, container: backgroundView.effectiveSize)

        core.logger.d(Self.module, "resize", "the page asked to be resized, orientation: [\(isPortrait ? "portrait" : "landscape")], orientationKey: [\(usedFallback ? fallback : preferred)], usedFallbackOrientation: [\(usedFallback)], x: [\(frame.origin.x.logValue)], y: [\(frame.origin.y.logValue)], width: [\(frame.width.logValue)], height: [\(frame.height.logValue)]")
        core.logger.d(Self.module, "resize", "resize container detail, containerSize: [\(backgroundView.effectiveSize.logValue)], resizeGeometry: [\(parameters)]")

        baseWebViewFrame = frame
        hasExplicitPlacement = true
        applySafeAreaPlacement()
    }

    // MARK: - Actions

    /// Runs whatever the page asked for.
    private func handleAction(_ parameters: [String: Any]) {
        // The action runs first: a closing call to action carries both its event
        // and `close`, and returning early would throw the event away.
        defer {
            if let closeValue = parameters["close"] as? String, Self.isTruthy(closeValue) {
                core.logger.d(Self.module, "handleAction", "the content asked to be closed")
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
            if let link = parameters["link"] as? String {
                openExternalLink(link)
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
                reportAppearance()
            }

            core.logger.d(Self.module, "recordEvents", "recording a content event, key: [\(key)]")
            core.logger.d(Self.module, "recordEvents", "content event detail, key: [\(key)], segmentation: [\(segmentation)]")
            core.modules.events.recordEvent(key, segmentation: segmentation)
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
        }
    }

    /// Receives both injected scripts' messages.
    fileprivate func handleScriptMessage(name: String, body: Any) {
        switch name {
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

        decisionHandler(.allow)
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

        // A feedback widget renders itself as soon as it loads and never reports a
        // shown event, so loading is the only signal it has appeared.
        if isFeedbackWidget {
            reportAppearance()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        core.logger.d(Self.module, "didFail", "the page failed to load after being committed and the web view is dismissed, error: [\(failure.localizedDescription)], domain: [\(failure.domain)], code: [\(failure.code)], reason: [navigation-failure]")
        close()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failure = error as NSError
        core.logger.d(Self.module, "didFailProvisionalNavigation", "the page failed to start loading and the web view is dismissed, error: [\(failure.localizedDescription)], domain: [\(failure.domain)], code: [\(failure.code)], reason: [navigation-failure]")
        close()
    }
}

#if os(iOS) || os(visionOS)
/// Hosts the overlay content and reports interface size changes.
final class WebViewController: UIViewController {

    /// Called when the interface size changes, which is the reliable rotation
    /// signal: the device orientation notification also fires for face up and face
    /// down, which do not change the layout.
    var sizeChangeHandler: (() -> Void)?

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
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.sizeChangeHandler?()
        }
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
