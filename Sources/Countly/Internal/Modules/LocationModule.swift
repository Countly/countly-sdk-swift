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
final class LocationModule: ModuleBase {

    override class var moduleName: String { "Location" }

    /// `latitude,longitude`, or `nil` when no coordinate was supplied.
    private(set) var locationCoordinate: String?
    private(set) var city: String?
    private(set) var isoCountryCode: String?
    private(set) var ipAddress: String?

    /// When set, the SDK sends an empty `location=` so the server stops inferring
    /// location from the request's IP address.
    private(set) var isLocationInfoDisabled = false

    // MARK: - Init

    func applyInitialConfig() {
        if core.config.disableLocation {
            logD("applyInitialConfig", "location is switched off in the initial config, nothing will be reported and the server is told to stop inferring a location")
            disableLocation()
        } else {
            logD("applyInitialConfig", "location is taken from the initial config, it rides along on the first session request rather than a request of its own")
            updateLocation(core.config.location,
                           city: core.config.city,
                           isoCountryCode: core.config.isoCountryCode,
                           ipAddress: core.config.ipAddress)
        }
    }

    // MARK: - Public operations

    /// Stores a location and reports it right away.
    func recordLocation(_ coordinate: CLLocationCoordinate2D,
                        city: String?,
                        isoCountryCode: String?,
                        ipAddress: String?) {
        logI("recordLocation", "location recording requested, coordinateProvided: [\(CLLocationCoordinate2DIsValid(coordinate))], cityProvided: [\(!(city ?? "").isEmpty)], countryCodeProvided: [\(!(isoCountryCode ?? "").isEmpty)], IPProvided: [\(!(ipAddress ?? "").isEmpty)]")
        logV("recordLocation", "location recording detail, latitude: [\(coordinate.latitude.logValue)], longitude: [\(coordinate.longitude.logValue)], city: [\(city ?? "")], countryCode: [\(isoCountryCode ?? "")], IP: [\(ipAddress ?? "")]")

        guard core.modules.consent.hasConsent(for: .location) else {
            logV("recordLocation", "no location consent given, location is not recorded")
            return
        }

        guard core.serverConfig.locationTrackingEnabled else {
            logD("recordLocation", "location recording is dropped, location tracking is disabled by server config")
            return
        }

        updateLocation(coordinate, city: city, isoCountryCode: isoCountryCode, ipAddress: ipAddress)
        sendLocationRequest()
    }

    /// Stores a location without reporting it, which is what init does so the
    /// values ride along on the first session request instead of a second one.
    func updateLocation(_ coordinate: CLLocationCoordinate2D,
                        city: String?,
                        isoCountryCode: String?,
                        ipAddress: String?) {
        if CLLocationCoordinate2DIsValid(coordinate) {
            locationCoordinate = String(format: "%f,%f", coordinate.latitude, coordinate.longitude)
        } else {
            // The public API defaults to an invalid coordinate to mean "not
            // supplied", so this is the ordinary city-only call and not a mistake.
            logD("updateLocation", "no usable coordinate was supplied, any previously stored coordinate is cleared")
            locationCoordinate = nil
        }

        self.city = Self.nilIfEmpty(city)
        self.isoCountryCode = Self.nilIfEmpty(isoCountryCode)
        self.ipAddress = Self.nilIfEmpty(ipAddress)

        logD("updateLocation", "stored location fields updated, coordinateStored: [\(locationCoordinate != nil)], cityStored: [\(self.city != nil)], countryCodeStored: [\(self.isoCountryCode != nil)], IPStored: [\(self.ipAddress != nil)]")
        logV("updateLocation", "stored location field detail, location: [\(locationCoordinate ?? "")], city: [\(self.city ?? "")], countryCode: [\(self.isoCountryCode ?? "")], IP: [\(self.ipAddress ?? "")]")

        // The server resolves a city only together with its country, so one
        // without the other is silently useless.
        if self.city != nil, self.isoCountryCode == nil {
            logW("updateLocation", "city and country code should be set as a pair, country code is missing while city is set")
        } else if self.isoCountryCode != nil, self.city == nil {
            logW("updateLocation", "city and country code should be set as a pair, city is missing while country code is set")
        }

        if locationCoordinate != nil || self.city != nil || self.isoCountryCode != nil || self.ipAddress != nil {
            if isLocationInfoDisabled {
                logD("updateLocation", "a location field was supplied, location reporting is switched back on for this device")
            }
            isLocationInfoDisabled = false
        }
    }

    /// An empty string means the host application supplied nothing, and is stored
    /// as nothing: an empty field on the wire would read as a value the server
    /// should keep.
    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Reports whatever is stored, if consent and behavior settings allow it.
    func sendLocationInfo() {
        logI("sendLocationInfo", "stored location info send requested, locationInfoDisabled: [\(isLocationInfoDisabled)]")

        guard core.modules.consent.hasConsent(for: .location) else {
            logV("sendLocationInfo", "no location consent given, stored location info is not sent")
            return
        }

        guard core.serverConfig.locationTrackingEnabled else {
            logD("sendLocationInfo", "stored location info send is dropped, location tracking is disabled by server config")
            return
        }

        sendLocationRequest()
    }

    /// Clears the stored location and tells the server to stop inferring one.
    func disableLocationInfo() {
        logI("disableLocationInfo", "location clearing requested")

        guard core.modules.consent.hasConsent(for: .location) else {
            logV("disableLocationInfo", "no location consent given, location info is not cleared")
            return
        }

        disableLocation()
        sendLocationRequest()
    }

    /// Drops the stored fields without setting `isLocationInfoDisabled`, so a
    /// location supplied later is still honoured.
    func forgetStoredLocation() {
        logD("forgetStoredLocation", "dropping all stored location fields, coordinateWasStored: [\(locationCoordinate != nil)], cityWasStored: [\(city != nil)], countryCodeWasStored: [\(isoCountryCode != nil)], IPWasStored: [\(ipAddress != nil)]")

        locationCoordinate = nil
        city = nil
        isoCountryCode = nil
        ipAddress = nil
    }

    /// Clears the stored fields without sending anything.
    func disableLocation() {
        logD("disableLocation", "clearing all stored location fields, coordinateWasStored: [\(locationCoordinate != nil)], cityWasStored: [\(city != nil)], countryCodeWasStored: [\(isoCountryCode != nil)], IPWasStored: [\(ipAddress != nil)]")

        isLocationInfoDisabled = true
        locationCoordinate = nil
        city = nil
        isoCountryCode = nil
        ipAddress = nil
    }

    // MARK: - Wire

    /// Sends the location parameters on their own request, whatever the consent
    /// state.
    ///
    /// Consent withdrawal has to be able to send the empty form: that is the
    /// signal that tells the server to stop inferring location from the request
    /// IP, and gating it on the consent that was just withdrawn would swallow it.
    func sendLocationRequest() {
        guard let locationQuery = core.network.builder.locationQueryString() else {
            logD("sendLocationRequest", "no location request is queued, nothing is stored to send and location is not disabled, so the next session request carries the location instead")
            return
        }

        logD("sendLocationRequest", "location request is being queued, locationInfoDisabled: [\(isLocationInfoDisabled)], coordinateSent: [\(locationCoordinate != nil)], citySent: [\(city != nil)], countryCodeSent: [\(isoCountryCode != nil)], IPSent: [\(ipAddress != nil)]")
        core.network.enqueueAndProceed(core.network.builder.queryEssentials() + locationQuery)
    }
}
