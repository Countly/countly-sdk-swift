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

/// What the user data in a gathered log line belongs to, and so whose consent
/// the line needs before it may leave the device.
///
/// Log gathering never gets a consent of its own: a consent for logging could
/// override the choices the user actually made. A line goes out under the
/// consent of whatever it quotes instead, and a line that quotes nothing of the
/// user's goes out as it is.
enum LogGatheringScope: Equatable {

    /// The SDK's own working: state, storage, networking, timing. Always uploaded.
    case sdk

    /// Data of one feature. Uploaded as logged only with that feature's consent.
    case feature(ConsentFeature)

    /// A line from a cross cutting helper, which can quote any feature's data and
    /// cannot say which. Uploaded as logged only when every feature is consented
    /// to.
    case anyFeature

    /// The scope of the lines a log module writes.
    ///
    /// Attribution is by module because the module is the one thing the logger
    /// already holds for every line, and in this SDK a module is a feature. A
    /// name this table does not know is cross cutting rather than the SDK's own
    /// working, so a module added later cannot start uploading user data by being
    /// forgotten here.
    static func ofModule(_ module: String) -> LogGatheringScope {
        switch module {
        case "Events": return .feature(.events)
        case "Views": return .feature(.viewTracking)
        case "UserProfile": return .feature(.userDetails)
        case "Sessions": return .feature(.sessions)
        case "Location": return .feature(.location)
        // The crash log store writes the breadcrumbs it was handed.
        case "Crash", "CrashLogStore": return .feature(.crashReporting)
        case "Push", "PushRuntime": return .feature(.pushNotifications)
        case "Attribution": return .feature(.attribution)
        case "APM": return .feature(.performanceMonitoring)
        case "Feedback": return .feature(.feedback)
        case "RemoteConfig": return .feature(.remoteConfig)
        case "Content": return .feature(.content)
        case "DeviceMetrics": return .feature(.metrics)

        // The limit checks quote whatever key or value they truncated, which
        // belongs to whichever feature happened to call them.
        case "Limits": return .anyFeature

        // The request path reports lengths, endpoints and counts rather than
        // bodies, and the few lines that do quote a whole request say so at the
        // call site. Health check and server config traffic is the SDK's own.
        case "Countly", "Consent", "DeviceID", "ConnectionTest", "ConnectionManager",
             "RequestBuilder", "RequestQueue", "KeyValueStore", "Storage", "ServerConfig",
             "HealthTracker", "Lifecycle", "WebView", "LogGathering", "Utils":
            return .sdk

        default: return .anyFeature
        }
    }
}

/// What the gatherer needs from the rest of the SDK to deliver a batch.
protocol LogGatheringTransport: AnyObject {
    /// Whether behavior settings allow requests to be queued at all.
    var isTrackingEnabled: Bool { get }
    /// Whether any consent is given. Nothing is uploaded, not even a redacted
    /// line, while this is false.
    var hasAnyConsent: Bool { get }
    /// Whether one feature is consented to, which decides whether a line carrying
    /// that feature's user data goes out as logged or redacted.
    func hasConsent(for feature: ConsentFeature) -> Bool
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

    /// What replaces the body of a line whose feature is not consented to.
    ///
    /// Worded as a consent state rather than as a loss, because that is what an
    /// operator reading the batch has to act on.
    static func redactionNotice(_ missing: ConsentFeature) -> String {
        "no consent for [\(missing.wireName)], the rest of this line is redacted"
    }

    /// One gathered line, already truncated.
    struct Line: Equatable {
        let timestamp: Int64
        let level: String
        let message: String

        /// Whose consent this line needs before it may go out as logged.
        let scope: LogGatheringScope

        /// How many characters at the front of `message` are the
        /// `[module] function, ` header. Redaction keeps them and drops the rest,
        /// which is the only part that can quote the user's own data. Held as a
        /// length rather than a copy of the header, so the buffer still holds
        /// every character of a line exactly once.
        let headerLength: Int

        /// The feature whose consent this line lacks, or nil when it may go out
        /// as logged.
        func missingConsent(in granted: Set<ConsentFeature>) -> ConsentFeature? {
            switch scope {
            case .sdk:
                return nil
            case .feature(let feature):
                return granted.contains(feature) ? nil : feature
            case .anyFeature:
                return ConsentFeature.allCases.first { !granted.contains($0) }
            }
        }

