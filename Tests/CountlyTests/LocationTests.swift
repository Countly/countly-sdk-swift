//
//  LocationTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
import CoreLocation
@testable import Countly

/// Where the SDK says the device is, and the one case where saying nothing is
/// different from saying it is empty.
///
/// The server infers a location from the request's IP address unless it is told
/// otherwise. An omitted `location` parameter means "infer it"; an explicit empty
/// `location=` means "stop". That distinction is the whole reason location has its
/// own module rather than being three more parameters, and it is what most of
/// these check, along with when the values travel: with the next `begin_session`
/// when one is coming, on their own otherwise.
final class LocationTests: CountlyBaseTestCase {

    private let coordinate = CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784)

    /// The requests that carry location information, in queue order.
    private func locationRequests(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .filter { $0["location"] != nil || $0["city"] != nil || $0["country_code"] != nil || $0["ip_address"] != nil }
    }

    /// Location requests that are not a `begin_session`.
    private func separateLocationRequests(of instance: CountlyInstance) -> [[String: Any]] {
        locationRequests(of: instance).filter { $0["begin_session"] == nil }
    }

    private func beginSession(of instance: CountlyInstance) -> [String: Any]? {
        TestUtils.requests(requestQueue(of: instance), carrying: "begin_session").last
    }

    // MARK: - Recording

    /// Once the session's `begin_session` went out, a new location goes on its own
    /// right away, without the IP address, which the server uses only with a
    /// `begin_session`.
    func testALocationSetDuringASessionGoesOutOnItsOwnWithoutTheIPAddress() {
        let countly = startInstance()
        countly.sessions.beginSession()

        countly.location.recordLocation(coordinate,
                                        city: "Istanbul",
                                        isoCountryCode: "TR",
                                        ipAddress: "10.1.2.3")

        guard let request = separateLocationRequests(of: countly).last else {
            XCTFail("recording a location during a session should have queued a request")
            return
        }

        TestUtils.assertBaseParameters(request)
        XCTAssertEqual(request["location"] as? String, "41.008200,28.978400")
        XCTAssertEqual(request["city"] as? String, "Istanbul")
        XCTAssertEqual(request["country_code"] as? String, "TR")
        XCTAssertNil(request["ip_address"])

        countly.sessions.endSession()
        countly.sessions.beginSession()
        XCTAssertEqual(beginSession(of: countly)?["ip_address"] as? String, "10.1.2.3",
                       "the stored IP address goes with the next begin session request")
    }

    /// A location set before the session begins waits for its `begin_session`,
    /// rather than going out twice.
    func testALocationSetBeforeTheSessionWaitsForItsBeginSession() {
        let countly = startInstance()

        countly.location.recordLocation(coordinate, city: nil, isoCountryCode: nil, ipAddress: "10.1.2.3")
        XCTAssertTrue(separateLocationRequests(of: countly).isEmpty, "a begin session request is still to come")

        countly.sessions.beginSession()

        XCTAssertEqual(beginSession(of: countly)?["location"] as? String, "41.008200,28.978400")
        XCTAssertEqual(beginSession(of: countly)?["ip_address"] as? String, "10.1.2.3")
        XCTAssertTrue(separateLocationRequests(of: countly).isEmpty)
    }

    /// Without "sessions" consent no `begin_session` will carry the location, so it
    /// goes on its own.
    func testWithoutSessionsConsentTheLocationGoesOutOnItsOwn() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.consents = [.location]
        }

        countly.location.recordLocation(coordinate, city: "Istanbul", isoCountryCode: "TR", ipAddress: "10.1.2.3")

        let request = separateLocationRequests(of: countly).last { $0["city"] != nil }
        XCTAssertEqual(request?["city"] as? String, "Istanbul")
        XCTAssertNil(request?["ip_address"])
    }

    /// Fields the caller did not supply are omitted rather than sent empty, so the
    /// server keeps inferring the ones it can.
    func testFieldsThatWereNotSuppliedAreOmitted() {
        let countly = startInstance()
        countly.sessions.beginSession()

        countly.location.recordLocation(coordinate, city: nil, isoCountryCode: nil, ipAddress: nil)

        guard let request = separateLocationRequests(of: countly).last else {
            XCTFail("recording a location should have queued a request")
            return
        }
        XCTAssertNotNil(request["location"])
        XCTAssertNil(request["city"])
        XCTAssertNil(request["country_code"])
        XCTAssertNil(request["ip_address"])
    }

    /// An invalid coordinate is not a location. It is dropped rather than sent as
    /// a pair of meaningless numbers.
    func testAnInvalidCoordinateIsNotSent() {
        let countly = startInstance()
        countly.sessions.beginSession()

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid,
                                        city: "Istanbul",
                                        isoCountryCode: "TR",
                                        ipAddress: nil)

        guard let request = separateLocationRequests(of: countly).last else {
            XCTFail("the city and country are still worth sending")
            return
        }
        XCTAssertNil(request["location"])
        XCTAssertEqual(request["city"] as? String, "Istanbul")
    }

    /// The server stores the country code as sent, so a lowercase one would show
    /// up as a country of its own, and an IP address it cannot read places nobody.
    /// Values out of form are not used.
    func testACountryCodeOrIPAddressOutOfFormIsNotUsed() {
        let countly = startInstance()

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid, city: "Istanbul", isoCountryCode: "tr", ipAddress: "999.1.2.3")
        countly.sessions.beginSession()

        XCTAssertNil(beginSession(of: countly)?["country_code"])
        XCTAssertNil(beginSession(of: countly)?["ip_address"])
        XCTAssertEqual(beginSession(of: countly)?["city"] as? String, "Istanbul")
        XCTAssertEqual(logCodeCount(HealthLogCode.invalidValue, of: countly), 2)

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid, city: nil, isoCountryCode: nil, ipAddress: "2001:db8::1")
        countly.sessions.endSession()
        countly.sessions.beginSession()
        XCTAssertEqual(beginSession(of: countly)?["ip_address"] as? String, "2001:db8::1")
    }

    // MARK: - Disabling

    /// This is the case the whole module exists for: an explicit empty `location=`
    /// tells the server to stop inferring a location from the IP address. Omitting
    /// the parameter would mean the opposite.
    func testDisablingLocationSendsAnExplicitEmptyLocation() {
        let countly = startInstance()

        countly.location.disableLocationInfo()

        guard let request = locationRequests(of: countly).last else {
            XCTFail("disabling location has to be reported, it is not just local state")
            return
        }
        XCTAssertEqual(request["location"] as? String, "")
        XCTAssertNil(request["city"])
        XCTAssertNil(request["country_code"])
        XCTAssertNil(request["ip_address"])
    }

    func testDisablingLocationInTheConfigMeansTheFirstRequestAlreadyCarriesTheEmptyForm() {
        let countly = startInstance {
            $0.disableLocation = true
            $0.manualSessionHandling = true
        }

        countly.sessions.beginSession()

        guard let begin = TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").first else {
            XCTFail("the session should have begun")
            return
        }
        XCTAssertEqual(begin["location"] as? String, "",
                       "the very first session must not have its location inferred")
    }

    /// Turning location off works without consent too, so a consent given later
    /// does not turn it back on.
    func testDisablingLocationAppliesWithoutConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.location.disableLocationInfo()
        countly.consent.giveConsent(for: [.location, .sessions])
        countly.sessions.beginSession()

        XCTAssertEqual(beginSession(of: countly)?["location"] as? String, "")
    }

    /// Recording a location after disabling has to work: the user turned it back
    /// on, and the SDK must not stay silently disabled.
    func testRecordingALocationAfterDisablingReEnablesIt() {
        let countly = startInstance()

        countly.location.disableLocationInfo()
        countly.location.recordLocation(coordinate, city: "Istanbul", isoCountryCode: "TR", ipAddress: nil)
        countly.sessions.beginSession()

        XCTAssertEqual(beginSession(of: countly)?["location"] as? String, "41.008200,28.978400")
    }

    // MARK: - Config

    /// Location given at init rides along on the first session request rather than
    /// producing a second one, so the session is attributed from the start.
    func testLocationFromTheConfigTravelsOnTheSessionRatherThanItsOwnRequest() {
        let countly = startInstance {
            $0.location = coordinate
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
            $0.ipAddress = "10.1.2.3"
            $0.manualSessionHandling = true
        }

        countly.sessions.beginSession()

        guard let begin = TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").first else {
            XCTFail("the session should have begun")
            return
        }
        XCTAssertEqual(begin["location"] as? String, "41.008200,28.978400")
        XCTAssertEqual(begin["city"] as? String, "Istanbul")
        XCTAssertEqual(begin["country_code"] as? String, "TR")
        XCTAssertEqual(begin["ip_address"] as? String, "10.1.2.3")
        XCTAssertTrue(separateLocationRequests(of: countly).isEmpty)
    }

    // MARK: - Consent

    func testNoLocationIsRecordedWithoutLocationConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.location.recordLocation(coordinate, city: "Istanbul", isoCountryCode: "TR", ipAddress: nil)

        let recorded = locationRequests(of: countly).filter { ($0["location"] as? String)?.isEmpty == false }
        XCTAssertTrue(recorded.isEmpty)
    }

    /// Without location consent the SDK must actively tell the server not to infer
    /// one, which is the empty form rather than silence.
    func testWithoutLocationConsentTheSessionCarriesTheEmptyLocation() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.manualSessionHandling = true
        }
        countly.consent.giveConsent(for: .sessions)
        countly.sessions.beginSession()

        guard let begin = TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").first else {
            XCTFail("the session should have begun")
            return
        }
        XCTAssertEqual(begin["location"] as? String, "")
    }

    /// Values from the config wait for location consent, and go out on their own
    /// once it is given when no session request will carry them.
    func testConfigValuesGoOutOnceLocationConsentIsGiven() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
        }
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "city").isEmpty)

        countly.consent.giveConsent(for: .location)

        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "city").last?["city"] as? String, "Istanbul")
    }

    // MARK: - Server setting

    func testTheServerCanSwitchLocationTrackingOff() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(false).json()
        }

        countly.location.recordLocation(coordinate, city: "Istanbul", isoCountryCode: "TR", ipAddress: nil)
        countly.sessions.beginSession()

        let recorded = locationRequests(of: countly).filter { ($0["location"] as? String)?.isEmpty == false }
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertEqual(beginSession(of: countly)?["location"] as? String, "",
                       "with lt off the server records no location, not even from the IP address")
    }

    /// The server's "lt" wins over the application's choice while its settings
    /// contain it: true keeps location on although the application turned it off.
    func testTheServersLocationSettingWinsOverTheApplicationsChoice() {
        let countly = startInstance {
            $0.disableLocation = true
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(true).json()
        }

        countly.location.disableLocationInfo()
        countly.sessions.beginSession()

        XCTAssertTrue(separateLocationRequests(of: countly).filter { $0["location"] as? String == "" }.isEmpty,
                      "no erase request while the server keeps location on")
        XCTAssertNil(beginSession(of: countly)?["location"], "the server places the session from the IP address")
    }

    /// An off state that came from the server ends when its settings no longer
    /// contain "lt", without the application having to set a location.
    func testAnOffStateFromTheServerEndsWithTheSetting() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(false).json()
        }
        XCTAssertFalse(core(of: countly).modules.location.isLocationOn)

        MockURLProtocol.respond(pathContaining: "/o/sdk", json: ServerConfigBuilder().json())
        core(of: countly).serverConfig.fetch(config: core(of: countly).config)

        TestUtils.waitUntil("the answer without lt turns location back on") {
            core(of: countly).modules.location.isLocationOn
        }
    }
}
