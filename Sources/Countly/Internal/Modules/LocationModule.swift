//
//  LocationModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import CoreLocation

/// Holds the location the host application wants reported.
///
/// The SDK never asks the device where it is. Everything here is supplied by the
/// host application, which is what keeps location an explicit product decision
/// rather than a side effect of integrating analytics.
///
/// Location is on while "location" consent is given and location tracking is
/// allowed: by the server's "lt" while its settings contain it, otherwise by the
/// application, which turns it off with `disableLocationInfo()` and back on with
/// a value. While it is on, every `begin_session` carries the stored values; while
/// it is off, the empty `location=`, which keeps the server from looking the
/// location up from the request's IP address.
final class LocationModule: ModuleBase {

    override class var moduleName: String { "Location" }

    /// `latitude,longitude`, or `nil` when no coordinate was supplied.
    private(set) var locationCoordinate: String?
    private(set) var city: String?
    private(set) var isoCountryCode: String?
    private(set) var ipAddress: String?

    /// Whether the application turned location off. Kept in memory only, and
    /// overruled by the server's "lt" while its settings contain it.
    private(set) var isDisabledByApp = false

    /// Whether stored values changed since a request last carried them, so a
    /// `begin_session` that took them is not followed by a second request.
    private var hasUnsentValues = false

    /// The server's "lt" this module last acted on, so a change can be told from a
    /// repeat. Set once the initial config is applied.
    private var appliedServerSetting: Bool?
    private var isConfigured = false

    /// Whether location is on now.
    var isLocationOn: Bool {
        guard core.modules.consent.hasConsent(for: .location) else { return false }
        if let setting = core.serverConfig.locationTracking { return setting }
        return !isDisabledByApp
    }

    // MARK: - Init

    /// Applies the location of the config: off when the config disables it,
    /// otherwise its values, kept until a request can carry them.
    func applyInitialConfig() {
        appliedServerSetting = core.serverConfig.locationTracking
        isConfigured = true

        if core.config.disableLocation {
            logD("applyInitialConfig", "location is switched off in the initial config, nothing will be reported and the server is told to stop inferring a location")
            isDisabledByApp = true
            forgetStoredLocation()
        } else {
            logD("applyInitialConfig", "location is taken from the initial config, it rides along on the first session request rather than a request of its own")
            updateLocation(core.config.location,
                           city: core.config.city,
                           isoCountryCode: core.config.isoCountryCode,
                           ipAddress: core.config.ipAddress)
        }
    }

    /// At the end of init, when no `begin_session` will carry the location: the
    /// values go out on their own while location is on, the empty location while
    /// it is off.
    func sendAtEndOfInit() {
        // A session begun during init already carried it.
        guard !core.modules.sessions.isSessionStarted else { return }
        guard !isBeginSessionExpected else {
            logD("sendAtEndOfInit", "a begin session request will carry the location, nothing is sent on its own")
            return
        }

        if isLocationOn {
            sendUnsentValues()
        } else {
            sendEraseRequest()
        }
    }

    // MARK: - Public operations

    /// Replaces the stored location and sends it: with the next `begin_session`
    /// when one is still to come, otherwise on its own right away. Ignored while
    /// the server turns location tracking off.
    func recordLocation(_ coordinate: CLLocationCoordinate2D,
                        city: String?,
                        isoCountryCode: String?,
                        ipAddress: String?) {
        logI("recordLocation", "location recording requested, coordinateProvided: [\(Self.isGiven(coordinate))], cityProvided: [\(!(city ?? "").isEmpty)], countryCodeProvided: [\(!(isoCountryCode ?? "").isEmpty)], IPProvided: [\(!(ipAddress ?? "").isEmpty)]")

        guard core.modules.consent.hasConsent(for: .location) else {
            logV("recordLocation", "no location consent given, location is not recorded")
            return
        }

        guard core.serverConfig.locationTrackingEnabled else {
            logD("recordLocation", "location recording is dropped, location tracking is disabled by server config")
            return
        }

        logV("recordLocation", "location recording detail, latitude: [\(coordinate.latitude.logValue)], longitude: [\(coordinate.longitude.logValue)], city: [\(city ?? "")], countryCode: [\(isoCountryCode ?? "")], IP: [\(ipAddress ?? "")]")

        updateLocation(coordinate, city: city, isoCountryCode: isoCountryCode, ipAddress: ipAddress)
        sendUnsentValuesUnlessASessionWillCarryThem()
    }

