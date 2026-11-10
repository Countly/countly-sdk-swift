//
//  ConsentTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import CoreLocation
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

    /// Every wire name maps back to its feature, and an unknown one is refused
    /// rather than guessed. Bridge SDKs receive consent as these strings.
    func testAWireNameMapsBackToItsFeature() {
        for feature in ConsentFeature.allCases {
            XCTAssertEqual(ConsentFeature(wireName: feature.wireName), feature, feature.wireName)
        }
        XCTAssertNil(ConsentFeature(wireName: "not-a-feature"))
        XCTAssertNil(ConsentFeature(wireName: ""))
        XCTAssertNil(ConsentFeature(wireName: "Sessions"), "the wire is lowercase and the match is exact")
    }

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

    // MARK: - Withdrawal closes what it opened

    /// A coordinate left in memory across a withdrawal is re-sent on re-grant.
    func testWithdrawingLocationConsentForgetsTheStoredLocation() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.consents = [.location]
        }

        countly.location.recordLocation(CLLocationCoordinate2D(latitude: 41.0082, longitude: 28.9784),
                                        city: "Istanbul", isoCountryCode: "TR", ipAddress: "10.2.33.12")
        countly.consent.cancelConsent(for: .location)

        // Only what the re-grant itself enqueues; earlier requests had consent.
        let beforeRegrant = requestQueue(of: countly).count
        countly.consent.giveConsent(for: .location)

        let sentAfterRegrant = requestQueue(of: countly)
            .dropFirst(beforeRegrant)
            .filter { $0.contains("41.008") || $0.contains("Istanbul") }
        XCTAssertTrue(sentAfterRegrant.isEmpty,
                      "the location withdrawn from should not be transmitted after the re-grant, got: \(sentAfterRegrant)")
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
    func testGrantingAnAlreadyGrantedFeatureQueuesNoSecondRequest() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.giveConsent(for: .events)
        let afterFirst = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        countly.consent.giveConsent(for: .events)
        let afterSecond = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        XCTAssertEqual(afterSecond, afterFirst)
        XCTAssertTrue(countly.consent.hasConsent(for: .events))
    }

    func testRemovingConsentThatWasNeverGivenQueuesNothing() {
        let countly = startInstance { $0.requiresConsent = true }
        let before = TestUtils.requests(requestQueue(of: countly), carrying: "consent").count

        countly.consent.cancelConsent(for: [.events, .crashReporting])

        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "consent").count, before)
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
        XCTAssertEqual(logCodeCount(HealthLogCode.invalidConsentName, of: countly), 1)
    }

    func testSetConsentGivesOrRemoves() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.consent.setConsent(for: [.events, .crashReporting], given: true)
        XCTAssertTrue(countly.consent.hasConsent(for: .events))
        XCTAssertTrue(countly.consent.hasConsent(for: .crashReporting))

        countly.consent.setConsent(for: [.events], given: false)
        XCTAssertFalse(countly.consent.hasConsent(for: .events))
        XCTAssertTrue(countly.consent.hasConsent(for: .crashReporting))
    }

    func testAFeatureGroupGivesAndRemovesConsentForAllItsFeatures() {
        let countly = startInstance { $0.requiresConsent = true }
        countly.consent.createFeatureGroup("activity", features: [.sessions, .events, .viewTracking])

        countly.consent.setConsentFeatureGroup("activity", given: true)
        XCTAssertTrue(countly.consent.hasConsent(forGroup: "activity"))
        XCTAssertTrue(countly.consent.hasConsent(for: .viewTracking))
        XCTAssertFalse(countly.consent.hasConsent(for: .crashReporting), "only the group's features")

        countly.consent.cancelConsent(for: .events)
        XCTAssertFalse(countly.consent.hasConsent(forGroup: "activity"), "a group has consent only when all its features do")

        countly.consent.setConsentFeatureGroup("activity", given: false)
        XCTAssertFalse(countly.consent.hasConsent(for: .sessions))

        countly.consent.setConsentFeatureGroup("never-created", given: true)
        XCTAssertFalse(countly.consent.hasConsent(forGroup: "never-created"))
        XCTAssertEqual(logCodeCount(HealthLogCode.invalidConsentName, of: countly), 2)
    }

    /// A device ID change without merge removes every consent for the new user,
    /// but tells the server nothing: the removal would be filed under a user who
    /// never gave the consent. The location erase request is skipped for the same
    /// reason.
    func testAChangeWithoutMergeRemovesConsentWithoutSendingAnything() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.consents = [.location, .events]
        }
        let before = requestQueue(of: countly).count

        countly.deviceID.changeWithoutMerge("next-user")

        let after = requestQueue(of: countly).dropFirst(before).map(TestUtils.parseQuery)
        XCTAssertTrue(after.filter { $0["consent"] != nil }.isEmpty, "no consent request for the silent removal")
        XCTAssertTrue(after.filter { $0["location"] != nil }.isEmpty, "no location erase request")
        XCTAssertFalse(countly.consent.hasConsent(for: .location))
        XCTAssertFalse(countly.consent.hasConsent(for: .events))
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

    /// Every flag of a grant is set before any feature reacts, so the session the
    /// grant begins already sees the metrics consent given with it.
    func testASessionBegunByAGrantCarriesTheMetricsGivenWithIt() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.manualSessionHandling = false
        }
        // An automatic session is refused while the application reads as in the background.
        AppState.setActive(true)

        countly.consent.giveAllConsents()

        let begins = TestUtils.requests(requestQueue(of: countly), carrying: "begin_session")
        XCTAssertEqual(begins.count, 1)
        XCTAssertNotNil(begins.first?["metrics"], "the metrics consent came with the same grant")
    }

    /// A location stored before its consent rides on the session the same grant
    /// begins, and is not sent a second time on its own.
    func testALocationGivenWithTheSessionGoesOutOnce() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.manualSessionHandling = false
            $0.city = "Izmir"
            $0.isoCountryCode = "TR"
        }
        AppState.setActive(true)

        countly.consent.giveConsent(for: [.location, .sessions])

        let carriers = TestUtils.requests(requestQueue(of: countly), carrying: "city")
        XCTAssertEqual(carriers.count, 1)
        XCTAssertNotNil(carriers.first?["begin_session"], "the session carries the location")
    }

    /// Profile changes pending when the user consent goes are dropped, also when
    /// the same call closes the session and sends its events, and the events still
    /// go out before the session ends.
    func testWithdrawingEverythingDropsThePendingProfileChanges() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.manualSessionHandling = true
        }
        countly.consent.giveAllConsents()
        countly.sessions.beginSession()
        countly.events.recordEvent("inside-the-session")
        countly.userProfile.setProperty("name", value: "Ada")

        countly.consent.cancelAllConsents()

        let queue = requestQueue(of: countly)
        XCTAssertTrue(TestUtils.requests(queue, carrying: "user_details").isEmpty)
        let eventsAt = queue.firstIndex { TestUtils.parseQuery($0)["events"] != nil }
        let endAt = queue.firstIndex { TestUtils.parseQuery($0)["end_session"] != nil }
        guard let eventsAt, let endAt else {
            XCTFail("expected both an events request and an end_session in \(queue.count) requests")
            return
        }
        XCTAssertLessThan(eventsAt, endAt)
    }

    /// The session in flight is closed while there is still consent to report it.
    /// Withdrawing in the other order would leave the session open on the server
    /// forever.
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
            .feedback: "feedback",
            .remoteConfig: "remote-config",
            .content: "content",
            .metrics: "metrics",
            .starRating: "star-rating",
        ]

        XCTAssertEqual(expected.count, ConsentFeature.allCases.count,
                       "a new consent feature needs its wire name asserted here")
        for (feature, name) in expected {
            XCTAssertEqual(feature.wireName, name)
            XCTAssertEqual(ConsentFeature(wireName: name), feature)
        }
    }
}
