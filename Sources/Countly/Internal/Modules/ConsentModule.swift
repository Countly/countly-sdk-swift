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

    /// Where a consent change comes from, which decides the reactions it runs.
    enum ChangeSource {
        /// The host application's call, or the server's consent requirement.
        case app
        /// A device ID change without merge. No consent request is sent, and the
        /// reactions that would send something are skipped: what the leaving user
        /// needed already went out under the old device ID.
        case deviceIDChangedWithoutMerge
    }

    /// Whether consent gates anything at all. Set at init from the configuration;
    /// a change the behavior settings make at runtime goes through
    /// `applyRequirementChange(to:)`, which runs the reactions of the change.
    ///
    /// Logged on every change: behavior settings can turn this on for an
    /// integration that never asked for it, and from then on every feature is
    /// gated. That is the first thing to check when a feature collects nothing.
    /// A change also re-decides which gathered log lines may be uploaded.
    var requiresConsent: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _requiresConsent
        }
        set {
            stateLock.lock()
            let oldValue = _requiresConsent
            _requiresConsent = newValue
            stateLock.unlock()

            guard newValue != oldValue else { return }
            logI("requiresConsent", "consent requirement changed, requiresConsent: [\(newValue)], grantedFeatureCount: [\(granted.count)]")
            core.logGatherer.consentDidChange()
        }
    }

    /// Raw per-feature state. Only meaningful while `requiresConsent` is on.
    private var granted: Set<ConsentFeature> {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _granted
        }
        set {
            stateLock.lock()
            _granted = newValue
            stateLock.unlock()
        }
    }

    /// Guards the consent state, which the log gatherer reads for every line it
    /// captures, on whichever thread logged it. Never held while logging.
    private let stateLock = NSLock()
    private var _requiresConsent = false
    private var _granted: Set<ConsentFeature> = []

    /// Named sets of features the host application created, see
    /// `createFeatureGroup(_:features:)`. Kept for the run only, like consent.
    private var featureGroups: [String: [ConsentFeature]] = [:]

    /// The order the reactions to a grant run in, once every flag of the grant is
    /// set. Sessions before user details, so the orientation a session begins with
    /// is not recorded a second time.
    private static let grantOrder: [ConsentFeature] = [
        .sessions, .userDetails, .location, .events, .crashReporting,
        .pushNotifications, .viewTracking, .attribution,
        .feedback, .remoteConfig, .content, .metrics, .starRating,
    ]

    /// The order consent is withdrawn in. The features that close while their
    /// consent still stands come first: pending profile changes are dropped, so
    /// the session's last flush cannot send them, then the views end inside the
    /// session, then the session ends.
    private static let revokeOrder: [ConsentFeature] = [
        .userDetails, .viewTracking, .sessions, .events, .crashReporting,
        .pushNotifications, .location, .attribution,
        .feedback, .remoteConfig, .content, .metrics, .starRating,
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

    /// Whether every feature of a group has consent. `false` for a group that was
    /// never created, with a warning.
    func hasConsent(forGroup groupName: String) -> Bool {
        guard let features = features(ofGroup: groupName, function: "hasConsentForGroup") else { return false }
        return features.allSatisfy { hasConsent(for: $0) }
    }

    /// Logs whether consent is required and the state of every feature. Changes
    /// nothing.
    func checkAllConsent() {
        let states = ConsentFeature.allCases
            .map { "\($0.wireName): [\(hasConsent(for: $0))]" }
            .joined(separator: ", ")
        logI("checkAllConsent", "consent state, requiresConsent: [\(requiresConsent)], \(states)")
    }

    // MARK: - Mutation

    /// Grants consent for every feature.
    func giveAllConsents() {
        logI("giveAllConsents", "consent is given for every feature, featureCount: [\(ConsentFeature.allCases.count)]")
        giveConsent(for: ConsentFeature.allCases)
    }

    /// Grants consent for the named features, reports the new state when anything
    /// changed, and releases the gathered log lines that waited for it.
    func giveConsent(for features: [ConsentFeature]) {
        logI("giveConsent", "giving consent for features, featureCount: [\(features.count)], features: [\(Self.describe(features))]")

        guard requiresConsent else {
            logD("giveConsent", "consent is not required by the configuration, giving consent for features will be ignored")
            return
        }

        guard !features.isEmpty else {
            logW("giveConsent", "the feature list is empty, there is no consent to give")
            core.healthTracker.recordLogCode(HealthLogCode.invalidConsentName)
            return
        }

        let stateBeforeChange = Self.describe(granted)
        let requested = Set(features)
        let newlyGranted = Self.grantOrder.filter { requested.contains($0) && !granted.contains($0) }

        guard !newlyGranted.isEmpty else {
            logD("giveConsent", "consent was already given for every requested feature, nothing changed and no consent request is sent, granted: [\(stateBeforeChange)]")
            return
        }

        grant(newlyGranted) { granted.formUnion(newlyGranted) }

        logD("giveConsent", "consent state after giving consent, grantedBefore: [\(stateBeforeChange)], grantedAfter: [\(Self.describe(granted))]")

        sendConsents()
        core.logGatherer.consentDidChange()
    }

    /// Withdraws consent for every feature.
    func cancelAllConsents() {
        logI("cancelAllConsents", "consent is cancelled for every feature, featureCount: [\(ConsentFeature.allCases.count)]")
        cancelConsent(for: ConsentFeature.allCases)
    }

    /// Withdraws consent for every feature before a device ID change without
    /// merge replaces the device ID, without telling the server. The new user
    /// starts with no consent, and the features run only the reactions that change
    /// state on the device.
    func removeAllConsentsForDeviceIDChange() {
        logI("removeAllConsentsForDeviceIDChange", "consent is removed for every feature without informing the server, the device ID changes without merge, featureCount: [\(ConsentFeature.allCases.count)]")
        guard requiresConsent else {
            // Lifted by the server for now: the new user still starts with none once it is back.
            granted = []
            return
        }
        cancelConsent(for: ConsentFeature.allCases, source: .deviceIDChangedWithoutMerge)
    }

    /// Withdraws consent for the named features, reports the new state when
    /// anything changed, and takes the gathered log lines of those features back
    /// out of the upload buffer.
    func cancelConsent(for features: [ConsentFeature], source: ChangeSource = .app) {
        logI("cancelConsent", "cancelling consent for features, featureCount: [\(features.count)], features: [\(Self.describe(features))], source: [\(source)]")

        guard requiresConsent else {
            logD("cancelConsent", "consent is not required by the configuration, cancelling consent for features will be ignored")
            return
        }

        guard !features.isEmpty else {
            logW("cancelConsent", "the feature list is empty, there is no consent to cancel")
            core.healthTracker.recordLogCode(HealthLogCode.invalidConsentName)
            return
        }

        let stateBeforeChange = Self.describe(granted)
        let requested = Set(features)
        let withdrawn = Self.revokeOrder.filter { requested.contains($0) && granted.contains($0) }

        guard !withdrawn.isEmpty else {
            logD("cancelConsent", "consent was not given for any requested feature, nothing changed and no consent request is sent, granted: [\(stateBeforeChange)]")
            return
        }

        withdraw(withdrawn, source: source) { granted.subtract(withdrawn) }

        logD("cancelConsent", "consent state after cancelling consent, grantedBefore: [\(stateBeforeChange)], grantedAfter: [\(Self.describe(granted))]")

        if source == .app {
            sendConsents()
        }
        core.logGatherer.consentDidChange()
    }

    /// Gives or removes consent for the named features.
    func setConsent(for features: [ConsentFeature], given: Bool) {
        if given {
            giveConsent(for: features)
        } else {
            cancelConsent(for: features)
        }
    }

    /// Stores a named set of features, so consent can be given or removed for all
    /// of them at once. A group created again with the same name is replaced.
    func createFeatureGroup(_ groupName: String, features: [ConsentFeature]) {
        guard !groupName.isEmpty else {
            logW("createFeatureGroup", "the group name is empty, the group is not created")
            core.healthTracker.recordLogCode(HealthLogCode.invalidConsentName)
            return
        }
        logD("createFeatureGroup", "a consent feature group is stored, groupName: [\(groupName)], features: [\(Self.describe(features))]")
        stateLock.lock()
        featureGroups[groupName] = features
        stateLock.unlock()
    }

    /// Gives or removes consent for every feature of a group.
    func setConsentFeatureGroup(_ groupName: String, given: Bool) {
        guard let features = features(ofGroup: groupName, function: "setConsentFeatureGroup") else { return }
        setConsent(for: features, given: given)
    }

    /// The features of a group, or `nil` with a warning when no group of that
    /// name was created.
    private func features(ofGroup groupName: String, function: String) -> [ConsentFeature]? {
        stateLock.lock()
        let features = featureGroups[groupName]
        stateLock.unlock()
        guard let features else {
            logW(function, "no consent feature group exists with this name, the call is ignored, groupName: [\(groupName)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidConsentName)
            return nil
        }
        return features
    }

    /// Applies a consent requirement the behavior settings changed while the SDK
    /// runs. Turning it on acts like removing consent for every feature that has
    /// none and sends the new state; lifting it acts like giving consent for every
    /// feature and sends nothing, as no consent request goes out while consent is
    /// not required.
    func applyRequirementChange(to required: Bool) {
        stateLock.lock()
        let wasRequired = _requiresConsent
        let grantedNow = _granted
        stateLock.unlock()

        guard wasRequired != required else { return }

        if required {
            let losing = Self.revokeOrder.filter { !grantedNow.contains($0) }
            logI("applyRequirementChange", "the server turned the consent requirement on, the features without consent stop, features: [\(Self.describe(losing))]")
            withdraw(losing, source: .app) { requiresConsent = true }
            sendConsents()
        } else {
            let gaining = Self.grantOrder.filter { !grantedNow.contains($0) }
            logI("applyRequirementChange", "the server lifted the consent requirement, every feature works as if consent were given, features: [\(Self.describe(gaining))]")
            grant(gaining) { requiresConsent = false }
        }
    }

    /// Makes `features` usable through `setFlags`, then runs their reactions in
    /// order. Every flag comes before any reaction, so a session begun by the
    /// grant carries the metrics and the location given with it.
    private func grant(_ features: [ConsentFeature], setFlags: () -> Void) {
        setFlags()
        for feature in features {
            applySideEffect(of: feature, granted: true, source: .app)
        }
        afterGranting(features)
    }

    /// Stops `features` around `clearFlags`: the closings in
    /// ``closesBeforeFlagClears`` run while the consent is still in place, since
    /// they are gated on it, and the other reactions after.
    private func withdraw(_ features: [ConsentFeature], source: ChangeSource, clearFlags: () -> Void) {
        for feature in features where Self.closesBeforeFlagClears.contains(feature) {
            applySideEffect(of: feature, granted: false, source: source)
        }
        clearFlags()
        for feature in features where !Self.closesBeforeFlagClears.contains(feature) {
            applySideEffect(of: feature, granted: false, source: source)
        }
    }

    /// Reactions that run after every other reaction of a grant, so after a
    /// session the same grant began. Location values are sent only then, so that
    /// session carries them rather than a second request.
    private func afterGranting(_ features: [ConsentFeature]) {
        if features.contains(.location) {
            logD("consentDidChange", "consent granted, feature: [\(ConsentFeature.location.wireName)], stored location values become usable")
            core.modules.location.consentGiven()
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

    /// Features whose withdrawal side effect runs before any flag of the
    /// withdrawal clears: what the views and the session close is itself gated on
    /// their consent, and the pending profile changes must be gone before the
    /// session's last flush.
    private static let closesBeforeFlagClears: Set<ConsentFeature> = [.userDetails, .viewTracking, .sessions]

    /// Starts or stops whatever the feature owns.
    ///
    /// Kept in one place so the granting and withdrawing paths cannot drift apart,
    /// which is how a feature ends up running without consent.
    private func applySideEffect(of feature: ConsentFeature, granted isGranted: Bool, source: ChangeSource) {
        let modules = core.modules
        let silently = source == .deviceIDChangedWithoutMerge

        switch feature {
        case .sessions:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], a begin session is requested only with automatic session tracking, automaticSessionTrackingEnabled: [\(core.serverConfig.automaticSessionTrackingEnabled)]")
                if core.serverConfig.automaticSessionTrackingEnabled {
                    modules?.sessions.beginSession(automatically: true)
                }
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], session tracking will no longer be performed")
                modules?.sessions.endSession(automatically: true)
            }

        case .events:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], custom events will be recorded")
            } else if silently {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], timed events will be cleared, the recorded events already went out under the previous device ID")
                modules?.events.clearAllTimedEvents()
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
                modules?.crashes.consentGiven()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], crash reporting will be stopped, breadcrumbs and the global crash segmentation are dropped")
                modules?.crashes.consentRemoved()
            }

        case .pushNotifications:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], push notifications will be started")
                modules?.push.startPushNotifications()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], push notifications will be stopped, emptyTokenSent: [\(!silently)]")
                modules?.push.consentRemoved(silently: silently)
            }

        case .location:
            // Granting runs after the other reactions of the grant, see `afterGranting`.
            if !isGranted {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], stored location values are cleared, eraseRequestSent: [\(!silently)]")
                modules?.location.consentRemoved(silently: silently)
            }

        case .viewTracking:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], automatic view tracking will be started")
                modules?.views.startAutoViewTracking()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], automatic view tracking and every open view will be stopped")
                modules?.views.stopAllViewsForConsentWithdrawal()
            }

        case .attribution:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], attribution will be sent")
                modules?.attribution.sendIndirectAttributionIfAvailable()
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], attribution will no longer be sent")
            }

        case .starRating:
            logD("consentDidChange", "consent changed, feature: [\(feature.wireName)], granted: [\(isGranted)], legacy rating results follow it")

        case .feedback:
            if isGranted {
                logD("consentDidChange", "consent granted, feature: [\(feature.wireName)], feedback widgets can now be requested and shown")
            } else {
                logD("consentDidChange", "consent cancelled, feature: [\(feature.wireName)], a feedback widget on screen will be closed without a closed event")
                modules?.feedback.consentRemoved()
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
        logD("halt", "consent module is halted, granted consents and feature groups will be cleared, grantedFeatureCount: [\(granted.count)]")
        granted.removeAll()
        stateLock.lock()
        featureGroups.removeAll()
        stateLock.unlock()
    }
}
