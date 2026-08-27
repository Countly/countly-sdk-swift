//
//  PushRuntime.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import ObjectiveC

#if canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS))
import UserNotifications
#endif
#if os(iOS) || os(visionOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// What the process knows about its APNs device token.
///
/// A failed registration is not the same as no registration yet: the first means
/// the server should be told to stop trying to reach this device, the second means
/// there is nothing to say. A sentinel string spelled the difference before, which
/// every reader had to remember to compare against.
enum PushDeviceToken {
    case value(String)
    case failed
}

#if os(iOS) || os(visionOS) || os(macOS)

/// Everything about push that belongs to the process rather than to a Countly
/// instance.
///
/// The platform offers one APNs registration, one device token and one
/// `UNUserNotificationCenter` delegate. All three land here and are fanned out to
/// every instance that switched push on, so several instances can report the same
/// notification to their own servers.
final class PushRuntime: NSObject {

    static let shared = PushRuntime()

    private let subscribers = WeakRegistry<PushModule>()
    private let lock = NSLock()

    private var storedToken: PushDeviceToken?

    /// The token the process last received, or nil if none has arrived yet.
    var currentToken: PushDeviceToken? {
        lock.lock()
        defer { lock.unlock() }
        return storedToken
    }

    /// The delegate that was installed before this one, chained to so a host
    /// application that handles notifications itself keeps working.
    private weak var previousNotificationDelegate: AnyObject?
    private var hasInstalledNotificationDelegate = false
    private var hasGraftedApplicationDelegate = false

    private override init() {
        super.init()
    }

    // MARK: - Subscribers

    /// Adds a module, installs whatever the process needs, and replays a token
    /// that already arrived.
    ///
    /// The install decision lives here rather than in the module because it is
    /// process state: which instance happens to start first must not decide
    /// whether the application delegate gets grafted. `automaticHandling` is
    /// therefore a request, and the first instance to ask is the one that gets it.
    func register(_ module: PushModule, automaticHandling: Bool) {
        subscribers.add(module)

        // Assigned synchronously, before this call returns. `UNUserNotificationCenter`
        // requires its delegate to be in place before the application finishes
        // launching, and a host starts the SDK from `didFinishLaunching`; deferring
        // by even one run loop turn loses the response for a notification tap that
        // cold started the application, which is the single most valuable push
        // event there is.
        if automaticHandling { assertNotificationCenterDelegate() }

        // The graft does need the hop: reading the application delegate is main
        // thread work, and a host that installs its own delegates later in
        // `didFinishLaunching` has not finished doing so yet.
        DispatchQueue.main.async {
            if automaticHandling { self.graftApplicationDelegate() }
            self.requestRemoteNotificationRegistration()
        }

        // A token that arrived before this instance started still belongs to it.
        if let existing = currentToken {
            module.didReceive(existing)
        }
    }

    func deregister(_ module: PushModule) {
        // The application delegate graft stays: it is an implementation swap with
        // no "before" to restore, and a later instance would want it anyway. The
        // notification centre delegate is a slot that had an owner, so it is given
        // back once nobody is left to fan out to.
        if subscribers.remove(module) {
            uninstallNotificationCenterDelegate()
        }
    }

    #if os(macOS)
    /// Reports a notification that was clicked while the application was not
    /// running.
    ///
    /// macOS delivers that click through the application delegate's launch
    /// notification, not through the notification centre delegate, and by the time
    /// the SDK is started it has already happened. The host passes it in through
    /// `CountlyConfig.launchNotification`; without it a click that cold started the
    /// application records nothing and opens nothing.
    func replayLaunchNotification(_ launchInfo: [AnyHashable: Any]) {
        #if canImport(UserNotifications)
        guard let response = launchInfo[NSApplication.launchUserNotificationUserInfoKey] as? UNNotificationResponse else { return }
        handle(response: response)
        #endif
    }
    #endif

    /// Whether any registered instance has consent to act on a notification.
    private var hasAnyPushConsent: Bool {
        subscribers.current().contains { $0.hasPushConsent }
    }

    /// Asks the system to register for remote notifications. Main thread only.
    private func requestRemoteNotificationRegistration() {
        #if os(iOS) || os(visionOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    // MARK: - Token

    /// Call from `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Called automatically from the grafted application delegate unless the host
    /// switched automatic handling off, in which case the host forwards it.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        broadcast(.value(deviceToken.hexString))
    }

    /// Call from `application(_:didFailToRegisterForRemoteNotificationsWithError:)`.
    func didFailToRegisterForRemoteNotifications() {
        broadcast(.failed)
    }

