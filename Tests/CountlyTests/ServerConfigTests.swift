//
//  ServerConfigTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Behavior settings: the switches the server holds over an already-shipped build.
///
/// This is how support turns a feature off, tightens a limit, or gets logs out of
/// a released application without waiting for an app store review, so the parsing
/// has to be strict about what it accepts and the resolved values have to reach
/// the modules that act on them.
final class ServerConfigTests: CountlyBaseTestCase {

    private func serverConfig(of instance: CountlyInstance) -> ServerConfig {
        core(of: instance).serverConfig
    }

    // MARK: - Defaults

    /// With nothing configured the SDK has to behave as though every switch were
    /// on, or an application that never talks to a server that serves behavior
    /// settings would silently do nothing.
    func testWithNoSettingsEverythingDefaultsToEnabled() {
        let config = serverConfig(of: startInstance())

        XCTAssertTrue(config.trackingEnabled)
        XCTAssertTrue(config.networkingEnabled)
        XCTAssertTrue(config.sessionTrackingEnabled)
        XCTAssertTrue(config.viewTrackingEnabled)
        XCTAssertTrue(config.customEventTrackingEnabled)
        XCTAssertTrue(config.crashReportingEnabled)
        XCTAssertTrue(config.locationTrackingEnabled)
        XCTAssertFalse(config.consentRequired)
    }

    // MARK: - Parsing

    func testEverySwitchInTheDocumentIsApplied() {
        let settings = ServerConfigBuilder()
            .tracking(false)
            .networking(false)
            .sessionTracking(false)
            .viewTracking(false)
            .customEventTracking(false)
            .crashReporting(false)
            .locationTracking(false)
            .json()

        let config = serverConfig(of: startInstance { $0.sdkBehaviorSettings = settings })

        XCTAssertFalse(config.trackingEnabled)
        XCTAssertFalse(config.networkingEnabled)
        XCTAssertFalse(config.sessionTrackingEnabled)
        XCTAssertFalse(config.viewTrackingEnabled)
        XCTAssertFalse(config.customEventTrackingEnabled)
        XCTAssertFalse(config.crashReportingEnabled)
        XCTAssertFalse(config.locationTrackingEnabled)
    }

    /// A document with no version or timestamp cannot be ordered against another
    /// one, so it is refused outright rather than half applied.
    func testADocumentWithoutAVersionOrTimestampIsIgnored() {
        let settings = #"{"c": {"tracking": false}}"#

        let config = serverConfig(of: startInstance { $0.sdkBehaviorSettings = settings })

        XCTAssertTrue(config.trackingEnabled, "an unversioned document must change nothing")
    }

    func testUnparseableSettingsAreIgnoredRatherThanCrashing() {
        let config = serverConfig(of: startInstance { $0.sdkBehaviorSettings = "{not json" })

        XCTAssertTrue(config.trackingEnabled)
        XCTAssertTrue(config.networkingEnabled)
    }

    /// A newer server can send a key this build has never heard of. It is dropped
    /// rather than carried into the cache, so it cannot come back to confuse a
    /// later read.
    func testAnUnknownKeyIsDroppedWithoutDisturbingTheKnownOnes() {
        let settings = ServerConfigBuilder()
            .tracking(false)
            .unknown("a_switch_from_the_future", true)
            .json()

        let countly = startInstance { $0.sdkBehaviorSettings = settings }

        XCTAssertFalse(serverConfig(of: countly).trackingEnabled)
        let cached = core(of: countly).keyValueStore.serverConfig?["c"] as? [String: Any]
        XCTAssertNil(cached?["a_switch_from_the_future"])
    }

    // MARK: - Limits

