//
//  PushModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS))
import UserNotifications
#endif
/// Registers for push notifications, reports the token, and records what the user
/// did with a notification.
///
/// The device token belongs to the process, not to a Countly instance, so it is
/// received once and handed to whichever instances want it. Reporting it is per
/// instance, because each has its own app key and server.
final class PushModule: ModuleBase {

    override class var moduleName: String { "Push" }

    /// Platform value reported with a push action.
    private static var platformValue: String {
        #if os(iOS) || os(visionOS)
        return "i"
        #elseif os(macOS)
        return "m"
        #else
        return "unknown"
        #endif
    }

    /// Whether push was switched on in the config. Without it the module does
    /// nothing, whatever consent says.
    private var isEnabledOnInitialConfig = false

    /// Whether this instance registered for the process-wide token.
    private var isRegistered = false

    // MARK: - Init

    func applyInitialConfig() {
        guard core.config.features.contains(.pushNotifications) else { return }
        isEnabledOnInitialConfig = true
        startPushNotifications()
    }

    // MARK: - Registration

    /// Registers for remote notifications and starts observing the token.
    func startPushNotifications() {
        logI("startPushNotifications", "push notifications registration requested, enabledOnInitialConfig: [\(isEnabledOnInitialConfig)]")

        guard isEnabledOnInitialConfig else { return }

        guard core.modules.consent.hasConsent(for: .pushNotifications) else {
            logV("startPushNotifications", "no push consent given, remote notification registration is skipped")
            return
        }

        guard !isRegistered else { return }
        isRegistered = true

        #if os(iOS) || os(visionOS) || os(macOS)
        let automatic = !core.config.disableAutomaticPushHandling
        if !automatic {
            logI("startPushNotifications", "automatic push handling is disabled, the host application has to forward the device token and notification actions itself")
        }
        PushRuntime.shared.register(self, automaticHandling: automatic)

        #if os(macOS)
        if automatic, let launchInfo = core.config.launchNotification {
            PushRuntime.shared.replayLaunchNotification(launchInfo)
        }
        #endif
        #endif
    }

    /// Whether this instance asked for foreground notifications not to be shown.
    var suppressesForegroundAlert: Bool {
        core.config.doNotShowAlertForNotifications
    }

    /// Whether this instance may act on a notification at all.
    var hasPushConsent: Bool {
        core.modules.consent.hasConsent(for: .pushNotifications)
    }

    /// Stops observing the token.
    ///
    /// Deliberately does not call `unregisterForRemoteNotifications`, unlike the
    /// reference: APNs registration belongs to the process, and one instance
    /// halting must not stop the others, or the host application, from receiving
    /// anything. The consequence is that after `halt()` the system keeps delivering
    /// notifications; this instance simply stops reporting them.
    func stopPushNotifications() {
        logI("stopPushNotifications", "push notifications unregistration requested, enabledOnInitialConfig: [\(isEnabledOnInitialConfig)]")

        guard isEnabledOnInitialConfig, isRegistered else { return }
        isRegistered = false

        #if os(iOS) || os(visionOS) || os(macOS)
        PushRuntime.shared.deregister(self)
        #endif
    }

    /// Asks the user for permission and reports the token afterwards.
    func askForNotificationPermission(options: UInt = 0, completion: ((Bool, Error?) -> Void)? = nil) {
        logI("askForNotificationPermission", "notification permission requested, options: [\(options)], completionHandlerProvided: [\(completion != nil)]")

        guard core.modules.consent.hasConsent(for: .pushNotifications) else {
            logV("askForNotificationPermission", "no push consent given, notification permission is not requested")
            // Answered rather than dropped. The reference returns silently here,
            // which in Swift leaks the continuation of any caller that wrapped this
            // in `withCheckedContinuation` and hangs that task for good.
            completion?(false, nil)
            return
        }

        #if canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS))
        let resolved: UNAuthorizationOptions = options == 0
            ? [.badge, .sound, .alert]
            : UNAuthorizationOptions(rawValue: options)

        UNUserNotificationCenter.current().requestAuthorization(options: resolved) { [weak self] granted, error in
            guard let self else { return }

            if let error {
                self.logE("askForNotificationPermission", "notification permission request returned an error, granted: [\(granted)], error: [\(error.localizedDescription)]")
            } else {
                self.logI("askForNotificationPermission", "notification permission result received, granted: [\(granted)]")
            }

            completion?(granted, error)
            self.sendToken()
        }
        #else
        completion?(false, nil)
        #endif
    }

    // MARK: - Token

    /// Called by the runtime when the process receives a token.
    func didReceive(_ token: PushDeviceToken) {
        sendToken(token)
    }

