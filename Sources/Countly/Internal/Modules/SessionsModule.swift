//
//  SessionsModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Reports when the application is being used and for how long.
///
/// A session is three requests: `begin_session`, periodic `session_duration`
/// updates while the application is in the foreground, and `end_session` with the
/// remaining duration. The server stitches them together, so sending them out of
/// order or twice produces a wrong session length.
final class SessionsModule: ModuleBase {

    override class var moduleName: String { "Sessions" }

    /// Whether a session is currently open.
    private(set) var isSessionStarted = false

    /// When the current stretch of foreground time began.
    private var lastSessionStartTime: TimeInterval = 0

    /// Sub-second remainder carried between updates, so a series of updates does
    /// not lose a fraction of a second each time.
    private var unsentSessionLength: TimeInterval = 0

    /// Whether the SDK is suspended, which happens on background and around a
    /// device ID change.
    private var isSuspended = false

    /// Drives the periodic session update.
    private var updateTimer: Timer?

    /// The interval the running timer was built with, so a behavior settings change
    /// can be told apart from a no-op.
    private var scheduledUpdatePeriod: TimeInterval = 0

    #if os(watchOS)
    /// watchOS delivers a "became active" notification during launch, which would
    /// otherwise begin a second session on top of the one init just began.
    ///
    /// Process-wide rather than per instance, because what it suppresses is a
    /// property of the launch. A per-instance flag is reset by `start(with:)`, so
    /// halting and re-initialising inside one process would swallow a real resume
    /// and leave the SDK with no open session until the next one.
    private static var hasSkippedFirstResume = false
    #endif

    // MARK: - Timer

    /// Starts the session update timer. Called at the end of init.
    func startUpdateTimer() {
        stopUpdateTimer()

        let period = core.config.updateSessionPeriod
        let timer = Timer(timeInterval: period, repeats: true) { [weak self] _ in
            self?.onUpdateTimer()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateTimer = timer
        scheduledUpdatePeriod = period
        logD("startUpdateTimer", "session update timer scheduled, updatePeriodSeconds: [\(period.logSeconds)]")
    }

    /// Rebuilds the timer when the behavior settings change its interval.
    ///
    /// The interval arrives from the server as `sui`, and a timer built once at
    /// init keeps the interval the SDK started with until the next launch. A
    /// server that lowers the interval to reduce data loss, or raises it to reduce
    /// traffic, expects the change to take effect now.
    func applyUpdatePeriodIfChanged() {
        guard updateTimer != nil else {
            logD("applyUpdatePeriodIfChanged", "the session update timer is not running, the new update period will be picked up when it starts, updatePeriodSeconds: [\(core.config.updateSessionPeriod.logSeconds)]")
            return
        }
        guard core.config.updateSessionPeriod != scheduledUpdatePeriod else { return }

        logD("applyUpdatePeriodIfChanged", "behavior settings changed the session update period, the timer will be rebuilt, previousPeriodSeconds: [\(scheduledUpdatePeriod.logSeconds)], newPeriodSeconds: [\(core.config.updateSessionPeriod.logSeconds)]")
        startUpdateTimer()
    }

    func stopUpdateTimer() {
        guard updateTimer != nil else { return }

        logD("stopUpdateTimer", "session update timer invalidated, scheduledPeriodSeconds: [\(scheduledUpdatePeriod.logSeconds)]")
        updateTimer?.invalidate()
        updateTimer = nil
    }

    /// Sends whatever is due on each tick.
    ///
    /// Nothing is sent while suspended: `suspend` has already flushed the events
    /// and closed the session, and a tick landing afterwards would reopen work the
    /// SDK just finished.
    private func onUpdateTimer() {
        // Every tick uploads the gathered log lines too, for a buffer that never
        // reaches the batch size.
        core.logGatherer.scheduleFlush()

        guard !isSuspended else {
            logD("onUpdateTimer", "the SDK is suspended, this session update tick will be skipped entirely")
            return
        }

        if core.serverConfig.automaticSessionTrackingEnabled || core.config.enableManualSessionControlHybridMode {
            updateSession()
        } else {
            logD("onUpdateTimer", "sessions are driven manually and hybrid mode is off, this tick will only flush events")
        }

        core.modules.events.sendEventsWithSaveIfNeeded()
    }

    // MARK: - Session lifecycle

    /// Opens a session.
    func beginSession() {
        logI("beginSession", "session begin requested, isSessionStarted: [\(isSessionStarted)], automaticSessionTracking: [\(core.serverConfig.automaticSessionTrackingEnabled)]")

        guard core.modules.consent.hasConsent(for: .sessions) else {
            logV("beginSession", "no consent for sessions, no session will be started")
            return
        }

        guard core.serverConfig.sessionTrackingEnabled else {
            logD("beginSession", "session tracking is disabled by behavior settings, no session will be started")
            return
        }

        guard !isSessionStarted else {
            logW("beginSession", "a session is already running, this session begin will be ignored")
            return
        }

        // A session begun while the application is in the background would report
        // time the user never spent in the app.
        if core.serverConfig.automaticSessionTrackingEnabled, !AppState.isForeground {
            logD("beginSession", "app is in the background, the automatic session will not be started")
            return
        }

        if core.modules.userProfile.hasUnsyncedChanges {
            logD("beginSession", "unsynced user profile changes will be sent before the session begins")
            core.modules.userProfile.save()
        }

        isSessionStarted = true
        lastSessionStartTime = Date().timeIntervalSince1970
        unsentSessionLength = 0

        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.sessionBegin)=1"
        queryString += "&\(QS.metrics)=\(CountlyJSON.escapedString(from: core.metricsDictionary(), logger: log))"

        if !core.serverConfig.locationTrackingEnabled {
            logD("beginSession", "location tracking is disabled by behavior settings, the begin session request will carry no location")
        } else if let locationQuery = core.network.builder.locationQueryString() {
            queryString += locationQuery
            logD("beginSession", "location information will be sent with the begin session request")
        } else {
            logD("beginSession", "no location information is set, the begin session request will carry none")
        }

        logD("beginSession", "session opened, the begin session request will be queued, isForeground: [\(AppState.isForeground)]")

        core.network.enqueue(queryString)
        core.modules.views.recordOrientation()
        core.network.proceedOnQueue()
    }

