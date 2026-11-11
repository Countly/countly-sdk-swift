//
//  AttributionModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Reports where an install or a session came from.
///
/// Direct attribution carries a Countly campaign the user clicked. Indirect
/// attribution carries advertising identifiers the host application obtained
/// itself, which the SDK never collects on its own.
final class AttributionModule: ModuleBase {

    override class var moduleName: String { "Attribution" }

    /// Campaign type the server understands for direct attribution.
    private static let countlyCampaignType = "countly"

    /// Campaign type reserved for server-side integration tests, which sends the
    /// raw campaign data instead of parsing it.
    private static let testCampaignType = "_special_test"

    /// The advertising identifiers last supplied.
    ///
    /// Sent as a request of their own, not folded into `begin_session`. The
    /// reference rides them along on the session, but only for the deprecated
    /// `config.attributionID`, which this SDK does not have.
    private(set) var indirectAttribution: [String: String]?

    // MARK: - Init

    func applyInitialConfig() {
        logD("applyInitialConfig", "attribution module starting, directAttributionInConfig: [\(core.config.campaignType != nil && core.config.campaignData != nil)], indirectAttributionInConfig: [\(core.config.indirectAttribution != nil)]")

        if let type = core.config.campaignType, let data = core.config.campaignData {
            recordDirectAttribution(campaignType: type, campaignData: data)
        } else if core.config.campaignType != nil || core.config.campaignData != nil {
            warnIgnored("applyInitialConfig", "direct attribution needs both the campaign type and the campaign data, nothing is sent, campaignTypeGiven: [\(core.config.campaignType != nil)], campaignDataGiven: [\(core.config.campaignData != nil)]")
        }

        if let attribution = core.config.indirectAttribution {
            recordIndirectAttribution(attribution)
        }
    }

    // MARK: - Direct attribution

    /// Reports a campaign the user came from.
    func recordDirectAttribution(campaignType: String, campaignData: String) {
        logI("recordDirectAttribution", "recording direct attribution, campaignType: [\(campaignType)], campaignDataLength: [\(campaignData.count)]")
        logV("recordDirectAttribution", "direct attribution campaign data detail, campaignData: [\(campaignData)]")

        guard core.modules.consent.hasConsent(for: .attribution) else {
            logV("recordDirectAttribution", "no consent given for attribution, the direct attribution will not be recorded")
            return
        }

        guard !campaignType.isEmpty else {
            warnIgnored("recordDirectAttribution", "omitting the call, campaignType must be a non zero length string")
            return
        }

        guard !campaignData.isEmpty else {
            warnIgnored("recordDirectAttribution", "omitting the call, campaignData must be a non zero length string, campaignType: [\(campaignType)]")
            return
        }

        if campaignType == Self.testCampaignType {
            logD("recordDirectAttribution", "the campaign type is the server side test type, the campaign data is sent raw instead of being parsed")
            sendAttributionData(campaignData)
            return
        }

        guard campaignType == Self.countlyCampaignType else {
            logW("recordDirectAttribution", "omitting the call, direct attribution is only supported for the 'countly' campaign type, campaignType: [\(campaignType)]")
            return
        }

        guard let parsed = CountlyJSON.object(from: Data(campaignData.utf8), logger: log) as? [String: Any] else {
            warnIgnored("recordDirectAttribution", "omitting the call, the campaign data is not valid JSON")
            return
        }

        guard let campaignID = parsed["cid"] as? String, !campaignID.isEmpty else {
            warnIgnored("recordDirectAttribution", "omitting the call, the campaign ID in the campaign data is missing or empty")
            return
        }

        let campaignUserID = parsed["cuid"] as? String
        if (campaignUserID ?? "").isEmpty {
            logD("recordDirectAttribution", "the campaign user ID in the campaign data is missing or empty, it will be ignored")
        }

        sendDirectAttribution(campaignID: campaignID, campaignUserID: campaignUserID)
    }

