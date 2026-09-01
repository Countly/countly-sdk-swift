//
//  CountlyInstance.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// One Countly SDK, reporting to one app key on one server.
///
/// Everything an instance owns is its own: storage, device ID, request queue,
/// timers, log level, and its lifecycle observation. Two instances in the same
/// application cannot see each other's data, which is what makes reporting the
/// same session to two servers, or two tenants to the same server, possible.
///
/// Obtained from `Countly.shared` or `Countly.instance(named:)`, never
/// constructed directly.
public final class CountlyInstance {

    private static let module = "Countly"

    /// Registry key of this instance.
    public let name: String

    /// Built by `start(with:)` and released by `halt()`.
    private var core: SDKCore?
    private var lifecycleObserver: LifecycleObserver?

    /// Guards the start and halt transitions, which can be reached from any
    /// thread.
    private let lifecycleLock = NSRecursiveLock()

    // MARK: - Feature facades

    /// Custom events.
    public private(set) lazy var events = EventsAPI(instance: self)

    /// Sessions.
    public private(set) lazy var sessions = SessionsAPI(instance: self)

    /// View tracking.
    public private(set) lazy var views = ViewsAPI(instance: self)

    /// The user profile.
    public private(set) lazy var userProfile = UserProfileAPI(instance: self)

    /// Consent.
    public private(set) lazy var consent = ConsentAPI(instance: self)

    /// The device ID.
    public private(set) lazy var deviceID = DeviceIDAPI(instance: self)

    /// Location.
    public private(set) lazy var location = LocationAPI(instance: self)

    /// Crash reporting.
    public private(set) lazy var crashes = CrashesAPI(instance: self)

    /// Remote config and A/B testing.
    public private(set) lazy var remoteConfig = RemoteConfigAPI(instance: self)

    /// Attribution.
    public private(set) lazy var attribution = AttributionAPI(instance: self)

    /// Performance monitoring.
    public private(set) lazy var performance = APMAPI(instance: self)

    /// Feedback widgets.
    public private(set) lazy var feedback = FeedbackAPI(instance: self)

    /// Content zone.
    public private(set) lazy var content = ContentAPI(instance: self)

    /// Push notifications.
    public private(set) lazy var push = PushAPI(instance: self)

    /// The request queue.
    public private(set) lazy var requestQueue = RequestQueueAPI(instance: self)

    // MARK: - Init

    init(name: String) {
        self.name = name
    }

