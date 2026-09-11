//
//  ConnectionManager.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Sends what the modules queue, one request at a time, in order.
///
/// Ordering is the point: the server reconstructs a session from a sequence of
/// requests, so a later request must not overtake an earlier one. The head of the
/// queue is only removed once the server has accepted it, which is what makes the
/// SDK survive a crash or a dead network without losing data.
final class ConnectionManager: NSObject {

    private static let module = "ConnectionManager"

    unowned let core: SDKCore
    let builder: RequestBuilder

    /// Serializes callback and runnable bookkeeping.
    private let callbackQueue = DispatchQueue(label: "ly.count.callbackQueue")

    /// Guards the single-in-flight invariant.
    private let stateLock = NSLock()
    private var isProcessingQueue = false
    private var isBackingOff = false
    private var currentTask: URLSessionTask?

    /// When the current drain of the queue started, used to time it and to decide
    /// whether the flush runnables should fire.
    private var drainStartTime: Date?
    private var hasAnyRequestFailed = false

    /// Callbacks waiting for their request to complete, keyed by the callback ID
    /// that travels inside the queued query string.
    private var requestCallbacks: [String: RequestCallback] = [:]

    /// Blocks that run once the queue drains with nothing having failed.
    private var queueFlushRunnables: [() -> Void] = []

    /// Guards the two cached sessions.
    ///
    /// They are built lazily from URLSession completion threads, from timers and
    /// from the crash path, so an unguarded lazy assignment would let two threads
    /// each build one, leak whichever loses, and race on the reference itself.
    private let sessionLock = NSLock()
    private var urlSession: URLSession?
    private var immediateSession: URLSession?

    init(core: SDKCore, builder: RequestBuilder) {
        self.core = core
        self.builder = builder
        super.init()
    }

    // MARK: - Enqueueing

    /// Queues a request and starts draining.
    func enqueueAndProceed(_ queryString: String) {
        enqueue(queryString)
        proceedOnQueue()
    }

    /// Queues a request without starting a drain, for callers that will follow up
    /// with several more.
    func enqueue(_ queryString: String) {
        core.requestQueueStore.enqueue(queryString,
                                       appVersion: DeviceMetrics.appVersion,
                                       trackingEnabled: core.serverConfig.trackingEnabled)
    }

    /// Queues a request and reports its outcome to `callback`.
    ///
    /// The callback is kept in memory and referenced from the queued string by a
    /// generated ID. A callback therefore does not survive a process restart,
    /// while the request it belongs to does.
    func enqueue(_ queryString: String, callback: RequestCallback?) {
        guard !queryString.isEmpty else {
            core.logger.d(Self.module, "enqueue", "request is not queued, reason: the query string is empty, callbackProvided: [\(callback != nil)]")
            return
        }

        guard let callback else {
            enqueue(queryString)
            return
        }

        let callbackID = UUID().uuidString
        core.logger.d(Self.module, "enqueue", "queueing a request with a callback, callbackID: [\(callbackID)], queryStringLength: [\(queryString.count)]")

        callbackQueue.sync { requestCallbacks[callbackID] = callback }
        enqueue("\(queryString)&\(QS.callbackID)=\(callbackID)")
    }

    /// Registers a block to run the next time the queue drains completely with no
    /// failures. Used by journey triggers, which need the server to have seen
    /// everything before they ask what to show.
    func addQueueFlushRunnable(_ runnable: @escaping () -> Void) {
        callbackQueue.sync {
            queueFlushRunnables.append(runnable)
            core.logger.d(Self.module, "addQueueFlushRunnable", "adding a queue flush runnable, totalRunnableCount: [\(queueFlushRunnables.count)]")
        }
    }

    /// Drops every registered flush runnable.
    func clearQueueFlushRunnables() {
        callbackQueue.sync {
            core.logger.d(Self.module, "clearQueueFlushRunnables", "clearing all queue flush runnables, count: [\(queueFlushRunnables.count)]")
            queueFlushRunnables.removeAll()
        }
    }

    // MARK: - Draining

    /// Sends the head of the queue, then calls itself until the queue is empty.
    ///
    /// Every early return here is a reason not to send right now; none of them
    /// discard data. The processing flag is released before returning in each case
    /// so a later trigger can pick the drain back up.
    func proceedOnQueue() {
        guard core.serverConfig.networkingEnabled else {
            core.logger.d(Self.module, "proceedOnQueue", "aborting queue processing, reason: SDK networking is disabled from server config")
            return
        }

        stateLock.lock()
        if isProcessingQueue {
            stateLock.unlock()
            core.logger.d(Self.module, "proceedOnQueue", "aborting queue processing, reason: another request is already in process")
            return
        }
        isProcessingQueue = true
        stateLock.unlock()

        if core.isCrashing {
            abortProcessing("application is crashing")
            return
        }

        if core.isTerminating {
            abortProcessing("application is terminating")
            return
        }

        if core.requestQueueStore.isBeingModified {
            abortProcessing("request queue is being modified")
            return
        }

        stateLock.lock()
        let backingOff = isBackingOff
        stateLock.unlock()
        if backingOff {
            abortProcessing("backoff is currently active")
            return
        }

        if drainStartTime == nil {
            drainStartTime = Date()
            hasAnyRequestFailed = false
            core.logger.d(Self.module, "proceedOnQueue", "queue processing is started, queuedRequestCount: [\(core.requestQueueStore.count)]")
        }

        guard let head = core.requestQueueStore.head else {
            finishDrain()
            return
        }

        if core.requestQueueStore.isOldRequest(head) {
            core.logger.w(Self.module, "proceedOnQueue", "dropping the request at the head of the queue, reason: request age exceeded the configured drop age, requestDropAgeHours: [\(core.requestQueueStore.requestDropAgeHours)], requestSize: [\(head.count)], queuedRequestCount: [\(core.requestQueueStore.count)]")
            core.requestQueueStore.removeHead(head)
            core.requestQueueStore.save()
            releaseProcessing()
            proceedOnQueue()
            return
        }

        // A request recorded before a real device ID was known must wait: sending
        // it now would attribute the data to the placeholder ID.
        if head.contains("&\(QS.deviceID)=\(TemporaryDeviceID.value)") {
            abortProcessing("device ID of the request at the head of the queue is the temporary device ID")
            return
        }

        send(head: head)
    }

