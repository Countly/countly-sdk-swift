//
//  ValidationTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// What the SDK refuses, and what it does instead of refusing.
///
/// Everything here is an input the SDK cannot use: a value of the wrong type, a
/// string that cannot be cut where it was asked to be cut, a setting the server
/// sent as the wrong kind of thing. None of them may crash and none may be
/// silently taken at face value, because the cost of either is paid on the wire
/// where nobody is watching.
final class ValidationTests: CountlyBaseTestCase {

    // MARK: - Behaviour settings of the wrong type

    /// The server's settings arrive as untyped JSON. A value of the wrong kind is
    /// dropped rather than coerced, because coercing would apply a setting nobody
    /// wrote.
    func testABehaviourSettingOfTheWrongTypeIsDropped() {
        let settings = """
        {"v": 1, "t": 1700000000000, "c": {
          "tracking": "yes",
          "rqs": true,
          "bom_rqp": "half",
          "networking": false
        }}
        """

        let countly = startInstance { $0.sdkBehaviorSettings = settings }
        let config = core(of: countly).serverConfig

        XCTAssertTrue(config.trackingEnabled, "a string is not a boolean, so the key is dropped")
        // Zero is the "the server said nothing" value for a size, which is what a
        // dropped key has to leave behind.
        XCTAssertEqual(config.requestQueueSize, 0, "a boolean is not an integer")
        XCTAssertFalse(config.networkingEnabled, "the well formed key beside them still applies")
    }

