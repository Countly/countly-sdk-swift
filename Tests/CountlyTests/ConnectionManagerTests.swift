//
//  ConnectionManagerTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// The paths a request can take that are not the ordinary one.
///
/// `NetworkingTests` covers the happy path: queue a request, send it, decide
/// whether the server accepted it. These are the branches around it, each of which
/// exists because of a specific way the ordinary path fails: a server that is
/// overloaded rather than broken, a crash that must go out before the process
/// dies, a picture that cannot travel in a query string, and a request whose
/// caller is waiting for an answer.
final class ConnectionManagerTests: CountlyBaseTestCase {

    /// Every test here asserts on what reached the transport, so the whole suite
    /// needs a transport it can see.
    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipUnlessNetworkIsInterceptable()
    }

    private static let accepted = #"{"result": "Success"}"#

    // MARK: - Backing off

    /// A server that answers slowly while the queue is nearly empty is overloaded,
    /// not broken. Backing off gives it room instead of adding to the pile, which
    /// is the difference between a slow server recovering and a slow server being
    /// hammered by every client at once.
    ///
    /// Observed through the pause it causes rather than through the health check
    /// counter: the health check is sent once per launch and has already gone by
    /// the time a test could read it.
    func testASlowAnswerFromAnUnpressuredQueuePausesTheDrain() {
        MockURLProtocol.respondSlowly(after: 1.2, json: Self.accepted)

        let countly = startInstance {
            $0.eventSendThreshold = 1
            // A one second threshold with a queue that is nearly empty and a
            // request that is brand new: the three conditions the backoff needs,
            // all set through the same behaviour settings a server would send.
            $0.sdkBehaviorSettings = ServerConfigBuilder()
                .backoffMechanism(true)
                .bomAcceptedTimeout(1)
                .bomDuration(120)
                .json()
        }

        countly.events.recordEvent("slow-one")
        TestUtils.waitUntil("the first request is accepted") {
            self.requestQueue(of: countly).isEmpty
        }

        // The drain is now paused for the backoff duration, so the next request
        // stays put rather than being sent straight after.
        countly.events.recordEvent("slow-two")
        TestUtils.pump(1.0)

        XCTAssertFalse(requestQueue(of: countly).isEmpty,
                       "the backoff should have paused the drain, leaving this request queued")
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { !$0.query.contains("slow-two") },
                      "nothing recorded during the backoff should have reached the server")
    }

    /// The backoff is opt out, because an application talking to a server it
    /// controls may prefer to keep pushing.
    func testTheBackoffCanBeSwitchedOffLocally() {
        MockURLProtocol.respondSlowly(after: 1.2, json: Self.accepted)

        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.disableBackoffMechanism = true
        }

        XCTAssertFalse(core(of: countly).serverConfig.backoffMechanism,
                       "an explicit local opt out holds even against a server that says nothing")

        countly.events.recordEvent("slow")
        TestUtils.waitUntil("the slow request is accepted") {
            self.requestQueue(of: countly).isEmpty
        }
    }

    /// A fast answer is not a backoff, and the streak of consecutive backoffs has
    /// to be closed when one arrives.
    func testAFastAnswerDoesNotTriggerABackoff() {
        MockURLProtocol.respondToEverything(json: Self.accepted)

        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().backoffMechanism(true).json()
        }

        countly.events.recordEvent("fast")

        TestUtils.waitUntil("the queue drains") { self.requestQueue(of: countly).isEmpty }
    }

    // MARK: - Crash reports

    /// A crash the SDK detected itself may be the last thing the process does, so
    /// its report is sent on the spot rather than queued, and the call blocks until
    /// the server has answered.
    func testAnAutoDetectedCrashIsSentImmediatelyRatherThanQueued() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance { $0.features = [.crashReporting] }

        core(of: countly).modules.crashes.handleAutoDetectedCrash(
            name: "SIGSEGV", reason: "boom", stackTrace: ["0 MyApp 0x1 boom"])

        // Already delivered by the time the call returns, which is the point of the
        // immediate path.
        let sent = MockURLProtocol.requests.filter { $0.query.contains("crash=") }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.method, "POST")
        XCTAssertEqual(sent.first?.path, "/i")
        XCTAssertTrue(requestQueue(of: countly).filter { $0.contains("crash=") }.isEmpty,
                      "an accepted immediate report must not also sit in the queue")
    }

    /// If the immediate send fails, the report goes back into the queue rather than
    /// being lost: the crash still happened.
    func testAnAutoDetectedCrashThatCannotBeSentIsQueuedInstead() {
        // No handler, so the send fails at the transport level.
        let countly = startInstance { $0.features = [.crashReporting] }

        core(of: countly).modules.crashes.handleAutoDetectedCrash(
            name: "SIGSEGV", reason: "boom", stackTrace: ["0 MyApp 0x1 boom"])

        XCTAssertEqual(requestQueue(of: countly).filter { $0.contains("crash=") }.count, 1)
    }

    /// In temporary mode nothing may be attributed, so even a crash the SDK caught
    /// itself waits for a real device ID instead of going out under the placeholder.
    func testAnAutoDetectedCrashIsHeldBackInTemporaryDeviceIDMode() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance {
            $0.temporaryDeviceIDMode = true
            $0.features = [.crashReporting]
        }

        core(of: countly).modules.crashes.handleAutoDetectedCrash(
            name: "SIGSEGV", reason: "boom", stackTrace: ["0 MyApp 0x1 boom"])

        XCTAssertTrue(MockURLProtocol.requests.filter { $0.query.contains("crash=") }.isEmpty)
        XCTAssertEqual(requestQueue(of: countly).filter { $0.contains("crash=") }.count, 1)
    }

    /// An error the application reported itself is not urgent, however it is
    /// flagged: only a crash the SDK caught skips the queue.
    func testAManuallyRecordedErrorAlwaysGoesThroughTheQueue() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance()

        countly.crashes.recordError("handled", isFatal: false, stackTrace: [])
        countly.crashes.recordError("reported as fatal", isFatal: true, stackTrace: [])

        // Both go through the queue, so both are drained rather than sent on the
        // spot. Counted at the transport because a drained queue is empty.
        TestUtils.waitUntil("both reports drain") {
            MockURLProtocol.requests.filter { $0.query.contains("crash=") }.count == 2
        }
        XCTAssertTrue(MockURLProtocol.requests
            .filter { $0.query.contains("crash=") }
            .allSatisfy { $0.method == "GET" },
            "a queued report is an ordinary request, not the immediate POST")
    }

    // MARK: - Picture upload

    /// A local profile picture cannot travel in a query string, so the whole
    /// request is rebuilt as a multipart POST with the file as one of its parts and
    /// every query parameter as another.
    func testALocalProfilePictureIsSentAsAMultipartPost() throws {
        // The multipart upload is built only on the platforms with a profile
        // picture to upload; elsewhere the whole path is compiled out.
        #if !(os(iOS) || os(visionOS))
        throw XCTSkip("profile picture upload only exists on iOS and visionOS")
        #else
        MockURLProtocol.respondToEverything(json: Self.accepted)

        let picture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("countly-test-avatar-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }

        let countly = startInstance()
        countly.userProfile.setProperty("picturePath", value: picture.path)
        countly.userProfile.save()


        TestUtils.waitUntil("the picture upload is sent") {
            MockURLProtocol.requests.contains { $0.method == "POST" && $0.body.contains("form-data") }
        }

        guard let upload = MockURLProtocol.requests.last(where: { $0.body.contains("form-data") }) else {
            XCTFail("no multipart request was sent")
            return
        }

        // The parameters that would have been in the query string are parts now.
        XCTAssertTrue(upload.body.contains("name=\"app_key\""))
        XCTAssertTrue(upload.body.contains("name=\"device_id\""))
        XCTAssertTrue(upload.body.contains(Self.appKey))
        #endif
    }

    /// Integrations pass a `file://` URL as often as a plain path, because that is
    /// what most system APIs hand back. Both are accepted, and both have to resolve
    /// the same way in the readability check and in the read that builds the
    /// request: if those disagree the picture passes validation and then silently
    /// never uploads.
    func testAPictureIsUploadedWhicheverFormItsPathTakes() throws {
        #if !(os(iOS) || os(visionOS))
        throw XCTSkip("profile picture upload only exists on iOS and visionOS")
        #else
        let picture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("countly-test-avatar-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: picture)
        defer { try? FileManager.default.removeItem(at: picture) }

        for form in [picture.path, picture.absoluteString] {
            MockURLProtocol.reset()
            MockURLProtocol.respondToEverything(json: Self.accepted)

            let countly = startInstance()
            countly.userProfile.setProperty("picturePath", value: form)
            countly.userProfile.save()

            TestUtils.waitUntil("the picture at [\(form)] is uploaded") {
                MockURLProtocol.requests.contains { $0.body.contains("form-data") }
            }
        }
        #endif
    }

    /// A path pointing at nothing would produce a multipart request with no file,
    /// which the server rejects, so it is refused when it is set.
    func testAPicturePathThatPointsAtNothingIsRefused() {
        let countly = startInstance()

        countly.userProfile.setProperty("picturePath", value: "/definitely/not/a/real/file.png")
        countly.userProfile.save()

        XCTAssertTrue(requestQueue(of: countly).isEmpty)
    }

    // MARK: - Request callbacks

    /// A queued request can carry a callback, which is how a feature learns the
    /// server has seen something before asking about it. The callback lives in
    /// memory while the request itself survives a restart.
    func testAQueuedRequestCanReportItsOwnOutcome() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance()

        let reported = expectation(description: "the request reports back")
        core(of: countly).network.enqueue(
            "\(core(of: countly).network.builder.queryEssentials())&custom=1") { _, success in
            XCTAssertTrue(success)
            reported.fulfill()
        }
        core(of: countly).network.proceedOnQueue()

        wait(for: [reported], timeout: TestUtils.asyncTimeout)
    }

    func testAQueuedRequestWithNoQueryStringIsNotQueuedAtAll() {
        let countly = startInstance()
        let before = requestQueue(of: countly).count

        core(of: countly).network.enqueue("") { _, _ in
            XCTFail("an empty request should never be sent")
        }

        XCTAssertEqual(requestQueue(of: countly).count, before)
    }

    // MARK: - Dropping stale requests during a drain

    /// A request past its drop age is discarded as the queue is drained rather
    /// than sent, so a device that was offline for a month does not flood the
    /// server with a month of stale data on reconnect.
    func testAStaleRequestIsDroppedAsTheQueueDrainsRatherThanSent() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance { $0.requestDropAgeHours = 1 }

        let store = core(of: countly).requestQueueStore
        let ancient = Int64((Date().timeIntervalSince1970 - 7200) * 1000)
        store.enqueue("app_key=\(Self.appKey)&timestamp=\(ancient)&stale=1",
                      appVersion: "1.0", trackingEnabled: true)
        core(of: countly).network.proceedOnQueue()

        TestUtils.waitUntil("the stale request leaves the queue") {
            self.requestQueue(of: countly).allSatisfy { !$0.contains("stale=1") }
        }
        XCTAssertTrue(MockURLProtocol.requests.allSatisfy { !$0.query.contains("stale=1") },
                      "a stale request is dropped, not sent")
    }

    // MARK: - Holding everything back

    /// In temporary mode the queue is not drained at all: every request in it is
    /// waiting to be rewritten to a real device ID first.
    func testTheQueueIsNotDrainedInTemporaryDeviceIDMode() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance {
            $0.temporaryDeviceIDMode = true
            $0.eventSendThreshold = 1
        }

        countly.events.recordEvent("held")
        TestUtils.pump(0.3)

        XCTAssertFalse(requestQueue(of: countly).isEmpty)
        XCTAssertTrue(MockURLProtocol.requests.filter { $0.query.contains("events=") }.isEmpty)
    }

    /// The server's networking switch stops the drain outright, which is the kill
    /// switch support reaches for when a build is misbehaving.
    func testTheQueueIsNotDrainedWhileTheServerHasNetworkingOff() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance {
            $0.eventSendThreshold = 1
            $0.sdkBehaviorSettings = ServerConfigBuilder().networking(false).json()
        }

        countly.events.recordEvent("blocked")
        TestUtils.pump(0.3)

        XCTAssertFalse(requestQueue(of: countly).isEmpty)
        XCTAssertTrue(MockURLProtocol.requests.filter { $0.query.contains("events=") }.isEmpty)
    }

    // MARK: - Sending stored requests on demand

    func testAttemptToSendStoredRequestsDrainsWhatIsWaiting() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("waiting")
        XCTAssertFalse(requestQueue(of: countly).isEmpty)

        MockURLProtocol.respondToEverything(json: Self.accepted)
        countly.requestQueue.attemptToSendStoredRequests()

        TestUtils.waitUntil("the queue drains") { self.requestQueue(of: countly).isEmpty }
    }

    // MARK: - Suspend and resume

    /// Suspending flushes everything to disk, because the process may not come
    /// back. Resuming picks the drain back up.
    func testSuspendingFlushesAndResumingCarriesOn() {
        let countly = startInstance { $0.eventSendThreshold = 100 }

        countly.events.recordEvent("recorded-before-suspend")
        countly.suspend()

        XCTAssertFalse(requestQueue(of: countly).isEmpty,
                       "the in-memory batch should have been pushed into the queue")

        MockURLProtocol.respondToEverything(json: Self.accepted)
        countly.resume()

        TestUtils.waitUntil("the queue drains after resuming") {
            self.requestQueue(of: countly).isEmpty
        }
    }
}
