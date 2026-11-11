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
public final class CountlyInstance: NSObject {

    private static let module = "Countly"

    /// Registry key of this instance.
    @objc
    public let name: String

    /// Built by `start(with:)` and released by `halt()`.
    private var core: SDKCore?
    private var lifecycleObserver: LifecycleObserver?

    /// Guards the start and halt transitions, which can be reached from any
    /// thread.
    private let lifecycleLock = NSRecursiveLock()

    // MARK: - Feature facades

    /// Custom events.
    @objc
    public private(set) lazy var events = EventsAPI(instance: self)

    /// Sessions.
    @objc
    public private(set) lazy var sessions = SessionsAPI(instance: self)

    /// View tracking.
    @objc
    public private(set) lazy var views = ViewsAPI(instance: self)

    /// The user profile.
    @objc
    public private(set) lazy var userProfile = UserProfileAPI(instance: self)

    /// Consent.
    @objc
    public private(set) lazy var consent = ConsentAPI(instance: self)

    /// The device ID.
    @objc
    public private(set) lazy var deviceID = DeviceIDAPI(instance: self)

    /// Location.
    @objc
    public private(set) lazy var location = LocationAPI(instance: self)

    /// Crash reporting.
    @objc
    public private(set) lazy var crashes = CrashesAPI(instance: self)

    /// Remote config and A/B testing.
    @objc
    public private(set) lazy var remoteConfig = RemoteConfigAPI(instance: self)

    /// Attribution.
    @objc
    public private(set) lazy var attribution = AttributionAPI(instance: self)

    /// Feedback widgets.
    @objc
    public private(set) lazy var feedback = FeedbackAPI(instance: self)

    /// Content zone.
    @objc
    public private(set) lazy var content = ContentAPI(instance: self)

    /// Push notifications.
    @objc
    public private(set) lazy var push = PushAPI(instance: self)

    /// The request queue.
    @objc
    public private(set) lazy var requestQueue = RequestQueueAPI(instance: self)

    // MARK: - Init

    init(name: String) {
        self.name = name
    }

    deinit {
        // Released ahead of the core it holds `unowned`: tearing it down logs
        // through the core, and stored properties are released in declaration
        // order, the core first.
        lifecycleObserver = nil
    }

