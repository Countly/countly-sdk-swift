//
//  MultiInstanceTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Several SDKs in one process, and the lifecycle of any one of them.
///
/// This is the feature that separates this SDK from the one it was ported from:
/// the reference keeps its logger, clock, queue and device ID in process-wide
/// singletons, so a second instance is not possible. Here every one of those is per
/// instance, and what these check is that no state at all leaks across the
/// boundary.
final class MultiInstanceTests: CountlyBaseTestCase {

    // MARK: - The registry

    func testAskingForTheSameNameTwiceReturnsTheSameInstance() {
        let first = Countly.instance(named: "registry-stability")
        let second = Countly.instance(named: "registry-stability")

        XCTAssertTrue(first === second)
    }

    /// Getting a handle must never start the SDK. An accidental reference cannot
    /// be allowed to begin collecting data.
    func testGettingAnInstanceNeverStartsIt() {
        let countly = Countly.instance(named: "never-auto-started")

        XCTAssertFalse(countly.isStarted)
    }

    func testGetInstanceNeverCreatesOne() {
        XCTAssertNil(Countly.getInstance(named: "definitely-never-created-\(UUID().uuidString)"))
    }

    /// A name that failed to load must not quietly become the default instance,
    /// which would report one tenant's data into another tenant's dashboard.
    func testAnEmptyNameIsRefusedRatherThanReadAsTheDefaultInstance() {
        let refused = Countly.instance(named: "")

        XCTAssertFalse(refused === Countly.shared)
        XCTAssertNil(Countly.getInstance(named: ""), "nothing is registered under an empty name")

        refused.start(with: baseConfig())

        XCTAssertFalse(refused.isStarted, "started, it would run a second SDK over the default instance's storage")
    }

    /// A facade taken from the refused handle stays attached to it, so its calls
    /// report the empty name rather than a removal that never happened.
    func testAFacadeOfTheRefusedInstanceStaysAttachedToIt() {
        let events = Countly.instance(named: "").events

        XCTAssertTrue(events.instance === Countly.instance(named: ""))
        events.recordEvent("ignored")
    }

    func testListingInstancesExcludesTheDefaultOne() {
        _ = Countly.instance(named: "listed-instance")

        XCTAssertTrue(Countly.listInstances().contains("listed-instance"))
        XCTAssertFalse(Countly.listInstances().contains(Countly.defaultInstanceName))
    }

    // MARK: - Isolation