    /// Whether this instance has been started and not halted.
    public var isStarted: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return core?.hasStarted ?? false
    }

    /// Internal access for the facades. `nil` before `start(with:)`.
    func requireCore(_ function: String = #function) -> SDKCore? {
        lifecycleLock.lock()
        let current = core
        lifecycleLock.unlock()

        guard let current, current.hasStarted else {
            // Deliberately printed rather than logged: without a core there is no
            // logger, and a call before init is exactly the mistake worth seeing.
            Logger.print("[Warning] [\(Self.module)] \(function), the SDK has not been started yet, the call is ignored")
            return nil
        }
        return current
    }

    // MARK: - Starting

    /// Starts the SDK.
    ///
    /// A second call is ignored rather than restarting: an already running
    /// instance has a session open and a queue in flight, and tearing that down
    /// silently would lose data.
    public func start(with config: CountlyConfig) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if let core, core.hasStarted {
            core.logger.w(Self.module, "start", "omitting the call, the SDK has already been started")
            return
        }

        // Validated before anything is built, so a misconfigured start leaves no
        // half-initialized state behind.
        if let failure = config.validate() {
            Logger.print("[Error] [\(Self.module)] start, \(failure.message)")
            return
        }

        // An instance name in the config is advisory: the registry key decides
        // where data lives. A mismatch is worth saying out loud, because the
        // developer probably expected the config to win.
        if let configName = config.instanceName, !configName.isEmpty, configName != name {
            Logger.print("[Warning] [\(Self.module)] start, the instance name in the config does not match the name this instance was created with, configName: [\(configName)], instanceName: [\(name)]")
        }

        config.sdkInternalLimits.clampToMinimums()

        let builtCore = SDKCore(instanceName: name, config: config)
        builtCore.hasStarted = true
        self.core = builtCore

        build(core: builtCore)
        configure(core: builtCore, with: config)
    }

    /// Wires the object graph.
    private func build(core: SDKCore) {
        let builder = RequestBuilder(core: core)
        let network = ConnectionManager(core: core, builder: builder)

        let modules = ModuleRegistry(
            consent: ConsentModule(core: core),
            deviceID: DeviceIDModule(core: core),
            events: EventsModule(core: core),
            sessions: SessionsModule(core: core),
            views: ViewsModule(core: core),
            userProfile: UserProfileModule(core: core),
            location: LocationModule(core: core),
            crashes: CrashModule(core: core),
            remoteConfig: RemoteConfigModule(core: core),
            attribution: AttributionModule(core: core),
            apm: APMModule(core: core),
            feedback: FeedbackModule(core: core),
            content: ContentModule(core: core),
            push: PushModule(core: core))

        core.attach(network: network, modules: modules)

        core.healthTracker.transport = network
        core.serverConfig.transport = network
        core.serverConfig.delegate = self
    }

    /// Applies the config in the order the features depend on each other.
    private func configure(core: SDKCore, with config: CountlyConfig) {
        let modules = core.modules!
        let logger = core.logger

        // Behavior settings first: they can change limits, queue sizes and whether
        // features are allowed at all, and everything below reads those.
        if config.disableSDKBehaviorSettingsUpdates {
            core.serverConfig.disableUpdates()
        }
        core.serverConfig.retrieveFromStorage(config: config)
        core.refreshLimits()

        modules.consent.requiresConsent = config.requiresConsent

        logger.i(Self.module, "start", "initializing, appKey: [\(config.appKey)], serverUrl: [\(config.normalizedHost)], instanceName: [\(name)], sdkName: [\(SDKIdentity.name)], sdkVersion: [\(SDKIdentity.version)], device: [\(DeviceMetrics.device)], osName: [\(DeviceMetrics.osName ?? "")], osVersion: [\(DeviceMetrics.osVersion ?? "")]")

        // Logged after the stored behavior settings were merged in, so these are
        // the values the SDK will actually run with rather than the ones the
        // developer passed. A value the server overrode is the usual reason an
        // integration does not behave the way its config reads.
        logger.i(Self.module, "start", "tracking configuration in effect, requiresConsent: [\(config.requiresConsent)], enableAllConsents: [\(config.enableAllConsents)], initialConsentCount: [\(config.consents.count)], manualSessionHandling: [\(config.manualSessionHandling)], hybridSessionMode: [\(config.enableManualSessionControlHybridMode)], automaticViewTracking: [\(config.enableAutomaticViewTracking)], viewTrackingExclusionCount: [\(config.automaticViewTrackingExclusionList.count)], orientationTracking: [\(config.enableOrientationTracking)], updateSessionPeriod: [\(config.updateSessionPeriod.logSeconds)], eventSendThreshold: [\(config.eventSendThreshold)], enableDebug: [\(config.enableDebug)], internalLogLevel: [\(config.internalLogLevel.label)]")

        logger.i(Self.module, "start", "networking configuration in effect, storedRequestsLimit: [\(config.storedRequestsLimit)], requestDropAgeHours: [\(config.requestDropAgeHours)], requestTimeoutDuration: [\(config.requestTimeoutDuration.logSeconds)], alwaysUsePOST: [\(config.alwaysUsePOST)], customNetworkRequestHeaderCount: [\(config.customNetworkRequestHeaders?.count ?? 0)], pinnedCertificateCount: [\(config.pinnedCertificates.count)], secretSaltConfigured: [\(config.secretSalt?.isEmpty == false)], customMetricCount: [\(config.customMetrics.count)], temporaryDeviceIDMode: [\(config.temporaryDeviceIDMode)], deviceIDProvided: [\(config.deviceID != nil)], resetStoredDeviceID: [\(config.resetStoredDeviceID)], behaviorSettingsUpdatesDisabled: [\(config.disableSDKBehaviorSettingsUpdates)], backoffMechanismDisabled: [\(config.disableBackoffMechanism)], features: [\(config.features.map { "\($0)" }.joined(separator: ", "))]")

        logger.d(Self.module, "start", "behavior settings in effect, trackingEnabled: [\(core.serverConfig.trackingEnabled)], networkingEnabled: [\(core.serverConfig.networkingEnabled)], sessionTracking: [\(core.serverConfig.sessionTrackingEnabled)], automaticSessionTracking: [\(core.serverConfig.automaticSessionTrackingEnabled)], viewTracking: [\(core.serverConfig.viewTrackingEnabled)], automaticViewTracking: [\(core.serverConfig.automaticViewTrackingEnabled)], crashReporting: [\(core.serverConfig.crashReportingEnabled)], automaticCrashReporting: [\(core.serverConfig.automaticCrashReportingEnabled)], locationTracking: [\(core.serverConfig.locationTrackingEnabled)], customEventTracking: [\(core.serverConfig.customEventTrackingEnabled)], backoffMechanism: [\(core.serverConfig.backoffMechanism)], consentRequired: [\(core.serverConfig.consentRequired)]")

        logger.d(Self.module, "start", "SDK internal limits in effect, maxKeyLength: [\(config.sdkInternalLimits.maxKeyLength)], maxValueSize: [\(config.sdkInternalLimits.maxValueSize)], maxValueSizePicture: [\(config.sdkInternalLimits.maxValueSizePicture)], maxSegmentationValues: [\(config.sdkInternalLimits.maxSegmentationValues)], maxBreadcrumbCount: [\(config.sdkInternalLimits.maxBreadcrumbCount)], maxStackTraceLineLength: [\(config.sdkInternalLimits.maxStackTraceLineLength)], maxStackTraceLinesPerThread: [\(config.sdkInternalLimits.maxStackTraceLinesPerThread)]")

        // The device ID must exist before any request is built.
        modules.deviceID.initialize(with: config)

        core.requestQueueStore.storedRequestsLimit = Swift.max(1, config.storedRequestsLimit)
        core.requestQueueStore.requestDropAgeHours = config.requestDropAgeHours

        core.network.addCustomNetworkRequestHeaders(config.customNetworkRequestHeaders)

        if let provided = config.providedUserProperties, !provided.isEmpty {
            logger.i(Self.module, "start", "applying the user properties provided at init, count: [\(provided.count)]")
            modules.userProfile.setProperties(provided)
        }
        modules.userProfile.save()

        core.serverConfig.fetch(config: config)

        // Seeded before anything can consult it. `beginSession` below refuses to
        // open a session while the application is in the background, and the
        // lifecycle observer that seeds this is installed much further down, so
        // without this the flag would still be its optimistic default and a launch
        // straight into the background would open a session for time the user
        // never spent in the application. Idempotent, so the later install is a
        // no-op.
        AppState.startObserving()

        modules.location.applyInitialConfig()
        modules.crashes.applyInitialConfig()

        // Automatic session tracking is resolved through the behavior settings
        // chain, so the server can override the developer's manual choice.
        if core.serverConfig.automaticSessionTrackingEnabled {
            modules.sessions.beginSession()
        } else {
            modules.views.recordOrientation()
        }

        modules.push.applyInitialConfig()

        // Installed here rather than left to `applyAutomaticTrackingState` at the
        // end of init: everything between the two points, including each module's
        // `didInit` and the first drain of the queue, would otherwise run with no
        // crash handler in place. The call is idempotent, so the later pass is
        // still what applies a behavior settings change.
        if core.serverConfig.crashReportingEnabled, core.serverConfig.automaticCrashReportingEnabled {
            modules.crashes.startCrashReporting()
        }

        if !config.automaticViewTrackingExclusionList.isEmpty {
            modules.views.addAutoViewTrackingExclusionList(config.automaticViewTrackingExclusionList)
        }

        if config.disableViewRestartForManualRecording {
            modules.views.isManualViewRestartActive = false
        }

        if let globalViewSegmentation = config.globalViewSegmentation {
            modules.views.setGlobalViewSegmentation(globalViewSegmentation)
        }

        modules.sessions.startUpdateTimer()
        modules.remoteConfig.applyInitialConfig()
        modules.remoteConfig.downloadRemoteConfigAutomatically()
        modules.apm.applyInitialConfig()

        installLifecycleObserver(core: core)

        core.network.proceedOnQueue()

        // Consent last, so the requests it triggers carry the fully configured
        // state.
        if config.enableAllConsents {
            modules.consent.giveAllConsents()
        } else if !config.consents.isEmpty {
            modules.consent.giveConsent(for: config.consents)
        } else if config.requiresConsent {
            modules.consent.sendConsents()
        }

        // Without session consent nothing carried location or attribution along,
        // so they are sent on their own.
        if !modules.consent.hasConsent(for: .sessions) {
            if !modules.consent.hasConsent(for: .location) || modules.location.isLocationInfoDisabled {
                modules.location.sendLocationRequest()
            } else {
                modules.location.sendLocationInfo()
            }
            modules.attribution.sendIndirectAttributionIfAvailable()
        }

        modules.attribution.applyInitialConfig()

        core.healthTracker.sendHealthCheck(isDeviceIDTemporary: modules.deviceID.isTemporary,
                                           networkingEnabled: core.serverConfig.networkingEnabled)

        core.hasFinishedInit = true

        for module in modules.all {
            module.didInit()
        }

        // The behavior settings answer can arrive before init finishes, in which
        // case it deliberately left automatic tracking alone. Now that the
        // configuration is complete the resolved values are applied, so a server
        // side view or crash setting is never silently dropped.
        applyAutomaticTrackingState(core: core)
    }

    // MARK: - Lifecycle observation

    private func installLifecycleObserver(core: SDKCore) {
        let observer = LifecycleObserver(core: core)

        observer.onForeground = { [weak self] in
            guard let self, let core = self.core else { return }
            for module in core.modules.all { module.didEnterForeground() }
        }

        observer.onBackground = { [weak self] in
            guard let self, let core = self.core else { return }
            for module in core.modules.all { module.didEnterBackground() }
        }

        observer.onWillResignActive = { [weak self] in
            self?.core?.healthTracker.saveState()
        }

        observer.onWillTerminate = { [weak self] in
            self?.handleTermination()
        }

        observer.onOrientationChange = { [weak self] in
            self?.core?.modules.views.recordOrientation()
        }

        observer.register()
        lifecycleObserver = observer
    }

    /// Flushes everything synchronously, because the process is about to end.
    private func handleTermination() {
        guard let core else { return }
        core.logger.d(Self.module, "willTerminate", "the app will terminate, flushing events and saving the state synchronously")

        core.healthTracker.saveState()
        core.isTerminating = true
        core.modules.views.applicationWillTerminate()
        core.modules.events.sendEventsWithSaveIfNeeded()
        core.modules.apm.endBackgroundTrace()
        core.requestQueueStore.saveSync()
    }

    // MARK: - Integration-wide operations

    /// Points the SDK at a different server.
    ///
    /// Requests already queued keep going to their original destination only if
    /// they have already been sent; anything still queued goes to the new host.
    public func setNewHost(_ host: String) {
        guard let core = requireCore() else { return }
        guard !host.isEmpty else {
            core.logger.w(Self.module, "setNewHost", "omitting the call, the provided host is empty")
            return
        }
        core.logger.i(Self.module, "setNewHost", "the server host is being changed, host: [\(host)], previousHost: [\(core.config.host)], queuedRequestCount: [\(core.requestQueueStore.count)]")
        core.config.host = host
    }

    /// Points the SDK at a different app key.
    ///
    /// Queued requests keep the app key they were recorded under, so data already
    /// collected still lands where it belongs. Use the request queue API to rewrite
    /// or drop them.
    public func setNewAppKey(_ appKey: String) {
        guard let core = requireCore() else { return }
        guard !appKey.isEmpty else {
            core.logger.w(Self.module, "setNewAppKey", "omitting the call, the provided app key is empty")
            return
        }

        core.logger.i(Self.module, "setNewAppKey", "the app key is being changed, appKey: [\(appKey)], previousAppKey: [\(core.config.appKey)], queuedRequestCount: [\(core.requestQueueStore.count)]")
        core.modules.events.sendEventsWithSaveIfNeeded()
        core.modules.sessions.suspend()
        core.config.appKey = appKey
        core.modules.sessions.resume()
    }

    /// Replaces the session configuration used for every request.
    public func setNewURLSessionConfiguration(_ configuration: URLSessionConfiguration) {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "setNewURLSessionConfiguration", "a custom URL session configuration is being applied and the cached sessions will be rebuilt, customHeaderCount: [\(configuration.httpAdditionalHeaders?.count ?? 0)]")
        core.config.urlSessionConfiguration = configuration
        core.network.reset()
    }

    /// Adds headers to every request the SDK makes.
    public func addCustomNetworkRequestHeaders(_ headers: [String: String]?) {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "addCustomNetworkRequestHeaders", "custom network request headers are being set through the public API, providedHeaderCount: [\(headers?.count ?? 0)]")
        core.network.addCustomNetworkRequestHeaders(headers)
    }

    /// Reports the device metrics again, optionally overriding some of them.
    public func recordMetrics(_ metricsOverride: [String: String]? = nil) {
        guard let core = requireCore() else { return }

        core.logger.i(Self.module, "recordMetrics", "recording metrics, overrideMetricCount: [\(metricsOverride?.count ?? 0)]")

        guard core.modules.consent.hasConsent(for: .metrics) else {
            core.logger.d(Self.module, "recordMetrics", "the metrics request is not queued, reason: no consent is given for metrics")
            return
        }

        var metrics = core.metricsDictionary()
        if let metricsOverride, !metricsOverride.isEmpty {
            metrics.merge(metricsOverride) { _, override in override }
        }

        core.logger.d(Self.module, "recordMetrics", "metrics request is being prepared, finalMetricCount: [\(metrics.count)]")

        let queryString = "\(core.network.builder.queryEssentials())&\(QS.metrics)=\(CountlyJSON.escapedString(from: metrics, logger: core.logger))"
        core.network.enqueueAndProceed(queryString)
    }

    /// Queues a request the SDK does not otherwise produce.
    ///
    /// Keys the SDK owns are stripped, because a request that overrides the device
    /// ID or the timestamp would be attributed to the wrong user or moment.
    public func addDirectRequest(_ parameters: [String: String]?) {
        guard let core = requireCore() else { return }
        guard let parameters, !parameters.isEmpty else {
            core.logger.w(Self.module, "addDirectRequest", "omitting the call, the provided parameters are nil or empty")
            return
        }

        guard core.modules.consent.hasAnyConsent else {
            core.logger.d(Self.module, "addDirectRequest", "the direct request is not queued, reason: no consent is given for any feature")
            return
        }

        var filtered = parameters
        for key in RequestBuilder.reservedKeys where filtered[key] != nil {
            core.logger.w(Self.module, "addDirectRequest", "a reserved query string key is detected in the direct request parameters and it will be removed, key: [\(key)]")
            filtered.removeValue(forKey: key)
        }

        core.logger.i(Self.module, "addDirectRequest", "direct request is being queued, parameterCount: [\(filtered.count + 1)]")

        var queryString = core.network.builder.queryEssentials()
        queryString += "&dr=1"
        for (key, value) in filtered {
            queryString += "&\(key)=\(value)"
        }

        core.network.enqueueAndProceed(queryString)
    }

    /// Suspends tracking: flushes what is pending and closes the session.
    public func suspend() {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "suspend", "the public suspend call is received, pending data will be flushed and the session closed")
        core.modules.sessions.suspend()
    }

    /// Resumes tracking after a suspend.
    public func resume() {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "resume", "the public resume call is received, session handling will be restarted")
        core.modules.sessions.resume()
    }

    /// Stops the SDK and releases everything it holds.
    ///
    /// - Parameter clearStorage: When `true`, the persisted device ID, queue and
    ///   cached state are erased too. The next start looks like a first install.
    public func halt(clearStorage: Bool = false) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard let core, core.hasStarted else {
            // Printed rather than logged for the same reason `requireCore` prints.
            Logger.print("[Warning] [\(Self.module)] halt, the SDK is not running, the call is ignored")
            return
        }

        core.logger.i(Self.module, "halt", "the SDK is being halted, clearStorage: [\(clearStorage)], queuedRequestCount: [\(core.requestQueueStore.count)]")

        lifecycleObserver?.deregister()
        lifecycleObserver = nil

        // Reverse registry order, so a module is torn down before whatever it
        // depends on.
        for module in core.modules.all.reversed() {
            module.halt(clearStorage: clearStorage)
        }

        core.serverConfig.stop()
        core.network.reset()

        if clearStorage {
            core.requestQueueStore.flush()
            core.requestQueueStore.deleteFile()
            core.crashLogStore.deleteAll()
            core.keyValueStore.clearAll()
        } else {
            core.requestQueueStore.saveSync()
        }

        core.hasStarted = false
        core.hasFinishedInit = false
        self.core = nil

        core.logger.d(Self.module, "halt", "the SDK is halted, every module is torn down and the network is reset")
    }
}