    /// Limits from the server overwrite the ones the application configured, which
    /// is what makes them a control rather than a suggestion.
    func testLimitsFromTheServerOverrideTheConfiguredOnes() {
        let settings = ServerConfigBuilder()
            .maxKeyLength(5)
            .maxValueSize(6)
            .maxSegmentationValues(2)
            .maxBreadcrumbCount(3)
            .json()

        let countly = startInstance {
            $0.sdkInternalLimits.maxKeyLength = 128
            $0.sdkInternalLimits.maxValueSize = 256
            $0.sdkBehaviorSettings = settings
            $0.eventSendThreshold = 1
        }

        let limits = core(of: countly).config.sdkInternalLimits
        XCTAssertEqual(limits.maxKeyLength, 5)
        XCTAssertEqual(limits.maxValueSize, 6)
        XCTAssertEqual(limits.maxSegmentationValues, 2)
        XCTAssertEqual(limits.maxBreadcrumbCount, 3)

        // And they are actually enforced, not merely stored.
        countly.events.recordEvent("a-long-event-key")
        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        XCTAssertEqual(TestUtils.events(in: request)[0]["key"] as? String, "a-lon")
    }

    /// A limit of zero would discard every value, which is worse than ignoring the
    /// misconfiguration, so values below the minimum are refused.
    func testALimitBelowItsMinimumIsRefused() {
        let settings = ServerConfigBuilder().maxKeyLength(0).maxValueSize(-5).json()

        let countly = startInstance {
            $0.sdkInternalLimits.maxKeyLength = 20
            $0.sdkBehaviorSettings = settings
        }

        XCTAssertEqual(core(of: countly).config.sdkInternalLimits.maxKeyLength, 20)
    }

    // MARK: - Listing filters

    func testAnEventBlacklistDropsTheListedKeysAndAWhitelistDropsEverythingElse() {
        let blacklisted = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().eventBlacklist(["banned"]).json()
        }
        XCTAssertFalse(serverConfig(of: blacklisted).shouldRecordEvent("banned"))
        XCTAssertTrue(serverConfig(of: blacklisted).shouldRecordEvent("anything-else"))

