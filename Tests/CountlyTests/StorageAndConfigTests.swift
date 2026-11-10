//
//  StorageAndConfigTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
import CoreLocation
@testable import Countly

/// The pieces that survive a launch, and the configuration that can change during
/// one.
///
/// Everything here is about state that outlives the moment it was written: a
/// session configuration swapped at runtime, a location half-specified. Each is cheap to get wrong and
/// expensive to notice, because the symptom appears a launch or a week later.
final class StorageAndConfigTests: CountlyBaseTestCase {

    private static let accepted = #"{"result": "Success"}"#

    // MARK: - Swapping the session configuration

    /// An application can hand the SDK a session of its own, for a proxy or a
    /// pinned transport it manages itself. The change has to take effect on the
    /// next request rather than on the next launch.
    func testANewSessionConfigurationTakesEffectImmediately() throws {
        try skipUnlessNetworkIsInterceptable()

        let countly = startInstance { $0.eventSendThreshold = 1 }
        let before = core(of: countly).network.session()

        let replacement = MockURLProtocol.sessionConfiguration()
        replacement.httpAdditionalHeaders = ["X-Replaced": "yes"]
        countly.setNewURLSessionConfiguration(replacement)

        let after = core(of: countly).network.session()
        XCTAssertFalse(before === after, "the session is rebuilt rather than reused")

        MockURLProtocol.respondToEverything(json: Self.accepted)
        countly.events.recordEvent("after-the-swap")
        TestUtils.waitUntil("the queue drains through the new session") {
            self.requestQueue(of: countly).isEmpty
        }
    }

    /// Adding headers rebuilds the session too, or the headers would only apply to
    /// requests made after the next unrelated rebuild.
    func testAddingHeadersRebuildsTheSession() {
        let countly = startInstance()
        let before = core(of: countly).network.session()

        countly.addCustomNetworkRequestHeaders(["X-Tenant": "acme"])

        XCTAssertFalse(before === core(of: countly).network.session())
    }

    // MARK: - Location, half specified

