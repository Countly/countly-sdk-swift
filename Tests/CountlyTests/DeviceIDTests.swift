//
//  DeviceIDTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Who the SDK says this device is, and what happens when that changes.
///
/// The device ID decides which user every request is attributed to, so getting it
/// wrong splits one person into two or merges two into one. These cover the three
/// things that decide that: where the ID comes from at start, what `t` reports
/// about its origin, and which of merge and no-merge a change takes.
final class DeviceIDTests: CountlyBaseTestCase {

    // MARK: - Resolving the ID at start

    func testAnIDSuppliedInTheConfigIsUsedAndReportedAsDeveloperSupplied() {
        let countly = startInstance {
            $0.deviceID = "user-42"
            $0.eventSendThreshold = 1
        }

        XCTAssertEqual(countly.deviceID.current, "user-42")
        XCTAssertEqual(countly.deviceID.type, .developerSupplied)

        countly.events.recordEvent("hello")
        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        TestUtils.assertBaseParameters(request, deviceID: "user-42",
                                       deviceIDType: DeviceIDType.developerSupplied.rawValue)
    }

    /// With no ID from the application the SDK generates one, and says so with
    /// `t=1`. The value itself is opaque; what matters is that it exists and is
    /// labelled as the SDK's own.
    func testWithNoSuppliedIDTheSDKGeneratesOneAndSaysSo() {
        let countly = startInstance {
            $0.deviceID = nil
            $0.eventSendThreshold = 1
        }

        guard let generated = countly.deviceID.current else {
            XCTFail("the SDK should have generated a device ID")
            return
        }
        XCTAssertFalse(generated.isEmpty)
        XCTAssertEqual(countly.deviceID.type, .sdkGenerated)

        countly.events.recordEvent("hello")
        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        TestUtils.assertBaseParameters(request, deviceID: generated,
                                       deviceIDType: DeviceIDType.sdkGenerated.rawValue)
    }

    /// A generated ID has to survive a restart, or every launch would look like a
    /// new user.
    func testAGeneratedIDIsReusedOnTheNextStart() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = nil
        let first = start(firstConfig)
        let generated = first.deviceID.current
        XCTAssertNotNil(generated)
        first.halt()

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = nil
        let second = start(secondConfig)

