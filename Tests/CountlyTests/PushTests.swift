//
//  PushTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
#if canImport(UserNotifications)
import UserNotifications
#endif
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

    /// Starts the default instance, the only one that handles push.
    ///
    /// Its storage outlives a crashed run, so the stored device ID is reset. The
    /// token is reported without asking for the permission state, because
    /// `UNUserNotificationCenter.current()` aborts under `swift test`, and the
    /// process token an earlier test broadcast reaches every new registration.
    @discardableResult
    private func startPushInstance(_ adjust: (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        startInstance {
            $0.instanceName = Countly.defaultInstanceName
            $0.resetStoredDeviceID = true
            $0.sendPushTokenAlways = true
            adjust($0)
        }
    }

    // MARK: - Recording an action

    /// A tap on the notification body is button index zero, which is how the
    /// dashboard tells a body tap from an action button.
    func testTappingTheBodyIsRecordedAsButtonZero() {
        let countly = startPushInstance { $0.eventSendThreshold = 1 }

        countly.push.recordAction(for: notification(id: "n-1"), clickedButtonIndex: 0)

        let recorded = events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }
        XCTAssertEqual(recorded.count, 1)

        let segmentation = (recorded[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[CountlyPushKey.notificationID] as? String, "n-1")
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 0)
        XCTAssertNotNil(segmentation[CountlyPushKey.platform], "the platform tells the dashboard which SDK reported it")
    }

    func testTappingAnActionButtonCarriesItsIndex() {
        let countly = startPushInstance { $0.eventSendThreshold = 1 }

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
        let countly = startPushInstance { $0.eventSendThreshold = 1 }

        countly.push.recordAction(for: ["something": "else"], clickedButtonIndex: 0)
        countly.push.recordAction(for: [CountlyPushKey.countlyPayload: [String: Any]()],
                                  clickedButtonIndex: 0)
        countly.push.recordAction(for: notification(id: ""), clickedButtonIndex: 0)

        XCTAssertTrue(events(of: countly).isEmpty)
    }

    func testNoActionIsRecordedWithoutPushConsent() {
        let countly = startPushInstance {
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
        let countly = startPushInstance {
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
        let countly = startPushInstance { $0.sendPushTokenAlways = true }

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
        let countly = startPushInstance { $0.sendPushTokenAlways = true }

        core(of: countly).modules.push.didReceive(.failed)

        guard let request = tokenRequests(of: countly).last else {
            XCTFail("a failed registration should still have queued a request")
            return
        }
        XCTAssertEqual(request["ios_token"] as? String, "")
        #endif
    }

    func testClearingTheTokenSendsAnEmptyOne() {
        let countly = startPushInstance()

        core(of: countly).modules.push.clearToken()

        XCTAssertEqual(tokenRequests(of: countly).last?["ios_token"] as? String, "")
    }

    func testNoTokenIsSentWithoutPushConsent() {
        let countly = startPushInstance {
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
        let countly = startPushInstance { $0.sendPushTokenAlways = true }
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
        let countly = startPushInstance { $0.requiresConsent = true }

        let answered = expectation(description: "the permission request answers")
        countly.push.askForNotificationPermission { granted, error in
            XCTAssertFalse(granted)
            XCTAssertNil(error)
            answered.fulfill()
        }

        wait(for: [answered], timeout: TestUtils.asyncTimeout)
    }

    // MARK: - The runtime

    /// The token and the taps belong to the process, so only the default instance
    /// handles push. A named instance that asks for it registers for nothing, and
    /// reports no token, no cleared token and no tap, so no second server receives
    /// a token or a tap for a notification it never sent.
    func testOnlyTheDefaultInstanceHandlesPush() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let main = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }
        let named = startInstance {
            $0.sendPushTokenAlways = true
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0xAB, 0xCD]))
        named.push.recordPushNotificationToken()
        named.push.clearPushNotificationToken()
        named.push.recordAction(for: notification(id: "n-named"), clickedButtonIndex: 0)
        main.push.recordAction(for: notification(id: "n-main"), clickedButtonIndex: 0)

        XCTAssertEqual(tokenRequests(of: main).last?["ios_token"] as? String, "abcd")
        XCTAssertTrue(tokenRequests(of: named).isEmpty, "a named instance must not report the process token")
        XCTAssertTrue(events(of: named).isEmpty, "a named instance must not record taps")
        XCTAssertEqual(events(of: main).filter { $0["key"] as? String == "[CLY]_push_action" }.count, 1)
        #endif
    }

    /// The server keeps a token on the user that sent it last. Before a device ID
    /// change without merge the token is taken back from the leaving user, under
    /// their device ID, and after it the token goes out for the new user, or the
    /// previous user's pushes would keep reaching this device.
    func testAChangeWithoutMergeMovesTheTokenFromTheLeavingUserToTheNewOne() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }
        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x0C, 0x0D]))
        XCTAssertEqual(tokenRequests(of: countly).last?["device_id"] as? String, Self.deviceID)

        countly.deviceID.changeWithMerge("merged-user")
        let afterMerge = tokenRequests(of: countly).count
        XCTAssertEqual(afterMerge, 1, "a merge moves the token on the server, so nothing is sent again")

        countly.deviceID.changeWithoutMerge("next-user")

        let sent = Array(tokenRequests(of: countly).dropFirst(afterMerge))
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.first?["device_id"] as? String, "merged-user", "the merge moved the token to the merged user")
        XCTAssertEqual(sent.first?["ios_token"] as? String, "")
        XCTAssertEqual(sent.last?["device_id"] as? String, "next-user")
        XCTAssertEqual(sent.last?["ios_token"] as? String, "0c0d")
        #endif
    }

    /// With consent required, a change without merge withdraws every consent, so
    /// the token waits until push consent is given for the new user. The silent
    /// consent removal does not clear the token a second time.
    func testAChangeWithoutMergeUnderRequiredConsentWaitsForThePushConsent() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
            $0.requiresConsent = true
            $0.consents = [.pushNotifications]
        }
        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x0E, 0x0F]))
        let before = tokenRequests(of: countly).count

        countly.deviceID.changeWithoutMerge("consent-user")
        let cleared = Array(tokenRequests(of: countly).dropFirst(before))
        XCTAssertEqual(cleared.count, 1, "only the empty token for the leaving user, no push consent for the new user yet")
        XCTAssertEqual(cleared.first?["device_id"] as? String, Self.deviceID)
        XCTAssertEqual(cleared.first?["ios_token"] as? String, "")

        countly.consent.giveConsent(for: .pushNotifications)
        XCTAssertEqual(tokenRequests(of: countly).last?["device_id"] as? String, "consent-user")
        XCTAssertEqual(tokenRequests(of: countly).last?["ios_token"] as? String, "0e0f")
        #endif
    }

    /// Servers from 26.01 on keep the token through a consent change, so the SDK
    /// clears it itself, or an opted out user keeps getting campaign pushes.
    func testRemovingPushConsentClearsTheTokenOnTheServer() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
            $0.requiresConsent = true
            $0.consents = [.pushNotifications]
        }
        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x01, 0x0F]))

        countly.consent.cancelConsent(for: .pushNotifications)

        XCTAssertEqual(tokenRequests(of: countly).last?["ios_token"] as? String, "")
        XCTAssertEqual(tokenRequests(of: countly).last?["device_id"] as? String, Self.deviceID)
        #endif
    }

    /// A reset of the stored device ID at start is a user change too: the token
    /// sent for the previous user is taken back under their device ID.
    func testResettingTheStoredDeviceIDTakesTheTokenBackFromThePreviousUser() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let first = startPushInstance {
            $0.deviceID = "previous-user"
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }
        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x02, 0x0F]))
        XCTAssertEqual(tokenRequests(of: first).last?["device_id"] as? String, "previous-user")
        first.halt()

        let second = startPushInstance { $0.deviceID = "next-user" }

        let cleared = tokenRequests(of: second).filter { $0["ios_token"] as? String == "" }
        XCTAssertEqual(cleared.count, 1)
        XCTAssertEqual(cleared.first?["device_id"] as? String, "previous-user")
        #endif
    }

    /// A failed registration reports an empty token through the default
    /// instance, so the server stops trying to reach a device that cannot
    /// receive anything.
    func testAFailedRegistrationReachesTheDefaultInstance() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
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

    // MARK: - Registering for the process-wide token

    /// Registration is what subscribes an instance to the process-wide token, and
    /// it is gated on push having been switched on in the initial config. An
    /// instance that never asked for push must not start receiving tokens because
    /// some other instance in the process did.
    ///
    /// Asserted as a delta rather than an absolute count: the runtime holds its
    /// token for the life of the process and nothing resets it between tests, so
    /// "this instance saw no new token" is the only claim that stays true whatever
    /// ran first.
    func testAnInstanceWithoutThePushFeatureNeverHearsAboutTheToken() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.sendPushTokenAlways = true
            // Deliberately not `.pushNotifications`.
            $0.features = [.crashReporting]
            $0.disableAutomaticPushHandling = true
        }
        let before = tokenRequests(of: countly).count

        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x01, 0x02]))

        XCTAssertEqual(tokenRequests(of: countly).count, before,
                       "an instance that did not ask for push was handed a token anyway")
        #endif
    }

    /// Consent gates registration, not just sending. Without it the instance is not
    /// subscribed at all, so a token arriving for the process does not reach it.
    func testAnInstanceWithoutPushConsentDoesNotHearAboutTheTokenUntilConsentArrives() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.requiresConsent = true
            $0.disableAutomaticPushHandling = true
        }
        let before = tokenRequests(of: countly).count

        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x0A, 0x0B]))
        XCTAssertEqual(tokenRequests(of: countly).count, before,
                       "a token reached an instance with no push consent")

        // Giving consent registers the instance, which is the path
        // `ConsentModule` takes when a feature is switched on after start.
        countly.consent.giveConsent(for: .pushNotifications)
        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0x0A, 0x0B]))

        XCTAssertGreaterThan(tokenRequests(of: countly).count, before,
                             "consent should have subscribed the instance to the token")
        #endif
    }

    /// Registering is idempotent. The call happens on start, again when consent
    /// arrives, and again on any later `recordPushNotificationToken`, so a second
    /// subscription would have the instance report the same token twice and bill
    /// the server for a duplicate.
    func testRegisteringMoreThanOnceStillReportsTheTokenOnce() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("push tokens only exist on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }
        // Already registered on start; these must all be absorbed.
        core(of: countly).modules.push.startPushNotifications()
        core(of: countly).modules.push.startPushNotifications()
        let before = tokenRequests(of: countly).count

        Countly.didRegisterForRemoteNotifications(deviceToken: Data([0xFE, 0xED]))

        XCTAssertEqual(tokenRequests(of: countly).count, before + 1,
                       "the instance subscribed more than once and reported the token twice")
        #endif
    }

    /// Coming back to the foreground re-asserts the notification centre delegate,
    /// because a host that installs its own delegate after the SDK started would
    /// otherwise silently stop notification taps being reported.
    ///
    /// The re-assertion itself talks to `UNUserNotificationCenter`, which a unit
    /// test cannot observe. What is asserted here is the guard around it: the two
    /// configurations that must take the early return, and that neither path
    /// disturbs the instance. That is the part that would break on a refactor.
    func testComingBackToTheForegroundIsHarmlessWhicheverWayPushIsConfigured() throws {
        #if !(os(iOS) || os(visionOS) || os(macOS))
        throw XCTSkip("the notification centre delegate only exists on iOS, visionOS and macOS")
        #else
        // Registered, but the host owns the delegate, so the SDK must not claim it.
        //
        // `sendPushTokenAlways` is not incidental. The runtime holds its token for
        // the life of the process, so an instance registering here picks up a token
        // an earlier test broadcast, and reporting it without this flag goes through
        // `UNUserNotificationCenter.current()`, which aborts outright under `swift
        // test`: there is no application bundle, and the framework raises
        // `bundleProxyForCurrentProcess is nil` rather than returning an error. That
        // is also why the permission branches of `sendToken` are uncovered and
        // cannot be covered from a unit test.
        let manual = startPushInstance {
            $0.sendPushTokenAlways = true
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }
        // Never registered, so there is nothing to re-assert.
        let unregistered = startInstance { $0.features = [.crashReporting] }

        let manualBefore = tokenRequests(of: manual).count
        let unregisteredBefore = tokenRequests(of: unregistered).count

        core(of: manual).modules.push.didEnterForeground()
        core(of: unregistered).modules.push.didEnterForeground()

        XCTAssertEqual(tokenRequests(of: manual).count, manualBefore,
                       "re-asserting the delegate is not a reason to re-report the token")
        XCTAssertEqual(tokenRequests(of: unregistered).count, unregisteredBefore)
        #endif
    }

    // MARK: - A response forwarded by the host

    /// A body tap forwarded through the public entry point is recorded the same as
    /// one the SDK's own delegate saw, and carries the notification's ID.
    func testAForwardedBodyTapIsRecordedAsButtonZero() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        Countly.handleNotificationResponse(try response(id: "n-10", url: "https://count.ly"))

        let recorded = events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }
        XCTAssertEqual(recorded.count, 1)

        let segmentation = (recorded.first?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[CountlyPushKey.notificationID] as? String, "n-10")
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 0)
        #endif
    }

    /// The button index is read off the action identifier the SDK registered, so a
    /// bridge forwarding the response reports the same index the native path would.
    func testAForwardedActionButtonCarriesItsIndex() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        let notification = try response(id: "n-11",
                                        buttons: [["t": "Open", "l": "https://count.ly/one"],
                                                  ["t": "Later", "l": "https://count.ly/two"]],
                                        actionIdentifier: CountlyPushKey.actionIdentifierPrefix + "2")
        Countly.handleNotificationResponse(notification)

        let segmentation = (events(of: countly).first?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 2)
        #endif
    }

    /// Swiping a notification away is the user declining it. Reporting it as a tap
    /// would inflate the click-through of every campaign.
    func testADismissedNotificationRecordsNothing() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        Countly.handleNotificationResponse(try response(id: "n-12",
                                                        url: "https://count.ly",
                                                        actionIdentifier: UNNotificationDismissActionIdentifier))

        XCTAssertTrue(events(of: countly).isEmpty)
        #endif
    }

    /// A host can forward every response without filtering: one that carries no
    /// Countly payload, or an unusable ID, is ignored. An identifier the SDK never
    /// registered is still a user acting on a Countly notification, so it is
    /// reported as a body tap rather than dropped.
    func testAForwardedResponseIsIgnoredUnlessItIsCountlys() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        let countly = startPushInstance {
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
        }

        Countly.handleNotificationResponse(try response(userInfo: ["something": "else"]))
        Countly.handleNotificationResponse(try response(id: ""))
        XCTAssertTrue(events(of: countly).isEmpty)

        Countly.handleNotificationResponse(try response(id: "n-13", actionIdentifier: "SomeOtherSDKAction"))

        let segmentation = (events(of: countly).first?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[CountlyPushKey.notificationID] as? String, "n-13")
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 0,
                       "an unregistered identifier is still a body tap")
        #endif
    }

    // MARK: - Taps before the start

    /// A tap that started the application before the SDK did is kept and recorded
    /// once the default instance starts, with the time it happened.
    func testATapBeforeTheStartIsRecordedAtTheStartWithItsTime() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        Countly.handleNotificationResponse(try response(id: "n-early",
                                                        buttons: [["t": "Open", "l": "https://count.ly/one"]],
                                                        actionIdentifier: CountlyPushKey.actionIdentifierPrefix + "1"))
        let tappedAt = Date().timeIntervalSince1970
        TestUtils.pump(1.5)

        let countly = startPushInstance { $0.eventSendThreshold = 1 }

        let recorded = events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }
        XCTAssertEqual(recorded.count, 1)
        let segmentation = (recorded.first?["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation[CountlyPushKey.notificationID] as? String, "n-early")
        XCTAssertEqual(TestUtils.int(segmentation[CountlyPushKey.actionButtonIndex]), 1)
        let recordedAt = (TestUtils.double(recorded.first?["timestamp"]) ?? 0) / 1000
        XCTAssertLessThan(abs(recordedAt - tappedAt), 1, "the event carries the time of the tap, not of the start")
        XCTAssertTrue(core(of: countly).keyValueStore.pendingPushActions.isEmpty)
        #endif
    }

    func testATapBeforeTheStartIsDroppedWithoutPushConsent() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        Countly.handleNotificationResponse(try response(id: "n-early"))

        let countly = startPushInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }

        XCTAssertTrue(events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }.isEmpty)
        XCTAssertTrue(core(of: countly).keyValueStore.pendingPushActions.isEmpty)
        #endif
    }

    // MARK: - Opening a URL

    /// The application's handler gets the link first and can take it over. The
    /// action is recorded before, whatever the handler returns.
    func testTheApplicationsActionHandlerCanTakeTheLinkOver() throws {
        #if !(canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS)))
        throw XCTSkip("the push runtime only exists on iOS, visionOS and macOS")
        #else
        var handled: URL?
        let countly = startPushInstance {
            $0.eventSendThreshold = 1
            $0.features = [.pushNotifications]
            $0.disableAutomaticPushHandling = true
            $0.pushActionHandler = { link, _ in
                handled = link
                return true
            }
        }

        Countly.handleNotificationResponse(try response(id: "n-20", url: "myapp://inbox"))

        TestUtils.waitUntil("the action handler is called") { handled != nil }
        XCTAssertEqual(handled?.absoluteString, "myapp://inbox")
        XCTAssertEqual(events(of: countly).filter { $0["key"] as? String == "[CLY]_push_action" }.count, 1)
        #endif
    }

    /// A notification link is remote input: a dangerous scheme is never opened,
    /// and an allow list narrows the rest.
    func testDangerousLinkSchemesAreNeverOpenedAndAnAllowListNarrowsTheRest() {
        XCTAssertTrue(LinkSchemePolicy.isAllowed(scheme: "https", allowedSchemes: []))
        XCTAssertTrue(LinkSchemePolicy.isAllowed(scheme: "myapp", allowedSchemes: []))
        for scheme in ["file", "content", "javascript", "jar", "zip", "intent", "data", "JavaScript"] {
            XCTAssertFalse(LinkSchemePolicy.isAllowed(scheme: scheme, allowedSchemes: []), scheme)
        }
        XCTAssertTrue(LinkSchemePolicy.isAllowed(scheme: "MyApp", allowedSchemes: ["myapp"]))
        XCTAssertFalse(LinkSchemePolicy.isAllowed(scheme: "https", allowedSchemes: ["myapp"]))
        XCTAssertFalse(LinkSchemePolicy.isAllowed(scheme: "javascript", allowedSchemes: ["javascript"]))
        XCTAssertFalse(LinkSchemePolicy.isAllowed(scheme: nil, allowedSchemes: []))
    }

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

    #if canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS))
    /// A `UNNotificationResponse` carrying `userInfo`.
    ///
    /// Neither `UNNotification` nor `UNNotificationResponse` has a public
    /// initializer, and both are the input to the entry point under test, so they
    /// are decoded from a coder that answers with the values they ask for.
    private func response(userInfo: [AnyHashable: Any],
                          actionIdentifier: String = UNNotificationDefaultActionIdentifier) throws -> UNNotificationResponse {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: "request", content: content, trigger: nil)

        let notification = try XCTUnwrap(UNNotification(coder: DecodedFromValues([
            "date": Date(),
            "request": request,
            "sourceIdentifier": "",
        ])))
        return try XCTUnwrap(UNNotificationResponse(coder: DecodedFromValues([
            "notification": notification,
            "actionIdentifier": actionIdentifier,
        ])))
    }

    /// The same, for a Countly payload built by ``notification(id:buttons:url:)``.
    private func response(id: String,
                          buttons: [[String: Any]] = [],
                          url: String? = nil,
                          actionIdentifier: String = UNNotificationDefaultActionIdentifier) throws -> UNNotificationResponse {
        try response(userInfo: notification(id: id, buttons: buttons, url: url),
                     actionIdentifier: actionIdentifier)
    }
    #endif
}

#if canImport(UserNotifications) && (os(iOS) || os(visionOS) || os(macOS))
/// A keyed coder that hands back a fixed table, so a class whose initializer is
/// private to the framework can still be built in a test.
private final class DecodedFromValues: NSCoder {
    private let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
        super.init()
    }

    override var allowsKeyedCoding: Bool { true }
    override var requiresSecureCoding: Bool { false }
    override func containsValue(forKey key: String) -> Bool { values[key] != nil }
    override func decodeObject(forKey key: String) -> Any? { values[key] }
    override func decodeBool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func decodeInt64(forKey key: String) -> Int64 { values[key] as? Int64 ?? 0 }
    override func decodeInt32(forKey key: String) -> Int32 { values[key] as? Int32 ?? 0 }
    override func decodeDouble(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func failWithError(_: Error) {}
}
#endif