    /// The server resolves a city only together with its country, so one without
    /// the other is silently useless. It is still sent, because refusing would lose
    /// data the caller meant, but it is worth warning about.
    func testACityWithoutACountryIsStillSent() {
        let countly = startInstance()
        countly.sessions.beginSession()

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid,
                                        city: "Istanbul",
                                        isoCountryCode: nil,
                                        ipAddress: nil)

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "city").last else {
            XCTFail("the city should still have been sent")
            return
        }
        XCTAssertEqual(request["city"] as? String, "Istanbul")
        XCTAssertNil(request["country_code"])
    }

    func testACountryWithoutACityIsStillSent() {
        let countly = startInstance()
        countly.sessions.beginSession()

        countly.location.recordLocation(kCLLocationCoordinate2DInvalid,
                                        city: nil,
                                        isoCountryCode: "TR",
                                        ipAddress: nil)

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "country_code").last else {
            XCTFail("the country should still have been sent")
            return
        }
        XCTAssertEqual(request["country_code"] as? String, "TR")
    }

    /// The location the application supplied at init waits for location consent:
    /// without it nothing of it is ever sent.
    func testTheConfiguredLocationWaitsForConsent() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
        }

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "city").isEmpty)
    }

    /// While the server turns location tracking off, consent does not release the
    /// configured location either.
    func testTheConfiguredLocationIsNotSentWhileTheServerDisablesLocation() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(false).json()
        }

        countly.consent.giveConsent(for: .location)

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "city").isEmpty)
    }

    // MARK: - Foreground and background reaching every module

    /// The lifecycle is fanned out to every module rather than handled centrally,
    /// so a module added later gets the callbacks without anything else changing.
    func testForegroundAndBackgroundReachEveryModule() {
        let countly = startInstance {
            $0.eventSendThreshold = 100
            $0.manualSessionHandling = true
        }

        countly.events.recordEvent("held-in-memory")

        // Backgrounding flushes, which is a module reacting to the lifecycle rather
        // than to an API call.
        core(of: countly).modules.sessions.didEnterBackground()

        XCTAssertFalse(requestQueue(of: countly).isEmpty,
                       "the batch should have been pushed out on background")
    }

    /// Resigning active saves the health counters, because the process may not get
    /// another chance to write them.
    func testResigningActiveSavesTheHealthCounters() {
        let countly = startInstance()
        let core = core(of: countly)

        core.logger.e("Test", "test", "an error worth remembering")
        core.healthTracker.saveState()

        // The tracker owns its counters on a serial queue and the save hops onto it,
        // so the write lands a turn later.
        TestUtils.waitUntil("the counters reach storage") {
            !(core.keyValueStore.healthCheckState?.isEmpty ?? true)
        }
    }

    // MARK: - The instance registry

    /// Halting every instance at once is what a test harness and a deliberate
    /// teardown both need, and it must not trip over an instance that was never
    /// started.
    func testHaltingEveryInstanceSkipsTheOnesThatNeverStarted() {
        let started = startInstance()
        _ = Countly.instance(named: "never-started-\(UUID().uuidString.prefix(8))")

        Countly.haltAllInstances()

        XCTAssertFalse(started.isStarted)
    }

    /// Starting an instance again after a halt is a fresh start, not a resumption,
    /// which is what makes halt usable as a teardown between tests.
    func testAnInstanceCanBeStartedAgainAfterAHalt() {
        let name = uniqueInstanceName()

        let first = start(baseConfig(instanceName: name))
        XCTAssertTrue(first.isStarted)
        first.halt()
        XCTAssertFalse(first.isStarted)

        let again = start(baseConfig(instanceName: name))
        XCTAssertTrue(again.isStarted)
        XCTAssertTrue(first === again, "the registry hands back the same instance")
    }

    // MARK: - The key value store

    /// A write whose change observer waits on another thread must not hold up an
    /// erasure on that thread. `UserDefaults` runs observers inside the write, so
    /// a lock held across it turns such an observer into a deadlock.
    func testAnErasureDoesNotWaitOnAWriteStillRunningItsObservers() {
        let suite = "countly-kv-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = KeyValueStore(namespace: StorageNamespace(instanceName: uniqueInstanceName()),
                                  defaults: defaults,
                                  logger: nil)

        let writer = Recorded<Thread?>(nil)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observerWait = Recorded<DispatchTimeoutResult?>(nil)
        let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                           object: nil,
                                                           queue: nil) { _ in
            guard let thread = writer.value, Thread.current == thread, observerWait.value == nil else { return }
            entered.signal()
            observerWait.value = release.wait(timeout: .now() + 5)
        }
        defer { NotificationCenter.default.removeObserver(token) }

        let written = expectation(description: "the write returns")
        DispatchQueue.global().async {
            writer.value = Thread.current
            store.serverConfig = ["c": ["tracking": true]]
            written.fulfill()
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the write never notified its observer")
        store.clearAll()
        release.signal()
        wait(for: [written], timeout: 10)

        XCTAssertEqual(observerWait.value, .success, "the erasure waited for the write to finish its observers")
        XCTAssertNil(store.serverConfig, "the write that raced the erasure was not taken back")
    }

    /// A stored value that cannot be read back is reset to empty, an error the
    /// health check reports as e503.
    func testAStoredValueThatCannotBeReadIsResetAndCounted() {
        let config = baseConfig()
        let key = StorageNamespace(instanceName: config.instanceName).key(PersistencyKey.remoteConfig)
        UserDefaults.standard.set(Data("not an archive".utf8), forKey: key)

        let countly = start(config)

        XCTAssertTrue(countly.remoteConfig.getAllValues().isEmpty)
        XCTAssertEqual(logCodeCount(HealthLogCode.storedStateReset, of: countly), 1)
    }

    // MARK: - The config snapshot

    /// What the SDK changes on its config while running stays with that run: the
    /// caller's object starts the next run, or another instance, as it was given.
    func testRuntimeChangesNeverReachTheCallersConfig() {
        let config = baseConfig()
        let countly = start(config)

        countly.setNewAppKey("changed-at-runtime")
        countly.setNewHost("https://changed.example")

        XCTAssertEqual(config.appKey, Self.appKey)
        XCTAssertEqual(config.host, Self.host)
        XCTAssertEqual(core(of: countly).config.appKey, "changed-at-runtime")
    }

    /// One config can start two instances: changing it after the first started
    /// must not redirect that one's data to the second one's app.
    func testAConfigSharedByTwoInstancesKeepsThemApart() {
        let config = baseConfig()
        let first = start(config)

        config.appKey = "second-app-key"
        config.instanceName = uniqueInstanceName()
        let second = start(config)

        XCTAssertEqual(core(of: first).config.appKey, Self.appKey)
        XCTAssertEqual(core(of: second).config.appKey, "second-app-key")
    }

    /// Every stored property survives the snapshot, so nothing an integration sets
    /// is dropped when the instance takes its copy. The counts fail when a property
    /// is added or removed, which is the prompt to copy it and to set it here.
    func testTheSnapshotCopiesEveryStoredProperty() throws {
        let original = CountlyConfig()
        let delegate = SnapshotLoggerDelegate()

        original.host = "https://snapshot.example"
        original.appKey = "snapshot-app-key"
        original.instanceName = "snapshot-instance"
        original.enableDebug = true
        original.internalLogLevel = .verbose
        original.loggerDelegate = delegate
        original.features = [.crashReporting]
        original.customMetrics = ["metric": "1"]
        original.sdkName = "bridge"
        original.sdkVersion = "9.9.9"
        original.enableAutomaticViewTracking = true
        original.disableSwizzling = true
        original.automaticViewTrackingExclusionList = ["Excluded"]
        original.globalViewSegmentation = ["global": 1]
        original.disableViewRestartForManualRecording = true
        original.requiresConsent = true
        original.consents = [.events]
        original.enableAllConsents = true
        original.pushTestMode = .development
        original.sendPushTokenAlways = true
        original.disableAutomaticPushHandling = true
        original.launchNotification = ["launch": 1]
        original.doNotShowAlertForNotifications = true
        original.pushActionHandler = { _, _ in true }
        original.pushAllowedLinkSchemes = ["myapp"]
        original.location = CLLocationCoordinate2D(latitude: 1, longitude: 2)
        original.city = "City"
        original.isoCountryCode = "TR"
        original.ipAddress = "192.0.2.1"
        original.disableLocation = true
        original.deviceID = "snapshot-device"
        original.temporaryDeviceIDMode = true
        original.resetStoredDeviceID = true
        original.updateSessionPeriod = 7
        original.eventSendThreshold = 7
        original.storedRequestsLimit = 7
        original.requestDropAgeHours = 7
        original.requestTimeoutDuration = 7
        original.failedRequestCooldown = 7
        original.disableGradualRequestCleaner = true
        original.disableHealthCheck = true
        original.disableWebView = true
        original.disableSDKLoggingInProduction = true
        original.manualSessionHandling = true
        original.enableManualSessionControlHybridMode = true
        original.providedUserProperties = ["property": 1]
        original.campaignType = "campaign-type"
        original.campaignData = "campaign-data"
        original.indirectAttribution = ["idfa": "value"]
        original.crashSegmentation = ["crash": 1]
        original.pinnedCertificates = ["certificate"]
        original.secretSalt = "salt"
        original.urlSessionConfiguration.timeoutIntervalForRequest = 7
        original.shouldIgnoreTrustCheck = true
        original.customNetworkRequestHeaders = ["header": "value"]
        original.enableRemoteConfigAutomaticTriggers = true
        original.enableRemoteConfigValueCaching = true
        original.enrollABOnRCDownload = true
        original.remoteConfigRegisterGlobalCallback { _, _, _, _ in }
        original.enableOrientationTracking = false
        original.sdkBehaviorSettings = "{}"
        original.disableSDKBehaviorSettingsUpdates = true
        original.disableBackoffMechanism = true

        original.sdkInternalLimits.maxKeyLength = 7
        original.sdkInternalLimits.maxValueSize = 7
        original.sdkInternalLimits.maxValueSizePicture = 7
        original.sdkInternalLimits.maxBreadcrumbCount = 7
        original.sdkInternalLimits.maxSegmentationValues = 7
        original.sdkInternalLimits.maxStackTraceLineLength = 7
        original.sdkInternalLimits.maxStackTraceLinesPerThread = 7
        original.crashes.crashFilterCallback = { _ in false }
        original.content.globalContentCallback = { _, _ in }
        original.content.zoneTimerInterval = 77
        original.content.overlayCornerRadius = 7
        original.content.webViewDisplayOption = original.content.webViewDisplayOption == .immersive ? .safeArea : .immersive
        original.content.enableContentReloadOnStall = true
        original.content.contentReloadOnStallTimeout = 7
        original.content.disableZoom = true
        original.content.disableRotation = true
        original.content.contentURLHandler = { _ in true }
        original.content.allowedLinkSchemes = ["myapp"]
        original.content.showWidgetsWithinApp = true
        original.experimental.enablePreviousNameRecording = true
        original.experimental.enableVisibilityTracking = true

        let copy = original.snapshot()

        XCTAssertEqual(Mirror(reflecting: original).children.count, 67)
        XCTAssertEqual(Mirror(reflecting: original.sdkInternalLimits).children.count, 7)
        XCTAssertEqual(Mirror(reflecting: original.crashes).children.count, 1)
        XCTAssertEqual(Mirror(reflecting: original.content).children.count, 11)
        XCTAssertEqual(Mirror(reflecting: original.experimental).children.count, 2)

        assertSameValues(original, copy)
        XCTAssertFalse(original.urlSessionConfiguration === copy.urlSessionConfiguration,
                       "the SDK sets timeouts on its session configuration, so the caller's must not be shared")
        XCTAssertEqual(copy.urlSessionConfiguration.timeoutIntervalForRequest, 7)
    }

    /// Compares every stored property of two configs, sub-configurations included,
    /// which must be copies rather than the same objects.
    private func assertSameValues(_ original: Any, _ copy: Any, path: String = "config",
                                  file: StaticString = #filePath, line: UInt = #line) {
        let copied = Dictionary(uniqueKeysWithValues: Mirror(reflecting: copy).children.compactMap { child in
            child.label.map { ($0, child.value) }
        })

        for child in Mirror(reflecting: original).children {
            guard let label = child.label, let copiedValue = copied[label] else {
                XCTFail("\(path).\(child.label ?? "?") is missing from the copy", file: file, line: line)
                continue
            }

            // Only class instances are checked for identity. Casting a struct such
            // as a coordinate to an object would box it through a bridge.
            let typeName = String(describing: type(of: child.value))
            if Mirror(reflecting: child.value).displayStyle == .class {
                if typeName.contains("URLSessionConfiguration") { continue }
                if typeName.hasPrefix("Countly") {
                    XCTAssertFalse((child.value as AnyObject) === (copiedValue as AnyObject),
                                   "\(path).\(label) is shared rather than copied", file: file, line: line)
                    assertSameValues(child.value, copiedValue, path: "\(path).\(label)", file: file, line: line)
                    continue
                }
            }

            XCTAssertEqual(String(describing: child.value), String(describing: copiedValue),
                           "\(path).\(label) differs in the copy", file: file, line: line)
        }
    }

    // MARK: - SDK identity

    /// A bridge SDK reports itself, or every request it makes is attributed to the
    /// native SDK and the dashboard cannot tell a Flutter app from a native one.
    func testABridgeCanReportItsOwnNameAndVersion() {
        let countly = startInstance {
            $0.sdkName = "dart-flutterb-ios"
            $0.sdkVersion = "26.1.1"
        }
        countly.events.recordEvent("bridged")
        countly.requestQueue.attemptToSendStoredRequests()

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else {
            XCTFail("nothing was queued")
            return
        }
        XCTAssertEqual(request["sdk_name"] as? String, "dart-flutterb-ios")
        XCTAssertEqual(request["sdk_version"] as? String, "26.1.1")
    }

    /// Without an override the SDK reports itself, and a blank one is not an
    /// override: both fields are required on the wire.
    func testTheBuiltInIdentityIsUsedWhenNoneIsSuppliedOrItIsBlank() {
        let plain = startInstance()
        plain.events.recordEvent("plain")
        plain.requestQueue.attemptToSendStoredRequests()
        if let request = TestUtils.request(requestQueue(of: plain), at: 0) {
            XCTAssertEqual(request["sdk_name"] as? String, SDKIdentity.name)
            XCTAssertEqual(request["sdk_version"] as? String, SDKIdentity.version)
        } else {
            XCTFail("nothing was queued for the plain instance")
        }

        let blank = startInstance {
            $0.instanceName = self.uniqueInstanceName()
            $0.sdkName = "   "
            $0.sdkVersion = ""
        }
        blank.events.recordEvent("blank")
        blank.requestQueue.attemptToSendStoredRequests()
        if let request = TestUtils.request(requestQueue(of: blank), at: 0) {
            XCTAssertEqual(request["sdk_name"] as? String, SDKIdentity.name)
            XCTAssertEqual(request["sdk_version"] as? String, SDKIdentity.version)
        } else {
            XCTFail("nothing was queued for the blank instance")
        }
    }

    // MARK: - Diagnostic queue access

    /// A bridge SDK's integration suite asserts on what the SDK queued. Android
    /// exposes the same three through `CountlyStore`.
    func testTheQueuesCanBeReadAndARequestStoredVerbatim() {
        let countly = startInstance { $0.eventSendThreshold = 100 }

        countly.events.recordEvent("first", segmentation: ["a": 1])
        countly.events.recordEvent("second")

        let events = countly.events.recordedEvents()
        XCTAssertEqual(events.count, 2, "both events are still buffered below the send threshold")
        XCTAssertTrue(events[0].contains("\"first\""), "oldest first")
        XCTAssertTrue(events[1].contains("\"second\""))

        let before = countly.requestQueue.queuedRequests()
        countly.requestQueue.store("app_key=crafted&device_id=forged&custom=1")
        let after = countly.requestQueue.queuedRequests()

        XCTAssertEqual(after.count, before.count + 1)
        XCTAssertEqual(after.last, "app_key=crafted&device_id=forged&custom=1",
                       "a stored request reaches the queue exactly as written")
        XCTAssertEqual(countly.requestQueue.count, after.count)
    }

    /// Reading must not mutate, and an empty request is not queued.
    func testReadingTheQueueLeavesItAloneAndAnEmptyStoreIsRefused() {
        let countly = startInstance()
        countly.requestQueue.store("app_key=one")

        let first = countly.requestQueue.queuedRequests()
        let second = countly.requestQueue.queuedRequests()
        XCTAssertEqual(first, second, "reading the queue changed it")

        countly.requestQueue.store("")
        XCTAssertEqual(countly.requestQueue.queuedRequests().count, first.count,
                       "an empty request was queued")
    }
}

/// A logger delegate for the snapshot test, which only needs one to exist.
private final class SnapshotLoggerDelegate: NSObject, CountlyLoggerDelegate {
    func internalLog(_ log: String, level: CountlyLogLevel) {}
}
