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
    public var zoneTimerInterval: Int = 30 {
        didSet {
            if zoneTimerInterval < 1 { zoneTimerInterval = 30 }
        }
    }

    /// Layout of the content and feedback web views. Default `.immersive`.
    public var webViewDisplayOption: WebViewDisplayOption = .immersive

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

    public init() {}
}
