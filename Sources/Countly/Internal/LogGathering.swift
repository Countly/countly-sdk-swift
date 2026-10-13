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
    /// Whether a gathered batch still waits in the request queue.
    var hasQueuedSdkLogs: Bool { get }
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

    /// Held characters that ask for a delivery before a batch is full, so long
    /// lines go out instead of being trimmed at the ceiling first.
    static let deliveryCharThreshold = charCeiling * 3 / 4

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

    /// The scope and level of a line dropped before both were decided on.
    private struct DropKey: Hashable {
        let scope: LogGatheringScope
        let level: String
    }

    /// What became of a batch handed to the request queue.
    private enum UploadOutcome {
        case queued
        case refused
        case unserializable
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

    /// Lines dropped before init decided their consent or a directive decided the
    /// wanted levels. Only the consented, wanted ones count toward `d`.
    private var undecidedDrops: [DropKey: Int] = [:]

    /// Whether a delivery left lines behind for a batch still in the request queue,
    /// so the next one runs once that batch is sent.
    private var awaitsQueuedBatch = false

    /// Lines captured before this were held when a flush found a batch still in
    /// the request queue. The deliveries that follow take a partial batch only
    /// while one of them is left, so the lines logged meanwhile, sending
    /// included, cannot keep the chain going.
    private var flushThroughSequence: UInt64?

    /// Where the lines of a device ID change in progress begin.
    private var deviceIDChangeMark: UInt64?

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
    /// Off drops everything held speculatively, and a running gather's consented
    /// lines go out once as its last batch, which the server still accepts under
    /// that gather's id for a while. Gathering adopts the held lines and those
    /// awaiting consent, filtered to the requested levels, unless they belong to a
    /// different gather that was already running, in which case they are dropped
    /// because re-arming deletes the previous gather on the server.
    func apply(_ directive: LogGatheringDirective, source: String) {
        let newState: LogGatheringState = directive.isGathering ? .gathering : .off

        lock.lock()
        guard state != newState || self.directive != directive else {
            let held = lines.count
            let holdsFullBatch = state == .gathering && held >= directive.batchSize
            lock.unlock()
            logger?.d(Self.module, "apply", "the log gathering directive is unchanged, source: [\(source)], heldLineCount: [\(held)]")
            // A refetch is what turns tracking back on, and a full batch held meanwhile gets no other kick.
            if holdsFullBatch {
                scheduleDelivery(includePartialBatch: false)
            }
            return
        }

        let wasGathering = state == .gathering
        let previousGatherID = self.directive.gatherID
        state = newState
        self.directive = directive

        var tail: Batch?
        let gatherReplaced = wasGathering && previousGatherID != directive.gatherID
        if newState == .off, wasGathering, let previousGatherID, initFinished {
            // The server accepts the last lines of a stopped gather under its id for a while; a new gather deletes the old one's.
            tail = takeTailLocked(gatherID: previousGatherID)
        }
        if newState == .off || gatherReplaced {
            clearBufferLocked()
        } else {
            filterBufferLocked()
            adoptUndecidedDropsLocked()
            trimBufferLocked()
        }
        let held = lines.count
        let awaiting = awaitingConsent.count
        lock.unlock()

        logger?.d(Self.module, "apply", "the log gathering directive is applied, source: [\(source)], gathering: [\(directive.isGathering)], gatherID: [\(directive.gatherID ?? "none")], levels: [\(directive.levels)], batchSize: [\(directive.batchSize)], heldLineCount: [\(held)], awaitingConsentLineCount: [\(awaiting)], tailLineCount: [\(tail?.lines.count ?? 0)]")

        if let tail {
            deliverTail(tail)
        }

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
        undecidedDrops = undecidedDrops.filter { isConsentGiven(for: $0.key.scope) }
        if state == .gathering {
            adoptUndecidedDropsLocked()
        }
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
        let charsBefore = heldChars
        let (released, recalled) = redecideConsentLocked()
        let due = deliveryDueLocked(bufferedBefore: bufferedBefore, charsBefore: charsBefore)
        let awaiting = awaitingConsent.count
        lock.unlock()

        if released > 0 || recalled > 0 {
            logger?.d(Self.module, "consentDidChange", "gathered lines are re-decided against the consent state, releasedLineCount: [\(released)], recalledLineCount: [\(recalled)], awaitingConsentLineCount: [\(awaiting)]")
        }

        if due.isDue {
            scheduleDelivery(includePartialBatch: due.includePartialBatch)
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
    ///
    /// - Parameter ignoringQueuedBatch: queues everything held even while a batch
    ///   still waits in the request queue, for termination, after which nothing
    ///   else could.
    func flushNow(ignoringQueuedBatch: Bool = false) {
        guard isGathering else { return }
        deliver(includePartialBatch: true, ignoringQueuedBatch: ignoringQueuedBatch)
    }

    /// Called once a gathered batch has left the request queue. Runs the delivery
    /// that batch held back. A partial batch goes too while lines a flush asked
    /// for are left, since nothing else sends them while the app is in the
    /// background.
    func queuedBatchWasSent() {
        lock.lock()
        let awaited = awaitsQueuedBatch
        awaitsQueuedBatch = false
        lock.unlock()

        guard awaited else { return }
        scheduleDelivery(includePartialBatch: false, continuingFlush: true)
    }

    /// Marks the start of a device ID change, before it logs anything. Until it
    /// ends, no delivery takes a line it logs, since that line may quote the next
    /// user's ID.
    func deviceIDChangeBegins() {
        lock.lock()
        deviceIDChangeMark = nextSequence
        lock.unlock()
    }

    /// Marks the end of a device ID change. A change that kept the gather leaves
    /// its lines to be delivered like any other, and a full batch held meanwhile
    /// goes out now.
    func deviceIDChangeEnds() {
        lock.lock()
        deviceIDChangeMark = nil
        let holdsFullBatch = state == .gathering && lines.count >= directive.batchSize
        lock.unlock()

        if holdsFullBatch {
            scheduleDelivery(includePartialBatch: false)
        }
    }

    /// Ends the gather for a device ID change without merge, from inside the
    /// change.
    ///
    /// What may be uploaded of the lines logged before the change is queued now,
    /// while requests still carry the old device ID; the change's own lines, which
    /// quote the next user's ID, are never taken. Everything else held is then
    /// dropped, so neither user's lines reach the other's gather.
    func stopForDeviceIDChange() {
        // Held throughout, so no other delivery can queue a batch once the new device ID is in place.
        deliveryLock.lock()
        defer { deliveryLock.unlock() }

        guard isCapturing else { return }

        if isGathering {
            deliverSerialized(includePartialBatch: true, ignoringQueuedBatch: true)
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
        let charsBefore = heldChars
        lines.append(line)
        heldChars += line.message.countlyLength
        trimBufferLocked()
        let due = deliveryDueLocked(bufferedBefore: bufferedBefore, charsBefore: charsBefore)
        lock.unlock()

        if due.isDue {
            scheduleDelivery(includePartialBatch: due.includePartialBatch)
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

    private func scheduleDelivery(includePartialBatch: Bool, continuingFlush: Bool = false) {
        // The request queue is not usable before init finishes; the tail goes out
        // from `sdkInitFinished`.
        guard isInitFinished else { return }

        deliveryQueue.async { [weak self] in
            self?.deliver(includePartialBatch: includePartialBatch, continuingFlush: continuingFlush)
        }
    }

    /// Runs one delivery, serialized with every other.
    private func deliver(includePartialBatch: Bool, ignoringQueuedBatch: Bool = false, continuingFlush: Bool = false) {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        deliverSerialized(includePartialBatch: includePartialBatch,
                          ignoringQueuedBatch: ignoringQueuedBatch,
                          continuingFlush: continuingFlush)
    }

    /// Uploads what is due, one batch at a time. While an earlier batch still waits
    /// in the request queue nothing is uploaded and the next delivery runs once it
    /// is sent, so a device that cannot send fills the capped buffer rather than
    /// the queue. Lines stay held while tracking is off, because the request
    /// queue would drop them. Called with `deliveryLock` held.
    ///
    /// - Parameters:
    ///   - ignoringQueuedBatch: uploads everything held, oldest first, for the
    ///     paths after which nothing else could: a device ID change and
    ///     termination.
    ///   - continuingFlush: takes a partial batch while lines an earlier flush
    ///     asked for are left, for the delivery a sent batch releases.
    private func deliverSerialized(includePartialBatch: Bool, ignoringQueuedBatch: Bool = false, continuingFlush: Bool = false) {
        guard isInitFinished, let transport else { return }
        // A flush asks for what is held now; what is logged while it runs waits for the next one.
        let flushThrough = includePartialBatch ? currentSequence : nil

        markingTransportWork(true) {
            guard transport.isTrackingEnabled else {
                logger?.d(Self.module, "deliver", "tracking is disabled by behavior settings, the gathered lines stay held, heldLineCount: [\(heldLineCount)]")
                return
            }

            // Full batches go first and the partial tail last, so the tail is never uploaded ahead of older lines.
            while true {
                if !ignoringQueuedBatch, transport.hasQueuedSdkLogs {
                    let hasMore = holdForQueuedBatch(flushThrough: flushThrough)
                    if hasMore {
                        logger?.d(Self.module, "deliver", "a gathered log batch still waits in the request queue, the next one goes out once it is sent, heldLineCount: [\(heldLineCount)]")
                    }
                    return
                }

                guard let batch = takeBatch(includePartialBatch: includePartialBatch, continuingFlush: continuingFlush) else {
                    setAwaitsQueuedBatch(false)
                    return
                }

                switch upload(batch, through: transport) {
                case .unserializable, .queued:
                    continue
                case .refused:
                    return
                }
            }
        }
    }

    /// Hands one batch to the request queue, putting it back if the queue refuses
    /// it. A batch that cannot be serialized is counted as dropped instead: put
    /// back, it would head every later delivery.
    private func upload(_ batch: Batch, through transport: LogGatheringTransport) -> UploadOutcome {
        guard let payload = serialize(batch) else {
            logger?.w(Self.module, "deliver", "a gathered log batch could not be serialized and is dropped, lineCount: [\(batch.lines.count)]")
            countAsDropped(batch)
            return .unserializable
        }

        logger?.d(Self.module, "deliver", "uploading a gathered log batch, lineCount: [\(batch.lines.count)], droppedCount: [\(batch.dropped)], payloadLength: [\(payload.count)]")
        guard transport.sendSdkLogs(payload) else {
            restore(batch)
            return .refused
        }
        return .queued
    }

    /// Queues the last lines of a stopped gather once, under its id, after any
    /// delivery already running. They are gone if the queue refuses them, since
    /// their gather has ended.
    private func deliverTail(_ tail: Batch) {
        deliveryQueue.async { [weak self] in
            guard let self, let transport = self.transport else { return }
            self.deliveryLock.lock()
            defer { self.deliveryLock.unlock() }

            self.markingTransportWork(true) {
                guard let payload = self.serialize(tail) else {
                    self.logger?.d(Self.module, "deliverTail", "the last lines of the stopped gather could not be serialized and are dropped, lineCount: [\(tail.lines.count)]")
                    return
                }
                self.logger?.d(Self.module, "deliverTail", "uploading the last lines of the stopped gather under its id, lineCount: [\(tail.lines.count)], droppedCount: [\(tail.dropped)]")
                if !transport.sendSdkLogs(payload) {
                    self.logger?.d(Self.module, "deliverTail", "the request queue refused the last lines of the stopped gather, they are dropped, lineCount: [\(tail.lines.count)]")
                }
            }
        }
    }

    /// The sequence the next captured line gets.
    private var currentSequence: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextSequence
    }

    /// With a batch still in the request queue, arranges for the next delivery
    /// to run once it is sent, and returns whether anything is left for that
    /// delivery: a full batch, or a line held when a flush asked for everything.
    ///
    /// - Parameter flushThrough: the sequence a flush held back here was asked
    ///   to send up to, `nil` for a delivery of full batches.
    private func holdForQueuedBatch(flushThrough: UInt64?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .gathering else {
            awaitsQueuedBatch = false
            return false
        }
        if let flushThrough {
            flushThroughSequence = max(flushThroughSequence ?? 0, flushThrough)
        }
        awaitsQueuedBatch = deliverableCountLocked() >= directive.batchSize || holdsFlushRemainderLocked()
        return awaitsQueuedBatch
    }

    /// Whether a line an earlier flush asked for is still deliverable, forgetting
    /// that flush once none is.
    private func holdsFlushRemainderLocked() -> Bool {
        guard let flushThrough = flushThroughSequence else { return false }
        if deliverableCountLocked() > 0, let oldest = lines.first, oldest.sequence < flushThrough {
            return true
        }
        flushThroughSequence = nil
        return false
    }

    /// Records whether a delivery waits for the batch in the request queue to be sent.
    private func setAwaitsQueuedBatch(_ awaits: Bool) {
        lock.lock()
        awaitsQueuedBatch = awaits
        lock.unlock()
    }

    /// Takes up to one batch of the oldest lines, or `nil` when there is nothing
    /// to upload. The drop count travels with the batch that follows the loss and
    /// is reported once.
    ///
    /// - Parameter continuingFlush: takes a partial batch too while lines an
    ///   earlier flush asked for are left.
    private func takeBatch(includePartialBatch: Bool, continuingFlush: Bool = false) -> Batch? {
        lock.lock()
        defer { lock.unlock() }

        guard state == .gathering, let gatherID = directive.gatherID else { return nil }
        // A consent withdrawn since these lines were buffered takes them back out before they can leave.
        redecideConsentLocked()
        let available = deliverableCountLocked()
        guard available > 0 else { return nil }
        let mayTakePartial = includePartialBatch || (continuingFlush && holdsFlushRemainderLocked())
        if !mayTakePartial, available < directive.batchSize { return nil }

        let count = min(directive.batchSize, available)
        let taken = Array(lines.prefix(count))
        lines.removeFirst(count)
        heldChars -= Self.charCount(of: taken)
        let batch = Batch(lines: taken, dropped: droppedCount, gatherID: gatherID)
        droppedCount = 0
        return batch
    }

    /// How many of the oldest held lines a delivery may take. Lines are held in
    /// capture order, so those of a device ID change in progress are the tail.
    private func deliverableCountLocked() -> Int {
        deviceIDChangeMark.flatMap { mark in lines.firstIndex { $0.sequence >= mark } } ?? lines.count
    }

    /// Takes every held line as the last batch of a gather, its consent decided
    /// first, or `nil` when none is left.
    private func takeTailLocked(gatherID: String) -> Batch? {
        redecideConsentLocked()
        guard !lines.isEmpty else { return nil }
        let batch = Batch(lines: lines, dropped: droppedCount, gatherID: gatherID)
        lines.removeAll()
        heldChars = 0
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
    /// Until init has decided their consent and a directive the wanted levels, a
    /// drop is only tallied by scope and level, since it counts toward `d` only
    /// for a consented scope and a wanted level.
    private func trimBufferLocked() {
        let removed = Self.trim(&lines, chars: &heldChars)
        if initFinished, state == .gathering {
            droppedCount += removed.count
        } else {
            for line in removed {
                undecidedDrops[DropKey(scope: line.scope, level: line.level), default: 0] += 1
            }
        }
    }

    /// Counts the tallied drops of the wanted levels toward `d` once init has
    /// decided their consent, or before it keeps only those levels for init.
    private func adoptUndecidedDropsLocked() {
        let wanted = undecidedDrops.filter { directive.levels.contains($0.key.level) }
        guard initFinished else {
            undecidedDrops = wanted
            return
        }
        droppedCount += wanted.values.reduce(0, +)
        undecidedDrops.removeAll()
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

    /// Whether the lines just added brought the buffer to a full batch, or its
    /// characters past the delivery threshold, which a long line reaches long
    /// before the batch size. Only that moment asks for a delivery, so a full
    /// buffer held back while tracking is off does not queue one delivery per line.
    private func deliveryDueLocked(bufferedBefore: Int, charsBefore: Int) -> (isDue: Bool, includePartialBatch: Bool) {
        guard state == .gathering else { return (false, false) }
        let completesBatch = bufferedBefore < directive.batchSize && lines.count >= directive.batchSize
        let reachesCharThreshold = charsBefore < Self.deliveryCharThreshold && heldChars >= Self.deliveryCharThreshold
        return (completesBatch || reachesCharThreshold, reachesCharThreshold)
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
        undecidedDrops.removeAll()
        awaitingConsent.removeAll()
        awaitingChars = 0
        awaitsQueuedBatch = false
        flushThroughSequence = nil
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