        let whitelisted = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().eventWhitelist(["allowed"]).json()
        }
        XCTAssertTrue(serverConfig(of: whitelisted).shouldRecordEvent("allowed"))
        XCTAssertFalse(serverConfig(of: whitelisted).shouldRecordEvent("anything-else"))
    }

    func testUserPropertyFiltersWorkTheSameWay() {
        let blacklisted = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().userPropertyBlacklist(["secret"]).json()
        }
        XCTAssertFalse(serverConfig(of: blacklisted).shouldRecordUserProperty("secret"))
        XCTAssertTrue(serverConfig(of: blacklisted).shouldRecordUserProperty("plan"))

        let whitelisted = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().userPropertyWhitelist(["plan"]).json()
        }
        XCTAssertTrue(serverConfig(of: whitelisted).shouldRecordUserProperty("plan"))
        XCTAssertFalse(serverConfig(of: whitelisted).shouldRecordUserProperty("anything-else"))
    }

    /// The segmentation filters work per key across every event, which is how a
    /// field that turns out to carry something sensitive is switched off
    /// everywhere at once.
    func testSegmentationFiltersApplyAcrossEveryEvent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().segmentationBlacklist(["email"]).json()
        }

        countly.events.recordEvent("signup", segmentation: ["email": "a@b.c", "plan": "free"])

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let segmentation = (TestUtils.events(in: request)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertNil(segmentation["email"])
        XCTAssertEqual(segmentation["plan"] as? String, "free")
    }

    /// The per-event filter is narrower: it names the event as well as the key, so
    /// the same key can be kept elsewhere.
    func testThePerEventSegmentationFilterOnlyAppliesToItsOwnEvent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .eventSegmentationBlacklist(["signup": ["email"]])
                .json()
        }

        countly.events.recordEvent("signup", segmentation: ["email": "a@b.c"])
        countly.events.recordEvent("login", segmentation: ["email": "a@b.c"])

        let queue = requestQueue(of: countly)
        guard let first = TestUtils.request(queue, at: 0),
              let second = TestUtils.request(queue, at: 1) else { return }

        XCTAssertNil((TestUtils.events(in: first)[0]["segmentation"] as? [String: Any])?["email"])
        XCTAssertNotNil((TestUtils.events(in: second)[0]["segmentation"] as? [String: Any])?["email"])
    }

    // MARK: - Journey triggers

    func testJourneyTriggerEventsAndViewsAreRecognised() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .journeyTriggerEvents(["purchase"])
                .journeyTriggerViews(["Checkout"])
                .json()
        }

        let config = serverConfig(of: countly)
        XCTAssertTrue(config.isJourneyTriggerEvent("purchase"))
        XCTAssertFalse(config.isJourneyTriggerEvent("something-else"))
        XCTAssertTrue(config.isJourneyTriggerView("Checkout"))
        XCTAssertFalse(config.isJourneyTriggerView("Home"))
    }

    // MARK: - Effects on the rest of the SDK

    /// The server can require consent from an application that shipped without it,
    /// which is how a privacy requirement is applied after release.
    func testTheServerCanRequireConsentFromAnApplicationThatShippedWithoutIt() {
        let countly = startInstance {
            $0.requiresConsent = false
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().consentRequired(true).json()
        }

        XCTAssertTrue(serverConfig(of: countly).consentRequired)
        XCTAssertFalse(countly.consent.hasConsent(for: .events))

        countly.events.recordEvent("should-be-blocked")
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "events").isEmpty)
    }

    /// Tracking off is the hardest switch: nothing is even queued, so nothing can
    /// be sent later when it is switched back on.
    func testWithTrackingOffNothingIsQueuedAtAll() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.manualSessionHandling = true
            $0.sdkBehaviorSettings = ServerConfigBuilder().tracking(false).json()
        }

        countly.events.recordEvent("dropped")
        countly.sessions.beginSession()
        countly.userProfile.setProperty("name", value: "Ada")
        countly.userProfile.save()

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    /// The server can switch logging on for an application that never asked for
    /// it, which is how support gets a trace out of a shipped build.
    func testTheServerCanSwitchLoggingOn() {
        let settings = #"{"v": 1, "t": 1700000000000, "c": {"log": true}}"#

        let countly = startInstance {
            $0.enableDebug = false
            $0.sdkBehaviorSettings = settings
        }

        XCTAssertTrue(core(of: countly).config.enableDebug)
    }

    // MARK: - Caching

    /// The resolved document is cached, so an application launching offline keeps
    /// behaving the way the server last told it to rather than reverting to its
    /// own defaults.
    func testTheResolvedDocumentIsCachedAndReadBackOnTheNextStart() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.sdkBehaviorSettings = ServerConfigBuilder().customEventTracking(false).json()
        start(firstConfig).halt()

        // No settings supplied this time: whatever holds has to have come from the
        // cache.
        let second = start(baseConfig(instanceName: name))

        XCTAssertFalse(serverConfig(of: second).customEventTrackingEnabled)
    }

    /// The developer supplied settings are a bootstrap for the very first launch
    /// only. Once a document is cached, it is the cache that wins.
    func testDeveloperSuppliedSettingsOnlyApplyWhileTheCacheIsEmpty() {
        let name = uniqueInstanceName()

        let firstConfig = baseConfig(instanceName: name)
        firstConfig.sdkBehaviorSettings = ServerConfigBuilder().customEventTracking(false).json()
        start(firstConfig).halt()

        let secondConfig = baseConfig(instanceName: name)
        secondConfig.sdkBehaviorSettings = ServerConfigBuilder().customEventTracking(true).json()
        let second = start(secondConfig)

        XCTAssertFalse(serverConfig(of: second).customEventTrackingEnabled,
                       "the cached document is what the server actually said")
    }

    // MARK: - Fetching

    /// The fetch is an instant request on the read endpoint, because a build that
    /// has been switched off must not have to drain its queue before it hears so.
    func testTheSettingsAreFetchedImmediatelyRatherThanThroughTheQueue() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk",
                                json: ServerConfigBuilder().customEventTracking(false).json())

        let countly = startInstance()

        TestUtils.waitUntil("the behavior settings land") {
            !serverConfig(of: countly).customEventTrackingEnabled
        }

        let fetches = MockURLProtocol.requests(pathContaining: "/o/sdk")
            .filter { $0.query.contains("method=sc") }
        XCTAssertFalse(fetches.isEmpty)
    }

    func testUpdatesCanBeSwitchedOffByTheApplication() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond(pathContaining: "/o/sdk",
                                json: ServerConfigBuilder().customEventTracking(false).json())

        _ = startInstance { $0.disableSDKBehaviorSettingsUpdates = true }
        TestUtils.pump(0.3)

        XCTAssertTrue(MockURLProtocol.requests.filter { $0.query.contains("method=sc") }.isEmpty)
    }
}
