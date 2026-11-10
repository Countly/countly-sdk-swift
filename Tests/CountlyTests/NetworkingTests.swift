//
//  NetworkingTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Getting a queued request onto the wire, and deciding whether it arrived.
///
/// The queue only gives up a request once the server has accepted it, so what
/// counts as acceptance is the single most consequential judgement in the SDK:
/// judge too strictly and a perfectly good request is re-sent forever, judge too
/// loosely and data is dropped on the floor.
final class NetworkingTests: CountlyBaseTestCase {

    /// Every test here asserts on what reached the transport, so the whole suite
    /// needs a transport it can see.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessNetworkIsInterceptable()
    }

    /// The request carrying the named event, waiting for it to reach the wire.
    ///
    /// The SDK sends a health check and a behavior settings fetch of its own as it
    /// starts, so the first request on the wire is rarely the one a test recorded.
    private func eventRequest(_ key: String,
                              file: StaticString = #filePath,
                              line: UInt = #line) -> MockURLProtocol.Captured? {
        TestUtils.waitUntil("the [\(key)] event reaches the wire", file: file, line: line) {
            MockURLProtocol.requests.contains { $0.query.contains(key) }
        }
        return MockURLProtocol.requests.first { $0.query.contains(key) }
    }

    // MARK: - Draining

    func testAnAcceptedRequestLeavesTheQueue() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("accepted")

        TestUtils.waitUntil("the queue drains") { self.requestQueue(of: countly).isEmpty }
    }

    /// A failure leaves the head where it is. That is what makes the SDK survive a
    /// dead network rather than losing everything recorded during it.
    func testAFailedRequestStaysAtTheHeadOfTheQueue() {
        // No handler is installed, so every request fails at the transport level.
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("not-accepted")
        TestUtils.pump(0.3)

        XCTAssertEqual(requestQueue(of: countly).count, 1)
    }

    /// The server reconstructs a session from an ordered sequence, so the drain
    /// sends one request at a time and in order.
    func testRequestsAreSentOneAtATimeInQueueOrder() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        for index in 0..<4 {
            countly.events.recordEvent("event-\(index)")
        }

        TestUtils.waitUntil("the queue drains") { self.requestQueue(of: countly).isEmpty }

        let sentKeys = MockURLProtocol.requests
            .compactMap { TestUtils.parseQuery($0.query)["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["key"] as? String }

        XCTAssertEqual(sentKeys, ["event-0", "event-1", "event-2", "event-3"])
    }

    // MARK: - Judging a response

    /// Every queued request is accepted only with a JSON object carrying
    /// `result`, also the A/B enrollment the queue sends to `/o/sdk`: that
    /// endpoint answers with `result` as well.
    func testAQueuedRequestToAnotherEndpointNeedsAResultField() {
        MockURLProtocol.respond { captured in
            captured.path.hasPrefix("/o") ? (200, Data(#"{"colour": "blue"}"#.utf8)) : nil
        }
        let countly = startInstance()

        countly.remoteConfig.enrollIntoABTests(forKeys: ["button_colour"])
        TestUtils.pump(0.4)
        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "keys").count, 1,
                       "a 2xx without result is not an acceptance")

        MockURLProtocol.reset()
        MockURLProtocol.respond { captured in
            captured.path.hasPrefix("/o") ? (200, Data(#"{"result": "Successfully enrolled in ab tests"}"#.utf8)) : nil
        }
        countly.requestQueue.attemptToSendStoredRequests()

        TestUtils.waitUntil("the enrollment is accepted") {
            TestUtils.requests(self.requestQueue(of: countly), carrying: "keys").isEmpty
        }
    }

    /// After a failure the queue waits for the cool-down: requests recorded in
    /// the meantime do not start an earlier attempt, so a server that is down is
    /// not hit by every event the application records.
    func testAFailedRequestWaitsForTheCooldownBeforeItIsTriedAgain() {
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.failedRequestCooldown = 1
        }
        let eventAttempts = { MockURLProtocol.requests.filter { $0.query.contains("events=") }.count }

        countly.events.recordEvent("first")
        TestUtils.waitUntil("the first attempt fails") { eventAttempts() == 1 }

        countly.events.recordEvent("second")
        countly.events.recordEvent("third")
        TestUtils.pump(0.3)
        XCTAssertEqual(eventAttempts(), 1, "nothing is sent while the cool-down runs")

        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        TestUtils.waitUntil("the queue drains once the cool-down is over", timeout: 5) {
            self.requestQueue(of: countly).isEmpty
        }
    }

    /// A 2xx with no `result` on the ingest endpoint is not an acceptance: the
    /// server did not say it stored anything.
    func testAnIngestResponseWithoutAResultFieldIsAFailure() {
        MockURLProtocol.respondToEverything(json: #"{"something": "else"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("not-really-accepted")
        TestUtils.pump(0.4)

        XCTAssertEqual(requestQueue(of: countly).count, 1)
    }

    func testANonSuccessStatusCodeIsAFailure() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#, status: 500)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("rejected")
        TestUtils.pump(0.4)

        XCTAssertEqual(requestQueue(of: countly).count, 1)
    }

    // MARK: - Request shape

    /// Every request, queued or immediate, is a form POST with its data in the
    /// body and only the path in the URL, which keeps personal data out of server
    /// and proxy access logs.
    func testEveryRequestIsAPOSTWithItsDataInTheBody() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("short")
        _ = eventRequest("short")

        XCTAssertGreaterThan(MockURLProtocol.requests.count, 1, "the start-up requests are checked as well")
        for request in MockURLProtocol.requests {
            XCTAssertEqual(request.method, "POST", "path: \(request.path)")
            XCTAssertNil(request.url.query, "nothing but the path goes into the URL, path: \(request.path)")
            XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded", "path: \(request.path)")
        }
    }

    /// A request that skips the queue still tells the server how many requests
    /// wait on the device: the number queued at that moment.
    func testImmediateRequestsCarryTheQueuedRequestCount() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        _ = startInstance()

        TestUtils.waitUntil("the behavior settings fetch is sent") {
            MockURLProtocol.requests.contains { $0.query.contains("method=sc") }
        }
        let fetch = MockURLProtocol.requests.first { $0.query.contains("method=sc") }
        XCTAssertNotNil(TestUtils.parseQuery(fetch?.query ?? "")["rr"])
    }

    /// A URL has a length past which servers and proxies start refusing it, so a
    /// long request moves into a POST body rather than being truncated.
    func testALongRequestGoesOutAsAPOST() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkInternalLimits.maxValueSize = 10_000
        }

        countly.events.recordEvent("long", segmentation: ["blob": String(repeating: "x", count: 5_000)])

        let sent = eventRequest("long")
        XCTAssertEqual(sent?.method, "POST")
        XCTAssertTrue(sent?.query.contains("blob") == true)
    }

    // MARK: - The checksum

    /// With a salt configured every request carries a digest the server verifies,
    /// which is what stops someone replaying or forging one.
    func testASaltAddsAVerifiableChecksumToEveryRequest() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.secretSalt = "the-shared-secret"
        }

        countly.events.recordEvent("signed")

        guard let sent = eventRequest("signed")?.query else {
            XCTFail("the event request should have been sent")
            return
        }

        guard let range = sent.range(of: "&checksum256=") else {
            XCTFail("the request carries no checksum: \(sent)")
            return
        }
        let body = String(sent[sent.startIndex..<range.lowerBound])
        let checksum = String(sent[range.upperBound...])

        XCTAssertEqual(checksum, (body + "the-shared-secret").sha256Hex,
                       "the digest has to cover the request exactly as it was sent")
    }

    func testWithoutASaltNoChecksumIsAdded() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("unsigned")

        XCTAssertFalse(eventRequest("unsigned")?.query.contains("checksum256") == true,
                       "a digest of the literal string nil would be meaningless")
    }

    // MARK: - Custom headers and direct requests

    func testCustomHeadersReachTheRequest() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.addCustomNetworkRequestHeaders(["X-Tenant": "acme"])
        countly.events.recordEvent("with-headers")

        _ = eventRequest("with-headers")
        // The header is set on the session configuration, which is what every
        // request built from it then carries.
        let headers = core(of: countly).config.urlSessionConfiguration.httpAdditionalHeaders as? [String: String]
        XCTAssertEqual(headers?["X-Tenant"], "acme")
    }

    /// A direct request lets an application put something on the queue the SDK has
    /// no API for, but it may not overwrite the parameters the SDK owns.
    func testADirectRequestCarriesItsParametersButCannotOverrideTheSDKsOwn() {
        let countly = startInstance()

        countly.addDirectRequest([
            "custom_thing": "value",
            "device_id": "an-impostor",
            "app_key": "another-impostor",
        ])

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "custom_thing").last else {
            XCTFail("the direct request should have been queued")
            return
        }
        XCTAssertEqual(request["custom_thing"] as? String, "value")
        XCTAssertEqual(request["device_id"] as? String, Self.deviceID)
        XCTAssertEqual(request["app_key"] as? String, Self.appKey)
    }

    /// Keys and values are encoded by the SDK, so a value carrying the query
    /// separators arrives whole instead of splitting into parameters of its own.
    func testADirectRequestEncodesItsKeysAndValues() throws {
        let countly = startInstance()

        countly.addDirectRequest([
            "note": "a&b=c d+e/ü",
            "spaced key": "1",
        ])

        let raw = try XCTUnwrap(requestQueue(of: countly).last { $0.contains("dr=1") })
        XCTAssertTrue(raw.contains("&note=a%26b%3Dc%20d%2Be%2F%C3%BC"), raw)
        XCTAssertTrue(raw.contains("&spaced%20key=1"), raw)
        let request = TestUtils.parseQuery(raw)
        XCTAssertEqual(request["note"] as? String, "a&b=c d+e/ü")
        XCTAssertNil(request["b"], "the value split into a parameter of its own")
        TestUtils.assertBaseParameters(request)
    }

    func testAnEmptyDirectRequestQueuesNothing() {
        let countly = startInstance()
        let before = requestQueue(of: countly).count

        countly.addDirectRequest([:])
        countly.addDirectRequest(nil)

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    // MARK: - Flush runnables

    /// A flush runnable fires when the queue drains with nothing having failed,
    /// which is what lets a feature ask the server a question only once the server
    /// has seen everything leading up to it.
    func testAFlushRunnableFiresOnceTheQueueDrainsCleanly() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        let fired = expectation(description: "the flush runnable fires")
        fired.assertForOverFulfill = false
        countly.requestQueue.addQueueFlushRunnable { fired.fulfill() }

        countly.events.recordEvent("something to drain")

        wait(for: [fired], timeout: 5)
    }

    func testClearingFlushRunnablesStopsThemFiring() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        var fired = false
        countly.requestQueue.addQueueFlushRunnable { fired = true }
        countly.requestQueue.clearQueueFlushRunnables()

        countly.events.recordEvent("something to drain")
        TestUtils.waitUntil("the queue drains") { self.requestQueue(of: countly).isEmpty }
        TestUtils.pump(0.2)

        XCTAssertFalse(fired)
    }

    // MARK: - Metrics

    func testRecordingMetricsSendsThemOnTheirOwnRequest() {
        let countly = startInstance()

        countly.recordMetrics(["_custom_metric": "value"])

        guard let request = TestUtils.requests(requestQueue(of: countly), carrying: "metrics").last,
              let metrics = request["metrics"] as? [String: Any] else {
            XCTFail("recording metrics should have queued a request")
            return
        }
        XCTAssertEqual(metrics["_custom_metric"] as? String, "value")
        XCTAssertNotNil(metrics[MetricKey.os], "the override adds to the metrics rather than replacing them")
    }

    func testCustomMetricsFromTheConfigTravelWithTheSessionMetrics() {
        let countly = startInstance {
            $0.customMetrics = ["_tenant": "acme"]
            $0.manualSessionHandling = true
        }

        countly.sessions.beginSession()

        guard let begin = TestUtils.requests(requestQueue(of: countly), carrying: "begin_session").first,
              let metrics = begin["metrics"] as? [String: Any] else {
            XCTFail("the session should have begun with metrics")
            return
        }
        XCTAssertEqual(metrics["_tenant"] as? String, "acme")
    }
}
