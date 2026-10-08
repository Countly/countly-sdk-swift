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

/// Whose consent a gathered log line needs before it may be gathered.
///
/// Log gathering never gets a consent of its own: a consent for logging could
/// override the choices the user actually made. A line waits for the consent of
/// the feature that wrote it instead.
enum LogGatheringScope: Hashable {

    /// A line one feature wrote. Needs that feature's consent.
    case feature(ConsentFeature)

    /// A line attributed to no single feature, such as one from the request
    /// path, the stores or init, which can quote any feature's data. Needs both
    /// the events and the user details consent.
    case unattributed

    /// The scope of a line, from the module and function that wrote it.
    ///
    /// Two kinds of line are logged before the consent they belong to is
    /// checked, so they answer to that consent rather than to their module's: an
    /// events line naming a reserved event, whose key and segmentation belong to
    /// the feature owning the event, and the orientation lines of the views
    /// module, which belong to user details like the orientation event.
    static func of(module: String, function: String, message: String) -> LogGatheringScope {
        if module == ViewsModule.moduleName, function == "recordOrientation" {
            return .feature(.userDetails)
        }
        let scope = ofModule(module)
        guard scope == .feature(.events), let owner = ownerOfReservedEvent(namedIn: message) else { return scope }
        return .feature(owner)
    }

    /// The scope of the lines a log module writes.
    ///
    /// Attribution is by module because the module is the one thing the logger
    /// already holds for every line, and in this SDK a module is a feature. A
    /// module this table does not name owns no single feature, so a module added
    /// later cannot start gathering user data by being forgotten here.
    static func ofModule(_ module: String) -> LogGatheringScope {
        switch module {
        case EventsModule.moduleName: return .feature(.events)
        case ViewsModule.moduleName: return .feature(.viewTracking)
        case UserProfileModule.moduleName: return .feature(.userDetails)
        case SessionsModule.moduleName: return .feature(.sessions)
        case LocationModule.moduleName: return .feature(.location)
        // The crash log store writes the breadcrumbs it was handed.
        case CrashModule.moduleName, "CrashLogStore": return .feature(.crashReporting)
        case PushModule.moduleName, "PushRuntime": return .feature(.pushNotifications)
        case AttributionModule.moduleName: return .feature(.attribution)
        case APMModule.moduleName: return .feature(.performanceMonitoring)
        case FeedbackModule.moduleName: return .feature(.feedback)
        case RemoteConfigModule.moduleName: return .feature(.remoteConfig)
        case ContentModule.moduleName: return .feature(.content)
        case "DeviceMetrics": return .feature(.metrics)
        default: return .unattributed
        }
    }

    /// Each reserved event as its key reads in a `key: [...]` field.
    private static let reservedKeyFields = ReservedEventKey.owningFeature.map { (field: $0.key + "]", owner: $0.value) }

    /// The feature owning the reserved event a line names in its `key: [...]`
    /// field, or nil when it names none. Only that field counts, so a custom key
    /// or a segmentation value that merely contains a reserved key moves nothing.
    private static func ownerOfReservedEvent(namedIn message: String) -> ConsentFeature? {
        guard let field = message.range(of: "key: [") else { return nil }
        let named = message[field.upperBound...]
        return reservedKeyFields.first { named.hasPrefix($0.field) }?.owner
    }

    /// Whether a line of this scope may be gathered, given which features are
    /// consented to.
    func isConsented(_ hasConsent: (ConsentFeature) -> Bool) -> Bool {
        switch self {
        case .feature(let feature): return hasConsent(feature)
        case .unattributed: return hasConsent(.events) && hasConsent(.userDetails)
        }
    }
}

/// What the gatherer needs from the rest of the SDK to gather and deliver lines.
protocol LogGatheringTransport: AnyObject {
    /// Whether behavior settings allow requests to be queued at all.
    var isTrackingEnabled: Bool { get }
    /// Whether one feature is consented to, which is always true while consent
    /// is not required. Asked while a line is being captured, so it must not log.
    func hasConsent(for feature: ConsentFeature) -> Bool
    /// Queues one `sdk_logs` batch. Returns whether the queue took it.
    func sendSdkLogs(_ payload: String) -> Bool
}

