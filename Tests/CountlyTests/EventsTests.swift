//
//  EventsTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// What an event looks like by the time it reaches the request queue.
///
/// Events are the SDK's highest-traffic feature and the one the server is
/// strictest about, so these check the produced JSON rather than internal state:
/// the batch shape, the count and sum, the timed-event duration, what the SDK
/// limits do to a key and to segmentation, and the consent and server-config gates
/// that decide whether an event exists at all.
final class EventsTests: CountlyBaseTestCase {

    // MARK: - Recording

    func testRecordingAnEventPutsItInTheBatchWithTheDefaults() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("purchase")

        let queue = requestQueue(of: countly)
        guard let request = TestUtils.request(queue, at: 0) else { return }

        TestUtils.assertBaseParameters(request)
        let events = TestUtils.events(in: request)
        XCTAssertEqual(events.count, 1)
        TestUtils.assertEvent(events[0], key: "purchase", count: 1, sum: 0, duration: 0)
    }

    func testCountSumDurationAndSegmentationAllReachTheWire() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("purchase",
                                   segmentation: ["item": "book", "price": 12],
                                   count: 3,
                                   sum: 36.5,
                                   duration: 7.25)

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let events = TestUtils.events(in: request)
        XCTAssertEqual(events.count, 1)
        TestUtils.assertEvent(events[0],
                              key: "purchase",
                              count: 3,
                              sum: 36.5,
                              duration: 7.25,
                              segmentation: ["item": "book", "price": 12])
    }

    /// A count below one would tell the server the event happened zero or minus one
    /// times. Clamping keeps the call from being silently meaningless.
    func testCountBelowOneIsClampedRatherThanDropped() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("zero", count: 0)
        countly.events.recordEvent("negative", count: -5)

        let queue = requestQueue(of: countly)
        XCTAssertEqual(queue.count, 2)

        for (index, key) in ["zero", "negative"].enumerated() {
            guard let request = TestUtils.request(queue, at: index) else { continue }
            TestUtils.assertEvent(TestUtils.events(in: request)[0], key: key, count: 1)
        }
    }

    func testAnEmptyKeyRecordsNothing() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("")

        XCTAssertTrue(requestQueue(of: countly).isEmpty,
                      "an event with no key has nothing for the server to aggregate on")
    }

    /// The batch is what makes events cheap: they accumulate in memory and go out
    /// as one request once the threshold is reached, not one request each.
    func testEventsAccumulateUntilTheThresholdAndThenGoOutAsOneRequest() {
        let countly = startInstance { $0.eventSendThreshold = 3 }

        countly.events.recordEvent("one")
        countly.events.recordEvent("two")
        XCTAssertTrue(requestQueue(of: countly).isEmpty,
                      "below the threshold nothing should have been queued yet")

        countly.events.recordEvent("three")

        let queue = requestQueue(of: countly)
        XCTAssertEqual(queue.count, 1, "the whole batch is one request")
        guard let request = TestUtils.request(queue, at: 0) else { return }

        let events = TestUtils.events(in: request)
        XCTAssertEqual(events.map { $0["key"] as? String }, ["one", "two", "three"],
                       "the batch preserves the order the events were recorded in")
    }

    /// Every event carries the ID of the one before it, which is the chain the
    /// server walks to reconstruct a user's path.
    func testEachEventPointsAtItsPredecessor() {
        let countly = startInstance { $0.eventSendThreshold = 3 }

        countly.events.recordEvent("first")
        countly.events.recordEvent("second")
        countly.events.recordEvent("third")

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let events = TestUtils.events(in: request)
        XCTAssertEqual(events.count, 3)

        let ids = events.map { $0["id"] as? String ?? "" }
        XCTAssertEqual(events[0]["peid"] as? String ?? "", "",
                       "the first event of the process has no predecessor")
        XCTAssertEqual(events[1]["peid"] as? String, ids[0])
        XCTAssertEqual(events[2]["peid"] as? String, ids[1])
        XCTAssertEqual(Set(ids).count, 3, "two events must never share an ID")
    }

    // MARK: - Timed events

    func testATimedEventReportsHowLongItRan() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.startEvent("download")
        TestUtils.pump(0.25)
        countly.events.endEvent("download", segmentation: ["source": "cdn"])

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let event = TestUtils.events(in: request)[0]

        TestUtils.assertEvent(event, key: "download", segmentation: ["source": "cdn"])
        let duration = TestUtils.double(event["dur"]) ?? 0
        XCTAssertGreaterThan(duration, 0.2, "the duration should span the wait")
        XCTAssertLessThan(duration, 5, "the duration should not be a wall clock artefact")
    }

    func testEndingATimedEventThatWasNeverStartedRecordsNothing() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.endEvent("never-started")

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    func testStartingTheSameTimedEventTwiceKeepsTheFirstTimer() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.startEvent("upload")
        TestUtils.pump(0.25)
        // The second start is ignored, so the duration is measured from the first.
        countly.events.startEvent("upload")
        countly.events.endEvent("upload")

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let duration = TestUtils.double(TestUtils.events(in: request)[0]["dur"]) ?? 0
        XCTAssertGreaterThan(duration, 0.2,
                             "restarting would have reset the timer and reported roughly zero")
    }

    func testCancellingATimedEventRecordsNothingAndReleasesTheKey() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.startEvent("aborted")
        countly.events.cancelEvent("aborted")
        countly.events.endEvent("aborted")

        XCTAssertTrue(requestQueue(of: countly).isEmpty,
                      "a cancelled timer must not produce an event, and ending it again must not either")

        // The key is free again, which is the point of cancelling rather than ending.
        countly.events.startEvent("aborted")
        countly.events.endEvent("aborted")
        XCTAssertEqual(requestQueue(of: countly).count, 1)
    }

    // MARK: - SDK limits

    func testKeysAndSegmentationAreTruncatedToTheConfiguredLimits() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkInternalLimits.maxKeyLength = 5
            $0.sdkInternalLimits.maxValueSize = 4
        }

        countly.events.recordEvent("a-very-long-event-key",
                                   segmentation: ["a-very-long-segmentation-key": "a-very-long-value"])

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let event = TestUtils.events(in: request)[0]

        XCTAssertEqual(event["key"] as? String, "a-ver")
        let segmentation = (event["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(Array(segmentation.keys), ["a-ver"])
        XCTAssertEqual(segmentation["a-ver"] as? String, "a-ve")
    }

    func testSegmentationIsCappedToTheConfiguredValueCount() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkInternalLimits.maxSegmentationValues = 2
        }

        countly.events.recordEvent("capped", segmentation: ["a": 1, "b": 2, "c": 3, "d": 4])

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let segmentation = (TestUtils.events(in: request)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(segmentation.count, 2)
    }

    /// The server stores numbers, strings, booleans and lists of those. Anything
    /// else is dropped key by key rather than failing the whole event, so one bad
    /// value cannot cost the rest of the segmentation. A date is the exception:
    /// the server reads one as epoch milliseconds, so it is converted.
    func testUnsupportedSegmentationValuesAreDroppedWithoutLosingTheEvent() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("mixed", segmentation: [
            "number": 42,
            "text": "value",
            "list": ["a", 1],
            "binary": Data([0x01]),
            "date": Date(timeIntervalSince1970: 1_700_000_000),
        ])

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let segmentation = (TestUtils.events(in: request)[0]["segmentation"] as? [String: Any]) ?? [:]

        XCTAssertEqual(Set(segmentation.keys), ["number", "text", "list", "date"])
        XCTAssertEqual((segmentation["date"] as? NSNumber)?.int64Value, 1_700_000_000_000,
                       "the date should have reached the wire as epoch milliseconds")
    }

    /// A number JSON cannot represent is dropped on its own. Kept, it makes the
    /// whole batch unserializable, and every event recorded around it is lost.
    func testANonFiniteSegmentationValueDoesNotCostTheOtherEvents() {
        let countly = startInstance { $0.eventSendThreshold = 3 }

        countly.events.recordEvent("a")
        countly.events.recordEvent("b", segmentation: ["ratio": Double.nan, "kept": "yes"])
        countly.events.recordEvent("c", segmentation: ["load": Double.infinity])

        let events = requestQueue(of: countly)
            .map(TestUtils.parseQuery)
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
        XCTAssertEqual(events.compactMap { $0["key"] as? String }.filter { ["a", "b", "c"].contains($0) }, ["a", "b", "c"],
                       "every event should survive a bad value in one of them")
        let b = events.first { $0["key"] as? String == "b" }?["segmentation"] as? [String: Any]
        XCTAssertEqual(b?["kept"] as? String, "yes")
        XCTAssertNil(b?["ratio"])
    }

    /// A sum or a duration JSON cannot represent is ignored with its default used,
    /// and counted for the health check, so the batch around it still goes out.
    func testANonFiniteSumOrDurationDoesNotCostTheOtherEvents() {
        let countly = startInstance { $0.eventSendThreshold = 3 }

        countly.events.recordEvent("a")
        countly.events.recordEvent("b", sum: .nan)
        countly.events.recordEvent("c", duration: .infinity)

        let events = TestUtils.requests(requestQueue(of: countly), carrying: "events")
            .flatMap { TestUtils.events(in: $0) }
            .filter { ["a", "b", "c"].contains($0["key"] as? String ?? "") }
        XCTAssertEqual(events.compactMap { $0["key"] as? String }, ["a", "b", "c"])
        XCTAssertEqual(logCodeCount(HealthLogCode.eventValueIgnored, of: countly), 2)
        guard events.count == 3 else { return }
        XCTAssertEqual(TestUtils.double(events[1]["sum"]), 0)
        XCTAssertEqual(TestUtils.double(events[2]["dur"]), 0)
    }

    /// An event recorded with an earlier timestamp, such as a notification tap
    /// replayed at the start, carries the hour and the weekday of that moment.
    func testAnEventCarriesTheHourAndWeekdayOfItsOwnTimestamp() throws {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let earlier = try XCTUnwrap(calendar.date(byAdding: .hour, value: -27, to: Date()))

        core(of: countly).modules.events.recordReservedEvent(ReservedEventKey.pushAction,
                                                             segmentation: ["i": "n-1"],
                                                             timestamp: earlier.timeIntervalSince1970)

        let event = try XCTUnwrap(TestUtils.requests(requestQueue(of: countly), carrying: "events")
            .flatMap { TestUtils.events(in: $0) }
            .first { $0["key"] as? String == ReservedEventKey.pushAction })
        XCTAssertEqual(TestUtils.int(event["hour"]), calendar.component(.hour, from: earlier))
        XCTAssertEqual(TestUtils.int(event["dow"]), calendar.component(.weekday, from: earlier) - 1)
    }

    // MARK: - Consent

    func testNoEventIsRecordedWithoutEventsConsent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }

        countly.events.recordEvent("blocked")
        countly.events.startEvent("also-blocked")
        countly.events.endEvent("also-blocked")

        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "events").isEmpty)

        countly.consent.giveConsent(for: .events)
        countly.events.recordEvent("allowed")

        let recorded = TestUtils.requests(requestQueue(of: countly), carrying: "events")
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(TestUtils.events(in: recorded[0])[0]["key"] as? String, "allowed")
    }

    func testAHostRecordedReservedEventAnswersToItsOwnFeatureConsentAndTheLimits() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
            $0.sdkInternalLimits.maxValueSize = 5
        }

        // Feedback consent is missing, so the rating widget event is dropped even though it is reserved.
        countly.events.recordReservedEvent(.ratingWidget, segmentation: ["comment": "kept short"])
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "events").isEmpty)

        countly.consent.giveConsent(for: .feedback)
        countly.events.recordReservedEvent(.ratingWidget, segmentation: ["comment": "kept short"])

        let recorded = TestUtils.requests(requestQueue(of: countly), carrying: "events")
        XCTAssertEqual(recorded.count, 1)
        let event = TestUtils.events(in: recorded[0])[0]
        XCTAssertEqual(event["key"] as? String, CountlyReservedEvent.ratingWidget.rawValue)
        // The segmentation went through the SDK limits like any other event's.
        XCTAssertEqual((event["segmentation"] as? [String: Any])?["comment"] as? String, "kept ")
    }

    func testAHostRecordedKeyThatIsNotReservedIsAnOrdinaryEvent() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.requiresConsent = true
        }

        countly.events.recordReservedEvent("custom_key")
        XCTAssertTrue(TestUtils.requests(requestQueue(of: countly), carrying: "events").isEmpty)

        countly.consent.giveConsent(for: .events)
        countly.events.recordReservedEvent("custom_key")
        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "events").count, 1)
    }

    // MARK: - Server config

    /// With tracking off the SDK records nothing new: an event is refused when it
    /// is recorded, counted for the health check, and never reaches the event
    /// queue, so it cannot go out once tracking is back on.
    func testWithTrackingOffAnEventIsRefusedWhenRecorded() {
        let countly = startInstance {
            $0.eventSendThreshold = 100
            $0.sdkBehaviorSettings = ServerConfigBuilder().tracking(false).json()
        }

        countly.events.recordEvent("refused")
        countly.events.recordEvent("refused-too")

        XCTAssertTrue(countly.events.recordedEvents().isEmpty)
        XCTAssertEqual(logCodeCount(HealthLogCode.trackingDisabled, of: countly), 2)
    }

    func testTheServerCanSwitchCustomEventTrackingOff() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().customEventTracking(false).json()
        }

        countly.events.recordEvent("suppressed")

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    func testTheServerEventBlacklistDropsOnlyTheListedKeys() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().eventBlacklist(["banned"]).json()
        }

        countly.events.recordEvent("banned")
        countly.events.recordEvent("allowed")

        let queue = requestQueue(of: countly)
        XCTAssertEqual(queue.count, 1)
        guard let request = TestUtils.request(queue, at: 0) else { return }
        XCTAssertEqual(TestUtils.events(in: request)[0]["key"] as? String, "allowed")
    }

    /// The server can cap the batch size, which overrides whatever the application
    /// configured locally.
    func testTheServerEventQueueSizeOverridesTheConfiguredThreshold() {
        let countly = startInstance {
            $0.eventSendThreshold = 100
            $0.sdkBehaviorSettings = ServerConfigBuilder().eventQueueSize(2).json()
        }

        countly.events.recordEvent("one")
        XCTAssertTrue(requestQueue(of: countly).isEmpty)
        countly.events.recordEvent("two")

        XCTAssertEqual(requestQueue(of: countly).count, 1)
    }

    // MARK: - Experimental segmentation

    /// `cly_v` reports whether the application was visible when the event happened,
    /// which is what separates a user action from a background timer firing.
    func testVisibilityTrackingAddsTheVisibilitySegmentation() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.experimental.enableVisibilityTracking = true
        }

        countly.events.recordEvent("visible")

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let segmentation = (TestUtils.events(in: request)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertNotNil(segmentation[SegKey.visibility], "cly_v should be present")
    }

    func testVisibilityTrackingIsOffByDefault() {
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("plain")

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let segmentation = (TestUtils.events(in: request)[0]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertNil(segmentation[SegKey.visibility])
    }

    /// The previous event name is opt in, and the first event of the process has
    /// none, which has to be an empty string rather than a missing key.
    func testPreviousEventNameRecordingChainsTheNames() {
        let countly = startInstance {
            $0.eventSendThreshold = 2
            $0.experimental.enablePreviousNameRecording = true
        }

        countly.events.recordEvent("first")
        countly.events.recordEvent("second")

        guard let request = TestUtils.request(requestQueue(of: countly), at: 0) else { return }
        let events = TestUtils.events(in: request)

        let first = (events[0]["segmentation"] as? [String: Any]) ?? [:]
        let second = (events[1]["segmentation"] as? [String: Any]) ?? [:]
        XCTAssertEqual(first[SegKey.previousEventName] as? String, "")
        XCTAssertEqual(second[SegKey.previousEventName] as? String, "first")
    }
}
