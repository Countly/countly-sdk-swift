//
//  APMModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

/// Reports how long things take: network calls, application launch, and whatever
/// the host application chooses to time itself.
final class APMModule: ModuleBase {

    override class var moduleName: String { "APM" }

    /// Keys of a trace payload.
    private enum Key {
        static let type = "type"
        static let network = "network"
        static let device = "device"
        static let name = "name"
        static let metrics = "apm_metrics"
        static let responseTime = "response_time"
        static let responsePayloadSize = "response_payload_size"
        static let responseCode = "response_code"
        static let requestPayloadSize = "request_payload_size"
        static let duration = "duration"
        static let startTime = "stz"
        static let endTime = "etz"
        static let appStart = "app_start"
        static let appInForeground = "app_in_foreground"
        static let appInBackground = "app_in_background"
    }

    private var startedCustomTraces: [String: Int64] = [:]
    private let traceLock = NSLock()

    private var enableForegroundBackgroundTracking = false
    private var enableAppStartTimeTracking = false
    private var enableManualAppLoadedTrigger = false

    /// The app start trace can only be recorded once per launch.
    private var hasRecordedAppStartTrace = false

    /// Tokens for the activation observers this module owns.
    private var activationObservers: [NSObjectProtocol] = []

    /// Process start time used for the app start trace, overridable by config.
    private var appStartTimestamp: Int64 = DeviceMetrics.processStartTimestampMs()

    // MARK: - Init

    func applyInitialConfig() {
        let apm = core.config.apm
        logI("applyInitialConfig", "apm module starting, enableAppStartTimeTracking: [\(apm.enableAppStartTimeTracking)], enableManualAppLoadedTrigger: [\(apm.enableManualAppLoadedTrigger)], enableForegroundBackgroundTracking: [\(apm.enableForegroundBackgroundTracking)]")

        enableAppStartTimeTracking = apm.enableAppStartTimeTracking
        enableManualAppLoadedTrigger = apm.enableManualAppLoadedTrigger
        enableForegroundBackgroundTracking = apm.enableForegroundBackgroundTracking

        if apm.appStartTimestampOverride > 0 {
            logD("applyInitialConfig", "the app start measurement basis is the timestamp supplied in config, appStartTimestampMs: [\(apm.appStartTimestampOverride)], processStartTimestampMs: [\(appStartTimestamp)]")
            appStartTimestamp = apm.appStartTimestampOverride
        } else {
            logD("applyInitialConfig", "the app start measurement basis is the process start time read from the kernel, processStartTimestampMs: [\(appStartTimestamp)]")
        }

        // Without a manual trigger the SDK has no reliable moment to call the
        // launch finished, so the trace would be meaningless.
        if enableAppStartTimeTracking, !enableManualAppLoadedTrigger {
            logW("applyInitialConfig", "automatic app start tracking is not supported, use the manual app loaded trigger by setting config.apm.enableManualAppLoadedTrigger and calling appLoadingFinished()")
        }

        startPerformanceMonitoring()
    }

    // MARK: - Foreground and background traces

    /// Begins timing foreground and background stretches.
    func startPerformanceMonitoring() {
        guard enableForegroundBackgroundTracking else {
            logD("startPerformanceMonitoring", "foreground and background tracking is not enabled in config, tracking will not be started")
            return
        }

        guard core.modules.consent.hasConsent(for: .performanceMonitoring) else {
            logV("startPerformanceMonitoring", "no apm consent given, foreground and background tracking is not started")
            return
        }

        logD("startPerformanceMonitoring", "foreground and background tracking is starting, isActive: [\(AppState.isActive)]")

        observeActivation()

        if AppState.isActive {
            startForegroundTrace()
        } else {
            startBackgroundTrace()
        }
    }

    /// Stops timing and discards whatever was running.
    func stopPerformanceMonitoring() {
        logD("stopPerformanceMonitoring", "foreground and background tracking is being stopped")
        removeActivationObservers()
        clearAllCustomTraces()
    }

    // MARK: - Activation

    /// Watches activation rather than backgrounding, and does so directly.
    ///
    /// The question this module asks is "is the application frontmost", which is
    /// not the question the session asks. Riding on the shared background hook got
    /// both wrong: on iOS the foreground trace stayed open while the application
    /// sat inactive behind an alert or Control Center, and on macOS, where the SDK
    /// deliberately does not observe resigning active for the session's sake, the
    /// trace was opened once and never closed at all.
    private func observeActivation() {
        guard activationObservers.isEmpty else {
            logD("observeActivation", "activation observers are already installed, nothing to do, observerCount: [\(activationObservers.count)]")
            return
        }

        #if os(iOS) || os(tvOS) || os(visionOS)
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in self?.startForegroundTrace() }
        observe(UIApplication.willResignActiveNotification) { [weak self] in self?.startBackgroundTrace() }
        #elseif os(macOS)
        observe(NSApplication.didBecomeActiveNotification) { [weak self] in self?.startForegroundTrace() }
        observe(NSApplication.willResignActiveNotification) { [weak self] in self?.startBackgroundTrace() }
        #endif