/// Gathers the SDK's own log lines for one instance and uploads them as
/// `sdk_logs` batches when a live behavior settings response asks for them.
///
/// Consent is decided per line when it is captured. A line whose consent is
/// given joins the buffer; any other waits apart, never uploaded, until that
/// consent is given, and a buffered line goes back to waiting when its consent
/// is withdrawn. Lines captured before init finishes are decided when it does,
/// because the consent state is only complete then.
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

        /// Whose consent this line needs, checked when it is captured, or when
        /// init finishes for a line captured before that.
        let scope: LogGatheringScope

        /// Capture order. Released lines are put back by it, since the wall clock
        /// shares a millisecond between lines and can step backwards.
        let sequence: UInt64
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

    /// Lines whose consent is not given as things stand. Kept apart from `lines`
    /// so no batch can carry one, and moved there once it is given.
    private var awaitingConsent: [Line] = []
    private var awaitingChars = 0

    private var state: LogGatheringState = .undecided
    private var directive = LogGatheringDirective.off
    private var initFinished = false
    private var nextSequence: UInt64 = 0

    /// Lines dropped from the buffer before init decided their consent, by scope.
    private var droppedBeforeInit: [LogGatheringScope: Int] = [:]

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

    /// A copy of the lines waiting for their consent, oldest first.
    var linesAwaitingConsent: [Line] {
        lock.lock()
        defer { lock.unlock() }
        return awaitingConsent
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
    /// Off drops everything held speculatively. Gathering adopts the held lines
    /// and those awaiting consent, filtered to the requested levels, unless they
    /// belong to a different gather that was already running, in which case they
    /// are dropped because the server rejects a batch attributed to a gather that
    /// ended.
    func apply(_ directive: LogGatheringDirective, source: String) {
        let newState: LogGatheringState = directive.isGathering ? .gathering : .off

        lock.lock()
        guard state != newState || self.directive != directive else {
            let held = lines.count
            let holdsFullBatch = state == .gathering && held >= directive.batchSize
            lock.unlock()
            logger?.d(Self.module, "apply", "the log gathering directive is unchanged, source: [\(source)], heldLineCount: [\(held)]")
            // A refetch is what turns tracking back on, and a full batch held meanwhile gets no other kick.
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
        let awaiting = awaitingConsent.count
        lock.unlock()

        logger?.d(Self.module, "apply", "the log gathering directive is applied, source: [\(source)], gathering: [\(directive.isGathering)], gatherID: [\(directive.gatherID ?? "none")], levels: [\(directive.levels)], batchSize: [\(directive.batchSize)], heldLineCount: [\(held)], awaitingConsentLineCount: [\(awaiting)]")

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

    /// The request queue is usable and the consent state complete from here on,
    /// so this is the first chance for the lines gathered during init to go out.
    ///
    /// Their consent is decided here, under the lock `capture` decides in, so
    /// every line is decided either here or when it is captured. A line dropped
    /// before this counts toward `d` only if its consent turns out to be given.
    func sdkInitFinished() {
        lock.lock()
        guard !initFinished else {
            lock.unlock()
            return
        }
        initFinished = true
        redecideConsentLocked()
        droppedCount += droppedBeforeInit.reduce(0) { $0 + (isConsentGiven(for: $1.key) ? $1.value : 0) }
        droppedBeforeInit.removeAll()
        let gathering = state == .gathering
        let awaiting = awaitingConsent.count
        lock.unlock()

        if gathering {
            logger?.d(Self.module, "sdkInitFinished", "init finished while gathering, the consented lines held so far will be uploaded, awaitingConsentLineCount: [\(awaiting)]")
            scheduleDelivery(includePartialBatch: true)
        }
    }

    /// Re-decides every held line against the consent state now. Called when a
    /// consent is given or withdrawn and when whether consent is required
    /// changes: a line whose consent is given joins the buffer in the order it
    /// was logged, and a line whose consent was withdrawn goes back to waiting.
    func consentDidChange() {
        lock.lock()
        // Before init finishes nothing is decided yet, and init finishing decides every line.
        guard initFinished else {
            lock.unlock()
            return
        }
        let bufferedBefore = lines.count
        let (released, recalled) = redecideConsentLocked()
        let completesBatch = completesBatchLocked(bufferedBefore: bufferedBefore)
        let awaiting = awaitingConsent.count
        lock.unlock()

        if released > 0 || recalled > 0 {
            logger?.d(Self.module, "consentDidChange", "gathered lines are re-decided against the consent state, releasedLineCount: [\(released)], recalledLineCount: [\(recalled)], awaitingConsentLineCount: [\(awaiting)]")
        }

        if completesBatch {
            scheduleDelivery(includePartialBatch: false)
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

    /// The capture order the next line will get. A device ID change reads it
    /// before it logs anything, so the lines it logs can be told apart.
    var nextCaptureSequence: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSequence
    }

    /// Ends the gather for a device ID change without merge.
    ///
    /// The lines logged since `mark` belong to the change itself and quote the
    /// next user's ID, so they are dropped. What may be uploaded of the rest is
    /// queued now, while requests still carry the old device ID, and everything
    /// else held is dropped, so neither user's lines reach the other's gather.
    func stopForDeviceIDChange(droppingLinesFrom mark: UInt64) {
        // Held throughout, so no other delivery can queue a batch once the new device ID is in place.
        deliveryLock.lock()
        defer { deliveryLock.unlock() }

        guard isCapturing else { return }

        lock.lock()
        lines.removeAll { $0.sequence >= mark }
        heldChars = Self.charCount(of: lines)
        lock.unlock()

        if isGathering {
            deliverSerialized(includePartialBatch: true)
        }

        lock.lock()
        resetLocked(to: .off)
        lock.unlock()

        logger?.d(Self.module, "stopForDeviceIDChange", "log gathering is stopped for a device ID change without merge, the lines that could not be uploaded under the previous device ID are dropped")
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

    /// Moves to `state` with the default directive and empty lists.
    private func resetLocked(to newState: LogGatheringState) {
        state = newState
        directive = .off
        clearBufferLocked()
    }

    // MARK: - Capture

    /// Holds one line. Called by the logger for every line anything wants.
    ///
    /// A line whose consent `scope` says is given joins the buffer, and any other
    /// waits apart for it. Before init finishes every line joins the buffer and
    /// is decided in `sdkInitFinished`. `scope` is only worked out for a line
    /// that is kept.
    func capture(_ message: String, level: CountlyLogLevel, scope: @autoclosure () -> LogGatheringScope) {
        guard !isTransportWork else { return }
        guard !message.contains(Self.transportMarker) else { return }

        let levelChar = level.gatheringLevel

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
                        scope: scope(),
                        sequence: nextSequence)
        nextSequence += 1

        if initFinished, !isConsentGiven(for: line.scope) {
            awaitingConsent.append(line)
            awaitingChars += line.message.countlyLength
            trimAwaitingConsentLocked()
            lock.unlock()
            return
        }

        let bufferedBefore = lines.count
        lines.append(line)
        heldChars += line.message.countlyLength
        trimBufferLocked()
        let completesBatch = completesBatchLocked(bufferedBefore: bufferedBefore)
        lock.unlock()

        if completesBatch {
            scheduleDelivery(includePartialBatch: false)
        }
    }

    /// Whether a line of `scope` may be gathered now. No while there is no
    /// transport to ask, so a line is never gathered on a guess.
    private func isConsentGiven(for scope: LogGatheringScope) -> Bool {
        guard let transport else { return false }
        return scope.isConsented(transport.hasConsent(for:))
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

    /// Runs one delivery, serialized with every other.
    private func deliver(includePartialBatch: Bool) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        deliverSerialized(includePartialBatch: includePartialBatch)
    }

    /// Uploads one batch, then keeps going while full batches remain. Lines stay
    /// held while tracking is off, because the request queue would drop them.
    /// Called with `deliveryLock` held.
    private func deliverSerialized(includePartialBatch: Bool) {
        guard isInitFinished, let transport else { return }

        markingTransportWork(true) {
            guard transport.isTrackingEnabled else {
                logger?.d(Self.module, "deliver", "tracking is disabled by behavior settings, the gathered lines stay held, heldLineCount: [\(heldLineCount)]")
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
        // A consent withdrawn while the batch was out found nothing of it to recall.
        redecideConsentLocked()
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

    /// What these lines add up to in `heldChars`, the unit the character ceiling
    /// is measured in.
    private static func charCount(of lines: [Line]) -> Int {
        lines.reduce(0) { $0 + $1.message.countlyLength }
    }

    /// Enforces both ceilings by dropping the oldest lines and counting them.
    /// Before init a drop is only tallied, since it counts toward `d` only if its
    /// consent turns out to be given when init decides.
    private func trimBufferLocked() {
        let removed = Self.trim(&lines, chars: &heldChars)
        if initFinished {
            droppedCount += removed.count
        } else {
            for line in removed {
                droppedBeforeInit[line.scope, default: 0] += 1
            }
        }
    }

    /// Enforces both ceilings on the lines awaiting consent. Not counted as
    /// dropped: a line whose consent was never given was never gathered.
    private func trimAwaitingConsentLocked() {
        Self.trim(&awaitingConsent, chars: &awaitingChars)
    }

    /// Drops the oldest of `lines` until both ceilings hold, keeping `chars` in
    /// step, and returns what went.
    @discardableResult
    private static func trim(_ lines: inout [Line], chars: inout Int) -> [Line] {
        var removed: [Line] = []
        while lines.count > LogGatheringDirective.maxBufferedLines || (chars > charCeiling && lines.count > 1) {
            let line = lines.removeFirst()
            chars -= line.message.countlyLength
            removed.append(line)
        }
        return removed
    }

    /// Whether the lines just added brought the buffer to a full batch. Only that
    /// moment asks for a delivery, so a full buffer held back while tracking is
    /// off does not queue one delivery per line.
    private func completesBatchLocked(bufferedBefore: Int) -> Bool {
        state == .gathering && bufferedBefore < directive.batchSize && lines.count >= directive.batchSize
    }

    /// Puts every held line where the consent state puts it now: in the buffer
    /// when its consent is given, waiting otherwise, each list in the order the
    /// lines were logged. Returns how many lines moved each way.
    @discardableResult
    private func redecideConsentLocked() -> (released: Int, recalled: Int) {
        let (kept, recalled) = splitByConsentLocked(lines)
        let (released, stillAwaiting) = splitByConsentLocked(awaitingConsent)
        guard !released.isEmpty || !recalled.isEmpty else { return (0, 0) }

        lines = (kept + released).sorted { $0.sequence < $1.sequence }
        heldChars = Self.charCount(of: lines)
        awaitingConsent = (stillAwaiting + recalled).sorted { $0.sequence < $1.sequence }
        awaitingChars = Self.charCount(of: awaitingConsent)
        trimBufferLocked()
        trimAwaitingConsentLocked()
        return (released.count, recalled.count)
    }

    /// Splits `lines` by whether their consent is given now, each part keeping
    /// the order of `lines`.
    private func splitByConsentLocked(_ lines: [Line]) -> (consented: [Line], awaiting: [Line]) {
        var consented: [Line] = []
        var awaiting: [Line] = []
        for line in lines {
            if isConsentGiven(for: line.scope) {
                consented.append(line)
            } else {
                awaiting.append(line)
            }
        }
        return (consented, awaiting)
    }

    /// Drops held and awaiting lines of unwanted levels. Not counted as dropped:
    /// they were never wanted.
    private func filterBufferLocked() {
        heldChars -= Self.removeLines(notIn: directive.levels, from: &lines)
        awaitingChars -= Self.removeLines(notIn: directive.levels, from: &awaitingConsent)
    }

    /// Removes the lines whose level is not in `levels` and returns how many
    /// characters they held.
    private static func removeLines(notIn levels: String, from lines: inout [Line]) -> Int {
        var removedChars = 0
        lines.removeAll { line in
            guard let character = line.level.first, !levels.contains(character) else { return false }
            removedChars += line.message.countlyLength
            return true
        }
        return removedChars
    }

    /// Drops every line, those awaiting consent included, and the drop count.
    private func clearBufferLocked() {
        lines.removeAll()
        heldChars = 0
        droppedCount = 0
        droppedBeforeInit.removeAll()
        awaitingConsent.removeAll()
        awaitingChars = 0
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
