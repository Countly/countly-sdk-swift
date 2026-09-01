//
//  APMTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The `apm` payload: how long things took.
///
/// A trace is a name, a type, a window of wall clock time and a bag of metrics.
/// The server charts the metrics under the name, so what these check is that each
/// kind of trace picks the right type, reports the right window, and does not
/// invent a trace for a timer that was never started.
final class APMTests: CountlyBaseTestCase {

    /// The `apm` objects queued so far, in order.
    private func traces(of instance: CountlyInstance) -> [[String: Any]] {
        TestUtils.requests(requestQueue(of: instance), carrying: "apm")
            .compactMap { $0["apm"] as? [String: Any] }
    }

    // MARK: - Network traces

    func testANetworkTraceCarriesTheFourMetricsTheServerCharts() {
        let countly = startInstance()

        countly.performance.recordNetworkTrace("GET /items",
                                               requestPayloadSize: 120,
                                               responsePayloadSize: 4096,
                                               responseStatusCode: 200,
                                               startTime: 1_000,
                                               endTime: 1_350)

        let recorded = traces(of: countly)
        XCTAssertEqual(recorded.count, 1)

        let trace = recorded[0]
        XCTAssertEqual(trace["type"] as? String, "network")
        XCTAssertEqual(trace["name"] as? String, "GET /items")
        XCTAssertEqual(TestUtils.int(trace["stz"]), 1_000)
        XCTAssertEqual(TestUtils.int(trace["etz"]), 1_350)

        let metrics = (trace["apm_metrics"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(metrics["response_time"]), 350)
        XCTAssertEqual(TestUtils.int(metrics["response_code"]), 200)
        XCTAssertEqual(TestUtils.int(metrics["request_payload_size"]), 120)
        XCTAssertEqual(TestUtils.int(metrics["response_payload_size"]), 4096)
    }

    func testANetworkTraceWithNoNameIsDropped() {
        let countly = startInstance()

        countly.performance.recordNetworkTrace("",
                                               requestPayloadSize: 0,
                                               responsePayloadSize: 0,
                                               responseStatusCode: 200,
                                               startTime: 1,
                                               endTime: 2)

        XCTAssertTrue(traces(of: countly).isEmpty)
    }

    /// An end before the start is the caller's mistake, not the SDK's, and losing
    /// the trace would hide it. It is recorded with the negative time it was given.
    func testATraceThatEndsBeforeItStartsIsStillRecorded() {
        let countly = startInstance()

        countly.performance.recordNetworkTrace("Backwards",
                                               requestPayloadSize: 0,
                                               responsePayloadSize: 0,
                                               responseStatusCode: 200,
                                               startTime: 2_000,
                                               endTime: 1_000)

        let metrics = (traces(of: countly).first?["apm_metrics"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(metrics["response_time"]), -1_000)
    }

    // MARK: - Custom traces

    func testACustomTraceReportsHowLongItRanAndAnyMetricsGivenToIt() {
        let countly = startInstance()

        countly.performance.startCustomTrace("image-decode")
        TestUtils.pump(0.25)
        countly.performance.endCustomTrace("image-decode", metrics: ["bytes": 2048])

        let recorded = traces(of: countly)
        XCTAssertEqual(recorded.count, 1)

        let trace = recorded[0]
        XCTAssertEqual(trace["type"] as? String, "device")
        XCTAssertEqual(trace["name"] as? String, "image-decode")

        let metrics = (trace["apm_metrics"] as? [String: Any]) ?? [:]
        XCTAssertEqual(TestUtils.int(metrics["bytes"]), 2048)

        let duration = TestUtils.int(metrics["duration"]) ?? -1
        XCTAssertGreaterThan(duration, 200, "the duration should span the wait, in milliseconds")
        XCTAssertLessThan(duration, 5_000)
    }

    func testEndingATraceThatWasNeverStartedRecordsNothing() {
        let countly = startInstance()

        countly.performance.endCustomTrace("never-started", metrics: nil)

        XCTAssertTrue(traces(of: countly).isEmpty)
    }

    func testStartingTheSameTraceTwiceKeepsTheFirstTimer() {
        let countly = startInstance()

        countly.performance.startCustomTrace("work")
        TestUtils.pump(0.25)
        countly.performance.startCustomTrace("work")
        countly.performance.endCustomTrace("work", metrics: nil)

        let metrics = (traces(of: countly).first?["apm_metrics"] as? [String: Any]) ?? [:]
        XCTAssertGreaterThan(TestUtils.int(metrics["duration"]) ?? -1, 200,
                             "restarting would have reset the timer and reported roughly zero")
    }

    func testCancellingATraceRecordsNothingAndReleasesTheName() {
        let countly = startInstance()

        countly.performance.startCustomTrace("abandoned")
        countly.performance.cancelCustomTrace("abandoned")
        countly.performance.endCustomTrace("abandoned", metrics: nil)

        XCTAssertTrue(traces(of: countly).isEmpty)

        countly.performance.startCustomTrace("abandoned")
        countly.performance.endCustomTrace("abandoned", metrics: nil)
        XCTAssertEqual(traces(of: countly).count, 1, "the name is free again after a cancel")
    }

    func testClearingAllTracesDiscardsEveryRunningTimer() {
        let countly = startInstance()

        countly.performance.startCustomTrace("a")
        countly.performance.startCustomTrace("b")
        countly.performance.clearAllCustomTraces()

        countly.performance.endCustomTrace("a", metrics: nil)
        countly.performance.endCustomTrace("b", metrics: nil)

        XCTAssertTrue(traces(of: countly).isEmpty)
    }

    // MARK: - The app start trace

    /// The app start trace measures how long the application took to become
    /// usable, so it has to start where the *process* did rather than where the
    /// SDK did. An application that does its own work before calling `start` would
    /// otherwise report only the remainder.
    func testTheAppStartTraceMeasuresFromProcessLaunchNotFromSDKStart() {
        let countly = startInstance {
            $0.apm.enableAppStartTimeTracking = true
            $0.apm.enableManualAppLoadedTrigger = true
        }

        countly.performance.appLoadingFinished()

        guard let trace = traces(of: countly).first(where: { $0["name"] as? String == "app_start" }) else {
            XCTFail("an app start trace should have been recorded")
            return
        }

        let metrics = (trace["apm_metrics"] as? [String: Any]) ?? [:]
        let duration = TestUtils.int(metrics["duration"]) ?? -1
        XCTAssertGreaterThan(duration, 0)

        // The test process has been alive for a while before this test ran, and the
        // SDK instance was built moments ago. A duration measured from SDK start
        // would be a handful of milliseconds; one measured from process launch is
        // not.
        XCTAssertGreaterThan(duration, 100,
                             "the trace looks like it started at SDK init rather than at launch")
    }

    func testTheAppStartTraceIsRecordedOnlyOncePerLaunch() {
        let countly = startInstance {
            $0.apm.enableAppStartTimeTracking = true
            $0.apm.enableManualAppLoadedTrigger = true
        }

        countly.performance.appLoadingFinished()
        countly.performance.appLoadingFinished()

        let appStarts = traces(of: countly).filter { $0["name"] as? String == "app_start" }
        XCTAssertEqual(appStarts.count, 1)
    }

    /// Without the manual trigger the SDK has no reliable moment to call the launch
    /// finished, so the trace would be meaningless and is not recorded at all.
    func testTheAppStartTraceNeedsBothSwitches() {
        let countly = startInstance { $0.apm.enableAppStartTimeTracking = true }

        countly.performance.appLoadingFinished()

        XCTAssertTrue(traces(of: countly).filter { $0["name"] as? String == "app_start" }.isEmpty)
    }

    /// An application that knows its own launch moment better than the kernel does
    /// can say so, which is what the override is for.
    func testTheAppStartTimestampCanBeOverridden() {
        let override = Int64(Date().timeIntervalSince1970 * 1000) - 5_000
        let countly = startInstance {
            $0.apm.enableAppStartTimeTracking = true
            $0.apm.enableManualAppLoadedTrigger = true
            $0.apm.appStartTimestampOverride = override
        }

        countly.performance.appLoadingFinished()

        guard let trace = traces(of: countly).first(where: { $0["name"] as? String == "app_start" }) else {
            XCTFail("an app start trace should have been recorded")
            return
        }
        XCTAssertEqual(TestUtils.int(trace["stz"]).map(Int64.init), override)

        let duration = TestUtils.int((trace["apm_metrics"] as? [String: Any])?["duration"]) ?? 0
        XCTAssertGreaterThanOrEqual(duration, 5_000)
    }

    // MARK: - Foreground and background stretches

    /// With the tracking on, the SDK opens a stretch as it starts and closes it
    /// when the application changes state, so the two traces between them account
    /// for the whole time the application was running.
    func testForegroundAndBackgroundStretchesAreTraced() {
        let countly = startInstance { $0.apm.enableForegroundBackgroundTracking = true }

        // Whichever stretch is open, moving to the other state closes it and opens
        // the other one.
        let apm = core(of: countly).modules.apm
        apm.endBackgroundTrace()
        TestUtils.pump(0.1)

        let names = traces(of: countly).compactMap { $0["name"] as? String }
        XCTAssertTrue(names.allSatisfy { $0 == "app_in_foreground" || $0 == "app_in_background" },
                      "only the two stretch traces should have been recorded, got \(names)")
    }

    /// Without the switch there are no stretches at all, so an application that did
    /// not ask for them is not charged for them.
    func testNoStretchIsTracedWithoutTheSwitch() {
        let countly = startInstance { $0.apm.enableForegroundBackgroundTracking = false }

        core(of: countly).modules.apm.endBackgroundTrace()
        TestUtils.pump(0.1)

        XCTAssertTrue(traces(of: countly).filter {
            ($0["name"] as? String)?.hasPrefix("app_in_") == true
        }.isEmpty)
    }

    func testStretchTracingNeedsPerformanceMonitoringConsent() {
        let countly = startInstance {
            $0.requiresConsent = true
            $0.apm.enableForegroundBackgroundTracking = true
        }

        core(of: countly).modules.apm.endBackgroundTrace()
        TestUtils.pump(0.1)

        XCTAssertTrue(traces(of: countly).isEmpty)
    }

    /// Halting has to take the observers down with it, or a stretch keeps being
    /// timed for an instance that no longer exists.
    func testHaltingStopsTheStretchTracing() {
        let countly = startInstance { $0.apm.enableForegroundBackgroundTracking = true }
        countly.halt()

        // Nothing to assert beyond surviving the teardown: the observers are gone,
        // so a later application state change reaches nothing.
        NotificationCenter.default.post(name: Notification.Name("CountlyTestUnrelated"), object: nil)
        TestUtils.pump(0.1)
    }

    // MARK: - Consent and limits

    func testNoTraceIsRecordedWithoutPerformanceMonitoringConsent() {
        let countly = startInstance { $0.requiresConsent = true }

        countly.performance.startCustomTrace("blocked")
        countly.performance.endCustomTrace("blocked", metrics: nil)
        countly.performance.recordNetworkTrace("also blocked",
                                               requestPayloadSize: 0,
                                               responsePayloadSize: 0,
                                               responseStatusCode: 200,
                                               startTime: 1,
                                               endTime: 2)

        XCTAssertTrue(traces(of: countly).isEmpty)

        countly.consent.giveConsent(for: .performanceMonitoring)
        countly.performance.startCustomTrace("allowed")
        countly.performance.endCustomTrace("allowed", metrics: nil)
        XCTAssertEqual(traces(of: countly).count, 1)
    }

    func testTraceNamesAreTruncatedToTheKeyLimit() {
        let countly = startInstance { $0.sdkInternalLimits.maxKeyLength = 6 }

        countly.performance.recordNetworkTrace("a-very-long-trace-name",
                                               requestPayloadSize: 0,
                                               responsePayloadSize: 0,
                                               responseStatusCode: 200,
                                               startTime: 1,
                                               endTime: 2)

        XCTAssertEqual(traces(of: countly).first?["name"] as? String, "a-very")
    }
}
