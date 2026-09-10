//
//  LogGathering.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Where log gathering stands for this run.
///
/// Every run starts undecided and captures every level speculatively, so the
/// lines logged during init are still there when a live behavior settings
/// response adopts them. Only a live response, or the certainty that none can
/// arrive this run, moves the state on.
enum LogGatheringState {
    case undecided
    case gathering
    case off
}

/// The parsed `lg` directive of a live behavior settings response.
///
/// Wire shapes: `{"e":false}` or `{"e":true,"i":"<id>","l":"ewidv","b":100}`.
/// A directive that enables gathering without a usable gather ID is treated as
/// off, because the server rejects every batch it cannot attribute.
struct LogGatheringDirective: Equatable {

    /// Keys of the `lg` object.
    enum Key {
        static let enabled = "e"
        static let gatherID = "i"
        static let levels = "l"
        static let batchSize = "b"
    }

    /// Every level character the wire protocol knows, which is also the fallback
    /// when the directive names none.
    static let allLevels = "ewidv"
    static let defaultBatchSize = 100
    static let minBatchSize = 10
    static let maxBufferedLines = 500

    /// `nil` when the directive says gathering is off.
    let gatherID: String?
    let levels: String
    let batchSize: Int

    /// The directive that turns gathering off.
    static let off = LogGatheringDirective(gatherID: nil, levels: allLevels, batchSize: defaultBatchSize)

    var isGathering: Bool { gatherID != nil }

    /// Reads a directive out of whatever the response carried under `lg`.
    ///
    /// Anything that is not a dictionary with `e` set to true and a non-empty
    /// string `i` decides off. Levels and batch size are sanitized rather than
    /// refused, so an odd value from the dashboard still yields a working gather.
    static func parse(_ raw: Any?, logger: Logger?) -> LogGatheringDirective {
        guard let directive = raw as? [String: Any] else {
            logger?.d("LogGathering", "parse", "the response carries no usable lg directive, log gathering is off")
            return .off
        }

        guard let enabled = directive[Key.enabled] as? NSNumber, enabled.boolValue else {
            logger?.d("LogGathering", "parse", "the lg directive says log gathering is off")
            return .off
        }

        let gatherID = (directive[Key.gatherID] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !gatherID.isEmpty else {
            logger?.d("LogGathering", "parse", "the lg directive enables log gathering but carries no usable gather ID, log gathering is off")
            return .off
        }

        let levels = sanitizeLevels(directive[Key.levels], logger: logger)
        let batchSize = clampBatchSize(directive[Key.batchSize])
        logger?.d("LogGathering", "parse", "the lg directive enables log gathering, gatherID: [\(gatherID)], levels: [\(levels)], batchSize: [\(batchSize)]")
        return LogGatheringDirective(gatherID: gatherID, levels: levels, batchSize: batchSize)
    }

    /// Keeps the level characters this SDK knows, lowercased, in the order sent
    /// and without duplicates. Falls back to every level when nothing usable is
    /// left, because an armed gather that captures nothing looks like a broken
    /// feature.
    static func sanitizeLevels(_ raw: Any?, logger: Logger?) -> String {
        guard let levels = raw as? String else { return allLevels }

        var filtered = ""
        for character in levels.lowercased() where allLevels.contains(character) && !filtered.contains(character) {
            filtered.append(character)
        }

        guard !filtered.isEmpty else {
            logger?.d("LogGathering", "sanitizeLevels", "no usable level in the lg directive, falling back to every level, received: [\(levels)]")
            return allLevels
        }
        return filtered
    }

    /// Clamps the batch size into the accepted range, falling back to the default
    /// when the value is missing or not a number.
    static func clampBatchSize(_ raw: Any?) -> Int {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return defaultBatchSize
        }
        return min(maxBufferedLines, max(minBatchSize, number.intValue))
    }
}

/// What the gatherer needs from the rest of the SDK to deliver a batch.
protocol LogGatheringTransport: AnyObject {
    /// Whether behavior settings allow requests to be queued at all.
    var isTrackingEnabled: Bool { get }
    /// Whether any consent is given. Gathered lines quote event keys, segmentation
    /// and whole requests, so they are user data.
    var hasAnyConsent: Bool { get }
    /// Queues one `sdk_logs` batch. Returns whether the queue took it.
    func sendSdkLogs(_ payload: String) -> Bool
}

/// Gathers the SDK's own log lines for one instance and uploads them as
/// `sdk_logs` batches when a live behavior settings response asks for them.
///
/// Wire shape of a batch: `{"i":gatherID,"d":dropped,"l":[{"t":ms,"l":"e","m":message}]}`.
/// Nothing here is persisted: the arm is held in memory and re-learned from the
/// next `sc` response, exactly like the connection test.
final class LogGatherer {

