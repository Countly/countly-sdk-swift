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

    /// Platform value reported with a push action: "i" for APNs on every Apple
    /// platform, the only key the server counts an Apple message under.
    private static let platformValue = "i"

    /// Whether push was switched on in the config. Without it the module does
    /// nothing, whatever consent says.
    private var isEnabledOnInitialConfig = false

    /// Whether this instance registered for the process-wide token.
    private var isRegistered = false

    /// Whether the click that cold started the application was replayed. Push
    /// starts again whenever its consent is given again, the replay only once.
    private var hasReplayedLaunchNotification = false

    // MARK: - Init

    func applyInitialConfig() {
        guard core.config.features.contains(.pushNotifications) else {
            logD("applyInitialConfig", "push is not in the config feature list, this module will stay inactive whatever consent says")
            return
        }

        // The token and the notification taps belong to the process, so one instance reports them, not every server.
        guard isDefaultInstance else {
            logW("applyInitialConfig", "push notifications are handled by the default instance only, this named instance will not register for them")
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
        if automatic, !hasReplayedLaunchNotification, let launchInfo = core.config.launchNotification {
            logD("startPushNotifications", "a launch notification was supplied in config, the click that cold started the app is replayed")
            hasReplayedLaunchNotification = true
            PushRuntime.shared.replayLaunchNotification(launchInfo)
        }
        #endif
        #endif
    }

    /// Whether this is the default instance, the only one that handles push.
    private var isDefaultInstance: Bool {
        core.namespace.isDefault
    }

    /// Sends the token again after a device ID change without merge. The server
    /// keeps a token on the user that sent it last, so this moves it to the new
    /// user; without it the previous user's pushes would still reach this device.
    func deviceIDChangedWithoutMerge() {
        guard isEnabledOnInitialConfig, isRegistered else { return }
        logD("deviceIDChangedWithoutMerge", "the device ID changed without merge, the push token is sent again for the new user")
        sendToken()
    }

    /// Sends the token again after the server URL or the app key changed: the
    /// new server or app does not have it.
    func connectionChanged() {
        guard isEnabledOnInitialConfig, isRegistered else { return }
        logD("connectionChanged", "the server URL or the app key changed, the push token is sent again")
        sendToken()
    }

    /// Takes the token back from the user whose device ID is in use now, before a
    /// device ID change without merge replaces it, so the leaving user's pushes stop
    /// reaching this device. Sent only when a token was sent for that device ID.
    func clearTokenForLeavingUser() {
        let deviceID = core.modules.deviceID.deviceID
        clearTokenForLeavingUser(deviceID: deviceID, typeValue: core.modules.deviceID.deviceIDType.wireValue)
    }

    /// Takes the token back from the user with `deviceID`, the stored device ID a
    /// reset at init is about to clear, when a token was sent for that device ID.
    func clearTokenForLeavingUser(deviceID: String, typeValue: Int) {
        guard isDefaultInstance, !deviceID.isEmpty, core.keyValueStore.pushTokenDeviceID == deviceID else {
            logD("clearTokenForLeavingUser", "no push token was sent for the leaving device ID, nothing is cleared")
            return
        }
        logD("clearTokenForLeavingUser", "the push token sent for the leaving device ID is cleared under that device ID")
        send(token: "", essentials: core.network.builder.queryEssentials(deviceID: deviceID, typeValue: typeValue))
        core.keyValueStore.pushTokenDeviceID = nil
    }

    /// Follows a device ID change with merge: the server moves the token to the
    /// new device ID with the rest of the profile, so nothing is sent and the
    /// record of whom it was sent for moves along.
    func deviceIDMerged(from oldDeviceID: String, into newDeviceID: String) {
        guard core.keyValueStore.pushTokenDeviceID == oldDeviceID else { return }
        core.keyValueStore.pushTokenDeviceID = newDeviceID
    }

    /// Follows the end of temporary device ID mode: a token queued under the
    /// placeholder was rewritten to the real device ID like every queued request,
    /// and the token is sent for the device ID now in use.
    func temporaryDeviceIDReplaced(by deviceID: String) {
        if core.keyValueStore.pushTokenDeviceID == TemporaryDeviceID.value {
            core.keyValueStore.pushTokenDeviceID = deviceID
        }
        guard isEnabledOnInitialConfig, isRegistered else { return }
        logD("temporaryDeviceIDReplaced", "temporary device ID mode ended, the push token is sent for the device ID now in use")
        sendToken()
    }

    /// Reacts to the removal of push consent: Countly notifications stop being
    /// handled and, unless the removal is the silent one of a device ID change
    /// without merge, an empty token takes the token away from the user on the
    /// server, which since 26.01 keeps it through a consent change.
    ///
    /// - Parameter silently: whether the removal comes from a device ID change
    ///   without merge, which already cleared the token under the old device ID.
    func consentRemoved(silently: Bool) {
        let hadToken = core.keyValueStore.pushTokenDeviceID != nil
        stopPushNotifications()
        guard !silently, isDefaultInstance, isEnabledOnInitialConfig || hadToken else { return }
        logD("consentRemoved", "push consent was removed, the push token is cleared on the server")
        clearToken()
    }

    /// Whether this instance asked for foreground notifications not to be shown.
    var suppressesForegroundAlert: Bool {
        core.config.doNotShowAlertForNotifications
    }

    /// The application's handler for the link of a tapped notification.
    var actionHandler: PushActionHandler? {
        core.config.pushActionHandler
    }

    /// The schemes notification links may open, empty for every scheme but the
    /// dangerous ones.
    var allowedLinkSchemes: [String] {
        core.config.pushAllowedLinkSchemes
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

        guard isDefaultInstance else {
            logD("sendToken", "push token is not sent, push notifications are handled by the default instance only")
            return
        }

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
        guard isDefaultInstance else {
            logD("clearToken", "push token is not cleared, push notifications are handled by the default instance only")
            return
        }
        logD("clearToken", "clearing the push token on the server by sending an empty token")
        send(token: "")
    }

    /// Queues a token request for the device ID in use and records whom the token
    /// went to, so it can be taken back when that user leaves.
    private func send(token: String) {
        send(token: token, essentials: core.network.builder.queryEssentials())
        core.keyValueStore.pushTokenDeviceID = token.isEmpty ? nil : core.modules.deviceID.deviceID
    }

    /// Queues a token request with the given base parameters.
    private func send(token: String, essentials: String) {
        let testMode = core.config.pushTestMode?.wireValue ?? 0
        logD("send", "push token request is being queued, tokenLength: [\(token.count)], pushTestMode: [\(testMode)]")
        logV("send", "push token request detail, token: [\(token)]")

        var queryString = essentials
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

        guard isDefaultInstance else {
            logD("recordAction", "notification action is not recorded, push notifications are handled by the default instance only")
            return
        }

        let countlyPayload = userInfo[CountlyPushKey.countlyPayload] as? [String: Any]
        let notificationID = countlyPayload?[CountlyPushKey.notificationID] as? String

        logD("recordAction", "the tapped notification was resolved, countlyPayloadPresent: [\(countlyPayload != nil)], notificationIDPresent: [\(!(notificationID ?? "").isEmpty)], payloadKeyCount: [\(countlyPayload?.count ?? 0)]")
        logV("recordAction", "tapped notification payload detail, userInfo: [\(userInfo)]")

        recordActionEvent(notificationID: notificationID, buttonIndex: buttonIndex)
    }

    /// Records the taps that arrived before the SDK started, with the time they
    /// happened, when push consent is given now. Without it they are dropped.
    private func recordPendingTaps() {
        guard isDefaultInstance else { return }
        let taps = core.keyValueStore.pendingPushActions
        guard !taps.isEmpty else { return }
        core.keyValueStore.pendingPushActions = []

        guard core.modules.consent.hasConsent(for: .pushNotifications) else {
            logD("recordPendingTaps", "notification taps from before the start are dropped, push consent is not given, tapCount: [\(taps.count)]")
            return
        }

        logD("recordPendingTaps", "notification taps from before the start are recorded with the time they happened, tapCount: [\(taps.count)]")
        for tap in taps {
            recordActionEvent(notificationID: tap[PendingPushActionKey.notificationID] as? String,
                              buttonIndex: (tap[PendingPushActionKey.buttonIndex] as? NSNumber)?.intValue ?? 0,
                              timestamp: (tap[PendingPushActionKey.time] as? NSNumber)?.doubleValue)
        }
    }

    private func recordActionEvent(notificationID: String?, buttonIndex: Int, timestamp: TimeInterval? = nil) {
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

        core.modules.events.recordReservedEvent(ReservedEventKey.pushAction, segmentation: segmentation, timestamp: timestamp)
    }

    // MARK: - Lifecycle

    /// Once init is complete, so the consent given at its end applies.
    override func didInit() {
        recordPendingTaps()
    }

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