    private func broadcast(_ token: PushDeviceToken) {
        lock.lock()
        storedToken = token
        lock.unlock()

        for module in subscribers.current() {
            module.didReceive(token)
        }
    }

    // MARK: - Application delegate

    /// Takes over the two remote notification registration callbacks so the host
    /// application does not have to forward them.
    ///
    /// The host's own implementation is always called afterwards, and one is only
    /// added when the host has none, so nothing the host does is lost. Done once
    /// per process however many instances ask for it, and never undone: there is no
    /// "before" implementation to restore, only the host's, which still runs.
    ///
    /// Main thread only.
    private func graftApplicationDelegate() {
        #if os(iOS) || os(visionOS)
        let delegate: AnyObject? = UIApplication.shared.delegate
        #else
        let delegate: AnyObject? = NSApplication.shared.delegate
        #endif

        // Left un-grafted rather than half done: the flag stays clear, so the next
        // instance to start tries again.
        guard let delegateClass = delegate.map({ type(of: $0) }) else { return }

        // One acquisition for the test and the set. Two would let a second caller
        // graft on top of the first, which chains rather than recursing but does
        // send the token twice.
        lock.lock()
        let alreadyDone = hasGraftedApplicationDelegate
        hasGraftedApplicationDelegate = true
        lock.unlock()

        guard !alreadyDone else { return }

        graft(selector: NSSelectorFromString("application:didRegisterForRemoteNotificationsWithDeviceToken:"),
              onto: delegateClass) { [weak self] argument in
            guard let data = argument as? Data else { return }
            self?.didRegisterForRemoteNotifications(deviceToken: data)
        }

        graft(selector: NSSelectorFromString("application:didFailToRegisterForRemoteNotificationsWithError:"),
              onto: delegateClass) { [weak self] _ in
            self?.didFailToRegisterForRemoteNotifications()
        }
    }

    /// Replaces one two-argument delegate callback with a version that calls
    /// `handler` and then whatever was there before.
    ///
    /// Chaining by capturing the original implementation, rather than exchanging
    /// with a method of our own, keeps the host's implementation reachable even
    /// when it is inherited from a superclass.
    private func graft(selector: Selector,
                       onto delegateClass: AnyClass,
                       handler: @escaping (Any) -> Void) {
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void

        let existing = class_getInstanceMethod(delegateClass, selector)
        let originalIMP = existing.map { method_getImplementation($0) }

        // Void return, object receiver, selector, two object arguments. Only used
        // when the host has no implementation of its own to copy the encoding from.
        let encoding = existing
            .flatMap { method_getTypeEncoding($0) }
            .map { String(cString: $0) } ?? "v@:@@"

        let replacement: @convention(block) (AnyObject, AnyObject, AnyObject) -> Void = { receiver, application, argument in
            handler(argument)

            guard let originalIMP else { return }
            let original = unsafeBitCast(originalIMP, to: Original.self)
            original(receiver, selector, application, argument)
        }

        let newIMP = imp_implementationWithBlock(replacement)
        _ = encoding.withCString { class_replaceMethod(delegateClass, selector, newIMP, $0) }
    }

    // MARK: - Notification centre delegate

    /// Makes the SDK the notification centre delegate, chaining to whatever is
    /// there.
    ///
    /// Re-asserted on every registration rather than latched on the first, because
    /// the delegate is a single slot the host can take back at any time: a SwiftUI
    /// application that starts the SDK in `init()` and assigns its own delegate
    /// from a view's `task` a moment later would otherwise evict the SDK silently
    /// and permanently, and every later notification tap would record nothing.
    /// Whoever is found in the slot becomes the one that gets chained to.
    func assertNotificationCenterDelegate() {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        let existing = center.delegate

        guard !(existing === self) else { return }

        lock.lock()
        if let existing { previousNotificationDelegate = existing }
        hasInstalledNotificationDelegate = true
        lock.unlock()

        center.delegate = self
        #endif
    }

    /// Restores the previous delegate, if this one is still installed.
    private func uninstallNotificationCenterDelegate() {
        #if canImport(UserNotifications)
        // Re-checked rather than trusting the caller: an instance can register
        // between the last one deregistering and this running, and handing the slot
        // back underneath it would leave it permanently deaf.
        guard subscribers.isEmpty else { return }

        lock.lock()
        let wasInstalled = hasInstalledNotificationDelegate
        let previous = previousNotificationDelegate
        hasInstalledNotificationDelegate = false
        previousNotificationDelegate = nil
        lock.unlock()

        guard wasInstalled else { return }

        let center = UNUserNotificationCenter.current()
        if center.delegate === self {
            center.delegate = previous as? UNUserNotificationCenterDelegate
        }
        #endif
    }

