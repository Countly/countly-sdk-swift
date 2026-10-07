//
//  LogGatheringTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Per user SDK log gathering: the tri-state the SDK starts in, the speculative
/// buffer that makes the init lines available, adoption and discard, directive
/// sanitising, the two buffer ceilings, and the shape of the uploaded batch.
///
/// The state machine is exercised on a gatherer of its own with a fake transport,
/// so the assertions are about the lines a test injected and nothing else. The
/// wiring into the SDK, from the live `sc` response down to the request queue, is
/// exercised on real instances.
final class LogGatheringTests: CountlyBaseTestCase {

    // Mirrored on purpose: a test that read them from the implementation would
    // pass even if a value changed to something wrong.
    private let allLevels = "ewidv"
    private let defaultBatchSize = 100
    private let minBatchSize = 10
    private let maxBufferedLines = 500
    private let maxMessageLength = 4096
    private let charCeiling = 128 * 1024

    private let harnessPrefix = "harness line"

    // MARK: - A gatherer of its own

    /// Stands in for the connection manager and records what was handed to it.
    private final class FakeTransport: LogGatheringTransport {
        private let lock = NSLock()
        private var _tracking = true
        private var _consent = true
        private var _granted = Set(ConsentFeature.allCases)
        private var _refuse = false
        private var _payloads: [String] = []
        private var _threads: [Thread] = []

