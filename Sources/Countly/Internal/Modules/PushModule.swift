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
        guard core.config.features.contains(.pushNotifications) else {
            logD("applyInitialConfig", "push is not in the config feature list, this module will stay inactive whatever consent says")
            return
        }

        logD("applyInitialConfig", "push module starting, disableAutomaticPushHandling: [\(core.config.disableAutomaticPushHandling)], sendPushTokenAlways: [\(core.config.sendPushTokenAlways)], doNotShowAlertForNotifications: [\(core.config.doNotShowAlertForNotifications)], pushTestMode: [\(core.config.pushTestMode?.wireValue ?? 0)]")

        isEnabledOnInitialConfig = true
        startPushNotifications()
    }

    // MARK: - Registration

    /// Registers for remote notifications and starts observing the token.
    func startPushNotifications() {
        logI("startPushNotifications", "push notifications registration requested, enabledOnInitialConfig: [\(isEnabledOnInitialConfig)]")

        guard isEnabledOnInitialConfig else {
            logD("startPushNotifications", "push registration is skipped, push was not switched on in the initial config")
            return
        }

        guard core.modules.consent.hasConsent(for: .pushNotifications) else {
            logV("startPushNotifications", "no push consent given, remote notification registration is skipped")
            return
        }

        guard !isRegistered else {
            logD("startPushNotifications", "push registration is skipped, this instance is already registered for the process wide token")
            return
        }
        isRegistered = true

        #if os(iOS) || os(visionOS) || os(macOS)
        let automatic = !core.config.disableAutomaticPushHandling
        if automatic {
            logI("startPushNotifications", "automatic push handling is on, the SDK claims the notification centre delegate and the remote notification registration callbacks")
        } else {
            logI("startPushNotifications", "automatic push handling is disabled, the host application has to forward the device token and notification actions itself")
        }
        PushRuntime.shared.register(self, automaticHandling: automatic)

        #if os(macOS)
        if automatic, let launchInfo = core.config.launchNotification {
            logD("startPushNotifications", "a launch notification was supplied in config, the click that cold started the app is replayed")
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

        guard isEnabledOnInitialConfig, isRegistered else {
            logD("stopPushNotifications", "push unregistration is a no-op, enabledOnInitialConfig: [\(isEnabledOnInitialConfig)], isRegistered: [\(isRegistered)]")
            return
        }
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

        logD("askForNotificationPermission", "asking the system for notification authorization, resolvedOptions: [\(resolved.rawValue)], defaultsUsed: [\(options == 0)]")

        UNUserNotificationCenter.current().requestAuthorization(options: resolved) { [weak self] granted, error in
            // The user's answer is reported even once a halt has released the module.
            guard let self else {
                completion?(granted, error)
                return
            }

            if let error {
                self.logE("askForNotificationPermission", "notification permission request returned an error, granted: [\(granted)], error: [\(error.localizedDescription)]")
            } else {
                self.logI("askForNotificationPermission", "notification permission result received, granted: [\(granted)]")
            }

            completion?(granted, error)
            self.sendToken()
        }
        #else
        logD("askForNotificationPermission", "this platform has no user notification support, the completion is answered with a refusal")
        completion?(false, nil)
        #endif
    }

    // MARK: - Token

    /// Called by the runtime when the process receives a token.
    func didReceive(_ token: PushDeviceToken) {
        switch token {
        case .value(let value):
            logI("didReceive", "a device token arrived from the process wide push runtime, tokenLength: [\(value.count)]")
            logV("didReceive", "device token detail, token: [\(value)]")
        case .failed:
            logI("didReceive", "remote notification registration failed for this process, no device token will be available")
        }

        sendToken(token)
    }

    /// Reports the current token, if the permission state warrants it.
    func sendToken(_ overrideToken: PushDeviceToken? = nil) {
        logI("sendToken", "push token reporting requested, tokenSuppliedByCaller: [\(overrideToken != nil)]")

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
        logD("send", "push token request is being queued, tokenLength: [\(token.count)], pushTestMode: [\(testMode)]")
        logV("send", "push token request detail, token: [\(token)]")

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

        logD("recordAction", "the tapped notification was resolved, countlyPayloadPresent: [\(countlyPayload != nil)], notificationIDPresent: [\(!(notificationID ?? "").isEmpty)], payloadKeyCount: [\(countlyPayload?.count ?? 0)]")
        logV("recordAction", "tapped notification payload detail, userInfo: [\(userInfo)]")

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
        guard isRegistered, !core.config.disableAutomaticPushHandling else {
            logD("didEnterForeground", "the notification centre delegate is not re-asserted, isRegistered: [\(isRegistered)], disableAutomaticPushHandling: [\(core.config.disableAutomaticPushHandling)]")
            return
        }

        logD("didEnterForeground", "re-asserting the notification centre delegate in case the host application took the slot")
        PushRuntime.shared.assertNotificationCenterDelegate()
        #endif
    }

    override func halt(clearStorage: Bool) {
        // The system keeps delivering notifications after this: only the reporting
        // stops, so a log line here is the only trace of why they stopped landing.
        logD("halt", "push module halting, this instance stops reporting notifications while the process stays registered with the system")
        stopPushNotifications()
        isEnabledOnInitialConfig = false
    }
}
