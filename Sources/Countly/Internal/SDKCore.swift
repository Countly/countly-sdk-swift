//
//  SDKCore.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Everything one Countly instance is made of, in one place.
///
/// Modules reach their collaborators through the core rather than through
/// singletons, which is what makes several instances able to coexist: each has its
/// own logger, clock, stores, networking and module set, and none of them can see
/// another instance's state.
///
/// Modules hold the core `unowned`, the core holds the modules strongly, and the
/// `CountlyInstance` holds the core. Nothing in that graph retains a cycle.
final class SDKCore {

    /// Registry key of this instance.
    let instanceName: String

    /// Where this instance's data lives.
    let namespace: StorageNamespace

    let logger: Logger

    /// Holds the logger's lines for the server while a gather is armed or not yet
    /// decided. Created with the logger, so the very first init lines are held.
    let logGatherer: LogGatherer

    let clock: MonotonicClock

    /// The config this instance was started with. Mutated in place by behavior
    /// settings, which is how a server side limit change reaches the modules.
    let config: CountlyConfig

    let keyValueStore: KeyValueStore
    let requestQueueStore: RequestQueueStore
    let crashLogStore: CrashLogStore
    let healthTracker: HealthTracker
    let serverConfig: ServerConfig

    /// Recomputed whenever behavior settings change the limits.
    private(set) var limits: LimitsEnforcer

    /// Set once, immediately after construction. Not optional in practice, but
    /// the modules need a built core to be constructed against.
    private(set) var modules: ModuleRegistry!

    /// Set once, immediately after construction, for the same reason.
    private(set) var network: ConnectionManager!

    /// `true` once `start(with:)` has been called and not halted.
    var hasStarted = false

    /// `true` once `start(with:)` has run to completion. Some behavior settings
    /// work is deferred until then, because it depends on values init has not
    /// assigned yet.
    var hasFinishedInit = false

    /// Whether the application is currently crashing, which suspends queue
    /// processing: nothing is sent while the process goes down, and the stored
    /// crash report goes out on the next launch.
    var isCrashing = false

    /// Whether the application is terminating, which stops new requests from
    /// starting.
    var isTerminating = false

    /// The name reported on the wire: the bridge's if it set one, else this SDK's.
    ///
    /// Resolved here rather than at each of the seven read sites, so a bridge that
    /// overrides it cannot be reported inconsistently across requests, feedback
    /// widget URLs and the connection test report.
    let sdkName: String

    /// The version reported on the wire, the counterpart to ``sdkName``.
    let sdkVersion: String

    /// A blank override is no override: the wire requires both fields.
    private static func resolvedIdentity(_ override: String?, fallback: String) -> String {
        let trimmed = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // The value is interpolated into every query string as is, so it has to be escaped once here.
        return trimmed.isEmpty ? fallback : trimmed.urlEscaped
    }

    init(instanceName: String, config: CountlyConfig) {
        self.instanceName = instanceName
        self.config = config
        self.sdkName = Self.resolvedIdentity(config.sdkName, fallback: SDKIdentity.name)
        self.sdkVersion = Self.resolvedIdentity(config.sdkVersion, fallback: SDKIdentity.version)
        self.namespace = StorageNamespace(instanceName: instanceName)

        let isDefault = namespace.isDefault
        self.logger = Logger(instanceName: isDefault ? nil : instanceName)
        logger.enableDebug = config.enableDebug
        logger.level = config.internalLogLevel
        logger.delegate = config.loggerDelegate

        self.logGatherer = LogGatherer(logger: logger)
        logger.gatherer = logGatherer

        self.clock = MonotonicClock()
        self.limits = LimitsEnforcer(limits: config.sdkInternalLimits, logger: logger)

        self.keyValueStore = KeyValueStore(namespace: namespace, logger: logger)
        self.requestQueueStore = RequestQueueStore(namespace: namespace, logger: logger)
        self.crashLogStore = CrashLogStore(namespace: namespace, logger: logger)
        crashLogStore.maxBreadcrumbCount = config.sdkInternalLimits.maxBreadcrumbCount
        self.healthTracker = HealthTracker(store: keyValueStore, logger: logger)
        self.serverConfig = ServerConfig(store: keyValueStore, logger: logger)

        logger.healthTracker = healthTracker
    }

    /// Second construction phase: hands the core its networking and modules.
    func attach(network: ConnectionManager, modules: ModuleRegistry) {
        self.network = network
        self.modules = modules
        logGatherer.transport = self
    }