    /// Stores a location without sending it, replacing every stored value: a
    /// value not given clears the stored one. A value that is not in its valid
    /// form is ignored with a warning. Any usable value turns location back on
    /// after the application turned it off.
    func updateLocation(_ coordinate: CLLocationCoordinate2D,
                        city: String?,
                        isoCountryCode: String?,
                        ipAddress: String?) {
        // Values the server's "lt" withholds are never logged, at any level.
        let mayLogValues = core.serverConfig.locationTrackingEnabled

        if CLLocationCoordinate2DIsValid(coordinate) {
            locationCoordinate = String(format: "%f,%f", coordinate.latitude, coordinate.longitude)
        } else {
            if Self.isGiven(coordinate) {
                warnInvalid("the coordinate is not a valid latitude and longitude")
            }
            locationCoordinate = nil
        }

        self.city = Self.nilIfEmpty(city)

        self.isoCountryCode = Self.nilIfEmpty(isoCountryCode)
        if let code = self.isoCountryCode, !Self.isCountryCode(code) {
            warnInvalid("the country code is not an uppercase ISO 3166-1 alpha-2 code")
            if mayLogValues {
                logV("updateLocation", "unused country code detail, countryCode: [\(code)]")
            }
            self.isoCountryCode = nil
        }

        self.ipAddress = Self.nilIfEmpty(ipAddress)
        if let address = self.ipAddress, !Self.isIPAddress(address) {
            warnInvalid("the IP address is not an IPv4 or IPv6 address")
            if mayLogValues {
                logV("updateLocation", "unused IP address detail, ipAddress: [\(address)]")
            }
            self.ipAddress = nil
        }

        logD("updateLocation", "stored location fields updated, coordinateStored: [\(locationCoordinate != nil)], cityStored: [\(self.city != nil)], countryCodeStored: [\(self.isoCountryCode != nil)], IPStored: [\(self.ipAddress != nil)]")
        if mayLogValues {
            logV("updateLocation", "stored location field detail, location: [\(locationCoordinate ?? "")], city: [\(self.city ?? "")], countryCode: [\(self.isoCountryCode ?? "")], IP: [\(self.ipAddress ?? "")]")
        }

        // The server resolves a city only together with its country, so one
        // without the other is silently useless.
        if self.city != nil, self.isoCountryCode == nil {
            logW("updateLocation", "city and country code should be set as a pair, country code is missing while city is set")
        } else if self.isoCountryCode != nil, self.city == nil {
            logW("updateLocation", "city and country code should be set as a pair, city is missing while country code is set")
        }

        hasUnsentValues = hasStoredValues
        if hasStoredValues, isDisabledByApp {
            logD("updateLocation", "a location value was supplied, location reporting is switched back on for this device")
            isDisabledByApp = false
        }
    }

    /// Turns location off until a value is set again, with or without consent, so
    /// a later consent does not turn it back on. Clears the stored values and
    /// erases the location on the server, unless the server's "lt" keeps location
    /// on, in which case the choice applies once its settings no longer contain it.
    func disableLocationInfo() {
        logI("disableLocationInfo", "location clearing requested, serverSetting: [\(core.serverConfig.locationTracking.map { "\($0)" } ?? "not set")]")
        isDisabledByApp = true
        forgetStoredLocation()

        guard core.serverConfig.locationTracking != true else {
            logD("disableLocationInfo", "the server's location setting keeps location on, the application's choice applies once the settings no longer contain it")
            return
        }
        sendEraseRequest()
    }

    // MARK: - Consent

    /// The stored values become usable: they go with the next `begin_session`,
    /// or on their own when none is coming. Location the application turned off
    /// stays off.
    func consentGiven() {
        hasUnsentValues = hasStoredValues
        guard isLocationOn else { return }
        sendUnsentValuesUnlessASessionWillCarryThem()
    }

    /// Clears the stored values and, unless the removal is the silent one of a
    /// device ID change without merge, erases the location on the server.
    func consentRemoved(silently: Bool) {
        forgetStoredLocation()
        if !silently {
            sendEraseRequest()
        }
    }

    // MARK: - Server setting

    /// Follows a change of the server's "lt". Turning it off clears the stored
    /// values and erases the location. When the settings stop containing it, the
    /// application's choice applies again: location off by the application is
    /// erased once more, and an off state that came from the server ends by itself.
    func serverSettingChanged() {
        guard isConfigured else { return }
        let setting = core.serverConfig.locationTracking
        let previous = appliedServerSetting
        appliedServerSetting = setting
        guard setting != previous else { return }

        logD("serverSettingChanged", "the server's location setting changed, previous: [\(previous.map { "\($0)" } ?? "not set")], current: [\(setting.map { "\($0)" } ?? "not set")], disabledByApp: [\(isDisabledByApp)]")
        switch setting {
        case false?:
            forgetStoredLocation()
            sendEraseRequest()
        case nil where previous == true && isDisabledByApp:
            sendEraseRequest()
        default:
            break
        }
    }

