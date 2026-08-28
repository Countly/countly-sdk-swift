//
//  HealthTrackerTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The `hc` payload: how badly the SDK behaved during the previous run.
///
/// The counters are wire data rather than diagnostics, which makes them easy to
/// get subtly wrong: they are gathered even when logging is switched off, they
/// survive a process restart, and they are cleared only once the server has
/// actually accepted them. Each of those is a way to lose or double-count a
/// number the dashboard then reports as fact.
final class HealthTrackerTests: CountlyBaseTestCase {

    /// The `hc` object of the most recent health check, waiting for at least
    /// `count` of them to have been sent.
    private func healthCheck(after count: Int = 1, timeout: TimeInterval = 5) -> [String: Any]? {
        TestUtils.waitUntil("\(count) health check(s) sent", timeout: timeout) {
            self.healthChecks.count >= count
        }
        guard let request = healthChecks.last else { return nil }
        return TestUtils.parseQuery(request.query)["hc"] as? [String: Any]
    }

    private var healthChecks: [MockURLProtocol.Captured] {
        MockURLProtocol.requests.filter { $0.query.contains("hc=") }
    }

    /// Starts an instance whose start-up health check fails, so the once-per-launch
    /// claim is released and the test can send a second one carrying whatever it
    /// recorded in between.
    ///
    /// Without this the counters read back would be the ones from init, taken
    /// before the test did anything.
    private func instanceWithFailedStartupCheck() -> CountlyInstance {
        // No handler is installed yet, so every request fails at the transport level.
        let countly = startInstance()
        TestUtils.waitUntil("the start-up health check has been attempted") {
            !self.healthChecks.isEmpty
        }
        TestUtils.pump(0.2)
        return countly
    }

    // MARK: - The payload