        XCTAssertEqual(second.deviceID.current, generated)
        XCTAssertEqual(second.deviceID.type, .sdkGenerated)
    }

    /// The stored ID wins over the config, so an application that hardcodes an ID
    /// does not overwrite an identity a previous run established.
    func testAStoredIDWinsOverTheConfiguredOne() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = "first"
        start(firstConfig).halt()

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = "second"
        let second = start(secondConfig)

        XCTAssertEqual(second.deviceID.current, "first")
    }

    func testResetStoredDeviceIDLetsTheConfiguredIDWin() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = "first"
        start(firstConfig).halt()

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = "second"
        secondConfig.resetStoredDeviceID = true
        let second = start(secondConfig)

        XCTAssertEqual(second.deviceID.current, "second")
    }

    /// Resetting a generated ID with no ID configured has to produce a new one,
    /// or the reset would hand back the identity it was meant to drop.
    func testResetStoredDeviceIDGeneratesANewIDInsteadOfTheStoredOne() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = nil
        let first = start(firstConfig)
        let generated = first.deviceID.current
        XCTAssertNotNil(generated)
        first.halt()

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = nil
        secondConfig.resetStoredDeviceID = true
        let second = start(secondConfig)

        XCTAssertNotNil(second.deviceID.current)
        XCTAssertNotEqual(second.deviceID.current, generated)
        XCTAssertEqual(second.deviceID.type, .sdkGenerated)
    }

    /// An application that knows who the user is does not want them held as
    /// anonymous, so a provided ID wins over temporary mode at init.
    func testAProvidedIDWinsOverTemporaryModeAtInit() {
        let countly = startInstance {
            $0.temporaryDeviceIDMode = true
            $0.deviceID = "known-user"
        }

        XCTAssertFalse(countly.deviceID.isTemporaryIDMode)
        XCTAssertEqual(countly.deviceID.current, "known-user")
        XCTAssertEqual(countly.deviceID.type, .developerSupplied)
    }

    /// A run that ended in temporary mode followed by one that provides an ID
    /// leaves the placeholder, so what was held is rewritten to the real identity.
    func testAProvidedIDLeavesAStoredTemporaryMode() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.temporaryDeviceIDMode = true
        firstConfig.deviceID = nil
        firstConfig.eventSendThreshold = 1
        let first = start(firstConfig)
        first.events.recordEvent("recorded-while-anonymous")
        first.halt()

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = "finally-known"
        let second = start(secondConfig)

        XCTAssertFalse(second.deviceID.isTemporaryIDMode)
        XCTAssertEqual(second.deviceID.current, "finally-known")
        for request in requestQueue(of: second).map(TestUtils.parseQuery) {
            XCTAssertEqual(request["device_id"] as? String, "finally-known", "nothing may still carry the placeholder")
        }
    }

    // MARK: - Changing the ID

    /// A merge tells the server the two identities are the same person, so the old
    /// ID travels with the request and no local state is discarded.
    func testChangingWithMergeSendsTheOldIDAndKeepsConsent() {
        let countly = startInstance {
            $0.deviceID = "old"
            $0.requiresConsent = true
        }
        countly.consent.giveAllConsents()

        countly.deviceID.changeWithMerge("new")

        XCTAssertEqual(countly.deviceID.current, "new")
        XCTAssertTrue(countly.consent.hasConsent(for: .events),
                      "a merge is the same person, so their consent still holds")

        let merges = TestUtils.requests(requestQueue(of: countly), carrying: "old_device_id")
        XCTAssertEqual(merges.count, 1)
        XCTAssertEqual(merges[0]["old_device_id"] as? String, "old")
        TestUtils.assertBaseParameters(merges[0], deviceID: "new")
    }

    /// Without a merge the new ID is a different person, so nothing about the old
    /// one carries over: no `old_device_id`, and consent starts empty again.
    func testChangingWithoutMergeStartsAFreshIdentity() {
        let countly = startInstance {
            $0.deviceID = "old"
            $0.requiresConsent = true
        }
        countly.consent.giveAllConsents()

        countly.deviceID.changeWithoutMerge("new")

        XCTAssertEqual(countly.deviceID.current, "new")
        XCTAssertFalse(countly.consent.hasConsent(for: .events),
                       "a new user has not consented to anything yet")
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "old_device_id").isEmpty)
    }

    /// `setID` picks the behaviour from where the current ID came from: replacing a
    /// generated ID means someone just logged in, so their history merges;
    /// replacing a developer supplied ID means a different account signed in.
    func testSetIDMergesOverAGeneratedIDAndSplitsOverASuppliedOne() {
        let generated = startInstance { $0.deviceID = nil }
        generated.deviceID.setID("logged-in")
        XCTAssertEqual(generated.deviceID.type, .developerSupplied)
        XCTAssertEqual(TestUtils.requests(requestQueue(of: generated), carrying: "old_device_id").count, 1,
                       "identifying a previously anonymous user merges the two")

        let supplied = startInstance { $0.deviceID = "account-a" }
        supplied.deviceID.setID("account-b")
        XCTAssertEqual(supplied.deviceID.current, "account-b")
        XCTAssertTrue(TestUtils.requests(requestQueue(of: supplied), carrying: "old_device_id").isEmpty,
                      "one account signing out and another in is not a merge")
    }

    func testSettingAnEmptyIDIsRefused() {
        let countly = startInstance { $0.deviceID = "keep-me" }

        countly.deviceID.setID("")

        XCTAssertEqual(countly.deviceID.current, "keep-me")
    }

    func testSettingTheSameIDDoesNothing() {
        let countly = startInstance { $0.deviceID = "same" }
        let before = requestQueue(of: countly).count

        countly.deviceID.changeWithMerge("same")

        XCTAssertEqual(requestQueue(of: countly).count, before,
                       "an ID that did not change is not a change to report")
    }

    // MARK: - Temporary mode

    /// Temporary mode is the "we do not know who this is yet" state: the SDK keeps
    /// recording, but everything is held under a placeholder ID and nothing may be
    /// attributed until a real ID arrives.
    func testTemporaryModeHoldsEverythingUnderThePlaceholder() {
        let countly = startInstance {
            $0.temporaryDeviceIDMode = true
            $0.deviceID = nil
            $0.eventSendThreshold = 1
        }

        XCTAssertTrue(countly.deviceID.isTemporaryIDMode)
        XCTAssertEqual(countly.deviceID.type, .temporary)

        countly.events.recordEvent("held", count: 1)
        countly.events.recordEvent("also-held")

        let queue = requestQueue(of: countly)
        XCTAssertFalse(queue.isEmpty, "recording still happens, it is just not attributed yet")
        for request in queue.map(TestUtils.parseQuery) {
            XCTAssertEqual(request["device_id"] as? String, TemporaryDeviceID.value)
        }
    }

    /// Leaving temporary mode is the same user finally getting an identity, so
    /// everything held back is rewritten to the real ID rather than discarded.
    func testLeavingTemporaryModeRewritesEverythingThatWasHeld() {
        let countly = startInstance {
            $0.temporaryDeviceIDMode = true
            $0.deviceID = nil
            $0.eventSendThreshold = 1
        }

        countly.events.recordEvent("recorded-while-anonymous")
        XCTAssertFalse(requestQueue(of: countly).isEmpty)

        countly.deviceID.setID("finally-known")

        XCTAssertFalse(countly.deviceID.isTemporaryIDMode)
        XCTAssertEqual(countly.deviceID.current, "finally-known")

        let queue = requestQueue(of: countly)
        XCTAssertFalse(queue.isEmpty)
        for request in queue.map(TestUtils.parseQuery) {
            XCTAssertEqual(request["device_id"] as? String, "finally-known",
                           "nothing may still carry the placeholder")
            XCTAssertEqual(request["t"] as? String, "\(DeviceIDType.developerSupplied.rawValue)",
                           "the rewritten requests also carry the new ID's origin")
        }
    }

    /// A merge into the placeholder is meaningless, so the SDK overrides it rather
    /// than sending an `old_device_id` the server cannot act on.
    func testEnteringTemporaryModeNeverMerges() {
        let countly = startInstance { $0.deviceID = "real" }

        countly.deviceID.enableTemporaryIDMode()

        XCTAssertTrue(countly.deviceID.isTemporaryIDMode)
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "old_device_id").isEmpty)
    }

    // MARK: - Wire values

    /// `t` is what tells the server whether it is looking at an identity the
    /// application chose or one the SDK invented, and every Countly SDK agrees on
    /// these two numbers.
    func testTheDeviceIDTypeWireValuesAreTheSharedOnes() {
        XCTAssertEqual(DeviceIDType.developerSupplied.wireValue, 0)
        XCTAssertEqual(DeviceIDType.sdkGenerated.wireValue, 1)
    }
}