    private func finishDrain() {
        let elapsed = drainStartTime.map { -$0.timeIntervalSinceNow } ?? 0
        core.logger.d(Self.module, "proceedOnQueue", "request queue is empty, all requests are processed, totalTimeTaken: [\(elapsed.logSeconds)]")

        if !hasAnyRequestFailed {
            var runnables: [() -> Void] = []
            callbackQueue.sync {
                if !queueFlushRunnables.isEmpty {
                    core.logger.d(Self.module, "proceedOnQueue", "all requests succeeded, executing queue flush runnables, count: [\(queueFlushRunnables.count)]")
                    runnables = queueFlushRunnables
                    queueFlushRunnables.removeAll()
                }
            }
            // Run outside the lock: a runnable may queue more work.
            for runnable in runnables { runnable() }
            if !runnables.isEmpty {
                core.logger.d(Self.module, "proceedOnQueue", "all queue flush runnables are executed and removed")
            }
        } else {
            core.logger.d(Self.module, "proceedOnQueue", "at least one request failed, queue flush runnables will not be executed")
        }

        drainStartTime = nil
        hasAnyRequestFailed = false
        releaseProcessing()
    }

    /// Sends the head of the queue.
    ///
    /// Lines logged while sending a gathered log batch are not gathered, or every
    /// tick would upload a batch about the last one. The caller may already be
    /// marked, since the delivery loop lands here synchronously, so the mark is
    /// restored on the way out.
    private func send(head: String) {
        let isSdkLogsTransport = head.contains("&\(QS.sdkLogs)=")
        core.logGatherer.markingTransportWork(isSdkLogsTransport) {
            sendMarked(head: head, isSdkLogsTransport: isSdkLogsTransport)
        }
    }

    private func sendMarked(head: String, isSdkLogsTransport: Bool) {
        var queryString = head
        var endpoint = Endpoint.input

        if let override = extractAndRemoveParameter(&queryString, parameter: QS.newEndPoint) {
            endpoint = override
        }

        var callback: RequestCallback?
        let callbackID = extractAndRemoveParameter(&queryString, parameter: QS.callbackID)
        if let callbackID {
            callbackQueue.sync { callback = requestCallbacks[callbackID] }
            if callback == nil {
                core.logger.d(Self.module, "proceedOnQueue", "the request carries a callback ID but no callback is registered under it, it was queued before the process restarted, callbackID: [\(callbackID)]")
            }
        }

        queryString = builder.appendRemainingRequestCount(queryString)

        // Checked with a substring first: resolving it means decoding the whole
        // query, and only a profile picture save ever carries one. The key is
        // matched as a parameter, because a gathered log batch can quote its name.
        let pictureUpload = queryString.contains("&\(QS.userDetails)=") ? pictureUploadData(for: queryString) : nil
        if pictureUpload == nil {
            queryString = builder.appendChecksum(queryString)
        }

        let request = buildRequest(queryString: queryString, endpoint: endpoint, pictureUpload: pictureUpload)
        let startedAt = Date()

        // The core is captured strongly for the life of the callback: it is held
        // `unowned` on this class, and `halt()` can release it while a request is
        // still in flight.
        // Held from here until the completion has finished dealing with the
        // response, which is where the head is removed and the queue written.
        BackgroundTaskGuard.shared.begin()

        let task = session().dataTask(with: request) { [weak self, core] data, response, error in
            defer { BackgroundTaskGuard.shared.end() }
            guard let self else { return }
            _ = core
            self.stateLock.lock()
            self.currentTask = nil
            self.stateLock.unlock()

            // The completion runs on a session thread of its own, which has to be
            // marked in turn while it deals with a gathered log batch.
            self.core.logGatherer.markingTransportWork(isSdkLogsTransport) {
                let elapsed = Date().timeIntervalSince(startedAt)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

                if response != nil {
                    self.core.logger.d(Self.module, "proceedOnQueue", "response received, endpoint: [\(request.url?.path ?? "")], statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], duration: [\(elapsed.logSeconds)]")
                }

                if let error {
                    self.handleTransportFailure(error: error, request: request, callback: callback, callbackID: callbackID)
                    return
                }

                if self.isRequestSuccessful(response: response, data: data, endpoint: endpoint) {
                    self.handleSuccess(head: head,
                                       queryString: queryString,
                                       elapsed: elapsed,
                                       request: request,
                                       callback: callback,
                                       callbackID: callbackID,
                                       response: response)
                } else {
                    self.handleServerFailure(statusCode: statusCode,
                                             data: data,
                                             request: request,
                                             callback: callback,
                                             callbackID: callbackID)
                }
            }
        }

        stateLock.lock()
        currentTask = task
        stateLock.unlock()

        task.resume()
        logRequest(request)
    }

