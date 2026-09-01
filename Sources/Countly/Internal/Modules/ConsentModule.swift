//
//  ConsentModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Decides what the SDK is allowed to collect.
///
/// When `requiresConsent` is off every feature reports itself as consented, which
/// is what makes an integration that does not care about consent work unchanged.
/// When it is on nothing is collected until the host application says so, and
/// every change is reported to the server as a full snapshot of the state.
final class ConsentModule: ModuleBase {

    override class var moduleName: String { "Consent" }

    /// Whether consent gates anything at all. Can be turned on by behavior
    /// settings after init, never off.
    ///
    /// Logged on every change: behavior settings can turn this on for an
    /// integration that never asked for it, and from then on every feature is
    /// gated. That is the first thing to check when a feature collects nothing.
    var requiresConsent: Bool = false {
        didSet {
            guard requiresConsent != oldValue else { return }
            logI("requiresConsent", "consent requirement changed, requiresConsent: [\(requiresConsent)], grantedFeatureCount: [\(granted.count)]")
        }
    }

    /// Raw per-feature state. Only meaningful while `requiresConsent` is on.
    private var granted: Set<ConsentFeature> = []

    /// The order consent is granted in.
    ///
    /// Location comes first deliberately: a `begin_session` produced before
    /// location consent is granted carries an empty `location=`, which tells the
    /// server to stop inferring location and cannot be undone for that session.
    private static let grantOrder: [ConsentFeature] = [
        .location, .userDetails, .sessions, .events, .crashReporting,
        .pushNotifications, .viewTracking, .attribution, .performanceMonitoring,
        .feedback, .remoteConfig, .content, .metrics,
    ]

    /// The order consent is withdrawn in. Sessions first, so the session in flight
    /// is closed while there is still consent to report it.
    private static let revokeOrder: [ConsentFeature] = [
        .sessions, .events, .userDetails, .crashReporting, .pushNotifications,
        .location, .viewTracking, .attribution, .performanceMonitoring,
        .feedback, .remoteConfig, .content, .metrics,
    ]

    /// Feature names in a stable order, so a before and after state can be
    /// compared by eye in the log.
    private static func describe<S: Sequence>(_ features: S) -> String where S.Element == ConsentFeature {
        features.map(\.wireName).sorted().joined(separator: ", ")
    }

    // MARK: - Queries

    /// Whether the SDK may act on a feature right now.
    func hasConsent(for feature: ConsentFeature) -> Bool {
        guard requiresConsent else { return true }
        return granted.contains(feature)
    }

    /// Whether anything at all is consented to, which is the gate on requests that
    /// do not belong to one feature.
    var hasAnyConsent: Bool {
        guard requiresConsent else { return true }
        return !granted.isEmpty
    }

    // MARK: - Mutation

    /// Grants consent for every feature.
    func giveAllConsents() {
        logI("giveAllConsents", "consent is given for every feature, featureCount: [\(ConsentFeature.allCases.count)]")
        giveConsent(for: ConsentFeature.allCases)
    }

    /// Grants consent for the named features and reports the new state.
    func giveConsent(for features: [ConsentFeature]) {
        logI("giveConsent", "giving consent for features, featureCount: [\(features.count)], features: [\(Self.describe(features))]")

        guard requiresConsent else {
            logD("giveConsent", "consent is not required by the configuration, giving consent for features will be ignored")
            return
        }

        guard !features.isEmpty else {
            logE("giveConsent", "feature list is empty, there is no consent to give")
            return
        }

        let stateBeforeChange = Self.describe(granted)
        let requested = Set(features)
        for feature in Self.grantOrder where requested.contains(feature) && !granted.contains(feature) {
            granted.insert(feature)
            applySideEffect(of: feature, granted: true)
        }

        logD("giveConsent", "consent state after giving consent, grantedBefore: [\(stateBeforeChange)], grantedAfter: [\(Self.describe(granted))]")

        sendConsents()
    }

    /// Withdraws consent for every feature.
    func cancelAllConsents() {
        logI("cancelAllConsents", "consent is cancelled for every feature, featureCount: [\(ConsentFeature.allCases.count)]")
        cancelConsent(for: ConsentFeature.allCases)
    }

    /// Withdraws consent for every feature without telling the server.
    ///
    /// Used when the device ID changes without merge: the new user starts with no
    /// consent, and a consent request for the old user would be misattributed.
    func cancelAllConsentsWithoutSending() {
        logI("cancelAllConsentsWithoutSending", "consent is cancelled for every feature without informing the server, featureCount: [\(ConsentFeature.allCases.count)]")
        cancelConsent(for: ConsentFeature.allCases, skipSendingRequest: true)
    }