    /// Whether this instance has been started and not halted.
    @objc
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
            let reason = Countly.isRegistered(self) ? "the SDK has not been started yet" : notRegisteredReason
            Logger.print("[Warning] [\(Self.module)] \(function), \(reason), the call is ignored")
            PendingHealthCounts.recordWarning(instanceName: name, code: HealthLogCode.calledBeforeInit)
            return nil
        }
        return current
    }

    /// Why this instance can never run, for one the registry does not hold.
    private var notRegisteredReason: String {
        if name.isEmpty {
            return "the instance was requested with an empty name and can never be started, use Countly.shared for the default instance"
        }
        return "the instance was removed from the registry and can no longer be started, get a new one with Countly.instance(named:), name: [\(name)]"
    }

    // MARK: - Starting

    /// Starts the SDK.
    ///
    /// A second call is ignored rather than restarting: an already running
    /// instance has a session open and a queue in flight, and tearing that down
    /// silently would lose data.
    @objc(startWithConfig:)
    public func start(with config: CountlyConfig) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        if let core, core.hasStarted {
            core.logger.w(Self.module, "start", "omitting the call, the SDK has already been started")
            core.healthTracker.recordLogCode(HealthLogCode.startedAgain)
            return
        }

        // Only the instance the registry holds under a name may run on that name's
        // storage. A handle `Countly.removeInstance(named:)` dropped would run a
        // second SDK over the files and keys of the one the registry made since,
        // and an empty name maps to the default instance's storage.
        guard Countly.isRegistered(self) else {
            Logger.print("[Error] [\(Self.module)] start, \(notRegisteredReason), the call is ignored")
            return
        }

        // Validated before anything is built, so a misconfigured start leaves no
        // half-initialized state behind.
        if let failure = config.validate() {
            Logger.print("[Error] [\(Self.module)] start, \(failure.message)")
            PendingHealthCounts.recordError(instanceName: name)
            return
        }

        // An instance name in the config is advisory: the registry key decides
        // where data lives. A mismatch is worth saying out loud, because the
        // developer probably expected the config to win.
        if let configName = config.instanceName, !configName.isEmpty, configName != name {
            Logger.print("[Warning] [\(Self.module)] start, the instance name in the config does not match the name this instance was created with, configName: [\(configName)], instanceName: [\(name)]")
        }

        // A copy, so the server's behavior settings and calls such as
        // `setNewAppKey` change this run only: the caller's object starts the next
        // run as it was given, and a config shared by two instances cannot carry
        // one's changes into the other.
        let config = config.snapshot()

        // Taken before anything is opened. A previous holder still halting is
        // waited for, so its last write lands before this instance reads.
        StorageClaims.claim(StorageNamespace(instanceName: name), for: self)

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
            feedback: FeedbackModule(core: core),
            content: ContentModule(core: core),
            push: PushModule(core: core),
            connectionTest: ConnectionTestModule(core: core))

        core.attach(network: network, modules: modules)

        core.healthTracker.transport = network
        core.healthTracker.consentChecker = { [weak core] feature in
            core?.modules.consent.hasConsent(for: feature) ?? true
        }
        core.serverConfig.transport = network
        core.serverConfig.delegate = self
        core.serverConfig.logGatherer = core.logGatherer
        core.serverConfig.connectionTest = modules.connectionTest
    }

    /// Applies the config in the order the features depend on each other.
    private func configure(core: SDKCore, with config: CountlyConfig) {
        let modules = core.modules!
        let logger = core.logger

        core.healthTracker.absorb(PendingHealthCounts.take(instanceName: name))
        core.healthTracker.healthCheckEnabled = !config.disableHealthCheck

        // Checked before the behavior settings read the developer's values.
        config.resetInvalidValues(logger: logger)
        if config.host.hasSuffix("/") {
            logger.w(Self.module, "start", "the trailing slashes of the server URL are removed, so endpoint paths can be appended to it, serverUrl: [\(config.normalizedHost)]")
        }

        // Behavior settings first: they can change limits, queue sizes and whether
        // features are allowed at all, and everything below reads those.
        if config.disableSDKBehaviorSettingsUpdates {
            core.serverConfig.disableUpdates()
        }
        core.serverConfig.retrieveFromStorage(config: config)
        core.refreshLimits()

        modules.consent.requiresConsent = config.requiresConsent

        logger.i(Self.module, "start", "initializing, appKey: [\(config.appKey)], serverUrl: [\(config.normalizedHost)], instanceName: [\(name)], sdkName: [\(core.sdkName)], sdkVersion: [\(core.sdkVersion)], sdkIdentityOverridden: [\(core.sdkName != SDKIdentity.name || core.sdkVersion != SDKIdentity.version)], device: [\(DeviceMetrics.device)], osName: [\(DeviceMetrics.osName ?? "")], osVersion: [\(DeviceMetrics.osVersion ?? "")]")

        // Logged after the stored behavior settings were merged in, so these are
        // the values the SDK will actually run with rather than the ones the
        // developer passed. A value the server overrode is the usual reason an
        // integration does not behave the way its config reads.
        logger.i(Self.module, "start", "tracking configuration in effect, requiresConsent: [\(config.requiresConsent)], enableAllConsents: [\(config.enableAllConsents)], initialConsentCount: [\(config.consents.count)], manualSessionHandling: [\(config.manualSessionHandling)], hybridSessionMode: [\(config.enableManualSessionControlHybridMode)], automaticViewTracking: [\(config.enableAutomaticViewTracking)], viewTrackingExclusionCount: [\(config.automaticViewTrackingExclusionList.count)], orientationTracking: [\(config.enableOrientationTracking)], updateSessionPeriod: [\(config.updateSessionPeriod.logSeconds)], eventSendThreshold: [\(config.eventSendThreshold)], enableDebug: [\(config.enableDebug)], internalLogLevel: [\(config.internalLogLevel.label)]")

        logger.i(Self.module, "start", "networking configuration in effect, storedRequestsLimit: [\(config.storedRequestsLimit)], requestDropAgeHours: [\(config.requestDropAgeHours)], requestTimeoutDuration: [\(config.requestTimeoutDuration.logSeconds)], failedRequestCooldown: [\(config.failedRequestCooldown.logSeconds)], gradualRequestCleaner: [\(!config.disableGradualRequestCleaner)], healthCheckDisabled: [\(config.disableHealthCheck)], webViewDisabled: [\(config.disableWebView)],customNetworkRequestHeaderCount: [\(config.customNetworkRequestHeaders?.count ?? 0)], pinnedCertificateCount: [\(config.pinnedCertificates.count)], secretSaltConfigured: [\(config.secretSalt?.isEmpty == false)], customMetricCount: [\(config.customMetrics.count)], temporaryDeviceIDMode: [\(config.temporaryDeviceIDMode)], deviceIDProvided: [\(config.deviceID != nil)], resetStoredDeviceID: [\(config.resetStoredDeviceID)], behaviorSettingsUpdatesDisabled: [\(config.disableSDKBehaviorSettingsUpdates)], backoffMechanismDisabled: [\(config.disableBackoffMechanism)], features: [\(config.features.map { "\($0)" }.joined(separator: ", "))]")

        logger.d(Self.module, "start", "behavior settings in effect, trackingEnabled: [\(core.serverConfig.trackingEnabled)], networkingEnabled: [\(core.serverConfig.networkingEnabled)], sessionTracking: [\(core.serverConfig.sessionTrackingEnabled)], automaticSessionTracking: [\(core.serverConfig.automaticSessionTrackingEnabled)], viewTracking: [\(core.serverConfig.viewTrackingEnabled)], automaticViewTracking: [\(core.serverConfig.automaticViewTrackingEnabled)], crashReporting: [\(core.serverConfig.crashReportingEnabled)], automaticCrashReporting: [\(core.serverConfig.automaticCrashReportingEnabled)], locationTracking: [\(core.serverConfig.locationTracking.map { "\($0)" } ?? "not set")], customEventTracking: [\(core.serverConfig.customEventTrackingEnabled)], backoffMechanism: [\(core.serverConfig.backoffMechanism)], consentRequired: [\(core.serverConfig.consentRequired.map { "\($0)" } ?? "not set")]")

        logger.d(Self.module, "start", "SDK internal limits in effect, maxKeyLength: [\(config.sdkInternalLimits.maxKeyLength)], maxValueSize: [\(config.sdkInternalLimits.maxValueSize)], maxValueSizePicture: [\(config.sdkInternalLimits.maxValueSizePicture)], maxSegmentationValues: [\(config.sdkInternalLimits.maxSegmentationValues)], maxBreadcrumbCount: [\(config.sdkInternalLimits.maxBreadcrumbCount)], maxStackTraceLineLength: [\(config.sdkInternalLimits.maxStackTraceLineLength)], maxStackTraceLinesPerThread: [\(config.sdkInternalLimits.maxStackTraceLinesPerThread)]")

        // The device ID must exist before any request is built.
        modules.deviceID.initialize(with: config)

        core.requestQueueStore.storedRequestsLimit = config.storedRequestsLimit
        core.requestQueueStore.requestDropAgeHours = config.requestDropAgeHours
        core.requestQueueStore.isGradualCleanerEnabled = !config.disableGradualRequestCleaner

        core.network.addCustomNetworkRequestHeaders(config.customNetworkRequestHeaders)

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
        //
        // Nothing happens in the manual branch, which is what Android does. Its
        // orientation comes from session start, from a rotation, and from an
        // activity start; none of those is init itself. An application that starts
        // an activity after init gets one from that, and the foreground hook in
        // `ViewsModule` is the iOS equivalent. Recording here instead would put an
        // orientation event in the queue before the host has begun its session.
        if core.serverConfig.automaticSessionTrackingEnabled {
            modules.sessions.beginSession(automatically: true)
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

        // After the consent, which the profile calls need.
        if let provided = config.providedUserProperties, !provided.isEmpty {
            logger.i(Self.module, "start", "applying the user properties provided at init, count: [\(provided.count)]")
            modules.userProfile.setProperties(provided)
            modules.userProfile.save()
        }

        // When no session request will carry the location, it goes on its own.
        modules.location.sendAtEndOfInit()

        // Without session consent nothing carried attribution along either.
        if !modules.consent.hasConsent(for: .sessions) {
            modules.attribution.sendIndirectAttributionIfAvailable()
        }

        modules.attribution.applyInitialConfig()

        core.healthTracker.sendHealthCheck(isDeviceIDTemporary: modules.deviceID.isTemporary,
                                           networkingEnabled: core.serverConfig.networkingEnabled)

        core.hasFinishedInit = true

        // The request queue is usable from here on, so this is the first chance
        // for the lines gathered during init to go out.
        core.logGatherer.sdkInitFinished()

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
            // Nothing about the gathered lines is persisted, so the only way the
            // tail survives the app going away is getting it into the queue now.
            core.logGatherer.flushNow()
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

        core.isTerminating = true
        core.modules.views.applicationWillTerminate()
        core.modules.events.sendEventsWithSaveIfNeeded()
        core.modules.sessions.applicationWillTerminate()
        core.healthTracker.saveStateSync()
        // The queue is not drained while terminating, but a queued tail survives to
        // the next launch through the sync save below.
        core.logGatherer.flushNow(ignoringQueuedBatch: true)
        core.requestQueueStore.saveSync()
    }

    // MARK: - Integration-wide operations

    /// Points the SDK at a different server, for this run: the next start uses
    /// the server URL of the config again.
    ///
    /// Everything still queued goes to the new server; a request already on its
    /// way finishes at the old one. The new server is then caught up: the push
    /// token and, while consent is required, the consent state are sent again,
    /// and its behavior settings and, with automatic triggers, its remote config
    /// are fetched. A URL that is not an absolute http or https URL, or an http URL
    /// while certificates are pinned, is ignored with an error.
    @objc
    public func setNewHost(_ host: String) {
        guard let core = requireCore() else { return }

        var normalized = host
        while normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        guard normalized != Placeholder.host, CountlyConfig.isValidServerURL(normalized) else {
            core.logger.e(Self.module, "setNewHost", "omitting the call, the server URL is not a valid absolute http or https URL, host: [\(host)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidServerURL)
            return
        }

        guard core.config.pinnedCertificates.isEmpty || CountlyConfig.usesHTTPS(normalized) else {
            core.logger.e(Self.module, "setNewHost", "omitting the call, certificate pinning is configured and the server URL does not use https, host: [\(host)]")
            core.healthTracker.recordLogCode(HealthLogCode.invalidServerURL)
            return
        }

        core.logger.i(Self.module, "setNewHost", "the server host is being changed, host: [\(normalized)], previousHost: [\(core.config.normalizedHost)], queuedRequestCount: [\(core.requestQueueStore.count)]")
        core.config.host = normalized
        catchUpAfterConnectionChange(core: core)
    }

    /// Points the SDK at a different app key, for this run: the next start uses
    /// the app key of the config again.
    ///
    /// What belongs to the old app is closed first under the old key: the running
    /// views stop, pending events and profile changes are queued and the running
    /// session ends. Then a session begins for the new app if one was running,
    /// and automatic view tracking starts a view for the screen on display. The
    /// stored remote config values belong to the old app and are cleared, and the
    /// new app is caught up like a new server. Requests already queued keep the
    /// app key they were recorded under; the request queue API rewrites or drops
    /// them. An empty or placeholder key is ignored with an error, the key in use
    /// is ignored.
    @objc
    public func setNewAppKey(_ appKey: String) {
        guard let core = requireCore() else { return }

        guard !appKey.isEmpty, appKey != Placeholder.appKey else {
            core.logger.e(Self.module, "setNewAppKey", "omitting the call, the app key is empty or still the placeholder value")
            core.healthTracker.recordLogCode(HealthLogCode.invalidAppKey)
            return
        }

        guard appKey != core.config.appKey else {
            core.logger.d(Self.module, "setNewAppKey", "omitting the call, the app key is the one in use")
            return
        }

        core.logger.i(Self.module, "setNewAppKey", "the app key is being changed, appKey: [\(appKey)], previousAppKey: [\(core.config.appKey)], queuedRequestCount: [\(core.requestQueueStore.count)]")

        let modules = core.modules!
        modules.views.stopAllViewsForIdentityChange()
        modules.events.sendEventsWithSaveIfNeeded()
        let endedSession = modules.sessions.endSessionForIdentityChange(includingManual: true)

        core.config.appKey = appKey

        modules.sessions.beginSessionAfterIdentityChange(wasAutomatic: endedSession)
        modules.views.startViewForCurrentScreenAfterIdentityChange()
        modules.remoteConfig.clearCachedRemoteConfig()
        catchUpAfterConnectionChange(core: core)
    }

    /// Catches a new server or app up after `setNewHost` or `setNewAppKey`,
    /// since it knows nothing that was sent before. In temporary device ID mode
    /// the fetches skip themselves as usual.
    private func catchUpAfterConnectionChange(core: SDKCore) {
        core.modules.push.connectionChanged()
        if core.modules.consent.requiresConsent {
            core.modules.consent.sendConsents()
        }
        core.serverConfig.fetch(config: core.config)
        core.modules.remoteConfig.downloadRemoteConfigAutomatically()
    }

    /// Replaces the session configuration used for every request.
    @objc
    public func setNewURLSessionConfiguration(_ configuration: URLSessionConfiguration) {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "setNewURLSessionConfiguration", "a custom URL session configuration is being applied and the cached sessions will be rebuilt, customHeaderCount: [\(configuration.httpAdditionalHeaders?.count ?? 0)]")
        core.config.urlSessionConfiguration = configuration
        core.network.reset()
    }

    /// Adds headers to every request the SDK makes.
    @objc
    public func addCustomNetworkRequestHeaders(_ headers: [String: String]?) {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "addCustomNetworkRequestHeaders", "custom network request headers are being set through the public API, providedHeaderCount: [\(headers?.count ?? 0)]")
        core.network.addCustomNetworkRequestHeaders(headers)
    }

    /// Reports the device metrics again, optionally overriding some of them.
    @objc
    public func recordMetrics(_ metricsOverride: [String: String]? = nil) {
        guard let core = requireCore() else { return }

        core.logger.i(Self.module, "recordMetrics", "recording metrics, overrideMetricCount: [\(metricsOverride?.count ?? 0)]")

        guard core.modules.consent.hasConsent(for: .metrics) else {
            core.logger.d(Self.module, "recordMetrics", "the metrics request is not queued, reason: no consent is given for metrics")
            return
        }

        var metrics = core.metricsDictionary()
        if let metricsOverride, !metricsOverride.isEmpty {
            let usable = metricsOverride.filter { !$0.key.isEmpty && !$0.value.isEmpty }
            if usable.count != metricsOverride.count {
                core.logger.w(Self.module, "recordMetrics", "metric overrides with an empty key or value are skipped, skippedCount: [\(metricsOverride.count - usable.count)]")
                core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            }
            metrics.merge(usable) { _, override in override }
        }

        core.logger.d(Self.module, "recordMetrics", "metrics request is being prepared, finalMetricCount: [\(metrics.count)]")

        let queryString = "\(core.network.builder.queryEssentials())&\(QS.metrics)=\(CountlyJSON.escapedString(from: metrics, logger: core.logger))"
        core.network.enqueueAndProceed(queryString)
    }

    /// Queues a request the SDK does not otherwise produce.
    ///
    /// Keys the SDK owns are stripped, because a request that overrides the device
    /// ID or the timestamp would be attributed to the wrong user or moment. Keys and
    /// values are URL-encoded here, so pass them as they are.
    @objc
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

        guard !filtered.isEmpty else {
            core.logger.w(Self.module, "addDirectRequest", "omitting the call, no parameter is left once the reserved keys are removed")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            return
        }

        core.logger.i(Self.module, "addDirectRequest", "direct request is being queued, parameterCount: [\(filtered.count + 1)]")

        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.directRequest)=1"
        for (key, value) in filtered {
            queryString += "&\(key.urlEscaped)=\(value.urlEscaped)"
        }

        core.network.enqueueAndProceed(queryString)
    }

    /// Suspends tracking: flushes what is pending and closes the session.
    @objc
    public func suspend() {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "suspend", "the public suspend call is received, pending data will be flushed and the session closed")
        core.modules.sessions.suspend()
    }

    /// Resumes tracking after a suspend.
    @objc
    public func resume() {
        guard let core = requireCore() else { return }
        core.logger.i(Self.module, "resume", "the public resume call is received, session handling will be restarted")
        core.modules.sessions.resume()
    }

    /// Stops the SDK and releases everything it holds.
    ///
    /// The instance stays registered under its name, so `Countly.shared` and any
    /// reference the application kept go on pointing at it, and `start(with:)` can
    /// be called on it again: erasing the data and starting over is
    /// `halt(clearStorage: true)` followed by `start(with:)`. To drop a named
    /// instance from the registry as well, use `Countly.removeInstance(named:)`.
    ///
    /// - Parameter clearStorage: When `true`, the persisted device ID, queue and
    ///   cached state are erased too, also when the instance is not running. The
    ///   next start looks like a first install.
    @objc
    public func halt(clearStorage: Bool = false) {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        guard let core, core.hasStarted else {
            if clearStorage {
                eraseStoredData()
            } else {
                // Printed rather than logged for the same reason `requireCore` prints.
                Logger.print("[Warning] [\(Self.module)] halt, the SDK is not running, the call is ignored")
            }
            return
        }

        core.logger.i(Self.module, "halt", "the SDK is being halted, clearStorage: [\(clearStorage)], queuedRequestCount: [\(core.requestQueueStore.count)]")

        lifecycleObserver?.deregister()
        lifecycleObserver = nil

        // A behavior settings answer still on its way belongs to this run, and
        // would otherwise be applied to the next start of this instance.
        core.serverConfig.delegate = nil

        // First, so a module's halt-time flush lands in the queue and is not sent.
        core.network.halt()

        // Reverse registry order, so a module is torn down before whatever it
        // depends on.
        for module in core.modules.all.reversed() {
            module.halt(clearStorage: clearStorage)
        }

        core.serverConfig.stop()
        core.logGatherer.halt()

        // Every store is closed, not only erased ones: a send or a download that
        // completes after this point belongs to the run being halted and must not
        // write over what the next start reads.
        if clearStorage {
            core.requestQueueStore.flush()
            core.requestQueueStore.deleteFile()
            core.keyValueStore.clearAll()
        } else {
            core.requestQueueStore.close()
            core.keyValueStore.close()
        }

        core.hasStarted = false
        core.hasFinishedInit = false
        self.core = nil

        StorageClaims.release(core.namespace, by: self)

        core.logger.d(Self.module, "halt", "the SDK is halted, every module is torn down and the network is reset")
    }

    /// Erases what this instance's storage holds without starting it, for a
    /// `halt(clearStorage: true)` that finds it not running.
    ///
    /// Only the registered instance may: a handle `Countly.removeInstance(named:)`
    /// dropped would otherwise wipe the files of the instance the registry made
    /// since, while it runs on them. The namespace is held for the duration, so a
    /// previous holder still halting finishes its last write first.
    private func eraseStoredData() {
        guard Countly.isRegistered(self) else {
            Logger.print("[Warning] [\(Self.module)] halt, \(notRegisteredReason), its stored data is not erased")
            return
        }

        let namespace = StorageNamespace(instanceName: name)
        StorageClaims.claim(namespace, for: self)
        defer { StorageClaims.release(namespace, by: self) }

        RequestQueueDatabase(namespace: namespace, logger: nil).deleteEverything()
        KeyValueStore(namespace: namespace, logger: nil).clearAll()

        Logger.print("[Info] [\(Self.module)] halt, the SDK is not running, its stored data is erased, name: [\(name)]")
    }
}

