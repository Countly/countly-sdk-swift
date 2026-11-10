//
//  ServerConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Server driven behavior settings, known on the wire as SBS.
///
/// The server can switch SDK features on and off, retune queue sizes and limits,
/// and filter what is recorded, without an application update. Four layers are
/// resolved in order, each overriding the one before:
///
/// 1. the built-in SDK defaults
/// 2. the developer's `CountlyConfig`
/// 3. settings the developer supplied as JSON at init, while nothing is stored
/// 4. the last valid answer of the server, which replaces the stored one whole
///
/// Every setting is resolved again from the developer's values on each answer:
/// one the answer does not carry, or carries with an invalid value, falls back
/// to the developer config or the default. So adopting behavior settings never
/// changes an existing integration, and an operator removing a setting in the
/// dashboard undoes it on every device.
final class ServerConfig {

    private static let module = "ServerConfig"

    // MARK: - Wire keys

    /// Top level keys of a behavior settings document.
    private enum DocKey {
        static let timestamp = "t"
        static let version = "v"
        static let config = "c"

        /// Log gathering directive, a sibling of `c`. Read from a live response
        /// only and never stored: a stored directive decides nothing.
        static let logGathering = "lg"

        /// Connection test flag, a sibling of `c`. Read from a live response only,
        /// stripped before the response is validated or cached, never persisted.
        static let connectionTest = "ct"

        /// The only top level keys that reach storage. Anything else, the two
        /// operator armed keys above included, must not survive into the cache.
        static let stored: Set<String> = [timestamp, version, config]
    }

    /// Keys inside the `c` section, which also name what an apply changed.
    enum Key {
        static let tracking = "tracking"
        static let networking = "networking"
        static let requestQueueSize = "rqs"
        static let eventQueueSize = "eqs"
        static let sessionUpdateInterval = "sui"
        static let sessionTracking = "st"
        static let viewTracking = "vt"
        static let locationTracking = "lt"
        static let refreshContentZone = "rcz"
        static let backoffMechanism = "bom"

        static let limitKeyLength = "lkl"
        static let limitValueSize = "lvs"
        static let limitSegValues = "lsv"
        static let limitBreadcrumb = "lbc"
        static let limitTraceLine = "ltlpt"
        static let limitTraceLength = "ltl"

        static let customEventTracking = "cet"
        static let enterContentZone = "ecz"
        static let contentZoneInterval = "czi"
        static let consentRequired = "cr"
        static let dropOldRequestTime = "dort"
        static let crashReporting = "crt"
        static let automaticSessionTracking = "ast"
        static let automaticViewTracking = "avt"
        static let automaticCrashReporting = "acr"
        static let serverConfigUpdateInterval = "scui"

        static let bomAcceptedTimeout = "bom_at"
        static let bomRQPercentage = "bom_rqp"
        static let bomRequestAge = "bom_ra"
        static let bomDuration = "bom_d"

        static let eventBlacklist = "eb"
        static let eventWhitelist = "ew"
        static let userPropertyBlacklist = "upb"
        static let userPropertyWhitelist = "upw"
        static let userPropertyCacheLimit = "upcl"
        static let segmentationBlacklist = "sb"
        static let segmentationWhitelist = "sw"
        static let eventSegmentationBlacklist = "esb"
        static let eventSegmentationWhitelist = "esw"
        static let journeyTriggerEvents = "jte"
        static let journeyTriggerViews = "jtv"

        /// Anything not listed here is dropped rather than stored, so an unknown
        /// key from a newer server cannot accumulate in the cache forever.
        static let known: Set<String> = [
            tracking, networking, sessionUpdateInterval, requestQueueSize, eventQueueSize,
            crashReporting, automaticSessionTracking, automaticViewTracking, automaticCrashReporting,
            sessionTracking, limitKeyLength, limitValueSize, limitSegValues, limitBreadcrumb,
            limitTraceLine, limitTraceLength, customEventTracking, viewTracking, enterContentZone,
            contentZoneInterval, consentRequired, dropOldRequestTime, serverConfigUpdateInterval,
            locationTracking, refreshContentZone, backoffMechanism, bomAcceptedTimeout,
            bomRQPercentage, bomRequestAge, bomDuration, userPropertyCacheLimit,
            eventBlacklist, eventWhitelist, userPropertyBlacklist, userPropertyWhitelist,
            segmentationBlacklist, segmentationWhitelist, eventSegmentationBlacklist,
            eventSegmentationWhitelist, journeyTriggerEvents, journeyTriggerViews,
        ]
    }

    /// The `method` value of a behavior settings fetch.
    static let fetchMethod = "sc"

    /// Where the document being applied came from. Carried only so a log dump
    /// says whether the SDK is running on last run's cache, on what the developer
    /// handed in at init, or on what the server just answered.
    private enum Source: String {
        case storedCache = "stored cache"
        case developerSupplied = "developer supplied"
        case serverFetch = "server fetch"
    }

    /// The settings one apply changed, in the order they were read.
    ///
    /// Only a value that differs from the one in effect counts. The server sends
    /// every configured key on every answer, and treating an unchanged key as a
    /// change would rerun every side effect of a change on every refresh.
    private struct ChangeLog {
        private(set) var keys: Set<String> = []
        private(set) var descriptions: [String] = []

        /// Records that `key` now resolves to `value`.
        mutating func record(_ key: String, _ value: String) {
            keys.insert(key)
            descriptions.append("\(key): \(value)")
        }
    }

    /// The allow and block lists, replaced whole under `filterLock`.
    ///
    /// An answer replaces them on a network thread while events, views and user
    /// properties read them on whatever thread recorded them, so readers take a
    /// copy under the lock rather than reading the sets in place.
    private struct ListingFilters {
        var events: Set<String> = []
        var eventsIsWhitelist = false
        var userProperties: Set<String> = []
        var userPropertiesIsWhitelist = false
        var segmentation: Set<String> = []
        var segmentationIsWhitelist = false
        var eventSegmentation: [String: Set<String>] = [:]
        var eventSegmentationIsWhitelist = false
        var journeyTriggerEvents: Set<String> = []
        var journeyTriggerViews: Set<String> = []
    }

    // MARK: - Resolved values

    private(set) var trackingEnabled = true
    private(set) var networkingEnabled = true
    private(set) var crashReportingEnabled = true
    private(set) var automaticSessionTrackingEnabled = true
    private(set) var automaticViewTrackingEnabled = false
    private(set) var automaticCrashReportingEnabled = false
    private(set) var customEventTrackingEnabled = true
    private(set) var enterContentZone = false
    private(set) var viewTrackingEnabled = true
    private(set) var sessionTrackingEnabled = true
    private(set) var refreshContentZoneEnabled = true
    private(set) var backoffMechanism = true