    private func handleSuccess(head: String,
                               queryString: String,
                               elapsed: TimeInterval,
                               request: URLRequest,
                               callback: RequestCallback?,
                               callbackID: String?,
                               response: URLResponse?) {
        core.logger.d(Self.module, "proceedOnQueue", "request completed successfully and will be removed from the queue, endpoint: [\(request.url?.path ?? "")], statusCode: [\((response as? HTTPURLResponse)?.statusCode ?? 0)], duration: [\(elapsed.logSeconds)]")

        deliver(callback, callbackID: callbackID, response: response.map { String(describing: $0) }, success: true)

        core.requestQueueStore.removeHead(head)
        core.requestQueueStore.save()

        // The flag is released only after the head is gone. Releasing it earlier
        // would let a concurrent caller re-send the request that just succeeded.
        releaseProcessing()

        if core.serverConfig.backoffMechanism, shouldBackOff(responseTimeSeconds: Int(elapsed), queryString: queryString) {
            core.logger.d(Self.module, "proceedOnQueue", "stopping queue processing, reason: backoff is triggered, responseTimeSeconds: [\(Int(elapsed))], queuedRequestCount: [\(core.requestQueueStore.count)]")
            drainStartTime = nil
            hasAnyRequestFailed = false
            startBackoffCountdown()
        } else {
            proceedOnQueue()
        }
    }

    private func handleServerFailure(statusCode: Int,
                                     data: Data?,
                                     request: URLRequest,
                                     callback: RequestCallback?,
                                     callbackID: String?) {
        core.logger.d(Self.module, "proceedOnQueue", "request failed, endpoint: [\(request.url?.path ?? "")], statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)]")

        let body = data.flatMap { String(data: $0, encoding: .utf8) }
        core.logger.v(Self.module, "proceedOnQueue", "failed request detail, fullResponseURL: [\(request.url?.absoluteString ?? "")], serverErrorResponseBody: [\(body ?? "")]")

        hasAnyRequestFailed = true
        deliver(callback, callbackID: callbackID, response: body, success: false)

        core.healthTracker.logFailedNetworkRequest(statusCode: statusCode, errorResponse: body)
        core.healthTracker.saveState()

        core.logger.d(Self.module, "proceedOnQueue", "queue processing is stopped after a rejected request, the request stays at the head of the queue and is sent again on the next drain, queuedRequestCount: [\(core.requestQueueStore.count)]")

        drainStartTime = nil
        releaseProcessing()
    }

    private func handleTransportFailure(error: Error,
                                        request: URLRequest,
                                        callback: RequestCallback?,
                                        callbackID: String?) {
        let nsError = error as NSError
        core.logger.d(Self.module, "proceedOnQueue", "request failed with a network error, endpoint: [\(request.url?.path ?? "")], errorDomain: [\(nsError.domain)], errorCode: [\(nsError.code)], errorDescription: [\(error.localizedDescription)]")

        hasAnyRequestFailed = true
        deliver(callback, callbackID: callbackID, response: error.localizedDescription, success: false)

        #if os(watchOS)
        // The watch can be suspended without warning, so the queue is flushed to
        // disk at every opportunity there.
        core.requestQueueStore.save()
        #endif

        core.logger.d(Self.module, "proceedOnQueue", "queue processing is stopped after a network error, the request stays at the head of the queue and is sent again on the next drain, queuedRequestCount: [\(core.requestQueueStore.count)]")

        drainStartTime = nil
        releaseProcessing()
    }

    /// The response is autoclosed because most requests carry no callback, and
    /// describing an `HTTPURLResponse` renders every header into a string nobody
    /// reads.
    private func deliver(_ callback: RequestCallback?, callbackID: String?, response: @autoclosure () -> String?, success: Bool) {
        guard let callback else { return }

        core.logger.d(Self.module, "proceedOnQueue", "the outcome of the request is delivered to the callback it was queued with, success: [\(success)], callbackID: [\(callbackID ?? "none")]")
        callback(response(), success)
        if let callbackID {
            callbackQueue.sync { _ = requestCallbacks.removeValue(forKey: callbackID) }
        }
    }

    /// Gives up this drain, leaving the queue as it is so a later trigger picks it
    /// back up.
    private func abortProcessing(_ reason: String) {
        core.logger.d(Self.module, "proceedOnQueue", "aborting queue processing, reason: [\(reason)]")
        releaseProcessing()
    }

    private func releaseProcessing() {
        stateLock.lock()
        isProcessingQueue = false
        stateLock.unlock()
    }

    // MARK: - Backoff

    /// Whether the server looks overloaded enough to pause sending.
    ///
    /// All three conditions have to hold: the response was slow, the queue is
    /// small enough that pausing will not overflow it, and the request was recent
    /// enough that the delay still matters. A backlog of old data keeps draining.
    private func shouldBackOff(responseTimeSeconds: Int, queryString: String) -> Bool {
        let result = isServerOverloaded(responseTimeSeconds: responseTimeSeconds, queryString: queryString)

        if !result {
            core.healthTracker.logConsecutiveBackoffRequest()
        }

        return result
    }