    /// A fraction has to be strictly between zero and one: zero would make every
    /// queue count as pressured and one would make none of them.
    func testABackoffFractionOutsideItsRangeIsDropped() {
        for value in [0.0, 1.0, -0.5, 2.0] {
            let countly = startInstance {
                $0.sdkBehaviorSettings = ServerConfigBuilder()
                    .bomRequestQueuePercentage(value)
                    .json()
            }
            XCTAssertEqual(core(of: countly).serverConfig.bomRQPercentage, 0.5,
                           "\(value) is outside the accepted range and should have been dropped")
        }

        let accepted = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .bomRequestQueuePercentage(0.25)
                .json()
        }
        XCTAssertEqual(core(of: accepted).serverConfig.bomRQPercentage, 0.25, accuracy: 0.0001)
    }

    /// An integer below the minimum its setting allows is dropped rather than
    /// clamped, because a server that sent nonsense has not expressed a preference.
    func testAnIntegerBelowItsMinimumIsDropped() {
        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .requestQueueSize(0)
                .sessionUpdateInterval(0)
                .json()
        }
        let config = core(of: countly).serverConfig

        // Zero is what "unset" looks like for both, so a refused value is
        // indistinguishable from the server never having sent one, which is the
        // point: nothing was applied.
        XCTAssertEqual(config.requestQueueSize, 0)
        XCTAssertEqual(config.sessionInterval, 0)

        // And a value at the minimum is accepted, so the guard is a floor rather
        // than a blanket refusal.
        let accepted = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().requestQueueSize(1).json()
        }
        XCTAssertEqual(core(of: accepted).serverConfig.requestQueueSize, 1)
    }

    /// A settings document with a config section that is not an object has nothing
    /// usable in it, and must not take the SDK's defaults with it.
    func testASettingsDocumentWithNoUsableConfigSectionChangesNothing() {
        for body in [#"{"v": 1, "t": 1, "c": "not an object"}"#,
                     #"{"v": 1, "t": 1}"#,
                     #"{"c": {"tracking": false}}"#] {
            let countly = startInstance { $0.sdkBehaviorSettings = body }
            XCTAssertTrue(core(of: countly).serverConfig.trackingEnabled,
                          "document [\(body)] should have changed nothing")
        }
    }

    // MARK: - Truncation

    /// Truncation counts UTF-16 units, which is what the server counts. Counting
    /// characters instead would let a string of emoji go out at twice the limit
    /// while the SDK logged that it had been cut.
    func testTruncationCountsTheUnitsTheServerCounts() {
        let limits = CountlySDKLimitsConfig()
        limits.maxValueSize = 10
        let enforcer = LimitsEnforcer(limits: limits, logger: nil)

        let emoji = String(repeating: "😀", count: 20)
        let truncated = enforcer.truncatedValue(emoji, "test")

        XCTAssertLessThanOrEqual(truncated.utf16.count, 10)
    }

    /// Cutting inside a character would produce a broken string, so the cut moves
    /// back to the nearest boundary rather than landing mid-character.
    func testTruncationNeverCutsInsideACharacter() {
        let limits = CountlySDKLimitsConfig()
        // An odd limit inside a surrogate pair, so a naive cut would split one.
        limits.maxValueSize = 5
        let enforcer = LimitsEnforcer(limits: limits, logger: nil)

        let truncated = enforcer.truncatedValue(String(repeating: "😀", count: 5), "test")

        XCTAssertLessThanOrEqual(truncated.utf16.count, 5)
        XCTAssertFalse(truncated.unicodeScalars.contains { $0.properties.isDefaultIgnorableCodePoint })
        // Round tripping proves it is still well formed.
        XCTAssertEqual(String(data: Data(truncated.utf8), encoding: .utf8), truncated)
    }

    /// A limit smaller than the first character leaves nothing that can be sent, so
    /// the result is empty rather than broken.
    func testALimitSmallerThanTheFirstCharacterYieldsNothing() {
        let limits = CountlySDKLimitsConfig()
        limits.maxValueSize = 1
        let enforcer = LimitsEnforcer(limits: limits, logger: nil)

        XCTAssertEqual(enforcer.truncatedValue("😀", "test"), "")
    }

    /// A picture URL is held to its own, much larger limit: it is an address, not a
    /// label, and cutting it to the ordinary value limit makes it unresolvable.
    func testAPictureValueUsesThePictureLimit() {
        let limits = CountlySDKLimitsConfig()
        limits.maxValueSize = 4
        limits.maxValueSizePicture = 12
        let enforcer = LimitsEnforcer(limits: limits, logger: nil)

        XCTAssertEqual(enforcer.truncatedPictureValue("0123456789abcdef", "test"), "0123456789ab")
        XCTAssertEqual(enforcer.truncatedPictureValue("short", "test"), "short")
    }

    // MARK: - Segmentation values

    /// The server stores numbers, strings and lists of those. A list carrying
    /// anything else has the offending elements dropped rather than the whole list.
    func testAListDropsOnlyItsUnsupportedElements() {
        let enforcer = LimitsEnforcer(limits: CountlySDKLimitsConfig(), logger: nil)

        let filtered = enforcer.filterSupportedDataTypes(["list": ["a", 1, Data(), Date(), "b"]])
        guard let list = filtered["list"] as? [Any] else {
            XCTFail("the list should have survived: \(filtered)")
            return
        }

        XCTAssertEqual(list.map { "\($0)" }, ["a", "1", "b"])
    }

    // MARK: - JSON that cannot be represented

    /// An object JSON cannot represent is reported as nothing rather than as an
    /// empty string, so a caller can tell "could not serialize" from "serialized to
    /// nothing".
    func testAnUnrepresentableObjectSerializesToNothing() {
        XCTAssertNil(CountlyJSON.string(from: Date(), logger: nil))
        XCTAssertNil(CountlyJSON.string(from: nil, logger: nil))
        XCTAssertEqual(CountlyJSON.escapedString(from: Date(), logger: nil), "")

        XCTAssertNotNil(CountlyJSON.string(from: ["a": 1], logger: nil))
    }

    func testResponseBytesThatAreNotJSONParseToNothing() {
        XCTAssertNil(CountlyJSON.object(from: nil, logger: nil))
        XCTAssertNil(CountlyJSON.object(from: Data(), logger: nil))
        XCTAssertNil(CountlyJSON.object(from: Data("not json".utf8), logger: nil))
        XCTAssertNotNil(CountlyJSON.object(from: Data(#"{"a":1}"#.utf8), logger: nil))
    }

    // MARK: - Content geometry

    /// A page that pins only its origin still covers the space it was given, rather
    /// than collapsing to nothing and becoming an invisible touch trap.
    func testContentGeometryFallsBackToTheContainerSize() {
        let container = CGSize(width: 400, height: 800)

        let partial = CGRect(contentGeometry: ["x": 10, "y": 20], container: container)
        XCTAssertEqual(partial, CGRect(x: 10, y: 20, width: 400, height: 800))

        let full = CGRect(contentGeometry: ["x": 1, "y": 2, "w": 3, "h": 4], container: container)
        XCTAssertEqual(full, CGRect(x: 1, y: 2, width: 3, height: 4))

        let empty = CGRect(contentGeometry: [:], container: container)
        XCTAssertEqual(empty, CGRect(origin: .zero, size: container))
    }

    // MARK: - The health tracker's reset

    /// A full reset restores the once-per-launch guard as well as the counters,
    /// which is what lets a halted and restarted instance report again.
    func testResettingTheHealthTrackerRestoresTheOncePerLaunchGuard() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)

        let countly = startInstance()
        let tracker = core(of: countly).healthTracker

        TestUtils.waitUntil("the start-up health check is sent") {
            MockURLProtocol.requests.contains { $0.query.contains("hc=") }
        }
        let afterFirst = MockURLProtocol.requests.filter { $0.query.contains("hc=") }.count

        tracker.reset()

        TestUtils.waitUntil("a second health check is sent after the reset") {
            tracker.sendHealthCheck(isDeviceIDTemporary: false, networkingEnabled: true)
            return MockURLProtocol.requests.filter { $0.query.contains("hc=") }.count > afterFirst
        }
    }

    // MARK: - The public error surface

    /// A Swift error is described rather than dropped, so an application can hand
    /// the SDK whatever it caught.
    func testASwiftErrorIsRecordedByItsDescription() {
        struct Boom: Error, CustomStringConvertible {
            var description: String { "the boom happened" }
        }

        let countly = startInstance()
        countly.crashes.recordError(Boom())

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("recording an error should have queued a crash request")
            return
        }
        XCTAssertEqual(crash["_name"] as? String, "the boom happened")
    }

    /// An `NSException` carries its own stack trace and reason, which is what makes
    /// it worth having its own entry point.
    func testAnExceptionIsRecordedWithItsNameAndReason() {
        let countly = startInstance()

        countly.crashes.recordException(
            NSException(name: .genericException, reason: "something went wrong", userInfo: nil))

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("recording an exception should have queued a crash request")
            return
        }
        XCTAssertEqual(crash["_name"] as? String, "something went wrong")
        XCTAssertEqual(crash["_type"] as? String, NSExceptionName.genericException.rawValue)
    }

    /// An exception carrying no reason still has to be reportable: its name is the
    /// best description available.
    func testAnExceptionWithNoReasonFallsBackToItsName() {
        let countly = startInstance()

        countly.crashes.recordException(
            NSException(name: NSExceptionName("MyException"), reason: nil, userInfo: nil))

        guard let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any] else {
            XCTFail("recording an exception should have queued a crash request")
            return
        }
        XCTAssertEqual(crash["_name"] as? String, "MyException")
    }

    /// An exception's `userInfo` is context the application attached, so it travels
    /// as segmentation.
    func testAnExceptionsUserInfoBecomesSegmentation() {
        let countly = startInstance()

        countly.crashes.recordException(
            NSException(name: .genericException, reason: "boom", userInfo: ["screen": "cart"]))

        let crash = TestUtils.requests(requestQueue(of: countly), carrying: "crash")
            .last?["crash"] as? [String: Any]
        XCTAssertEqual((crash?["_custom"] as? [String: Any])?["screen"] as? String, "cart")
    }
}
