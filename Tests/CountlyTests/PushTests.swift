//
//  PushTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Reporting the device token and what the user did with a notification.
///
/// Most of the push feature is delegate plumbing that only a real application can
/// exercise. What is testable here is the part that decides what reaches the
/// server: which token is reported and under what permission state, and the
/// `[CLY]_push_action` event that carries a tap.
final class PushTests: CountlyBaseTestCase {

    /// A Countly notification payload, as the server sends it.
    private func notification(id: String,
                              buttons: [[String: Any]] = [],
                              url: String? = nil) -> [AnyHashable: Any] {
        var payload: [String: Any] = [CountlyPushKey.notificationID: id]
        if !buttons.isEmpty { payload[CountlyPushKey.buttons] = buttons }
        if let url { payload[CountlyPushKey.defaultURL] = url }
        return [CountlyPushKey.countlyPayload: payload]
    }

    /// Every event the SDK recorded.
    private func events(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
    }

    /// The token requests the SDK queued.
    private func tokenRequests(of instance: CountlyInstance) -> [[String: Any]] {
        TestUtils.requests(requestQueue(of: instance), carrying: "token_session")
    }

    // MARK: - Recording an action

    /// A tap on the notification body is button index zero, which is how the
    /// dashboard tells a body tap from an action button.
    func testTappingTheBodyIsRecordedAsButtonZero() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.push.recordAction(for: notification(id: "n-1"), clickedButtonIndex: 0)