        var isTrackingEnabled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _tracking }
            set { lock.lock(); _tracking = newValue; lock.unlock() }
        }

        var hasAnyConsent: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _consent }
            set { lock.lock(); _consent = newValue; lock.unlock() }
        }

        /// The features consented to. Setting it also settles `hasAnyConsent`, so
        /// a test states the consent state once.
        var granted: Set<ConsentFeature> {
            get { lock.lock(); defer { lock.unlock() }; return _granted }
            set {
                lock.lock()
                _granted = newValue
                _consent = !newValue.isEmpty
                lock.unlock()
            }
        }

        func hasConsent(for feature: ConsentFeature) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return _granted.contains(feature)
        }

        /// When set, the queue refuses every batch, as it does when tracking flips
        /// off between the check and the send.
        var refuses: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _refuse }
            set { lock.lock(); _refuse = newValue; lock.unlock() }
        }

        var payloads: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _payloads
        }

        var deliveryThreads: [Thread] {
            lock.lock()
            defer { lock.unlock() }
            return _threads
        }

        var batches: [[String: Any]] {
            payloads.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }

        func sendSdkLogs(_ payload: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if _refuse { return false }
            _payloads.append(payload)
            _threads.append(Thread.current)
            return true
        }
    }

    /// A gatherer past init, wired to `transport`, with no logger of its own so
    /// only the lines a test injects are ever held.
    private func makeGatherer(_ transport: FakeTransport = FakeTransport(), initFinished: Bool = true) -> LogGatherer {
        let gatherer = LogGatherer(logger: nil)
        gatherer.transport = transport
        if initFinished { gatherer.sdkInitFinished() }
        return gatherer
    }

    private func directive(id: String, levels: String? = "ewidv", batchSize: Int? = 100) -> LogGatheringDirective {
        var raw: [String: Any] = ["e": true, "i": id]
        if let levels { raw["l"] = levels }
        if let batchSize { raw["b"] = batchSize }
        return LogGatheringDirective.parse(raw, logger: nil)
    }

    private func capture(_ gatherer: LogGatherer,
                         _ count: Int,
                         level: CountlyLogLevel = .debug,
                         message: String? = nil,
                         scope: LogGatheringScope = .sdk) {
        for index in 0..<count {
            gatherer.capture("\(message ?? harnessPrefix) \(index)", level: level, scope: scope, headerLength: 0)
        }
    }

    private func messages(_ gatherer: LogGatherer) -> [String] {
        gatherer.heldLines.map(\.message)
    }

    private func lines(in batch: [String: Any]) -> [[String: Any]] {
        (batch["l"] as? [[String: Any]]) ?? []
    }

    // MARK: - The state the SDK starts in

    func testStartsUndecidedAndCapturesEveryLevelSpeculatively() {
        let gatherer = makeGatherer()
        XCTAssertEqual(gatherer.currentState, .undecided, "the SDK has to gather before a directive exists, or init logs are unreachable")

        for level in [CountlyLogLevel.error, .warning, .info, .debug, .verbose] {
            capture(gatherer, 1, level: level)
        }

        // Which levels the operator wants arrives with the directive, so nothing
        // can be filtered yet.
        XCTAssertEqual(gatherer.heldLineCount, 5)
        XCTAssertEqual(gatherer.heldLines.map(\.level), ["e", "w", "i", "d", "v"])
        XCTAssertEqual(gatherer.pendingDroppedCount, 0)
    }

    func testALineCarriesAMillisecondTimestampAndASingleCharacterLevel() throws {
        let gatherer = makeGatherer()
        capture(gatherer, 1, level: .error)

        let line = try XCTUnwrap(gatherer.heldLines.first)
        XCTAssertEqual(line.level, "e")
        XCTAssertGreaterThan(line.timestamp, 1_600_000_000_000, "milliseconds since epoch, not seconds")
        XCTAssertEqual(line.message, "\(harnessPrefix) 0")
    }

    // MARK: - Adoption and discard

    func testAdoptionKeepsTheSpeculativeLinesFilteredToTheRequestedLevels() {
        let gatherer = makeGatherer()
        capture(gatherer, 2, level: .error)
        capture(gatherer, 3, level: .debug)
        capture(gatherer, 1, level: .verbose)

        gatherer.apply(directive(id: "gather_1", levels: "e"), source: "test")

        XCTAssertEqual(gatherer.currentState, .gathering)
        XCTAssertEqual(gatherer.currentDirective.gatherID, "gather_1")
        XCTAssertEqual(gatherer.heldLines.map(\.level), ["e", "e"], "the init lines are the reason speculative capture exists")
        XCTAssertEqual(gatherer.pendingDroppedCount, 0, "a level filter is not a buffer overflow")

        // From here on the filter applies at capture time.
        capture(gatherer, 1, level: .debug)
        capture(gatherer, 1, level: .error)
        XCTAssertEqual(gatherer.heldLineCount, 3)
    }

    func testAnOffDirectiveDropsEverythingHeldAndStopsCapturing() {
        let gatherer = makeGatherer()
        capture(gatherer, 7)

        gatherer.apply(.off, source: "test")

        XCTAssertEqual(gatherer.currentState, .off)
        XCTAssertEqual(gatherer.heldLineCount, 0)
        XCTAssertEqual(gatherer.pendingDroppedCount, 0, "lines nobody asked for are not a reportable loss")
        XCTAssertFalse(gatherer.isCapturing)

        capture(gatherer, 5)
        XCTAssertEqual(gatherer.heldLineCount, 0)
    }

    func testADifferentGatherIDDropsTheHeldLinesAndTheSameOneKeepsThem() {
        let gatherer = makeGatherer()
        gatherer.apply(directive(id: "gather_old"), source: "test")
        capture(gatherer, 4)

        gatherer.apply(directive(id: "gather_old"), source: "test")
        XCTAssertEqual(gatherer.heldLineCount, 4, "every config fetch repeats the directive, that must not lose lines")

        gatherer.apply(directive(id: "gather_new"), source: "test")
        XCTAssertEqual(gatherer.heldLineCount, 0, "the server rejects a batch attributed to a gather that ended")
        XCTAssertEqual(gatherer.currentDirective.gatherID, "gather_new")
        XCTAssertEqual(gatherer.pendingDroppedCount, 0)
    }

    func testAChangedLevelSetInsideTheSameGatherRefiltersWhatIsHeld() {
        let gatherer = makeGatherer()
        gatherer.apply(directive(id: "gather_1"), source: "test")
        capture(gatherer, 2, level: .error)
        capture(gatherer, 2, level: .debug)

        gatherer.apply(directive(id: "gather_1", levels: "d"), source: "test")

        XCTAssertEqual(gatherer.heldLines.map(\.level), ["d", "d"])
    }

    func testDecidingOffOnlyCountsWhileUndecided() {
        let gatherer = makeGatherer()
        capture(gatherer, 3)

        gatherer.decideOffIfUndecided("fetch failed")
        XCTAssertEqual(gatherer.currentState, .off, "nothing can adopt the lines this run, holding them is pointless")
        XCTAssertEqual(gatherer.heldLineCount, 0)

        gatherer.apply(directive(id: "gather_keep"), source: "test")
        capture(gatherer, 3)

        gatherer.decideOffIfUndecided("fetch failed")
        XCTAssertEqual(gatherer.currentState, .gathering, "a running gather survives a transient failure of the periodic refetch")
        XCTAssertEqual(gatherer.heldLineCount, 3)
    }

    func testHaltDiscardsTheGatherAndStopsCapturingAndDelivering() {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_1", levels: "e", batchSize: 20), source: "test")
        capture(gatherer, 3, level: .error)

        gatherer.halt()

        XCTAssertEqual(gatherer.currentState, .off)
        XCTAssertEqual(gatherer.heldLineCount, 0, "no tail upload on stop, the lines are discarded")
        XCTAssertEqual(gatherer.currentDirective, .off)
        capture(gatherer, 2)
        gatherer.flushNow()
        XCTAssertEqual(gatherer.heldLineCount, 0)
        XCTAssertTrue(transport.payloads.isEmpty)
    }

    // MARK: - Directive sanitising

    func testEnabledWithoutAGatherIDIsOff() {
        XCTAssertEqual(LogGatheringDirective.parse(["e": true], logger: nil), .off)
        XCTAssertEqual(LogGatheringDirective.parse(["e": true, "i": "  "], logger: nil), .off,
                       "a batch with no gather id can not be attributed and the server rejects it")
        XCTAssertEqual(LogGatheringDirective.parse(["e": true, "i": 42], logger: nil), .off)
    }

    func testAnythingThatIsNotAnEnabledDictionaryIsOff() {
        XCTAssertEqual(LogGatheringDirective.parse(nil, logger: nil), .off)
        XCTAssertEqual(LogGatheringDirective.parse("armed", logger: nil), .off)
        XCTAssertEqual(LogGatheringDirective.parse(["e": false, "i": "gather_1"], logger: nil), .off)
        XCTAssertEqual(LogGatheringDirective.parse(["i": "gather_1"], logger: nil), .off)
    }

    func testLevelsAreLowercasedDeduplicatedAndFilteredWithAFallbackToEveryLevel() {
        XCTAssertEqual(directive(id: "g", levels: "EeWwE").levels, "ew")
        XCTAssertEqual(directive(id: "g", levels: "e!w").levels, "ew")
        XCTAssertEqual(directive(id: "g", levels: "vdiwe").levels, "vdiwe", "a set, kept in the order sent")
        XCTAssertEqual(directive(id: "g", levels: "!!zz").levels, allLevels, "an armed gather that captures nothing looks like a broken feature")
        XCTAssertEqual(directive(id: "g", levels: nil).levels, allLevels)
        XCTAssertEqual(LogGatheringDirective.parse(["e": true, "i": "g", "l": 5], logger: nil).levels, allLevels)
    }

    func testTheBatchSizeIsClampedIntoRange() {
        XCTAssertEqual(directive(id: "g", batchSize: 1).batchSize, minBatchSize, "a batch of one would upload a request per log line")
        XCTAssertEqual(directive(id: "g", batchSize: 100_000).batchSize, maxBufferedLines, "a batch bigger than the buffer would never fill")
        XCTAssertEqual(directive(id: "g", batchSize: 0).batchSize, minBatchSize)
        XCTAssertEqual(directive(id: "g", batchSize: 250).batchSize, 250)
        XCTAssertEqual(directive(id: "g", batchSize: nil).batchSize, defaultBatchSize)
        XCTAssertEqual(LogGatheringDirective.parse(["e": true, "i": "g", "b": "many"], logger: nil).batchSize, defaultBatchSize)
        XCTAssertEqual(LogGatheringDirective.parse(["e": true, "i": "g", "b": true], logger: nil).batchSize, defaultBatchSize)
    }

    // MARK: - The buffer ceilings

    func testTheLineCeilingDropsTheOldestLinesAndCountsThem() {
        let gatherer = makeGatherer()
        capture(gatherer, maxBufferedLines + 25)

        XCTAssertEqual(gatherer.heldLineCount, maxBufferedLines)
        XCTAssertEqual(gatherer.pendingDroppedCount, 25, "the loss is reported as 'd' instead of disappearing silently")
        XCTAssertEqual(messages(gatherer).first, "\(harnessPrefix) 25")
        XCTAssertEqual(messages(gatherer).last, "\(harnessPrefix) \(maxBufferedLines + 24)")
    }

    func testTheCharacterCeilingDropsTheOldestLines() {
        let gatherer = makeGatherer()
        // Short of the message cap, so the counter suffix survives.
        let long = String(repeating: "c", count: maxMessageLength - 100)
        capture(gatherer, 40, message: long)

        // 40 x 4000 is past 128 KB, so the oldest went and were counted.
        XCTAssertLessThanOrEqual(gatherer.heldLineCount, 32)
        XCTAssertGreaterThanOrEqual(gatherer.pendingDroppedCount, 8)
        XCTAssertLessThanOrEqual(messages(gatherer).reduce(0) { $0 + $1.utf16.count }, charCeiling)
        XCTAssertEqual(messages(gatherer).last, "\(long) 39")
    }

    func testALongMessageIsCutNotDropped() throws {
        let gatherer = makeGatherer()
        gatherer.capture("xxx" + String(repeating: "x", count: maxMessageLength + 500), level: .debug, scope: .sdk, headerLength: 0)

        let stored = try XCTUnwrap(gatherer.heldLines.first?.message)
        XCTAssertEqual(stored.utf16.count, maxMessageLength)
        XCTAssertTrue(stored.hasPrefix("xxx"))
    }

    func testTheCutNeverSplitsASurrogatePair() throws {
        let gatherer = makeGatherer()
        // One code unit short of the limit, then an emoji that needs two.
        gatherer.capture(String(repeating: "a", count: maxMessageLength - 1) + "😀", level: .debug, scope: .sdk, headerLength: 0)

        let stored = try XCTUnwrap(gatherer.heldLines.first?.message)
        XCTAssertLessThanOrEqual(stored.utf16.count, maxMessageLength)
        XCTAssertNotNil(stored.data(using: .utf8), "a lone surrogate can not be encoded and would poison the whole batch")
        XCTAssertNotNil(CountlyJSON.string(from: ["m": stored], logger: nil))
    }

    // MARK: - Self capture

    func testALineQuotingAnUploadedBatchIsNeverGathered() {
        let gatherer = makeGatherer()
        gatherer.apply(directive(id: "gather_marker"), source: "test")

        gatherer.capture("request started &sdk_logs={\"i\":\"x\"}", level: .debug, scope: .sdk, headerLength: 0)
        gatherer.capture("plain line", level: .debug, scope: .sdk, headerLength: 0)

        XCTAssertEqual(messages(gatherer), ["plain line"])
    }

    func testLinesLoggedByTheTransportThreadAreNotGathered() {
        let gatherer = makeGatherer()
        gatherer.apply(directive(id: "gather_thread"), source: "test")

        gatherer.markingTransportWork(true) {
            capture(gatherer, 3)
            XCTAssertTrue(gatherer.isTransportWork)
            // An ordinary request sent from the delivery loop is not transport
            // work, its lines are wanted; the outer mark comes back afterwards.
            gatherer.markingTransportWork(false) {
                XCTAssertFalse(gatherer.isTransportWork)
                capture(gatherer, 1, message: "ordinary request line")
            }
            XCTAssertTrue(gatherer.isTransportWork)
            capture(gatherer, 3)
        }
        XCTAssertFalse(gatherer.isTransportWork)
        capture(gatherer, 2)

        XCTAssertEqual(gatherer.heldLineCount, 3, "the request path logs the batch it sends, gathering that would re-upload it every tick")
        XCTAssertEqual(messages(gatherer).first, "ordinary request line 0")
    }

    func testTheTransportMarkIsPerGathererNotPerProcess() {
        let first = makeGatherer()
        let second = makeGatherer()
        second.apply(directive(id: "gather_other"), source: "test")

        first.markingTransportWork(true) {
            capture(second, 2)
        }

        XCTAssertEqual(second.heldLineCount, 2, "one instance's upload must not mute another instance's capture")
    }

    // MARK: - Delivery through the transport

    func testAFullBatchIsDeliveredOffTheCapturingThreadWithTheWireShape() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_upload", levels: "e", batchSize: minBatchSize), source: "test")

        capture(gatherer, minBatchSize, level: .error)

        TestUtils.waitUntil("the full batch is handed to the transport") { transport.payloads.count == 1 }
        XCTAssertEqual(gatherer.heldLineCount, 0)

        let batch = try XCTUnwrap(transport.batches.first)
        XCTAssertEqual(batch["i"] as? String, "gather_upload")
        XCTAssertEqual(TestUtils.int(batch["d"]), 0)
        let lines = lines(in: batch)
        XCTAssertEqual(lines.count, minBatchSize)
        XCTAssertEqual(lines.map { $0["m"] as? String }, (0..<minBatchSize).map { "\(harnessPrefix) \($0)" }, "oldest first")
        XCTAssertTrue(lines.allSatisfy { ($0["l"] as? String) == "e" })
        XCTAssertTrue(lines.allSatisfy { TestUtils.int64($0["t"]) ?? 0 > 1_600_000_000_000 })
        XCTAssertNotEqual(transport.deliveryThreads.first, Thread.current, "the capturing thread may be inside a store write")
    }

    func testAPartialBatchWaitsForAFlush() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_partial", batchSize: minBatchSize), source: "test")
        capture(gatherer, minBatchSize - 1)

        TestUtils.pump(0.3)
        XCTAssertTrue(transport.payloads.isEmpty, "only full batches go out on their own")

        gatherer.flushNow()

        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(lines(in: try XCTUnwrap(transport.batches.first)).count, minBatchSize - 1, "a flush takes the partial batch that is there")
        XCTAssertEqual(gatherer.heldLineCount, 0)
    }

    func testAFlushDoesNothingWhileUndecidedOrOff() {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        capture(gatherer, defaultBatchSize * 2)

        gatherer.flushNow()
        gatherer.scheduleFlush()
        TestUtils.pump(0.2)
        XCTAssertTrue(transport.payloads.isEmpty, "there is nothing to attribute a batch to yet")
        XCTAssertEqual(gatherer.heldLineCount, defaultBatchSize * 2, "and the lines stay held")

        gatherer.apply(.off, source: "test")
        gatherer.flushNow()
        XCTAssertTrue(transport.payloads.isEmpty)
    }

    func testNothingIsDeliveredBeforeInitFinishesAndTheTailGoesOutWhenItDoes() {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport, initFinished: false)
        gatherer.apply(directive(id: "gather_init", batchSize: minBatchSize), source: "test")
        capture(gatherer, minBatchSize + 3)

        gatherer.flushNow()
        TestUtils.pump(0.2)
        XCTAssertTrue(transport.payloads.isEmpty, "the request queue is not usable before init finishes")
        XCTAssertEqual(gatherer.heldLineCount, minBatchSize + 3)

        gatherer.sdkInitFinished()

        TestUtils.waitUntil("the init tail is uploaded") { transport.payloads.count == 2 }
        XCTAssertEqual(transport.batches.map { lines(in: $0).count }, [minBatchSize, 3], "the full batch first, then the partial tail init finishing includes")
    }

    func testAdoptionDrainsOnlyFullBatchesAndReportsTheDropCountOnce() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        // While gathering every full batch drains, so the buffer only ever
        // overflows before a directive arrives.
        capture(gatherer, maxBufferedLines + 12, level: .error)
        XCTAssertEqual(gatherer.pendingDroppedCount, 12)

        gatherer.apply(directive(id: "gather_dropped", levels: "e", batchSize: 200), source: "test")

        TestUtils.waitUntil("the two full batches drain on adoption") { transport.payloads.count == 2 }
        TestUtils.pump(0.2)
        XCTAssertEqual(transport.payloads.count, 2, "the remaining 100 lines wait for a flush")
        XCTAssertEqual(gatherer.heldLineCount, 100)

        let dropCounts = transport.batches.map { TestUtils.int($0["d"]) ?? -1 }
        XCTAssertEqual(dropCounts, [12, 0], "the gap reaches the operator once, with the batch that follows it")
        XCTAssertEqual(gatherer.pendingDroppedCount, 0)

        gatherer.flushNow()
        XCTAssertEqual(transport.batches.reduce(0) { $0 + lines(in: $1).count }, maxBufferedLines, "every held line went out, none twice")
    }

    func testABatchTheQueueRefusesGoesBackToTheFrontWithItsDropCount() {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        capture(gatherer, maxBufferedLines + 5, level: .error)
        gatherer.apply(directive(id: "gather_refused", levels: "e", batchSize: maxBufferedLines), source: "test")
        TestUtils.waitUntil("adoption drains the full batch") { transport.payloads.count == 1 }
        XCTAssertEqual(gatherer.heldLineCount, 0)

        transport.refuses = true
        capture(gatherer, 3, level: .error, message: "late line")
        gatherer.flushNow()

        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(messages(gatherer), ["late line 0", "late line 1", "late line 2"], "oldest first, nothing lost")

        transport.refuses = false
        gatherer.flushNow()
        XCTAssertEqual(transport.payloads.count, 2)
        XCTAssertEqual(TestUtils.int(transport.batches[0]["d"]), 5)
        XCTAssertEqual(TestUtils.int(transport.batches[1]["d"]), 0)
    }

    func testLinesAreHeldWhileTrackingIsOffOrNoConsentIsGiven() {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_gated", batchSize: minBatchSize), source: "test")

        transport.isTrackingEnabled = false
        capture(gatherer, minBatchSize)
        gatherer.flushNow()
        TestUtils.pump(0.2)
        XCTAssertTrue(transport.payloads.isEmpty, "the queue drops everything while tracking is off, the lines would be lost")
        XCTAssertEqual(gatherer.heldLineCount, minBatchSize)

        transport.isTrackingEnabled = true
        transport.hasAnyConsent = false
        gatherer.flushNow()
        XCTAssertTrue(transport.payloads.isEmpty, "gathered lines quote event keys and whole requests, they are user data")
        XCTAssertEqual(gatherer.heldLineCount, minBatchSize)

        transport.hasAnyConsent = true
        gatherer.flushNow()
        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(gatherer.heldLineCount, 0)
    }

    // MARK: - Consent, per line

    /// Collects what the developer facing sink was handed, so a test can compare
    /// it against what the same call uploaded.
    private final class LogSink: CountlyLoggerDelegate {
        private let lock = NSLock()
        private var _lines: [String] = []

        var lines: [String] {
            lock.lock()
            defer { lock.unlock() }
            return _lines
        }

        func internalLog(_ log: String, level: CountlyLogLevel) {
            lock.lock()
            _lines.append(log)
            lock.unlock()
        }
    }

    /// The messages of the lines of the first uploaded batch, in order.
    private func uploadedMessages(_ transport: FakeTransport) -> [String] {
        guard let batch = transport.batches.first else { return [] }
        return lines(in: batch).compactMap { $0["m"] as? String }
    }

    /// Mirrored on purpose, as the numbers above are: the wording is what an
    /// operator reads in the dashboard when a feature was not consented to.
    private func redactionNotice(_ wireName: String) -> String {
        "no consent for [\(wireName)], the rest of this line is redacted"
    }

    /// The scope table is the whole of the per feature rule, so a module that
    /// writes user data and is missing from it is the bug this guards against. A
    /// name nobody has classified is cross cutting, never the SDK's own working.
    func testEveryLogModuleIsClassified() {
        let byFeature: [String: ConsentFeature] = [
            "Events": .events, "Views": .viewTracking, "UserProfile": .userDetails,
            "Sessions": .sessions, "Location": .location, "Crash": .crashReporting,
            "CrashLogStore": .crashReporting, "Push": .pushNotifications,
            "PushRuntime": .pushNotifications, "Attribution": .attribution,
            "APM": .performanceMonitoring, "Feedback": .feedback,
            "RemoteConfig": .remoteConfig, "Content": .content, "DeviceMetrics": .metrics,
        ]
        for (module, feature) in byFeature {
            XCTAssertEqual(LogGatheringScope.ofModule(module), .feature(feature), "module \(module)")
        }

        let ownWorking = ["Countly", "Consent", "DeviceID", "ConnectionTest", "ConnectionManager",
                          "RequestBuilder", "RequestQueue", "KeyValueStore", "Storage", "ServerConfig",
                          "HealthTracker", "Lifecycle", "WebView", "LogGathering", "Utils"]
        for module in ownWorking {
            XCTAssertEqual(LogGatheringScope.ofModule(module), .sdk, "module \(module)")
        }

        XCTAssertEqual(LogGatheringScope.ofModule("Limits"), .anyFeature, "the limit checks quote whatever they truncated")
        XCTAssertEqual(LogGatheringScope.ofModule("Module"), .anyFeature, "the unoverridden module name is not a licence to upload")
        XCTAssertEqual(LogGatheringScope.ofModule("SomethingAddedLater"), .anyFeature)
    }

    func testALineGoesOutWholeOnlyWithTheConsentOfTheFeatureItCarries() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        transport.granted = [.sessions]
        gatherer.apply(directive(id: "gather_feature"), source: "test")

        let eventHeader = "[Events] recordEvent, "
        let viewHeader = "[Views] startView, "
        let sessionHeader = "[Sessions] beginSession, "
        let queueHeader = "[RequestQueue] enqueue, "

        gatherer.capture(eventHeader + "recording an event, key: [cart_opened], segmentationKeys: [price]",
                         level: .debug, scope: .feature(.events), headerLength: eventHeader.count)
        gatherer.capture(viewHeader + "starting a view, name: [Checkout]",
                         level: .debug, scope: .feature(.viewTracking), headerLength: viewHeader.count)
        gatherer.capture(sessionHeader + "a session is begun, durationSeconds: [0]",
                         level: .debug, scope: .feature(.sessions), headerLength: sessionHeader.count)
        gatherer.capture(queueHeader + "request is stored in the queue, queryStringLength: [410]",
                         level: .debug, scope: .sdk, headerLength: queueHeader.count)

        gatherer.flushNow()

        let uploaded = uploadedMessages(transport)
        XCTAssertEqual(uploaded, [
            eventHeader + redactionNotice("events"),
            viewHeader + redactionNotice("views"),
            sessionHeader + "a session is begun, durationSeconds: [0]",
            queueHeader + "request is stored in the queue, queryStringLength: [410]",
        ])

        let whole = uploaded.joined()
        XCTAssertFalse(whole.contains("cart_opened"), "an event key reached the server without events consent")
        XCTAssertFalse(whole.contains("Checkout"), "a view name reached the server without views consent")
        XCTAssertFalse(whole.contains("price"), "segmentation reached the server without events consent")
    }

    func testACrossCuttingLineNeedsEveryConsent() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        transport.granted = Set(ConsentFeature.allCases).subtracting([.metrics])
        gatherer.apply(directive(id: "gather_cross"), source: "test")

        let header = "[Limits] truncatedValue, "
        let message = header + "truncated value detail, target: [Event segmentation], fullValue: [steve@example.com]"
        gatherer.capture(message, level: .verbose, scope: .anyFeature, headerLength: header.count)
        gatherer.flushNow()

        // The helper cannot say whose value it truncated, so one missing consent
        // is enough to redact it, and the notice names the one that is missing.
        XCTAssertEqual(uploadedMessages(transport), [header + redactionNotice("metrics")])

        transport.granted = Set(ConsentFeature.allCases)
        gatherer.capture(message, level: .verbose, scope: .anyFeature, headerLength: header.count)
        gatherer.flushNow()
        XCTAssertEqual(uploadedMessages(transport).count, 1)
        XCTAssertEqual(transport.batches.count, 2)
        XCTAssertEqual(lines(in: transport.batches[1]).compactMap { $0["m"] as? String }, [message],
                       "with every consent given the line goes out as it was logged")
    }

    func testARedactedLineIsRedactedOnTheWireOnlyAndCanStillGoOutWholeLater() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        transport.granted = [.sessions]
        transport.refuses = true
        gatherer.apply(directive(id: "gather_restore"), source: "test")

        let header = "[Events] recordEvent, "
        let message = header + "recording an event, key: [cart_opened]"
        gatherer.capture(message, level: .debug, scope: .feature(.events), headerLength: header.count)
        gatherer.flushNow()

        XCTAssertTrue(transport.payloads.isEmpty)
        XCTAssertEqual(messages(gatherer), [message], "the buffer holds what was logged, redaction happens on the way out")

        transport.refuses = false
        transport.granted = [.sessions, .events]
        gatherer.flushNow()
        XCTAssertEqual(uploadedMessages(transport), [message])
    }

    func testTheLocalLogKeepsWhatTheUploadedCopyLoses() throws {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        transport.granted = [.sessions]
        gatherer.apply(directive(id: "gather_local"), source: "test")

        let sink = LogSink()
        let logger = Logger(instanceName: nil)
        logger.delegate = sink
        logger.level = .verbose
        logger.gatherer = gatherer

        logger.d("Events", "recordEvent", "recording an event, key: [cart_opened], segmentationKeys: [price]")
        gatherer.flushNow()

        let local = try XCTUnwrap(sink.lines.first)
        XCTAssertTrue(local.contains("key: [cart_opened]"), "the developer log has to keep showing what the method was called with")
        XCTAssertTrue(local.contains("segmentationKeys: [price]"))

        let uploaded = try XCTUnwrap(uploadedMessages(transport).first)
        XCTAssertEqual(uploaded, "[Events] recordEvent, " + redactionNotice("events"))
    }

    // MARK: - Wired into the SDK

    private func gatherer(of instance: CountlyInstance) -> LogGatherer {
        core(of: instance).logGatherer
    }

    /// Every queued request carrying an `sdk_logs` batch, decoded, oldest first.
    private func uploadedBatches(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance).map(TestUtils.parseQuery).compactMap { $0["sdk_logs"] as? [String: Any] }
    }

    private func respondToBehaviorSettings(with json: String) {
        MockURLProtocol.respond { captured in
            guard captured.path.contains("/o/sdk"), captured.query.contains("method=sc") else { return nil }
            return (200, Data(json.utf8))
        }
    }

    /// Starts an instance whose behavior settings fetch arms gathering, and waits
    /// until the directive landed.
    private func startArmed(id: String = "gather_live",
                            levels: String = "ewidv",
                            batchSize: Int = 100,
                            settings: ServerConfigBuilder = ServerConfigBuilder(),
                            adjust: (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        respondToBehaviorSettings(with: settings.armLogGathering(id: id, levels: levels, batchSize: batchSize).json())
        let countly = startInstance(adjust)
        TestUtils.waitUntil("the live directive arms gathering") { gatherer(of: countly).currentState == .gathering }
        return countly
    }

    func testAnArmedLiveResponseAdoptsTheInitLinesAndUploadsThemWithTheBaseParameters() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed()
        XCTAssertEqual(gatherer(of: countly).currentDirective.gatherID, "gather_live")

        gatherer(of: countly).flushNow()

        let batches = uploadedBatches(of: countly)
        XCTAssertFalse(batches.isEmpty, "the batch never reached the request queue")
        XCTAssertTrue(batches.allSatisfy { ($0["i"] as? String) == "gather_live" })

        let messages = batches.flatMap { lines(in: $0) }.compactMap { $0["m"] as? String }
        XCTAssertTrue(messages.contains { $0.contains("initializing, appKey") }, "the init lines are the reason speculative capture exists")
        XCTAssertTrue(batches.flatMap { lines(in: $0) }.allSatisfy { allLevels.contains(($0["l"] as? String) ?? "?") })

        // The level travels in the line's own field, so the message carries no prefix.
        let prefixes = ["[Error]", "[Warning]", "[Info]", "[Debug]", "[Verbose]"]
        XCTAssertTrue(messages.allSatisfy { message in !prefixes.contains { message.hasPrefix($0) } })

        // Its own request, with the usual identity so the dashboard can group per SDK.
        let requests = TestUtils.requests(requestQueue(of: countly), carrying: "sdk_logs")
        XCTAssertEqual(requests.count, batches.count)
        for request in requests {
            TestUtils.assertBaseParameters(request)
            XCTAssertNil(request["events"], "a batch never piggybacks on another request")
        }
    }

    func testCaptureWorksWhileConsoleLoggingIsOff() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed { $0.enableDebug = false }

        XCTAssertFalse(core(of: countly).logger.isEnabled(.debug), "nothing reaches the console")
        XCTAssertTrue(core(of: countly).logger.isWanted(.debug), "but the capture still wants the line")

        let before = gatherer(of: countly).heldLineCount
        countly.events.recordEvent("probe")
        XCTAssertGreaterThan(gatherer(of: countly).heldLineCount, before)
    }

    func testTheUploadDoesNotGatherItsOwnTransportLines() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(batchSize: 10)

        gatherer(of: countly).flushNow()
        TestUtils.waitUntil("an upload landed in the queue") { !uploadedBatches(of: countly).isEmpty }
        // Let the request path finish reporting the failed send of that batch.
        TestUtils.pump(0.5)

        let held = messages(gatherer(of: countly))
        XCTAssertTrue(held.allSatisfy { !$0.contains("sdk_logs") }, "held a line describing the upload: \(held.filter { $0.contains("sdk_logs") })")
        XCTAssertTrue(held.allSatisfy { !$0.contains("sendSdkLogs") }, "held the request path's own commentary: \(held.filter { $0.contains("sendSdkLogs") })")
        let uploaded = uploadedBatches(of: countly).flatMap { lines(in: $0) }.compactMap { $0["m"] as? String }
        XCTAssertTrue(uploaded.allSatisfy { !$0.contains("sdk_logs") }, "a batch nested the previous one")
    }

    func testLinesAreHeldUntilAnyConsentIsGiven() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_consent") { $0.requiresConsent = true }

        gatherer(of: countly).flushNow()
        XCTAssertTrue(uploadedBatches(of: countly).isEmpty, "gathered lines quote event keys and whole requests, they are user data")
        XCTAssertGreaterThan(gatherer(of: countly).heldLineCount, 0)

        countly.consent.giveConsent(for: [.events])
        gatherer(of: countly).flushNow()

        let batches = uploadedBatches(of: countly)
        XCTAssertFalse(batches.isEmpty, "any consent at all releases them")
        XCTAssertEqual(batches.first?["i"] as? String, "gather_consent")
    }

    func testLinesAreHeldWhileTrackingIsOff() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_tracking", settings: ServerConfigBuilder().tracking(false))
        XCTAssertFalse(core(of: countly).serverConfig.trackingEnabled)

        gatherer(of: countly).flushNow()
        XCTAssertTrue(requestQueue(of: countly).isEmpty, "the queue drops everything while tracking is off")
        XCTAssertGreaterThan(gatherer(of: countly).heldLineCount, 0, "so the lines stay held")

        respondToBehaviorSettings(with: ServerConfigBuilder().tracking(true).armLogGathering(id: "gather_tracking").json())
        core(of: countly).serverConfig.fetch(config: core(of: countly).config)
        TestUtils.waitUntil("tracking is switched back on") { core(of: countly).serverConfig.trackingEnabled }
        gatherer(of: countly).flushNow()

        XCTAssertFalse(uploadedBatches(of: countly).isEmpty)
        XCTAssertEqual(uploadedBatches(of: countly).first?["i"] as? String, "gather_tracking")
    }

    // MARK: - Deciding

    func testALiveResponseWithoutADirectiveOrWithADisarmedOneDecidesOff() throws {
        try skipUnlessNetworkIsInterceptable()
        respondToBehaviorSettings(with: ServerConfigBuilder().json())
        let plain = startInstance()
        TestUtils.waitUntil("a response without lg decides off") { gatherer(of: plain).currentState == .off }
        XCTAssertEqual(gatherer(of: plain).heldLineCount, 0)

        respondToBehaviorSettings(with: ServerConfigBuilder().disarmLogGathering().json())
        let disarmed = startInstance()
        TestUtils.waitUntil("e:false decides off") { gatherer(of: disarmed).currentState == .off }

        respondToBehaviorSettings(with: ServerConfigBuilder().logGathering(["e": true]).json())
        let noID = startInstance()
        TestUtils.waitUntil("e:true without an id decides off") { gatherer(of: noID).currentState == .off }
    }

    func testAFailedFetchDecidesOffOnlyWhileUndecided() throws {
        try skipUnlessNetworkIsInterceptable()
        // The mock fails every request nobody answers.
        let failed = startInstance()
        TestUtils.waitUntil("a failed fetch decides off") { gatherer(of: failed).currentState == .off }

        let armed = startArmed(id: "gather_survives")
        MockURLProtocol.reset()
        let fetchesBefore = MockURLProtocol.requests.count
        core(of: armed).serverConfig.fetch(config: core(of: armed).config)
        TestUtils.waitUntil("the refetch went out and failed") { MockURLProtocol.requests.count > fetchesBefore }
        TestUtils.pump(0.3)

        XCTAssertEqual(gatherer(of: armed).currentState, .gathering, "a running gather survives a transient failure of the periodic refetch")
        XCTAssertEqual(gatherer(of: armed).currentDirective.gatherID, "gather_survives")
    }

    func testTemporaryDeviceIDModeAndDisabledUpdatesDecideOffAtOnce() {
        let temporary = startInstance { $0.temporaryDeviceIDMode = true; $0.deviceID = nil }
        XCTAssertEqual(gatherer(of: temporary).currentState, .off, "no behavior settings are fetched in temporary mode, so no directive can arrive")

        let disabled = startInstance { $0.disableSDKBehaviorSettingsUpdates = true }
        XCTAssertEqual(gatherer(of: disabled).currentState, .off)
    }

    func testAStoredOrDeveloperSuppliedDirectiveDecidesNothing() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond { captured in
            guard captured.path.contains("/o/sdk"), captured.query.contains("method=sc") else { return nil }
            // A slow answer, so the state before it lands can be observed.
            Thread.sleep(forTimeInterval: 0.8)
            return (200, Data(ServerConfigBuilder().json().utf8))
        }

        let countly = startInstance {
            $0.sdkBehaviorSettings = ServerConfigBuilder().armLogGathering(id: "gather_stored").json()
        }

        XCTAssertEqual(gatherer(of: countly).currentState, .undecided, "a run only ever uploads the lines it gathered itself")
        XCTAssertNil(core(of: countly).keyValueStore.serverConfig?["lg"], "the directive never reaches the cache")

        TestUtils.waitUntil("the live response without lg decides off") { gatherer(of: countly).currentState == .off }
    }

    func testExtraTopLevelKeysAndAnEmptyConfigSectionAreAccepted() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_extra", settings: ServerConfigBuilder().topLevel("a_key_from_the_future", 1))

        let stored = core(of: countly).keyValueStore.serverConfig
        XCTAssertEqual((stored?["c"] as? [String: Any])?.count, 0, "an empty c is a valid answer and is cached as such")
        XCTAssertNil(stored?["lg"])
        XCTAssertNil(stored?["a_key_from_the_future"])

        let withSettings = startArmed(id: "gather_inner", settings: ServerConfigBuilder().customEventTracking(false))
        XCTAssertFalse(core(of: withSettings).serverConfig.customEventTrackingEnabled, "the inner settings still apply beside the directive")
    }

    func testEachInstanceDecidesOnItsOwn() throws {
        try skipUnlessNetworkIsInterceptable()
        let armed = startArmed(id: "gather_a")

        respondToBehaviorSettings(with: ServerConfigBuilder().json())
        let plain = startInstance()
        TestUtils.waitUntil("the second instance decides off") { gatherer(of: plain).currentState == .off }

        XCTAssertEqual(gatherer(of: armed).currentState, .gathering)
        gatherer(of: armed).flushNow()
        gatherer(of: plain).flushNow()
        XCTAssertFalse(uploadedBatches(of: armed).isEmpty)
        XCTAssertTrue(uploadedBatches(of: plain).isEmpty)
    }

    func testHaltingTheInstanceDiscardsTheGatherWithoutATailUpload() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_halt")
        let gatherer = gatherer(of: countly)
        // Init finishing may have drained everything held so far; a few more lines
        // make sure there is a partial tail to discard.
        countly.events.recordEvent("before-halt")
        XCTAssertGreaterThan(gatherer.heldLineCount, 0)

        countly.halt()

        XCTAssertEqual(gatherer.currentState, .off)
        XCTAssertEqual(gatherer.heldLineCount, 0, "nothing from the gather survives, and halt's own lines are not held either")
    }
}