    /// Reports the current token, if the permission state warrants it.
    func sendToken(_ overrideToken: PushDeviceToken? = nil) {
        guard core.modules.consent.hasConsent(for: .pushNotifications) else {
            logV("sendToken", "no push consent given, push token is not sent")
            return
        }

        #if os(iOS) || os(visionOS) || os(macOS)
        guard let received = overrideToken ?? PushRuntime.shared.currentToken else {
            logD("sendToken", "push token is not sent, no token has been received yet")
            return
        }

        // Registration failed. An empty token tells the server to stop trying to
        // reach this device, which is more useful than silence.
        guard case .value(let token) = received else {
            logD("sendToken", "push token is in error state, an empty token will be sent to the server instead")
            clearToken()
            return
        }

        // The host application asked for the token whatever the permission state,
        // so the server can hold it until permission arrives.
        if core.config.sendPushTokenAlways {
            logI("sendToken", "push token is being sent without checking the permission state, tokenLength: [\(token.count)]")
            send(token: token)
            return
        }

        let hadPermissionBefore = core.keyValueStore.notificationPermission

        #if canImport(UserNotifications)
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }

            let isProvisional = settings.authorizationStatus == .provisional

            if settings.authorizationStatus == .authorized || isProvisional {
                self.logI("sendToken", "notification permission is granted, push token is being sent, tokenLength: [\(token.count)], provisional: [\(isProvisional)]")
                self.send(token: token)
                self.core.keyValueStore.notificationPermission = true
            } else if hadPermissionBefore {
                // Permission was taken away. Clearing the token stops the server
                // sending to a device that can no longer show anything.
                self.logI("sendToken", "notification permission has been revoked, the stored push token is being cleared")
                self.clearToken()
                self.core.keyValueStore.notificationPermission = false
            } else {
                self.logD("sendToken", "notification permission is not granted and was not granted before, push token is not sent")
            }
        }
        #endif
        #endif
    }

    /// Tells the server this device has no usable token.
    func clearToken() {
        logD("clearToken", "clearing the push token on the server by sending an empty token")
        send(token: "")
    }

    private func send(token: String) {
        let testMode = core.config.pushTestMode?.wireValue ?? 0
        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.pushTokenSession)=1"
        queryString += "&\(QS.pushTokeniOS)=\(token)"
        queryString += "&\(QS.pushTestMode)=\(testMode)"

        core.network.enqueueAndProceed(queryString)
    }

    // MARK: - Actions

    /// Records that the user acted on a notification.
    ///
    /// - Parameter buttonIndex: `0` for the notification body, `1` and up for its
    ///   action buttons.
    func recordAction(for userInfo: [AnyHashable: Any], clickedButtonIndex buttonIndex: Int) {
        logI("recordAction", "notification action recording requested, buttonIndex: [\(buttonIndex)]")

        guard core.modules.consent.hasConsent(for: .pushNotifications) else {
            logV("recordAction", "no push consent given, notification action is not recorded")
            return
        }

        let countlyPayload = userInfo[CountlyPushKey.countlyPayload] as? [String: Any]
        let notificationID = countlyPayload?[CountlyPushKey.notificationID] as? String

        recordActionEvent(notificationID: notificationID, buttonIndex: buttonIndex)
    }

    private func recordActionEvent(notificationID: String?, buttonIndex: Int) {
        // An empty ID is as unusable as a missing one: the event would reach the
        // dashboard as a click nothing can be attributed to. The automatic path
        // and the notification service extension both refuse it, and this is the
        // manual entry point onto the same event, so it refuses it too.
        guard let notificationID, !notificationID.isEmpty else {
            logW("recordActionEvent", "notification action event is dropped, the notification has no Countly notification ID")
            return
        }

        logD("recordActionEvent", "notification action taken, notificationID: [\(notificationID)], buttonIndex: [\(buttonIndex)]")

        let segmentation: [String: Any] = [
            CountlyPushKey.notificationID: notificationID,
            CountlyPushKey.actionButtonIndex: buttonIndex,
            CountlyPushKey.platform: Self.platformValue,
        ]

        core.modules.events.recordReservedEvent(ReservedEventKey.pushAction, segmentation: segmentation)
    }

    // MARK: - Lifecycle

    override func didEnterForeground() {
        #if os(iOS) || os(visionOS) || os(macOS)
        // The host may have taken the delegate slot since the last check. Re-asserting
        // here rather than only at registration keeps a notification tap reportable
        // for an integration that installs its own delegate after the SDK starts.
        guard isRegistered, !core.config.disableAutomaticPushHandling else { return }
        PushRuntime.shared.assertNotificationCenterDelegate()
        #endif
    }

    override func halt(clearStorage: Bool) {
        stopPushNotifications()
        isEnabledOnInitialConfig = false
    }
}