    private static let module = "LogGathering"

    /// Keys of the uploaded batch.
    enum BatchKey {
        static let gatherID = "i"
        static let droppedCount = "d"
        static let lines = "l"
    }

    /// Keys of one line inside a batch.
    enum LineKey {
        static let timestamp = "t"
        static let level = "l"
        static let message = "m"
    }

    /// The server stores at most this many characters of a message, so there is
    /// no point in holding more.
    static let maxMessageLength = 4096

    /// Second ceiling, on the characters held in total. A line may be a whole
    /// message long, so a line count alone is not a bound on memory.
    static let charCeiling = 128 * 1024

    /// A line that quotes an uploaded batch is never gathered, or every batch
    /// would nest the previous one and an idle SDK would gather forever.
    static let transportMarker = QS.sdkLogs

    /// One gathered line, already truncated.
    struct Line: Equatable {
        let timestamp: Int64
        let level: String
        let message: String
    }

    /// One batch taken out of the buffer, with what it was built from so a refused
    /// send can put it back.
    private struct Batch {
        let lines: [Line]
        let dropped: Int
        let gatherID: String
    }

    /// Guards every field below it. Nothing is logged while it is held: logging
    /// re-enters `capture`, which takes the same lock.
    private let lock = NSLock()
    private var lines: [Line] = []
    private var heldChars = 0
    private var droppedCount = 0
    private var state: LogGatheringState = .undecided
    private var directive = LogGatheringDirective.off
    private var initFinished = false

    /// Serializes deliveries. The timer schedules them on `deliveryQueue`, the
    /// background and terminate paths run them on the caller's thread, and two
    /// deliveries interleaving would queue batches out of order.
    private let deliveryLock = NSLock()

    /// Uploads run here, never on the thread that logged the line that filled a
    /// batch: that thread may be inside a store write or a lock of its own.
    private let deliveryQueue = DispatchQueue(label: "ly.count.sdklogs.delivery", qos: .utility)

    /// Per instance, so two instances in one process cannot mute each other's
    /// capture through a shared thread flag.
    private let transportMarkKey: String

    /// The logger this gatherer captures from. Weak: the logger holds the gatherer.
    private weak var logger: Logger?

    /// Set once the networking layer exists. Weak: the core owns both.
    weak var transport: LogGatheringTransport?

    init(logger: Logger?) {
        self.logger = logger
        transportMarkKey = "ly.count.sdklogs.transport.\(UUID().uuidString)"
    }

    // MARK: - State

