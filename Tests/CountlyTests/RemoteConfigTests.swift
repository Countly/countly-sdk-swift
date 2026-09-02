//
//  RemoteConfigTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Reading configuration back from the server, and the A/B testing built on it.
///
/// Remote config is the one feature where the SDK asks rather than reports, so it
/// skips the request queue and goes out as an instant request. That makes the
/// things worth checking different from the rest of the SDK: which URL was called,
/// what the cache does with the answer, and whether every path that takes a
/// completion handler actually calls it.
final class RemoteConfigTests: CountlyBaseTestCase {

    /// Every test here asserts on what reached the transport, so the whole suite
    /// needs a transport it can see.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessNetworkIsInterceptable()
    }

    /// Only the requests this feature makes. The SDK sends a health check and a
    /// behavior settings fetch of its own as it starts, which are not remote
    /// config traffic and are gated separately.
    private func remoteConfigRequests() -> [MockURLProtocol.Captured] {
        let methods = ["method=rc", "method=fetch_remote_config", "ab_fetch_variants",
                       "ab_fetch_experiments", "ab_enroll_variant"]
        return MockURLProtocol.requests.filter { request in
            methods.contains { request.query.contains($0) }
        }
    }

    /// Answers the remote config download but leaves the A/B enrolment unanswered.
    ///
    /// Enrolment requests go to `/o/sdk` as well, so a handler that answers the
    /// whole path answers those too, and the request queue then drains the
    /// enrolment out of itself in the background. A test that reads the queue
    /// afterwards is racing that drain: on a fast machine it wins, on a loaded CI
    /// runner it does not. Leaving the enrolment to the mock's default connection
    /// failure keeps it at the head of the queue, which is exactly what the queue
    /// assertions are written against.
    private func respondToDownloadOnly(json: String) {
        MockURLProtocol.respond { request in
            guard request.path.contains("/o/sdk") else { return nil }
            guard !request.query.contains("method=ab") else { return nil }
            return (200, Data(json.utf8))
        }
    }

    /// Waits for `completion` to be invoked, failing the test if it never is.
    ///
    /// A remote config call that captures a completion handler and never calls it
    /// leaves the host application waiting for the life of the process, so "it was
    /// called at all" is as much the assertion as what it was called with.
    private func expectCompletion(_ description: String,
                                  timeout: TimeInterval = 5,
                                  _ body: (@escaping () -> Void) -> Void) {
        let expectation = expectation(description: description)
        var fulfilled = false
        body {
            guard !fulfilled else { return }
            fulfilled = true
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }

    // MARK: - Downloading

    func testDownloadingKeysCachesEveryValueTheServerSent() {
        MockURLProtocol.respond(pathContaining: "/o/sdk",
                                json: #"{"colour": "blue", "limit": 7, "on": true}"#)
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { result, error, _, _ in
                XCTAssertEqual(result, .success)
                XCTAssertNil(error)
                done()
            }
        }

        XCTAssertEqual(countly.remoteConfig.getValue("colour").value as? String, "blue")
        XCTAssertEqual(TestUtils.int(countly.remoteConfig.getValue("limit").value), 7)
        XCTAssertEqual(countly.remoteConfig.getAllValues().count, 3)
    }

    /// The request is an instant one on the read endpoint, not a queued report, so
    /// a value the application is waiting for is not stuck behind a backlog.
    func testTheDownloadGoesOutImmediatelyRatherThanThroughTheQueue() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: "{}")
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }

        let requests = MockURLProtocol.requests(pathContaining: "/o/sdk")
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.contains { $0.query.contains("method=rc") })
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "method").isEmpty,
                      "the fetch must not sit in the request queue")
    }

    func testAskingForSpecificKeysNamesThemInTheRequest() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadSpecificKeys(["a", "b"]) { _, _, _, _ in done() }
        }

        guard let request = MockURLProtocol.requests(pathContaining: "/o/sdk").last else {
            XCTFail("a request should have gone out")
            return
        }
        let parsed = TestUtils.parseQuery(request.query)
        XCTAssertEqual(TestUtils.describe(parsed["keys"] ?? ""), "[a,b]")
        XCTAssertNil(parsed["omit_keys"])
    }

    func testOmittingKeysNamesThemInTheRequest() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadOmittingKeys(["secret"]) { _, _, _, _ in done() }
        }

        guard let request = MockURLProtocol.requests(pathContaining: "/o/sdk").last else {
            XCTFail("a request should have gone out")
            return
        }
        let parsed = TestUtils.parseQuery(request.query)
        XCTAssertEqual(TestUtils.describe(parsed["omit_keys"] ?? ""), "[secret]")
        XCTAssertNil(parsed["keys"])
    }

    /// A full download replaces the cache; a partial one merges into it. Getting
    /// that backwards either loses values the server still serves or keeps values
    /// it has withdrawn.
    func testAFullDownloadReplacesTheCacheAndAPartialOneMergesIntoIt() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1, "b": 2}"#)
        let countly = startInstance()

        expectCompletion("the full download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, isFullUpdate, _ in
                XCTAssertTrue(isFullUpdate)
                done()
            }
        }
        XCTAssertEqual(countly.remoteConfig.getAllValues().count, 2)

        MockURLProtocol.reset()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"b": 20, "c": 30}"#)

        expectCompletion("the partial download reports back") { done in
            countly.remoteConfig.downloadSpecificKeys(["b", "c"]) { _, _, isFullUpdate, _ in
                XCTAssertFalse(isFullUpdate)
                done()
            }
        }

        let all = countly.remoteConfig.getAllValues()
        XCTAssertEqual(all.count, 3, "a is still there after a partial update")
        XCTAssertEqual(TestUtils.int(all["b"]?.value), 20)
        XCTAssertEqual(TestUtils.int(all["c"]?.value), 30)
    }

    func testAFailedDownloadReportsAnErrorAndLeavesTheCacheAlone() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        expectCompletion("the first download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }

        MockURLProtocol.reset()  // nothing answers, so the request fails

        expectCompletion("the failed download still reports back") { done in
            countly.remoteConfig.downloadKeys { result, error, _, _ in
                XCTAssertEqual(result, .error)
                XCTAssertNotNil(error)
                done()
            }
        }

        XCTAssertEqual(TestUtils.int(countly.remoteConfig.getValue("a").value), 1,
                       "a failed refresh must not empty the cache")
    }

    // MARK: - Reading values

    /// A key that was never downloaded reads as a nil value. The flag beside it
    /// only means anything once there is a value, which is why it stays true.
    func testAKeyThatWasNeverDownloadedReadsAsAbsent() {
        let countly = startInstance()

        let data = countly.remoteConfig.getValue("never-downloaded")

        XCTAssertNil(data.value)
        XCTAssertTrue(data.isCurrentUsersData)
    }

    func testClearingDiscardsEverythingCached() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }
        XCTAssertEqual(countly.remoteConfig.getAllValues().count, 1)

        countly.remoteConfig.clearAll()

        XCTAssertTrue(countly.remoteConfig.getAllValues().isEmpty)
    }

    /// The cache survives a restart, so an application that launches offline still
    /// gets the values it had last time rather than its hardcoded fallbacks.
    func testTheCacheSurvivesARestart() {
        let name = uniqueInstanceName()
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"colour": "blue"}"#)

        let first = start(baseConfig(instanceName: name))
        expectCompletion("the download reports back") { done in
            first.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }
        first.halt()

        MockURLProtocol.reset()
        let second = start(baseConfig(instanceName: name))

        XCTAssertEqual(second.remoteConfig.getValue("colour").value as? String, "blue")
    }

    // MARK: - Registered callbacks

    /// A global callback hears about every download, which is how an application
    /// re-renders itself when the configuration changes underneath it.
    func testRegisteredCallbacksHearAboutEveryDownload() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        let notified = expectation(description: "the registered callback fires")
        notified.assertForOverFulfill = false
        countly.remoteConfig.registerDownloadCallback { result, _, _, values in
            XCTAssertEqual(result, .success)
            XCTAssertEqual(TestUtils.int(values["a"]?.value), 1)
            notified.fulfill()
        }

        countly.remoteConfig.downloadKeys(completion: nil)
        wait(for: [notified], timeout: 5)
    }

    func testRemovingAllCallbacksStopsTheNotifications() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        var fired = false
        countly.remoteConfig.registerDownloadCallback { _, _, _, _ in fired = true }
        countly.remoteConfig.removeAllDownloadCallbacks()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }

        XCTAssertFalse(fired)
    }

    // MARK: - Enrolling by reading

    /// Reading a value is what makes the device part of the experiment, so the
    /// enrollment is tied to the read rather than to the download.
    func testReadingAValueAndEnrollingAsksToBeEnrolled() {
        respondToDownloadOnly(json: #"{"colour": "blue"}"#)
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }

        let before = requestQueue(of: countly).count
        XCTAssertEqual(countly.remoteConfig.getValueAndEnroll("colour").value as? String, "blue")

        // One snapshot answers both questions: reading the queue twice would let it
        // change between the two reads.
        let queued = requestQueue(of: countly)
        let enrolments = queued
            .map(TestUtils.parseQuery)
            .filter { $0["method"] as? String == "ab" }
        XCTAssertEqual(enrolments.count, 1)
        XCTAssertGreaterThan(queued.count, before)
    }

    /// A key with no value is not an experiment the device is in, so reading it
    /// enrols in nothing.
    func testReadingAMissingValueEnrollsInNothing() {
        let countly = startInstance()
        let before = requestQueue(of: countly).count

        XCTAssertNil(countly.remoteConfig.getValueAndEnroll("never-downloaded").value)

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    func testReadingEveryValueAndEnrollingCoversThemAllAtOnce() {
        respondToDownloadOnly(json: #"{"a": 1, "b": 2}"#)
        let countly = startInstance()

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }

        XCTAssertEqual(countly.remoteConfig.getAllValuesAndEnroll().count, 2)

        let enrolments = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .filter { $0["method"] as? String == "ab" }
        XCTAssertEqual(enrolments.count, 1, "one request covers every key")
    }

    func testReadingEveryValueWithAnEmptyCacheEnrollsInNothing() {
        let countly = startInstance()
        let before = requestQueue(of: countly).count

        XCTAssertTrue(countly.remoteConfig.getAllValuesAndEnroll().isEmpty)

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    // MARK: - Removing one callback

    /// A Swift closure has no identity to compare against, so registering hands
    /// back a token and removing takes it. Removing one leaves the others alone.
    func testOneRegisteredCallbackCanBeRemovedWithoutTouchingTheRest() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        var removedFired = false
        let kept = expectation(description: "the callback that stayed fires")
        kept.assertForOverFulfill = false

        let token = countly.remoteConfig.registerDownloadCallback { _, _, _, _ in removedFired = true }
        countly.remoteConfig.registerDownloadCallback { _, _, _, _ in kept.fulfill() }

        guard let token else {
            XCTFail("registering should have handed back a token")
            return
        }
        countly.remoteConfig.removeDownloadCallback(token)

        countly.remoteConfig.downloadKeys(completion: nil)
        wait(for: [kept], timeout: TestUtils.asyncTimeout)

        XCTAssertFalse(removedFired, "the removed callback must not fire")
    }

    /// Removing with a token that belongs to nothing is a no-op rather than an
    /// error, because the caller may be tearing down twice.
    func testRemovingACallbackTwiceIsHarmless() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)
        let countly = startInstance()

        guard let token = countly.remoteConfig.registerDownloadCallback({ _, _, _, _ in }) else {
            XCTFail("registering should have handed back a token")
            return
        }
        countly.remoteConfig.removeDownloadCallback(token)
        countly.remoteConfig.removeDownloadCallback(token)
    }

    /// A callback supplied at init is registered like any other, so it can be
    /// removed by name along with the rest.
    func testAGlobalCallbackFromTheConfigIsRegisteredAtStart() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"a": 1}"#)

        let notified = expectation(description: "the config callback fires")
        notified.assertForOverFulfill = false
        let countly = startInstance {
            $0.remoteConfigRegisterGlobalCallback { _, _, _, _ in notified.fulfill() }
        }

        countly.remoteConfig.downloadKeys(completion: nil)
        wait(for: [notified], timeout: TestUtils.asyncTimeout)
    }

    // MARK: - A/B testing

    func testEnrollingAndExitingUseTheirOwnMethods() {
        let countly = startInstance()

        countly.remoteConfig.enrollIntoABTests(forKeys: ["experiment-a"])
        countly.remoteConfig.exitABTests(forKeys: ["experiment-a"])

        let queued = requestQueue(of: countly).map(TestUtils.parseQuery)
        XCTAssertTrue(queued.contains { $0["method"] as? String == "ab" })
        XCTAssertTrue(queued.contains { $0["method"] as? String == "ab_opt_out" })
    }

    /// The response shape is an object carrying `jsonArray`, not a bare array. Any
    /// other reading reports every successful download as a failure.
    func testExperimentInformationIsParsedFromTheDocumentedShape() {
        let payload = """
        {"jsonArray": [{"id": "e1", "name": "Colour test", "description": "",
                        "currentVariant": "blue", "variants": {}}]}
        """
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: payload)
        let countly = startInstance()

        expectCompletion("the experiment download reports back") { done in
            countly.remoteConfig.testingDownloadExperimentInformation { result, error in
                XCTAssertEqual(result, .success, "error was \(String(describing: error))")
                done()
            }
        }

        let experiments = countly.remoteConfig.testingGetAllExperimentInfo()
        XCTAssertEqual(experiments["e1"]?.experimentName, "Colour test")
        XCTAssertEqual(experiments["e1"]?.currentVariant, "blue")
    }

    func testVariantsAreDownloadedAndReadBackPerKey() {
        MockURLProtocol.respond(pathContaining: "/o/sdk",
                                json: #"{"colour": ["blue", "green"]}"#)
        let countly = startInstance()

        expectCompletion("the variant download reports back") { done in
            countly.remoteConfig.testingDownloadVariantInformation { result, _ in
                XCTAssertEqual(result, .success)
                done()
            }
        }

        XCTAssertEqual(countly.remoteConfig.testingGetVariants(forKey: "colour").map { "\($0)" },
                       ["blue", "green"])
        XCTAssertEqual(countly.remoteConfig.testingGetAllVariants().count, 1)
    }

    /// Enrolment writes state on the server, so it goes to the input endpoint
    /// rather than the read endpoint the fetches use.
    func testEnrollingIntoAVariantGoesToTheInputEndpoint() {
        MockURLProtocol.respond(pathContaining: "/i", json: #"{"result": "Success"}"#)
        let countly = startInstance()

        expectCompletion("the enrolment reports back") { done in
            countly.remoteConfig.testingEnrollIntoVariant(key: "colour", variantName: "blue") { _, _ in
                done()
            }
        }

        guard let request = MockURLProtocol.requests.last(where: { $0.query.contains("ab_enroll_variant") }) else {
            XCTFail("an enrolment request should have gone out")
            return
        }
        XCTAssertEqual(request.path, "/i")
        let parsed = TestUtils.parseQuery(request.query)
        XCTAssertEqual(parsed["key"] as? String, "colour")
        XCTAssertEqual(parsed["variant"] as? String, "blue")
    }

    func testEnrollingWithAnEmptyKeyOrVariantIsRefused() {
        let countly = startInstance()

        expectCompletion("the empty key reports back") { done in
            countly.remoteConfig.testingEnrollIntoVariant(key: "", variantName: "blue") { result, _ in
                XCTAssertEqual(result, .error)
                done()
            }
        }

        XCTAssertTrue(MockURLProtocol.requests.filter { $0.query.contains("ab_enroll_variant") }.isEmpty)
    }

    // MARK: - Gates

    /// Enrolment is the one testing call that writes state, so an ungated one
    /// would enrol a user who declined remote config.
    func testNothingIsFetchedOrEnrolledWithoutRemoteConfigConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        for (label, call) in [
            ("download", { (done: @escaping () -> Void) in
                countly.remoteConfig.downloadKeys { result, _, _, _ in
                    XCTAssertEqual(result, .error)
                    done()
                }
            }),
            ("variants", { done in
                countly.remoteConfig.testingDownloadVariantInformation { result, _ in
                    XCTAssertEqual(result, .error)
                    done()
                }
            }),
            ("experiments", { done in
                countly.remoteConfig.testingDownloadExperimentInformation { result, _ in
                    XCTAssertEqual(result, .error)
                    done()
                }
            }),
            ("enrolment", { done in
                countly.remoteConfig.testingEnrollIntoVariant(key: "k", variantName: "v") { result, _ in
                    XCTAssertEqual(result, .error)
                    done()
                }
            }),
        ] {
            expectCompletion("the \(label) reports back", call)
        }

        XCTAssertTrue(remoteConfigRequests().isEmpty,
                      "no remote config traffic should have reached the network without consent")
    }

    /// In temporary mode the SDK does not know who the user is, so it must not ask
    /// the server anything about them or write anything against them.
    func testNothingReachesTheNetworkInTemporaryDeviceIDMode() {
        let countly = startInstance { $0.temporaryDeviceIDMode = true }

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { result, _, _, _ in
                XCTAssertEqual(result, .error)
                done()
            }
        }
        expectCompletion("the enrolment reports back") { done in
            countly.remoteConfig.testingEnrollIntoVariant(key: "k", variantName: "v") { result, _ in
                XCTAssertEqual(result, .error)
                done()
            }
        }

        XCTAssertTrue(remoteConfigRequests().isEmpty)
    }

    /// The server's networking kill switch has to reach the instant requests too,
    /// or the one path that bypasses the queue also bypasses the switch.
    func testNothingReachesTheNetworkWhileTheServerHasNetworkingOff() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().networking(false).json()
        }

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { result, _, _, _ in
                XCTAssertEqual(result, .error)
                done()
            }
        }
        expectCompletion("the variant download reports back") { done in
            countly.remoteConfig.testingDownloadVariantInformation { result, _ in
                XCTAssertEqual(result, .error)
                done()
            }
        }

        XCTAssertTrue(remoteConfigRequests().isEmpty)
    }

    // MARK: - Automatic download

    func testAutomaticTriggersDownloadTheConfigAsTheSDKStarts() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"colour": "blue"}"#)

        let countly = startInstance { $0.enableRemoteConfigAutomaticTriggers = true }

        TestUtils.waitUntil("the automatic download lands") {
            countly.remoteConfig.getValue("colour").value != nil
        }
    }

    func testWithoutAutomaticTriggersNothingIsDownloadedAtStart() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: #"{"colour": "blue"}"#)

        _ = startInstance { $0.enableRemoteConfigAutomaticTriggers = false }
        TestUtils.pump(0.3)

        XCTAssertTrue(MockURLProtocol.requests.filter { $0.query.contains("method=rc") }.isEmpty)
    }

    /// A/B enrolment on download is opt in, and it travels as `oi=1` on the fetch
    /// rather than as a request of its own.
    func testEnrollingOnDownloadIsAskedForOnTheFetchItself() {
        MockURLProtocol.respond(pathContaining: "/o/sdk", json: "{}")
        let countly = startInstance { $0.enrollABOnRCDownload = true }

        expectCompletion("the download reports back") { done in
            countly.remoteConfig.downloadKeys { _, _, _, _ in done() }
        }

        guard let request = MockURLProtocol.requests.last(where: { $0.query.contains("method=rc") }) else {
            XCTFail("a fetch should have gone out")
            return
        }
        XCTAssertEqual(TestUtils.parseQuery(request.query)["oi"] as? String, "1")
    }

    // MARK: - Migrating a cache written by the Objective-C SDK

    /// An application replacing the Objective-C Countly SDK with this one keeps the
    /// same `UserDefaults`, so the remote config cache it finds on the first launch
    /// was written by the old SDK in the old shape: archived `CountlyRCData`
    /// objects rather than plain dictionaries.
    ///
    /// Failing to read them is silent. Nothing errors, the cache simply comes back
    /// empty, and every value the application asked for falls back to its default
    /// until the next successful fetch. On a launch with no network that is the
    /// whole session, which is exactly when a cache was supposed to help.
    ///
    /// The stand-in below is archived under the old class's Objective-C name, which
    /// is what `@objc(CountlyRCData)` on `LegacyArchivedRCData` exists to match.
    func testACacheWrittenByThePreviousObjectiveCSDKIsStillReadable() throws {
        let name = uniqueInstanceName()
        let namespace = StorageNamespace(instanceName: name)

        let legacy = LegacyRCStandIn(value: "dark", isCurrentUsersData: true)
        let stale = LegacyRCStandIn(value: 42, isCurrentUsersData: false)

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        // The name the previous SDK wrote, not this one's Swift type name.
        archiver.setClassName("CountlyRCData", for: LegacyRCStandIn.self)
        archiver.encode(["theme": legacy, "seats": stale], forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        UserDefaults.standard.set(archiver.encodedData,
                                  forKey: namespace.key(PersistencyKey.remoteConfig))
        defer { UserDefaults.standard.removeObject(forKey: namespace.key(PersistencyKey.remoteConfig)) }

        let countly = start(baseConfig(instanceName: name))

        XCTAssertEqual(countly.remoteConfig.getValue("theme").value as? String, "dark",
                       "a value cached by the previous SDK was lost on migration")

        // The stale marker has to survive too, or a value belonging to a previous
        // user is silently presented as the current user's.
        XCTAssertEqual(TestUtils.int(countly.remoteConfig.getValue("seats").value), 42)
        XCTAssertFalse(countly.remoteConfig.getValue("seats").isCurrentUsersData,
                       "the stale marker was dropped, so another user's value now reads as this one's")
    }

}

/// Stands in for the Objective-C SDK's `CountlyRCData` when writing a legacy
/// archive. It cannot be the real type: `LegacyArchivedRCData` has only
/// `init?(coder:)`, by design, because nothing in the SDK should ever create one.
// An explicit Objective-C name because `NSCoding` needs a stable one. It is not
// the legacy name: that is applied per archive with `setClassName`, so this type
// cannot collide with the real `@objc(CountlyRCData)`.
@objc(CountlyTestLegacyRCStandIn)
private final class LegacyRCStandIn: NSObject, NSCoding {

    let value: Any?
    let isCurrentUsersData: Bool

    init(value: Any?, isCurrentUsersData: Bool) {
        self.value = value
        self.isCurrentUsersData = isCurrentUsersData
        super.init()
    }

    init?(coder: NSCoder) {
        value = coder.decodeObject(forKey: "value")
        isCurrentUsersData = coder.decodeBool(forKey: "isCurrentUsersData")
        super.init()
    }

    // The key names are the ones the previous SDK encoded under.
    func encode(with coder: NSCoder) {
        coder.encode(value, forKey: "value")
        coder.encode(isCurrentUsersData, forKey: "isCurrentUsersData")
    }
}