    // MARK: - Wire

    /// The location parameters of a `begin_session`: the stored values while
    /// location is on, nothing when there are none, which lets the server look the
    /// location up, and the empty location while location is off.
    func beginSessionParameters() -> String? {
        guard isLocationOn else {
            logD("beginSessionParameters", "location is off, the begin session request carries the empty location")
            return "&\(QS.location)="
        }
        hasUnsentValues = false
        return valueParameters(includingIPAddress: true)
    }

    /// Whether a `begin_session` is to be expected: "sessions" consent is given
    /// and the server allows session tracking.
    private var isBeginSessionExpected: Bool {
        core.modules.consent.hasConsent(for: .sessions) && core.serverConfig.sessionTrackingEnabled
    }

    private func sendUnsentValuesUnlessASessionWillCarryThem() {
        guard core.modules.sessions.isSessionStarted || !isBeginSessionExpected else {
            logD("sendUnsentValues", "the location waits for the next begin session request")
            return
        }
        sendUnsentValues()
    }

    /// Sends the stored values on a request of their own, without the IP address,
    /// which the server uses only with a `begin_session`.
    private func sendUnsentValues() {
        guard hasUnsentValues, let parameters = valueParameters(includingIPAddress: false) else {
            logD("sendUnsentValues", "no location values are waiting to be sent on their own")
            return
        }
        hasUnsentValues = false
        logD("sendUnsentValues", "a location request is being queued, coordinateSent: [\(locationCoordinate != nil)], citySent: [\(city != nil)], countryCodeSent: [\(isoCountryCode != nil)]")
        core.network.enqueueAndProceed(core.network.builder.queryEssentials() + parameters)
    }

    /// Sends the empty location, which tells the server to stop placing the user.
    func sendEraseRequest() {
        logD("sendEraseRequest", "a location erase request is being queued")
        core.network.enqueueAndProceed("\(core.network.builder.queryEssentials())&\(QS.location)=")
    }

    /// The stored values as parameters, or `nil` when none is stored.
    private func valueParameters(includingIPAddress: Bool) -> String? {
        var parts: [String] = []
        if let value = locationCoordinate { parts.append("&\(QS.location)=\(value.urlEscaped)") }
        if let value = city { parts.append("&\(QS.locationCity)=\(value.urlEscaped)") }
        if let value = isoCountryCode { parts.append("&\(QS.locationCountry)=\(value.urlEscaped)") }
        if includingIPAddress, let value = ipAddress { parts.append("&\(QS.locationIP)=\(value.urlEscaped)") }
        return parts.isEmpty ? nil : parts.joined()
    }

    // MARK: - Values

    private var hasStoredValues: Bool {
        locationCoordinate != nil || city != nil || isoCountryCode != nil || ipAddress != nil
    }

    /// Drops the stored values without changing whether location is on, so a
    /// location supplied later is still honoured.
    func forgetStoredLocation() {
        logD("forgetStoredLocation", "dropping all stored location fields, coordinateWasStored: [\(locationCoordinate != nil)], cityWasStored: [\(city != nil)], countryCodeWasStored: [\(isoCountryCode != nil)], IPWasStored: [\(ipAddress != nil)]")

        locationCoordinate = nil
        city = nil
        isoCountryCode = nil
        ipAddress = nil
        hasUnsentValues = false
    }

    private func warnInvalid(_ message: String) {
        logW("updateLocation", "\(message), the value is not used")
        core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
    }

    /// An empty string means the host application supplied nothing, and is stored
    /// as nothing: an empty field on the wire would read as a value the server
    /// should keep.
    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Whether a coordinate was supplied at all. The public API defaults to
    /// `kCLLocationCoordinate2DInvalid` to mean "not given".
    private static func isGiven(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude != kCLLocationCoordinate2DInvalid.latitude
            || coordinate.longitude != kCLLocationCoordinate2DInvalid.longitude
    }

    /// Two uppercase ASCII letters. The server stores the code as sent, so a
    /// lowercase one would show up as a country of its own.
    private static func isCountryCode(_ value: String) -> Bool {
        value.unicodeScalars.count == 2 && value.unicodeScalars.allSatisfy { (65...90).contains($0.value) }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, value, &ipv4) == 1 || inet_pton(AF_INET6, value, &ipv6) == 1
    }
}
