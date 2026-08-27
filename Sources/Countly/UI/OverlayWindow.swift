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
#endif
