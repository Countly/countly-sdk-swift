//
//  HealthTracker.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// The feature areas whose method calls the health check counts.
enum HealthArea: String, CaseIterable {
    case sessions
    case events
    case views
    case crashes

    /// The consent the counts of this area follow.
    var consent: ConsentFeature {
        switch self {
        case .sessions: return .sessions
        case .events: return .events
        case .views: return .viewTracking
        case .crashes: return .crashReporting
        }
    }
}

/// The log codes the health check reports, with the meaning every Countly SDK
/// gives them.
enum HealthLogCode {
    static let calledBeforeInit = "w101"
    static let invalidServerURL = "e102"
    static let invalidAppKey = "e103"
    static let startedAgain = "w110"
    static let invalidSetting = "w121"
    static let keyCut = "w201"
    static let valueCut = "w202"
    static let entriesDropped = "w203"
    static let stackTraceCut = "w205"
    static let unsupportedValueRemoved = "w206"
    static let queueFull = "w310"
    static let backoffStarted = "w320"
    static let backoffContinued = "w321"
    static let requestTooOld = "w330"
    static let invalidConsentName = "w402"
    static let storageFailed = "e501"
    static let storedStateReset = "e503"
    static let trackingDisabled = "w505"
    static let invalidDeviceID = "w601"
    static let invalidValue = "w700"
    static let emptyEventKey = "w701"
    static let emptyViewName = "w710"
    static let eventNotRunning = "w720"
    static let cancelledEventNotRunning = "w721"
    static let eventAlreadyRunning = "w722"
    static let viewNotFound = "w730"
    static let viewPauseMismatch = "w731"
    static let automaticTrackingActive = "w740"
    static let eventValueIgnored = "w750"
    static let sessionOutOfOrder = "w760"
}

/// Counts how badly the SDK is behaving and reports it once per launch.
///
/// The counters are wire data, not diagnostics: they become the `hc` payload of
/// an instant request sent shortly after init. That is why `logError` and
/// `logWarning` are called from the logger even when logging is switched off, and
/// why raising a log line from debug to warning is a telemetry change rather than
/// a cosmetic one.
///
/// Nothing on this class may log at error or warning level. Those two levels call
/// straight back into `logError` / `logWarning`, which would repopulate the very
/// counters a clear is discarding, and re-enter the serial queue that owns them.
final class HealthTracker {

    private static let module = "HealthTracker"

    /// Keys of the persisted counter state.
    private enum StateKey {
        static let logError = "LErr"
        static let logWarning = "LWar"
        static let statusCode = "RStatC"
        static let errorMessage = "REMsg"
        static let backoffRequest = "BReq"
        static let consecutiveBackoffRequest = "CBReq"
        static let methodUsage = "MU"
        static let logCodes = "LC"
    }

    /// Keys of the `hc` request payload.
    private enum RequestKey {
        static let errorCount = "el"
        static let warningCount = "wl"
        static let statusCode = "sc"
        static let requestError = "em"
        static let backoffRequest = "bom"
        static let consecutiveBackoffRequest = "cbom"
        static let methodUsage = "fu"
        static let logCodes = "lc"
    }

    /// Longest error message retained, so one huge server error cannot bloat
    /// every subsequent health check.
    private static let maxErrorMessageLength = 1000

    /// A method usage or log code count stops growing here until it is reported.
    static let maxCount = 65535

    /// Serial queue owning every counter. All mutation hops onto it.
    private let queue = DispatchQueue(label: "ly.count.healthtracker.queue")

    private let store: KeyValueStore
    private weak var logger: Logger?

    /// Set once the instance is composed. Weak so the tracker never keeps an
    /// instance alive.
    weak var transport: HealthCheckTransport?

    /// Answers whether a feature has consent, so method usage and the log codes of
    /// a feature area follow that consent. Set once the modules exist.
    var consentChecker: ((ConsentFeature) -> Bool)?

    private var countLogWarning: Int = 0
    private var countLogError: Int = 0
    private var countBackoffRequest: Int = 0
    private var countConsecutiveBackoffRequest: Int = 0
    private var consecutiveBackoffRequest: Int = 0
    private var statusCode: Int = -1
    private var errorMessage: String = ""
    private var methodUsage: [String: [String: Int]] = [:]
    private var logCodes: [String: Int] = [:]

    /// Set while an automatically detected crash is being reported, when calling
    /// into this class could deadlock the dying process.
    private var isRecordingStopped = false

