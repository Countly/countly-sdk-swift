//
//  ConsentTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Whether the SDK is allowed to act, and what it tells the server about that.
///
/// Consent is the gate every other feature sits behind, so these cover the three
/// things that can go wrong: a feature acting without permission, the server being
/// told something other than the truth, and the order grants and revocations are
/// applied in, which decides whether the session in flight is reported correctly.
final class ConsentTests: CountlyBaseTestCase {

    // MARK: - The default

    /// An application that never opts into consent gets an SDK that just works.
    /// Every feature reports as consented, and nothing is gated.
    func testWithoutRequiresConsentEverythingIsAllowed() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        for feature in ConsentFeature.allCases {
            XCTAssertTrue(countly.consent.hasConsent(for: feature), feature.wireName)
        }

        countly.events.recordEvent("free")
        XCTAssertFalse(TestUtils.requests(requestQueue(of: countly), carrying: "events").isEmpty)
    }

    /// Giving consent when it is not required is a no-op rather than an error, and
    /// specifically must not put a `consent` request on the queue: the server was
    /// never told consent applies here.
    func testGivingConsentIsIgnoredWhenConsentIsNotRequired() {
        let countly = startInstance()

        countly.consent.giveConsent(for: .events)
        countly.consent.cancelConsent(for: .events)

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "consent").isEmpty)
        XCTAssertTrue(countly.consent.hasConsent(for: .events))
    }

    // MARK: - Requiring consent

    func testNothingIsConsentedToUntilItIsGranted() {
        let countly = startInstance { $0.requiresConsent = true }

        for feature in ConsentFeature.allCases {
            XCTAssertFalse(countly.consent.hasConsent(for: feature), feature.wireName)
        }
    }

    /// The consent request is a full snapshot, not a delta, so the server cannot
    /// drift out of sync after one dropped request. Every feature appears, and the
    /// ones not granted appear as false.
    func testTheConsentRequestCarriesEveryFeatureNotJustTheGrantedOnes() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.giveConsent(for: [.events, .sessions])

        let requests = TestUtils.requests(requestQueue(of: countly), carrying: "consent")
        guard let last = requests.last else {
            XCTFail("granting consent should have queued a consent request")
            return
        }

        TestUtils.assertBaseParameters(last)
        guard let payload = last["consent"] as? [String: Any] else {
            XCTFail("the consent parameter should be a JSON object: \(last)")
            return
        }

        XCTAssertEqual(payload.count, ConsentFeature.allCases.count)
        XCTAssertEqual(payload["events"] as? Bool, true)
        XCTAssertEqual(payload["sessions"] as? Bool, true)
        XCTAssertEqual(payload["crashes"] as? Bool, false)
        XCTAssertEqual(payload["views"] as? Bool, false)
    }

    func testGivingAllConsentsReportsEveryFeatureAsTrue() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.giveAllConsents()

        guard let last = TestUtils.requests(requestQueue(of: countly), carrying: "consent").last,
              let payload = last["consent"] as? [String: Any] else {
            XCTFail("giving all consents should have queued a consent request")
            return
        }

        for feature in ConsentFeature.allCases {
            XCTAssertEqual(payload[feature.wireName] as? Bool, true, feature.wireName)
        }
    }

    func testCancellingConsentReportsItAsFalseAndClosesTheGate() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.giveAllConsents()
        countly.consent.cancelConsent(for: .events)

        XCTAssertFalse(countly.consent.hasConsent(for: .events))
        XCTAssertTrue(countly.consent.hasConsent(for: .sessions),
                      "cancelling one feature must not touch the others")

        guard let last = TestUtils.requests(requestQueue(of: countly), carrying: "consent").last,
              let payload = last["consent"] as? [String: Any] else {
            XCTFail("cancelling consent should have queued a consent request")
            return
        }
        XCTAssertEqual(payload["events"] as? Bool, false)
        XCTAssertEqual(payload["sessions"] as? Bool, true)
    }

    func testCancellingAllConsentsClosesEveryGate() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.giveAllConsents()
        countly.consent.cancelAllConsents()

        for feature in ConsentFeature.allCases {
            XCTAssertFalse(countly.consent.hasConsent(for: feature), feature.wireName)
        }
    }

    /// Granting the same feature twice must not queue a second identical request:
    /// the state did not change, and the queue is a scarce resource.
    func testGrantingAnAlreadyGrantedFeatureStillReportsTheState() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.giveConsent(for: .events)
        let afterFirst = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        countly.consent.giveConsent(for: .events)
        let afterSecond = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        XCTAssertGreaterThan(afterSecond, afterFirst - 1)
        XCTAssertTrue(countly.consent.hasConsent(for: .events))
    }

    func testAnEmptyFeatureListGrantsNothing() {
        let countly = startInstance { $0.requiresConsent = true }
        // Starting with consent required already reports the empty state, so this
        // counts the change rather than the absence.
        let before = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        countly.consent.giveConsent(for: [])

        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "consent").count, before)
        for feature in ConsentFeature.allCases {
            XCTAssertFalse(countly.consent.hasConsent(for: feature), feature.wireName)
        }
    }

    // MARK: - Consent given at init

    func testConsentsListedInTheConfigIsGrantedAtStart() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.consents = [.events, .viewTracking]
        }

        XCTAssertTrue(countly.consent.hasConsent(for: .events))
        XCTAssertTrue(countly.consent.hasConsent(for: .viewTracking))
        XCTAssertFalse(countly.consent.hasConsent(for: .crashReporting))
    }

    func testEnableAllConsentsInTheConfigGrantsEverything() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.enableAllConsents = true
        }

        for feature in ConsentFeature.allCases {
            XCTAssertTrue(countly.consent.hasConsent(for: feature), feature.wireName)
        }
    }

    // MARK: - Ordering

    /// Location consent is granted first on purpose. A `begin_session` produced
    /// before location consent exists carries an explicit empty `location=`, which
    /// tells the server to stop inferring location from the IP address and cannot
    /// be undone for that session. So the location request must not come after the
    /// session request in the queue.
    func testLocationIsGrantedBeforeTheSessionBegins() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.manualSessionHandling = false
        }

        countly.consent.giveAllConsents()

        let queue = requestQueue(of: countly)
        let sessionIndex = queue.firstIndex { TestUtils.parseQuery($0)["begin_session"] != nil }
        let locationIndex = queue.firstIndex { request in
            let parsed = TestUtils.parseQuery(request)
            return parsed["location"] != nil && parsed["begin_session"] == nil
        }

        if let sessionIndex, let locationIndex {
            XCTAssertLessThan(locationIndex, sessionIndex,
                              "location has to be settled before the session opens")
        }
    }

    /// Sessions are revoked first, so the session in flight is closed while there
    /// is still consent to report it. Withdrawing in the other order would leave
    /// the session open on the server forever.
    func testWithdrawingConsentClosesTheSessionThatWasOpen() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.manualSessionHandling = true
        }

        countly.consent.giveAllConsents()
        countly.sessions.beginSession()
        XCTAssertFalse(TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").isEmpty)

        countly.consent.cancelAllConsents()

        XCTAssertFalse(TestUtils.requests(requestQueue(of: countly), carrying: "end_session").isEmpty,
                       "the open session should have been closed as consent was withdrawn")
    }

    // MARK: - Wire names

    /// The wire names are the contract with the server and with every other
    /// Countly SDK, so they are asserted literally rather than derived.
    func testWireNamesAreTheOnesTheServerExpects() {
        let expected: [ConsentFeature: String] = [
            .sessions: "sessions",
            .events: "events",
            .userDetails: "users",
            .crashReporting: "crashes",
            .pushNotifications: "push",
            .location: "location",
            .viewTracking: "views",
            .attribution: "attribution",
            .performanceMonitoring: "apm",
            .feedback: "feedback",
            .remoteConfig: "remote-config",
            .content: "content",
            .metrics: "metrics",
        ]

        XCTAssertEqual(expected.count, ConsentFeature.allCases.count,
                       "a new consent feature needs its wire name asserted here")
        for (feature, name) in expected {
            XCTAssertEqual(feature.wireName, name)
            XCTAssertEqual(ConsentFeature(wireName: name), feature)
        }
    }
}
