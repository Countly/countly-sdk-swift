//
//  UserProfileTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The `user_details` payload: who the server thinks this user is.
///
/// The payload has two halves the server treats very differently. The predefined
/// fields sit at the top level and are what the dashboard shows on a profile; the
/// custom ones sit under `custom` and can also carry modifier operations the
/// server applies rather than stores. Getting a key into the wrong half is
/// invisible on the wire and wrong in the dashboard, so most of these check which
/// half a value landed in.
final class UserProfileTests: CountlyBaseTestCase {

    /// The `user_details` object of the last profile request, or `nil` when none
    /// was queued.
    private func lastUserDetails(of instance: CountlyInstance) -> [String: Any]? {
        TestUtils.requests(requestQueue(of: instance), carrying: "user_details")
            .last?["user_details"] as? [String: Any]
    }

    private func lastCustom(of instance: CountlyInstance) -> [String: Any] {
        (lastUserDetails(of: instance)?["custom"] as? [String: Any]) ?? [:]
    }

    // MARK: - Predefined fields

    func testPredefinedFieldsLandAtTheTopLevel() {
        let countly = startInstance()

        countly.userProfile.setProperties([
            "name": "Ada Lovelace",
            "username": "ada",
            "email": "ada@example.com",
            "organization": "Analytical Engines",
            "phone": "+441234567890",
            "gender": "F",
            "byear": 1815,
        ])
        countly.userProfile.save()

        guard let details = lastUserDetails(of: countly) else {
            XCTFail("saving should have queued a user_details request")
            return
        }

        XCTAssertEqual(details["name"] as? String, "Ada Lovelace")
        XCTAssertEqual(details["username"] as? String, "ada")
        XCTAssertEqual(details["email"] as? String, "ada@example.com")
        XCTAssertEqual(details["organization"] as? String, "Analytical Engines")
        XCTAssertEqual(details["phone"] as? String, "+441234567890")
        XCTAssertEqual(details["gender"] as? String, "F")
        XCTAssertEqual(TestUtils.int(details["byear"]), 1815)
        XCTAssertNil(details["custom"], "none of these belong under custom")
    }

    func testAnythingElseLandsUnderCustom() {
        let countly = startInstance()

        countly.userProfile.setProperties(["plan": "pro", "seats": 12])
        countly.userProfile.save()

        guard let details = lastUserDetails(of: countly) else {
            XCTFail("saving should have queued a user_details request")
            return
        }
        XCTAssertNil(details["plan"], "a custom key must not be promoted to the top level")

        let custom = lastCustom(of: countly)
        XCTAssertEqual(custom["plan"] as? String, "pro")
        XCTAssertEqual(TestUtils.int(custom["seats"]), 12)
    }

    /// `NSNull` clears a predefined field on the server. It is meaningless for a
    /// custom key, which is unset through its own call, so it is dropped there.
    func testNullClearsAPredefinedFieldAndIsIgnoredForACustomOne() {
        let countly = startInstance()

        countly.userProfile.setProperties(["name": NSNull(), "plan": NSNull()])
        countly.userProfile.save()

        guard let details = lastUserDetails(of: countly) else {
            XCTFail("clearing a predefined field is a change worth sending")
            return
        }
        XCTAssertTrue(details["name"] is NSNull)
        XCTAssertNil(lastCustom(of: countly)["plan"])
    }

    /// A negative birth year is not a year. Sending null clears the field rather
    /// than storing nonsense the dashboard would then plot.
    func testANegativeBirthYearClearsTheFieldInsteadOfBeingStored() {
        let countly = startInstance()

        countly.userProfile.setProperty("byear", value: -50)
        countly.userProfile.save()

        XCTAssertTrue(lastUserDetails(of: countly)?["byear"] is NSNull)
    }

    // MARK: - Custom properties

    func testUnsettingACustomPropertySendsNullForIt() {
        let countly = startInstance()

        countly.userProfile.unsetCustomProperty("plan")
        countly.userProfile.save()

        XCTAssertTrue(lastCustom(of: countly)["plan"] is NSNull)
    }

    func testSetCustomPropertyNeverRoutesToAPredefinedField() {
        let countly = startInstance()

        // The name of a predefined field, but set through the custom API, so it is
        // the user's own key and belongs under `custom`.
        countly.userProfile.setCustomProperty("name", value: "not-the-profile-name")
        countly.userProfile.save()

        XCTAssertNil(lastUserDetails(of: countly)?["name"])
        XCTAssertEqual(lastCustom(of: countly)["name"] as? String, "not-the-profile-name")
    }

    // MARK: - Modifiers