        let recorded = events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }
        XCTAssertEqual(recorded.count, 1)

        let segmentation = (recorded[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[CountlyPushKey.notificationID] as? String, "n-1")
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 0)
        XCTAssertNotNil(segmentation[CountlyPushKey.platform], "the platform tells the dashboard which SDK reported it")
    }

    func testTappingAnActionButtonCarriesItsIndex() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.push.recordAction(for: notification(id: "n-2",
                                                    buttons: [["t": "Open"], ["t": "Later"]]),
                                  clickedButtonIndex: 2)

        let segmentation = (events(of: countly).first?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 2)
    }

    /// A notification with no Countly payload is somebody else's, and an ID that is
    /// present but empty is as unusable as a missing one: either would reach the
    /// dashboard as a click nothing can be attributed to.
    func testANotificationWithNoUsableIDRecordsNothing() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.push.recordAction(for: ["something": "else"], clickedButtonIndex: 0)
        countly.push.recordAction(for: [CountlyPushKey.countlyPayload: [String: Any]()],
                                  clickedButtonIndex: 0)
        countly.push.recordAction(for: notification(id: ""), clickedButtonIndex: 0)

        XCTAssertTrue(events(of: countly).isEmpty)
    }

    func testNoActionIsRecordedWithoutPushConsent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }

        countly.push.recordAction(for: notification(id: "n-3"), clickedButtonIndex: 0)
        XCTAssertTrue(events(of: countly).isEmpty)

        countly.consent.giveConsent(for: .pushNotifications)
        countly.push.recordAction(for: notification(id: "n-3"), clickedButtonIndex: 0)

        XCTAssertEqual(events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }.count, 1)
    }

    // MARK: - The token

    /// The token is reported with the test mode, which is what routes the
    /// notification through the sandbox or production APNs environment. Getting it
    /// backwards sends every development push to the wrong environment.
    func testTheTokenIsReportedWithTheConfiguredTestMode() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startInstance {
            $0.sendPushTokenAlways = true
            $0.pushTestMode = .development
        }

        core(of: countly).modules.push.didReceive(.value("abc123"))

        guard let request = tokenRequests(of: countly).last else {
            XCTFail("receiving a token should have queued a request")
            return
        }
        TestUtils.assertBaseParameters(request)
        XCTAssertEqual(request["ios_token"] as? String, "abc123")
        XCTAssertEqual(TestUtils.int(request["test_mode"]), PushTestMode.development.wireValue)
        XCTAssertEqual(request["token_session"] as? String, "1")
        #endif
    }

    func testTheTestModeDefaultsToProductionWhenNoneIsConfigured() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startInstance { $0.sendPushTokenAlways = true }

        core(of: countly).modules.push.didReceive(.value("abc123"))

        XCTAssertEqual(TestUtils.int(tokenRequests(of: countly).last?["test_mode"]), 0)
        #endif
    }

    /// Registration failing is worth reporting: an empty token tells the server to
    /// stop trying to reach this device, which is more useful than silence.
    func testAFailedRegistrationClearsTheTokenOnTheServer() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startInstance { $0.sendPushTokenAlways = true }

        core(of: countly).modules.push.didReceive(.failed)

        guard let request = tokenRequests(of: countly).last else {
            XCTFail("a failed registration should still have queued a request")
            return
        }
        XCTAssertEqual(request["ios_token"] as? String, "")
        #endif
    }

    func testClearingTheTokenSendsAnEmptyOne() {
        let countly = startInstance()

        core(of: countly).modules.push.clearToken()

        XCTAssertEqual(tokenRequests(of: countly).last?["ios_token"] as? String, "")
    }

    func testNoTokenIsSentWithoutPushConsent() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.sendPushTokenAlways = true
        }

        core(of: countly).modules.push.didReceive(.value("abc123"))

        XCTAssertTrue(tokenRequests(of: countly).isEmpty)
    }

    /// Without a token there is nothing to report, so asking for one to be sent is
    /// a no-op rather than a request carrying an empty value.
    func testAskingToSendATokenBeforeOneArrivedSendsNothing() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startInstance { $0.sendPushTokenAlways = true }
        let before = tokenRequests(of: countly).count

        // No token has been received by this instance, and the process-wide runtime
        // has none either unless another test put one there.
        if PushRuntime.shared.currentToken == nil {
            countly.push.recordPushNotificationToken()
            XCTAssertEqual(tokenRequests(of: countly).count, before)
        }
        #endif
    }

    // MARK: - Permission

    /// The permission request answers even when it refuses, because a caller that
    /// wrapped it in a continuation would otherwise hang for good.
    func testAskingForPermissionWithoutConsentStillAnswers() {
        let countly = startInstance { $0.requiresConsent = true }

        let answered = expectation(description: "the permission request answers")
        countly.push.askForNotificationPermission { granted, error in
            XCTAssertFalse(granted)
            XCTAssertNil(error)
            answered.fulfill()
        }

        wait(for: [answered], timeout: TestUtils.asyncTimeout)
    }

    // MARK: - The runtime

    /// The runtime holds the token for the process, not for one instance, because
    /// the token belongs to the application. Every registered instance hears about
    /// it.
    func testTheTokenReachesEveryRegisteredInstance() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let first = startInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }
        let second = startInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0xAB, 0xCD]))

        XCTAssertEqual(tokenRequests(of: first).last?["ios_token"] as? String, "abcd")
        XCTAssertEqual(tokenRequests(of: second).last?["ios_token"] as? String, "abcd")
        #endif
    }

    func testAFailedRegistrationReachesEveryRegisteredInstance() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        Countly.didFailToRegisterForRemoteNotifications(
            error: NSError(domain: "test", code: 1))

        XCTAssertEqual(tokenRequests(of: countly).last?["ios_token"] as? String, "")
        #endif
    }

    /// A device token is reported as lowercase hex, which is the form APNs and the
    /// server agree on.
    func testTheDeviceTokenIsReportedAsLowercaseHex() {
        XCTAssertEqual(Data([0x00, 0x0F, 0xA5, 0xFF]).hexString, "000fa5ff")
    }

    // MARK: - Opening a URL

    /// A URL that is missing, empty or not a URL at all is not opened, and must not
    /// trap on the way to deciding that.
    func testAnUnusableURLIsNotOpened() throws {
        // The push runtime only exists where notifications do.
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        PushRuntime.shared.openURL(nil)
        PushRuntime.shared.openURL("")
        PushRuntime.shared.openURL("   ")
        #endif
    }
}