    /// The server's "lt", or `nil` while the settings do not contain it and the
    /// application's own choice applies.
    private(set) var locationTracking: Bool?

    /// Whether the server allows location tracking: everything but an "lt" of false.
    var locationTrackingEnabled: Bool { locationTracking != false }

    /// The server's "cr", or `nil` while the settings do not contain it and the
    /// developer's `requiresConsent` applies.
    private(set) var consentRequired: Bool?

    /// The server's "bom", or `nil` while the settings do not contain it and the
    /// developer's `disableBackoffMechanism` applies.
    private var backoffSetting: Bool?

    private(set) var bomAcceptedTimeoutSeconds = Default.bomAcceptedTimeoutSeconds
    private(set) var bomRQPercentage = Default.bomRQPercentage
    private(set) var bomRequestAge = Default.bomRequestAge
    private(set) var bomDuration = Default.bomDuration

    /// The values a setting falls back to when neither the server nor the
    /// developer config says otherwise.
    private enum Default {
        static let bomAcceptedTimeoutSeconds = 10
        static let bomRQPercentage = 0.5
        static let bomRequestAge = 24
        static let bomDuration = 60
        static let userPropertyCacheLimit = 100
    }

    /// The developer's configuration as it was before any behavior setting was
    /// applied, which every setting the server does not send falls back to.
    private var developerConfig: CountlyConfig?

    /// Zero means "the server said nothing, use the developer value".
    private(set) var eventQueueSize = 0
    private(set) var requestQueueSize = 0
    private(set) var sessionInterval = 0
    private(set) var limitKeyLength = 0
    private(set) var limitValueSize = 0
    private(set) var limitSegValues = 0
    private(set) var limitBreadcrumb = 0
    private(set) var limitTraceLine = 0
    private(set) var limitTraceLength = 0
    /// Nil when the server said nothing. Zero means "stop dropping by age", so it
    /// cannot double as the absent marker.
    private(set) var dropOldRequestTime: Int?
    private(set) var contentZoneInterval = 0

    private(set) var userPropertyCacheLimit = Default.userPropertyCacheLimit
    private(set) var requestTimeoutDuration: TimeInterval = 30

    // MARK: - Listing filters

    private let filterLock = NSLock()
    private var listingFilters = ListingFilters()

    /// A copy of the filters in effect, safe to read on any thread.
    private var currentFilters: ListingFilters {
        filterLock.lock()
        defer { filterLock.unlock() }
        return listingFilters
    }

    // MARK: - Fetch bookkeeping

    private var version = 0
    private var timestamp: Int64 = 0
    private var lastFetchTimestamp: Int64 = 0
    private var currentUpdateIntervalHours = 4
    private var serverConfigUpdateInterval = 0
    private var updatesDisabled = false
    private var refreshTimer: Timer?

    /// Guards `halted`, which a fetch completing on a network thread reads.
    private let stateLock = NSLock()
    private var halted = false