    // MARK: - Indirect attribution

    /// Reports advertising identifiers the host application supplied.
    func recordIndirectAttribution(_ attribution: [String: String]) {
        logI("recordIndirectAttribution", "recording indirect attribution, keys: [\(attribution.keys.sorted().joined(separator: ", "))], count: [\(attribution.count)]")
        logV("recordIndirectAttribution", "indirect attribution parameter detail, attribution: [\(attribution)]")

        guard core.modules.consent.hasConsent(for: .attribution) else {
            logV("recordIndirectAttribution", "no consent given for attribution, the indirect attribution will not be recorded")
            return
        }

        // An empty identifier is worse than a missing one: it would overwrite a
        // value the server already has.
        let nonEmpty = attribution.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        if nonEmpty.count < attribution.count {
            warnIgnored("recordIndirectAttribution", "indirect attribution entries with an empty key or value are dropped rather than overwriting what the server already holds, droppedCount: [\(attribution.count - nonEmpty.count)]")
        }

        guard !nonEmpty.isEmpty else {
            logW("recordIndirectAttribution", "omitting the call, no usable key and value pair is left")
            return
        }

        let sanitized = limits.truncatedAndLimited(nonEmpty, "Indirect attribution")

        indirectAttribution = sanitized.compactMapValues { $0 as? String }
        sendIndirectAttribution()
    }

    /// Logs an ignored call or value as a warning and counts it.
    private func warnIgnored(_ function: String, _ message: String) {
        logW(function, message)
        core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
    }

    /// Resends the stored identifiers, used when attribution consent arrives after
    /// they were supplied.
    func sendIndirectAttributionIfAvailable() {
        guard indirectAttribution != nil else {
            logD("sendIndirectAttributionIfAvailable", "no indirect attribution has been supplied yet, there is nothing to resend")
            return
        }
        sendIndirectAttribution()
    }

    // MARK: - Wire

    private func sendIndirectAttribution() {
        guard let attribution = indirectAttribution, !attribution.isEmpty else {
            logD("sendIndirectAttribution", "indirect attribution request is not queued, every supplied identifier was empty or was dropped by the SDK limits")
            return
        }

        logD("sendIndirectAttribution", "indirect attribution request is being queued, these are the keys that survived the SDK limits, keys: [\(attribution.keys.sorted().joined(separator: ", "))], count: [\(attribution.count)]")

        let queryString = "\(core.network.builder.queryEssentials())&\(QS.attributionID)=\(CountlyJSON.escapedString(from: attribution, logger: log))"
        core.network.enqueueAndProceed(queryString)
    }

    private func sendDirectAttribution(campaignID: String, campaignUserID: String?) {
        // Escaped like every other value: these come from campaign JSON a deep
        // link supplied, so an unescaped `&` would inject a parameter of its own.
        var queryString = "\(core.network.builder.queryEssentials())&\(QS.campaignID)=\(campaignID.urlEscaped)"
        if let campaignUserID, !campaignUserID.isEmpty {
            queryString += "&\(QS.campaignUser)=\(campaignUserID.urlEscaped)"
        }

        logI("sendDirectAttribution", "direct attribution request is being queued, campaignID: [\(campaignID)], campaignUserIDProvided: [\(!(campaignUserID ?? "").isEmpty)]")
        core.network.enqueueAndProceed(queryString)
    }

    private func sendAttributionData(_ data: String) {
        logD("sendAttributionData", "raw campaign data request is being queued, campaignDataLength: [\(data.count)]")

        let queryString = "\(core.network.builder.queryEssentials())&\(QS.attributionData)=\(data.urlEscaped)"
        core.network.enqueueAndProceed(queryString)
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        logD("halt", "attribution module halting, the stored indirect attribution is dropped, wasStored: [\(indirectAttribution != nil)]")
        indirectAttribution = nil
    }
}