    /// Rebuilds the limit enforcer after behavior settings changed the limits.
    func refreshLimits() {
        limits = LimitsEnforcer(limits: config.sdkInternalLimits, logger: logger)
        // The breadcrumb file caps itself, so it has to hear about a limit the
        // server lowered as well.
        crashLogStore.maxBreadcrumbCount = config.sdkInternalLimits.maxBreadcrumbCount
    }

    /// The metrics dictionary for this instance, including its custom metrics.
    func metricsDictionary() -> [String: String] {
        DeviceMetrics.metricsDictionary(customMetrics: sanitizedCustomMetrics(), logger: logger)
    }

    /// Custom metrics with the SDK limits applied, computed once per read because
    /// the limits can change under behavior settings.
    private func sanitizedCustomMetrics() -> [String: String] {
        guard !config.customMetrics.isEmpty else { return [:] }
        return limits.truncatedAndLimited(config.customMetrics, "Custom metric")
            .compactMapValues { $0 as? String }
    }
}

/// The core is what the log gatherer delivers through, rather than the
/// connection manager directly: a delivery in flight holds its transport strongly,
/// and holding the core keeps everything the send touches alive across a `halt`.
/// Holding only the manager would leave it reading a released core.
extension SDKCore: LogGatheringTransport {

    var isTrackingEnabled: Bool {
        serverConfig.trackingEnabled
    }

    var hasAnyConsent: Bool {
        modules.consent.hasAnyConsent
    }

    func sendSdkLogs(_ payload: String) -> Bool {
        network.sendSdkLogs(payload)
    }
}

/// Strong references to every module of one instance.
///
/// A class rather than a struct so the core can hold it after the modules were
/// built against the core.
final class ModuleRegistry {

    let consent: ConsentModule
    let deviceID: DeviceIDModule
    let events: EventsModule
    let sessions: SessionsModule
    let views: ViewsModule
    let userProfile: UserProfileModule
    let location: LocationModule
    let crashes: CrashModule
    let remoteConfig: RemoteConfigModule
    let attribution: AttributionModule
    let apm: APMModule
    let feedback: FeedbackModule
    let content: ContentModule
    let push: PushModule
    let connectionTest: ConnectionTestModule

    init(consent: ConsentModule,
         deviceID: DeviceIDModule,
         events: EventsModule,
         sessions: SessionsModule,
         views: ViewsModule,
         userProfile: UserProfileModule,
         location: LocationModule,
         crashes: CrashModule,
         remoteConfig: RemoteConfigModule,
         attribution: AttributionModule,
         apm: APMModule,
         feedback: FeedbackModule,
         content: ContentModule,
         push: PushModule,
         connectionTest: ConnectionTestModule) {
        self.consent = consent
        self.deviceID = deviceID
        self.events = events
        self.sessions = sessions
        self.views = views
        self.userProfile = userProfile
        self.location = location
        self.crashes = crashes
        self.remoteConfig = remoteConfig
        self.attribution = attribution
        self.apm = apm
        self.feedback = feedback
        self.content = content
        self.push = push
        self.connectionTest = connectionTest
    }

    /// Every module, for operations that fan out over all of them.
    var all: [ModuleBase] {
        [consent, deviceID, events, sessions, views, userProfile, location,
         crashes, remoteConfig, attribution, apm, feedback, content, push, connectionTest]
    }
}

/// Shared behavior of every module.
///
/// A class rather than a protocol so modules inherit the `core` plumbing and the
/// default lifecycle hooks instead of restating them.
class ModuleBase {

    unowned let core: SDKCore

    /// Name used in log lines, so a reader can tell which module spoke.
    class var moduleName: String { "Module" }

    init(core: SDKCore) {
        self.core = core
    }

    var log: Logger { core.logger }

    // MARK: - Convenience log helpers

    func logE(_ function: String = #function, _ message: @autoclosure () -> String) {
        log.e(Self.moduleName, function, message())
    }

    func logW(_ function: String = #function, _ message: @autoclosure () -> String) {
        log.w(Self.moduleName, function, message())
    }

    func logI(_ function: String = #function, _ message: @autoclosure () -> String) {
        log.i(Self.moduleName, function, message())
    }

    func logD(_ function: String = #function, _ message: @autoclosure () -> String) {
        log.d(Self.moduleName, function, message())
    }

    func logV(_ function: String = #function, _ message: @autoclosure () -> String) {
        log.v(Self.moduleName, function, message())
    }

    // MARK: - Lifecycle hooks

    /// Called once the whole instance is wired, in registry order.
    func didInit() {}

    /// Called when the application comes to the foreground.
    func didEnterForeground() {}

    /// Called when the application goes to the background.
    func didEnterBackground() {}

    /// Called when the instance is halted, so a module can release timers and
    /// observers. Modules are halted in reverse registry order.
    func halt(clearStorage: Bool) {}
}