    /// Turned off by `CountlyConfig.disableHealthCheck`. The counters still
    /// accumulate, but no report is sent.
    var healthCheckEnabled: Bool = true

    /// One health check per launch. Set once the server accepts it.
    private var healthCheckSent: Bool = false

    init(store: KeyValueStore, logger: Logger?) {
        self.store = store
        self.logger = logger
        restore()
    }

    // MARK: - Counters

    func logWarning() {
        queue.async { self.countLogWarning += 1 }
    }

    func logError() {
        queue.async { self.countLogError += 1 }
    }

    /// Records the last failed network response. Only sensible status codes are
    /// kept, so a transport level failure does not overwrite a real server error.
    func logFailedNetworkRequest(statusCode: Int, errorResponse: String?) {
        guard statusCode > 0, statusCode < 1000 else {
            logger?.d(Self.module, "logFailedNetworkRequest", "the failed network request is not recorded, it carries no server status, statusCode: [\(statusCode)]")
            return
        }

        let message = String((errorResponse ?? "").prefix(Self.maxErrorMessageLength))
        queue.async {
            self.statusCode = statusCode
            self.errorMessage = message
            self.logger?.d(Self.module, "logFailedNetworkRequest", "recorded failed network request, statusCode: [\(statusCode)], storedErrorMessageLength: [\(message.count)]")
        }
    }

    /// Records one backoff pause. The run of backoffs it belongs to grows, and
    /// `cbom` is raised to it at once, so nothing has to end the run to keep the
    /// longest one up to date.
    func logBackoffRequest() {
        queue.async {
            let runBefore = self.countConsecutiveBackoffRequest
            self.countBackoffRequest += 1
            self.countConsecutiveBackoffRequest += 1
            self.consecutiveBackoffRequest = max(self.consecutiveBackoffRequest, self.countConsecutiveBackoffRequest)
            self.incrementLogCodeLocked(HealthLogCode.backoffStarted)
            if runBefore > 0 {
                self.incrementLogCodeLocked(HealthLogCode.backoffContinued)
            }
            self.logger?.d(Self.module, "logBackoffRequest", "recorded a backoff, backoffCount: [\(self.countBackoffRequest)], currentRun: [\(self.countConsecutiveBackoffRequest)], longestRun: [\(self.consecutiveBackoffRequest)]")
        }
    }

    /// Ends the current run of backoffs, after a request was answered in time.
    func logConsecutiveBackoffRequest() {
        queue.async { self.countConsecutiveBackoffRequest = 0 }
    }

    /// Counts one call of a method of a feature area.
    ///
    /// - Parameters:
    ///   - automatic: whether the SDK made the call by itself, which the server
    ///     reads from the ":a" modifier.
    func recordUsage(_ area: HealthArea, _ method: String, automatic: Bool = false) {
        guard !isRecordingStopped, !method.isEmpty else { return }
        guard consentChecker?(area.consent) ?? true else { return }

        let name = automatic ? method + ":a" : method
        queue.async {
            var methods = self.methodUsage[area.rawValue] ?? [:]
            methods[name] = min(Self.maxCount, (methods[name] ?? 0) + 1)
            self.methodUsage[area.rawValue] = methods
        }
    }

    /// Counts occurrences of a known problem.
    ///
    /// - Parameters:
    ///   - area: the feature area of the public method that ran into it, whose
    ///     consent the count then follows.
    ///   - count: how many times it occurred, for example the number of requests
    ///     one trim of the queue dropped.
    func recordLogCode(_ code: String, area: HealthArea? = nil, count: Int = 1) {
        guard !isRecordingStopped, !code.isEmpty, count > 0 else { return }
        if let area, !(consentChecker?(area.consent) ?? true) { return }

        queue.async { self.incrementLogCodeLocked(code, by: count) }
    }

    /// Must be called on `queue`.
    private func incrementLogCodeLocked(_ code: String, by count: Int = 1) {
        logCodes[code] = min(Self.maxCount, (logCodes[code] ?? 0) + count)
    }

    /// The method usage and log code counts not reported yet, read after every
    /// count queued before this call. Must not be called on `queue`.
    var pendingCounts: (methodUsage: [String: [String: Int]], logCodes: [String: Int]) {
        queue.sync { (methodUsage, logCodes) }
    }

