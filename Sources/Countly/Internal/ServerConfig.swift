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
    }

    /// Keys inside the `c` section.
    private enum Key {
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
    private(set) var dropOldRequestTime = 0
    private(set) var contentZoneInterval = 0

    private(set) var userPropertyCacheLimit = 100
    private(set) var requestTimeoutDuration: TimeInterval = 30

    // MARK: - Listing filters

    private var eventFilterSet: Set<String> = []
    private var eventFilterIsWhitelist = false
    private var userPropertyFilterSet: Set<String> = []
    private var userPropertyFilterIsWhitelist = false
    private var segmentationFilterSet: Set<String> = []
    private var segmentationFilterIsWhitelist = false
    private var eventSegmentationFilterMap: [String: Set<String>] = [:]
    private var eventSegmentationFilterIsWhitelist = false
    private var journeyTriggerEvents: Set<String> = []
    private var journeyTriggerViews: Set<String> = []

    // MARK: - Fetch bookkeeping

    private var version = 0
    private var timestamp: Int64 = 0
    private var lastFetchTimestamp: Int64 = 0
    private var currentUpdateIntervalHours = 4
    private var serverConfigUpdateInterval = 0
    private var updatesDisabled = false
    private var refreshTimer: Timer?

    // MARK: - Collaborators

    private let store: KeyValueStore
    private weak var logger: Logger?

    /// Applies resolved values to the rest of the SDK. Weak: the instance owns
    /// this object.
    weak var delegate: ServerConfigDelegate?

    /// Performs the fetch. Weak for the same reason.
    weak var transport: ServerConfigTransport?

    init(store: KeyValueStore, logger: Logger?) {
        self.store = store
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Stops the refresh timer. Called from `halt`.
    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Turns off every fetch, at the developer's request.
    func disableUpdates() {
        logger?.i(Self.module, "disableUpdates", "behavior settings updates are being disabled")
        updatesDisabled = true
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

        var stored = store.serverConfig ?? [:]
        logger?.d(Self.module, "retrieveFromStorage", "behavior settings read from persisted cache, keyCount: [\(stored.count)], developerSuppliedSettings: [\(config.sdkBehaviorSettings != nil)]")

        if stored.isEmpty, let supplied = config.sdkBehaviorSettings {
            if let parsed = CountlyJSON.object(from: Data(supplied.utf8), logger: logger) as? [String: Any] {
                stored = parsed
                logger?.d(Self.module, "retrieveFromStorage", "cache was empty, falling back to developer supplied behavior settings, keyCount: [\(stored.count)]")
            } else {
                logger?.e(Self.module, "retrieveFromStorage", "could not parse developer supplied sdkBehaviorSettings, they will be ignored")
            }
        }

        populate(&stored, config: config)
        store.serverConfig = stored
    }

    // MARK: - Layer 4: the server

    /// Whether enough time has passed to refresh, used on foreground.
    func fetchIfTimeIsUp(config: CountlyConfig) {
        guard !updatesDisabled else {
            logger?.d(Self.module, "fetchIfTimeIsUp", "periodic behavior settings check skipped, updates are disabled")
            return
        }
        guard lastFetchTimestamp != 0 else { return }

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = now - lastFetchTimestamp
        let interval = Int64(currentUpdateIntervalHours) * 60 * 60 * 1000

        if elapsed > interval {
            logger?.d(Self.module, "fetchIfTimeIsUp", "behavior settings refresh interval elapsed, a fetch will be triggered, timePassedMs: [\(elapsed)], intervalHours: [\(currentUpdateIntervalHours)]")
            fetch(config: config)
        }
    }

    /// Asks the server for behavior settings and merges the answer into what is
    /// stored.
    func fetch(config: CountlyConfig) {
        logger?.d(Self.module, "fetch", "starting a behavior settings fetch, currentVersion: [\(version)], updateIntervalHours: [\(currentUpdateIntervalHours)]")

        guard !updatesDisabled else {
            logger?.d(Self.module, "fetch", "fetch aborted, behavior settings updates are disabled")
            return
        }

        guard let transport, !transport.isDeviceIDTemporary else {
            logger?.d(Self.module, "fetch", "fetch aborted, sdk is in temporary device ID mode")
            return
        }

        lastFetchTimestamp = Int64(Date().timeIntervalSince1970 * 1000)
        scheduleRefreshTimerIfNeeded(config: config)

        transport.fetchServerConfig { [weak self] data, statusCode, error in
            guard let self else { return }

            if let error {
                self.logger?.d(Self.module, "fetch", "behavior settings fetch failed, statusCode: [\(statusCode)], error: [\(error.localizedDescription)]")
                return
            }

            guard statusCode == 200 else {
                self.logger?.d(Self.module, "fetch", "behavior settings fetch failed, statusCode: [\(statusCode)]")
                return
            }

            guard let response = CountlyJSON.object(from: data, logger: self.logger) as? [String: Any],
                  response[DocKey.config] != nil else {
                self.logger?.d(Self.module, "fetch", "no config section in the response, previously stored behavior settings will be kept")
                return
            }

            var stored = self.store.serverConfig ?? [:]
            self.merge(&stored, incoming: response)
            self.populate(&stored, config: config)
            self.store.serverConfig = stored
            self.logger?.d(Self.module, "fetch", "fetched behavior settings were merged and persisted, storedKeyCount: [\(stored.count)]")
        }
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
    /// stored values. A document that is not shaped like `{t, v, c}` is discarded
    /// whole rather than partially applied.
    private func merge(_ base: inout [String: Any], incoming: [String: Any]) {
        guard incoming.count == 3, let incomingConfig = incoming[DocKey.config] as? [String: Any] else {
            logger?.w(Self.module, "merge", "incoming behavior settings will be ignored, expected 3 entries including a config section, entryCount: [\(incoming.count)]")
            return
        }

        guard incoming[DocKey.version] != nil, incoming[DocKey.timestamp] != nil else {
            logger?.w(Self.module, "merge", "incoming behavior settings will be ignored, version or timestamp entry is missing")
            return
        }

        guard !incomingConfig.isEmpty else {
            logger?.w(Self.module, "merge", "incoming behavior settings will be ignored, config section is empty or not a dictionary")
            return
        }

        base[DocKey.timestamp] = incoming[DocKey.timestamp]
        base[DocKey.version] = incoming[DocKey.version]

        var merged = (base[DocKey.config] as? [String: Any]) ?? [:]
        for (key, value) in incomingConfig where !(value is NSNull) {
            merged[key] = value
        }
        removeConflictingFilterKeys(&merged, incoming: incomingConfig)
        base[DocKey.config] = merged

        logger?.d(Self.module, "merge", "incoming behavior settings merged into the stored ones, incomingKeyCount: [\(incomingConfig.count)], mergedKeyCount: [\(merged.count)]")
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
    private func populate(_ document: inout [String: Any], config: CountlyConfig) {
        if config.requestTimeoutDuration <= 0 {
            config.requestTimeoutDuration = 1
        }
        requestTimeoutDuration = config.requestTimeoutDuration

        // Applied whatever the server sent: an explicit local opt-out must hold
        // against a server that says nothing at all, not only against one that
        // enables the mechanism.
        if config.disableBackoffMechanism {
            backoffMechanism = false
        }

        guard let rawConfig = document[DocKey.config] as? [String: Any] else {
            logger?.d(Self.module, "populate", "no usable config section in the behavior settings, falling back to SDK defaults")
            return
        }

        guard document[DocKey.version] != nil, document[DocKey.timestamp] != nil else {
            logger?.w(Self.module, "populate", "version or timestamp is missing in the behavior settings, falling back to SDK defaults")
            return
        }

        version = intValue(document[DocKey.version]) ?? 0
        timestamp = Int64(intValue(document[DocKey.timestamp]) ?? 0)

        var section = rawConfig
        for key in section.keys where !Key.known.contains(key) {
            logger?.d(Self.module, "populate", "unknown behavior setting key will be dropped, key: [\(key)]")
            section.removeValue(forKey: key)
        }

        var applied: [String] = []

        readBool(&section, Key.tracking, &trackingEnabled, &applied)
        readBool(&section, Key.networking, &networkingEnabled, &applied)
        readInt(&section, Key.sessionUpdateInterval, &sessionInterval, min: 1, &applied)
        readInt(&section, Key.requestQueueSize, &requestQueueSize, min: 1, &applied)
        readInt(&section, Key.eventQueueSize, &eventQueueSize, min: 1, &applied)
        readBool(&section, Key.crashReporting, &crashReportingEnabled, &applied)
        readBool(&section, Key.automaticSessionTracking, &automaticSessionTrackingEnabled, &applied)
        readBool(&section, Key.automaticViewTracking, &automaticViewTrackingEnabled, &applied)
        readBool(&section, Key.automaticCrashReporting, &automaticCrashReportingEnabled, &applied)
        readBool(&section, Key.sessionTracking, &sessionTrackingEnabled, &applied)
        readBool(&section, Key.logging, &loggingEnabled, &applied)
        readInt(&section, Key.limitKeyLength, &limitKeyLength, min: 1, &applied)
        readInt(&section, Key.limitValueSize, &limitValueSize, min: 1, &applied)
        readInt(&section, Key.limitSegValues, &limitSegValues, min: 1, &applied)
        readInt(&section, Key.limitBreadcrumb, &limitBreadcrumb, min: 1, &applied)
        readInt(&section, Key.limitTraceLine, &limitTraceLine, min: 1, &applied)
        readInt(&section, Key.limitTraceLength, &limitTraceLength, min: 1, &applied)
        readBool(&section, Key.customEventTracking, &customEventTrackingEnabled, &applied)
        readBool(&section, Key.viewTracking, &viewTrackingEnabled, &applied)
        readBool(&section, Key.enterContentZone, &enterContentZone, &applied)
        readInt(&section, Key.contentZoneInterval, &contentZoneInterval, min: 16, &applied)
        readBool(&section, Key.consentRequired, &consentRequired, &applied)
        readInt(&section, Key.dropOldRequestTime, &dropOldRequestTime, min: 0, &applied)
        readInt(&section, Key.serverConfigUpdateInterval, &serverConfigUpdateInterval, min: 1, &applied)
        readBool(&section, Key.locationTracking, &locationTrackingEnabled, &applied)
        readBool(&section, Key.refreshContentZone, &refreshContentZoneEnabled, &applied)
        readBool(&section, Key.backoffMechanism, &backoffMechanism, &applied)
        readInt(&section, Key.bomAcceptedTimeout, &bomAcceptedTimeoutSeconds, min: 1, &applied)
        readDouble(&section, Key.bomRQPercentage, &bomRQPercentage, &applied)
        readInt(&section, Key.bomRequestAge, &bomRequestAge, min: 1, &applied)
        readInt(&section, Key.bomDuration, &bomDuration, min: 1, &applied)
        readInt(&section, Key.userPropertyCacheLimit, &userPropertyCacheLimit, min: 1, &applied)

        updateListingFilters(&section, applied: &applied)

        document[DocKey.config] = section

        if !applied.isEmpty {
            notifyChange(config: config)
        }

        logger?.d(Self.module, "populate", "behavior settings applied, version: [\(version)], timestamp: [\(timestamp)], appliedValues: [\(applied.joined(separator: ", "))]")
    }

    /// Pushes the resolved values into the rest of the SDK.
    private func notifyChange(config: CountlyConfig) {
        // The server may switch logging on for an application that never asked
        // for it, which is how support gets a trace out of a shipped build.
        config.enableDebug = loggingEnabled || config.enableDebug

        let limits = config.sdkInternalLimits
        if limitKeyLength > 0 { limits.maxKeyLength = limitKeyLength }
        if limitValueSize > 0 { limits.maxValueSize = limitValueSize }
        if limitSegValues > 0 { limits.maxSegmentationValues = limitSegValues }
        if limitBreadcrumb > 0 { limits.maxBreadcrumbCount = limitBreadcrumb }
        if limitTraceLength > 0 { limits.maxStackTraceLineLength = limitTraceLength }
        if limitTraceLine > 0 { limits.maxStackTraceLinesPerThread = limitTraceLine }

        if eventQueueSize > 0 { config.eventSendThreshold = eventQueueSize }
        if dropOldRequestTime > 0 { config.requestDropAgeHours = dropOldRequestTime }
        if requestQueueSize > 0 { config.storedRequestsLimit = requestQueueSize }
        if sessionInterval > 0 {
            config.updateSessionPeriod = TimeInterval(sessionInterval)
        } else {
            sessionInterval = Int(config.updateSessionPeriod)
        }

        let consentBecameRequired = !config.requiresConsent && consentRequired
        if consentRequired { config.requiresConsent = true }

        if contentZoneInterval > 0 { config.content.zoneTimerInterval = contentZoneInterval }

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

        delegate?.serverConfigDidChange(self, consentBecameRequired: consentBecameRequired)
    }

    // MARK: - Value readers

    /// Reads a boolean, dropping the key when the value is not one.
    private func readBool(_ section: inout [String: Any], _ key: String, _ target: inout Bool, _ applied: inout [String]) {
        guard let value = section[key] else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            logger?.w(Self.module, "readBool", "dropping behavior setting, a boolean was expected, key: [\(key)], receivedType: [\(type(of: value))]")
            section.removeValue(forKey: key)
            return
        }
        target = number.boolValue
        applied.append("\(key): \(target)")
    }

    /// Reads an integer at or above `min`, dropping the key otherwise.
    private func readInt(_ section: inout [String: Any], _ key: String, _ target: inout Int, min minimum: Int, _ applied: inout [String]) {
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
        target = intValue
        applied.append("\(key): \(intValue)")
    }

    /// Reads a fraction strictly between 0 and 1, dropping the key otherwise.
    private func readDouble(_ section: inout [String: Any], _ key: String, _ target: inout Double, _ applied: inout [String]) {
        guard let value = section[key] else { return }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            logger?.w(Self.module, "readDouble", "dropping behavior setting, a double was expected, key: [\(key)], receivedType: [\(type(of: value))]")
            section.removeValue(forKey: key)
            return
        }
        let doubleValue = number.doubleValue
        guard doubleValue > 0.0, doubleValue < 1.0 else {
            logger?.w(Self.module, "readDouble", "dropping behavior setting, value is out of the accepted range, key: [\(key)], value: [\(doubleValue)], acceptedRange: [0.0 - 1.0]")
            section.removeValue(forKey: key)
            return
        }
        target = doubleValue
        applied.append("\(key): \(doubleValue)")
    }

    private func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    // MARK: - Listing filters

    /// Resolves the blacklist and whitelist pairs. A blacklist always wins when
    /// both are present, because excluding is the safer of the two.
    private func updateListingFilters(_ section: inout [String: Any], applied: inout [String]) {
        resolveListFilter(&section,
                          blacklistKey: Key.eventBlacklist,
                          whitelistKey: Key.eventWhitelist,
                          set: &eventFilterSet,
                          isWhitelist: &eventFilterIsWhitelist,
                          applied: &applied)

        resolveListFilter(&section,
                          blacklistKey: Key.userPropertyBlacklist,
                          whitelistKey: Key.userPropertyWhitelist,
                          set: &userPropertyFilterSet,
                          isWhitelist: &userPropertyFilterIsWhitelist,
                          applied: &applied)

        resolveListFilter(&section,
                          blacklistKey: Key.segmentationBlacklist,
                          whitelistKey: Key.segmentationWhitelist,
                          set: &segmentationFilterSet,
                          isWhitelist: &segmentationFilterIsWhitelist,
                          applied: &applied)

        resolveMapFilter(&section,
                         blacklistKey: Key.eventSegmentationBlacklist,
                         whitelistKey: Key.eventSegmentationWhitelist,
                         map: &eventSegmentationFilterMap,
                         isWhitelist: &eventSegmentationFilterIsWhitelist,
                         applied: &applied)

        resolveNameSet(&section, key: Key.journeyTriggerEvents, set: &journeyTriggerEvents, applied: &applied)
        resolveNameSet(&section, key: Key.journeyTriggerViews, set: &journeyTriggerViews, applied: &applied)

        logger?.d(Self.module, "updateListingFilters", "resolved listing filters, eventFilterCount: [\(eventFilterSet.count)], eventFilterIsWhitelist: [\(eventFilterIsWhitelist)], userPropertyFilterCount: [\(userPropertyFilterSet.count)], userPropertyFilterIsWhitelist: [\(userPropertyFilterIsWhitelist)], segmentationFilterCount: [\(segmentationFilterSet.count)], segmentationFilterIsWhitelist: [\(segmentationFilterIsWhitelist)], eventSegmentationFilteredEventCount: [\(eventSegmentationFilterMap.count)], eventSegmentationFilterIsWhitelist: [\(eventSegmentationFilterIsWhitelist)], journeyTriggerEventCount: [\(journeyTriggerEvents.count)], journeyTriggerViewCount: [\(journeyTriggerViews.count)]")
    }

    private func resolveListFilter(_ section: inout [String: Any],
                                   blacklistKey: String,
                                   whitelistKey: String,
                                   set: inout Set<String>,
                                   isWhitelist: inout Bool,
                                   applied: inout [String]) {
        if let blacklist = section[blacklistKey] as? [String] {
            set = Set(blacklist)
            isWhitelist = false
            applied.append("\(blacklistKey): \(blacklist)")
            section.removeValue(forKey: whitelistKey)
        } else if let whitelist = section[whitelistKey] as? [String] {
            set = Set(whitelist)
            isWhitelist = true
            applied.append("\(whitelistKey): \(whitelist)")
        } else {
            section.removeValue(forKey: blacklistKey)
            section.removeValue(forKey: whitelistKey)
        }
    }

    private func resolveMapFilter(_ section: inout [String: Any],
                                  blacklistKey: String,
                                  whitelistKey: String,
                                  map: inout [String: Set<String>],
                                  isWhitelist: inout Bool,
                                  applied: inout [String]) {
        func build(_ raw: [String: Any]) -> [String: Set<String>] {
            var result: [String: Set<String>] = [:]
            for (key, value) in raw {
                if let list = value as? [String] { result[key] = Set(list) }
            }
            return result
        }

        if let blacklist = section[blacklistKey] as? [String: Any] {
            map = build(blacklist)
            isWhitelist = false
            applied.append("\(blacklistKey): \(blacklist.keys.sorted())")
            section.removeValue(forKey: whitelistKey)
        } else if let whitelist = section[whitelistKey] as? [String: Any] {
            map = build(whitelist)
            isWhitelist = true
            applied.append("\(whitelistKey): \(whitelist.keys.sorted())")
        } else {
            section.removeValue(forKey: blacklistKey)
            section.removeValue(forKey: whitelistKey)
        }
    }

    private func resolveNameSet(_ section: inout [String: Any], key: String, set: inout Set<String>, applied: inout [String]) {
        if let list = section[key] as? [String] {
            set = Set(list)
            applied.append("\(key): \(list)")
        } else {
            section.removeValue(forKey: key)
        }
    }

    // MARK: - Filter queries

    /// Whether an event key survives the event filter.
    func shouldRecordEvent(_ eventKey: String) -> Bool {
        guard !eventFilterSet.isEmpty else { return true }
        return eventFilterIsWhitelist == eventFilterSet.contains(eventKey)
    }

    /// Whether a user property key survives the user property filter.
    func shouldRecordUserProperty(_ propertyKey: String) -> Bool {
        guard !userPropertyFilterSet.isEmpty else { return true }
        return userPropertyFilterIsWhitelist == userPropertyFilterSet.contains(propertyKey)
    }

    /// Drops segmentation keys that the global or per-event filter excludes.
    func filterSegmentation(_ segmentation: [String: Any]?, eventKey: String) -> [String: Any]? {
        guard let segmentation else { return nil }

        let hasGlobalFilter = !segmentationFilterSet.isEmpty
        let eventFilter = eventSegmentationFilterMap[eventKey]
        let hasEventFilter = !(eventFilter?.isEmpty ?? true)

        guard hasGlobalFilter || hasEventFilter else { return segmentation }

        var result = segmentation
        for key in segmentation.keys {
            if hasGlobalFilter, segmentationFilterIsWhitelist != segmentationFilterSet.contains(key) {
                logger?.v(Self.module, "filterSegmentation", "dropping segmentation key by the global segmentation filter, key: [\(key)], filterIsWhitelist: [\(segmentationFilterIsWhitelist)]")
                result.removeValue(forKey: key)
            } else if hasEventFilter, let eventFilter,
                      eventSegmentationFilterIsWhitelist != eventFilter.contains(key) {
                logger?.v(Self.module, "filterSegmentation", "dropping segmentation key by the event level segmentation filter, key: [\(key)], eventKey: [\(eventKey)]")
                result.removeValue(forKey: key)
            }
        }
        return result
    }

    /// Whether recording this event should also flush the queue, so a journey can
    /// react to it right away.
    func isJourneyTriggerEvent(_ eventKey: String) -> Bool {
        journeyTriggerEvents.contains(eventKey)
    }

    /// Whether starting this view should also flush the queue.
    func isJourneyTriggerView(_ viewName: String) -> Bool {
        journeyTriggerViews.contains(viewName)
    }
}

/// Applies resolved behavior settings to the rest of the SDK.
protocol ServerConfigDelegate: AnyObject {
    /// - Parameter consentBecameRequired: `true` when the server turned consent
    ///   requirement on for an application that did not require it, which means
    ///   the consent state has to be resent.
    func serverConfigDidChange(_ serverConfig: ServerConfig, consentBecameRequired: Bool)
}

/// What the behavior settings fetch needs from the networking layer.
protocol ServerConfigTransport: AnyObject {
    var isDeviceIDTemporary: Bool { get }
    func fetchServerConfig(completion: @escaping (Data?, Int, Error?) -> Void)
}
