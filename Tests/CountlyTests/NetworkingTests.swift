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

    /// Only the ingest endpoint promises a `result` field. The read endpoints
    /// answer with application payload of their own shape, so demanding `result`
    /// there marks a perfectly good response as a failure and leaves the request
    /// at the head of the queue to be re-sent on every later drain.
    func testAcceptanceIsJudgedPerEndpoint() {
        MockURLProtocol.respond { captured in
            captured.path == "/i" ? (200, Data(#"{"result": "Success"}"#.utf8)) : nil
        }
        MockURLProtocol.respond { captured in
            // A read endpoint answering with its own shape and no `result` field.
            captured.path.hasPrefix("/o") ? (200, Data(#"{"colour": "blue"}"#.utf8)) : nil
        }

        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("ingested")

        TestUtils.waitUntil("the ingest request is accepted") {
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

    func testAShortRequestGoesOutAsAGET() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance { $0.eventSendThreshold = 1 }

        countly.events.recordEvent("short")

        XCTAssertEqual(eventRequest("short")?.method, "GET")
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

    func testEveryRequestCanBeForcedIntoAPOST() {
        MockURLProtocol.respondToEverything(json: #"{"result": "Success"}"#)
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.alwaysUsePOST = true
        }

        countly.events.recordEvent("short-but-posted")

        XCTAssertEqual(eventRequest("short-but-posted")?.method, "POST")
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