    /// Adds counts made before this tracker existed, such as calls to an instance
    /// that was not started yet.
    func absorb(_ pending: PendingHealthCounts.Counts) {
        guard pending.warnings > 0 || pending.errors > 0 || !pending.logCodes.isEmpty else { return }
        queue.async {
            self.countLogWarning += pending.warnings
            self.countLogError += pending.errors
            for (code, count) in pending.logCodes {
                self.logCodes[code] = min(Self.maxCount, (self.logCodes[code] ?? 0) + count)
            }
        }
    }

    /// Adds automatically detected crashes the previous run reported, which were
    /// counted outside this class because they happen inside a crash handler.
    func addAutomaticCrashes(_ count: Int) {
        guard count > 0 else { return }
        queue.async {
            var methods = self.methodUsage[HealthArea.crashes.rawValue] ?? [:]
            methods["record:a"] = min(Self.maxCount, (methods["record:a"] ?? 0) + count)
            self.methodUsage[HealthArea.crashes.rawValue] = methods
        }
    }

    /// Stops method usage and log codes while an automatically detected crash is
    /// reported, since the crash handler must not reach this class.
    func stopRecordingForCrash() {
        isRecordingStopped = true
    }

    /// Lifts ``stopRecordingForCrash()`` when crash reporting starts again or the
    /// instance is halted.
    func resumeRecording() {
        isRecordingStopped = false
    }

    // MARK: - Persistence

    /// Persists the counters so a launch that never got to send a health check
    /// still contributes its numbers to the next one. The current backoff run
    /// keeps going: `cbom` already holds the longest one.
    func saveState() {
        queue.async { self.persistStateLocked() }
    }

    /// Persists the counters before returning, for the moment the process quits
    /// and an asynchronous save might never run. Not to be called on `queue`.
    func saveStateSync() {
        queue.sync { self.persistStateLocked() }
    }

    /// Must be called on `queue`.
    private func persistStateLocked() {
        store.healthCheckState = stateLocked()
        logger?.d(Self.module, "saveState", "counters persisted, errorCount: [\(countLogError)], warningCount: [\(countLogWarning)], statusCode: [\(statusCode)], backoffCount: [\(countBackoffRequest)], longestBackoffRun: [\(consecutiveBackoffRequest)], methodUsageAreaCount: [\(methodUsage.count)], logCodeCount: [\(logCodes.count)]")
    }

    /// Must be called on `queue`.
    private func stateLocked() -> [String: Any] {
        [
            StateKey.logWarning: countLogWarning,
            StateKey.logError: countLogError,
            StateKey.statusCode: statusCode,
            StateKey.errorMessage: errorMessage,
            StateKey.backoffRequest: countBackoffRequest,
            StateKey.consecutiveBackoffRequest: consecutiveBackoffRequest,
            StateKey.methodUsage: methodUsage,
            StateKey.logCodes: logCodes,
        ]
    }

    /// Zeroes the counters and persists the empty state.
    func clearAndSave() {
        queue.async {
            self.clearValuesLocked()
            self.store.healthCheckState = [:]
            self.logger?.d(Self.module, "clearAndSave", "counters cleared and empty state persisted")
        }
    }

    /// Full reset, including the once-per-launch guard.
    func reset() {
        queue.async {
            self.clearValuesLocked()
            self.healthCheckSent = false
            self.healthCheckEnabled = true
            self.store.healthCheckState = [:]
            self.logger?.d(Self.module, "reset", "health tracker reset, healthCheckSent and healthCheckEnabled restored to their initial values")
        }
    }

    private func clearValuesLocked() {
        logger?.d(Self.module, "clearValues", "clearing counters, discardedErrorCount: [\(countLogError)], discardedWarningCount: [\(countLogWarning)], discardedBackoffCount: [\(countBackoffRequest)]")

        countLogWarning = 0
        countLogError = 0
        statusCode = -1
        errorMessage = ""
        countBackoffRequest = 0
        consecutiveBackoffRequest = 0
        countConsecutiveBackoffRequest = 0
        methodUsage = [:]
        logCodes = [:]
    }