    /// The health check goes out on its own, immediately, because a build that is
    /// misbehaving badly enough to matter may never drain its queue.
    func testTheHealthCheckIsSentOnceAtStartWithEveryCounter() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)

        _ = startInstance()

        guard let payload = healthCheck() else {
            XCTFail("a health check should have been sent")
            return
        }

        XCTAssertNotNil(payload["el"], "error count")
        XCTAssertNotNil(payload["wl"], "warning count")
        XCTAssertNotNil(payload["sc"], "last failing status code")
        XCTAssertNotNil(payload["em"], "last error message")
        XCTAssertNotNil(payload["bom"], "backoff request count")
        XCTAssertNotNil(payload["cbom"], "consecutive backoff peak")
    }

    func testTheHealthCheckGoesToTheInputEndpoint() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)

        _ = startInstance()

        TestUtils.waitUntil("a health check is sent") {
            MockURLProtocol.requests.contains { $0.query.contains("hc=") }
        }
        let request = MockURLProtocol.requests.first { $0.query.contains("hc=") }
        XCTAssertEqual(request?.path, "/i")
    }

    /// Once per launch, whatever else happens. A second one would double count the
    /// same run.
    func testOnlyOneHealthCheckIsSentPerLaunch() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)

        let countly = startInstance { $0.deviceID = "starting-id" }
        _ = healthCheck()

        // Leaving temporary mode triggers another send, and so does anything else
        // that decides the SDK is newly able to report.
        countly.deviceID.changeWithMerge("a-new-id")
        TestUtils.pump(0.3)

        XCTAssertEqual(healthChecks.count, 1)
    }

    // MARK: - Counting

    /// The counters are fed by the logger itself, at error and warning level, even
    /// when logging is switched off. Raising a log line from debug to warning is
    /// therefore a change to this payload rather than a cosmetic one.
    func testErrorsAndWarningsAreCountedEvenWithLoggingOff() {
        let countly = instanceWithFailedStartupCheck()
        core(of: countly).config.enableDebug = false
        let tracker = core(of: countly).healthTracker

        core(of: countly).logger.e("Test", "test", "an error")
        core(of: countly).logger.e("Test", "test", "another error")
        core(of: countly).logger.w("Test", "test", "a warning")

        // Read through a send, which is the only thing that snapshots the counters.
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        tracker.sendHealthCheck(isDeviceIDTemporary: false, networkingEnabled: true)

        guard let payload = healthCheck(after: 2) else {
            XCTFail("the health check should have been sent")
            return
        }
        XCTAssertGreaterThanOrEqual(TestUtils.int(payload["el"]) ?? 0, 2)
        XCTAssertGreaterThanOrEqual(TestUtils.int(payload["wl"]) ?? 0, 1)
    }

    func testAFailedRequestRecordsItsStatusCodeAndMessage() {
        let countly = instanceWithFailedStartupCheck()
        let tracker = core(of: countly).healthTracker

        tracker.logFailedNetworkRequest(statusCode: 503, errorResponse: "service unavailable")

        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        tracker.sendHealthCheck(isDeviceIDTemporary: false, networkingEnabled: true)

        guard let payload = healthCheck(after: 2) else {
            XCTFail("the health check should have been sent")
            return
        }
        XCTAssertEqual(TestUtils.int(payload["sc"]), 503)
        XCTAssertEqual(payload["em"] as? String, "service unavailable")
    }

    /// One enormous server error must not bloat every health check from then on.
    func testAVeryLongErrorMessageIsTruncated() {
        let countly = instanceWithFailedStartupCheck()
        let tracker = core(of: countly).healthTracker

        tracker.logFailedNetworkRequest(statusCode: 500,
                                        errorResponse: String(repeating: "x", count: 5_000))

        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        tracker.sendHealthCheck(isDeviceIDTemporary: false, networkingEnabled: true)

        guard let payload = healthCheck(after: 2) else {
            XCTFail("the health check should have been sent")
            return
        }
        XCTAssertLessThanOrEqual((payload["em"] as? String ?? "").count, 1_000)
    }

    /// `cbom` is the longest unbroken run of backed-off requests, not the current
    /// one, so the peak has to survive the streak being broken.
    func testTheConsecutiveBackoffPeakIsRememberedAfterTheStreakBreaks() {
        let countly = instanceWithFailedStartupCheck()
        let tracker = core(of: countly).healthTracker

        // Each backed-off request extends the running streak.
        tracker.logBackoffRequest()
        tracker.logBackoffRequest()
        tracker.logBackoffRequest()
        // A request that was not backed off closes it, which is what turns the
        // running count into a remembered peak.
        tracker.logConsecutiveBackoffRequest()

        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        tracker.sendHealthCheck(isDeviceIDTemporary: false, networkingEnabled: true)

        guard let payload = healthCheck(after: 2) else {
            XCTFail("the health check should have been sent")
            return
        }
        XCTAssertGreaterThanOrEqual(TestUtils.int(payload["cbom"]) ?? 0, 3)
    }

    // MARK: - Persistence

    /// The counters describe a run that may have ended in a crash, so they have to
    /// survive the process that recorded them.
    func testTheCountersSurviveARestart() {
        let name = uniqueInstanceName()

        let first = start(baseConfig(instanceName: name))
        core(of: first).logger.e("Test", "test", "an error before the restart")
        core(of: first).healthTracker.clearAndSave()
        core(of: first).logger.e("Test", "test", "another error")
        core(of: first).healthTracker.saveState()
        first.halt()

        MockURLProtocol.reset()
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        _ = start(baseConfig(instanceName: name))

        guard let payload = healthCheck() else {
            XCTFail("the health check should have been sent")
            return
        }
        XCTAssertGreaterThanOrEqual(TestUtils.int(payload["el"]) ?? 0, 1,
                                    "the error recorded before the restart should still be counted")
    }

    // MARK: - Gates

    /// In temporary mode nothing may be attributed, and the health check carries a
    /// device ID like every other request.
    func testNoHealthCheckIsSentInTemporaryDeviceIDMode() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)

        _ = startInstance { $0.temporaryDeviceIDMode = true }
        TestUtils.pump(0.3)

        XCTAssertTrue(healthChecks.isEmpty)
    }

    func testNoHealthCheckIsSentWhileTheServerHasNetworkingOff() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)

        _ = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().networking(false).json()
        }
        TestUtils.pump(0.3)

        XCTAssertTrue(healthChecks.isEmpty)
    }
}
