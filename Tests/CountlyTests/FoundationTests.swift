//
//  PlaceholderTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Covers the pieces the whole SDK rests on: how data is namespaced per
/// instance, how values are escaped and capped on the way out, and how the
/// clock guarantees ordering.
final class FoundationTests: XCTestCase {

    // MARK: - Storage namespacing

    func testDefaultInstanceUsesLegacyPathsAndKeys() {
        let namespace = StorageNamespace(instanceName: nil)

        XCTAssertTrue(namespace.isDefault)
        XCTAssertEqual(namespace.key(PersistencyKey.storedDeviceID), PersistencyKey.storedDeviceID)
        XCTAssertEqual(namespace.fileName("Countly", extension: "dat"), "Countly.dat")
    }

    func testDefaultInstanceNameResolvesToTheDefaultNamespace() {
        let namespace = StorageNamespace(instanceName: StorageNamespace.defaultInstanceName)
        XCTAssertTrue(namespace.isDefault)
    }

    func testNamedInstanceGetsItsOwnPathsAndKeys() {
        let namespace = StorageNamespace(instanceName: "tenantA")

        XCTAssertFalse(namespace.isDefault)
        XCTAssertNotEqual(namespace.key(PersistencyKey.storedDeviceID), PersistencyKey.storedDeviceID)
        XCTAssertTrue(namespace.key(PersistencyKey.storedDeviceID).hasPrefix(PersistencyKey.storedDeviceID))
        XCTAssertTrue(namespace.fileName("Countly", extension: "dat").hasSuffix(".dat"))
    }

    /// Sanitizing is lossy, so names that reduce to the same safe string still
    /// have to end up in different stores.
    func testNamesThatSanitizeAlikeStillGetDifferentNamespaces() {
        let dotted = StorageNamespace(instanceName: "a.b")
        let dashed = StorageNamespace(instanceName: "a-b")
        let spaced = StorageNamespace(instanceName: "a b")

        XCTAssertNotEqual(dotted.suffix, spaced.suffix)
        XCTAssertNotEqual(dashed.suffix, spaced.suffix)
    }

    func testSanitizedNamespaceIsFileSafe() {
        let namespace = StorageNamespace(instanceName: "a/b:c\\d e")
        let unsafe = CharacterSet(charactersIn: "/\\: ")
        XCTAssertNil(namespace.suffix.rangeOfCharacter(from: unsafe))
    }

    // MARK: - Escaping

    /// Every reserved character has to be escaped, or a value could break out of
    /// its query parameter.
    func testURLEscapingLeavesOnlyUnreservedCharacters() {
        XCTAssertEqual("a b".urlEscaped, "a%20b")
        XCTAssertEqual("a&b=c".urlEscaped, "a%26b%3Dc")
        XCTAssertEqual("a+b".urlEscaped, "a%2Bb")
        XCTAssertEqual("a/b".urlEscaped, "a%2Fb")
        XCTAssertEqual("aA0-._~".urlEscaped, "aA0-._~")
    }

    func testQueryStringKeyLookup() {
        let query = "app_key=abc&device_id=xyz&t=1"
        XCTAssertEqual(query.valueForQueryStringKey("device_id"), "xyz")
        XCTAssertNil(query.valueForQueryStringKey("missing"))
    }