    /// The three conditions themselves, each of which is a reason to keep sending.
    private func isServerOverloaded(responseTimeSeconds: Int, queryString: String) -> Bool {
        guard responseTimeSeconds >= core.serverConfig.bomAcceptedTimeoutSeconds else {
            core.logger.d(Self.module, "shouldBackOff", "backoff is not triggered, reason: the server answered within the accepted timeout, responseTimeSeconds: [\(responseTimeSeconds)], acceptedTimeoutSeconds: [\(core.serverConfig.bomAcceptedTimeoutSeconds)]")
            return false
        }

        let remaining = core.requestQueueStore.count
        let threshold = Int(Double(core.requestQueueStore.storedRequestsLimit) * core.serverConfig.bomRQPercentage)
        guard remaining <= threshold else {
            core.logger.d(Self.module, "shouldBackOff", "backoff is not triggered, reason: pausing would overflow the request queue, remainingRequestCount: [\(remaining)], requestCountThreshold: [\(threshold)], storedRequestsLimit: [\(core.requestQueueStore.storedRequestsLimit)]")
            return false
        }

        let ageSeconds = queryString.requestAgeSeconds
        guard ageSeconds <= Double(core.serverConfig.bomRequestAge) * 3600.0 else {
            core.logger.d(Self.module, "shouldBackOff", "backoff is not triggered, reason: the request is a backlog one and the delay no longer matters, requestAge: [\(ageSeconds.logSeconds)], acceptedRequestAgeHours: [\(core.serverConfig.bomRequestAge)]")
            return false
        }

        core.logger.d(Self.module, "shouldBackOff", "backoff is triggered, responseTimeSeconds: [\(responseTimeSeconds)], remainingRequestCount: [\(remaining)], requestCountThreshold: [\(threshold)], requestAge: [\(ageSeconds.logSeconds)]")
        core.healthTracker.logBackoffRequest()
        return true
    }

    private func startBackoffCountdown() {
        let duration = core.serverConfig.bomDuration
        core.logger.d(Self.module, "startBackoffCountdown", "backoff countdown is started and queue processing is paused, pauseDurationSeconds: [\(duration)], queuedRequestCount: [\(core.requestQueueStore.count)]")

        stateLock.lock()
        isBackingOff = true
        stateLock.unlock()

        DispatchQueue.global(qos: .default).asyncAfter(deadline: .now() + .seconds(duration)) { [weak self] in
            guard let self else { return }
            self.core.logger.d(Self.module, "startBackoffCountdown", "backoff countdown is finished, resuming queue processing on a background thread")
            self.stateLock.lock()
            self.isBackingOff = false
            self.stateLock.unlock()
            self.proceedOnQueue()
        }
    }

    // MARK: - Operator armed diagnostics

    /// Queues one connection test report as its own request.
    ///
    /// No consent gate, by cross SDK rule: the report describes the network the
    /// device is on, not the user, and the health check bypasses consent on the
    /// same grounds. The queue's own rules still govern it.
    func sendConnectionTestResults(_ resultsJSON: String) {
        guard enqueueDiagnostic(key: QS.connectionTestResults, payload: resultsJSON) else {
            core.logger.d(Self.module, "sendConnectionTestResults", "the connection test report is dropped, the instance is halted or tracking is disabled, reportLength: [\(resultsJSON.count)]")
            return
        }
        core.logger.d(Self.module, "sendConnectionTestResults", "the connection test report is queued, reportLength: [\(resultsJSON.count)]")
    }

    /// Queues one operator armed diagnostic payload as its own request and starts
    /// a drain. Returns whether the store took it: a halted instance and tracking
    /// switched off are the two reasons it would not.
    private func enqueueDiagnostic(key: String, payload: String) -> Bool {
        guard core.hasStarted, core.serverConfig.trackingEnabled else { return false }
        enqueueAndProceed("\(builder.queryEssentials())&\(key)=\(payload.urlEscaped)")
        return true
    }

    // MARK: - Crash reports

    /// Sends a crash report, optionally bypassing the queue.
    ///
    /// An immediate send blocks the calling thread until the server answers,
    /// because the process is about to die and an async send would not survive it.
    /// If it fails the report is queued so the next launch sends it.
    ///
    /// Reachable from the signal handler, so no log line here goes above info:
    /// error and warning logging touches dispatch primitives that are not
    /// async-signal-safe.
    func sendCrashReport(_ report: String?, immediately: Bool) {
        guard core.serverConfig.networkingEnabled else {
            core.logger.d(Self.module, "sendCrashReport", "crash report is dropped, reason: SDK networking is disabled from server config, crashReportLength: [\(report?.count ?? 0)]")
            return
        }

        guard let report else {
            core.logger.d(Self.module, "sendCrashReport", "crash report is nil, converting it to JSON may have failed due to custom objects in the crash segmentation")
            return
        }

        let queryString = "\(builder.queryEssentials())&\(QS.crash)=\(report)"

        guard immediately else {
            core.logger.d(Self.module, "sendCrashReport", "crash report is added to the request queue, crashReportLength: [\(report.count)]")
            enqueueAndProceed(queryString)
            return
        }

        // Stops anything else from starting a drain that would race the crash
        // report. Only the crash leaves at crash time: recorded events and the
        // running session stay on disk and are reported on the next launch.
        core.isCrashing = true

        if core.modules.deviceID.isTemporary {
            core.logger.d(Self.module, "sendCrashReport", "crash report is stored to be sent later, reason: device ID is the temporary device ID, crashReportLength: [\(report.count)]")
            enqueue(queryString)
            core.requestQueueStore.saveSync()
            return
        }

        core.requestQueueStore.saveSync()

        let stamped = "\(queryString)&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        guard let endpointURL = URL(string: core.config.normalizedHost + Endpoint.input) else {
            // Queued instead of dropped: the host may be fixed on a later launch,
            // and trapping here would crash the app while it is already crashing.
            core.logger.d(Self.module, "sendCrashReport", "the server URL could not be built, the crash report is queued instead")
            enqueue(queryString)
            core.requestQueueStore.saveSync()
            return
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = Data(builder.appendChecksum(stamped).utf8)

        core.logger.i(Self.module, "sendCrashReport", "sending crash report immediately, endpoint: [\(Endpoint.input)], method: [POST], bodySize: [\(request.httpBody?.count ?? 0)]")

        let semaphore = DispatchSemaphore(value: 0)
        session().dataTask(with: request) { [weak self] data, response, error in
            defer { semaphore.signal() }
            guard let self else { return }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || !self.isRequestSuccessful(response: response, data: data, endpoint: Endpoint.input) {
                self.core.logger.d(Self.module, "sendCrashReport", "immediate crash report request failed and it is queued to be sent later, endpoint: [\(request.url?.path ?? "")], statusCode: [\(statusCode)], errorDescription: [\(error?.localizedDescription ?? "none")]")
                self.enqueue(queryString)
                self.core.requestQueueStore.saveSync()
            } else {
                self.core.logger.d(Self.module, "sendCrashReport", "immediate crash report request completed successfully, endpoint: [\(request.url?.path ?? "")], responseSize: [\(data?.count ?? 0)]")
            }
        }.resume()

        logRequest(request)
        semaphore.wait()
    }

