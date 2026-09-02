//
//  HealthTracker.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

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
    }

    /// Keys of the `hc` request payload.
    private enum RequestKey {
        static let errorCount = "el"
        static let warningCount = "wl"
        static let statusCode = "sc"
        static let requestError = "em"
        static let backoffRequest = "bom"
        static let consecutiveBackoffRequest = "cbom"
    }

    /// Longest error message retained, so one huge server error cannot bloat
    /// every subsequent health check.
    private static let maxErrorMessageLength = 1000

    /// Serial queue owning every counter. All mutation hops onto it.
    private let queue = DispatchQueue(label: "ly.count.healthtracker.queue")

    private let store: KeyValueStore
    private weak var logger: Logger?

    /// Set once the instance is composed. Weak so the tracker never keeps an
    /// instance alive.
    weak var transport: HealthCheckTransport?

    private var countLogWarning: Int = 0
    private var countLogError: Int = 0
    private var countBackoffRequest: Int = 0
    private var countConsecutiveBackoffRequest: Int = 0
    private var consecutiveBackoffRequest: Int = 0
    private var statusCode: Int = -1
    private var errorMessage: String = ""

    /// Turned off by behavior settings.
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
        guard statusCode > 0, statusCode < 1000, let errorResponse else {
            // Says why a health check can report no failure at all while the
            // requests were failing the whole time.
            logger?.d(Self.module, "logFailedNetworkRequest", "the failed network request is not recorded, it carries no server status or no response body, statusCode: [\(statusCode)], hasErrorResponse: [\(errorResponse != nil)]")
            return
        }

        queue.async {
            self.statusCode = statusCode
            self.errorMessage = String(errorResponse.prefix(Self.maxErrorMessageLength))
            self.logger?.d(Self.module, "logFailedNetworkRequest", "recorded failed network request, statusCode: [\(statusCode)], errorResponseLength: [\(errorResponse.count)], storedErrorMessageLength: [\(self.errorMessage.count)]")
        }
    }

    /// Records that a request was held back by the backoff mechanism.
    func logBackoffRequest() {
        queue.async {
            self.countBackoffRequest += 1
            self.countConsecutiveBackoffRequest += 1
            self.logger?.d(Self.module, "logBackoffRequest", "recorded a backed off request, backoffRequestCount: [\(self.countBackoffRequest)], currentConsecutiveBackoffRequestCount: [\(self.countConsecutiveBackoffRequest)]")
        }
    }

    /// Closes the current backoff streak, keeping the longest one seen.
    func logConsecutiveBackoffRequest() {
        queue.async { self.closeBackoffStreak() }
    }

    /// Must be called on `queue`.
    private func closeBackoffStreak() {
        consecutiveBackoffRequest = max(consecutiveBackoffRequest, countConsecutiveBackoffRequest)
        countConsecutiveBackoffRequest = 0
        logger?.d(Self.module, "closeBackoffStreak", "consecutive backoff streak closed, peakConsecutiveBackoffRequestCount: [\(consecutiveBackoffRequest)]")
    }

    // MARK: - Persistence

    /// Persists the counters so a launch that never got to send a health check
    /// still contributes its numbers to the next one.
    func saveState() {
        queue.async {
            // Closed inline, before the snapshot is built. Enqueueing the close
            // instead would run it after the dictionary below was assembled and
            // persist the peak as of the previous close.
            self.closeBackoffStreak()

            let state: [String: Any] = [
                StateKey.logWarning: self.countLogWarning,
                StateKey.logError: self.countLogError,
                StateKey.statusCode: self.statusCode,
                StateKey.errorMessage: self.errorMessage,
                StateKey.backoffRequest: self.countBackoffRequest,
                StateKey.consecutiveBackoffRequest: self.consecutiveBackoffRequest,
            ]
            self.store.healthCheckState = state
            self.logger?.d(Self.module, "saveState", "counters persisted, errorCount: [\(self.countLogError)], warningCount: [\(self.countLogWarning)], statusCode: [\(self.statusCode)], errorMessageLength: [\(self.errorMessage.count)], backoffRequestCount: [\(self.countBackoffRequest)], peakConsecutiveBackoffRequestCount: [\(self.consecutiveBackoffRequest)]")
        }
    }

    /// Zeroes the counters and persists the empty state, after the server has
    /// accepted them.
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
        logger?.d(Self.module, "clearValues", "clearing counters, discardedErrorCount: [\(countLogError)], discardedWarningCount: [\(countLogWarning)], discardedBackoffRequestCount: [\(countBackoffRequest)]")

        countLogWarning = 0
        countLogError = 0
        statusCode = -1
        errorMessage = ""
        countBackoffRequest = 0
        consecutiveBackoffRequest = 0
        countConsecutiveBackoffRequest = 0
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

        logger?.d(Self.module, "restore", "restored persisted counters, errorCount: [\(countLogError)], warningCount: [\(countLogWarning)], statusCode: [\(statusCode)], errorMessageLength: [\(errorMessage.count)], backoffRequestCount: [\(countBackoffRequest)], consecutiveBackoffRequestCount: [\(consecutiveBackoffRequest)]")
    }

    // MARK: - Sending

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

        let payload = snapshotPayload()
        let requestError = (payload[RequestKey.requestError] as? String) ?? ""
        logger?.i(Self.module, "sendHealthCheck", "sending health check request, errorCount: [\(payload[RequestKey.errorCount] ?? 0)], warningCount: [\(payload[RequestKey.warningCount] ?? 0)], statusCode: [\(payload[RequestKey.statusCode] ?? -1)], backoffRequestCount: [\(payload[RequestKey.backoffRequest] ?? 0)], consecutiveBackoffRequestCount: [\(payload[RequestKey.consecutiveBackoffRequest] ?? 0)], requestErrorLength: [\(requestError.count)]")

        // The body the server sent back on the last failed request is repeated
        // verbatim on the wire, and nobody knows what a deployment puts in it.
        if !requestError.isEmpty {
            logger?.v(Self.module, "sendHealthCheck", "health check request error detail, requestError: [\(requestError)]")
        }

        transport.sendHealthCheck(payload: payload) { [weak self] wasAccepted, error in
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

            self.logger?.d(Self.module, "sendHealthCheck", "health check accepted by the server, counters will be cleared")
            self.clearAndSave()
        }
    }

    /// Reads the counters synchronously for the outgoing request.
    private func snapshotPayload() -> [String: Any] {
        queue.sync {
            [
                RequestKey.errorCount: countLogError,
                RequestKey.warningCount: countLogWarning,
                RequestKey.statusCode: statusCode,
                RequestKey.requestError: errorMessage,
                RequestKey.backoffRequest: countBackoffRequest,
                RequestKey.consecutiveBackoffRequest: consecutiveBackoffRequest,
            ]
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
