//
//  CountlyContentConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// How a content presentation ended.
public enum ContentStatus: Int, Sendable {
    /// The user reached the end of the content flow.
    case completed
    /// The content was dismissed before completing.
    case closed
}

/// How the content and feedback web views are laid out.
public enum WebViewDisplayOption: Int, Sendable {
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
public final class CountlyContentConfig {

    /// Notified when a content presentation completes or is closed.
    public var globalContentCallback: ContentCallback?

    /// How often the SDK asks the server for content while a content zone is
    /// entered, in seconds. Default 30.
    ///
    /// Anything at or below the minimum is ignored and the previous value kept,
    /// which is what the other Countly SDKs do. Polling every second or two is
    /// never what an integration means, and the cost of taking it literally is
    /// paid by the server rather than by whoever set it.
    public var zoneTimerInterval: Int = 30 {
        didSet {
            if zoneTimerInterval <= Self.minimumZoneTimerInterval {
                zoneTimerInterval = oldValue
            }
        }
    }

    /// The shortest polling interval the SDK accepts, in seconds.
    static let minimumZoneTimerInterval = 15

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

    /// Layout of the content and feedback web views. Default `.safeArea`.
    ///
    /// The safe area rather than the full screen, so what the SDK draws clears the
    /// notch, the home indicator and, on macOS, the menu bar and the Dock. A page
    /// laid out under any of those is a page with part of itself unreadable or
    /// untappable, and the SDK cannot know which part matters.
    ///
    /// Note this differs from the Android SDK, which defaults to `IMMERSIVE`.
    public var webViewDisplayOption: WebViewDisplayOption = .safeArea

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

    public init() {}
}