    /// Reports the time elapsed since the last update.
    func updateSession() {
        logI("updateSession", "session update requested, isSessionStarted: [\(isSessionStarted)]")

        guard core.modules.consent.hasConsent(for: .sessions) else {
            logV("updateSession", "no consent for sessions, the session duration will not be updated")
            return
        }

        guard core.serverConfig.sessionTrackingEnabled else {
            logD("updateSession", "session tracking is disabled by behavior settings, the session duration will not be updated")
            return
        }

        guard isSessionStarted else {
            logD("updateSession", "no session is running, this session update will be ignored")
            return
        }

        if core.modules.userProfile.hasUnsyncedChanges {
            logD("updateSession", "unsynced user profile changes will be sent before the session update")
            core.modules.userProfile.save()
        }

        let duration = sessionLengthInSeconds()
        logD("updateSession", "session duration update will be queued, durationSeconds: [\(duration)], carriedRemainderSeconds: [\(unsentSessionLength.logSeconds)]")

        core.network.enqueueAndProceed("\(core.network.builder.queryEssentials())&\(QS.sessionDuration)=\(duration)")
    }

    /// Closes the session, reporting the remaining duration.
    func endSession() {
        logI("endSession", "session end requested, isSessionStarted: [\(isSessionStarted)]")

        guard core.modules.consent.hasConsent(for: .sessions) else {
            logV("endSession", "no consent for sessions, the session will not be ended")
            return
        }

        guard core.serverConfig.sessionTrackingEnabled else {
            logD("endSession", "session tracking is disabled by behavior settings, the session will not be ended")
            return
        }

        guard isSessionStarted else {
            logD("endSession", "no session is running, this session end will be ignored")
            return
        }

        isSessionStarted = false

        let duration = sessionLengthInSeconds()
        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.sessionEnd)=1"
        queryString += "&\(QS.sessionDuration)=\(duration)"

