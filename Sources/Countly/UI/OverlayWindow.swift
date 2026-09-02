//
//  OverlayWindow.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

#if os(iOS) || os(visionOS)
import UIKit

/// The window SDK-rendered content is presented in.
///
/// A window of its own rather than a modal on the host application's view
/// controller: content and feedback widgets have to appear over whatever is on
/// screen without interfering with the application's own navigation, and without
/// the application being able to dismiss them by accident.
final class OverlayWindow: UIWindow {

    /// Places the window on the active scene at just above normal level, so it
    /// covers the application but stays below system alerts.
    ///
    /// A scene-less window is created on iOS 12, where scenes do not exist.
    init() {
        #if os(visionOS)
        if let scene = OverlayWindow.activeWindowScene() {
            super.init(windowScene: scene)
        } else {
            super.init(frame: ScreenReader.screenBounds)
        }
        #else
        if #available(iOS 13.0, *), let scene = OverlayWindow.activeWindowScene() {
            super.init(windowScene: scene)
        } else {
            super.init(frame: ScreenReader.screenBounds)
        }
        #endif

        backgroundColor = .clear
        windowLevel = .normal + 1
        isHidden = true
    }

    @available(iOS 13.0, *)
    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Lets touches outside the presented content reach the application below.
    ///
    /// Without this the whole screen would be captured by a widget occupying a
    /// corner of it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === rootViewController?.view ? nil : hit
    }
}

/// Background view of the overlay that only claims the touches its subviews want.
final class PassThroughBackgroundView: UIView {

    /// When set, the view reports portrait dimensions whatever the device
    /// orientation is, which is how content pinned to portrait keeps its layout.
    var reportPortraitSizeOnly = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        for subview in subviews.reversed() {
            let converted = convert(point, to: subview)
            if let hit = subview.hitTest(converted, with: event) {
                return hit
            }
        }
        return nil
    }

    /// The size content should be laid out against.
    var effectiveSize: CGSize {
        guard reportPortraitSizeOnly else { return bounds.size }
        let shorter = Swift.min(bounds.width, bounds.height)
        let longer = Swift.max(bounds.width, bounds.height)
        return CGSize(width: shorter, height: longer)
    }
}

#elseif os(macOS)
import AppKit

/// The window SDK-rendered content is presented in.
///
/// A borderless, transparent panel floating above the application rather than a
/// sheet on one of its windows: content has to appear over whatever the user is
/// doing without taking key focus away from it and without being tied to a window
/// the application might close underneath it.
///
/// `NSPanel` rather than `NSWindow` because a panel can be non-activating, which is
/// what keeps the application's own window key while content is on screen.
final class OverlayWindow: NSPanel {

    /// - Parameter surfaceFrame: the desktop region content is shown in, which is
    ///   the screen or the application's own window depending on configuration.
    ///   This rect positions the panel on the desktop, so it has to carry a real
    ///   origin or the panel lands on whichever display owns the global origin.
    init(surfaceFrame: CGRect) {
        super.init(contentRect: surfaceFrame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the application but below system alerts, matching where the iOS
        // overlay sits in the window level order.
        level = .floating
        // Follows the user across spaces, like the content it is showing.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Set on the panel as well as in the view's hit testing: a borderless
        // panel would otherwise swallow clicks in its transparent areas.
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        orderOut(nil)
    }

    /// A borderless panel is not key by default, and the content page needs to
    /// receive typing for a survey's free-text answer.
    override var canBecomeKey: Bool { true }

    /// The application stays the main window, so its title bar does not dim while
    /// content is up.
    override var canBecomeMain: Bool { false }

    /// AppKit's counterpart of the iOS window's `isHidden`, so the shared
    /// presentation code reads the same on both platforms.
    var isHidden: Bool {
        get { !isVisible }
        set { newValue ? orderOut(nil) : orderFrontRegardless() }
    }

    /// The view the panel presents, mirroring `rootViewController` on iOS.
    var rootViewController: WebViewController? {
        didSet { contentViewController = rootViewController }
    }
}

/// Background view of the overlay that only claims the clicks its subviews want.
///
/// `NSView.hitTest` takes a point in the *superview's* coordinates and has no
/// event, which is the one place the two platforms' hit testing genuinely differ.
final class PassThroughBackgroundView: NSView {

    /// When set, the view reports portrait dimensions whatever the window shape is,
    /// which is how content pinned to portrait keeps its layout.
    var reportPortraitSizeOnly = false

    /// Top-left origin, so the geometry a content page sends means the same thing
    /// here as it does on iOS. Without this every `resize_me` would be upside down.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(convert(local, to: superview)) { return hit }
        }
        return nil
    }

    /// The size content should be laid out against.
    var effectiveSize: CGSize {
        guard reportPortraitSizeOnly else { return bounds.size }
        let shorter = Swift.min(bounds.width, bounds.height)
        let longer = Swift.max(bounds.width, bounds.height)
        return CGSize(width: shorter, height: longer)
    }
}

/// Hosts the overlay content and reports size changes.
///
/// The iOS counterpart hears about rotation; a macOS window is resized instead,
/// which is the same signal for the same purpose.
final class WebViewController: NSViewController {

    var sizeChangeHandler: (() -> Void)?

    var contentView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let contentView {
                contentView.frame = view.bounds
                view.addSubview(contentView)
            }
        }
    }

    override func loadView() {
        // Not read from `view`: `loadView` is what creates it, so touching it here
        // calls straight back into this method. The window resizes the content view
        // to itself as soon as it is installed, and the autoresizing mask keeps it
        // that way, so this initial frame only has to be non-degenerate.
        let background = PassThroughBackgroundView(frame: ScreenReader.overlayFrame)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.clear.cgColor
        background.autoresizingMask = [NSView.AutoresizingMask.width, .height]
        view = background
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        sizeChangeHandler?()
    }
}
#endif
