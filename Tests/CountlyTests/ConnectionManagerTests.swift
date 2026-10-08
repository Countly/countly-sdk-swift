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
        // The queue empties inside the same response handling that starts the
        // pause, so waiting for the pause itself is what makes the next record
        // land during it rather than a moment before it.
        TestUtils.waitUntil("the backoff is in effect") {
            self.core(of: countly).network.isBackingOffForTesting
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

    /// A crash the SDK detected itself stops the queue for the rest of the dying
    /// process: its report, and anything recorded after it, wait on disk for the
    /// next launch instead of starting a send the process cannot finish.
    func testAnAutoDetectedCrashStopsTheQueueUntilTheNextLaunch() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance {
            $0.features = [.crashReporting]
            $0.eventSendThreshold = 1
        }
        TestUtils.waitUntil("the start-up queue drains") { self.requestQueue(of: countly).isEmpty }

        reportAutoDetectedCrash(on: countly)
        let sentBeforeTheCrash = MockURLProtocol.requests.count
        countly.events.recordEvent("after the crash")
        TestUtils.pump(0.5)

        XCTAssertEqual(MockURLProtocol.requests.count, sentBeforeTheCrash,
                       "no request may start once the crash is stored")
        let queued = requestQueue(of: countly)
        XCTAssertEqual(TestUtils.requests(queued, carrying: "crash").count, 1,
                       "the crash report should wait in the queue")
        let eventKeys = TestUtils.requests(queued, carrying: "events")
            .compactMap { $0["events"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { $0["key"] as? String }
        XCTAssertTrue(eventKeys.contains("after the crash"),
                      "an event recorded after the crash should wait in the queue too, found: [\(eventKeys)]")
    }

    /// An error the application reported itself is drained right away, however it
    /// is flagged: only a crash the SDK caught waits for the next launch.
    func testAManuallyRecordedErrorAlwaysGoesThroughTheQueue() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance()

        countly.crashes.recordError("handled", isFatal: false, stackTrace: [])
        countly.crashes.recordError("reported as fatal", isFatal: true, stackTrace: [])

        // Counted at the transport because a drained queue is empty.
        TestUtils.waitUntil("both reports drain") {
            MockURLProtocol.requests.filter { $0.query.contains("crash=") }.count == 2
        }
        XCTAssertTrue(MockURLProtocol.requests
            .filter { $0.query.contains("crash=") }
            .allSatisfy { $0.method == "GET" },
            "a queued report is an ordinary request")
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

    /// A long backlog of stale requests is dropped without a nested call per
    /// request. A device offline for days can hold a thousand of them, and the
    /// drain runs on threads with small stacks, a URL session's among them.
    func testABacklogOfStaleRequestsIsDroppedOnASmallStack() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance {
            $0.requestDropAgeHours = 1
            $0.storedRequestsLimit = 5000
        }

        let core = core(of: countly)
        TestUtils.waitUntil("the drain started by init is over") {
            !core.network.isProcessingQueueForTesting
        }

        let ancient = Int64((Date().timeIntervalSince1970 - 7200) * 1000)
        for index in 0..<2000 {
            core.requestQueueStore.appendVerbatim("app_key=\(Self.appKey)&timestamp=\(ancient)&stale=\(index)")
        }

        let drained = expectation(description: "the drain returns")
        let thread = Thread {
            core.network.proceedOnQueue()
            drained.fulfill()
        }
        thread.stackSize = 256 * 1024
        thread.start()
        wait(for: [drained], timeout: 30)

        XCTAssertTrue(requestQueue(of: countly).allSatisfy { !$0.contains("stale=") },
                      "every stale request is dropped")
    }

    // MARK: - Holding everything back

    /// In temporary mode the queue is not drained at all: every request in it is
    /// waiting to be rewritten to a real device ID first.
    func testTheQueueIsNotDrainedInTemporaryDeviceIDMode() {
        MockURLProtocol.respondToEverything(json: Self.accepted)
        let countly = startInstance {
            $0.temporaryDeviceIDMode = true
            $0.deviceID = nil
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

    /// Recording already fires a send, which the mock refuses because nothing
    /// answers yet. A drain asked for while that send is in flight is refused, so
    /// it has to settle before the answer is installed, or the test only passes
    /// when the main thread beats the mock's loading thread.
    func testAttemptToSendStoredRequestsDrainsWhatIsWaiting() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        countly.events.recordEvent("waiting")
        XCTAssertFalse(requestQueue(of: countly).isEmpty)
        TestUtils.waitUntil("the unanswered send settles") {
            !self.core(of: countly).network.isProcessingQueueForTesting
        }

        MockURLProtocol.respondToEverything(json: Self.accepted)
        countly.requestQueue.attemptToSendStoredRequests()

        TestUtils.waitUntil("the queue drains") { self.requestQueue(of: countly).isEmpty }
    }

    // MARK: - Suspend and resume

    /// Suspending flushes everything to disk, because the process may not come
    /// back. Resuming starts no drain of its own: under manual sessions nothing is
    /// begun, and an automatic session is refused while `AppState` reads
    /// background, which an earlier suite can leave behind. The next trigger is
    /// what sends the batch suspend queued, so that is what is asked for.
    func testSuspendingFlushesAndResumingCarriesOn() {
        let countly = startInstance { $0.eventSendThreshold = 100 }

        countly.events.recordEvent("recorded-before-suspend")
        countly.suspend()

        XCTAssertTrue(requestQueue(of: countly).contains { $0.contains("recorded-before-suspend") },
                      "the in-memory batch should have been pushed into the queue")
        TestUtils.waitUntil("the unanswered send settles") {
            !self.core(of: countly).network.isProcessingQueueForTesting
        }

        MockURLProtocol.respondToEverything(json: Self.accepted)
        countly.resume()
        countly.requestQueue.attemptToSendStoredRequests()

        TestUtils.waitUntil("the queue drains after resuming") {
            self.requestQueue(of: countly).isEmpty
        }
    }

    // MARK: - After halt

    /// A send that lands after `halt()`, which a connection test battery or a
    /// backoff countdown finishing on a background queue can do, is refused. It
    /// used to reach a session `halt()` had invalidated, and `URLSession` answers
    /// that with an exception that takes the host application down.
    func testNothingIsSentAfterHalt() {
        let countly = startInstance { $0.eventSendThreshold = 1 }
        let core = core(of: countly)
        countly.events.recordEvent("left-behind")
        TestUtils.waitUntil("the unanswered send settles") { !core.network.isProcessingQueueForTesting }
        XCTAssertFalse(core.requestQueueStore.snapshot.isEmpty)
        // Startup traffic is asynchronous too; a task resumed before the halt may land after it.
        TestUtils.waitUntil("the behavior settings fetch goes out") {
            MockURLProtocol.requests.contains { $0.query.contains("method=sc") }
        }
        TestUtils.pump(0.3)
        let sentBeforeHalt = MockURLProtocol.requests.map(\.url.absoluteString)

        countly.halt()
        MockURLProtocol.respondToEverything(json: Self.accepted)

        core.network.proceedOnQueue()
        let probe = URLRequest(url: URL(string: "\(Self.host)/o/sdk?method=sc")!)
        XCTAssertNil(core.network.instantTask(with: probe) { _, _, _ in XCTFail("a halted instance completed a request") })
        TestUtils.pump(0.3)

        let sentAfterHalt = MockURLProtocol.requests.map(\.url.absoluteString)
        XCTAssertEqual(sentAfterHalt.count, sentBeforeHalt.count,
                       "a halted instance sent: \(Array(sentAfterHalt.dropFirst(sentBeforeHalt.count)))")
        XCTAssertFalse(core.network.isProcessingQueueForTesting, "the refused drain must release the queue")
        XCTAssertFalse(core.requestQueueStore.snapshot.isEmpty, "the queue is kept for the next start")
    }
}