        logD("observeActivation", "activation observers installed for the foreground and background traces, observerCount: [\(activationObservers.count)]")
    }

    private func observe(_ name: Notification.Name, handler: @escaping () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            handler()
        }
        activationObservers.append(token)
    }

    private func removeActivationObservers() {
        for token in activationObservers {
            NotificationCenter.default.removeObserver(token)
        }
        activationObservers.removeAll()
    }

    private func startForegroundTrace() {
        guard enableForegroundBackgroundTracking else { return }
        logD("startForegroundTrace", "the app became active, the background stretch is closed and a foreground stretch is opened")
        endBackgroundTrace()
        startCustomTrace(Key.appInForeground)
    }

    private func endForegroundTrace() {
        guard enableForegroundBackgroundTracking else { return }
        endCustomTrace(Key.appInForeground, metrics: nil)
    }

    private func startBackgroundTrace() {
        guard enableForegroundBackgroundTracking else { return }
        logD("startBackgroundTrace", "the app resigned active, the foreground stretch is closed and a background stretch is opened")
        endForegroundTrace()
        startCustomTrace(Key.appInBackground)
    }

    /// Ends the background stretch. Also called at termination, so the last
    /// background stretch is not lost.
    func endBackgroundTrace() {
        guard enableForegroundBackgroundTracking else { return }
        endCustomTrace(Key.appInBackground, metrics: nil)
    }

    // MARK: - App start

    /// Marks the application as fully loaded, closing the app start trace.
    func appLoadingFinished() {
        logI("appLoadingFinished", "the host application reported that loading has finished")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        recordAppStartDurationTrace(startTime: appStartTimestamp, endTime: now)
    }

    private func recordAppStartDurationTrace(startTime: Int64, endTime: Int64) {
        logI("recordAppStartDurationTrace", "app start duration trace recording requested, startTimeMs: [\(startTime)], endTimeMs: [\(endTime)]")

        guard core.modules.consent.hasConsent(for: .performanceMonitoring) else {
            logV("recordAppStartDurationTrace", "no apm consent given, app start duration trace is not recorded")
            return
        }

        guard enableAppStartTimeTracking, enableManualAppLoadedTrigger else {
            logD("recordAppStartDurationTrace", "app start duration trace is dropped, set enableAppStartTimeTracking and enableManualAppLoadedTrigger in config to record it")
            return
        }

        guard !hasRecordedAppStartTrace else {
            logW("recordAppStartDurationTrace", "app start duration trace is dropped, it can only be recorded once per app launch")
            return
        }

        // Both ends are wall clock readings, so a negative value means the app
        // start timestamp override is in the future or the clock moved backwards
        // between them. Either way what reaches the dashboard is wrong.
        let duration = endTime - startTime
        if duration < 0 {
            logW("recordAppStartDurationTrace", "app start duration is negative, it will still be recorded, durationMs: [\(duration)]")
        }

        logD("recordAppStartDurationTrace", "app start trace recorded, traceName: [\(Key.appStart)], durationMs: [\(duration)]")

        send(trace: [
            Key.type: Key.device,
            Key.name: Key.appStart,
            Key.metrics: [Key.duration: duration],
            Key.startTime: startTime,
            Key.endTime: endTime,
        ])

        hasRecordedAppStartTrace = true
    }

    // MARK: - Network traces

    /// Reports one network call the host application made.
    func recordNetworkTrace(_ traceName: String,
                            requestPayloadSize: Int,
                            responsePayloadSize: Int,
                            responseStatusCode: Int,
                            startTime: Int64,
                            endTime: Int64) {
        logI("recordNetworkTrace", "network trace recording requested, traceName: [\(traceName)], requestPayloadSize: [\(requestPayloadSize)], responsePayloadSize: [\(responsePayloadSize)], responseStatusCode: [\(responseStatusCode)], startTimeMs: [\(startTime)], endTimeMs: [\(endTime)]")

        guard core.modules.consent.hasConsent(for: .performanceMonitoring) else {
            logV("recordNetworkTrace", "no apm consent given, network trace is not recorded")
            return
        }

        guard !traceName.isEmpty else {
            logE("recordNetworkTrace", "network trace is dropped, trace name is empty or nil")
            return
        }

        // Both ends come from the host application, so a negative value is a
        // caller passing the two timestamps the wrong way round.
        let responseTime = endTime - startTime
        if responseTime < 0 {
            logW("recordNetworkTrace", "network trace response time is negative, the start and end timestamps are likely swapped, traceName: [\(traceName)], responseTimeMs: [\(responseTime)]")
        }

        let truncatedName = limits.truncatedKey(traceName, "Network trace name")

        logD("recordNetworkTrace", "network trace recorded, traceName: [\(truncatedName)], responseTimeMs: [\(responseTime)]")

        send(trace: [
            Key.type: Key.network,
            Key.name: truncatedName,
            Key.metrics: [
                Key.requestPayloadSize: requestPayloadSize,
                Key.responseTime: responseTime,
                Key.responseCode: responseStatusCode,
                Key.responsePayloadSize: responsePayloadSize,
            ],
            Key.startTime: startTime,
            Key.endTime: endTime,
        ])
    }

    // MARK: - Custom traces

    /// Starts timing something the host application names.
    func startCustomTrace(_ traceName: String) {
        logI("startCustomTrace", "custom trace start requested, traceName: [\(traceName)]")

        guard core.modules.consent.hasConsent(for: .performanceMonitoring) else {
            logV("startCustomTrace", "no apm consent given, custom trace is not started")
            return
        }

        guard !traceName.isEmpty else {
            logE("startCustomTrace", "custom trace start is dropped, trace name is empty or nil")
            return
        }

        traceLock.lock()
        defer { traceLock.unlock() }

        guard startedCustomTraces[traceName] == nil else {
            logW("startCustomTrace", "custom trace start is ignored, a trace with the same name is already running, traceName: [\(traceName)]")
            return
        }

        startedCustomTraces[traceName] = core.clock.nowMs()
        logD("startCustomTrace", "custom trace started, traceName: [\(traceName)], runningTraceCount: [\(startedCustomTraces.count)]")
    }

    /// Ends a custom trace and reports its duration plus any metrics.
    func endCustomTrace(_ traceName: String, metrics: [String: Any]?) {
        logI("endCustomTrace", "custom trace end requested, traceName: [\(traceName)], metricCount: [\(metrics?.count ?? 0)]")

        guard core.modules.consent.hasConsent(for: .performanceMonitoring) else {
            logV("endCustomTrace", "no apm consent given, custom trace is not ended")
            return
        }

        guard !traceName.isEmpty else {
            logE("endCustomTrace", "custom trace end is dropped, trace name is empty or nil")
            return
        }

        traceLock.lock()
        let startTime = startedCustomTraces.removeValue(forKey: traceName)
        traceLock.unlock()

        guard let startTime else {
            logW("endCustomTrace", "custom trace end is a no-op, no running trace with this name, traceName: [\(traceName)]")
            return
        }

        let truncatedName = limits.truncatedKey(traceName, "Custom trace name")
        var payloadMetrics = limits.sanitized(metrics, "Custom trace metric") ?? [:]

        let endTime = core.clock.nowMs()
        let duration = endTime - startTime
        payloadMetrics[Key.duration] = duration

        // Both ends come from the SDK's own strictly increasing clock, so this is
        // unreachable unless that clock is replaced. Kept as a guard, and kept at
        // debug: nothing an integration did could cause it, so it must not spend a
        // health check warning.
        if duration < 0 {
            logD("endCustomTrace", "custom trace duration is negative, it will still be recorded, traceName: [\(truncatedName)], durationMs: [\(duration)]")
        }

        logD("endCustomTrace", "custom trace ended, traceName: [\(truncatedName)], durationMs: [\(duration)], metricCount: [\(payloadMetrics.count)]")

        send(trace: [
            Key.type: Key.device,
            Key.name: truncatedName,
            Key.metrics: payloadMetrics,
            Key.startTime: startTime,
            Key.endTime: endTime,
        ])
    }

    /// Discards a running trace without reporting it.
    func cancelCustomTrace(_ traceName: String) {
        logI("cancelCustomTrace", "custom trace cancellation requested, traceName: [\(traceName)]")

        guard core.modules.consent.hasConsent(for: .performanceMonitoring) else {
            logV("cancelCustomTrace", "no apm consent given, custom trace is not cancelled")
            return
        }

        guard !traceName.isEmpty else {
            logE("cancelCustomTrace", "custom trace cancellation is dropped, trace name is empty or nil")
            return
        }

        traceLock.lock()
        let removed = startedCustomTraces.removeValue(forKey: traceName)
        let remaining = startedCustomTraces.count
        traceLock.unlock()

        guard removed != nil else {
            logD("cancelCustomTrace", "custom trace cancellation is a no-op, no running trace with this name, traceName: [\(traceName)]")
            return
        }

        logD("cancelCustomTrace", "custom trace cancelled, its duration is discarded, traceName: [\(traceName)], runningTraceCount: [\(remaining)]")
    }

    /// Discards every running trace.
    func clearAllCustomTraces() {
        traceLock.lock()
        defer { traceLock.unlock() }
        logD("clearAllCustomTraces", "clearing all running custom traces, they were started and never ended, runningTraceCount: [\(startedCustomTraces.count)], traceNames: [\(startedCustomTraces.keys.sorted().joined(separator: ", "))]")
        startedCustomTraces.removeAll()
    }

    // MARK: - Wire

    private func send(trace: [String: Any]) {
        logD("send", "apm trace request is being queued, traceType: [\(trace[Key.type] as? String ?? "")], traceName: [\(trace[Key.name] as? String ?? "")]")

        let queryString = "\(core.network.builder.queryEssentials())&\(QS.apm)=\(CountlyJSON.escapedString(from: trace, logger: log))"
        core.network.enqueueAndProceed(queryString)
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        logD("halt", "apm module halting, the activation observers are removed and every running trace is discarded")
        removeActivationObservers()
        clearAllCustomTraces()
        hasRecordedAppStartTrace = false
    }
}
