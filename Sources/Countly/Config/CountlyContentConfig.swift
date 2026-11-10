//
//  CountlyContentConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// How a content presentation ended.
@objc public enum ContentStatus: Int, Sendable {
    /// The user reached the end of the content flow.
    case completed
    /// The content was dismissed before completing.
    case closed
}

/// How the content and feedback web views are laid out.
@objc public enum WebViewDisplayOption: Int, Sendable {
    /// Full screen, ignoring safe area insets.
    case immersive
    /// Inset to the safe area.
    case safeArea
}

/// Called when a content presentation finishes.
public typealias ContentCallback = (_ status: ContentStatus, _ data: [String: Any]) -> Void

/// Called when a link is opened from the content web view.
///
/// Return `true` if the host application routed the URL itself. Returning
/// `false`, or not installing a handler, lets the SDK open it in the system
/// browser. Always called on the main thread.
public typealias ContentURLHandler = (_ url: URL) -> Bool

/// Content zone settings.
///
/// Content is an experimental feature and these options may change.
@objcMembers
public final class CountlyContentConfig: NSObject {

    /// Notified when a content presentation completes or is closed.
    public var globalContentCallback: ContentCallback?

    /// How often the SDK asks the server for content while a content zone is
    /// entered, in seconds. Default 30, at least 15.
    ///
    /// A value below 15 is ignored with a warning at start and the default used.
    /// Polling every second or two is never what an integration means, and the
    /// cost of taking it literally is paid by the server rather than by whoever
    /// set it.
    public var zoneTimerInterval: Int = CountlyContentConfig.defaultZoneTimerInterval

    /// The shortest polling interval the SDK accepts, in seconds.
    static let minimumZoneTimerInterval = 15

    /// The polling interval when none is configured, in seconds.
    static let defaultZoneTimerInterval = 30

    /// Corner radius of the overlay, in points, or `nil` to take the window's own.
    ///
    /// Only has an effect alongside `showWidgetsWithinApp`, where the overlay is
    /// sized to the application's window and has to be shaped like it: a page that
    /// paints a full-surface backdrop otherwise draws square corners over the
    /// window's curved ones.
    ///
    /// Left `nil`, the SDK reads the radius from the window at presentation time,
    /// which is right for a standard window on any macOS version and needs no
    /// configuration. Set it when the application gives its window a shape of its
    /// own, since nothing the SDK can read will describe that.
    public var overlayCornerRadius: CGFloat?

    /// `overlayCornerRadius` for Objective-C, in points, or `nil`.
    @available(swift, obsoleted: 1)
    @objc(overlayCornerRadius)
    public var objcOverlayCornerRadius: NSNumber? {
        get { overlayCornerRadius.map { NSNumber(value: Double($0)) } }
        set { overlayCornerRadius = newValue.map { CGFloat($0.doubleValue) } }
    }

    /// Layout of the content and feedback web views. Default `.immersive`, except
    /// `.safeArea` on macOS.
    ///
    /// Immersive draws under the status bar and the home indicator, which is what
    /// the Android and Objective-C SDKs do by default. A hardware cutout is always
    /// kept clear whatever the option says. `.safeArea` keeps the page inside the
    /// safe area instead. On macOS the option only names where the panel sits, so
    /// it stays inside the visible frame, clear of the menu bar and the Dock.
    public var webViewDisplayOption: WebViewDisplayOption = {
        #if os(macOS)
        return .safeArea
        #else
        return .immersive
        #endif
    }()

    /// Reloads the content web view when a load stalls instead of closing it.
    ///
    /// A reload reuses the warm connection and cached assets, which recovers
    /// loads that fail when a server or edge drops the initial burst of parallel
    /// resource connections. Disabled by default.
    public var enableContentReloadOnStall: Bool = false

    /// How long a content load may stall before the SDK reloads it, in
    /// milliseconds. Only consulted when `enableContentReloadOnStall` is set.
    /// Default 1000.
    public var contentReloadOnStallTimeout: Int = 1000

    /// Turns off pinch and double-tap zoom in the content web view. The page's
    /// own viewport width and initial scale are preserved.
    public var disableZoom: Bool = false

    /// Pins displayed content to the portrait layout whatever the device
    /// orientation is, and does not re-place it on rotation. Never applies to
    /// feedback widgets.
    public var disableRotation: Bool = false

    /// Lets the host application take over links opened from the content web
    /// view, which is how an app routes its own deep links.
    public var contentURLHandler: ContentURLHandler?

    /// The URI schemes links from content and feedback widgets may open, compared
    /// without case, for example `["https", "myapp"]`. Checked after
    /// `contentURLHandler` declined the link.
    ///
    /// Empty by default, which allows every scheme except the dangerous ones:
    /// file, content, javascript, jar, zip, intent and data. Those are never
    /// opened. A refused link is logged as a warning.
    public var allowedLinkSchemes: [String] = []

    /// Shows content and feedback widgets inside the application's own window
    /// rather than over the whole screen.
    ///
    /// Off by default, which lays everything out against the screen the application
    /// is on, minus the menu bar and the Dock. Turn it on to keep everything the
    /// SDK draws within the application, so it moves with the window and never
    /// paints over anything else. Falls back to the screen when the application has
    /// no window to measure, which is an agent or a menu bar application.
    ///
    /// Has no effect where the application already fills the screen, which is every
    /// platform except macOS.
    public var showWidgetsWithinApp: Bool = false

    public override init() {}

    /// Takes every value of `other`, for the snapshot an instance runs on.
    func copyValues(from other: CountlyContentConfig) {
        globalContentCallback = other.globalContentCallback
        zoneTimerInterval = other.zoneTimerInterval
        overlayCornerRadius = other.overlayCornerRadius
        webViewDisplayOption = other.webViewDisplayOption
        enableContentReloadOnStall = other.enableContentReloadOnStall
        contentReloadOnStallTimeout = other.contentReloadOnStallTimeout
        disableZoom = other.disableZoom
        disableRotation = other.disableRotation
        contentURLHandler = other.contentURLHandler
        allowedLinkSchemes = other.allowedLinkSchemes
        showWidgetsWithinApp = other.showWidgetsWithinApp
    }
}
