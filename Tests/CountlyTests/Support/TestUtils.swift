//
//  TestUtils.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Reading and asserting on what the SDK put on the wire.
///
/// Every Countly SDK's test suite checks the same thing in the end: given a call,
/// what query string reached the request queue, and what does it carry. These are
/// the helpers that make that assertion one line, and they deliberately mirror the
/// ones the Android and Objective-C suites use so a behaviour tested in one is
/// recognisably the same test here.
enum TestUtils {

    // MARK: - Waiting

    /// Generous ceiling for every wait in the suite. A satisfied wait returns as
    /// soon as its condition holds, so a large timeout costs nothing when things
    /// work, and stops a loaded CI simulator, which is far slower than a developer
    /// machine, from tripping over a value tuned on one.
    static let asyncTimeout: TimeInterval = 20

    /// The ceiling for waits that depend on WebKit, which are the only ones whose
    /// slowest step is a process launch rather than work the SDK does.
    ///
    /// A content page needs the WebContent and Networking processes up before any
    /// of its own work starts, and on a contended runner those have been measured
    /// taking over thirty seconds each to launch, which is already past
    /// `asyncTimeout` before the page has done anything. Raising the general
    /// ceiling to cover that would make every unrelated hang take a minute to
    /// surface, so only the WebKit-bound suites pay it.
    static let webKitTimeout: TimeInterval = 90

    /// Polls `condition` until it holds or `timeout` elapses, pumping the run loop
    /// meanwhile, and reports whether it held.
    ///
    /// Returns as soon as it holds, so a satisfied wait costs no wall clock while a
    /// loaded CI runner still gets the time it needs. Always prefer this over a
    /// fixed sleep: a sleep either wastes time or expires before the work landed.
    @discardableResult
    static func waitUntil(_ description: String,
                          timeout: TimeInterval = TestUtils.asyncTimeout,
                          file: StaticString = #filePath,
                          line: UInt = #line,
                          _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        let held = condition()
        if !held {
            XCTFail("timed out waiting for: \(description)", file: file, line: line)
        }
        return held
    }

    /// Pumps the run loop for `seconds` without asserting anything, for the few
    /// cases where the thing being waited for is the *absence* of an effect.
    static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Parsing

    /// Splits a queued query string into its parameters, percent-decoding both
    /// sides and parsing any value that is a JSON object or array.
    ///
    /// A value that fails to parse as JSON stays the decoded string, so a test can
    /// assert on `events` as `[[String: Any]]` and on `app_key` as `String` without
    /// knowing which is which.
    static func parseQuery(_ queryString: String) -> [String: Any] {
        var result: [String: Any] = [:]

        for pair in queryString.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = String(parts[0]).removingPercentEncoding ?? String(parts[0])
            let raw = String(parts[1])
            let value = raw.removingPercentEncoding ?? raw

            if let json = jsonObject(from: value) {
                result[key] = json
            } else {
                result[key] = value
            }
        }