    /// Takes the reported amounts away once the server accepted a health check.
    /// What was counted while the request was on its way stays for the next one.
    private func clearSentValues(_ sent: Snapshot) {
        queue.async {
            self.countLogError = max(0, self.countLogError - sent.errors)
            self.countLogWarning = max(0, self.countLogWarning - sent.warnings)
            self.countBackoffRequest = max(0, self.countBackoffRequest - sent.backoffs)

            if self.statusCode == sent.statusCode, self.errorMessage == sent.errorMessage {
                self.statusCode = -1
                self.errorMessage = ""
            }
            if self.consecutiveBackoffRequest == sent.longestBackoffRun {
                self.consecutiveBackoffRequest = 0
            }

            for (area, methods) in sent.methodUsage {
                var remaining = self.methodUsage[area] ?? [:]
                for (method, count) in methods {
                    let left = (remaining[method] ?? 0) - count
                    remaining[method] = left > 0 ? left : nil
                }
                self.methodUsage[area] = remaining.isEmpty ? nil : remaining
            }
            for (code, count) in sent.logCodes {
                let left = (self.logCodes[code] ?? 0) - count
                self.logCodes[code] = left > 0 ? left : nil
            }

            self.store.healthCheckState = self.stateLocked()
            self.logger?.d(Self.module, "clearSentValues", "the reported amounts are taken off the counters, remainingErrorCount: [\(self.countLogError)], remainingWarningCount: [\(self.countLogWarning)], remainingBackoffCount: [\(self.countBackoffRequest)]")
        }
    }

    private func restore() {
        guard let state = store.healthCheckState, !state.isEmpty else {
            logger?.d(Self.module, "restore", "no counters were carried over from a previous launch, the health check starts from zero")
            return
        }

        countLogWarning = (state[StateKey.logWarning] as? Int) ?? 0
        countLogError = (state[StateKey.logError] as? Int) ?? 0
        statusCode = (state[StateKey.statusCode] as? Int) ?? -1
        errorMessage = (state[StateKey.errorMessage] as? String) ?? ""
        countBackoffRequest = (state[StateKey.backoffRequest] as? Int) ?? 0
        consecutiveBackoffRequest = (state[StateKey.consecutiveBackoffRequest] as? Int) ?? 0

        if let storedUsage = state[StateKey.methodUsage] as? [String: Any] {
            for (area, value) in storedUsage {
                guard let methods = value as? [String: Any] else { continue }
                var counts: [String: Int] = [:]
                for (method, count) in methods {
                    guard let count = count as? Int, count > 0 else { continue }
                    counts[method] = min(Self.maxCount, count)
                }
                if !counts.isEmpty {
                    methodUsage[area] = counts
                }
            }
        }
        if let storedCodes = state[StateKey.logCodes] as? [String: Any] {
            for (code, count) in storedCodes {
                guard let count = count as? Int, count > 0 else { continue }
                logCodes[code] = min(Self.maxCount, count)
            }
        }

        logger?.d(Self.module, "restore", "restored persisted counters, errorCount: [\(countLogError)], warningCount: [\(countLogWarning)], statusCode: [\(statusCode)], errorMessageLength: [\(errorMessage.count)], backoffCount: [\(countBackoffRequest)], longestBackoffRun: [\(consecutiveBackoffRequest)], methodUsageAreaCount: [\(methodUsage.count)], logCodeCount: [\(logCodes.count)]")
    }

    // MARK: - Sending

    /// The counters a health check reported, kept until the server answers.
    private struct Snapshot {
        let errors: Int
        let warnings: Int
        let statusCode: Int
        let errorMessage: String
        let backoffs: Int
        let longestBackoffRun: Int
        let methodUsage: [String: [String: Int]]
        let logCodes: [String: Int]

        var payload: [String: Any] {
            [
                RequestKey.errorCount: errors,
                RequestKey.warningCount: warnings,
                RequestKey.statusCode: statusCode,
                RequestKey.requestError: errorMessage,
                RequestKey.backoffRequest: backoffs,
                RequestKey.consecutiveBackoffRequest: longestBackoffRun,
                RequestKey.methodUsage: methodUsage,
                RequestKey.logCodes: logCodes,
            ]
        }
    }

