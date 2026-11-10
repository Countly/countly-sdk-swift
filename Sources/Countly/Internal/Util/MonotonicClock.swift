//
//  MonotonicClock.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Strictly monotonic millisecond clock and event-ID source, one per instance.
///
/// The server orders events inside a batch by their timestamp, so two events
/// recorded in the same millisecond must not report the same value. When the
/// wall clock has not advanced past the last issued value the clock returns
/// `last + 1`.
///
/// This is deliberately **not** a static helper. A process-wide counter lets a
/// high-throughput burst on one instance push a sibling instance's timestamps
/// into the future, because the drift is then bounded by the sum of all
/// instances' call rates rather than each instance's own rate. It also leaks
/// state between tests.
final class MonotonicClock {

    private let lock = NSLock()
    private var lastMs: Int64 = 0

    /// Launch time of this clock, on the monotonic uptime clock rather than the
    /// wall clock, so a user changing the device time cannot make the SDK report a
    /// negative run length.
    private let startUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// Seconds since the epoch, guaranteed greater than the previous call.
    func now() -> TimeInterval {
        TimeInterval(nowMs()) / 1000.0
    }

    /// Milliseconds since the epoch, guaranteed greater than the previous call.
    func nowMs() -> Int64 {
        lock.lock()
        defer { lock.unlock() }

        let wall = Int64((Date().timeIntervalSince1970 * 1000).rounded(.down))
        if wall <= lastMs {
            lastMs += 1
        } else {
            lastMs = wall
        }
        return lastMs
    }

    /// Six random bytes in base64 with the issuing timestamp appended.
    ///
    /// The trailing timestamp comes from this same clock, so an event's ID never
    /// encodes a moment earlier than the event's own `timestamp` field.
    func generateEventID() -> String {
        var randomBytes = [UInt8](repeating: 0, count: 6)
        for index in randomBytes.indices {
            randomBytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        let randomBase64 = Data(randomBytes).base64EncodedString()
        return "\(randomBase64)\(nowMs())"
    }

    /// Whole seconds elapsed since this clock was created.
    func timeSinceLaunch() -> Int {
        Int(ProcessInfo.processInfo.systemUptime - startUptime)
    }

    /// Seconds on a clock that only moves forward, also while the device sleeps,
    /// whatever the user does to the device's date and time. For measuring
    /// durations, such as a session's.
    func monotonicSeconds() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    // MARK: - Calendar fields sent as base parameters

    /// Autoupdating so that a device changing region mid-session does not leave
    /// `hour` and `dow` computed in the old zone while `tz` reports the new one.
    private static let gregorian: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.autoupdatingCurrent
        return calendar
    }()

    /// The hour of `date`, now by default.
    func hourOfDay(at date: Date = Date()) -> Int {
        MonotonicClock.gregorian.component(.hour, from: date)
    }

    /// The weekday of `date`, now by default. Sunday is 0, matching the server's
    /// expectation.
    func dayOfWeek(at date: Date = Date()) -> Int {
        MonotonicClock.gregorian.component(.weekday, from: date) - 1
    }

    /// Offset from GMT in minutes.
    func timeZoneOffsetMinutes() -> Int {
        TimeZone.current.secondsFromGMT() / 60
    }
}
