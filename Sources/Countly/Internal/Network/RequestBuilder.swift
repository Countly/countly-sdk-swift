//
//  RequestBuilder.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Assembles the query strings the SDK sends.
///
/// Every request starts from the same nine base parameters, which is what lets
/// the server attribute it to an application, a device and a moment. Modules
/// append their own payload on top.
final class RequestBuilder {

    private static let module = "RequestBuilder"

    unowned let core: SDKCore

    init(core: SDKCore) {
        self.core = core
    }

    /// Keys a host application may not set on a direct request, because the SDK
    /// owns them.
    static let reservedKeys: Set<String> = [
        QS.appKey, QS.deviceID, QS.deviceIDType, QS.timestamp, QS.hourOfDay,
        QS.dayOfWeek, QS.timeZone, QS.sdkVersion, QS.sdkName, QS.deviceIDOld,
        QS.checksum256,
    ]

    /// The nine parameters on every request.
    ///
    /// The timestamp comes from the instance's monotonic clock, so two requests
    /// produced in the same millisecond still order correctly on the server.
    func queryEssentials() -> String {
        let deviceID = core.modules.deviceID.deviceID
        let typeValue = core.modules.deviceID.deviceIDType.wireValue
        let timestampMs = core.clock.nowMs()

        core.logger.d(Self.module, "queryEssentials", "base request parameters are built, deviceIDType: [\(typeValue)], deviceIDLength: [\(deviceID.count)], timestamp: [\(timestampMs)], appKeyLength: [\(core.config.appKey.count)]")

        return [
            "\(QS.appKey)=\(core.config.appKey.urlEscaped)",
            "\(QS.deviceID)=\(deviceID.urlEscaped)",
            "\(QS.deviceIDType)=\(typeValue)",
            "\(QS.timestamp)=\(timestampMs)",
            "\(QS.hourOfDay)=\(core.clock.hourOfDay())",
            "\(QS.dayOfWeek)=\(core.clock.dayOfWeek())",
            "\(QS.timeZone)=\(core.clock.timeZoneOffsetMinutes())",
            "\(QS.sdkVersion)=\(core.sdkVersion)",
            "\(QS.sdkName)=\(core.sdkName)",
        ].joined(separator: "&")
    }

    /// Appends the tamper check the server verifies against its configured salt.
    ///
    /// Without a salt the request goes out unchanged rather than carrying a
    /// checksum of the literal string "nil", which would be meaningless.
    func appendChecksum(_ queryString: String) -> String {
        guard let salt = core.config.secretSalt, !salt.isEmpty else {
            core.logger.d(Self.module, "appendChecksum", "no checksum is appended to the query string, reason: no secret salt is configured")
            return queryString
        }

        let checksum = (queryString + salt).sha256Hex
        core.logger.d(Self.module, "appendChecksum", "checksum is appended to the query string, queryStringLength: [\(queryString.count)]")
        return "\(queryString)&\(QS.checksum256)=\(checksum)"
    }

    /// Tells the server how many more requests are still waiting, which is what
    /// drives its backpressure signalling.
    func appendRemainingRequestCount(_ queryString: String) -> String {
        let remaining = max(0, core.requestQueueStore.count - 1)
        core.logger.d(Self.module, "appendRemainingRequestCount", "the remaining request count is appended to the query string, remainingRequestCount: [\(remaining)]")
        return "\(queryString)&\(QS.remainingRequest)=\(remaining)"
    }

    /// Location parameters, or an explicit empty location.
    ///
    /// An empty `location=` is not the same as omitting it: it tells the server to
    /// stop inferring location from the request's IP address. That is why this
    /// returns a value rather than `nil` when location is switched off.
    func locationQueryString() -> String? {
        let location = core.modules.location

        guard core.modules.consent.hasConsent(for: .location), !location.isLocationInfoDisabled else {
            core.logger.d(Self.module, "locationQueryString", "an empty location is sent so the server stops inferring it from the IP address, hasLocationConsent: [\(core.modules.consent.hasConsent(for: .location))], isLocationInfoDisabled: [\(location.isLocationInfoDisabled)]")
            return "&\(QS.location)="
        }

        var parts: [String] = []
        if let value = location.locationCoordinate { parts.append("&\(QS.location)=\(value.urlEscaped)") }
        if let value = location.city { parts.append("&\(QS.locationCity)=\(value.urlEscaped)") }
        if let value = location.isoCountryCode { parts.append("&\(QS.locationCountry)=\(value.urlEscaped)") }
        if let value = location.ipAddress { parts.append("&\(QS.locationIP)=\(value.urlEscaped)") }

        guard !parts.isEmpty else {
            core.logger.d(Self.module, "locationQueryString", "no location parameters are attached to the request, reason: none of them has a value")
            return nil
        }

        core.logger.d(Self.module, "locationQueryString", "location parameters are attached to the request, hasCoordinate: [\(location.locationCoordinate != nil)], hasCity: [\(location.city != nil)], hasCountryCode: [\(location.isoCountryCode != nil)], hasIPAddress: [\(location.ipAddress != nil)]")
        return parts.joined()
    }

    /// Marks a query string so the connection manager sends it somewhere other
    /// than the input endpoint.
    ///
    /// The override travels inside the queued string rather than beside it,
    /// because the queue is a list of strings that has to survive being written to
    /// disk and read back by a later launch.
    func withEndpointOverride(_ queryString: String, endpoint: String) -> String {
        core.logger.d(Self.module, "withEndpointOverride", "the request is marked to be sent to another endpoint, endpoint: [\(endpoint)]")
        return "\(queryString)\(QS.endPointOverrideTag)\(endpoint)"
    }
}