    func testSHA256MatchesKnownDigest() {
        XCTAssertEqual("abc".sha256Hex,
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    // MARK: - Limits

    private func enforcer(keyLength: Int = 8, valueSize: Int = 8, segmentation: Int = 2) -> LimitsEnforcer {
        let limits = CountlySDKLimitsConfig()
        limits.maxKeyLength = keyLength
        limits.maxValueSize = valueSize
        limits.maxSegmentationValues = segmentation
        return LimitsEnforcer(limits: limits, logger: nil)
    }

    func testKeysAndValuesAreTruncatedToTheirLimits() {
        let limits = enforcer()
        XCTAssertEqual(limits.truncatedKey("0123456789", "test"), "01234567")
        XCTAssertEqual(limits.truncatedValue("0123456789", "test"), "01234567")
        XCTAssertEqual(limits.truncatedKey("short", "test"), "short")
    }

    func testSegmentationIsTrimmedToTheValueLimit() {
        let limits = enforcer(segmentation: 2)
        let trimmed = limits.limited(["a": 1, "b": 2, "c": 3], "test")
        XCTAssertEqual(trimmed.count, 2)
    }

    /// The server stores numbers, strings and lists of those. Anything else is
    /// dropped rather than failing the whole call.
    func testUnsupportedSegmentationValuesAreDropped() {
        let limits = enforcer(segmentation: 10)
        let filtered = limits.filterSupportedDataTypes([
            "number": 1,
            "text": "value",
            "list": ["a", 2],
            "unsupported": Data(),
        ])

        XCTAssertEqual(Set(filtered.keys), ["number", "text", "list"])
    }

    // MARK: - Clock

    /// The server orders events inside a batch by timestamp, so two events in the
    /// same millisecond must not report the same value.
    func testClockNeverRepeatsATimestamp() {
        let clock = MonotonicClock()
        var seen = Set<Int64>()

        for _ in 0..<1000 {
            let value = clock.nowMs()
            XCTAssertFalse(seen.contains(value))
            seen.insert(value)
        }
    }

    /// A burst on one instance must not push another instance's timestamps into
    /// the future, which is why the clock is per instance.
    func testClocksAreIndependentPerInstance() {
        let busy = MonotonicClock()
        for _ in 0..<5000 { _ = busy.nowMs() }

        let fresh = MonotonicClock()
        XCTAssertLessThan(fresh.nowMs(), busy.nowMs())
    }

    /// An event ID encodes a moment that must not predate the event's own
    /// timestamp.
    func testEventIDCarriesAMonotonicTimestamp() {
        let clock = MonotonicClock()
        let before = clock.nowMs()
        let identifier = clock.generateEventID()

        XCTAssertGreaterThan(identifier.count, 8)
        let trailing = Int64(identifier.suffix(13)) ?? 0
        XCTAssertGreaterThan(trailing, before)
    }

    // MARK: - Consent

    func testConsentWireNamesRoundTrip() {
        for feature in ConsentFeature.allCases {
            XCTAssertEqual(ConsentFeature(wireName: feature.wireName), feature)
        }
    }

    func testConsentWireNamesAreTheOnesTheServerExpects() {
        XCTAssertEqual(ConsentFeature.userDetails.wireName, "users")
        XCTAssertEqual(ConsentFeature.crashReporting.wireName, "crashes")
        XCTAssertEqual(ConsentFeature.viewTracking.wireName, "views")
        XCTAssertEqual(ConsentFeature.starRating.wireName, "star-rating")
        XCTAssertEqual(ConsentFeature.remoteConfig.wireName, "remote-config")
    }

    // MARK: - Config validation

    func testConfigRejectsMissingAndPlaceholderValues() {
        let empty = CountlyConfig()
        XCTAssertEqual(empty.validate(), .missingAppKey)

        let placeholder = CountlyConfig(appKey: Placeholder.appKey, host: "https://example.com")
        XCTAssertEqual(placeholder.validate(), .missingAppKey)

        let noHost = CountlyConfig(appKey: "key", host: "")
        XCTAssertEqual(noHost.validate(), .missingHost)

        let valid = CountlyConfig(appKey: "key", host: "https://example.com")
        XCTAssertNil(valid.validate())
    }

    /// A server URL that is not an absolute http or https URL would make every
    /// request fail, so the SDK refuses to start with one.
    func testConfigRejectsAServerURLThatIsNotAnAbsoluteHTTPURL() {
        for host in ["ftp://example.com", "example.com", "my server", "https://", "file:///tmp/countly"] {
            XCTAssertEqual(CountlyConfig(appKey: "key", host: host).validate(), .invalidHost, "host: \(host)")
        }
        XCTAssertNil(CountlyConfig(appKey: "key", host: "http://localhost:8080/").validate())
        XCTAssertNil(CountlyConfig(appKey: "key", host: "https://example.com/countly").validate())
    }

    /// Pinning protects nothing on a plain http connection, so the combination is
    /// refused rather than silently ignored.
    func testPinningNeedsAnHTTPSServerURL() {
        let config = CountlyConfig(appKey: "key", host: "http://example.com")
        config.pinnedCertificates = ["server.cer"]
        XCTAssertEqual(config.validate(), .pinningRequiresHTTPS)

        config.host = "https://example.com"
        XCTAssertNil(config.validate())
    }

    func testHostLosesItsTrailingSlashes() {
        let config = CountlyConfig(appKey: "key", host: "https://example.com//")
        XCTAssertEqual(config.normalizedHost, "https://example.com")
    }

    /// A limit below one would silently discard every value, so it is ignored and
    /// the default stays; it is never raised to one.
    func testLimitsBelowOneFallBackToTheDefaults() {
        let limits = CountlySDKLimitsConfig()
        limits.maxKeyLength = 0
        limits.maxValueSize = -5
        limits.maxBreadcrumbCount = 7

        var rejected: [String] = []
        limits.resetInvalidValues { name, _, _ in rejected.append(name) }

        XCTAssertEqual(limits.maxKeyLength, DefaultLimits.maxKeyLength)
        XCTAssertEqual(limits.maxValueSize, DefaultLimits.maxValueSize)
        XCTAssertEqual(limits.maxBreadcrumbCount, 7, "a valid value is left alone")
        XCTAssertEqual(Set(rejected), ["maxKeyLength", "maxValueSize"])
    }

    /// An option outside its valid range is ignored with a warning and the
    /// default is used, never a value raised or lowered to fit.
    func testConfigValuesOutsideTheirRangeFallBackToTheDefaults() {
        let config = CountlyConfig(appKey: "key", host: "https://example.com")
        config.storedRequestsLimit = 0
        config.eventSendThreshold = -1
        config.updateSessionPeriod = 0
        config.requestTimeoutDuration = 0.5
        config.requestDropAgeHours = -2
        config.failedRequestCooldown = CountlyConfig.minimumFailedRequestCooldown - 1

        let resetCount = config.resetInvalidValues(logger: Logger(instanceName: nil))

        XCTAssertEqual(resetCount, 6)
        XCTAssertEqual(config.storedRequestsLimit, 1000)
        XCTAssertEqual(config.eventSendThreshold, 100)
        XCTAssertEqual(config.updateSessionPeriod, CountlyConfig.defaultUpdateSessionPeriod)
        XCTAssertEqual(config.requestTimeoutDuration, 30)
        XCTAssertEqual(config.requestDropAgeHours, 0)
        XCTAssertEqual(config.failedRequestCooldown, 60)
    }

    // MARK: - Registry

    func testInstanceLookupIsStableAndDoesNotAutoStart() {
        let first = Countly.instance(named: "parity-test")
        let second = Countly.instance(named: "parity-test")

        XCTAssertTrue(first === second)
        XCTAssertFalse(first.isStarted)
    }

    func testEmptyNameDoesNotResolveToTheDefaultInstance() {
        XCTAssertFalse(Countly.instance(named: "") === Countly.shared)
    }

    func testGetInstanceDoesNotCreate() {
        XCTAssertNil(Countly.getInstance(named: "never-created-instance"))
    }

    func testListInstancesExcludesTheDefaultOne() {
        _ = Countly.instance(named: "listed-instance")
        XCTAssertTrue(Countly.listInstances().contains("listed-instance"))
        XCTAssertFalse(Countly.listInstances().contains(Countly.defaultInstanceName))
    }

    // MARK: - Hex encoding

    func testHexEncodingMatchesTheDigestFormat() {
        XCTAssertEqual(Data([0x00, 0x0f, 0xa5, 0xff]).hexString, "000fa5ff")
        XCTAssertEqual(Data().hexString, "")
    }

    // MARK: - Weak registry

    func testRegistryReportsTheFirstAndLastEntry() {
        final class Subscriber {}

        let registry = WeakRegistry<Subscriber>()
        let first = Subscriber()
        let second = Subscriber()

        XCTAssertTrue(registry.add(first), "the first entry is what triggers install")
        XCTAssertFalse(registry.add(second))
        XCTAssertEqual(registry.current().count, 2)

        XCTAssertFalse(registry.remove(first))
        XCTAssertTrue(registry.remove(second), "the last removal is what triggers uninstall")
        XCTAssertTrue(registry.isEmpty)
    }

    /// A halted instance must not be kept alive by the process-wide registries.
    func testRegistryDropsDeallocatedEntries() {
        final class Subscriber {}

        let registry = WeakRegistry<Subscriber>()
        let kept = Subscriber()
        registry.add(kept)

        do {
            let transient = Subscriber()
            registry.add(transient)
            XCTAssertEqual(registry.current().count, 2)
        }

        XCTAssertEqual(registry.current().count, 1)
    }

    // MARK: - Request age

    func testRequestAgeReadsTheQueuedTimestamp() {
        let now = Date().timeIntervalSince1970
        let request = "app_key=k&timestamp=\(Int64((now - 3600) * 1000))"
        XCTAssertEqual(request.requestAgeSeconds, 3600, accuracy: 5)
    }

    /// A request with no readable timestamp has to read as stale, not as fresh,
    /// or the age based drop would keep it forever.
    func testRequestWithNoTimestampReadsAsAncient() {
        XCTAssertGreaterThan("app_key=k".requestAgeSeconds, 1_000_000_000)
    }

    // MARK: - Theme

    func testThemeIsAppendedWithTheRightSeparator() {
        XCTAssertEqual(DeviceMetrics.urlString("https://a.com/p", byAppendingThemeMode: "d"),
                       "https://a.com/p?th=d")
        XCTAssertEqual(DeviceMetrics.urlString("https://a.com/p?x=1", byAppendingThemeMode: "l"),
                       "https://a.com/p?x=1&th=l")
        XCTAssertEqual(DeviceMetrics.urlString("https://a.com/p", byAppendingThemeMode: nil),
                       "https://a.com/p")
    }
}
