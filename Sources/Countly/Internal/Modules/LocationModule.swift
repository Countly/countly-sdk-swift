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
            disableLocation()
        } else {
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
        logV("recordLocation", "location recording detail, latitude: [\(coordinate.latitude)], longitude: [\(coordinate.longitude)], city: [\(city ?? "")], countryCode: [\(isoCountryCode ?? "")], IP: [\(ipAddress ?? "")]")

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
            locationCoordinate = nil
        }

        self.city = (city?.isEmpty ?? true) ? nil : city
        self.isoCountryCode = (isoCountryCode?.isEmpty ?? true) ? nil : isoCountryCode
        self.ipAddress = (ipAddress?.isEmpty ?? true) ? nil : ipAddress

        logD("updateLocation", "stored location fields updated, coordinate: [\(locationCoordinate != nil)], city: [\(self.city != nil)], countryCode: [\(self.isoCountryCode != nil)], IP: [\(self.ipAddress != nil)]")
        logV("updateLocation", "stored location field detail, location: [\(locationCoordinate ?? "")], city: [\(self.city ?? "")], countryCode: [\(self.isoCountryCode ?? "")], IP: [\(self.ipAddress ?? "")]")

        // The server resolves a city only together with its country, so one
        // without the other is silently useless.
        if self.city != nil, self.isoCountryCode == nil {
            logW("updateLocation", "city and country code should be set as a pair, country code is missing while city is set")
        } else if self.isoCountryCode != nil, self.city == nil {
            logW("updateLocation", "city and country code should be set as a pair, city is missing while country code is set")
        }

        if locationCoordinate != nil || self.city != nil || self.isoCountryCode != nil || self.ipAddress != nil {
            isLocationInfoDisabled = false
        }
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
        logI("disableLocationInfo", "location info is cleared and location tracking is disabled for this device")

        sendLocationRequest()
    }

    /// Clears the stored fields without sending anything.
    func disableLocation() {
        logD("disableLocation", "clearing all stored location fields")

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
        guard let locationQuery = core.network.builder.locationQueryString() else { return }
        core.network.enqueueAndProceed(core.network.builder.queryEssentials() + locationQuery)
    }
}