    /// Modifiers are operations, not values: the server applies them to whatever
    /// it already holds. Each has a fixed `$`-prefixed name shared by every
    /// Countly SDK.
    func testEachModifierIsSentUnderItsOwnOperator() {
        let countly = startInstance()

        countly.userProfile.setOnce("first_seen", value: "2024-01-01")
        countly.userProfile.increment("logins")
        countly.userProfile.incrementBy("credits", value: 25)
        countly.userProfile.multiply("score", value: 2)
        countly.userProfile.max("best", value: 99)
        countly.userProfile.min("worst", value: 1)
        countly.userProfile.push("tags", value: "beta")
        countly.userProfile.pushUnique("groups", value: "admins")
        countly.userProfile.pull("removed_tags", value: "alpha")
        countly.userProfile.save()

        let custom = lastCustom(of: countly)

        XCTAssertEqual((custom["first_seen"] as? [String: Any])?["$setOnce"] as? String, "2024-01-01")
        XCTAssertEqual(TestUtils.int((custom["logins"] as? [String: Any])?["$inc"]), 1)
        XCTAssertEqual(TestUtils.int((custom["credits"] as? [String: Any])?["$inc"]), 25)
        XCTAssertEqual(TestUtils.int((custom["score"] as? [String: Any])?["$mul"]), 2)
        XCTAssertEqual(TestUtils.int((custom["best"] as? [String: Any])?["$max"]), 99)
        XCTAssertEqual(TestUtils.int((custom["worst"] as? [String: Any])?["$min"]), 1)
        XCTAssertNotNil((custom["groups"] as? [String: Any])?["$addToSet"])
        XCTAssertNotNil((custom["tags"] as? [String: Any])?["$push"])
        XCTAssertNotNil((custom["removed_tags"] as? [String: Any])?["$pull"])
    }

    /// Pushing three values before a save has to send all three. Overwriting would
    /// silently drop the first two, which is the kind of loss nobody notices until
    /// the numbers are wrong.
    func testRepeatedListModifiersAccumulateInsteadOfOverwriting() {
        let countly = startInstance()

        countly.userProfile.push("tags", value: "a")
        countly.userProfile.push("tags", value: "b")
        countly.userProfile.push("tags", value: "c")
        countly.userProfile.save()

        let pushed = (lastCustom(of: countly)["tags"] as? [String: Any])?["$push"]
        guard let values = pushed as? [Any] else {
            XCTFail("three pushes should have produced an array, got \(String(describing: pushed))")
            return
        }
        XCTAssertEqual(values.map { "\($0)" }, ["a", "b", "c"])
    }

    // MARK: - Rejected values

    /// A value the server cannot store is dropped at the door rather than being
    /// carried into a payload that then fails to serialize.
    func testUnsupportedValueTypesAreDropped() {
        let countly = startInstance()

        countly.userProfile.setCustomProperty("binary", value: Data([0x00]))
        countly.userProfile.setCustomProperty("moment", value: Date())
        countly.userProfile.setCustomProperty("fine", value: "yes")
        countly.userProfile.save()

        let custom = lastCustom(of: countly)
        XCTAssertNil(custom["binary"])
        XCTAssertNil(custom["moment"])
        XCTAssertEqual(custom["fine"] as? String, "yes")
    }

    /// `NaN` and the infinities cannot be represented in JSON, and one of them
    /// anywhere in the object makes the whole payload unserializable. If they were
    /// accepted, the SDK would send an empty `user_details=` and then clear every
    /// staged property as though the server had received them, so a single bad
    /// number would destroy the entire profile update.
    func testNonFiniteNumbersAreRejectedWithoutTakingTheRestOfTheProfileWithThem() {
        let countly = startInstance()

        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.setCustomProperty("bad", value: Double.nan)
        countly.userProfile.incrementBy("also_bad", value: .infinity)
        countly.userProfile.multiply("still_bad", value: -.infinity)
        countly.userProfile.setCustomProperty("good", value: 1.5)
        countly.userProfile.save()

        guard let details = lastUserDetails(of: countly) else {
            XCTFail("the good half of the profile should still have been sent")
            return
        }

        XCTAssertEqual(details["name"] as? String, "Ada")
        let custom = lastCustom(of: countly)
        XCTAssertNil(custom["bad"])
        XCTAssertNil(custom["also_bad"])
        XCTAssertNil(custom["still_bad"])
        XCTAssertEqual(TestUtils.double(custom["good"]) ?? 0, 1.5, accuracy: 0.0001)
    }

    // MARK: - Saving

