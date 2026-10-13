//
//  AutoViewTracker.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
import ObjectiveC

/// Watches view controller appearances and hands them to whichever instances
/// asked for automatic view tracking.
///
/// The swizzle it installs is process-wide and can only be installed once, so the
/// tracker is a shared object with a registry rather than a per-instance one.
/// Everything downstream of the callback is per instance: each subscriber applies
/// its own exclusion list, consent and behavior settings.
final class AutoViewTracker {

    static let shared = AutoViewTracker()

    private let subscribers = WeakRegistry<ViewsModule>()
    private let swizzleLock = NSLock()
    private var hasSwizzled = false

    private init() {}

    /// Adds a module and installs the swizzle on first use.
    func register(_ module: ViewsModule) {
        subscribers.add(module)

        swizzleLock.lock()
        let shouldSwizzle = !hasSwizzled
        hasSwizzled = true
        swizzleLock.unlock()

        if shouldSwizzle {
            AutoViewTracker.installSwizzle()
        }
    }

    /// Removes a module. The swizzle stays installed: uninstalling it would race
    /// with any appearance in flight, and with no subscribers it does nothing.
    func deregister(_ module: ViewsModule) {
        subscribers.remove(module)
    }

    /// Fans an appearance out to every registered module.
    ///
    /// The swizzle outlives the last subscriber, so this runs for every screen in
    /// the host application even when the SDK is halted. The empty case is the
    /// common one and costs nothing.
    func viewControllerDidAppear(_ viewController: UIViewController) {
        guard !subscribers.isEmpty else { return }

        for module in subscribers.current() {
            module.handleAutoTrackedViewController(viewController)
        }
    }

    // MARK: - Swizzling

