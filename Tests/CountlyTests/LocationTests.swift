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
/// these check.
final class LocationTests: CountlyBaseTestCase {

    private let coordinate = CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784)

    /// The requests that carry location information, in queue order.
    private func locationRequests(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .filter { $0["location"] != nil || $0["city"] != nil || $0["country_code"] != nil || $0["ip_address"] != nil }
    }

    // MARK: - Recording

    func testRecordingALocationSendsEveryFieldItWasGiven() {
        let countly = startInstance()

        countly.location.recordLocation(coordinate,
                                        city: "Istanbul",
                                        isoCountryCode: "TR",
                                        ipAddress: "10.1.2.3")

        guard let request = locationRequests(of: countly).last else {
            XCTFail("recording a location should have queued a request")
            return
        }

        TestUtils.assertBaseParameters(request)
        XCTAssertEqual(request["location"] as? String, "41.008200,28.978400")
        XCTAssertEqual(request["city"] as? String, "Istanbul")
        XCTAssertEqual(request["country_code"] as? String, "TR")
        XCTAssertEqual(request["ip_address"] as? String, "10.1.2.3")
    }

    /// Fields the caller did not supply are omitted rather than sent empty, so the
    /// server keeps inferring the ones it can.
    func testFieldsThatWereNotSuppliedAreOmitted() {
        let countly = startInstance()

        countly.location.recordLocation(coordinate, city: nil, isoCountryCode: nil, ipAddress: nil)

        guard let request = locationRequests(of: countly).last else {
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

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid,
                                        city: "Istanbul",
                                        isoCountryCode: "TR",
                                        ipAddress: nil)

        guard let request = locationRequests(of: countly).last else {
            XCTFail("the city and country are still worth sending")
            return
        }
        XCTAssertNil(request["location"])
        XCTAssertEqual(request["city"] as? String, "Istanbul")
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

    /// Recording a location after disabling has to work: the user turned it back
    /// on, and the SDK must not stay silently disabled.
    func testRecordingALocationAfterDisablingReEnablesIt() {
        let countly = startInstance()

        countly.location.disableLocationInfo()
        countly.location.recordLocation(coordinate, city: "Istanbul", isoCountryCode: "TR", ipAddress: nil)

        guard let request = locationRequests(of: countly).last else {
            XCTFail("the new location should have been queued")
            return
        }
        XCTAssertEqual(request["location"] as? String, "41.008200,28.978400")
    }

    // MARK: - Config

    /// Location given at init rides along on the first session request rather than
    /// producing a second one, so the session is attributed from the start.
    func testLocationFromTheConfigTravelsOnTheSessionRatherThanItsOwnRequest() {
        let countly = startInstance {
            $0.location = coordinate
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
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

    // MARK: - Server config

    func testTheServerCanSwitchLocationTrackingOff() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(false).json()
        }

        countly.location.recordLocation(coordinate, city: "Istanbul", isoCountryCode: "TR", ipAddress: nil)

        let recorded = locationRequests(of: countly).filter { ($0["location"] as? String)?.isEmpty == false }
        XCTAssertTrue(recorded.isEmpty)
    }
}
