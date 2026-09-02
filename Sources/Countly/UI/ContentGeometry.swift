//
//  ContentGeometry.swift
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

/// Where a content page is allowed to sit on screen.
///
/// The server lays a piece of content out against a size this SDK reports at fetch
/// time, and the SDK then places what comes back. Both halves live here because
/// they have to agree: a page told it has the whole 874pt window and then placed in
/// the 812pt between the Dynamic Island and the home indicator is a page that
/// scrolls, with its buttons cut in half at the bottom edge.
enum ContentGeometry {

#if os(macOS)

    /// The overlay is a panel of its own and the surface frame already has the menu
    /// bar and the Dock taken out, so there is nothing further to subtract.
    static func windowSize(displayOption: WebViewDisplayOption,
                           surface: PresentationSurface = .screen) -> CGSize {
        ScreenReader.surfaceFrame(surface).size
    }

    /// Nothing to clear: the size above had nothing removed from it.
    static func placementOffset(displayOption: WebViewDisplayOption) -> CGPoint {
        .zero
    }

    /// What the size above was derived from, for the log line that reports it.
    static var windowBounds: CGSize { ScreenReader.screenBounds.size }

    static var safeAreaDescription: String { "none" }

#else

    /// A top inset at least this large is a hardware cutout rather than an ordinary
    /// status bar, which is 20pt.
    private static let notchInsetThreshold: CGFloat = 44

    private static var window: UIWindow? { ScreenReader.keyWindow }

    private static var safeAreaInsets: UIEdgeInsets { window?.safeAreaInsets ?? .zero }

    /// What the reported size was derived from.
    ///
    /// Logged next to the result, because a content page laid out against the wrong
    /// size is the failure this type exists to prevent, and the number alone does
    /// not say whether the window or the insets were what went wrong.
    static var windowBounds: CGSize { window?.bounds.size ?? ScreenReader.screenBounds.size }

    static var safeAreaDescription: String {
        let insets = safeAreaInsets
        return "top=\(insets.top.logValue) left=\(insets.left.logValue) bottom=\(insets.bottom.logValue) right=\(insets.right.logValue)"
    }

    static func windowSize(displayOption: WebViewDisplayOption) -> CGSize {
        // Falls back to the screen when there is no window to read, which is the
        // one case where the insets are unknowable. Reporting a zero size instead
        // would have the server lay the content out against nothing.
        contentSize(in: window?.bounds.size ?? ScreenReader.screenBounds.size,
                    insets: safeAreaInsets,
                    displayOption: displayOption)
    }

    static func placementOffset(displayOption: WebViewDisplayOption) -> CGPoint {
        placementOffset(insets: safeAreaInsets,
                        displayOption: displayOption,
                        isLandscapeLeft: interfaceOrientation == .landscapeLeft)
    }

    /// The size a content page is laid out against.
    ///
    /// A cutout is subtracted whatever the display option says, because nothing
    /// legible fits behind one: immersive means "under the status bar", not "under
    /// the Dynamic Island". The bottom inset only goes in safe area mode, which is
    /// what asks for the home indicator to be left clear.
    static func contentSize(in bounds: CGSize,
                            insets: UIEdgeInsets,
                            displayOption: WebViewDisplayOption) -> CGSize {
        var size = bounds

        if hasTopNotch(insets) || displayOption == .safeArea {
            size.height -= insets.top
        }
        if displayOption == .safeArea {
            size.height -= insets.bottom
        }
        // The cutout is on one side or the other depending on which way the device
        // is held, and the usable width is the same either way, so subtracting the
        // larger of the two covers both.
        size.width -= Swift.max(insets.left, insets.right)

        return size
    }

    /// How far a placement has to move to clear the insets `contentSize` removed.
    ///
    /// Applied to the placement the server sent, never to the frame already on
    /// screen: the shifts are additive, so re-applying them walks the page off the
    /// display one rotation at a time.
    static func placementOffset(insets: UIEdgeInsets,
                                displayOption: WebViewDisplayOption,
                                isLandscapeLeft: Bool) -> CGPoint {
        var offset = CGPoint.zero

        if hasTopNotch(insets) || displayOption == .safeArea {
            offset.y = insets.top
        }

        // In landscape left the cutout sits on the trailing edge, so the content
        // already starts clear of it and shifting would only push it off the far
        // side. In portrait both insets are zero and this is a no-op.
        if !isLandscapeLeft {
            offset.x = Swift.max(insets.left, insets.right)
        }

        return offset
    }

    /// Whether the top inset is a hardware cutout rather than a status bar.
    private static func hasTopNotch(_ insets: UIEdgeInsets) -> Bool {
        insets.top >= notchInsetThreshold
    }

    private static var interfaceOrientation: UIInterfaceOrientation {
        #if os(iOS)
        if #available(iOS 13.0, *) {
            return window?.windowScene?.interfaceOrientation ?? .portrait
        }
        return UIApplication.shared.statusBarOrientation
        #else
        // visionOS has no device orientation, so a window is never rotated away
        // from the cutout-free case.
        return .portrait
        #endif
    }

#endif
}
#endif