        return result
    }

    private static func jsonObject(from value: String) -> Any? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
                || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// The parsed parameters of the request at `index`, or `nil` after failing the
    /// test when the queue is shorter than that.
    static func request(_ queue: [String],
                        at index: Int,
                        file: StaticString = #filePath,
                        line: UInt = #line) -> [String: Any]? {
        guard queue.indices.contains(index) else {
            XCTFail("request index \(index) is out of bounds, the queue holds \(queue.count)",
                    file: file, line: line)
            return nil
        }
        return parseQuery(queue[index])
    }

    /// The parsed parameters of every request in the queue that carries `key`.
    static func requests(_ queue: [String], carrying key: String) -> [[String: Any]] {
        queue.map(parseQuery).filter { $0[key] != nil }
    }

    // MARK: - Assertions

    /// Asserts the nine parameters every request carries, whatever it is about.
    ///
    /// A request missing one of these is malformed no matter what else it says, so
    /// this runs on every request a test looks at rather than being opted into.
    static func assertBaseParameters(_ request: [String: Any],
                                     deviceID: String = CountlyBaseTestCase.deviceID,
                                     appKey: String = CountlyBaseTestCase.appKey,
                                     deviceIDType: Int = DeviceIDType.developerSupplied.rawValue,
                                     file: StaticString = #filePath,
                                     line: UInt = #line) {
        XCTAssertEqual(request["app_key"] as? String, appKey, "app_key", file: file, line: line)
        XCTAssertEqual(request["device_id"] as? String, deviceID, "device_id", file: file, line: line)
        XCTAssertEqual(request["t"] as? String, "\(deviceIDType)", "device ID type", file: file, line: line)
        XCTAssertEqual(request["sdk_name"] as? String, SDKIdentity.name, "sdk_name", file: file, line: line)
        XCTAssertEqual(request["sdk_version"] as? String, SDKIdentity.version, "sdk_version", file: file, line: line)

        guard let timestamp = int(request["timestamp"]),
              let hour = int(request["hour"]),
              let dayOfWeek = int(request["dow"]),
              let timeZone = int(request["tz"]) else {
            XCTFail("a time parameter is missing or not a number in \(request)", file: file, line: line)
            return
        }

        XCTAssertGreaterThan(timestamp, 0, "timestamp", file: file, line: line)
        XCTAssertTrue((0..<24).contains(hour), "hour is \(hour)", file: file, line: line)
        XCTAssertTrue((0..<7).contains(dayOfWeek), "dow is \(dayOfWeek)", file: file, line: line)
        // The widest real offset range, UTC-12:00 to UTC+14:00, in minutes.
        XCTAssertTrue((-720...840).contains(timeZone), "tz is \(timeZone)", file: file, line: line)
    }

    /// Asserts that `request` carries exactly the given key/value pairs on top of
    /// the base parameters. Values are compared as strings, so a test can write
    /// `["begin_session": 1]` for a parameter that arrives as `"1"`.
    static func assertParameters(_ expected: [String: Any],
                                 in request: [String: Any],
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        for (key, value) in expected {
            guard let actual = request[key] else {
                XCTFail("expected \(key)=\(value), but the request has no \(key): \(request)",
                        file: file, line: line)
                continue
            }
            XCTAssertEqual(describe(actual), describe(value),
                           "parameter \(key)", file: file, line: line)
        }
    }

    /// The events carried by a request, in the order they were recorded.
    static func events(in request: [String: Any],
                       file: StaticString = #filePath,
                       line: UInt = #line) -> [[String: Any]] {
        guard let events = request["events"] as? [[String: Any]] else {
            XCTFail("the request carries no events array: \(request)", file: file, line: line)
            return []
        }
        return events
    }

    /// Asserts the fields every event carries and returns its segmentation.
    @discardableResult
    static func assertEvent(_ event: [String: Any],
                            key: String,
                            count: Int = 1,
                            sum: Double? = nil,
                            duration: Double? = nil,
                            segmentation: [String: Any]? = nil,
                            file: StaticString = #filePath,
                            line: UInt = #line) -> [String: Any] {
        XCTAssertEqual(event["key"] as? String, key, "event key", file: file, line: line)
        XCTAssertEqual(int(event["count"]), count, "event count", file: file, line: line)

        if let sum {
            XCTAssertEqual(double(event["sum"]) ?? 0, sum, accuracy: 0.0001,
                           "event sum", file: file, line: line)
        }
        if let duration {
            XCTAssertEqual(double(event["dur"]) ?? 0, duration, accuracy: 0.0001,
                           "event duration", file: file, line: line)
        }

        // Every event carries its own clock reading and its place in the ID chain.
        XCTAssertGreaterThan(int(event["timestamp"]) ?? 0, 0, "event timestamp", file: file, line: line)
        XCTAssertTrue((0..<24).contains(int(event["hour"]) ?? -1), "event hour", file: file, line: line)
        XCTAssertTrue((0..<7).contains(int(event["dow"]) ?? -1), "event dow", file: file, line: line)
        assertEventID(event["id"], "id", file: file, line: line)

        let actual = (event["segmentation"] as? [String: Any]) ?? [:]
        if let segmentation {
            XCTAssertEqual(actual.count, segmentation.count,
                           "segmentation key count, expected \(segmentation) got \(actual)",
                           file: file, line: line)
            for (key, value) in segmentation {
                guard let found = actual[key] else {
                    XCTFail("missing segmentation key '\(key)' in \(actual)", file: file, line: line)
                    continue
                }
                XCTAssertEqual(describe(found), describe(value),
                               "segmentation \(key)", file: file, line: line)
            }
        }
        return actual
    }

    /// An event ID is a base64 random part followed by a 13 digit millisecond
    /// timestamp. The server relies on that shape to order a batch, so it is worth
    /// asserting rather than checking the field merely exists.
    static func assertEventID(_ value: Any?,
                              _ label: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) {
        guard let identifier = value as? String, !identifier.isEmpty else {
            XCTFail("\(label) is missing or empty", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(identifier.count, 13, "\(label) is too short: \(identifier)",
                             file: file, line: line)
        guard let timestamp = Int64(identifier.suffix(13)) else {
            XCTFail("\(label) does not end in a millisecond timestamp: \(identifier)",
                    file: file, line: line)
            return
        }
        XCTAssertGreaterThan(timestamp, 0, "\(label) timestamp", file: file, line: line)
    }

    // MARK: - Coercion

    /// Query string values arrive as strings and JSON values as numbers, so every
    /// numeric assertion goes through these rather than through a single cast.
    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as Int: return number
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text)
        default: return nil
        }
    }

    /// Reads a value that does not fit an `Int` on every platform.
    ///
    /// `Int` is 32 bits on watchOS, and a millisecond epoch is not: `int(_:)`
    /// truncates one there, and a literal to compare it against does not even
    /// compile. Timestamps go through this instead.
    static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as Int64: return number
        case let number as Int: return Int64(number)
        case let number as NSNumber: return number.int64Value
        case let text as String: return Int64(text)
        default: return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as Double: return number
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }

    /// A stable string for a value of unknown type, so `1`, `"1"` and `NSNumber(1)`
    /// compare equal in an assertion.
    static func describe(_ value: Any) -> String {
        switch value {
        case let number as NSNumber:
            // NSNumber bridges booleans too, and "1" is the right description for
            // both the boolean and the integer on the wire.
            if CFNumberIsFloatType(number) {
                let asDouble = number.doubleValue
                return asDouble == asDouble.rounded() ? "\(Int(asDouble))" : "\(asDouble)"
            }
            return "\(number.intValue)"
        case let text as String:
            return text
        case let list as [Any]:
            return "[" + list.map(describe).joined(separator: ",") + "]"
        case is NSNull:
            return "<null>"
        default:
            return "\(value)"
        }
    }
}
