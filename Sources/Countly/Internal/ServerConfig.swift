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
/// 3. settings the developer supplied as JSON at init
/// 4. settings fetched from the server, merged into what was stored last run
///
/// When the server says nothing the resolved value equals the developer config,
/// so adopting behavior settings never changes an existing integration.
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
        static let logging = "log"
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
            sessionTracking, logging, limitKeyLength, limitValueSize, limitSegValues, limitBreadcrumb,
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
    private(set) var locationTrackingEnabled = true
    private(set) var viewTrackingEnabled = true
    private(set) var sessionTrackingEnabled = true
    private(set) var loggingEnabled = false
    private(set) var refreshContentZoneEnabled = true
    private(set) var backoffMechanism = true
    private(set) var consentRequired = false

    private(set) var bomAcceptedTimeoutSeconds = 10
    private(set) var bomRQPercentage = 0.5
    private(set) var bomRequestAge = 24
    private(set) var bomDuration = 60

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

    private(set) var userPropertyCacheLimit = 100
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
        automaticSessionTrackingEnabled = !config.manualSessionHandling
        #if os(iOS) || os(tvOS) || os(visionOS)
        automaticViewTrackingEnabled = config.enableAutomaticViewTracking
        #endif
        automaticCrashReportingEnabled = config.features.contains(.crashReporting)

        logger?.d(Self.module, "retrieveFromStorage", "automatic tracking flags seeded from the developer config, automaticSessionTracking: [\(automaticSessionTrackingEnabled)], automaticViewTracking: [\(automaticViewTrackingEnabled)], automaticCrashReporting: [\(automaticCrashReportingEnabled)]")

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
                logger?.e(Self.module, "retrieveFromStorage", "the developer supplied sdkBehaviorSettings are not a JSON object and will be ignored, suppliedLength: [\(supplied.count)]")
            }
        }

        populate(&stored, config: config, source: source)
        store.serverConfig = stored
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

            if response[DocKey.config] != nil {
                var stored = self.store.serverConfig ?? [:]
                self.merge(&stored, incoming: response)
                self.populate(&stored, config: config, source: .serverFetch)
                self.store.serverConfig = stored
                self.logger?.d(Self.module, "fetch", "fetched behavior settings were merged and persisted, responseLength: [\(data?.count ?? 0)], storedEntryCount: [\(stored.count)]")
            } else {
                self.logger?.d(Self.module, "fetch", "no config section in the response, previously stored behavior settings will be kept, responseLength: [\(data?.count ?? 0)]")
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

    // MARK: - Merging

    /// Folds an incoming document into the stored one.
    ///
    /// The server sends only what changed, so keys that are absent must keep their
    /// stored values. A document without a `c` dictionary, a version and a
    /// timestamp is discarded whole rather than partially applied. Top level keys
    /// beyond those three, such as the operator armed `lg` and `ct`, are ignored
    /// here and never reach the cache. An empty `c` is a valid answer meaning the
    /// server has nothing to override.
    private func merge(_ base: inout [String: Any], incoming: [String: Any]) {
        guard let incomingConfig = incoming[DocKey.config] as? [String: Any] else {
            logger?.w(Self.module, "merge", "incoming behavior settings will be ignored, the config section is missing or not a dictionary, entryKeys: [\(sortedKeyList(of: incoming))]")
            return
        }

        guard incoming[DocKey.version] != nil, incoming[DocKey.timestamp] != nil else {
            logger?.w(Self.module, "merge", "incoming behavior settings will be ignored, version or timestamp entry is missing, entryKeys: [\(sortedKeyList(of: incoming))]")
            return
        }

        let incomingVersion = intValue(incoming[DocKey.version]) ?? 0
        let incomingTimestamp = Int64(intValue(incoming[DocKey.timestamp]) ?? 0)
        if incomingVersion < version || incomingTimestamp < timestamp {
            logger?.d(Self.module, "merge", "the incoming behavior settings are older than the ones already in effect and are still applied, the server is the authority on this, incomingVersion: [\(incomingVersion)], currentVersion: [\(version)], incomingTimestamp: [\(incomingTimestamp)], currentTimestamp: [\(timestamp)]")
        }

        base[DocKey.timestamp] = incoming[DocKey.timestamp]
        base[DocKey.version] = incoming[DocKey.version]

        var merged = (base[DocKey.config] as? [String: Any]) ?? [:]
        for (key, value) in incomingConfig where !(value is NSNull) {
            merged[key] = value
        }
        removeConflictingFilterKeys(&merged, incoming: incomingConfig)
        base[DocKey.config] = merged

        logger?.d(Self.module, "merge", "incoming behavior settings merged into the stored ones, version: [\(incomingVersion)], timestamp: [\(incomingTimestamp)], incomingKeyCount: [\(incomingConfig.count)], incomingKeys: [\(sortedKeyList(of: incomingConfig))], mergedKeyCount: [\(merged.count)]")
    }

    /// A category can carry a blacklist or a whitelist, never both. A new list of
    /// one kind evicts a stored list of the other.
    private func removeConflictingFilterKeys(_ merged: inout [String: Any], incoming: [String: Any]) {
        let pairs = [
            (Key.eventBlacklist, Key.eventWhitelist),
            (Key.segmentationBlacklist, Key.segmentationWhitelist),
            (Key.eventSegmentationBlacklist, Key.eventSegmentationWhitelist),
            (Key.userPropertyBlacklist, Key.userPropertyWhitelist),
        ]

        for (blacklistKey, whitelistKey) in pairs {
            if isFilterValue(incoming[blacklistKey]) { merged.removeValue(forKey: whitelistKey) }
            if isFilterValue(incoming[whitelistKey]) { merged.removeValue(forKey: blacklistKey) }
        }
    }

    private func isFilterValue(_ value: Any?) -> Bool {
        value is [Any] || value is [String: Any]
    }

    // MARK: - Applying

    /// Validates and applies a stored document, then tells the rest of the SDK.
    ///
    /// Values of the wrong type or out of range are dropped from the document as
    /// well as ignored, so a bad value cannot keep being reapplied every launch.
    private func populate(_ document: inout [String: Any], config: CountlyConfig, source: Source) {
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

        // Applied whatever the server sent: an explicit local opt-out must hold
        // against a server that says nothing at all, not only against one that
        // enables the mechanism.
        if config.disableBackoffMechanism {
            logger?.d(Self.module, "populate", "the backoff mechanism is off because the developer config disables it, no behavior setting can turn it back on")
            backoffMechanism = false
        }

        guard let rawConfig = document[DocKey.config] as? [String: Any] else {
            if document.isEmpty {
                logger?.d(Self.module, "populate", "no behavior settings are stored yet, the developer configuration stays in effect, source: [\(source.rawValue)]")
            } else {
                logger?.d(Self.module, "populate", "the behavior settings hold no usable config section, the developer configuration stays in effect, source: [\(source.rawValue)], entryKeys: [\(sortedKeyList(of: document))]")
            }
            return
        }

        guard document[DocKey.version] != nil, document[DocKey.timestamp] != nil else {
            logger?.w(Self.module, "populate", "version or timestamp is missing in the behavior settings, the developer configuration stays in effect, source: [\(source.rawValue)], entryKeys: [\(sortedKeyList(of: document))]")
            return
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

        var changes = ChangeLog()

        readBool(&section, Key.tracking, &trackingEnabled, &changes)
        readBool(&section, Key.networking, &networkingEnabled, &changes)
        readInt(&section, Key.sessionUpdateInterval, &sessionInterval, min: 1, &changes)
        readInt(&section, Key.requestQueueSize, &requestQueueSize, min: 1, &changes)
        readInt(&section, Key.eventQueueSize, &eventQueueSize, min: 1, &changes)
        readBool(&section, Key.crashReporting, &crashReportingEnabled, &changes)
        readBool(&section, Key.automaticSessionTracking, &automaticSessionTrackingEnabled, &changes)
        readBool(&section, Key.automaticViewTracking, &automaticViewTrackingEnabled, &changes)
        readBool(&section, Key.automaticCrashReporting, &automaticCrashReportingEnabled, &changes)
        readBool(&section, Key.sessionTracking, &sessionTrackingEnabled, &changes)
        readBool(&section, Key.logging, &loggingEnabled, &changes)
        readInt(&section, Key.limitKeyLength, &limitKeyLength, min: 1, &changes)
        readInt(&section, Key.limitValueSize, &limitValueSize, min: 1, &changes)
        readInt(&section, Key.limitSegValues, &limitSegValues, min: 1, &changes)
        readInt(&section, Key.limitBreadcrumb, &limitBreadcrumb, min: 1, &changes)
        readInt(&section, Key.limitTraceLine, &limitTraceLine, min: 1, &changes)
        readInt(&section, Key.limitTraceLength, &limitTraceLength, min: 1, &changes)
        readBool(&section, Key.customEventTracking, &customEventTrackingEnabled, &changes)
        readBool(&section, Key.viewTracking, &viewTrackingEnabled, &changes)
        readBool(&section, Key.enterContentZone, &enterContentZone, &changes)
        readInt(&section, Key.contentZoneInterval, &contentZoneInterval, min: 16, &changes)
        readBool(&section, Key.consentRequired, &consentRequired, &changes)
        var dropAge = dropOldRequestTime ?? -1
        readInt(&section, Key.dropOldRequestTime, &dropAge, min: 0, &changes)
        dropOldRequestTime = dropAge >= 0 ? dropAge : nil
        readInt(&section, Key.serverConfigUpdateInterval, &serverConfigUpdateInterval, min: 1, &changes)
        readBool(&section, Key.locationTracking, &locationTrackingEnabled, &changes)
        readBool(&section, Key.refreshContentZone, &refreshContentZoneEnabled, &changes)
        if config.disableBackoffMechanism {
            if section[Key.backoffMechanism] != nil {
                logger?.d(Self.module, "populate", "the backoff mechanism setting is not applied, the developer config disables the mechanism")
            }
        } else {
            readBool(&section, Key.backoffMechanism, &backoffMechanism, &changes)
        }
        readInt(&section, Key.bomAcceptedTimeout, &bomAcceptedTimeoutSeconds, min: 1, &changes)
        readDouble(&section, Key.bomRQPercentage, &bomRQPercentage, &changes)
        readInt(&section, Key.bomRequestAge, &bomRequestAge, min: 1, &changes)
        readInt(&section, Key.bomDuration, &bomDuration, min: 1, &changes)
        readInt(&section, Key.userPropertyCacheLimit, &userPropertyCacheLimit, min: 1, &changes)

        updateListingFilters(&section, changes: &changes)

        document[DocKey.config] = section

        if !changes.keys.isEmpty {
            notifyChange(config: config, changedKeys: changes.keys)
        }

        logger?.d(Self.module, "populate", "behavior settings applied, source: [\(source.rawValue)], version: [\(version)], timestamp: [\(timestamp)], changedCount: [\(changes.keys.count)], changedValues: [\(changes.descriptions.joined(separator: ", "))]")
        logEffectiveConfiguration(config: config)
    }

    /// The state every layer resolved to, printed as the counterpart of the
    /// developer layer line so the two can be diffed straight out of a log dump.
    private func logEffectiveConfiguration(config: CountlyConfig) {
        logger?.d(Self.module, "populate", "effective behavior switches, tracking: [\(trackingEnabled)], networking: [\(networkingEnabled)], crashReporting: [\(crashReportingEnabled)], customEventTracking: [\(customEventTrackingEnabled)], sessionTracking: [\(sessionTrackingEnabled)], viewTracking: [\(viewTrackingEnabled)], locationTracking: [\(locationTrackingEnabled)], automaticSessionTracking: [\(automaticSessionTrackingEnabled)], automaticViewTracking: [\(automaticViewTrackingEnabled)], automaticCrashReporting: [\(automaticCrashReportingEnabled)], enterContentZone: [\(enterContentZone)], refreshContentZone: [\(refreshContentZoneEnabled)], backoffMechanism: [\(backoffMechanism)], consentRequired: [\(consentRequired)], logging: [\(loggingEnabled)]")

        let limits = config.sdkInternalLimits
        logger?.d(Self.module, "populate", "effective behavior values, eventSendThreshold: [\(config.eventSendThreshold)], storedRequestsLimit: [\(config.storedRequestsLimit)], requestDropAgeHours: [\(config.requestDropAgeHours)], updateSessionPeriod: [\(config.updateSessionPeriod.logSeconds)], requestTimeoutDuration: [\(requestTimeoutDuration.logSeconds)], contentZoneTimerInterval: [\(config.content.zoneTimerInterval)], userPropertyCacheLimit: [\(userPropertyCacheLimit)], backoffAcceptedTimeoutSeconds: [\(bomAcceptedTimeoutSeconds)], backoffQueuePercentage: [\(bomRQPercentage.logValue)], backoffRequestAgeHours: [\(bomRequestAge)], backoffDurationSeconds: [\(bomDuration)], maxKeyLength: [\(limits.maxKeyLength)], maxValueSize: [\(limits.maxValueSize)], maxSegmentationValues: [\(limits.maxSegmentationValues)], maxBreadcrumbCount: [\(limits.maxBreadcrumbCount)], maxStackTraceLineLength: [\(limits.maxStackTraceLineLength)], maxStackTraceLinesPerThread: [\(limits.maxStackTraceLinesPerThread)]")
    }

    /// Pushes the resolved values into the rest of the SDK.
    ///
    /// - Parameter changedKeys: the `c` keys whose value this apply changed.
    private func notifyChange(config: CountlyConfig, changedKeys: Set<String>) {
        // The server may switch logging on for an application that never asked
        // for it, which is how support gets a trace out of a shipped build.
        if loggingEnabled, !config.enableDebug {
            logger?.d(Self.module, "notifyChange", "logging is switched on by behavior settings for an application that did not ask for it")
        }
        config.enableDebug = loggingEnabled || config.enableDebug

        // Only the values that actually displace a developer one are collected, so
        // the line below reads as the list of settings the server took over.
        var overrides: [String] = []

        /// Zero means the server said nothing about this setting, which leaves the
        /// developer's value alone.
        func apply(_ name: String, _ target: inout Int, _ value: Int) {
            guard value > 0 else { return }
            if target != value {
                overrides.append("\(name): \(target) to \(value)")
            }
            target = value
        }

        let limits = config.sdkInternalLimits
        apply("maxKeyLength", &limits.maxKeyLength, limitKeyLength)
        apply("maxValueSize", &limits.maxValueSize, limitValueSize)
        apply("maxSegmentationValues", &limits.maxSegmentationValues, limitSegValues)
        apply("maxBreadcrumbCount", &limits.maxBreadcrumbCount, limitBreadcrumb)
        apply("maxStackTraceLineLength", &limits.maxStackTraceLineLength, limitTraceLength)
        apply("maxStackTraceLinesPerThread", &limits.maxStackTraceLinesPerThread, limitTraceLine)

        apply("eventSendThreshold", &config.eventSendThreshold, eventQueueSize)
        // Its own path because the shared `apply` reads zero as absent.
        if let dropAge = dropOldRequestTime {
            if config.requestDropAgeHours != dropAge {
                overrides.append("requestDropAgeHours: \(config.requestDropAgeHours) to \(dropAge)")
            }
            config.requestDropAgeHours = dropAge
        }
        apply("storedRequestsLimit", &config.storedRequestsLimit, requestQueueSize)

        if sessionInterval > 0 {
            let previousPeriod = Int(config.updateSessionPeriod)
            if previousPeriod != sessionInterval {
                overrides.append("updateSessionPeriod: \(previousPeriod) to \(sessionInterval)")
            }
            config.updateSessionPeriod = TimeInterval(sessionInterval)
        } else {
            sessionInterval = Int(config.updateSessionPeriod)
        }

        let consentBecameRequired = !config.requiresConsent && consentRequired
        if consentRequired { config.requiresConsent = true }
        if consentBecameRequired {
            logger?.d(Self.module, "notifyChange", "consent is now required by behavior settings for an application that did not require it, the consent state will be sent again")
        }

        apply("contentZoneTimerInterval", &config.content.zoneTimerInterval, contentZoneInterval)

        if !overrides.isEmpty {
            logger?.d(Self.module, "notifyChange", "behavior settings displaced developer configured values, overrideCount: [\(overrides.count)], overrides: [\(overrides.joined(separator: ", "))]")
        }

        // A backoff mechanism the developer switched off stays off, whatever the
        // server says: an explicit local opt-out outranks a remote default.
        if backoffMechanism, config.disableBackoffMechanism {
            logger?.d(Self.module, "notifyChange", "backoff mechanism is enabled by behavior settings but disabled in the developer config, it will stay off")
            backoffMechanism = false
        }

        if serverConfigUpdateInterval > 0,
           serverConfigUpdateInterval != currentUpdateIntervalHours,
           refreshTimer != nil {
            logger?.d(Self.module, "notifyChange", "behavior settings refresh timer will be rescheduled, intervalHours: [\(serverConfigUpdateInterval)]")
            currentUpdateIntervalHours = serverConfigUpdateInterval
            refreshTimer?.invalidate()
            refreshTimer = nil
            installRefreshTimer(config: config)
        }

        delegate?.serverConfigDidChange(self, consentBecameRequired: consentBecameRequired, changedKeys: changedKeys)
    }

    // MARK: - Value readers

    /// Reads a boolean, dropping the key when the value is not one.
    private func readBool(_ section: inout [String: Any], _ key: String, _ target: inout Bool, _ changes: inout ChangeLog) {
        guard let value = section[key] else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            logger?.w(Self.module, "readBool", "dropping behavior setting, a boolean was expected, key: [\(key)], receivedType: [\(type(of: value))]")
            section.removeValue(forKey: key)
            return
        }
        let previous = target
        target = number.boolValue
        if previous != target {
            changes.record(key, "\(target)")
        }
        logger?.d(Self.module, "readBool", "a behavior settings switch was resolved, key: [\(key)], previousValue: [\(previous)], newValue: [\(target)], changed: [\(previous != target)]")
    }

    /// Reads an integer at or above `min`, dropping the key otherwise.
    private func readInt(_ section: inout [String: Any], _ key: String, _ target: inout Int, min minimum: Int, _ changes: inout ChangeLog) {
        guard let value = section[key] else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            logger?.w(Self.module, "readInt", "dropping behavior setting, an integer was expected, key: [\(key)], receivedType: [\(type(of: value))]")
            section.removeValue(forKey: key)
            return
        }
        let intValue = number.intValue
        guard intValue >= minimum else {
            logger?.w(Self.module, "readInt", "dropping behavior setting, value is below the accepted minimum, key: [\(key)], value: [\(intValue)], minValue: [\(minimum)]")
            section.removeValue(forKey: key)
            return
        }
        let previous = target
        target = intValue
        if previous != intValue {
            changes.record(key, "\(intValue)")
        }
        logger?.d(Self.module, "readInt", "a behavior settings count was resolved, key: [\(key)], previousValue: [\(previous)], newValue: [\(intValue)], changed: [\(previous != intValue)]")
    }

    /// Reads a fraction strictly between 0 and 1, dropping the key otherwise.
    private func readDouble(_ section: inout [String: Any], _ key: String, _ target: inout Double, _ changes: inout ChangeLog) {
        guard let value = section[key] else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            logger?.w(Self.module, "readDouble", "dropping behavior setting, a double was expected, key: [\(key)], receivedType: [\(type(of: value))]")
            section.removeValue(forKey: key)
            return
        }
        let doubleValue = number.doubleValue
        guard doubleValue > 0.0, doubleValue < 1.0 else {
            logger?.w(Self.module, "readDouble", "dropping behavior setting, value is out of the accepted range, key: [\(key)], value: [\(doubleValue.logValue)], acceptedRange: [0.0 to 1.0]")
            section.removeValue(forKey: key)
            return
        }
        let previous = target
        target = doubleValue
        if previous != doubleValue {
            changes.record(key, doubleValue.logValue)
        }
        logger?.d(Self.module, "readDouble", "a behavior settings fraction was resolved, key: [\(key)], previousValue: [\(previous.logValue)], newValue: [\(doubleValue.logValue)], changed: [\(previous != doubleValue)]")
    }

    private func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    // MARK: - Listing filters

    /// Resolves the blacklist and whitelist pairs. A blacklist always wins when
    /// both are present, because excluding is the safer of the two.
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
        if let blacklist = section[blacklistKey] as? [String] {
            let resolved = Set(blacklist)
            if resolved != set || isWhitelist {
                changes.record(blacklistKey, blacklist.joined(separator: ", "))
            }
            set = resolved
            isWhitelist = false
            section.removeValue(forKey: whitelistKey)
        } else if let whitelist = section[whitelistKey] as? [String] {
            let resolved = Set(whitelist)
            if resolved != set || !isWhitelist {
                changes.record(whitelistKey, whitelist.joined(separator: ", "))
            }
            set = resolved
            isWhitelist = true
        } else {
            logUnusableFilter(section, blacklistKey, whitelistKey)
            section.removeValue(forKey: blacklistKey)
            section.removeValue(forKey: whitelistKey)
        }
    }

    /// A filter that arrived in a shape the SDK cannot read is dropped like any
    /// other unusable value. Saying so is the only way an integration can tell a
    /// filter that was refused from one that was never sent.
    private func logUnusableFilter(_ section: [String: Any], _ keys: String...) {
        for key in keys {
            guard let value = section[key] else { continue }
            logger?.d(Self.module, "updateListingFilters", "a behavior settings filter is not in a readable shape and will be dropped, key: [\(key)], receivedType: [\(type(of: value))]")
        }
    }

    private func resolveMapFilter(_ section: inout [String: Any],
                                  blacklistKey: String,
                                  whitelistKey: String,
                                  map: inout [String: Set<String>],
                                  isWhitelist: inout Bool,
                                  changes: inout ChangeLog) {
        func build(_ raw: [String: Any]) -> [String: Set<String>] {
            var result: [String: Set<String>] = [:]
            for (key, value) in raw {
                if let list = value as? [String] { result[key] = Set(list) }
            }
            return result
        }

        if let blacklist = section[blacklistKey] as? [String: Any] {
            let resolved = build(blacklist)
            if resolved != map || isWhitelist {
                changes.record(blacklistKey, sortedKeyList(of: blacklist))
            }
            map = resolved
            isWhitelist = false
            section.removeValue(forKey: whitelistKey)
        } else if let whitelist = section[whitelistKey] as? [String: Any] {
            let resolved = build(whitelist)
            if resolved != map || !isWhitelist {
                changes.record(whitelistKey, sortedKeyList(of: whitelist))
            }
            map = resolved
            isWhitelist = true
        } else {
            logUnusableFilter(section, blacklistKey, whitelistKey)
            section.removeValue(forKey: blacklistKey)
            section.removeValue(forKey: whitelistKey)
        }
    }

    private func resolveNameSet(_ section: inout [String: Any], key: String, set: inout Set<String>, changes: inout ChangeLog) {
        if let list = section[key] as? [String] {
            let resolved = Set(list)
            if resolved != set {
                changes.record(key, list.joined(separator: ", "))
            }
            set = resolved
        } else {
            logUnusableFilter(section, key)
            section.removeValue(forKey: key)
        }
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
    /// - Parameters:
    ///   - consentBecameRequired: `true` when the server turned consent
    ///     requirement on for an application that did not require it, which means
    ///     the consent state has to be resent.
    ///   - changedKeys: the `c` keys, named as in ``ServerConfig/Key``, whose
    ///     value this apply changed.
    func serverConfigDidChange(_ serverConfig: ServerConfig, consentBecameRequired: Bool, changedKeys: Set<String>)
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