    /// Two instances reporting to two app keys must not see each other's requests.
    /// A leak here would send one tenant's data to the other's dashboard.
    func testTwoInstancesKeepSeparateRequestQueues() {
        let firstConfig = baseConfig()
        firstConfig.appKey = "app-one"
        firstConfig.eventSendThreshold = 1
        let first = start(firstConfig)

        let secondConfig = baseConfig()
        secondConfig.appKey = "app-two"
        secondConfig.eventSendThreshold = 1
        let second = start(secondConfig)

        first.events.recordEvent("only-in-the-first")
        second.events.recordEvent("only-in-the-second")

        let firstQueue = requestQueue(of: first).map(TestUtils.parseQuery)
        let secondQueue = requestQueue(of: second).map(TestUtils.parseQuery)

        XCTAssertTrue(firstQueue.allSatisfy { $0["app_key"] as? String == "app-one" })
        XCTAssertTrue(secondQueue.allSatisfy { $0["app_key"] as? String == "app-two" })

        let firstKeys = firstQueue.compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }.compactMap { $0["key"] as? String }
        XCTAssertEqual(firstKeys, ["only-in-the-first"])
    }

    func testTwoInstancesKeepSeparateDeviceIDs() {
        let firstConfig = baseConfig()
        firstConfig.deviceID = "user-one"
        let first = start(firstConfig)

        let secondConfig = baseConfig()
        secondConfig.deviceID = "user-two"
        let second = start(secondConfig)

        XCTAssertEqual(first.deviceID.current, "user-one")
        XCTAssertEqual(second.deviceID.current, "user-two")

        first.deviceID.changeWithMerge("user-one-renamed")
        XCTAssertEqual(second.deviceID.current, "user-two",
                       "changing one instance's identity must not touch the other's")
    }

    func testTwoInstancesKeepSeparateConsent() {
        let firstConfig = baseConfig()
        firstConfig.requiresConsent = true
        let first = start(firstConfig)

        let secondConfig = baseConfig()
        secondConfig.requiresConsent = true
        let second = start(secondConfig)

        first.consent.giveAllConsents()

        XCTAssertTrue(first.consent.hasConsent(for: .events))
        XCTAssertFalse(second.consent.hasConsent(for: .events))
    }

    /// The clock is per instance for a specific reason: it never repeats a
    /// timestamp, so a burst on a shared clock would push another instance's
    /// timestamps into the future.
    func testABurstOnOneInstanceDoesNotPushTheOthersClockForward() {
        let busy = startInstance { $0.eventSendThreshold = 1000 }
        let quiet = startInstance { $0.eventSendThreshold = 1 }

        let before = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<3000 {
            busy.events.recordEvent("burst-\(index)")
        }

        quiet.events.recordEvent("after-the-burst")

        guard let request = TestUtils.request(requestQueue(of: quiet), at: 0) else { return }
        let timestamp = TestUtils.int64(TestUtils.events(in: request)[0]["timestamp"]) ?? 0

        XCTAssertLessThan(timestamp - before, 60_000,
                          "the quiet instance's clock should be near real time, not dragged forward")
    }

    // MARK: - Lifecycle

    func testStartingAnAlreadyStartedInstanceIsIgnored() {
        let config = baseConfig()
        let countly = start(config)
        countly.events.recordEvent("before")
        let before = requestQueue(of: countly).count

        countly.start(with: config)

        XCTAssertTrue(countly.isStarted)
        XCTAssertEqual(requestQueue(of: countly).count, before,
                       "a restart would have torn down a queue that is still in flight")
    }

    func testCallsBeforeStartAreIgnoredRatherThanCrashing() {
        let countly = Countly.instance(named: "used-before-start-\(UUID().uuidString.prefix(8))")

        XCTAssertFalse(countly.isStarted)
        countly.events.recordEvent("too early")
        countly.views.startView("Too early")
        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.save()
        countly.sessions.beginSession()

        XCTAssertFalse(countly.isStarted)
    }

    func testHaltStopsTheInstanceAndCallsAfterwardsAreIgnored() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("before the halt")

        countly.halt()

        XCTAssertFalse(countly.isStarted)
        countly.events.recordEvent("after the halt")
    }

    /// Removing an instance stops it and forgets the name, so the next request under
    /// that name gets a fresh, unstarted instance. Stored data is kept.
    func testRemoveInstanceStopsAndForgetsANamedInstance() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let name = countly.name
        countly.events.recordEvent("before removal")

        Countly.removeInstance(named: name)

        XCTAssertFalse(countly.isStarted)
        XCTAssertNil(Countly.getInstance(named: name))
        XCTAssertFalse(Countly.instance(named: name) === countly, "the name now yields a new instance")

        // The removed handle may not erase the storage, the fresh one may.
        Countly.instance(named: name).halt(clearStorage: true)
    }

    /// A facade the application kept must not take it down once the instance it
    /// came from is removed and released: the call is ignored instead.
    func testAFacadeKeptPastRemovalIgnoresCallsRatherThanCrashing() {
        let name = uniqueInstanceName()
        weak var removed: CountlyInstance?
        let events: EventsAPI = autoreleasepool {
            let countly = Countly.instance(named: name)
            removed = countly
            return countly.events
        }

        autoreleasepool {
            Countly.removeInstance(named: name)
        }

        XCTAssertNil(removed, "nothing holds a removed instance any more")
        events.recordEvent("after removal")
    }

    func testTheDefaultInstanceCannotBeRemoved() {
        let shared = Countly.shared

        Countly.removeInstance(named: Countly.defaultInstanceName)

        XCTAssertTrue(Countly.getInstance(named: Countly.defaultInstanceName) === shared)
    }

    /// A halt with `clearStorage` has to leave the next start looking like a first
    /// install, which is what makes it usable for a "delete my data" flow.
    func testHaltWithClearStorageLeavesNothingBehind() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = "to-be-erased"
        firstConfig.eventSendThreshold = 1000
        let first = start(firstConfig)
        first.events.recordEvent("to-be-erased")
        first.halt(clearStorage: true)

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = "a-fresh-start"
        let second = start(secondConfig)

        XCTAssertEqual(second.deviceID.current, "a-fresh-start",
                       "the erased device ID must not come back")
        XCTAssertTrue(requestQueue(of: second).isEmpty,
                      "the erased queue must not come back")
    }

    /// The erasure has to hold against the halted instance itself: a completion
    /// still in flight when the halt ran writes through the old store, and that
    /// write must not hand the next start the erased state back.
    func testAWriteLeftInFlightByAHaltedInstanceCannotUndoClearStorage() {
        let name = uniqueInstanceName()
        let first = start(baseConfig(instanceName: name))
        let haltedStore = core(of: first).keyValueStore

        first.halt(clearStorage: true)
        haltedStore.deviceID = "written-after-the-erasure"
        // In the shape the remote config cache reads back, so a write that landed
        // would be served to the next start rather than discarded as unreadable.
        haltedStore.remoteConfig = ["written": ["v": "after the erasure", "c": true]]

        let second = start(baseConfig(instanceName: name))

        XCTAssertEqual(second.deviceID.current, Self.deviceID,
                       "a stored device ID wins over the configured one, so none may be left behind")
        XCTAssertTrue(core(of: second).keyValueStore.remoteConfig.isEmpty)
    }

    /// An ordinary halt is not a delete: the queue is written out so the data is
    /// still sent on the next launch.
    func testAnOrdinaryHaltKeepsWhatWasQueued() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.eventSendThreshold = 1
        let first = start(firstConfig)
        first.events.recordEvent("must survive")
        XCTAssertFalse(requestQueue(of: first).isEmpty)
        first.halt()

        let second = start(baseConfig(instanceName: name))

        XCTAssertFalse(requestQueue(of: second).isEmpty,
                       "an ordinary halt must not lose data the server has not accepted")
    }

    /// An erasure is asked for when the user wants their data gone, which can be
    /// before the SDK was started this launch or after it was halted.
    func testClearStorageErasesAnInstanceThatIsNotRunning() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.deviceID = "to-be-erased"
        firstConfig.eventSendThreshold = 1
        let first = start(firstConfig)
        first.events.recordEvent("to-be-erased")
        first.halt()

        first.halt(clearStorage: true)

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.deviceID = "a-fresh-start"
        let second = start(secondConfig)

        XCTAssertEqual(second.deviceID.current, "a-fresh-start",
                       "the erased device ID must not come back")
        XCTAssertTrue(requestQueue(of: second).isEmpty,
                      "the erased queue must not come back")
    }

    /// A handle kept past `removeInstance(named:)` can no longer be started: next
    /// to the instance the registry made since, it would be a second SDK on the
    /// same storage, sending the same requests twice and wiping the other's files.
    func testAHandleKeptPastRemovalCanNeitherStartNorErase() {
        let name = uniqueInstanceName()
        let removed = start(baseConfig(instanceName: name))
        Countly.removeInstance(named: name)

        let current = start(baseConfig(instanceName: name))
        removed.start(with: baseConfig(instanceName: name))

        XCTAssertFalse(removed.isStarted)
        XCTAssertTrue(current.isStarted)

        removed.halt(clearStorage: true)

        XCTAssertEqual(core(of: current).keyValueStore.deviceID, Self.deviceID,
                       "the removed handle must not erase the storage the current instance runs on")
    }

    /// An instance started under a name whose previous instance is still halting
    /// waits for that halt to write its last state, rather than reading files that
    /// are still being written.
    func testAStartWaitsForThePreviousHolderOfItsStorage() {
        let name = uniqueInstanceName()
        let namespace = StorageNamespace(instanceName: name)
        let previousHolder = NSObject()
        StorageClaims.claim(namespace, for: previousHolder)

        let released = Recorded(false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            released.value = true
            StorageClaims.release(namespace, by: previousHolder)
        }

        let countly = start(baseConfig(instanceName: name))

        XCTAssertTrue(released.value, "the start went ahead while the previous holder still held the storage")
        XCTAssertTrue(countly.isStarted)
    }

    /// A breadcrumb that reaches a halted instance's store after the erasure must
    /// not bring the crash log back for the next start to attach to a report.
    func testABreadcrumbLeftInFlightByAHaltedInstanceCannotUndoClearStorage() {
        let countly = startInstance()
        let haltedStore = core(of: countly).crashLogStore

        countly.halt(clearStorage: true)
        haltedStore.append("written after the erasure")

        XCTAssertNil(haltedStore.readAll(), "the halted store must not write the crash log again")
    }

    /// A send that completes after an ordinary halt belongs to the halted run. Its
    /// removal must not reach the files the next start reads, where an emptied
    /// queue would erase what that start is still sending.
    func testASendCompletingAfterAHaltCannotRemoveTheNextStartsRows() throws {
        let name = uniqueInstanceName()
        let config = baseConfig(instanceName: name)
        config.eventSendThreshold = 1
        let first = start(config)
        first.events.recordEvent("in-flight-at-the-halt")
        let haltedStore = core(of: first).requestQueueStore
        let inFlight = try XCTUnwrap(haltedStore.headEntry)
        first.halt()

        _ = start(baseConfig(instanceName: name))
        haltedStore.removeHead(inFlight)
        haltedStore.saveSync()

        let files = RequestQueueDatabase.Files(namespace: StorageNamespace(instanceName: name),
                                               directory: StorageLocation.directoryURL(logger: nil))
        let connection = try SQLiteConnection(path: files.database.path)
        defer { connection.close() }
        let rows = try connection.rows("SELECT body FROM requests") { $0.text(0) ?? "" }

        XCTAssertTrue(rows.contains { $0.contains("in-flight-at-the-halt") },
                      "the halted run removed a row the next start still has to send")
    }

    /// Behavior settings that arrive from a halted run are not applied to the run
    /// started after it.
    func testSettingsFromAHaltedRunAreNotAppliedToTheNextOne() {
        let name = uniqueInstanceName()
        let first = start(baseConfig(instanceName: name))
        let haltedSettings = core(of: first).serverConfig
        first.halt()

        let second = start(baseConfig(instanceName: name))
        second.serverConfigDidChange(haltedSettings, consentBecameRequired: true, changedKeys: [ServerConfig.Key.consentRequired])

        XCTAssertFalse(requestQueue(of: second).contains { $0.contains("consent=") },
                       "the halted run's settings resent consent on the next run")
    }

    #if os(iOS) || os(visionOS) || os(macOS)
    /// A halt off the main thread leaves closing a widget to the main thread, and
    /// the halt has released the core by the time that runs. Closing still reads
    /// the core, so the close has to keep it alive rather than take the
    /// application down.
    func testAWidgetClosedAfterTheHaltReleasedTheCoreDoesNotCrash() {
        var core: SDKCore? = SDKCore(instanceName: uniqueInstanceName(), config: baseConfig())
        let store = core!.requestQueueStore
        defer { store.deleteFile() }
        let module = FeedbackModule(core: core!)
        module.presentedWidgetManagers = [WebViewManager(core: core!)]

        // The main thread is held until the halt is over, so the close it queues
        // runs after it, as it does when the application's main thread is busy.
        let halted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            module.halt(clearStorage: false)
            halted.signal()
        }
        halted.wait()

        // What `CountlyInstance.halt()` does with the last reference it holds.
        core = nil

        TestUtils.pump(0.3)
        XCTAssertTrue(module.presentedWidgetManagers.isEmpty)
    }
    #endif

    /// A call that takes a completion answers it even when there is no SDK to do
    /// the work: a caller awaiting it through a continuation would otherwise wait
    /// for the life of the process.
    func testCallsWithACompletionAreAnsweredWhenTheSDKIsNotRunning() {
        let countly = Countly.instance(named: uniqueInstanceName())
        let answered = expectation(description: "every completion is called")
        answered.expectedFulfillmentCount = 7

        countly.remoteConfig.downloadKeys { result, _, _, _ in
            XCTAssertEqual(result, .error)
            answered.fulfill()
        }
        countly.remoteConfig.downloadSpecificKeys(["key"]) { result, _, _, _ in
            XCTAssertEqual(result, .error)
            answered.fulfill()
        }
        countly.remoteConfig.downloadOmittingKeys(["key"]) { result, _, _, _ in
            XCTAssertEqual(result, .error)
            answered.fulfill()
        }
        countly.remoteConfig.testingDownloadVariantInformation { result, _ in
            XCTAssertEqual(result, .error)
            answered.fulfill()
        }
        countly.remoteConfig.testingDownloadExperimentInformation { result, _ in
            XCTAssertEqual(result, .error)
            answered.fulfill()
        }
        countly.remoteConfig.testingEnrollIntoVariant(key: "key", variantName: "variant") { result, _ in
            XCTAssertEqual(result, .error)
            answered.fulfill()
        }
        countly.push.askForNotificationPermission { granted, _ in
            XCTAssertFalse(granted)
            answered.fulfill()
        }

        wait(for: [answered], timeout: 1)
    }

    // MARK: - Configuration validation

    func testAnInstanceWithNoAppKeyOrHostDoesNotStart() {
        let noAppKey = Countly.instance(named: "no-app-key-\(UUID().uuidString.prefix(8))")
        let missingKey = CountlyConfig()
        missingKey.host = Self.host
        noAppKey.start(with: missingKey)
        XCTAssertFalse(noAppKey.isStarted)

        let noHost = Countly.instance(named: "no-host-\(UUID().uuidString.prefix(8))")
        let missingHost = CountlyConfig()
        missingHost.appKey = Self.appKey
        noHost.start(with: missingHost)
        XCTAssertFalse(noHost.isStarted)
    }

    func testAHostWithTrailingSlashesIsNormalised() {
        let config = baseConfig()
        config.host = "https://example.com//"

        XCTAssertEqual(config.normalizedHost, "https://example.com")
    }

    // MARK: - Overriding the configuration at runtime

    func testChangingTheHostAffectsWhereTheNextRequestGoes() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.setNewHost("https://elsewhere.count.ly")
        countly.events.recordEvent("to the new host")

        TestUtils.waitUntil("a request reaches the new host") {
            MockURLProtocol.requests.contains { $0.url.host == "elsewhere.count.ly" }
        }
    }

    /// Requests already queued keep the app key they were recorded under, because
    /// they belong to that dashboard application. Re-attributing them is a separate,
    /// explicit call.
    func testChangingTheAppKeyLeavesQueuedRequestsAlone() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("under the old key")

        countly.setNewAppKey("a-different-key")
        countly.events.recordEvent("under the new key")

        let keys = requestQueue(of: countly).map { TestUtils.parseQuery($0)["app_key"] as? String }
        XCTAssertTrue(keys.contains(Self.appKey))
        XCTAssertTrue(keys.contains("a-different-key"))
    }

    func testAnEmptyHostOrAppKeyIsRefused() {
        let countly = startInstance()

        countly.setNewHost("")
        countly.setNewAppKey("")

        XCTAssertEqual(core(of: countly).config.normalizedHost, Self.host)
        XCTAssertEqual(core(of: countly).config.appKey, Self.appKey)
    }
}