    /// Sends the health check as an instant request, outside the request queue.
    ///
    /// It carries no user data, which is why it is allowed to bypass the queue,
    /// but it is still withheld in temporary device ID mode and when networking is
    /// switched off by behavior settings.
    func sendHealthCheck(isDeviceIDTemporary: Bool, networkingEnabled: Bool) {
        guard let transport else {
            logger?.d(Self.module, "sendHealthCheck", "health check send skipped, the tracker has no transport yet")
            return
        }

        guard !isDeviceIDTemporary else {
            logger?.d(Self.module, "sendHealthCheck", "health check send skipped, sdk is in temporary device ID mode")
            return
        }

        guard networkingEnabled else {
            logger?.d(Self.module, "sendHealthCheck", "health check send skipped, networking is disabled by behavior settings")
            return
        }

        // Claimed under the queue that owns the flag, and claimed before the
        // request rather than after it succeeds. Reading it here and setting it in
        // the completion left a window in which a second trigger -- leaving
        // temporary device ID mode fires one right after init does -- passed the
        // guard too, sending the same counters twice and clearing them twice.
        let claimed: Bool = queue.sync {
            guard healthCheckEnabled, !healthCheckSent else { return false }
            healthCheckSent = true
            return true
        }

        guard claimed else {
            logger?.d(Self.module, "sendHealthCheck", "health check send skipped, it has already been sent this launch or is disabled")
            return
        }

        let snapshot = takeSnapshot()
        logger?.i(Self.module, "sendHealthCheck", "sending health check request, errorCount: [\(snapshot.errors)], warningCount: [\(snapshot.warnings)], statusCode: [\(snapshot.statusCode)], backoffCount: [\(snapshot.backoffs)], longestBackoffRun: [\(snapshot.longestBackoffRun)], methodUsageAreaCount: [\(snapshot.methodUsage.count)], logCodeCount: [\(snapshot.logCodes.count)], requestErrorLength: [\(snapshot.errorMessage.count)]")

        // The body the server sent back on the last failed request is repeated
        // verbatim on the wire, and nobody knows what a deployment puts in it.
        if !snapshot.errorMessage.isEmpty {
            logger?.v(Self.module, "sendHealthCheck", "health check request error detail, requestError: [\(snapshot.errorMessage)]")
        }

        transport.sendHealthCheck(payload: snapshot.payload) { [weak self] wasAccepted, error in
            guard let self else { return }

            if let error {
                self.logger?.d(Self.module, "sendHealthCheck", "health check request failed at the transport level, it will be retried later, error: [\(error.localizedDescription)]")
                self.queue.async { self.healthCheckSent = false }
                return
            }

            // Debug rather than error: a rejected health check must not inflate the
            // counters this request exists to report.
            guard wasAccepted else {
                self.logger?.d(Self.module, "sendHealthCheck", "the server did not accept the health check, counters will not be cleared")
                self.queue.async { self.healthCheckSent = false }
                return
            }

            self.logger?.d(Self.module, "sendHealthCheck", "health check accepted by the server, the reported amounts will be cleared")
            self.clearSentValues(snapshot)
        }
    }

    /// Reads the counters synchronously for the outgoing request.
    private func takeSnapshot() -> Snapshot {
        queue.sync {
            Snapshot(errors: countLogError,
                     warnings: countLogWarning,
                     statusCode: statusCode,
                     errorMessage: errorMessage,
                     backoffs: countBackoffRequest,
                     longestBackoffRun: consecutiveBackoffRequest,
                     methodUsage: methodUsage,
                     logCodes: logCodes)
        }
    }
}

/// What the health tracker needs from the networking layer, kept narrow so the
/// tracker does not depend on the whole connection manager.
///
/// The transport reports whether the server accepted the request rather than
/// handing back the body: deciding that is the networking layer's job, and it is
/// the same rule every other request is judged by.
protocol HealthCheckTransport: AnyObject {
    func sendHealthCheck(payload: [String: Any], completion: @escaping (Bool, Error?) -> Void)
}

/// Warnings, errors and log codes counted for an instance before it has a
/// health tracker, for example calls made before `start(with:)`. The tracker
/// takes them over when the instance starts.
enum PendingHealthCounts {

    /// What was counted for one instance.
    struct Counts {
        var warnings = 0
        var errors = 0
        var logCodes: [String: Int] = [:]
    }

    private static let lock = NSLock()
    private static var byInstance: [String: Counts] = [:]

    /// Counts a warning, with its log code when it has one.
    static func recordWarning(instanceName: String, code: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var counts = byInstance[instanceName] ?? Counts()
        counts.warnings += 1
        if let code {
            counts.logCodes[code] = min(HealthTracker.maxCount, (counts.logCodes[code] ?? 0) + 1)
        }
        byInstance[instanceName] = counts
    }

    /// Counts an error.
    static func recordError(instanceName: String) {
        lock.lock()
        defer { lock.unlock() }
        var counts = byInstance[instanceName] ?? Counts()
        counts.errors += 1
        byInstance[instanceName] = counts
    }

    /// Hands over and forgets what was counted for an instance.
    static func take(instanceName: String) -> Counts {
        lock.lock()
        defer { lock.unlock() }
        return byInstance.removeValue(forKey: instanceName) ?? Counts()
    }
}
