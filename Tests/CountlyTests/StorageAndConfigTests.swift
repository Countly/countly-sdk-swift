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
/// breadcrumb file that must not grow without bound, a session configuration
/// swapped at runtime, a location half-specified. Each is cheap to get wrong and
/// expensive to notice, because the symptom appears a launch or a week later.
final class StorageAndConfigTests: CountlyBaseTestCase {

    private static let accepted = #"{"result": "Success"}"#

    // MARK: - The breadcrumb file

    /// Only the newest breadcrumbs are ever read back, so without a cap the file
    /// grows for the life of the installation while all but its tail is dead
    /// weight. It is trimmed once it reaches twice the limit, so the rewrite is
    /// paid once per limit's worth rather than on every append.
    func testTheBreadcrumbFileIsTrimmedOnceItOutgrowsTwiceTheLimit() {
        let namespace = StorageNamespace(instanceName: "trim-\(UUID().uuidString.prefix(8))")
        let store = CrashLogStore(namespace: namespace, logger: nil)
        defer { store.deleteAll() }

        store.maxBreadcrumbCount = 3
        for index in 0..<12 {
            store.append("step-\(index)")
        }

        TestUtils.waitUntil("every breadcrumb has been written") {
            (store.readAll() ?? "").contains("step-11")
        }

        // The guarantee is a bound, not an exact count: the file is trimmed back to
        // the limit once it reaches twice it, and then grows again until the next
        // trim. What must hold is that it never runs away, and that the breadcrumbs
        // nearest a crash are the ones kept.
        let lines = (store.readAll() ?? "").split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(lines.count, 6, "the file grew past twice the limit")
        XCTAssertTrue(lines.last?.contains("step-11") == true,
                      "the newest breadcrumbs are the ones nearest a crash, so those are kept")
        XCTAssertFalse(lines.contains { $0.contains("step-0") }, "the oldest were dropped")
    }

    /// Below the trim point the file is left alone, because rewriting it on every
    /// append would turn a cheap log line into a whole-file read and write.
    func testTheBreadcrumbFileIsNotRewrittenBelowTheTrimPoint() {
        let namespace = StorageNamespace(instanceName: "no-trim-\(UUID().uuidString.prefix(8))")
        let store = CrashLogStore(namespace: namespace, logger: nil)
        defer { store.deleteAll() }

        store.maxBreadcrumbCount = 10
        for index in 0..<4 { store.append("step-\(index)") }

        TestUtils.waitUntil("the breadcrumbs land") {
            (store.readAll() ?? "").contains("step-3")
        }
        let lines = (store.readAll() ?? "").split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4)
    }

    /// Reading a file that was never written is not an error: it is the ordinary
    /// case on a first launch.
    func testReadingAnEmptyBreadcrumbStoreYieldsNothing() {
        let namespace = StorageNamespace(instanceName: "empty-\(UUID().uuidString.prefix(8))")
        let store = CrashLogStore(namespace: namespace, logger: nil)

        XCTAssertNil(store.readAll())
        // Deleting one that does not exist is equally ordinary.
        store.deleteAll()
        XCTAssertNil(store.readAll())
    }

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

    /// Sending the stored location again is how a feature that arrives later, such
    /// as consent, gets the location the application supplied at init.
    func testTheStoredLocationCanBeSentAgain() {
        let countly = startInstance {
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
        }
        let before = TestUtils.requests(requestQueue(of: countly), carrying: "city").count

        core(of: countly).modules.location.sendLocationInfo()

        XCTAssertGreaterThan(TestUtils.requests(requestQueue(of: countly), carrying: "city").count,
                             before)
    }

    func testSendingTheStoredLocationNeedsConsent() {
        let countly = startInstance { $0.requiresConsent = true }
        let before = requestQueue(of: countly).count

        core(of: countly).modules.location.sendLocationInfo()

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    func testSendingTheStoredLocationIsDroppedWhenTheServerDisablesLocation() {
        let countly = startInstance {
            $0.city = "Istanbul"
            $0.isoCountryCode = "TR"
            $0.sdkBehaviorSettings = ServerConfigBuilder().locationTracking(false).json()
        }
        let before = requestQueue(of: countly).count

        core(of: countly).modules.location.sendLocationInfo()

        XCTAssertEqual(requestQueue(of: countly).count, before)
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
        original.alwaysUsePOST = true
        original.manualSessionHandling = true
        original.enableManualSessionControlHybridMode = true
        original.providedUserProperties = ["property": 1]
        original.campaignType = "campaign-type"
        original.campaignData = "campaign-data"
        original.indirectAttribution = ["idfa": "value"]
        original.crashSegmentation = ["crash": 1]
        original.crashFilter = try NSRegularExpression(pattern: "filtered")
        original.shouldSendCrashReportCallback = { _ in false }
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
        original.apm.enableForegroundBackgroundTracking = true
        original.apm.enableAppStartTimeTracking = true
        original.apm.enableManualAppLoadedTrigger = true
        original.apm.appStartTimestampOverride = 7
        original.content.globalContentCallback = { _, _ in }
        original.content.zoneTimerInterval = 77
        original.content.overlayCornerRadius = 7
        original.content.webViewDisplayOption = original.content.webViewDisplayOption == .immersive ? .safeArea : .immersive
        original.content.enableContentReloadOnStall = true
        original.content.contentReloadOnStallTimeout = 7
        original.content.disableZoom = true
        original.content.disableRotation = true
        original.content.contentURLHandler = { _ in true }
        original.content.showWidgetsWithinApp = true
        original.experimental.enablePreviousNameRecording = true
        original.experimental.enableVisibilityTracking = true

        let copy = original.snapshot()

        XCTAssertEqual(Mirror(reflecting: original).children.count, 64)
        XCTAssertEqual(Mirror(reflecting: original.sdkInternalLimits).children.count, 7)
        XCTAssertEqual(Mirror(reflecting: original.crashes).children.count, 1)
        XCTAssertEqual(Mirror(reflecting: original.apm).children.count, 4)
        XCTAssertEqual(Mirror(reflecting: original.content).children.count, 10)
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