    private static func installSwizzle() {
        exchange(#selector(UIViewController.viewDidAppear(_:)),
                 #selector(UIViewController.countly_viewDidAppear(_:)))
        exchange(#selector(UIViewController.viewDidDisappear(_:)),
                 #selector(UIViewController.countly_viewDidDisappear(_:)))
    }

    private static func exchange(_ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, original),
              let replacementMethod = class_getInstanceMethod(UIViewController.self, replacement) else { return }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    // MARK: - Naming

    /// The name a view controller is reported under.
    ///
    /// Falls back down a chain rather than to a single source, because a view
    /// controller may express its name in any of these and an unnamed screen is
    /// worse than a class name. A compiler-mangled class name is worse still: a
    /// SwiftUI hosting controller is named by the view it hosts instead, and any
    /// other screen left with only a mangled name is `nil`.
    static func title(for viewController: UIViewController?) -> String? {
        guard let viewController else { return nil }

        if let named = viewController as? CountlyAutoViewTrackingName,
           let custom = named.countlyAutoViewTrackingName {
            return custom
        }

        // Emptiness, not just nil: a controller that sets `title = ""` to blank its
        // back button would otherwise report a nameless view, which the view module
        // then rejects, so the screen is never tracked at all.
        if let title = viewController.title, !title.isEmpty { return title }

        if let label = viewController.navigationItem.titleView as? UILabel,
           let text = label.text, !text.isEmpty {
            return text
        }

        if let navigationTitle = viewController.navigationItem.title, !navigationTitle.isEmpty {
            return navigationTitle
        }

        // A generic or private Swift class, a SwiftUI hosting controller among
        // them, only has its mangled runtime name here, such as
        // `_TtGC7SwiftUI19UIHostingControllerV5MyApp11ContentView_`, which no one
        // reading the dashboard can recognise.
        let className = NSStringFromClass(type(of: viewController))
        guard className.hasPrefix("_Tt") else { return className }
        return hostedViewName(of: viewController)
    }

    /// The type name of the view a SwiftUI hosting controller hosts.
    ///
    /// Read off the readable type name of its `UIHostingController` ancestor, so
    /// SwiftUI's own subclasses are covered too, with `ModifiedContent` wrappers
    /// taken off: `UIHostingController<ModifiedContent<ContentView, …>>` is
    /// `ContentView`.
    ///
    /// - Returns: `nil` for a view controller that hosts no SwiftUI view, and for
    ///   a root erased to `AnyView`, which is what SwiftUI's own sheet and
    ///   navigation hosts hold and which names no screen.
    private static func hostedViewName(of viewController: UIViewController) -> String? {
        var ancestor: AnyClass? = type(of: viewController)
        while let current = ancestor {
            if let hosting = genericComponents(of: String(describing: current)),
               hosting.base == "UIHostingController" {
                return rootViewName(hosting.arguments.first)
            }
            ancestor = class_getSuperclass(current)
        }
        return nil
    }

    /// A hosted root view's type name with its `ModifiedContent` wrappers taken
    /// off, or `nil` when nothing that names a screen is left.
    private static func rootViewName(_ typeName: String?) -> String? {
        guard var name = typeName else { return nil }

        while let modified = genericComponents(of: name),
              modified.base == "ModifiedContent",
              let content = modified.arguments.first {
            name = content
        }

        guard !name.isEmpty, name != "AnyView" else { return nil }
        return name
    }

    /// Splits a generic type name such as `Base<A, B<C, D>>` into its base name
    /// and its top-level arguments, or returns `nil` for a name that is not
    /// generic.
    private static func genericComponents(of typeName: String) -> (base: String, arguments: [String])? {
        guard typeName.hasSuffix(">"), let open = typeName.firstIndex(of: "<") else { return nil }

        let base = String(typeName[..<open])
        let inner = typeName[typeName.index(after: open)..<typeName.index(before: typeName.endIndex)]

        var arguments: [String] = []
        var current = ""
        var depth = 0
        for character in inner {
            switch character {
            case "<", "(":
                depth += 1
                current.append(character)
            case ">", ")":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }
        arguments.append(current.trimmingCharacters(in: .whitespaces))

        return (base, arguments)
    }

    /// Test hook: supplies the screen on display where no window scene is
    /// connected, as in a test host without an application.
    static var topViewControllerOverride: (() -> UIViewController?)?

    /// The view controller currently on screen.
    static func topViewController() -> UIViewController? {
        if let override = topViewControllerOverride {
            return override()
        }
        var top = ScreenReader.keyWindow?.rootViewController

        while true {
            if let presented = top?.presentedViewController {
                top = presented
            } else if let navigation = top as? UINavigationController {
                top = navigation.topViewController
            } else if let tab = top as? UITabBarController {
                top = tab.selectedViewController
            } else {
                break
            }
        }

        return top
    }

    /// Container view controllers that describe structure rather than a screen.
    static let defaultExclusionList: [String] = [
        "CountlyInternalViewController",
        "UINavigationController",
        "UIAlertController",
        "UIPageViewController",
        "UITabBarController",
        "UIReferenceLibraryViewController",
        "UISplitViewController",
        "UIInputViewController",
        "UISearchController",
        "UISearchContainerViewController",
        "UIApplicationRotationFollowingController",
        "MFMailComposeInternalViewController",
        "MFMailComposePlaceholderViewController",
        "UIInputWindowController",
        "_UIFallbackPresentationViewController",
        "UIActivityViewController",
        "UIActivityGroupViewController",
        "_UIActivityGroupListViewController",
        "_UIActivityViewControllerContentController",
        "UIKeyboardCandidateRowViewController",
        "UIKeyboardCandidateGridCollectionViewController",
        "UIPrintMoreOptionsTableViewController",
        "UIPrintPanelTableViewController",
        "UIPrintPanelViewController",
        "UIPrintPaperViewController",
        "UIPrintPreviewViewController",
        "UIPrintRangeViewController",
        "UIDocumentMenuViewController",
        "UIDocumentPickerViewController",
        "UIDocumentPickerExtensionViewController",
        "UIInterfaceActionGroupViewController",
        "UISystemInputViewController",
        "UIRecentsInputViewController",
        "UICompatibilityInputViewController",
        "UIInputViewAnimationControllerViewController",
        "UISnapshotModalViewController",
        "UIMultiColumnViewController",
        "UIKeyCommandDiscoverabilityHUDViewController",
    ]
}

/// Lets a view controller name itself for automatic view tracking.
@objc public protocol CountlyAutoViewTrackingName: AnyObject {
    /// The name to report instead of the title or class name.
    var countlyAutoViewTrackingName: String? { get }
}

extension UIViewController {

    /// Swizzled in place of `viewDidAppear`. The call to itself reaches the
    /// original implementation, because the two are exchanged.
    @objc dynamic func countly_viewDidAppear(_ animated: Bool) {
        countly_viewDidAppear(animated)

        AutoViewTracker.shared.viewControllerDidAppear(self)

        // Since iOS 13 a dismissed page sheet does not re-trigger `viewDidAppear`
        // on the controller behind it, and `presentingViewController` is already
        // nil by the time it disappears. Capturing it here is the only moment the
        // link still exists.
        if isCountlyPageSheetModal {
            var presenting = presentingViewController
            if let navigation = presenting as? UINavigationController {
                presenting = navigation.topViewController
            }
            countlyPresentingViewController = presenting
        }
    }

    /// Swizzled in place of `viewDidDisappear`.
    @objc dynamic func countly_viewDidDisappear(_ animated: Bool) {
        countly_viewDidDisappear(animated)

        if let presenting = countlyPresentingViewController {
            AutoViewTracker.shared.viewControllerDidAppear(presenting)
            countlyPresentingViewController = nil
        }
    }

    private var isCountlyPageSheetModal: Bool {
        #if os(iOS) || os(visionOS)
        return modalPresentationStyle == .pageSheet && isBeingPresented
        #else
        return false
        #endif
    }

    /// Associated storage for the controller a page sheet was presented from.
    ///
    /// Held in a weak box rather than as an unretained pointer: the stored
    /// controller can be popped off its navigation stack while the sheet is up, and
    /// reading a raw unretained reference afterwards is a use after free.
    private var countlyPresentingViewController: UIViewController? {
        get {
            (objc_getAssociatedObject(self, &AssociatedKeys.presentingViewController) as? WeakViewControllerBox)?.value
        }
        set {
            objc_setAssociatedObject(self,
                                     &AssociatedKeys.presentingViewController,
                                     newValue.map(WeakViewControllerBox.init),
                                     .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

/// Holds a view controller weakly so it can be stored in an associated object
/// without keeping it alive or dangling.
private final class WeakViewControllerBox {
    weak var value: UIViewController?
    init(_ value: UIViewController) { self.value = value }
}

private enum AssociatedKeys {
    static var presentingViewController: UInt8 = 0
}
#endif