        logD("endSession", "session closed, the end session request will be queued, durationSeconds: [\(duration)]")

        core.network.enqueueAndProceed(queryString)
        core.modules.views.resetFirstView()
    }

    /// Whole seconds since the last read, keeping the remainder for the next one.
    private func sessionLengthInSeconds() -> Int {
        let now = Date().timeIntervalSince1970
        unsentSessionLength += (now - lastSessionStartTime)
        lastSessionStartTime = now

        let whole = Int(unsentSessionLength)
        unsentSessionLength -= TimeInterval(whole)
        return whole
    }

    // MARK: - Suspend and resume

    /// Stops tracking and flushes everything to disk.
    ///
    /// Called on background and around a device ID change. Everything recorded is
    /// pushed out first, because the process may not come back.
    func suspend() {
        logI("suspend", "suspending the SDK, isSuspended: [\(isSuspended)]")

        #if os(watchOS)
        // The only lifecycle signal this platform gives before watchOS 7. Applied
        // before the guards below so the state is right even when the suspend
        // itself is a no-op.
        AppState.setActive(false)
        #endif

        guard core.hasStarted else {
            logD("suspend", "omitting the suspend, the SDK has not been started yet")
            return
        }

        guard !isSuspended else {
            logD("suspend", "the SDK is already suspended, nothing left to do")
            return
        }

        logD("suspend", "flushing events and saving the state before suspend, automaticSessions: [\(core.serverConfig.automaticSessionTrackingEnabled)]")

        isSuspended = true

        core.modules.views.applicationDidEnterBackground()
        core.modules.events.sendEventsWithSaveIfNeeded()

        if core.serverConfig.automaticSessionTrackingEnabled {
            endSession()
        } else {
            logD("suspend", "sessions are driven manually, the running session will be left open across the background")
        }

        core.requestQueueStore.save()
    }

    /// Restarts tracking after a suspend.
    func resume() {
        logI("resume", "resuming the SDK, isSuspended: [\(isSuspended)]")

        #if os(watchOS)
        AppState.setActive(true)
        #endif

        guard core.hasStarted else {
            logD("resume", "omitting the resume, the SDK has not been started yet")
            return
        }

        #if os(watchOS)
        if !SessionsModule.hasSkippedFirstResume {
            SessionsModule.hasSkippedFirstResume = true
            logD("resume", "skipping the first resume on watchOS to avoid a duplicate begin session")
            // Suspension is not entered on this path, so the state stays consistent
            // with an application that is in fact active.
            isSuspended = false
            return
        }
        #endif

        logD("resume", "restarting session handling after resume, automaticSessions: [\(core.serverConfig.automaticSessionTrackingEnabled)]")

        if core.serverConfig.automaticSessionTrackingEnabled {
            beginSession()
        } else {
            logD("resume", "sessions are driven manually, no session will be started on resume, hybridMode: [\(core.config.enableManualSessionControlHybridMode)]")
        }

        core.modules.views.applicationWillEnterForeground()
        isSuspended = false
    }

    // MARK: - Lifecycle

    override func didEnterForeground() {
        logD("didEnterForeground", "app entered foreground, behavior settings will be refreshed and the SDK resumed")
        core.serverConfig.fetchIfTimeIsUp(config: core.config)
        resume()
    }

    override func didEnterBackground() {
        logD("didEnterBackground", "app entered background, the health check state will be saved and the SDK suspended")
        core.healthTracker.saveState()
        suspend()
    }

    override func halt(clearStorage: Bool) {
        logD("halt", "sessions module is halting, the session state will be dropped without an end session request, isSessionStarted: [\(isSessionStarted)], unsentSessionLengthSeconds: [\(unsentSessionLength.logSeconds)]")
        stopUpdateTimer()
        isSessionStarted = false
        isSuspended = false
        unsentSessionLength = 0
        lastSessionStartTime = 0
    }
}