    /// Whether `stop()` ended this run. An answer landing afterwards decides nothing.
    private var isHalted: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return halted
    }

    // MARK: - Collaborators

    private let store: KeyValueStore
    private weak var logger: Logger?

    /// Applies resolved values to the rest of the SDK. Weak: the instance owns
    /// this object.
    weak var delegate: ServerConfigDelegate?

    /// Performs the fetch. Weak for the same reason.
    weak var transport: ServerConfigTransport?

    /// Receives the `lg` directive of every live response, and the decision that
    /// no response can arrive this run. Weak: the core owns it.
    weak var logGatherer: LogGatherer?

    /// Runs the probe battery when a live response carries `ct`. Weak: the
    /// module registry owns it.
    weak var connectionTest: ConnectionTestModule?

    init(store: KeyValueStore, logger: Logger?) {
        self.store = store
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Stops the refresh timer and ignores any answer still on its way. Called
    /// from `halt`.
    func stop() {
        logger?.d(Self.module, "stop", "the behavior settings refresh timer is being stopped, wasScheduled: [\(refreshTimer != nil)]")
        stateLock.lock()
        halted = true
        stateLock.unlock()
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Turns off every fetch, at the developer's request.
    func disableUpdates() {
        logger?.i(Self.module, "disableUpdates", "behavior settings updates are being disabled")
        updatesDisabled = true
        // Without fetches no directive can ever arrive or be renewed, which spares
        // the logger a buffer that would never be adopted.
        logGatherer?.decideOffIfUndecided("behavior settings updates are disabled, no directive can ever arrive")
    }

    // MARK: - Layer 2 and 3: developer config and stored settings

    /// Seeds from the developer config and applies whatever was stored last run,
    /// falling back to the developer supplied JSON when nothing is stored.
    ///
    /// Runs before the first request, so an application that was told last week to
    /// stop tracking does not start tracking again on this launch just because the
    /// fetch has not answered yet.
    func retrieveFromStorage(config: CountlyConfig) {
        developerConfig = config.snapshot()
        backoffMechanism = !config.disableBackoffMechanism
        automaticSessionTrackingEnabled = !config.manualSessionHandling
        #if os(iOS) || os(tvOS) || os(visionOS)
        automaticViewTrackingEnabled = config.enableAutomaticViewTracking
        #endif
        automaticCrashReportingEnabled = config.features.contains(.crashReporting)

        logger?.d(Self.module, "retrieveFromStorage", "automatic tracking flags seeded from the developer config, automaticSessionTracking: [\(automaticSessionTrackingEnabled)], automaticViewTracking: [\(automaticViewTrackingEnabled)], automaticCrashReporting: [\(automaticCrashReportingEnabled)], backoffMechanism: [\(backoffMechanism)]")

        logDeveloperLayer(config: config)

        var stored = store.serverConfig ?? [:]
        var source = Source.storedCache
        logger?.d(Self.module, "retrieveFromStorage", "behavior settings read from the persisted cache, cachedEntryCount: [\(stored.count)], hasDeveloperSuppliedSettings: [\(config.sdkBehaviorSettings != nil)], storedKeys: [\(sortedKeyList(of: stored))]")

        if stored.isEmpty, let supplied = config.sdkBehaviorSettings {
            if let parsed = CountlyJSON.object(from: Data(supplied.utf8), logger: logger) as? [String: Any] {
                stored = parsed
                source = .developerSupplied
                logger?.d(Self.module, "retrieveFromStorage", "the cache was empty, falling back to the developer supplied behavior settings, entryCount: [\(stored.count)], suppliedLength: [\(supplied.count)]")
            } else {
                logger?.w(Self.module, "retrieveFromStorage", "the developer supplied sdkBehaviorSettings are not a JSON object and will be ignored, suppliedLength: [\(supplied.count)]")
                logger?.healthTracker?.recordLogCode(HealthLogCode.invalidSetting)
            }
        }

        if populate(&stored, config: config, source: source) {
            store.serverConfig = stored
        } else if source == .storedCache, !stored.isEmpty {
            logger?.d(Self.module, "retrieveFromStorage", "the stored behavior settings are not a valid answer and are removed, the developer configuration stays in effect")
            store.serverConfig = nil
        }
    }

    /// The developer's own values, printed before anything can overrule them.
    ///
    /// Half of "the SDK is ignoring my configuration" is answered by comparing
    /// this line against what the layers above resolve to, so it goes out on every
    /// launch whether or not any behavior settings exist.
    private func logDeveloperLayer(config: CountlyConfig) {
        let limits = config.sdkInternalLimits
        logger?.d(Self.module, "retrieveFromStorage", "developer configuration before any behavior setting is applied, eventSendThreshold: [\(config.eventSendThreshold)], storedRequestsLimit: [\(config.storedRequestsLimit)], requestDropAgeHours: [\(config.requestDropAgeHours)], updateSessionPeriod: [\(config.updateSessionPeriod.logSeconds)], requestTimeoutDuration: [\(config.requestTimeoutDuration.logSeconds)], requiresConsent: [\(config.requiresConsent)], enableDebug: [\(config.enableDebug)], disableBackoffMechanism: [\(config.disableBackoffMechanism)], contentZoneTimerInterval: [\(config.content.zoneTimerInterval)], maxKeyLength: [\(limits.maxKeyLength)], maxValueSize: [\(limits.maxValueSize)], maxSegmentationValues: [\(limits.maxSegmentationValues)], maxBreadcrumbCount: [\(limits.maxBreadcrumbCount)], maxStackTraceLineLength: [\(limits.maxStackTraceLineLength)], maxStackTraceLinesPerThread: [\(limits.maxStackTraceLinesPerThread)]")
    }

    /// Key names of a document as one readable list. Interpolating the keys
    /// directly would print a collection description inside the brackets.
    private func sortedKeyList(of document: [String: Any]) -> String {
        document.keys.sorted().joined(separator: ", ")
    }

    // MARK: - Layer 4: the server

    /// Whether enough time has passed to refresh, used on foreground.
    func fetchIfTimeIsUp(config: CountlyConfig) {
        guard !updatesDisabled else {
            logger?.d(Self.module, "fetchIfTimeIsUp", "periodic behavior settings check skipped, updates are disabled")
            return
        }
        guard lastFetchTimestamp != 0 else {
            logger?.d(Self.module, "fetchIfTimeIsUp", "periodic behavior settings check skipped, nothing has been fetched yet this launch")
            return
        }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = now - lastFetchTimestamp
        let interval = Int64(currentUpdateIntervalHours) * 60 * 60 * 1000

        if elapsed > interval {
            logger?.d(Self.module, "fetchIfTimeIsUp", "behavior settings refresh interval elapsed, a fetch will be triggered, timePassedMs: [\(elapsed)], intervalHours: [\(currentUpdateIntervalHours)]")
            fetch(config: config)
        } else {
            logger?.d(Self.module, "fetchIfTimeIsUp", "behavior settings are still considered fresh, no fetch will be triggered, timePassedMs: [\(elapsed)], intervalMs: [\(interval)]")
        }
    }

    /// Asks the server for behavior settings and merges the answer into what is
    /// stored.
    func fetch(config: CountlyConfig) {
        logger?.d(Self.module, "fetch", "starting a behavior settings fetch, currentVersion: [\(version)], updateIntervalHours: [\(currentUpdateIntervalHours)]")

        guard !updatesDisabled else {
            logger?.d(Self.module, "fetch", "fetch aborted, behavior settings updates are disabled")
            logGatherer?.decideOffIfUndecided("behavior settings updates are disabled, no directive can ever arrive")
            return
        }

        guard let transport, !transport.isDeviceIDTemporary else {
            logger?.d(Self.module, "fetch", "fetch aborted, sdk is in temporary device ID mode")
            logGatherer?.decideOffIfUndecided("temporary device ID mode, no server response this run")
            return
        }

        lastFetchTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        scheduleRefreshTimerIfNeeded(config: config)

        let fetchStart = Date()
        // `lg` and `ct` are armed for the user this request is made for.
        let requestedIdentity = ArmedIdentity(deviceID: transport.deviceID, typeValue: transport.deviceIDTypeValue)
        let mergesAtRequest = transport.deviceIDMergeCount
        transport.fetchServerConfig { [weak self] data, statusCode, error in
            guard let self else { return }

            guard !self.isHalted else {
                self.logger?.d(Self.module, "fetch", "the behavior settings answer arrived after the instance was halted and is ignored, statusCode: [\(statusCode)]")
                return
            }

            // Wall clock of the whole fetch, reported by the connection test as its
            // `sc` row.
            let fetchLatencyMs = Int64(Date().timeIntervalSince(fetchStart) * 1000)

            if let error {
                let failure = error as NSError
                self.logger?.d(Self.module, "fetch", "the behavior settings request failed at the transport level, the stored settings stay in effect, statusCode: [\(statusCode)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
                self.logGatherer?.decideOffIfUndecided("server config fetch failed")
                return
            }

            guard statusCode == 200 else {
                self.logger?.d(Self.module, "fetch", "the server refused the behavior settings request, the stored settings stay in effect, statusCode: [\(statusCode)], responseLength: [\(data?.count ?? 0)]")
                self.logGatherer?.decideOffIfUndecided("server config fetch was refused")
                return
            }

            guard var response = CountlyJSON.object(from: data, logger: self.logger) as? [String: Any] else {
                self.logger?.d(Self.module, "fetch", "the behavior settings response is not a JSON object, previously stored behavior settings will be kept, responseLength: [\(data?.count ?? 0)]")
                self.logGatherer?.decideOffIfUndecided("server config response is not usable")
                return
            }

            // Read only here, from a live response, and removed before anything
            // below sees the response so it can never be cached.
            let connectionTestArmed = Self.extractConnectionTestFlag(&response)

            // A valid answer replaces the stored one whole: a setting the operator
            // removed has to stop applying, not live on from an earlier answer.
            var answer = response.filter { DocKey.stored.contains($0.key) }
            if self.populate(&answer, config: config, source: .serverFetch) {
                self.store.serverConfig = answer
                self.logger?.d(Self.module, "fetch", "the fetched behavior settings replaced the stored ones, responseLength: [\(data?.count ?? 0)], settingCount: [\((answer[DocKey.config] as? [String: Any])?.count ?? 0)]")
            } else {
                self.logger?.d(Self.module, "fetch", "the response is not a valid behavior settings answer, the stored settings stay in effect, responseLength: [\(data?.count ?? 0)]")
            }

            // Only a live response decides log gathering, never a stored document. A
            // live response without a usable directive decides against it.
            let isSameDevice = self.transport?.deviceID == requestedIdentity.deviceID
            if isSameDevice {
                self.logGatherer?.apply(LogGatheringDirective.parse(response[DocKey.logGathering], logger: self.logger),
                                        source: "server response")
            } else {
                self.logger?.d(Self.module, "fetch", "the device ID changed while the fetch was in flight, its log gathering directive belongs to the previous user and is ignored")
            }

            if connectionTestArmed {
                // A merge cancels the armed run on the server; a report under the old ID would only recreate that user.
                if self.transport?.deviceIDMergeCount == mergesAtRequest {
                    self.connectionTest?.startBattery(serverConfigLatencyMs: fetchLatencyMs,
                                                      armedFor: requestedIdentity,
                                                      mergesAtArming: mergesAtRequest)
                } else {
                    self.logger?.d(Self.module, "fetch", "the device ID was changed with merge since the request, the connection test armed for it is skipped")
                }
            }

            // Otherwise the current user stays undecided until the next refresh, hours away.
            if !isSameDevice, self.logGatherer?.currentState == .undecided {
                self.logger?.d(Self.module, "fetch", "log gathering is still undecided after a device ID change, the behavior settings are fetched again for the current device ID")
                self.fetch(config: config)
            }
        }
    }

    /// Reads and removes the top level `ct` flag from a live response, so it can
    /// never be cached and re-arm from storage.
    ///
    /// Truthy numbers, booleans and non-empty strings other than `"0"` and
    /// `"false"` arm the test; any other non-null value does too.
    static func extractConnectionTestFlag(_ response: inout [String: Any]) -> Bool {
        guard let value = response.removeValue(forKey: DocKey.connectionTest) else { return false }

        if value is NSNull { return false }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "0" && trimmed.lowercased() != "false"
        }
        return true
    }

    private func scheduleRefreshTimerIfNeeded(config: CountlyConfig) {
        guard refreshTimer == nil else { return }
        // A stored interval is adopted before the first timer is installed;
        // otherwise the reschedule below never runs and every launch falls back to
        // the built-in default however many times the server has said otherwise.
        if serverConfigUpdateInterval > 0 {
            currentUpdateIntervalHours = serverConfigUpdateInterval
        }
        installRefreshTimer(config: config)
    }

    private func installRefreshTimer(config: CountlyConfig) {
        let timer = Timer(timeInterval: TimeInterval(currentUpdateIntervalHours) * 60 * 60,
                          repeats: true) { [weak self] _ in
            self?.fetch(config: config)
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    // MARK: - Applying

    /// Whether a value is a JSON number rather than a boolean, which the bridge
    /// also hands over as an `NSNumber`.
    private static func isNumber(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    /// Validates and applies a whole document, then tells the rest of the SDK what
    /// changed.
    ///
    /// Every setting is resolved again: one the document does not carry falls back
    /// to the developer config or the default. Values of the wrong type or out of
    /// range are ignored with a warning, as if the key were missing, and dropped
    /// from the document, so a bad value is not kept in the cache.
    ///
    /// - Returns: Whether the document is a valid answer, a numeric `v` and `t`
    ///   with a `c` object, and was applied. An invalid one changes nothing.
    @discardableResult
    private func populate(_ document: inout [String: Any], config: CountlyConfig, source: Source) -> Bool {
        logger?.d(Self.module, "populate", "resolving behavior settings over the developer configuration, source: [\(source.rawValue)], entryCount: [\(document.count)]")

        if config.requestTimeoutDuration <= 0 {
            config.requestTimeoutDuration = 1
            logger?.d(Self.module, "populate", "the configured request timeout is not a usable duration and was raised, requestTimeoutDuration: [\(config.requestTimeoutDuration.logSeconds)]")
        }
        requestTimeoutDuration = config.requestTimeoutDuration

        // A developer supplied document may carry the operator armed top level
        // keys; they decide nothing here and must not be written to the cache.
        let strayKeys = document.keys.filter { !DocKey.stored.contains($0) }
        if !strayKeys.isEmpty {
            logger?.d(Self.module, "populate", "top level behavior settings keys that are never stored are dropped, keys: [\(strayKeys.sorted().joined(separator: ", "))]")
            for key in strayKeys {
                document.removeValue(forKey: key)
            }
        }

        guard let rawConfig = document[DocKey.config] as? [String: Any],
              Self.isNumber(document[DocKey.version]),
              Self.isNumber(document[DocKey.timestamp]) else {
            if document.isEmpty {
                logger?.d(Self.module, "populate", "no behavior settings are stored yet, the developer configuration stays in effect, source: [\(source.rawValue)]")
            } else if source == .developerSupplied {
                logger?.w(Self.module, "populate", "the developer supplied behavior settings are not a valid answer, a numeric v and t and a c object are needed, they are ignored, entryKeys: [\(sortedKeyList(of: document))]")
                logger?.healthTracker?.recordLogCode(HealthLogCode.invalidSetting)
            } else {
                logger?.d(Self.module, "populate", "the behavior settings are not a valid answer, a numeric v and t and a c object are needed, the settings in effect stay, source: [\(source.rawValue)], entryKeys: [\(sortedKeyList(of: document))]")
            }
            return false
        }

        version = intValue(document[DocKey.version]) ?? 0
        timestamp = Int64(intValue(document[DocKey.timestamp]) ?? 0)

        var section = rawConfig
        let unknownKeys = section.keys.filter { !Key.known.contains($0) }
        if !unknownKeys.isEmpty {
            logger?.d(Self.module, "populate", "behavior setting keys this SDK version does not know will be dropped, keyCount: [\(unknownKeys.count)], keys: [\(unknownKeys.sorted().joined(separator: ", "))]")
            for key in unknownKeys {
                section.removeValue(forKey: key)
            }
        }

        let developer = developerConfig ?? config
        var automaticViewTrackingDefault = false
        #if os(iOS) || os(tvOS) || os(visionOS)
        automaticViewTrackingDefault = developer.enableAutomaticViewTracking
        #endif

        var changes = ChangeLog()

        readBool(&section, Key.tracking, &trackingEnabled, default: true, &changes)
        readBool(&section, Key.networking, &networkingEnabled, default: true, &changes)
        readInt(&section, Key.sessionUpdateInterval, &sessionInterval, min: 1, &changes)
        readInt(&section, Key.requestQueueSize, &requestQueueSize, min: 1, &changes)
        readInt(&section, Key.eventQueueSize, &eventQueueSize, min: 1, &changes)
        readBool(&section, Key.crashReporting, &crashReportingEnabled, default: true, &changes)
        readBool(&section, Key.automaticSessionTracking, &automaticSessionTrackingEnabled, default: !developer.manualSessionHandling, &changes)
        readBool(&section, Key.automaticViewTracking, &automaticViewTrackingEnabled, default: automaticViewTrackingDefault, &changes)
        readBool(&section, Key.automaticCrashReporting, &automaticCrashReportingEnabled, default: developer.features.contains(.crashReporting), &changes)
        readBool(&section, Key.sessionTracking, &sessionTrackingEnabled, default: true, &changes)
        readInt(&section, Key.limitKeyLength, &limitKeyLength, min: 1, &changes)
        readInt(&section, Key.limitValueSize, &limitValueSize, min: 1, &changes)
        readInt(&section, Key.limitSegValues, &limitSegValues, min: 1, &changes)
        readInt(&section, Key.limitBreadcrumb, &limitBreadcrumb, min: 1, &changes)
        readInt(&section, Key.limitTraceLine, &limitTraceLine, min: 1, &changes)
        readInt(&section, Key.limitTraceLength, &limitTraceLength, min: 1, &changes)
        readBool(&section, Key.customEventTracking, &customEventTrackingEnabled, default: true, &changes)
        readBool(&section, Key.viewTracking, &viewTrackingEnabled, default: true, &changes)
        readBool(&section, Key.enterContentZone, &enterContentZone, default: false, &changes)
        readInt(&section, Key.contentZoneInterval, &contentZoneInterval, min: 15, &changes)
        readOptionalBool(&section, Key.consentRequired, &consentRequired, &changes)
        readOptionalInt(&section, Key.dropOldRequestTime, &dropOldRequestTime, min: 0, &changes)
        readInt(&section, Key.serverConfigUpdateInterval, &serverConfigUpdateInterval, min: 1, &changes)
        readOptionalBool(&section, Key.locationTracking, &locationTracking, &changes)
        readBool(&section, Key.refreshContentZone, &refreshContentZoneEnabled, default: true, &changes)
        readOptionalBool(&section, Key.backoffMechanism, &backoffSetting, &changes)
        backoffMechanism = backoffSetting ?? !developer.disableBackoffMechanism
        readInt(&section, Key.bomAcceptedTimeout, &bomAcceptedTimeoutSeconds, min: 1, default: Default.bomAcceptedTimeoutSeconds, &changes)
        readFraction(&section, Key.bomRQPercentage, &bomRQPercentage, default: Default.bomRQPercentage, &changes)
        readInt(&section, Key.bomRequestAge, &bomRequestAge, min: 1, default: Default.bomRequestAge, &changes)
        readInt(&section, Key.bomDuration, &bomDuration, min: 1, default: Default.bomDuration, &changes)
        readInt(&section, Key.userPropertyCacheLimit, &userPropertyCacheLimit, min: 1, default: Default.userPropertyCacheLimit, &changes)

        updateListingFilters(&section, changes: &changes)

        document[DocKey.config] = section

        if !changes.keys.isEmpty {
            notifyChange(config: config, developer: developer, changedKeys: changes.keys)
        }

        logger?.d(Self.module, "populate", "behavior settings applied, source: [\(source.rawValue)], version: [\(version)], timestamp: [\(timestamp)], changedCount: [\(changes.keys.count)], changedValues: [\(changes.descriptions.joined(separator: ", "))]")
        logEffectiveConfiguration(config: config)
        return true
    }

    /// The state every layer resolved to, printed as the counterpart of the
    /// developer layer line so the two can be diffed straight out of a log dump.
    private func logEffectiveConfiguration(config: CountlyConfig) {
        logger?.d(Self.module, "populate", "effective behavior switches, tracking: [\(trackingEnabled)], networking: [\(networkingEnabled)], crashReporting: [\(crashReportingEnabled)], customEventTracking: [\(customEventTrackingEnabled)], sessionTracking: [\(sessionTrackingEnabled)], viewTracking: [\(viewTrackingEnabled)], locationTracking: [\(locationTracking.map { "\($0)" } ?? "not set")], automaticSessionTracking: [\(automaticSessionTrackingEnabled)], automaticViewTracking: [\(automaticViewTrackingEnabled)], automaticCrashReporting: [\(automaticCrashReportingEnabled)], enterContentZone: [\(enterContentZone)], refreshContentZone: [\(refreshContentZoneEnabled)], backoffMechanism: [\(backoffMechanism)], consentRequired: [\(consentRequired.map { "\($0)" } ?? "not set")]")

        let limits = config.sdkInternalLimits
        logger?.d(Self.module, "populate", "effective behavior values, eventSendThreshold: [\(config.eventSendThreshold)], storedRequestsLimit: [\(config.storedRequestsLimit)], requestDropAgeHours: [\(config.requestDropAgeHours)], updateSessionPeriod: [\(config.updateSessionPeriod.logSeconds)], requestTimeoutDuration: [\(requestTimeoutDuration.logSeconds)], contentZoneTimerInterval: [\(config.content.zoneTimerInterval)], userPropertyCacheLimit: [\(userPropertyCacheLimit)], backoffAcceptedTimeoutSeconds: [\(bomAcceptedTimeoutSeconds)], backoffQueuePercentage: [\(bomRQPercentage.logValue)], backoffRequestAgeHours: [\(bomRequestAge)], backoffDurationSeconds: [\(bomDuration)], maxKeyLength: [\(limits.maxKeyLength)], maxValueSize: [\(limits.maxValueSize)], maxSegmentationValues: [\(limits.maxSegmentationValues)], maxBreadcrumbCount: [\(limits.maxBreadcrumbCount)], maxStackTraceLineLength: [\(limits.maxStackTraceLineLength)], maxStackTraceLinesPerThread: [\(limits.maxStackTraceLinesPerThread)]")
    }

    /// Pushes the resolved values into the rest of the SDK: a value the server
    /// set, or the developer's own where it set none.
    ///
    /// - Parameters:
    ///   - developer: the developer's configuration before any setting applied.
    ///   - changedKeys: the `c` keys whose value this apply changed.
    private func notifyChange(config: CountlyConfig, developer: CountlyConfig, changedKeys: Set<String>) {
        // Only the values that actually displace a developer one are collected, so
        // the line below reads as the list of settings the server took over.
        var overrides: [String] = []

        /// Zero means the server said nothing about this setting, which puts the
        /// developer's value back.
        func apply(_ name: String, _ target: inout Int, _ value: Int, developerValue: Int) {
            let resolved = value > 0 ? value : developerValue
            if resolved != developerValue {
                overrides.append("\(name): \(developerValue) to \(resolved)")
            }
            target = resolved
        }

        let limits = config.sdkInternalLimits
        let developerLimits = developer.sdkInternalLimits
        apply("maxKeyLength", &limits.maxKeyLength, limitKeyLength, developerValue: developerLimits.maxKeyLength)
        apply("maxValueSize", &limits.maxValueSize, limitValueSize, developerValue: developerLimits.maxValueSize)
        apply("maxSegmentationValues", &limits.maxSegmentationValues, limitSegValues, developerValue: developerLimits.maxSegmentationValues)
        apply("maxBreadcrumbCount", &limits.maxBreadcrumbCount, limitBreadcrumb, developerValue: developerLimits.maxBreadcrumbCount)
        apply("maxStackTraceLineLength", &limits.maxStackTraceLineLength, limitTraceLength, developerValue: developerLimits.maxStackTraceLineLength)
        apply("maxStackTraceLinesPerThread", &limits.maxStackTraceLinesPerThread, limitTraceLine, developerValue: developerLimits.maxStackTraceLinesPerThread)

        apply("eventSendThreshold", &config.eventSendThreshold, eventQueueSize, developerValue: developer.eventSendThreshold)
        apply("storedRequestsLimit", &config.storedRequestsLimit, requestQueueSize, developerValue: developer.storedRequestsLimit)
        apply("contentZoneTimerInterval", &config.content.zoneTimerInterval, contentZoneInterval, developerValue: developer.content.zoneTimerInterval)

        // Its own path, because zero is a value here: "stop dropping by age".
        config.requestDropAgeHours = dropOldRequestTime ?? developer.requestDropAgeHours
        if config.requestDropAgeHours != developer.requestDropAgeHours {
            overrides.append("requestDropAgeHours: \(developer.requestDropAgeHours) to \(config.requestDropAgeHours)")
        }

        config.updateSessionPeriod = sessionInterval > 0 ? TimeInterval(sessionInterval) : developer.updateSessionPeriod
        if config.updateSessionPeriod != developer.updateSessionPeriod {
            overrides.append("updateSessionPeriod: \(developer.updateSessionPeriod.logSeconds) to \(config.updateSessionPeriod.logSeconds)")
        }

        config.requiresConsent = consentRequired ?? developer.requiresConsent
        if config.requiresConsent != developer.requiresConsent {
            overrides.append("requiresConsent: \(developer.requiresConsent) to \(config.requiresConsent)")
        }

        if !overrides.isEmpty {
            logger?.d(Self.module, "notifyChange", "behavior settings displaced developer configured values, overrideCount: [\(overrides.count)], overrides: [\(overrides.joined(separator: ", "))]")
        }

        let interval = serverConfigUpdateInterval > 0 ? serverConfigUpdateInterval : Self.defaultUpdateIntervalHours
        if interval != currentUpdateIntervalHours, refreshTimer != nil {
            logger?.d(Self.module, "notifyChange", "behavior settings refresh timer will be rescheduled, intervalHours: [\(interval)]")
            currentUpdateIntervalHours = interval
            refreshTimer?.invalidate()
            refreshTimer = nil
            installRefreshTimer(config: config)
        }

        delegate?.serverConfigDidChange(self, changedKeys: changedKeys)
    }

    /// Hours between two fetches when the server does not set "scui".
    private static let defaultUpdateIntervalHours = 4

    // MARK: - Value readers

    /// Logs a setting that is ignored for its type or value, as if the server had
    /// not sent it, and drops it from the document.
    private func dropInvalid(_ section: inout [String: Any], _ key: String, _ function: String, _ reason: String) {
        logger?.w(Self.module, function, "a behavior setting is ignored, \(reason), key: [\(key)]")
        logger?.healthTracker?.recordLogCode(HealthLogCode.invalidSetting)
        section.removeValue(forKey: key)
    }

    /// The boolean under `key`, or `nil` when it is missing or not a boolean,
    /// which drops it with a warning.
    private func boolValue(_ section: inout [String: Any], _ key: String) -> Bool? {
        guard let value = section[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            dropInvalid(&section, key, "readBool", "a boolean was expected, receivedType: [\(type(of: value))]")
            return nil
        }
        return number.boolValue
    }

    /// The whole number under `key` at or above `minimum`, or `nil` when it is
    /// missing or invalid, which drops it with a warning.
    private func intValue(_ section: inout [String: Any], _ key: String, min minimum: Int) -> Int? {
        guard let value = section[key] else { return nil }
        guard Self.isNumber(value), let number = value as? NSNumber, number.doubleValue == number.doubleValue.rounded() else {
            dropInvalid(&section, key, "readInt", "a whole number was expected, receivedType: [\(type(of: value))]")
            return nil
        }
        guard number.intValue >= minimum else {
            dropInvalid(&section, key, "readInt", "the value is below the accepted minimum, value: [\(number.intValue)], minValue: [\(minimum)]")
            return nil
        }
        return number.intValue
    }

    /// Resolves a switch: the server's value, or `defaultValue` when it sent none
    /// or an invalid one.
    private func readBool(_ section: inout [String: Any], _ key: String, _ target: inout Bool, default defaultValue: Bool, _ changes: inout ChangeLog) {
        let resolved = boolValue(&section, key) ?? defaultValue
        let previous = target
        target = resolved
        if previous != resolved {
            changes.record(key, "\(resolved)")
            logger?.d(Self.module, "readBool", "a behavior settings switch changed, key: [\(key)], previousValue: [\(previous)], newValue: [\(resolved)], setByServer: [\(section[key] != nil)]")
        }
    }

    /// Resolves a switch whose absence means something of its own: `nil` while
    /// the server sends no valid value for it.
    private func readOptionalBool(_ section: inout [String: Any], _ key: String, _ target: inout Bool?, _ changes: inout ChangeLog) {
        let resolved = boolValue(&section, key)
        let previous = target
        target = resolved
        if previous != resolved {
            changes.record(key, resolved.map { "\($0)" } ?? "not set")
            logger?.d(Self.module, "readOptionalBool", "a behavior settings switch changed, key: [\(key)], previousValue: [\(previous.map { "\($0)" } ?? "not set")], newValue: [\(resolved.map { "\($0)" } ?? "not set")]")
        }
    }

    /// Resolves a count: the server's value, or `defaultValue` when it sent none
    /// or an invalid one. A default of 0 means "the developer's value applies".
    private func readInt(_ section: inout [String: Any], _ key: String, _ target: inout Int, min minimum: Int, default defaultValue: Int = 0, _ changes: inout ChangeLog) {
        let resolved = intValue(&section, key, min: minimum) ?? defaultValue
        let previous = target
        target = resolved
        if previous != resolved {
            changes.record(key, "\(resolved)")
            logger?.d(Self.module, "readInt", "a behavior settings count changed, key: [\(key)], previousValue: [\(previous)], newValue: [\(resolved)], setByServer: [\(section[key] != nil)]")
        }
    }

    /// Resolves a count whose absence means something of its own: `nil` while the
    /// server sends no valid value for it.
    private func readOptionalInt(_ section: inout [String: Any], _ key: String, _ target: inout Int?, min minimum: Int, _ changes: inout ChangeLog) {
        let resolved = intValue(&section, key, min: minimum)
        let previous = target
        target = resolved
        if previous != resolved {
            changes.record(key, resolved.map { "\($0)" } ?? "not set")
            logger?.d(Self.module, "readOptionalInt", "a behavior settings count changed, key: [\(key)], previousValue: [\(previous.map { "\($0)" } ?? "not set")], newValue: [\(resolved.map { "\($0)" } ?? "not set")]")
        }
    }

    /// Resolves a fraction above 0 and at most 1: the server's value, or
    /// `defaultValue` when it sent none or one out of range. A server that meant
    /// 50 percent and sent 50 would otherwise switch the queue check off.
    private func readFraction(_ section: inout [String: Any], _ key: String, _ target: inout Double, default defaultValue: Double, _ changes: inout ChangeLog) {
        var resolved = defaultValue
        if let value = section[key] {
            if Self.isNumber(value), let number = value as? NSNumber, number.doubleValue > 0, number.doubleValue <= 1 {
                resolved = number.doubleValue
            } else {
                dropInvalid(&section, key, "readFraction", "a fraction above 0 and at most 1 was expected, value: [\(value)]")
            }
        }
        let previous = target
        target = resolved
        if previous != resolved {
            changes.record(key, resolved.logValue)
            logger?.d(Self.module, "readFraction", "a behavior settings fraction changed, key: [\(key)], previousValue: [\(previous.logValue)], newValue: [\(resolved.logValue)]")
        }
    }

    private func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    // MARK: - Listing filters

    /// Resolves the blacklist and whitelist pairs. An empty list is ignored, as if
    /// it were missing, and a blacklist wins only when both lists have entries,
    /// because excluding is the safer of the two. Without either list the
    /// category is not filtered.
    private func updateListingFilters(_ section: inout [String: Any], changes: inout ChangeLog) {
        var filters = currentFilters

        resolveListFilter(&section,
                          blacklistKey: Key.eventBlacklist,
                          whitelistKey: Key.eventWhitelist,
                          set: &filters.events,
                          isWhitelist: &filters.eventsIsWhitelist,
                          changes: &changes)

        resolveListFilter(&section,
                          blacklistKey: Key.userPropertyBlacklist,
                          whitelistKey: Key.userPropertyWhitelist,
                          set: &filters.userProperties,
                          isWhitelist: &filters.userPropertiesIsWhitelist,
                          changes: &changes)

        resolveListFilter(&section,
                          blacklistKey: Key.segmentationBlacklist,
                          whitelistKey: Key.segmentationWhitelist,
                          set: &filters.segmentation,
                          isWhitelist: &filters.segmentationIsWhitelist,
                          changes: &changes)

        resolveMapFilter(&section,
                         blacklistKey: Key.eventSegmentationBlacklist,
                         whitelistKey: Key.eventSegmentationWhitelist,
                         map: &filters.eventSegmentation,
                         isWhitelist: &filters.eventSegmentationIsWhitelist,
                         changes: &changes)

        resolveNameSet(&section, key: Key.journeyTriggerEvents, set: &filters.journeyTriggerEvents, changes: &changes)
        resolveNameSet(&section, key: Key.journeyTriggerViews, set: &filters.journeyTriggerViews, changes: &changes)

        filterLock.lock()
        listingFilters = filters
        filterLock.unlock()

        logger?.d(Self.module, "updateListingFilters", "resolved listing filters, eventFilterCount: [\(filters.events.count)], eventFilterIsWhitelist: [\(filters.eventsIsWhitelist)], userPropertyFilterCount: [\(filters.userProperties.count)], userPropertyFilterIsWhitelist: [\(filters.userPropertiesIsWhitelist)], segmentationFilterCount: [\(filters.segmentation.count)], segmentationFilterIsWhitelist: [\(filters.segmentationIsWhitelist)], eventSegmentationFilteredEventCount: [\(filters.eventSegmentation.count)], eventSegmentationFilterIsWhitelist: [\(filters.eventSegmentationIsWhitelist)], journeyTriggerEventCount: [\(filters.journeyTriggerEvents.count)], journeyTriggerViewCount: [\(filters.journeyTriggerViews.count)]")
    }

    private func resolveListFilter(_ section: inout [String: Any],
                                   blacklistKey: String,
                                   whitelistKey: String,
                                   set: inout Set<String>,
                                   isWhitelist: inout Bool,
                                   changes: inout ChangeLog) {
        let blacklist = Set(nameList(&section, blacklistKey) ?? [])
        let whitelist = Set(nameList(&section, whitelistKey) ?? [])

        let resolved: Set<String>
        let resolvedIsWhitelist: Bool
        if !blacklist.isEmpty {
            if !whitelist.isEmpty {
                logger?.d(Self.module, "updateListingFilters", "a blacklist and a whitelist are both set, the blacklist applies, blacklistKey: [\(blacklistKey)], whitelistKey: [\(whitelistKey)]")
            }
            resolved = blacklist
            resolvedIsWhitelist = false
        } else {
            resolved = whitelist
            resolvedIsWhitelist = !whitelist.isEmpty
        }

        if resolved != set || resolvedIsWhitelist != isWhitelist {
            changes.record(resolvedIsWhitelist ? whitelistKey : blacklistKey, resolved.sorted().joined(separator: ", "))
        }
        set = resolved
        isWhitelist = resolvedIsWhitelist
    }

    /// The names under `key`, or `nil` when it is missing or not a list of
    /// strings, which drops it with a warning.
    private func nameList(_ section: inout [String: Any], _ key: String) -> [String]? {
        guard let value = section[key] else { return nil }
        guard let list = value as? [String] else {
            dropInvalid(&section, key, "updateListingFilters", "a list of names was expected, receivedType: [\(type(of: value))]")
            return nil
        }
        return list
    }

    private func resolveMapFilter(_ section: inout [String: Any],
                                  blacklistKey: String,
                                  whitelistKey: String,
                                  map: inout [String: Set<String>],
                                  isWhitelist: inout Bool,
                                  changes: inout ChangeLog) {
        /// The event to keys map under `key`, without the events whose list is
        /// empty. `nil` when it is missing or not such a map, which drops it.
        func readMap(_ key: String) -> [String: Set<String>]? {
            guard let value = section[key] else { return nil }
            guard let raw = value as? [String: Any], raw.values.allSatisfy({ $0 is [String] }) else {
                dropInvalid(&section, key, "updateListingFilters", "an object of event names to lists of keys was expected, receivedType: [\(type(of: value))]")
                return nil
            }
            return raw.compactMapValues { ($0 as? [String]).map(Set.init) }.filter { !$0.value.isEmpty }
        }

        let blacklist = readMap(blacklistKey) ?? [:]
        let whitelist = readMap(whitelistKey) ?? [:]

        let resolved: [String: Set<String>]
        let resolvedIsWhitelist: Bool
        if !blacklist.isEmpty {
            resolved = blacklist
            resolvedIsWhitelist = false
        } else {
            resolved = whitelist
            resolvedIsWhitelist = !whitelist.isEmpty
        }

        if resolved != map || resolvedIsWhitelist != isWhitelist {
            changes.record(resolvedIsWhitelist ? whitelistKey : blacklistKey, resolved.keys.sorted().joined(separator: ", "))
        }
        map = resolved
        isWhitelist = resolvedIsWhitelist
    }

    private func resolveNameSet(_ section: inout [String: Any], key: String, set: inout Set<String>, changes: inout ChangeLog) {
        let resolved = Set(nameList(&section, key) ?? [])
        if resolved != set {
            changes.record(key, resolved.sorted().joined(separator: ", "))
        }
        set = resolved
    }

    // MARK: - Filter queries

    /// Whether an event key survives the event filter.
    func shouldRecordEvent(_ eventKey: String) -> Bool {
        let filters = currentFilters
        guard !filters.events.isEmpty else { return true }
        return filters.eventsIsWhitelist == filters.events.contains(eventKey)
    }

    /// Whether a user property key survives the user property filter.
    func shouldRecordUserProperty(_ propertyKey: String) -> Bool {
        let filters = currentFilters
        guard !filters.userProperties.isEmpty else { return true }
        return filters.userPropertiesIsWhitelist == filters.userProperties.contains(propertyKey)
    }

    /// Drops segmentation keys that the global or per-event filter excludes.
    func filterSegmentation(_ segmentation: [String: Any]?, eventKey: String) -> [String: Any]? {
        guard let segmentation else { return nil }

        let filters = currentFilters
        let hasGlobalFilter = !filters.segmentation.isEmpty
        let eventFilter = filters.eventSegmentation[eventKey]
        let hasEventFilter = !(eventFilter?.isEmpty ?? true)

        guard hasGlobalFilter || hasEventFilter else { return segmentation }

        var result = segmentation
        for key in segmentation.keys {
            if hasGlobalFilter, filters.segmentationIsWhitelist != filters.segmentation.contains(key) {
                logger?.d(Self.module, "filterSegmentation", "dropping segmentation key by the global segmentation filter, key: [\(key)], filterIsWhitelist: [\(filters.segmentationIsWhitelist)]")
                result.removeValue(forKey: key)
            } else if hasEventFilter, let eventFilter,
                      filters.eventSegmentationIsWhitelist != eventFilter.contains(key) {
                logger?.d(Self.module, "filterSegmentation", "dropping segmentation key by the event level segmentation filter, key: [\(key)], eventKey: [\(eventKey)]")
                result.removeValue(forKey: key)
            }
        }
        return result
    }

    /// Whether recording this event should also flush the queue, so a journey can
    /// react to it right away.
    func isJourneyTriggerEvent(_ eventKey: String) -> Bool {
        currentFilters.journeyTriggerEvents.contains(eventKey)
    }

    /// Whether starting this view should also flush the queue.
    func isJourneyTriggerView(_ viewName: String) -> Bool {
        currentFilters.journeyTriggerViews.contains(viewName)
    }
}

/// The user a behavior settings request was made for, who owns anything its
/// answer arms.
struct ArmedIdentity: Equatable {
    let deviceID: String
    /// The `t` value the device ID had when the request was made.
    let typeValue: Int
}

/// Applies resolved behavior settings to the rest of the SDK.
protocol ServerConfigDelegate: AnyObject {
    /// - Parameter changedKeys: the `c` keys, named as in ``ServerConfig/Key``,
    ///   whose value this apply changed, a key the answer no longer carries
    ///   included.
    func serverConfigDidChange(_ serverConfig: ServerConfig, changedKeys: Set<String>)
}

/// What the behavior settings fetch needs from the networking layer.
protocol ServerConfigTransport: AnyObject {
    var isDeviceIDTemporary: Bool { get }
    /// The device ID requests are built with right now.
    var deviceID: String { get }
    /// The `t` value of the device ID requests are built with right now.
    var deviceIDTypeValue: Int { get }
    /// How many times the device ID was changed with merge in this run.
    var deviceIDMergeCount: Int { get }
    func fetchServerConfig(completion: @escaping (Data?, Int, Error?) -> Void)
}