    func testSavingWithNothingStagedSendsNothing() {
        let countly = startInstance()

        countly.userProfile.save()

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "user_details").isEmpty)
    }

    func testSavingClearsTheStagedProperties() {
        let countly = startInstance()

        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.save()
        countly.userProfile.save()

        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "user_details").count, 1,
                       "the second save has nothing left to send")
    }

    func testClearDiscardsEverythingStagedWithoutSendingIt() {
        let countly = startInstance()

        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.setCustomProperty("plan", value: "pro")
        countly.userProfile.clear()
        countly.userProfile.save()

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "user_details").isEmpty)
    }

    /// An event recorded before a profile change belongs to the profile as it was,
    /// so the events go out first.
    func testPendingEventsAreSentBeforeTheProfileChange() {
        let countly = startInstance { $0.eventSendThreshold = 100 }

        countly.events.recordEvent("before-the-change")
        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.save()

        let queue = requestQueue(of: countly)
        let eventsAt = queue.firstIndex { TestUtils.parseQuery($0)["events"] != nil }
        let detailsAt = queue.firstIndex { TestUtils.parseQuery($0)["user_details"] != nil }

        guard let eventsAt, let detailsAt else {
            XCTFail("expected both an events request and a user_details in \(queue.count) requests")
            return
        }
        XCTAssertLessThan(eventsAt, detailsAt)
    }

    // MARK: - Consent

    func testNothingIsSentWithoutUserDetailsConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.save()
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "user_details").isEmpty)

        countly.consent.giveConsent(for: .userDetails)
        countly.userProfile.save()
        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "user_details").count, 1,
                       "the properties were staged all along, and consent releases them")
    }

    // MARK: - Limits

    func testKeysAndValuesAreTruncatedToTheConfiguredLimits() {
        let countly = startInstance {
            $0.sdkInternalLimits.maxKeyLength = 5
            $0.sdkInternalLimits.maxValueSize = 4
        }

        countly.userProfile.setCustomProperty("a-long-custom-key", value: "a-long-value")
        countly.userProfile.save()

        let custom = lastCustom(of: countly)
        XCTAssertEqual(custom["a-lon"] as? String, "a-lo")
    }

    /// A picture URL gets its own, much larger limit: it is a URL, not a label, and
    /// truncating it to the ordinary value limit would make it unresolvable.
    func testAPictureURLIsHeldToThePictureLimitNotTheValueLimit() {
        let countly = startInstance {
            $0.sdkInternalLimits.maxValueSize = 4
            $0.sdkInternalLimits.maxValueSizePicture = 4096
        }

        let url = "https://example.com/a/rather/long/path/to/an/avatar.png"
        countly.userProfile.setProperty("picture", value: url)
        countly.userProfile.save()

        XCTAssertEqual(lastUserDetails(of: countly)?["picture"] as? String, url)
    }

    // MARK: - Server config

    func testTheServerUserPropertyBlacklistDropsOnlyTheListedKeys() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().userPropertyBlacklist(["secret"]).json()
        }

        countly.userProfile.setCustomProperty("secret", value: "hidden")
        countly.userProfile.setCustomProperty("public", value: "shown")
        countly.userProfile.save()

        let custom = lastCustom(of: countly)
        XCTAssertNil(custom["secret"])
        XCTAssertEqual(custom["public"] as? String, "shown")
    }

    // MARK: - Config

    func testProvidedUserPropertiesFromTheConfigAreSentAtStart() {
        let countly = startInstance { $0.providedUserProperties = ["name": "Ada", "plan": "pro"] }

        guard let details = lastUserDetails(of: countly) else {
            XCTFail("properties supplied at init should be sent as the SDK starts")
            return
        }
        XCTAssertEqual(details["name"] as? String, "Ada")
        XCTAssertEqual((details["custom"] as? [String: Any])?["plan"] as? String, "pro")
    }

    // MARK: - The server's cache limit

    /// The server can cap how many custom properties the SDK holds. Past the cap
    /// the extras are dropped rather than sent, because a profile with thousands of
    /// one-off keys is a bug in the integration and forwarding it makes it the
    /// server's problem too.
    func testCustomPropertiesAreTrimmedToTheServersCacheLimit() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().userPropertyCacheLimit(3).json()
        }

        // Deliberately set in an order unrelated to the sort order, so a trim that
        // happened to keep insertion order would not pass by luck.
        countly.userProfile.setProperties([
            "zeta": 1, "alpha": 2, "mike": 3, "bravo": 4, "yankee": 5,
        ])
        countly.userProfile.save()

        let custom = lastCustom(of: countly)

        XCTAssertEqual(custom.count, 3, "the limit was not applied")
        // Sorted rather than arbitrary: the same overflowing profile has to trim the
        // same way twice, or two devices with identical data disagree on the server.
        XCTAssertEqual(Set(custom.keys), ["alpha", "bravo", "mike"])
    }

    /// At or below the limit nothing is touched. The trim allocates and sorts, so
    /// it must not run for the ordinary profile that is nowhere near the cap.
    func testCustomPropertiesAreLeftAloneBelowTheLimit() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().userPropertyCacheLimit(5).json()
        }

        countly.userProfile.setProperties(["a": 1, "b": 2, "c": 3])
        countly.userProfile.save()

        XCTAssertEqual(Set(lastCustom(of: countly).keys), ["a", "b", "c"])
    }

}
