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
/// sanitising, the two buffer ceilings, the consent each line waits for, and the
/// shape of the uploaded batch.
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
        private var _trackingReads = 0
        private var _granted = Set(ConsentFeature.allCases)
        private var _refuse = false
        private var _payloads: [String] = []
        private var _threads: [Thread] = []

        /// Every delivery run reads this exactly once, which is what
        /// `deliveryRunCount` counts.
        var isTrackingEnabled: Bool {
            get { lock.lock(); defer { lock.unlock() }; _trackingReads += 1; return _tracking }
            set { lock.lock(); _tracking = newValue; lock.unlock() }
        }

        /// How many delivery runs have started, whether or not they sent anything.
        var deliveryRunCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _trackingReads
        }

        /// The features consented to. Every feature by default, which is what the
        /// SDK reports while consent is not required.
        var granted: Set<ConsentFeature> {
            get { lock.lock(); defer { lock.unlock() }; return _granted }
            set { lock.lock(); _granted = newValue; lock.unlock() }
        }

        /// Whether `granted` holds the feature.
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

    /// Every fake handed to a gatherer, kept for the whole test: a gatherer holds
    /// its transport weakly, and asks it for consent on every line.
    private var transports: [FakeTransport] = []

    /// A gatherer past init, wired to `transport`, with no logger of its own so
    /// only the lines a test injects are ever held.
    private func makeGatherer(_ transport: FakeTransport = FakeTransport(), initFinished: Bool = true) -> LogGatherer {
        transports.append(transport)
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

    /// Captures `count` numbered lines of one level and scope.
    private func capture(_ gatherer: LogGatherer,
                         _ count: Int,
                         level: CountlyLogLevel = .debug,
                         message: String? = nil,
                         scope: LogGatheringScope = .unattributed) {
        for index in 0..<count {
            gatherer.capture("\(message ?? harnessPrefix) \(index)", level: level, scope: scope)
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
        gatherer.capture("xxx" + String(repeating: "x", count: maxMessageLength + 500), level: .debug, scope: .unattributed)

        let stored = try XCTUnwrap(gatherer.heldLines.first?.message)
        XCTAssertEqual(stored.utf16.count, maxMessageLength)
        XCTAssertTrue(stored.hasPrefix("xxx"))
    }

    func testTheCutNeverSplitsASurrogatePair() throws {
        let gatherer = makeGatherer()
        // One code unit short of the limit, then an emoji that needs two.
        gatherer.capture(String(repeating: "a", count: maxMessageLength - 1) + "😀", level: .debug, scope: .unattributed)

        let stored = try XCTUnwrap(gatherer.heldLines.first?.message)
        XCTAssertLessThanOrEqual(stored.utf16.count, maxMessageLength)
        XCTAssertNotNil(stored.data(using: .utf8), "a lone surrogate can not be encoded and would poison the whole batch")
        XCTAssertNotNil(CountlyJSON.string(from: ["m": stored], logger: nil))
    }

    // MARK: - Self capture

    func testALineQuotingAnUploadedBatchIsNeverGathered() {
        let gatherer = makeGatherer()
        gatherer.apply(directive(id: "gather_marker"), source: "test")

        gatherer.capture("request started &sdk_logs={\"i\":\"x\"}", level: .debug, scope: .unattributed)
        gatherer.capture("plain line", level: .debug, scope: .unattributed)

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

    /// The request queue drops everything while tracking is off, so the gathered
    /// lines stay buffered until it is back on.
    func testTheBufferIsHeldWhileTrackingIsOff() {
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
        gatherer.flushNow()
        XCTAssertEqual(transport.payloads.count, 1)
        XCTAssertEqual(gatherer.heldLineCount, 0)
    }

    /// A buffer held back while tracking is off keeps growing past the batch size,
    /// and each further line asking for a delivery would queue hundreds of no-ops.
    /// The refetch that turns tracking back on is what sends the held batches.
    func testOnlyTheLineThatCompletesABatchAsksForADeliveryAndARefetchSendsWhatIsHeld() {
        let transport = FakeTransport()
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_held", batchSize: minBatchSize), source: "test")
        TestUtils.waitUntil("adoption ran its delivery") { transport.deliveryRunCount == 1 }

        transport.isTrackingEnabled = false
        capture(gatherer, minBatchSize * 5)
        TestUtils.waitUntil("the line completing the first batch ran a delivery") { transport.deliveryRunCount == 2 }
        TestUtils.pump(0.3)
        XCTAssertEqual(transport.deliveryRunCount, 2, "a full buffer held back while tracking is off must not queue a delivery per line")
        XCTAssertEqual(gatherer.heldLineCount, minBatchSize * 5)

        transport.isTrackingEnabled = true
        gatherer.apply(directive(id: "gather_held", batchSize: minBatchSize), source: "test")
        TestUtils.waitUntil("the refetch drains the held full batches") { transport.payloads.count == 5 }
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

        /// Keeps every line the SDK hands to the developer facing sink.
        func internalLog(_ log: String, level: CountlyLogLevel) {
            lock.lock()
            _lines.append(log)
            lock.unlock()
        }
    }

    /// The messages of every uploaded batch, oldest first.
    private func uploadedMessages(_ transport: FakeTransport) -> [String] {
        transport.batches.flatMap { lines(in: $0) }.compactMap { $0["m"] as? String }
    }

    /// The messages of the lines waiting for their consent, oldest first.
    private func awaitingMessages(_ gatherer: LogGatherer) -> [String] {
        gatherer.linesAwaitingConsent.map(\.message)
    }

    /// The scope table is the whole of the per feature rule, so a module that
    /// writes user data and is missing from it is the bug this guards against. A
    /// module that owns no single feature needs the events and user details
    /// consent, and so does a name nobody has classified.
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

        let noSingleFeature = ["Countly", "Consent", "DeviceID", "ConnectionTest", "ConnectionManager",
                               "RequestBuilder", "RequestQueue", "KeyValueStore", "Storage", "ServerConfig",
                               "HealthTracker", "Lifecycle", "WebView", "LogGathering", "Utils", "Limits",
                               "Module", "SomethingAddedLater"]
        for module in noSingleFeature {
            XCTAssertEqual(LogGatheringScope.ofModule(module), .unattributed, "module \(module)")
        }

        // A module added to the registry and left out of the table would gather its feature's data as unattributed.
        let ownWorking = [ConsentModule.moduleName, DeviceIDModule.moduleName, ConnectionTestModule.moduleName]
        for module in core(of: startInstance()).modules.all.map({ type(of: $0).moduleName }) where !ownWorking.contains(module) {
            XCTAssertNotEqual(LogGatheringScope.ofModule(module), .unattributed, "module \(module) is missing from the scope table")
        }
    }

    /// The public event calls log the key and segmentation before a reserved
    /// event's own consent is checked, so an events line naming a reserved event
    /// answers to the feature that owns the event.
    func testAnEventsLineNamingAReservedEventNeedsTheConsentOfThatEventsFeature() {
        let owners: [String: ConsentFeature] = [
            "[CLY]_view": .viewTracking, "[CLY]_orientation": .userDetails,
            "[CLY]_star_rating": .feedback, "[CLY]_nps": .feedback, "[CLY]_survey": .feedback,
            "[CLY]_push_action": .pushNotifications,
        ]
        for (key, owner) in owners {
            let line = "[Events] recordEvent, event segmentation detail, key: [\(key)], segmentation: [[\"name\": \"Checkout\"]]"
            XCTAssertEqual(eventsScope(line), .feature(owner), "key \(key)")
        }

        XCTAssertEqual(eventsScope("[Events] recordEvent, recording an event, key: [purchase]"), .feature(.events))
        XCTAssertEqual(eventsScope("[Events] recordEvent, recording an event, key: [[CLY]_viewed_product]"), .feature(.events),
                       "a custom key that only starts like a reserved one is a custom event")
        XCTAssertEqual(eventsScope("[Events] recordEvent, event segmentation detail, key: [checkout], segmentation: [[\"from\": \"[CLY]_view\"]]"),
                       .feature(.events), "a segmentation value naming a reserved event does not make the event reserved")
        XCTAssertEqual(LogGatheringScope.of(module: "Limits", function: "truncatedKey", message: "[Limits] truncatedKey, key: [[CLY]_view]"),
                       .unattributed, "only an events line is attributed by the event it names")
    }

    /// The views module logs the orientation before it checks the user details
    /// consent that the orientation event answers to.
    func testTheOrientationLinesOfTheViewsModuleNeedTheUserDetailsConsent() {
        XCTAssertEqual(LogGatheringScope.of(module: "Views", function: "recordOrientation",
                                            message: "[Views] recordOrientation, interface orientation changed, mode: [landscape]"),
                       .feature(.userDetails))
        XCTAssertEqual(LogGatheringScope.of(module: "Views", function: "startView",
                                            message: "[Views] startView, start view requested, name: [Checkout]"),
                       .feature(.viewTracking), "every other views line stays with the views consent")
    }

    /// The scope of a line the events module wrote from `recordEvent`.
    private func eventsScope(_ message: String) -> LogGatheringScope {
        LogGatheringScope.of(module: "Events", function: "recordEvent", message: message)
    }

    /// A line without its consent is held whole rather than redacted, because it
    /// is the debugging value, and it is never part of a batch until released.
    func testALineWaitsApartForItsConsentAndJoinsTheBufferInLoggedOrderOnceItIsGiven() {
        let transport = FakeTransport()
        transport.granted = [.events]
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_feature"), source: "test")

        let firstProperty = "[UserProfile] setProperty, value: [first@example.com]"
        let event = "[Events] recordEvent, key: [purchase]"
        let secondProperty = "[UserProfile] setProperty, value: [second@example.com]"
        let laterEvent = "[Events] recordEvent, key: [refund]"

        gatherer.capture(firstProperty, level: .debug, scope: .feature(.userDetails))
        gatherer.capture(event, level: .debug, scope: .feature(.events))
        gatherer.capture(secondProperty, level: .debug, scope: .feature(.userDetails))
        gatherer.flushNow()

        XCTAssertEqual(uploadedMessages(transport), [event], "the events consent covers the events line and nothing else")
        XCTAssertEqual(awaitingMessages(gatherer), [firstProperty, secondProperty], "the others wait whole, neither dropped nor redacted")

        gatherer.capture(laterEvent, level: .debug, scope: .feature(.events))
        transport.granted = [.events, .userDetails]
        gatherer.consentDidChange()

        XCTAssertTrue(awaitingMessages(gatherer).isEmpty)
        XCTAssertEqual(messages(gatherer), [firstProperty, secondProperty, laterEvent],
                       "a released line takes its place by when it was logged, within one millisecond too")
    }

    /// A line no single feature owns can quote an event or a user property, so it
    /// needs both consents, and only those two.
    func testAnUnknownLineUploadsWithNeitherTheEventsNorTheUserDetailsConsentAlone() {
        let transport = FakeTransport()
        transport.granted = [.events]
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_unknown"), source: "test")

        let line = "[SomethingAddedLater] work, a value it was handed: [secret-value]"
        gatherer.capture(line, level: .debug, scope: LogGatheringScope.of(module: "SomethingAddedLater", function: "work", message: line))
        gatherer.flushNow()
        XCTAssertTrue(transport.payloads.isEmpty, "the events consent alone does not cover a line no single feature owns")

        transport.granted = [.userDetails]
        gatherer.consentDidChange()
        gatherer.flushNow()
        XCTAssertTrue(transport.payloads.isEmpty, "nor does the user details consent alone")
        XCTAssertEqual(awaitingMessages(gatherer), [line])

        transport.granted = [.events, .userDetails]
        gatherer.consentDidChange()
        gatherer.flushNow()
        XCTAssertEqual(uploadedMessages(transport), [line], "the two together are enough, the other features are not needed")
    }

    /// A device ID change logs the next user's ID, so while it runs no delivery
    /// takes a line it logged: a change without merge drops them, and one that
    /// keeps the gather lets them go out once it ends.
    func testNoDeliveryTakesTheLinesOfADeviceIDChangeInProgress() {
        let transport = FakeTransport()
        let stopped = makeGatherer(transport)
        stopped.apply(directive(id: "gather_change"), source: "test")
        capture(stopped, 2, message: "before the change")
        stopped.deviceIDChangeBegins()
        capture(stopped, 2, message: "device ID change value detail, providedDeviceID: [new_user]")

        stopped.flushNow()
        XCTAssertEqual(uploadedMessages(transport), ["before the change 0", "before the change 1"])

        stopped.stopForDeviceIDChange()
        stopped.deviceIDChangeEnds()
        XCTAssertFalse(uploadedMessages(transport).contains { $0.contains("new_user") }, "the next user's ID reached the previous user's gather")
        XCTAssertEqual(stopped.currentState, .off)

        let mergeTransport = FakeTransport()
        let merged = makeGatherer(mergeTransport)
        merged.apply(directive(id: "gather_merge"), source: "test")
        merged.deviceIDChangeBegins()
        capture(merged, 2, message: "device ID value detail for the merging change, deviceID: [merged_user]")
        merged.deviceIDChangeEnds()
        merged.flushNow()
        XCTAssertEqual(uploadedMessages(mergeTransport).count, 2, "a merge keeps the gather, and the change's lines with it")
    }

    /// A buffered line answers to its consent until it is uploaded, so
    /// withdrawing that consent takes it back out of the buffer, and giving it
    /// again releases it.
    func testWithdrawingAConsentTakesItsLinesBackOutOfTheBuffer() {
        let transport = FakeTransport()
        transport.granted = [.events, .userDetails]
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_withdraw"), source: "test")

        let property = "[UserProfile] setProperty, value: [withdrawn@example.com]"
        let event = "[Events] recordEvent, key: [purchase]"
        gatherer.capture(property, level: .debug, scope: .feature(.userDetails))
        gatherer.capture(event, level: .debug, scope: .feature(.events))
        XCTAssertEqual(messages(gatherer), [property, event])

        transport.granted = [.events]
        gatherer.consentDidChange()
        XCTAssertEqual(messages(gatherer), [event])
        XCTAssertEqual(awaitingMessages(gatherer), [property], "the withdrawn line waits again instead of going out")
        gatherer.flushNow()
        XCTAssertEqual(uploadedMessages(transport), [event])

        transport.granted = [.events, .userDetails]
        gatherer.consentDidChange()
        gatherer.flushNow()
        XCTAssertEqual(uploadedMessages(transport), [event, property])
    }

    /// A batch out for upload holds no line a withdrawal could recall, so when the
    /// queue refuses it, its lines come back decided against the consent then.
    func testARefusedBatchComesBackDecidedAgainstTheConsentAsItIsThen() {
        let transport = FakeTransport()
        transport.granted = [.events, .userDetails]
        let gatherer = makeGatherer(transport)
        gatherer.apply(directive(id: "gather_refused_withdrawn"), source: "test")
        let property = "[UserProfile] setProperty, value: [withdrawn@example.com]"
        gatherer.capture(property, level: .debug, scope: .feature(.userDetails))

        transport.refuses = true
        transport.granted = [.events]
        gatherer.flushNow()

        XCTAssertTrue(transport.payloads.isEmpty)
        XCTAssertTrue(messages(gatherer).isEmpty)
        XCTAssertEqual(awaitingMessages(gatherer), [property])
    }

    /// Before init no line can be decided yet, so a line dropped then counts
    /// toward `d` only once init shows that its consent is given.
    func testADropBeforeInitCountsOnlyForALineWhoseConsentTurnsOutGiven() {
        let transport = FakeTransport()
        transport.granted = [.events]
        let gatherer = makeGatherer(transport, initFinished: false)

        // The 15 oldest go: 10 lines no single feature owns, then 5 events lines.
        capture(gatherer, 10, scope: .unattributed)
        capture(gatherer, 5, scope: .feature(.events))
        capture(gatherer, maxBufferedLines, scope: .feature(.events))
        gatherer.sdkInitFinished()

        XCTAssertEqual(gatherer.pendingDroppedCount, 5, "a dropped line that would have waited for its consent is no loss to report")
    }

    /// The waiting lines are bounded like the buffer, by lines and by characters,
    /// but what they lose is not reported, since it was never gathered.
    func testTheAwaitingLinesAreCappedLikeTheBufferWithoutCountingTheDrops() {
        let transport = FakeTransport()
        transport.granted = []
        let gatherer = makeGatherer(transport)

        capture(gatherer, maxBufferedLines + 25, scope: .feature(.events))
        XCTAssertEqual(awaitingMessages(gatherer).count, maxBufferedLines)
        XCTAssertEqual(awaitingMessages(gatherer).first, "\(harnessPrefix) 25", "the oldest go first")
        XCTAssertEqual(gatherer.pendingDroppedCount, 0, "a line whose consent was never given was never gathered, so it is no loss to report")

        let long = String(repeating: "c", count: maxMessageLength - 100)
        capture(gatherer, 40, message: long, scope: .feature(.events))
        XCTAssertLessThanOrEqual(awaitingMessages(gatherer).reduce(0) { $0 + $1.utf16.count }, charCeiling)
        XCTAssertEqual(awaitingMessages(gatherer).last, "\(long) 39")
        XCTAssertEqual(gatherer.pendingDroppedCount, 0)
        XCTAssertEqual(gatherer.heldLineCount, 0)
    }

    /// A waiting line belongs to the gather it was captured in, so it is filtered,
    /// kept and dropped exactly like a buffered one.
    func testTheAwaitingLinesFollowTheGatherLikeTheBuffer() {
        let transport = FakeTransport()
        transport.granted = []

        let gatherer = makeGatherer(transport)
        capture(gatherer, 2, level: .debug, scope: .feature(.events))
        capture(gatherer, 3, level: .error, scope: .feature(.events))
        gatherer.apply(directive(id: "gather_a", levels: "e"), source: "test")
        XCTAssertEqual(gatherer.linesAwaitingConsent.map(\.level), ["e", "e", "e"], "adoption filters them by level")

        gatherer.apply(directive(id: "gather_a", levels: "e"), source: "test")
        XCTAssertEqual(awaitingMessages(gatherer).count, 3, "a repeated directive keeps them")

        gatherer.apply(directive(id: "gather_b", levels: "e"), source: "test")
        XCTAssertTrue(awaitingMessages(gatherer).isEmpty, "they belong to the gather that ended")

        capture(gatherer, 2, level: .error, scope: .feature(.events))
        gatherer.apply(.off, source: "test")
        XCTAssertTrue(awaitingMessages(gatherer).isEmpty, "a stop drops them")

        let undecided = makeGatherer(transport)
        capture(undecided, 2, scope: .feature(.events))
        undecided.decideOffIfUndecided("test")
        XCTAssertTrue(awaitingMessages(undecided).isEmpty, "deciding off drops them")
    }

    /// The consents a configuration names are given at the end of init, so a line
    /// decided before that would be decided against an incomplete state.
    func testLinesCapturedBeforeInitFinishesAreDecidedWhenItDoes() {
        let transport = FakeTransport()
        transport.granted = []
        let gatherer = makeGatherer(transport, initFinished: false)
        gatherer.apply(directive(id: "gather_init"), source: "test")

        let event = "[Events] recordEvent, key: [purchase]"
        let property = "[UserProfile] setProperty, value: [someone@example.com]"
        gatherer.capture(event, level: .debug, scope: .feature(.events))
        gatherer.capture(property, level: .debug, scope: .feature(.userDetails))
        XCTAssertEqual(messages(gatherer), [event, property], "nothing is decided while the consent state is still being built")
        XCTAssertTrue(awaitingMessages(gatherer).isEmpty)

        // The consents a configuration names are given at the very end of init.
        transport.granted = [.events]
        gatherer.sdkInitFinished()

        XCTAssertEqual(awaitingMessages(gatherer), [property])
        TestUtils.waitUntil("init finishing uploads what its consent allows") { transport.payloads.count == 1 }
        XCTAssertEqual(uploadedMessages(transport), [event])
    }

    // MARK: - Wired into the SDK

    private func gatherer(of instance: CountlyInstance) -> LogGatherer {
        core(of: instance).logGatherer
    }

    /// Every queued request carrying an `sdk_logs` batch, decoded, oldest first.
    private func uploadedBatches(of instance: CountlyInstance) -> [[String: Any]] {
        requestQueue(of: instance).map(TestUtils.parseQuery).compactMap { $0["sdk_logs"] as? [String: Any] }
    }

    /// The messages of every line this instance queued for upload, oldest first.
    private func uploadedMessages(of instance: CountlyInstance) -> [String] {
        uploadedBatches(of: instance).flatMap { lines(in: $0) }.compactMap { $0["m"] as? String }
    }

    private func respondToBehaviorSettings(with json: String) {
        MockURLProtocol.respond { captured in
            guard captured.path.contains("/o/sdk"), captured.query.contains("method=sc") else { return nil }
            return (200, Data(json.utf8))
        }
    }

    /// Accepts every gathered log batch, so one queued at init end cannot stay
    /// failing at the head of the queue and hold back the requests behind it.
    private func acceptGatheredBatches() {
        MockURLProtocol.respond { captured in
            captured.query.contains("\(QS.sdkLogs)=") ? (200, Data(#"{"result":"Success"}"#.utf8)) : nil
        }
    }

    /// Whether a captured request is an ordinary one carrying `key`, rather than
    /// a gathered log batch quoting a line about it.
    private func isEventRequest(_ captured: MockURLProtocol.Captured, carrying key: String) -> Bool {
        captured.query.contains(key) && !captured.query.contains("\(QS.sdkLogs)=")
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
        XCTAssertTrue(uploadedMessages(of: countly).allSatisfy { !$0.contains("sdk_logs") }, "a batch nested the previous one")
    }

    /// The events module's lines answer to the events consent, while a line the
    /// SDK logged about itself still needs the user details consent too.
    func testAnEventsLineUploadsWithTheEventsConsentAlone() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_events") {
            $0.requiresConsent = true
            $0.consents = [.events]
        }

        countly.events.recordEvent("purchase_completed")
        gatherer(of: countly).flushNow()

        let uploaded = uploadedMessages(of: countly)
        XCTAssertTrue(uploaded.contains { $0.contains("[Events]") && $0.contains("purchase_completed") },
                      "the events consent covers the lines the events module wrote")
        XCTAssertFalse(uploaded.contains { $0.contains("initializing, appKey") },
                       "a line no single feature owns needs the user details consent as well")
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains("initializing, appKey") })
    }

    /// Giving a consent through the public API releases the lines that waited for
    /// it, so nothing logged before the consent is lost.
    func testAUserPropertyLineWaitsForTheUserDetailsConsentAndIsReleasedOnceItIsGiven() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_users") {
            $0.requiresConsent = true
            $0.consents = [.events]
        }
        let propertyLine = "single user property value detail, key: [email], value: [someone@example.com]"

        countly.userProfile.setProperty("email", value: "someone@example.com")
        gatherer(of: countly).flushNow()
        XCTAssertFalse(uploadedMessages(of: countly).contains { $0.contains("someone@example.com") })
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains(propertyLine) })

        countly.consent.giveConsent(for: [.userDetails])
        gatherer(of: countly).flushNow()

        XCTAssertTrue(uploadedMessages(of: countly).contains { $0.contains(propertyLine) }, "giving the consent releases the line that waited for it")
        XCTAssertFalse(awaitingMessages(gatherer(of: countly)).contains { $0.contains(propertyLine) })
    }

    /// Only the uploaded copy waits for consent: the developer log keeps showing
    /// every call in full.
    func testWithOnlySessionsConsentNoSecretIsUploadedAndEachWaitsWhileTheLocalLogKeepsIt() throws {
        try skipUnlessNetworkIsInterceptable()
        let sink = LogSink()
        let countly = startArmed(id: "gather_secrets") {
            $0.requiresConsent = true
            $0.consents = [.sessions]
            $0.loggerDelegate = sink
            $0.internalLogLevel = .verbose
        }

        countly.sessions.beginSession()
        countly.events.recordEvent("purchase", segmentation: ["sku": "secret-sku"])
        _ = countly.views.startView("secret checkout screen")
        countly.userProfile.setProperty("email", value: "secret@example.com")
        gatherer(of: countly).flushNow()

        let uploaded = uploadedMessages(of: countly)
        XCTAssertTrue(uploaded.contains { $0.contains("[Sessions]") }, "the sessions consent lets the sessions lines out")
        let awaiting = awaitingMessages(gatherer(of: countly))
        for secret in ["secret-sku", "secret checkout screen", "secret@example.com"] {
            XCTAssertFalse(uploaded.contains { $0.contains(secret) }, "[\(secret)] reached the server without the consent it belongs to")
            XCTAssertTrue(awaiting.contains { $0.contains(secret) }, "[\(secret)] waits for its consent instead of being dropped")
            XCTAssertTrue(sink.lines.contains { $0.contains(secret) }, "the local log lost [\(secret)]")
        }
    }

    /// Recording `[CLY]_view` through the events API logs the view name before the
    /// views consent is checked, so that line answers to the views consent.
    func testAViewNameRecordedUnderTheReservedViewKeyWaitsForTheViewsConsent() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_reserved") {
            $0.requiresConsent = true
            $0.consents = [.events, .userDetails]
        }

        countly.events.recordEvent("[CLY]_view", segmentation: ["name": "secret-view-name"])
        gatherer(of: countly).flushNow()
        XCTAssertFalse(uploadedMessages(of: countly).contains { $0.contains("secret-view-name") },
                       "the events module logs a reserved event before it checks the views consent the event answers to")
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains("secret-view-name") })

        countly.consent.giveConsent(for: [.viewTracking])
        gatherer(of: countly).flushNow()
        XCTAssertTrue(uploadedMessages(of: countly).contains { $0.contains("secret-view-name") })
    }

    /// Init logs before it reads whether consent is required, and those lines must
    /// not go out as if it were not.
    func testWithConsentRequiredAndNoneGivenNoInitLineIsUploaded() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_init_consent") { $0.requiresConsent = true }

        gatherer(of: countly).flushNow()

        XCTAssertTrue(uploadedBatches(of: countly).isEmpty, "every line needs a consent, those logged before init read the consent requirement too")
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains("developer configuration before any behavior setting is applied") })
    }

    /// A change of the consent requirement re-decides every waiting line, as
    /// giving a consent does.
    func testLinesAwaitingConsentAreReleasedWhenConsentIsNoLongerRequired() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_requirement") { $0.requiresConsent = true }
        countly.events.recordEvent("waiting-event")
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains("waiting-event") })

        core(of: countly).modules.consent.requiresConsent = false
        gatherer(of: countly).flushNow()

        XCTAssertTrue(uploadedMessages(of: countly).contains { $0.contains("waiting-event") })
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).isEmpty)
    }

    /// Without a consent requirement every feature counts as consented, so no
    /// line waits.
    func testWithoutConsentRequiredEveryLineUploads() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_open")

        countly.events.recordEvent("purchase")
        countly.userProfile.setProperty("email", value: "someone@example.com")
        gatherer(of: countly).flushNow()

        let uploaded = uploadedMessages(of: countly)
        XCTAssertTrue(uploaded.contains { $0.contains("[Events]") && $0.contains("purchase") })
        XCTAssertTrue(uploaded.contains { $0.contains("someone@example.com") })
        XCTAssertTrue(uploaded.contains { $0.contains("initializing, appKey") })
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).isEmpty, "nothing waits while consent is not required")
    }

    /// The limits cut a value on behalf of the feature that handed it over, here
    /// before the crash consent is ever checked, so the line they log about it
    /// answers to that feature rather than to events and user details.
    func testALimitsLineAnswersToTheConsentOfTheFeatureWhoseValueItCut() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_limits") {
            $0.requiresConsent = true
            $0.consents = [.events, .userDetails]
        }

        countly.crashes.setCrashSegmentation(["note": String(repeating: "x", count: 300) + "SECRET-CRASH-SEGMENTATION"])
        gatherer(of: countly).flushNow()

        XCTAssertFalse(uploadedMessages(of: countly).contains { $0.contains("SECRET-CRASH-SEGMENTATION") },
                       "crash data reached the server on the events and user details consent")
        let cut = try XCTUnwrap(gatherer(of: countly).linesAwaitingConsent.first { $0.message.contains("[Limits]") && $0.message.contains("SECRET-CRASH-SEGMENTATION") })
        XCTAssertEqual(cut.scope, .feature(.crashReporting))
    }

    /// A request queued for the previous user still goes out after a change
    /// without merge, and what its send logs quotes that user's data, so only
    /// the gather of the user it was queued for takes those lines.
    func testARequestQueuedForThePreviousDeviceIDIsNotGatheredForTheNextUser() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_old_user", batchSize: maxBufferedLines)
        acceptGatheredBatches()
        countly.events.recordEvent("old-user-secret-event")
        core(of: countly).modules.events.sendEventsWithSaveIfNeeded()
        TestUtils.waitUntil("the old user's gather takes the lines of the old user's request") {
            (messages(gatherer(of: countly)) + uploadedMessages(of: countly)).contains { $0.contains("[ConnectionManager]") && $0.contains("old-user-secret-event") }
        }

        countly.deviceID.changeWithoutMerge("new_user")
        gatherer(of: countly).apply(directive(id: "gather_new_user"), source: "test")
        let sendsBefore = MockURLProtocol.requests.count
        TestUtils.waitUntil("the old user's request is sent again while the next user's gather runs") {
            core(of: countly).network.proceedOnQueue()
            return MockURLProtocol.requests.dropFirst(sendsBefore).contains { isEventRequest($0, carrying: "old-user-secret-event") }
        }
        TestUtils.pump(0.3)

        let gathered = messages(gatherer(of: countly)) + awaitingMessages(gatherer(of: countly))
        XCTAssertFalse(gathered.contains { $0.contains("old-user-secret-event") }, "the next user's gather took the previous user's request")
    }

    /// A request still out when the device ID changes is the previous user's, so
    /// what its completion logs is not gathered for the next user either.
    func testTheCompletionOfARequestSentBeforeADeviceIDChangeIsNotGatheredForTheNextUser() throws {
        try skipUnlessNetworkIsInterceptable()
        let sink = LogSink()
        let countly = startArmed(id: "gather_in_flight", batchSize: maxBufferedLines) {
            $0.loggerDelegate = sink
            $0.internalLogLevel = .verbose
        }
        acceptGatheredBatches()
        MockURLProtocol.respond { captured in
            guard self.isEventRequest(captured, carrying: "in-flight-secret-event") else { return nil }
            // Slow, so the device ID changes while the request is out.
            Thread.sleep(forTimeInterval: 0.5)
            return (500, Data("in-flight-secret-reply".utf8))
        }

        countly.events.recordEvent("in-flight-secret-event")
        core(of: countly).modules.events.sendEventsWithSaveIfNeeded()
        TestUtils.waitUntil("the request is out") { MockURLProtocol.requests.contains { isEventRequest($0, carrying: "in-flight-secret-event") } }
        countly.deviceID.changeWithoutMerge("new_user")
        gatherer(of: countly).apply(directive(id: "gather_new_user"), source: "test")
        TestUtils.waitUntil("the reply to the previous user's request arrived") { sink.lines.contains { $0.contains("in-flight-secret-reply") } }

        let gathered = messages(gatherer(of: countly)) + awaitingMessages(gatherer(of: countly))
        XCTAssertFalse(gathered.contains { $0.contains("in-flight-secret") }, "the next user's gather took the reply to the previous user's request")
    }

    /// Withdrawing a consent through the public API takes that feature's lines
    /// back out of the upload buffer. Tracking is off, so no delivery can take
    /// the line first.
    func testWithdrawingAConsentThroughThePublicAPIRecallsItsLines() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_withdraw_api", settings: ServerConfigBuilder().tracking(false)) {
            $0.requiresConsent = true
            $0.consents = [.events, .userDetails]
        }
        countly.userProfile.setProperty("email", value: "withdrawn@example.com")
        XCTAssertTrue(messages(gatherer(of: countly)).contains { $0.contains("withdrawn@example.com") })

        countly.consent.cancelConsent(for: [.userDetails])

        XCTAssertFalse(messages(gatherer(of: countly)).contains { $0.contains("withdrawn@example.com") })
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains("withdrawn@example.com") })
    }

    /// A change without merge is a new user: what the old one may upload goes out
    /// under the old device ID, and the gather does not follow the next user.
    func testADeviceIDChangeWithoutMergeUploadsUnderTheOldIDAndThenStops() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_old_user")
        countly.events.recordEvent("old-user-event")

        countly.deviceID.changeWithoutMerge("new_user")

        let logRequests = TestUtils.requests(requestQueue(of: countly), carrying: "sdk_logs")
        XCTAssertTrue(uploadedMessages(of: countly).contains { $0.contains("old-user-event") }, "the held lines go out before the switch")
        XCTAssertTrue(logRequests.allSatisfy { ($0["device_id"] as? String) == Self.deviceID }, "every gathered line belongs to the old user")
        XCTAssertFalse(uploadedMessages(of: countly).contains { $0.contains("new_user") }, "the next user's ID never lands in the previous user's gather")
        XCTAssertEqual(gatherer(of: countly).currentState, .off)
        XCTAssertEqual(gatherer(of: countly).heldLineCount, 0)

        countly.events.recordEvent("new-user-event")
        gatherer(of: countly).flushNow()
        XCTAssertEqual(TestUtils.requests(requestQueue(of: countly), carrying: "sdk_logs").count, logRequests.count,
                       "the next user is not part of the old user's gather")
    }

    /// The next user's consent must never release a line the previous user did
    /// not consent to.
    func testADeviceIDChangeWithoutMergeDropsTheLinesAwaitingConsent() throws {
        try skipUnlessNetworkIsInterceptable()
        let countly = startArmed(id: "gather_old_user_consent") {
            $0.requiresConsent = true
            $0.consents = [.sessions]
        }
        countly.events.recordEvent("old-user-secret")
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).contains { $0.contains("old-user-secret") })

        countly.deviceID.changeWithoutMerge("new_user")
        countly.consent.giveConsent(for: [.events, .userDetails])
        gatherer(of: countly).flushNow()

        XCTAssertFalse(uploadedMessages(of: countly).contains { $0.contains("old-user-secret") },
                       "the old user's lines never go out under the next user's consent")
        XCTAssertTrue(awaitingMessages(gatherer(of: countly)).isEmpty)
        XCTAssertEqual(gatherer(of: countly).currentState, .off)
    }

    /// A directive fetched for the previous device ID belongs to that user, so it
    /// must not arm a gather for the next one.
    func testADirectiveFetchedBeforeADeviceIDChangeIsIgnored() throws {
        try skipUnlessNetworkIsInterceptable()
        MockURLProtocol.respond { captured in
            guard captured.path.contains("/o/sdk"), captured.query.contains("method=sc") else { return nil }
            // Slow, so the device ID changes while the fetch is in flight.
            Thread.sleep(forTimeInterval: 0.5)
            return (200, Data(ServerConfigBuilder().armLogGathering(id: "gather_previous_user").json().utf8))
        }
        let sink = LogSink()
        let countly = startInstance {
            $0.loggerDelegate = sink
            $0.internalLogLevel = .debug
        }

        countly.deviceID.changeWithoutMerge("new_user")
        TestUtils.waitUntil("the answer to the fetch made for the previous device ID arrived") {
            sink.lines.contains { $0.contains("the device ID changed while the fetch was in flight") }
        }

        XCTAssertEqual(gatherer(of: countly).currentState, .off, "the previous user's directive never arms a gather for the next user")
    }

    /// Temporary mode drops the identity like a change without merge, while a
    /// merge keeps the same user and so the same gather.
    func testEnteringTemporaryIDModeStopsLikeAChangeWithoutMergeAndAMergeKeepsGathering() throws {
        try skipUnlessNetworkIsInterceptable()
        let temporary = startArmed(id: "gather_temporary")
        temporary.events.recordEvent("before-temporary-mode")

        temporary.deviceID.enableTemporaryIDMode()

        let logRequests = TestUtils.requests(requestQueue(of: temporary), carrying: "sdk_logs")
        XCTAssertTrue(uploadedMessages(of: temporary).contains { $0.contains("before-temporary-mode") })
        XCTAssertTrue(logRequests.allSatisfy { ($0["device_id"] as? String) == Self.deviceID })
        XCTAssertEqual(gatherer(of: temporary).currentState, .off)

        let merged = startArmed(id: "gather_merge")
        merged.deviceID.changeWithMerge("merged_user")
        XCTAssertEqual(gatherer(of: merged).currentState, .gathering, "a merge is the same user, so the gather goes on")
        XCTAssertEqual(gatherer(of: merged).currentDirective.gatherID, "gather_merge")
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