// MARK: - Behavior settings

extension CountlyInstance: ServerConfigDelegate {

    func serverConfigDidChange(_ serverConfig: ServerConfig, consentBecameRequired: Bool) {
        guard let core else { return }

        guard core.hasStarted else {
            core.logger.d(Self.module, "serverConfigDidChange", "behavior settings changed while the SDK is not running, they are stored but not applied to it")
            return
        }

        core.logger.d(Self.module, "serverConfigDidChange", "behavior settings are being applied to the running SDK, consentBecameRequired: [\(consentBecameRequired)], trackingEnabled: [\(serverConfig.trackingEnabled)], networkingEnabled: [\(serverConfig.networkingEnabled)], storedRequestsLimit: [\(core.config.storedRequestsLimit)], requestDropAgeHours: [\(core.config.requestDropAgeHours)], requiresConsent: [\(core.config.requiresConsent)], enableDebug: [\(core.config.enableDebug)]")

        core.logger.enableDebug = core.config.enableDebug
        core.refreshLimits()

        core.requestQueueStore.storedRequestsLimit = Swift.max(1, core.config.storedRequestsLimit)
        core.requestQueueStore.requestDropAgeHours = core.config.requestDropAgeHours

        core.modules.consent.requiresConsent = core.config.requiresConsent
        core.modules.sessions.applyUpdatePeriodIfChanged()

        // Consent turning on mid-session means the server's view of what it may
        // keep just changed, so the state is resent.
        if consentBecameRequired, core.hasFinishedInit {
            core.logger.d(Self.module, "serverConfigDidChange", "consent requirement was turned on by behavior settings, consents will be resent")
            core.modules.consent.sendConsents()
            if !core.modules.consent.hasConsent(for: .location) {
                core.modules.location.sendLocationRequest()
            }
        }

        // Location switched off by the server clears what is stored and tells the
        // server to stop inferring it.
        if !serverConfig.locationTrackingEnabled, !core.modules.location.isLocationInfoDisabled {
            core.logger.d(Self.module, "serverConfigDidChange", "location tracking is disabled by behavior settings, location info will be cleared")
            core.modules.location.disableLocation()
            core.modules.location.sendLocationRequest()
        }

        // Content is cleared on every apply rather than exited, because exiting
        // would pull displayed content off screen on an unrelated settings change.
        DispatchQueue.main.async {
            core.modules.content.clearContentState()
            if serverConfig.enterContentZone {
                core.modules.content.enterContentZone()
            }
        }

        // Skipped during init: crash handling depends on values init has not
        // assigned yet, and `configure` applies them itself once it is done.
        if core.hasFinishedInit {
            applyAutomaticTrackingState(core: core)
        }
    }