    // MARK: - Request construction

    /// A URL for a string the configuration produced.
    ///
    /// A host the SDK cannot parse yields an unreachable URL rather than a trap:
    /// the request then fails like any other and stays in the queue, which is what
    /// a later launch with a corrected host needs.
    private static func requestURL(_ string: String) -> URL {
        URL(string: string) ?? URL(string: "https://invalid")!
    }

    private func buildRequest(queryString: String, endpoint: String, pictureUpload: Data?) -> URLRequest {
        let urlString = core.config.normalizedHost + endpoint
        var request = URLRequest(url: Self.requestURL(urlString))

        if let pictureUpload {
            var body = pictureUpload
            request.addValue("multipart/form-data; boundary=\(kUploadBoundary)", forHTTPHeaderField: "Content-Type")

            for pair in queryString.components(separatedBy: "&") {
                let parts = pair.components(separatedBy: "=")
                guard parts.count >= 2 else { continue }
                let key = parts[0].removingPercentEncoding ?? parts[0]
                let value = parts.dropFirst().joined(separator: "=").removingPercentEncoding ?? ""
                appendMultipart(&body, key: key, value: value)
            }

            if let salt = core.config.secretSalt, !salt.isEmpty {
                let unescaped = queryString.removingPercentEncoding ?? queryString
                appendMultipart(&body, key: QS.checksum256, value: (unescaped + salt).sha256Hex)
            }

            body.append(Data("\r\n--\(kUploadBoundary)--\r\n".utf8))
            request.httpMethod = "POST"
            request.httpBody = body
            core.logger.d(Self.module, "buildRequest", "request will be sent as a multipart POST with picture data, endpoint: [\(endpoint)], uploadDataSize: [\(body.count)]")
        } else if queryString.count > kGETRequestMaxLength || core.config.alwaysUsePOST {
            request.httpMethod = "POST"
            request.httpBody = Data(queryString.utf8)
            core.logger.d(Self.module, "buildRequest", "request will be sent as a POST, endpoint: [\(endpoint)], queryStringLength: [\(queryString.count)], getRequestMaxLength: [\(kGETRequestMaxLength)], alwaysUsePOST: [\(core.config.alwaysUsePOST)]")
        } else {
            request = URLRequest(url: Self.requestURL("\(urlString)?\(queryString)"))
        }

        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private func appendMultipart(_ data: inout Data, key: String, value: String) {
        data.append(Data("\r\n--\(kUploadBoundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(key)\";\r\n\r\n".utf8))
        data.append(Data(value.utf8))
    }

    /// Builds the leading multipart section when the queued request carries a
    /// local profile picture path.
    private func pictureUploadData(for queryString: String) -> Data? {
        #if os(iOS) || os(visionOS)
        guard let userDetails = queryString.valueForQueryStringKey(QS.userDetails),
              let unescaped = userDetails.removingPercentEncoding,
              let parsed = CountlyJSON.object(from: Data(unescaped.utf8), logger: core.logger) as? [String: Any],
              let localPath = parsed[UserProfileKey.localPicturePath] as? String,
              !localPath.isEmpty else {
            core.logger.d(Self.module, "pictureUploadData", "no local picture path is found in the user details of the request, it will be sent without a picture upload")
            return nil
        }

        core.logger.d(Self.module, "pictureUploadData", "local picture path is extracted from the query string, pathLength: [\(localPath.count)]")

        let allowed = ["gif", "png", "jpg", "jpeg"]
        let fileExtension = LocalPicturePath.fileExtension(of: localPath)
        guard let index = allowed.firstIndex(of: fileExtension) else {
            core.logger.w(Self.module, "pictureUploadData", "picture upload is skipped, reason: unsupported file extension, extension: [\(fileExtension)]")
            return nil
        }

        // Resolved the same way the readability check resolved it when the
        // property was set. Reading it differently here is how a picture that
        // passed validation silently fails to upload.
        guard let imageData = LocalPicturePath.data(at: localPath) else {
            core.logger.w(Self.module, "pictureUploadData", "picture upload is skipped, reason: local picture data can not be read, extension: [\(fileExtension)]")
            return nil
        }

        core.logger.d(Self.module, "pictureUploadData", "local picture data is read successfully, size: [\(imageData.count)]")

        // "jpg" and "jpeg" are the same format; the server expects the latter.
        let contentSubtype = index == 2 ? "jpeg" : allowed[index]

        var body = Data()
        body.append(Data("--\(kUploadBoundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"pictureFile\"; filename=\"\((localPath as NSString).lastPathComponent)\"\r\n".utf8))
        body.append(Data("Content-Type: image/\(contentSubtype)\r\n\r\n".utf8))
        body.append(imageData)
        return body
        #else
        return nil
        #endif
    }

    /// Pulls one parameter out of a queued query string and removes it.
    ///
    /// Used for the two parameters that are instructions to the SDK rather than
    /// data for the server: the endpoint override and the callback ID.
    private func extractAndRemoveParameter(_ queryString: inout String, parameter: String) -> String? {
        // Matched as a parameter, not as text: a gathered log batch can quote the
        // parameter's name, and a false match here would raise a warning per batch.
        guard queryString.contains("&\(parameter)=") else { return nil }

        guard let value = queryString.valueForQueryStringKey(parameter) else {
            core.logger.w(Self.module, "extractAndRemoveParameter", "parameter is present in the query string but its value could not be extracted, parameter: [\(parameter)]")
            return nil
        }

        queryString = queryString.replacingOccurrences(of: "&\(parameter)=\(value)", with: "")
        core.logger.d(Self.module, "extractAndRemoveParameter", "parameter is extracted and removed from the query string, parameter: [\(parameter)], valueLength: [\(value.count)]")
        return value
    }

    /// Decides whether a completed response counts as the request having landed.
    ///
    /// Only the ingest endpoint promises a `result` field, so only the ingest
    /// endpoint is judged by it. Every other endpoint answers with application
    /// payload of its own shape (remote config values, behavior settings, the
    /// widget list, A/B enrolment), and demanding `result` there marks a perfectly
    /// good response as a failure, leaving the request at the head of the queue to
    /// be retried on every later drain.
    ///
    /// - Parameters:
    ///   - endpoint: The path the request was sent to. Passed in rather than read
    ///     back off the response: a server hosted under a sub-path answers from
    ///     `/countly/i`, and a redirect can change the path outright, either of
    ///     which would make a path comparison conclude "not the ingest endpoint"
    ///     and wave through a 2xx that says `{"result": "Error"}`. That would
    ///     delete the request from the queue.
    ///   - quiet: Logs a rejection at debug rather than error. Used by the health
    ///     check, whose whole purpose is to report the error count, and which must
    ///     not add to it by being rejected.
    private func isRequestSuccessful(response: URLResponse?,
                                     data: Data?,
                                     endpoint: String,
                                     quiet: Bool = false) -> Bool {
        // Rejections are logged at debug for the health check and at error for
        // everything else, which is the only thing `quiet` changes. The two
        // wordings differ because a log message has to name one line of code.
        func logRejection(_ reason: String) {
            // Composed outside the literal so the message keeps the house shape,
            // where everything after the prose is a `key: [value]` pair.
            let line = (quiet ? "an unqueued request is judged as failed, " : "a queued request is judged as failed, ") + reason
            if quiet {
                core.logger.d(Self.module, "isRequestSuccessful", line)
            } else {
                core.logger.e(Self.module, "isRequestSuccessful", line)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            core.logger.d(Self.module, "isRequestSuccessful", "the request is judged as failed, reason: the reply is not an HTTP response, endpoint: [\(endpoint)], hasReply: [\(response != nil)]")
            return false
        }

        guard (200..<300).contains(http.statusCode) else {
            core.logger.d(Self.module, "isRequestSuccessful", "the request is judged as failed, reason: the HTTP status code is not in the 2XX series, endpoint: [\(endpoint)], statusCode: [\(http.statusCode)], responseSize: [\(data?.count ?? 0)]")
            return false
        }

        guard endpoint == Endpoint.input else {
            core.logger.d(Self.module, "isRequestSuccessful", "2XX on a non ingest endpoint is a success, the reply body is application payload and is not validated, endpoint: [\(endpoint)], statusCode: [\(http.statusCode)], responseSize: [\(data?.count ?? 0)]")
            return true
        }

        guard let reply = CountlyJSON.object(from: data, logger: nil) as? [String: Any] else {
            logRejection("reason: the server reply is not valid JSON, statusCode: [\(http.statusCode)], responseSize: [\(data?.count ?? 0)]")
            return false
        }

        core.logger.v(Self.module, "isRequestSuccessful", "server reply detail, fullResponseURL: [\(response?.url?.absoluteString ?? "")], parsedServerReply: [\(reply)]")

        guard let result = reply["result"] else {
            logRejection("reason: the server reply does not contain the result field, statusCode: [\(http.statusCode)], replyKeys: [\(reply.keys.sorted().joined(separator: ", "))]")
            return false
        }

        core.logger.d(Self.module, "isRequestSuccessful", "the server accepted the request, result: [\(result)]")
        return true
    }

    private func logRequest(_ request: URLRequest) {
        let bodySize = request.httpBody?.count ?? 0
        let sentSize = (request.url?.absoluteString.count ?? 0) + bodySize
        core.logger.i(Self.module, "logRequest", "sending request, endpoint: [\(request.url?.path ?? "")], method: [\(request.httpMethod ?? "GET")], approximateSentDataSize: [\(sentSize)], bodySize: [\(bodySize)]")

        core.logger.v(Self.module, "logRequest", "request detail, method: [\(request.httpMethod ?? "GET")], URL: [\(request.url?.absoluteString ?? "")], body: [\(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "binary picture upload data")]")
    }

    // MARK: - Sessions

    /// The session used for queued requests. Rebuilt when the configuration
    /// changes, for instance when custom headers are added.
    func session() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if let urlSession { return urlSession }

        let configuration = core.config.urlSessionConfiguration
        configuration.timeoutIntervalForRequest = core.serverConfig.requestTimeoutDuration
        configuration.timeoutIntervalForResource = core.serverConfig.requestTimeoutDuration

        core.logger.d(Self.module, "session", "building the URL session used for queued requests, requestTimeout: [\(core.serverConfig.requestTimeoutDuration.logSeconds)], customHeaderCount: [\(configuration.httpAdditionalHeaders?.count ?? 0)]")

        let session: URLSession
        if !core.config.pinnedCertificates.isEmpty {
            core.logger.d(Self.module, "session", "creating the URL session with certificate pinning, pinnedCertificateCount: [\(core.config.pinnedCertificates.count)]")
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
        urlSession = session
        return session
    }

    /// Session for requests that skip the queue: behavior settings and the health
    /// check. They carry no user data and are useless if delayed behind a backlog.
    func instantSession() -> URLSession {
        sessionLock.lock()
        defer { sessionLock.unlock() }

        if let immediateSession { return immediateSession }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = core.serverConfig.requestTimeoutDuration
        configuration.timeoutIntervalForResource = core.serverConfig.requestTimeoutDuration
        configuration.httpAdditionalHeaders = core.config.urlSessionConfiguration.httpAdditionalHeaders
        // A host that installed a URL protocol, for offline testing or for routing
        // through its own transport, means it for every request the SDK makes. The
        // instant session builds a configuration of its own rather than reusing the
        // supplied one, so anything it should inherit has to be copied explicitly,
        // which is already why the headers above are here.
        configuration.protocolClasses = core.config.urlSessionConfiguration.protocolClasses

        core.logger.d(Self.module, "instantSession", "building the URL session used for unqueued requests, requestTimeout: [\(core.serverConfig.requestTimeoutDuration.logSeconds)], pinnedCertificateCount: [\(core.config.pinnedCertificates.count)]")

        let session: URLSession
        if !core.config.pinnedCertificates.isEmpty {
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        } else {
            session = URLSession(configuration: configuration)
        }
        immediateSession = session
        return session
    }

    /// Adds headers to every request. Rebuilds the session so they take effect.
    func addCustomNetworkRequestHeaders(_ headers: [String: String]?) {
        guard let headers else {
            core.logger.d(Self.module, "addCustomNetworkRequestHeaders", "no custom network request headers are provided, the ones already set are kept")
            return
        }

        var updated = (core.config.urlSessionConfiguration.httpAdditionalHeaders as? [String: String]) ?? [:]
        var skipped = 0
        for (key, value) in headers {
            guard !key.isEmpty else {
                skipped += 1
                core.logger.v(Self.module, "addCustomNetworkRequestHeaders", "a custom network request header with an empty key is skipped")
                continue
            }
            updated[key] = value
        }

        if skipped > 0 {
            core.logger.w(Self.module, "addCustomNetworkRequestHeaders", "some custom network request headers are skipped, reason: empty key, skippedHeaderCount: [\(skipped)]")
        }

        core.logger.i(Self.module, "addCustomNetworkRequestHeaders", "custom network request headers are applied, totalHeaderCount: [\(updated.count)], headerNames: [\(updated.keys.sorted().joined(separator: ", "))]")
        core.config.urlSessionConfiguration.httpAdditionalHeaders = updated
        discardSessions()
    }

    /// Tears down the cached sessions.
    ///
    /// `URLSession` retains its delegate until it is invalidated, and with
    /// certificate pinning configured the delegate is this connection manager,
    /// which holds the core `unowned`. Simply dropping the reference would leave
    /// the session alive, and a later delegate callback would read a core that had
    /// already been released by `halt`. Every session this SDK builds is therefore
    /// invalidated rather than abandoned.
    private func discardSessions() {
        sessionLock.lock()
        let queued = urlSession
        let instant = immediateSession
        urlSession = nil
        immediateSession = nil
        sessionLock.unlock()

        core.logger.d(Self.module, "discardSessions", "the cached URL sessions are invalidated, a request in flight is cancelled and sent again from the queue, hadQueuedSession: [\(queued != nil)], hadInstantSession: [\(instant != nil)]")

        // `finishTasksAndInvalidate` would keep the delegate alive until the
        // in-flight task completes. The queue is what guarantees delivery, not the
        // session, so an interrupted request is re-sent from the queue on the next
        // drain and cancelling costs nothing.
        queued?.invalidateAndCancel()
        instant?.invalidateAndCancel()
    }

    /// Drops cached sessions and pending callbacks. Called from `halt`.
    func reset() {
        core.logger.i(Self.module, "reset", "connection manager is being reset, pending request callbacks and queue flush runnables will be cleared")
        callbackQueue.sync {
            requestCallbacks.removeAll()
            queueFlushRunnables.removeAll()
        }
        stateLock.lock()
        currentTask?.cancel()
        currentTask = nil
        isProcessingQueue = false
        isBackingOff = false
        stateLock.unlock()
        hasAnyRequestFailed = false
        drainStartTime = nil
        discardSessions()
    }
}

/// Reports the outcome of one request to whoever queued it.
public typealias RequestCallback = (_ response: String?, _ success: Bool) -> Void

// MARK: - Certificate pinning

extension ConnectionManager: URLSessionDelegate {

    /// Whether the certificate chain itself is trustworthy.
    private static func evaluate(_ trust: SecTrust, error: inout CFError?) -> Bool {
        if #available(iOS 12.0, tvOS 12.0, macOS 10.14, watchOS 5.0, *) {
            return SecTrustEvaluateWithError(trust, &error)
        }
        var result = SecTrustResultType.invalid
        guard SecTrustEvaluate(trust, &result) == errSecSuccess else { return false }
        return result == .unspecified || result == .proceed
    }

    /// The public key of a trust object, across the deployment range.
    private static func publicKey(of trust: SecTrust) -> SecKey? {
        if #available(iOS 14.0, tvOS 14.0, macOS 11.0, watchOS 7.0, *) {
            return SecTrustCopyKey(trust)
        }
        return SecTrustCopyPublicKey(trust)
    }