        /// The message this line is uploaded with: as logged when its feature is
        /// consented to, and the header plus a notice otherwise.
        ///
        /// The header is kept because the call a method was made from is what
        /// makes a gathered log readable, and it names only the SDK's own modules
        /// and functions.
        func uploadMessage(in granted: Set<ConsentFeature>) -> String {
            guard let missing = missingConsent(in: granted) else { return message }
            return String(message.prefix(headerLength)) + LogGatherer.redactionNotice(missing)
        }
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

    var currentState: LogGatheringState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Whether lines still have to be held: undecided or gathering. This is what
    /// makes the logger format a line while console logging is off.
    var isCapturing: Bool { currentState != .off }

    var isGathering: Bool { currentState == .gathering }

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

    /// Whether the request queue is usable yet. Nothing is delivered before it is.
    private var isInitFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return initFinished
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

        let gatherReplaced = wasGathering && previousGatherID != directive.gatherID
        if newState == .off || gatherReplaced {
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
    ///
    /// `scope` and `headerLength` are what the consent check at delivery works
    /// from. They are taken here rather than resolved later because the module
    /// a line came from is known only while it is being logged.
    func capture(_ message: String, level: CountlyLogLevel, scope: LogGatheringScope, headerLength: Int) {
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
                        message: message.countlyPrefix(Self.maxMessageLength),
                        scope: scope,
                        headerLength: headerLength)
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
        // The request queue is not usable before init finishes; the tail goes out
        // from `sdkInitFinished`.
        guard isInitFinished else { return }

        deliveryQueue.async { [weak self] in
            self?.deliver(includePartialBatch: includePartialBatch)
        }
    }

    /// Uploads one batch, then keeps going while full batches remain. Lines stay
    /// held while the request queue would drop them: tracking off, or no consent
    /// given yet.
    private func deliver(includePartialBatch: Bool) {
        guard isInitFinished, let transport else { return }

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

            // Read once for the whole delivery: consent granted halfway through
            // would otherwise redact some lines of a feature and not others, and
            // the batch would be read as if the user had changed their mind
            // mid-line.
            let granted = Set(ConsentFeature.allCases.filter { transport.hasConsent(for: $0) })

            // A flush drains the full batches first and the partial tail last, so
            // the tail is never uploaded ahead of older lines.
            while let batch = takeBatch(includePartialBatch: includePartialBatch) {
                guard let payload = serialize(batch, granted: granted) else {
                    // Putting an unserializable batch back would make it the head of
                    // every later delivery, so it is lost and counted.
                    logger?.w(Self.module, "deliver", "a gathered log batch could not be serialized and is dropped, lineCount: [\(batch.lines.count)]")
                    countAsDropped(batch)
                    continue
                }

                let redactedCount = batch.lines.filter { $0.missingConsent(in: granted) != nil }.count
                logger?.d(Self.module, "deliver", "uploading a gathered log batch, lineCount: [\(batch.lines.count)], redactedLineCount: [\(redactedCount)], droppedCount: [\(batch.dropped)], payloadLength: [\(payload.count)]")
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
        heldChars -= Self.charCount(of: taken)
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
        heldChars += Self.charCount(of: batch.lines)
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

    /// Builds the wire payload of a batch, redacting every line whose feature is
    /// not in `granted`. The held lines keep what they were logged with, so a
    /// batch the queue refuses can go out whole once consent arrives.
    private func serialize(_ batch: Batch, granted: Set<ConsentFeature>) -> String? {
        let payloadLines: [[String: Any]] = batch.lines.map { line in
            [LineKey.timestamp: line.timestamp,
             LineKey.level: line.level,
             LineKey.message: line.uploadMessage(in: granted)]
        }
        let payload: [String: Any] = [
            BatchKey.gatherID: batch.gatherID,
            BatchKey.droppedCount: batch.dropped,
            BatchKey.lines: payloadLines,
        ]
        return CountlyJSON.string(from: payload, logger: nil)
    }

    // MARK: - Buffer maintenance, under the lock

    /// What these lines add up to in `heldChars`, the unit the character ceiling
    /// is measured in.
    private static func charCount(of lines: [Line]) -> Int {
        lines.reduce(0) { $0 + $1.message.countlyLength }
    }

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