    /// Whether lines still have to be held: undecided or gathering. This is what
    /// makes the logger format a line while console logging is off.
    var isCapturing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state != .off
    }

    var isGathering: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .gathering
    }

    var currentState: LogGatheringState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// The directive in effect, for tests and log dumps.
    var currentDirective: LogGatheringDirective {
        lock.lock()
        defer { lock.unlock() }
        return directive
    }

    /// A copy of the held lines, oldest first.
    var heldLines: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    var heldLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return lines.count
    }

    /// Lines dropped since the last upload, reported as `d` with the next batch.
    var pendingDroppedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedCount
    }

    // MARK: - Directives

    /// Applies a directive from a live response to what is held.
    ///
    /// Off drops everything held speculatively. Gathering adopts the held lines,
    /// filtered to the requested levels, unless they belong to a different gather
    /// that was already running, in which case they are dropped because the
    /// server rejects a batch attributed to a gather that ended.
    func apply(_ directive: LogGatheringDirective, source: String) {
        let newState: LogGatheringState = directive.isGathering ? .gathering : .off

        lock.lock()
        guard state != newState || self.directive != directive else {
            let held = lines.count
            lock.unlock()
            logger?.d(Self.module, "apply", "the log gathering directive is unchanged, source: [\(source)], heldLineCount: [\(held)]")
            return
        }

        let wasGathering = state == .gathering
        let previousGatherID = self.directive.gatherID
        state = newState
        self.directive = directive

        if newState == .off {
            clearBufferLocked()
        } else if wasGathering, previousGatherID != directive.gatherID {
            clearBufferLocked()
        } else {
            filterBufferLocked()
            trimBufferLocked()
        }
        let held = lines.count
        lock.unlock()

        logger?.d(Self.module, "apply", "the log gathering directive is applied, source: [\(source)], gathering: [\(directive.isGathering)], gatherID: [\(directive.gatherID ?? "none")], levels: [\(directive.levels)], batchSize: [\(directive.batchSize)], heldLineCount: [\(held)]")

        if newState == .gathering {
            // Adoption may hand over a buffer already past the batch size. Partial
            // batches wait for the timer, the background or init finishing.
            scheduleDelivery(includePartialBatch: false)
        }
    }

    /// No response can arrive this run, which decides against gathering, but only
    /// while nothing has been decided yet. A running gather survives a transient
    /// failure of the periodic refetch.
    func decideOffIfUndecided(_ reason: String) {
        lock.lock()
        guard state == .undecided else {
            lock.unlock()
            return
        }
        resetLocked(to: .off)
        lock.unlock()

        logger?.d(Self.module, "decideOffIfUndecided", "log gathering is decided off, the speculatively held lines are dropped, reason: [\(reason)]")
    }

    // MARK: - Lifecycle

    /// The request queue is usable from here on, so this is the first chance for
    /// the lines gathered during init to go out.
    func sdkInitFinished() {
        lock.lock()
        initFinished = true
        let gathering = state == .gathering
        lock.unlock()

        if gathering {
            logger?.d(Self.module, "sdkInitFinished", "init finished while gathering, the lines held so far will be uploaded")
            scheduleDelivery(includePartialBatch: true)
        }
    }

    /// Timer flush, so a buffer that never fills a batch still goes out.
    func scheduleFlush() {
        guard isGathering, heldLineCount > 0 else { return }
        scheduleDelivery(includePartialBatch: true)
    }

    /// Synchronous flush, for the paths where the process may not come back:
    /// entering the background and terminating. Nothing is persisted, so getting
    /// the tail into the request queue now is the only way it survives.
    func flushNow() {
        guard isGathering else { return }
        deliver(includePartialBatch: true)
    }

    /// Ends the run: the held lines are discarded without a tail upload and
    /// nothing is captured or delivered any more. The next start builds a new
    /// core with a gatherer of its own, so nothing about a gather outlives its run.
    func halt() {
        lock.lock()
        resetLocked(to: .off)
        initFinished = false
        lock.unlock()
    }

    /// Moves to `state` with the default directive and an empty buffer.
    private func resetLocked(to newState: LogGatheringState) {
        state = newState
        directive = .off
        clearBufferLocked()
    }

    // MARK: - Capture

    /// Holds one line. Called by the logger for every line anything wants.
    func capture(_ message: String, level: CountlyLogLevel) {
        guard !isTransportWork else { return }
        guard !message.contains(Self.transportMarker) else { return }

        let levelChar = level.gatheringLevel
        var batchIsFull = false

        lock.lock()
        guard state != .off else {
            lock.unlock()
            return
        }
        // Level filtering is deferred while undecided: the wanted levels are not
        // known yet, so every level is held and the buffer is filtered on adoption.
        if state == .gathering, !directive.levels.contains(levelChar) {
            lock.unlock()
            return
        }

        let line = Line(timestamp: Int64(Date().timeIntervalSince1970 * 1000),
                        level: String(levelChar),
                        message: message.countlyPrefix(Self.maxMessageLength))
        lines.append(line)
        heldChars += line.message.countlyLength
        trimBufferLocked()
        batchIsFull = state == .gathering && lines.count >= directive.batchSize
        lock.unlock()

        if batchIsFull {
            scheduleDelivery(includePartialBatch: false)
        }
    }

    // MARK: - Transport mark

    /// Whether the calling thread is doing this feature's own transport work, so
    /// what it logs meanwhile is not gathered.
    var isTransportWork: Bool {
        Thread.current.threadDictionary[transportMarkKey] as? Bool == true
    }

    /// Runs `body` with the calling thread's mark set to exactly `active`, and
    /// restores the caller's own mark afterwards.
    ///
    /// Exactly, not inherited: the delivery loop reaches the request path
    /// synchronously and the head it sends is usually an older, ordinary request,
    /// whose send lines an operator wants to see. Restored, because the loop keeps
    /// logging after the send returns.
    func markingTransportWork<T>(_ active: Bool, _ body: () -> T) -> T {
        let previous = isTransportWork
        setTransportWork(active)
        defer { setTransportWork(previous) }
        return body()
    }

    private func setTransportWork(_ active: Bool) {
        if active {
            Thread.current.threadDictionary[transportMarkKey] = true
        } else {
            Thread.current.threadDictionary.removeObject(forKey: transportMarkKey)
        }
    }

    // MARK: - Delivery

    private func scheduleDelivery(includePartialBatch: Bool) {
        lock.lock()
        let ready = initFinished
        lock.unlock()
        // The request queue is not usable before init finishes; the tail goes out
        // from `sdkInitFinished`.
        guard ready else { return }

        deliveryQueue.async { [weak self] in
            self?.deliver(includePartialBatch: includePartialBatch)
        }
    }

    /// Uploads one batch, then keeps going while full batches remain. Lines stay
    /// held while the request queue would drop them: tracking off, or no consent
    /// given yet.
    private func deliver(includePartialBatch: Bool) {
        lock.lock()
        let ready = initFinished
        lock.unlock()
        guard ready, let transport else { return }

        deliveryLock.lock()
        defer { deliveryLock.unlock() }

        markingTransportWork(true) {
            guard transport.isTrackingEnabled else {
                logger?.d(Self.module, "deliver", "tracking is disabled by behavior settings, the gathered lines stay held, heldLineCount: [\(heldLineCount)]")
                return
            }

            guard transport.hasAnyConsent else {
                logger?.d(Self.module, "deliver", "no consent is given, the gathered lines stay held, heldLineCount: [\(heldLineCount)]")
                return
            }

            // A flush drains the full batches first and the partial tail last, so
            // the tail is never uploaded ahead of older lines.
            while let batch = takeBatch(includePartialBatch: includePartialBatch) {
                guard let payload = serialize(batch) else {
                    // Putting an unserializable batch back would make it the head of
                    // every later delivery, so it is lost and counted.
                    logger?.w(Self.module, "deliver", "a gathered log batch could not be serialized and is dropped, lineCount: [\(batch.lines.count)]")
                    countAsDropped(batch)
                    continue
                }

                logger?.d(Self.module, "deliver", "uploading a gathered log batch, lineCount: [\(batch.lines.count)], droppedCount: [\(batch.dropped)], payloadLength: [\(payload.count)]")
                guard transport.sendSdkLogs(payload) else {
                    restore(batch)
                    return
                }
            }
        }
    }

    /// Takes up to one batch of the oldest lines, or `nil` when there is nothing
    /// to upload. The drop count travels with the batch that follows the loss and
    /// is reported once.
    private func takeBatch(includePartialBatch: Bool) -> Batch? {
        lock.lock()
        defer { lock.unlock() }

        guard state == .gathering, let gatherID = directive.gatherID, !lines.isEmpty else { return nil }
        if !includePartialBatch, lines.count < directive.batchSize { return nil }

        let count = min(directive.batchSize, lines.count)
        let taken = Array(lines.prefix(count))
        lines.removeFirst(count)
        for line in taken {
            heldChars -= line.message.countlyLength
        }
        let batch = Batch(lines: taken, dropped: droppedCount, gatherID: gatherID)
        droppedCount = 0
        return batch
    }

    /// Puts a batch the queue refused back at the front of the buffer, oldest
    /// first, drop count included. Ignored when the gather changed meanwhile.
    private func restore(_ batch: Batch) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .gathering, directive.gatherID == batch.gatherID else { return }

        lines.insert(contentsOf: batch.lines, at: 0)
        for line in batch.lines {
            heldChars += line.message.countlyLength
        }
        droppedCount += batch.dropped
        trimBufferLocked()
    }

    /// Accounts a batch that can never be sent as dropped lines, so the loss still
    /// reaches the operator with the next batch.
    private func countAsDropped(_ batch: Batch) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .gathering, directive.gatherID == batch.gatherID else { return }
        droppedCount += batch.lines.count + batch.dropped
    }

    private func serialize(_ batch: Batch) -> String? {
        let payloadLines: [[String: Any]] = batch.lines.map {
            [LineKey.timestamp: $0.timestamp, LineKey.level: $0.level, LineKey.message: $0.message]
        }
        let payload: [String: Any] = [
            BatchKey.gatherID: batch.gatherID,
            BatchKey.droppedCount: batch.dropped,
            BatchKey.lines: payloadLines,
        ]
        return CountlyJSON.string(from: payload, logger: nil)
    }

    // MARK: - Buffer maintenance, under the lock

    /// Enforces both ceilings by dropping the oldest lines and counting them.
    private func trimBufferLocked() {
        while lines.count > LogGatheringDirective.maxBufferedLines
            || (heldChars > Self.charCeiling && lines.count > 1) {
            heldChars -= lines.removeFirst().message.countlyLength
            droppedCount += 1
        }
    }

    /// Drops held lines of unwanted levels. Not counted as dropped: they were
    /// never wanted.
    private func filterBufferLocked() {
        lines.removeAll { line in
            guard let character = line.level.first, !directive.levels.contains(character) else { return false }
            heldChars -= line.message.countlyLength
            return true
        }
    }

    private func clearBufferLocked() {
        lines.removeAll()
        heldChars = 0
        droppedCount = 0
    }
}

extension CountlyLogLevel {

    /// The one character the wire protocol uses for this level.
    var gatheringLevel: Character {
        switch self {
        case .error: return "e"
        case .warning: return "w"
        case .info: return "i"
        case .debug: return "d"
        case .verbose, .none: return "v"
        }
    }
}