    /// Accepts the server only when its public key matches one of the bundled
    /// certificates and the chain itself validates.
    ///
    /// Both checks matter: a matching key with an expired chain, or a valid chain
    /// with an unknown key, are each a reason to refuse.
    public func urlSession(_ session: URLSession,
                           didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            core.logger.d(Self.module, "didReceiveChallenge", "the authentication challenge is cancelled, reason: it carries no server trust to evaluate, authenticationMethod: [\(challenge.protectionSpace.authenticationMethod)]")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let policy = SecPolicyCreateSSL(true, host as CFString)
        let serverKey = Self.publicKey(of: serverTrust)

        var keysMatch = false
        for name in core.config.pinnedCertificates {
            guard let path = Bundle.main.path(forResource: name, ofType: nil),
                  let localData = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let localCert = SecCertificateCreateWithData(nil, localData as CFData) else {
                core.logger.e(Self.module, "didReceiveChallenge", "bundled certificate can not be found or read, certificate: [\(name)]")
                continue
            }

            var localTrust: SecTrust?
            SecTrustCreateWithCertificates(localCert, policy, &localTrust)
            guard let localTrust, let localKey = Self.publicKey(of: localTrust) else { continue }

            if let serverKey, localKey == serverKey {
                core.logger.d(Self.module, "didReceiveChallenge", "pinned certificate and server certificate match, certificate: [\(name)]")
                keysMatch = true
                break
            }
        }

        #if DEBUG
        if core.config.shouldIgnoreTrustCheck, let exceptions = SecTrustCopyExceptions(serverTrust) {
            SecTrustSetExceptions(serverTrust, exceptions)
        }
        #endif

        var error: CFError?
        let chainIsValid = Self.evaluate(serverTrust, error: &error)

        if keysMatch, chainIsValid {
            core.logger.d(Self.module, "didReceiveChallenge", "pinned certificate check is successful, proceeding with the request, host: [\(host)]")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        if !keysMatch {
            core.logger.d(Self.module, "didReceiveChallenge", "pinned certificate and server certificate do not match")
        }
        if !chainIsValid {
            core.logger.d(Self.module, "didReceiveChallenge", "server certificate is not valid, evaluation error: [\(error?.localizedDescription ?? "none")]")
        }

        core.logger.e(Self.module, "didReceiveChallenge", "pinned certificate check failed, cancelling the request, host: [\(host)]")
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

// MARK: - Log gathering

extension ConnectionManager {

    /// Queues one `sdk_logs` batch as its own request. Consent is the caller's
    /// business, which holds the lines back until it is given.
    ///
    /// Returns `false` when the store would drop it, so the caller keeps what it
    /// was about to send.
    func sendSdkLogs(_ payload: String) -> Bool {
        guard enqueueDiagnostic(key: QS.sdkLogs, payload: payload) else {
            core.logger.d(Self.module, "sendSdkLogs", "the gathered log batch is not queued, the instance is halted or tracking is disabled, payloadLength: [\(payload.count)]")
            return false
        }
        core.logger.d(Self.module, "sendSdkLogs", "a gathered log batch is queued, payloadLength: [\(payload.count)]")
        return true
    }
}

// MARK: - Instant requests

extension ConnectionManager: HealthCheckTransport, ServerConfigTransport {

    var isDeviceIDTemporary: Bool {
        core.modules.deviceID.isTemporary
    }

    /// Sends the health check outside the queue.
    func sendHealthCheck(payload: [String: Any], completion: @escaping (Bool, Error?) -> Void) {
        var queryString = builder.queryEssentials()
        queryString += "&hc=\(CountlyJSON.escapedString(from: payload, logger: core.logger))"
        queryString += "&\(QS.metrics)=\(CountlyJSON.escapedString(from: [MetricKey.appVersion: DeviceMetrics.appVersion], logger: core.logger))"
        queryString = builder.appendChecksum(queryString)

        let request = instantRequest(queryString: queryString, path: Endpoint.input)
        core.logger.d(Self.module, "sendHealthCheck", "health check request is prepared, method: [\(request.httpMethod ?? "GET")], queryLength: [\(queryString.count)]")

        instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            let wasAccepted = self.isRequestSuccessful(response: response, data: data, endpoint: Endpoint.input, quiet: true)
            self.core.logger.d(Self.module, "sendHealthCheck", "health check response received, accepted: [\(wasAccepted)], statusCode: [\((response as? HTTPURLResponse)?.statusCode ?? 0)], responseSize: [\(data?.count ?? 0)], errorDescription: [\(error?.localizedDescription ?? "none")]")
            completion(wasAccepted, error)
        }.resume()
    }

    /// Fetches behavior settings outside the queue.
    func fetchServerConfig(completion: @escaping (Data?, Int, Error?) -> Void) {
        var queryString = builder.queryEssentials()
        queryString += "&\(QS.method)=\(ServerConfig.fetchMethod)"
        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        queryString = builder.appendChecksum(queryString)

        let request = instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)
        core.logger.d(Self.module, "fetchServerConfig", "behavior settings request is prepared, method: [\(request.httpMethod ?? "GET")], queryLength: [\(queryString.count)]")

        instantSession().dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            self?.core.logger.d(Self.module, "fetchServerConfig", "behavior settings response received, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], errorDescription: [\(error?.localizedDescription ?? "none")]")
            completion(data, statusCode, error)
        }.resume()
    }

    /// Builds a GET or POST request depending on length, the same rule the queued
    /// path uses.
    func instantRequest(queryString: String, path: String) -> URLRequest {
        let base = core.config.normalizedHost + path

        if queryString.count > kGETRequestMaxLength || core.config.alwaysUsePOST {
            var request = URLRequest(url: Self.requestURL(base))
            request.httpMethod = "POST"
            request.httpBody = Data(queryString.utf8)
            return request
        }

        return URLRequest(url: Self.requestURL("\(base)?\(queryString)"))
    }
}