    /// Withdraws consent for the named features and reports the new state.
    func cancelConsent(for features: [ConsentFeature], skipSendingRequest: Bool = false) {
        logI("cancelConsent", "cancelling consent for features, featureCount: [\(features.count)], features: [\(Self.describe(features))], skipSendingConsentsRequest: [\(skipSendingRequest)]")

        guard requiresConsent else {
            logD("cancelConsent", "consent is not required by the configuration, cancelling consent for features will be ignored")
            return
        }

        let stateBeforeChange = Self.describe(granted)
        let requested = Set(features)
        for feature in Self.revokeOrder where requested.contains(feature) && granted.contains(feature) {
            // The side effect runs before the flag is cleared for sessions, so the
            // end-session request still passes its own consent check.
            if feature == .sessions {
                applySideEffect(of: feature, granted: false)
                granted.remove(feature)
            } else {
                granted.remove(feature)
                applySideEffect(of: feature, granted: false)
            }
        }

        logD("cancelConsent", "consent state after cancelling consent, grantedBefore: [\(stateBeforeChange)], grantedAfter: [\(Self.describe(granted))]")

        if !skipSendingRequest {
            sendConsents()
        }
    }

    /// Reports the full consent state to the server.
    ///
    /// A snapshot rather than a delta, so the server's view cannot drift out of
    /// sync with the device's after a dropped request.
    func sendConsents() {
        var payload: [String: Bool] = [:]
        for feature in ConsentFeature.allCases {
            payload[feature.wireName] = requiresConsent ? granted.contains(feature) : true
        }

        let sentAsGranted = payload.filter { $0.value }.keys.sorted().joined(separator: ", ")
        logD("sendConsents", "consents state will be sent to the server, requiresConsent: [\(requiresConsent)], featureCount: [\(payload.count)], grantedInRequest: [\(sentAsGranted)]")

        let queryString = "\(core.network.builder.queryEssentials())&\(QS.consent)=\(CountlyJSON.escapedString(from: payload, logger: log))"
        core.network.enqueueAndProceed(queryString)
    }

    // MARK: - Side effects

    /// Starts or stops whatever the feature owns.
    ///
    /// Kept in one place so the granting and withdrawing paths cannot drift apart,
    /// which is how a feature ends up running without consent.
    private func applySideEffect(of feature: ConsentFeature, granted isGranted: Bool) {
        let modules = core.modules

        switch feature {
        case .sessions:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], a begin session is requested only with automatic session tracking, automaticSessionTrackingEnabled: [\(core.serverConfig.automaticSessionTrackingEnabled)]")
                if core.serverConfig.automaticSessionTrackingEnabled {
                    modules?.sessions.beginSession()
                }
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], session tracking will no longer be performed")
                modules?.sessions.endSession()
            }

        case .events:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], custom events will be recorded")
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], recorded events will be sent and timed events will be cleared")
                modules?.events.sendEventsWithSaveIfNeeded()
                modules?.events.clearAllTimedEvents()
            }

        case .userDetails:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], orientation will be recorded and user details will be saved")
                modules?.views.recordOrientation()
                modules?.userProfile.save()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], stored user details will be cleared")
                modules?.userProfile.clearUserDetails()
            }

        case .crashReporting:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], crash reporting will be started")
                modules?.crashes.startCrashReporting()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], crash reporting will be stopped")
                modules?.crashes.stopCrashReporting()
            }

        case .pushNotifications:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], push notifications will be started")
                modules?.push.startPushNotifications()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], push notifications will be stopped")
                modules?.push.stopPushNotifications()
            }

        case .location:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], location info will be sent")
                modules?.location.sendLocationInfo()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], location info will be cleared on the server")
                // Unconditional: this sends the empty location that stops the
                // server inferring one, and the consent it would be gated on has
                // just been withdrawn.
                modules?.location.sendLocationRequest()
            }

        case .viewTracking:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], automatic view tracking will be started")
                modules?.views.startAutoViewTracking()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], automatic view tracking will be stopped")
                modules?.views.stopAutoViewTracking()
            }

        case .attribution:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], attribution will be sent")
                modules?.attribution.sendIndirectAttributionIfAvailable()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], attribution will no longer be sent")
            }

        case .performanceMonitoring:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], performance monitoring will be started")
                modules?.apm.startPerformanceMonitoring()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], performance monitoring will be stopped")
                modules?.apm.stopPerformanceMonitoring()
            }

        case .feedback:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], feedback widgets can now be requested and shown")
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], feedback widgets will no longer be shown")
            }

        case .remoteConfig:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], automatic remote config download will be triggered")
                modules?.remoteConfig.downloadRemoteConfigAutomatically()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], remote config values will no longer be downloaded")
            }

        case .content:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], content zone can be entered")
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], content zone will be exited")
                modules?.content.exitContentZone()
            }

        case .metrics:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], metrics will be included in requests")
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], metrics will be omitted from requests")
            }
        }
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        logD("halt", "consent module is halted, granted consents will be cleared, grantedFeatureCount: [\(granted.count)]")
        granted.removeAll()
    }
}