// MARK: - Behavior settings

extension CountlyInstance: ServerConfigDelegate {

    func serverConfigDidChange(_ serverConfig: ServerConfig, changedKeys: Set<String>) {
        // An answer the halt could not stop any more comes from the halted run's
        // settings, and after a restart `core` is already the next run.
        guard let core, core.serverConfig === serverConfig else { return }

        guard core.hasStarted else {
            core.logger.d(Self.module, "serverConfigDidChange", "behavior settings changed while the SDK is not running, they are stored but not applied to it")
            return
        }

        core.logger.d(Self.module, "serverConfigDidChange", "behavior settings are being applied to the running SDK, changedKeys: [\(changedKeys.sorted().joined(separator: ", "))], trackingEnabled: [\(serverConfig.trackingEnabled)], networkingEnabled: [\(serverConfig.networkingEnabled)], storedRequestsLimit: [\(core.config.storedRequestsLimit)], requestDropAgeHours: [\(core.config.requestDropAgeHours)], requiresConsent: [\(core.config.requiresConsent)]")

        core.refreshLimits()

        core.requestQueueStore.storedRequestsLimit = core.config.storedRequestsLimit
        core.requestQueueStore.requestDropAgeHours = core.config.requestDropAgeHours

        // During init the requirement is only recorded: nothing runs yet that a
        // change would have to start or stop, and init sends the consent state itself.
        if core.hasFinishedInit {
            let required = core.config.requiresConsent
            // The change starts and stops views, push and content, which belong to the main thread.
            onMainThread {
                guard core.hasStarted else { return }
                core.modules.consent.applyRequirementChange(to: required)
            }
        } else {
            core.modules.consent.requiresConsent = core.config.requiresConsent
        }
        core.modules.sessions.applyUpdatePeriodIfChanged()

        if changedKeys.contains(ServerConfig.Key.locationTracking) {
            core.modules.location.serverSettingChanged()
        }

        // Only the server's own zone settings may move a zone the app entered; cleared, not exited, so displayed content stays.
        let zoneSettingsChanged = changedKeys.contains(ServerConfig.Key.enterContentZone)
            || (serverConfig.enterContentZone && changedKeys.contains(ServerConfig.Key.contentZoneInterval))
        if zoneSettingsChanged, core.hasFinishedInit {
            DispatchQueue.main.async {
                core.modules.content.clearContentState()
                if serverConfig.enterContentZone {
                    core.modules.content.enterContentZone()
                }
            }
        }

        // Skipped during init: crash handling depends on values init has not
        // assigned yet, and `configure` applies them itself once it is done.
        if core.hasFinishedInit {
            applyAutomaticTrackingState(core: core)
        }
    }

    /// Brings automatic sessions, view tracking and crash reporting in line with
    /// the resolved settings. Safe to call repeatedly.
    private func applyAutomaticTrackingState(core: SDKCore) {
        let shouldTrackViews = core.serverConfig.viewTrackingEnabled && core.serverConfig.automaticViewTrackingEnabled

        DispatchQueue.main.async {
            core.modules.sessions.applyAutomaticSessionTracking()

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