    #if canImport(UserNotifications)
    /// The delegate that was installed before this one, if it is still alive.
    private var chainedDelegate: UNUserNotificationCenterDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return previousNotificationDelegate as? UNUserNotificationCenterDelegate
    }
    #endif

    // MARK: - Opening a URL

    /// Opens the URL a notification action carries.
    func openURL(_ urlString: String?) {
        guard let urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return }

        DispatchQueue.main.async {
            #if os(iOS) || os(visionOS)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            #elseif os(macOS)
            NSWorkspace.shared.open(url)
            #endif
        }
    }
}

#if canImport(UserNotifications)

extension PushRuntime: UNUserNotificationCenterDelegate {

    /// A notification arriving while the application is in the foreground.
    ///
    /// The SDK answers only for its own notifications, where
    /// `doNotShowAlertForNotifications` is the setting that decides, and suppresses
    /// only when every registered instance asked for it: a suppression is one
    /// integration's request, and honouring it would silently hide another
    /// integration's notifications too. Everything else is the host application's
    /// business and goes straight to whichever delegate was there before.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let isCountlyNotification = countlyPayload(in: notification.request.content.userInfo) != nil

        guard isCountlyNotification else {
            forward(to: chainedDelegate, center: center, willPresent: notification, completionHandler: completionHandler)
            return
        }

        let modules = subscribers.current()
        let suppressed = !modules.isEmpty && modules.allSatisfy(\.suppressesForegroundAlert)

        guard !suppressed else {
            completionHandler([])
            return
        }

        if #available(iOS 14.0, macOS 11.0, visionOS 1.0, *) {
            completionHandler([.list, .banner])
        } else {
            completionHandler([.alert])
        }
    }

    private func forward(to delegate: UNUserNotificationCenterDelegate?,
                         center: UNUserNotificationCenter,
                         willPresent notification: UNNotification,
                         completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let delegate,
              delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))) else {
            completionHandler([])
            return
        }
        delegate.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler)
    }

    /// The user tapped the notification body or one of its action buttons.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        handle(response: response)

        if let chained = chainedDelegate,
           chained.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))) {
            chained.userNotificationCenter?(center, didReceive: response, withCompletionHandler: completionHandler)
        } else {
            completionHandler()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                openSettingsFor notification: UNNotification?) {
        guard let chained = chainedDelegate,
              chained.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:))) else { return }
        chained.userNotificationCenter?(center, openSettingsFor: notification)
    }

    /// Records the action on every registered instance and opens the attached URL.
    ///
    /// The URL is opened once even when several instances are registered: the
    /// action is one user gesture, and opening the same URL twice would put two
    /// copies of a web page in front of them.
    private func handle(response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        guard let payload = countlyPayload(in: userInfo) else { return }

        var buttonIndex = 0
        var url = payload[CountlyPushKey.defaultURL] as? String

        // An identifier the SDK did not register is still a user acting on a Countly
        // notification, so it is reported as a body tap rather than dropped. It
        // reaches here when another SDK's category is attached to a notification
        // carrying a Countly payload.
        if response.actionIdentifier.hasPrefix(CountlyPushKey.actionIdentifierPrefix) {
            let suffix = response.actionIdentifier.dropFirst(CountlyPushKey.actionIdentifierPrefix.count)
            if let index = Int(suffix), index > 0 {
                buttonIndex = index
                let buttons = payload[CountlyPushKey.buttons] as? [[String: Any]] ?? []
                url = index <= buttons.count ? buttons[index - 1][CountlyPushKey.actionButtonURL] as? String : nil
            }
        }

        for module in subscribers.current() {
            module.recordAction(for: userInfo, clickedButtonIndex: buttonIndex)
        }

        // Consent gates the URL as well as the event. Opening it is SDK initiated
        // behavior on a user who declined push, and the reference wraps both in the
        // same check.
        guard hasAnyPushConsent else { return }

        openURL(url)
    }

    private func countlyPayload(in userInfo: [AnyHashable: Any]) -> [String: Any]? {
        guard let payload = userInfo[CountlyPushKey.countlyPayload] as? [String: Any],
              let notificationID = payload[CountlyPushKey.notificationID] as? String,
              !notificationID.isEmpty else { return nil }
        return payload
    }
}

#endif

#endif