    /// Brings automatic view tracking and crash reporting in line with the
    /// resolved settings. Safe to call repeatedly.
    private func applyAutomaticTrackingState(core: SDKCore) {
        let shouldTrackViews = core.serverConfig.viewTrackingEnabled && core.serverConfig.automaticViewTrackingEnabled

        DispatchQueue.main.async {
            let isActive = core.modules.views.isAutoViewTrackingActive
            if shouldTrackViews, !isActive {
                core.logger.d(Self.module, "applyAutomaticTrackingState", "behavior settings enable automatic view tracking, it will be started")
                core.modules.views.startAutoViewTracking()
            } else if !shouldTrackViews, isActive {
                core.logger.d(Self.module, "applyAutomaticTrackingState", "behavior settings disable automatic view tracking, it will be stopped")
                core.modules.views.stopAutoViewTracking()
            }
        }

        if core.serverConfig.crashReportingEnabled, core.serverConfig.automaticCrashReportingEnabled {
            core.logger.d(Self.module, "applyAutomaticTrackingState", "behavior settings enable automatic crash reporting, the crash handler will be started")
            core.modules.crashes.startCrashReporting()
        } else {
            core.logger.d(Self.module, "applyAutomaticTrackingState", "automatic crash reporting is disabled by behavior settings, the crash handler will not be started, crashReporting: [\(core.serverConfig.crashReportingEnabled)], automaticCrashReporting: [\(core.serverConfig.automaticCrashReportingEnabled)]")
        }
    }
}
