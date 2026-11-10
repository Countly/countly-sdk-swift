//
//  RemoteConfigModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Downloads server-controlled values and A/B variants.
///
/// Values are cached on disk so the host application has something to read on the
/// very first frame of a cold launch, before any network call could have
/// answered. After a user change the cache is kept but marked as belonging to the
/// previous user, so the application can decide whether a stale value is
/// acceptable.
final class RemoteConfigModule: ModuleBase {

    override class var moduleName: String { "RemoteConfig" }

    /// Request kinds and payload keys.
    private enum Key {
        static let fetchRemoteConfigLegacy = "fetch_remote_config"
        static let fetchVariant = "ab_fetch_variants"
        static let enrollVariant = "ab_enroll_variant"
        static let fetchExperiments = "ab_fetch_experiments"
        /// Key the experiment array is nested under in the server's answer.
        static let experimentArray = "jsonArray"
        static let variant = "variant"
        /// Key each variant object carries its name under.
        static let variantName = "name"
        static let key = "key"
        static let remoteConfig = "rc"
        static let autoOptIn = "oi"
    }

    /// Keys of a value cached as a dictionary, a shape that is read and rewritten.
    private enum CacheKey {
        static let value = "v"
        static let isCurrentUsersData = "c"
    }

    /// Cached values, keyed by remote config key.
    private var cachedRemoteConfig: [String: CountlyRCData] = [:]

    /// Guards the caches and the callback list, all of which are written from
    /// URLSession completions and read from the caller's thread.
    private let stateLock = NSLock()

    /// A/B variants from the last testing download.
    private var localCachedVariants: [String: [String]] = [:]

    /// Experiment information from the last testing download.
    private var localCachedExperiments: [String: CountlyExperimentInformation] = [:]

    /// Callbacks notified after each download.
    /// Registered download callbacks, keyed by the token handed back to whoever
    /// registered them.
    ///
    /// Keyed rather than a plain array because a Swift closure has no identity to
    /// compare against, so removing one needs an identity of its own. The token is
    /// that identity.
    private var downloadCallbacks: [RCCallbackToken: RCDownloadCallback] = [:]
    private var nextCallbackToken: UInt64 = 0

    /// Whether the SDK downloads on its own at init and after a user change.
    var isAutomaticTriggersEnabled = false

    /// Whether values survive a user change as stale rather than being erased.
    var isValueCachingEnabled = false

    /// Whether every download also enrolls the device in the matching A/B tests.
    var enrollABOnRCDownload = false

    private let lock = NSLock()

    // MARK: - Init

    func applyInitialConfig() {
        isAutomaticTriggersEnabled = core.config.enableRemoteConfigAutomaticTriggers
        isValueCachingEnabled = core.config.enableRemoteConfigValueCaching
        enrollABOnRCDownload = core.config.enrollABOnRCDownload

        logI("applyInitialConfig", "remote config initial configuration is applied, automaticTriggersEnabled: [\(isAutomaticTriggersEnabled)], valueCachingEnabled: [\(isValueCachingEnabled)], enrollABOnDownload: [\(enrollABOnRCDownload)], globalCallbackCount: [\(core.config.remoteConfigGlobalCallbacks.count)]")

        for callback in core.config.remoteConfigGlobalCallbacks {
            _ = registerDownloadCallback(callback)
        }

        loadCache()
    }

    // MARK: - Cache

    private func loadCache() {
        let stored = core.keyValueStore.remoteConfig
        var restored: [String: CountlyRCData] = [:]
        var foundOtherShapes = false

        for (key, raw) in stored {
            switch raw {
            case let archived as ArchivedRCData:
                restored[key] = CountlyRCData(value: unwrapNull(archived.value),
                                              isCurrentUsersData: archived.isCurrentUsersData)
            case let entry as [String: Any]:
                // The Objective-C SDK takes any entry for its own class, so the cache is rewritten below.
                foundOtherShapes = true
                restored[key] = CountlyRCData(value: unwrapNull(entry[CacheKey.value]),
                                              isCurrentUsersData: (entry[CacheKey.isCurrentUsersData] as? Bool) ?? true)
            default:
                foundOtherShapes = true
            }
        }

        cachedRemoteConfig = restored
        let staleKeyCount = cachedRemoteConfig.values.filter { !$0.isCurrentUsersData }.count
        logD("loadCache", "remote config cache is loaded from persistency, cachedKeyCount: [\(cachedRemoteConfig.count)], staleKeyCount: [\(staleKeyCount)], rewrittenInTheSharedShape: [\(foundOtherShapes)], cachedKeys: [\(Self.describe(cachedRemoteConfig.keys))]")

        if foundOtherShapes {
            persistCache()
        }
    }

    /// Key names in a stable order. Names are safe to log at debug, the values
    /// behind them are not.
    private static func describe<S: Sequence>(_ keys: S) -> String where S.Element == String {
        keys.sorted().joined(separator: ", ")
    }

    /// `NSNull` is how a nil value survives being archived, and it has to come back
    /// as nil rather than as an `NSNull` the host application would have to know
    /// about.
    private func unwrapNull(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    /// Writes the cache in the shape both SDKs read, a nil value as `NSNull` the
    /// way the Objective-C SDK stores a JSON null.
    private func persistCache() {
        var stored: [String: Any] = [:]
        for (key, data) in cachedRemoteConfig {
            stored[key] = ArchivedRCData(value: data.value ?? NSNull(), isCurrentUsersData: data.isCurrentUsersData)
        }
        core.keyValueStore.remoteConfig = stored
    }

    // MARK: - Reading values

    /// The cached value for a key, with a `nil` value when it is not known.
    func getValue(_ key: String) -> CountlyRCData {
        logI("getValue", "a remote config value is requested, key: [\(key)]")

        lock.lock()
        defer { lock.unlock() }

        let data = cachedRemoteConfig[key]
        // Reads never hit the network, so a missing or stale value is always a
        // question about what the last download put in the cache.
        logD("getValue", "remote config value is served from the local cache, key: [\(key)], valueExists: [\(data != nil)], belongsToCurrentUser: [\(data?.isCurrentUsersData ?? true)], cachedKeyCount: [\(cachedRemoteConfig.count)]")
        return data ?? CountlyRCData(value: nil, isCurrentUsersData: true)
    }

    /// Every cached value.
    func getAllValues() -> [String: CountlyRCData] {
        logI("getAllValues", "all remote config values are requested")

        lock.lock()
        defer { lock.unlock() }
        let staleKeyCount = cachedRemoteConfig.values.filter { !$0.isCurrentUsersData }.count
        logD("getAllValues", "all remote config values are served from the local cache, cachedKeyCount: [\(cachedRemoteConfig.count)], staleKeyCount: [\(staleKeyCount)], cachedKeys: [\(Self.describe(cachedRemoteConfig.keys))]")
        return cachedRemoteConfig
    }

    /// Reads a value and enrolls the device in its A/B test.
    ///
    /// Reading a value is what makes the device part of the experiment, so the
    /// enrollment is tied to the read rather than to the download.
    func getValueAndEnroll(_ key: String) -> CountlyRCData {
        logI("getValueAndEnroll", "a remote config value and an A/B test enrollment are requested, key: [\(key)]")

        let data = getValue(key)
        if data.value != nil {
            logD("getValueAndEnroll", "a value exists for the key, enrollment into its A/B test will be requested, key: [\(key)]")
            enrollIntoABTests(forKeys: [key])
        } else {
            logD("getValueAndEnroll", "no value exists for the key, enrollment into its A/B test will be skipped, key: [\(key)]")
        }
        return data
    }

    /// Reads every value and enrolls the device in all of their A/B tests.
    func getAllValuesAndEnroll() -> [String: CountlyRCData] {
        logI("getAllValuesAndEnroll", "all remote config values and their A/B test enrollments are requested")

        let all = getAllValues()
        if !all.isEmpty {
            logD("getAllValuesAndEnroll", "enrollment into the A/B tests of every cached key will be requested, cachedKeyCount: [\(all.count)]")
            enrollIntoABTests(forKeys: Array(all.keys))
        } else {
            logD("getAllValuesAndEnroll", "no cached remote config values exist, enrollment into the A/B tests of every cached key will be skipped")
        }
        return all
    }

    // MARK: - Downloading

    /// Downloads at init and after a user change, when configured to.
    func downloadRemoteConfigAutomatically() {
        guard isAutomaticTriggersEnabled else {
            logD("downloadRemoteConfigAutomatically", "automatic triggers are disabled, automatic remote config download will be skipped")
            return
        }

        guard core.modules.consent.hasConsent(for: .remoteConfig) else {
            logD("downloadRemoteConfigAutomatically", "no consent for remote config, automatic download will be skipped")
            return
        }

        guard !core.modules.deviceID.isTemporary, !isQueueHoldingTemporaryRequests else {
            logD("downloadRemoteConfigAutomatically", "device ID is in temporary mode or requests recorded in it are still queued, automatic remote config download will be skipped")
            return
        }

        logD("downloadRemoteConfigAutomatically", "automatic remote config download is starting, fetchType: [full]")
        downloadValues(keys: nil, omitKeys: nil, completion: nil)
    }

    /// Whether the request queue still holds requests with the temporary device
    /// ID: values downloaded now would be for a user the server does not know yet.
    private var isQueueHoldingTemporaryRequests: Bool {
        let marker = "&\(QS.deviceID)=\(TemporaryDeviceID.value)"
        return core.requestQueueStore.containsRequest { $0.contains(marker) }
    }

    /// What a failed request reports: `.networkIssue` when the server could not be
    /// reached, `.error` for an answer that was refused or unusable.
    private static func failureResult(for error: Error?) -> RequestResult {
        guard let error = error as NSError?, error.domain == NSURLErrorDomain else { return .error }
        return .networkIssue
    }

    /// Downloads every key.
    func downloadKeys(completion: RCDownloadCallback?) {
        logI("downloadKeys", "a download of every remote config key is requested")
        downloadValues(keys: nil, omitKeys: nil, completion: completion)
    }

    /// Downloads only the named keys.
    func downloadSpecificKeys(_ keys: [String], completion: RCDownloadCallback?) {
        logI("downloadSpecificKeys", "a download of specific remote config keys is requested, keyCount: [\(keys.count)], keys: [\(Self.describe(keys))]")
        downloadValues(keys: keys, omitKeys: nil, completion: completion)
    }

    /// Downloads everything except the named keys.
    func downloadOmittingKeys(_ omitKeys: [String], completion: RCDownloadCallback?) {
        logI("downloadOmittingKeys", "a download of every remote config key except the named ones is requested, omitKeyCount: [\(omitKeys.count)], omitKeys: [\(Self.describe(omitKeys))]")
        downloadValues(keys: nil, omitKeys: omitKeys, completion: completion)
    }

    private func downloadValues(keys: [String]?, omitKeys: [String]?, completion: RCDownloadCallback?) {
        // Every early exit reports back. A completion that is captured and never
        // called leaves a caller waiting on it for the life of the process.
        guard core.modules.consent.hasConsent(for: .remoteConfig) else {
            logD("downloadValues", "no consent for remote config, value download will be skipped")
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }

        guard !core.modules.deviceID.isTemporary, !isQueueHoldingTemporaryRequests else {
            logD("downloadValues", "device ID is in temporary mode or requests recorded in it are still queued, remote config value download will be skipped")
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }

        guard core.serverConfig.networkingEnabled else {
            logD("downloadValues", "networking is disabled by the server config, remote config value download will be skipped")
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }

        let isFullUpdate = keys == nil && omitKeys == nil
        logD("downloadValues", "remote config value download is starting, fetchType: [\(isFullUpdate ? "full" : "partial")], keyCount: [\(keys?.count ?? 0)], omitKeyCount: [\(omitKeys?.count ?? 0)], requestedKeys: [\(Self.describe(keys ?? []))], omittedKeys: [\(Self.describe(omitKeys ?? []))], enrollABOnDownload: [\(enrollABOnRCDownload)], completionHandlerProvided: [\(completion != nil)]")

        let requestedFor = core.modules.deviceID.deviceID
        fetch(keys: keys, omitKeys: omitKeys, isLegacy: false) { [weak self] remoteConfig, fetchError in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                completion?(RemoteConfigModule.failureResult(for: fetchError), fetchError ?? CountlyError.remoteConfigGeneralAPIError.asNSError, isFullUpdate, [:])
                return
            }

            var error = fetchError
            if error == nil, self.core.modules.deviceID.deviceID != requestedFor {
                self.logD("downloadValues", "the device ID changed while the download was running, the values belong to the previous user and are discarded")
                error = CountlyError.remoteConfigGeneralAPIError.asNSError
            }

            let downloaded = error == nil ? self.buildMeta(from: remoteConfig ?? [:]) : [:]
            var result = RequestResult.success

            if error == nil {
                self.logD("downloadValues", "remote config value download is successful, valueCount: [\(remoteConfig?.count ?? 0)], downloadedKeys: [\(Self.describe((remoteConfig ?? [:]).keys))]")
                self.logV("downloadValues", "remote config value download payload detail, remoteConfig: [\(remoteConfig ?? [:])]")

                self.lock.lock()
                if isFullUpdate {
                    self.cachedRemoteConfig = downloaded
                    self.logD("downloadValues", "remote config cache is replaced on full download, cachedKeyCount: [\(self.cachedRemoteConfig.count)]")
                } else {
                    self.cachedRemoteConfig.merge(downloaded) { _, new in new }
                    self.logD("downloadValues", "remote config cache is merged on partial download, mergedKeyCount: [\(downloaded.count)], cachedKeyCount: [\(self.cachedRemoteConfig.count)]")
                }
                self.persistCache()
                self.lock.unlock()
            } else {
                result = Self.failureResult(for: error)
                let nsError = error as NSError?
                self.logD("downloadValues", "remote config value download failed, the cached values are left untouched, result: [\(result.rawValue)], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
            }

            completion?(result, error, isFullUpdate, downloaded)

            // Snapshotted so a callback that registers another one does not mutate
            // the array being iterated.
            self.stateLock.lock()
            let callbacks = Array(self.downloadCallbacks.values)
            self.stateLock.unlock()

            self.logD("downloadValues", "registered download callbacks will be notified, callbackCount: [\(callbacks.count)]")
            for callback in callbacks {
                callback(result, error, isFullUpdate, downloaded)
            }
        }
    }

    /// Turns the raw response into cache entries owned by the current user.
    private func buildMeta(from remoteConfig: [String: Any]) -> [String: CountlyRCData] {
        var result: [String: CountlyRCData] = [:]
        for (key, value) in remoteConfig {
            result[key] = CountlyRCData(value: value, isCurrentUsersData: true)
        }
        return result
    }

    /// Performs the fetch as an instant request.
    ///
    /// Remote config is read back rather than reported, so it does not go through
    /// the request queue: a value the application is waiting for would be useless
    /// behind a backlog.
    private func fetch(keys: [String]?,
                       omitKeys: [String]?,
                       isLegacy: Bool,
                       completion: @escaping ([String: Any]?, Error?) -> Void) {
        // Both guards report back rather than returning silently. `downloadValues`
        // checks the same two conditions before calling in, but the behavior
        // settings that own `networkingEnabled` are applied from the network
        // thread, so either can have flipped in between. A completion that is
        // captured and never called leaves the caller waiting for the life of the
        // process.
        guard core.serverConfig.networkingEnabled else {
            logD("fetch", "remote config fetch is aborted, reason: networking is disabled from server config")
            completion(nil, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("fetch", "remote config fetch is aborted, reason: device ID is in temporary mode")
            completion(nil, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        let request = buildRequest(keys: keys, omitKeys: omitKeys, isLegacy: isLegacy)
        logD("fetch", "remote config request is started, method: [\(request.httpMethod ?? "GET")], path: [\(request.url?.path ?? "")], keyCount: [\(keys?.count ?? 0)], omitKeyCount: [\(omitKeys?.count ?? 0)]")

        let task = core.network.instantTask(with: request) { [weak self] data, response, transportError in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                DispatchQueue.main.async { completion(nil, transportError ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            var parsed: [String: Any]?
            var resolvedError = transportError

            if resolvedError == nil {
                parsed = CountlyJSON.object(from: data, logger: self.log) as? [String: Any]
                if parsed == nil {
                    self.logD("fetch", "the remote config response could not be read as a JSON object, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)]")
                    resolvedError = CountlyError.remoteConfigGeneralAPIError.asNSError
                }
            }

            if resolvedError == nil, statusCode != 200 {
                self.logD("fetch", "the remote config response carries a status code other than 200, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)]")
                resolvedError = CountlyError.remoteConfigGeneralAPIError.asNSError
            }

            // Callbacks reach the host application on the main thread, because a
            // remote config value usually drives what is on screen.
            // Weak again: the `guard let self` above makes it a strong local, and
            // a hop that captured that local would keep this module alive past the
            // core it holds `unowned`. The caller's completion still runs either
            // way, which is what it is waiting for.
            DispatchQueue.main.async { [weak self] in
                if let resolvedError {
                    let nsError = resolvedError as NSError
                    self?.logD("fetch", "remote config request failed, statusCode: [\(statusCode)], error: [\(nsError.localizedDescription)], domain: [\(nsError.domain)], code: [\(nsError.code)]")
                    completion(nil, resolvedError)
                } else {
                    self?.logD("fetch", "remote config request successfully completed, statusCode: [\(statusCode)], valueCount: [\(parsed?.count ?? 0)], responseKeys: [\(Self.describe((parsed ?? [:]).keys))]")
                    completion(parsed, nil)
                }
            }
        }
        guard let task else {
            completion(nil, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        task.resume()
    }

    private func buildRequest(keys: [String]?, omitKeys: [String]?, isLegacy: Bool) -> URLRequest {
        var queryString = core.network.builder.queryEssentials()
        queryString += "&\(QS.method)=\(isLegacy ? Key.fetchRemoteConfigLegacy : Key.remoteConfig)"

        if let keys {
            queryString += "&\(QS.rcKeys)=\(CountlyJSON.escapedString(from: keys, logger: log))"
        } else if let omitKeys {
            queryString += "&\(QS.rcOmitKeys)=\(CountlyJSON.escapedString(from: omitKeys, logger: log))"
        }

        if enrollABOnRCDownload {
            queryString += "&\(Key.autoOptIn)=1"
        }

        if core.modules.consent.hasConsent(for: .metrics) {
            queryString += "&\(QS.metrics)=\(CountlyJSON.escapedString(from: core.metricsDictionary(), logger: log))"
        }

        queryString += "&\(QS.appVersion)=\(core.appVersion.urlEscaped)"
        queryString = core.network.builder.finishImmediateRequest(queryString)

        return core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)
    }

    /// The preconditions every remote config network call shares.
    ///
    /// `action` names what is being skipped, so a caller reads the same log line
    /// it did when each of these guards was written out at its call site.
    private func isRemoteConfigCallAllowed(_ function: String,
                                           _ action: String,
                                           requiresNetworking: Bool) -> Bool {
        guard core.modules.consent.hasConsent(for: .remoteConfig) else {
            logD(function, "no consent for remote config, the call will be skipped, skippedAction: [\(action)]")
            return false
        }

        if requiresNetworking {
            guard core.serverConfig.networkingEnabled else {
                logD(function, "networking is disabled by the server config, the call will be skipped, skippedAction: [\(action)]")
                return false
            }
        }

        guard !core.modules.deviceID.isTemporary, !isQueueHoldingTemporaryRequests else {
            logD(function, "device ID is in temporary mode or requests recorded in it are still queued, the call will be skipped, skippedAction: [\(action)]")
            return false
        }

        return true
    }

    // MARK: - A/B tests

    /// Puts the device into the A/B tests of the given keys. Without a usable key
    /// the call is omitted with a warning: the server refuses an enrollment with
    /// no key, and a refused request would hold the queue up.
    func enrollIntoABTests(forKeys keys: [String]) {
        logI("enrollIntoABTests", "enrollment into A/B tests is requested, keyCount: [\(keys.count)]")

        let validKeys = keys.filter { !$0.isEmpty }
        guard !validKeys.isEmpty else {
            logW("enrollIntoABTests", "omitting the call, no valid key is given")
            core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
            return
        }

        guard isRemoteConfigCallAllowed("enrollIntoABTests", "A/B test enrollment", requiresNetworking: false) else { return }

        logD("enrollIntoABTests", "an enrollment request will be added to the request queue, keys: [\(Self.describe(validKeys))]")
        sendABRequest(method: QS.abOptIn, keys: validKeys, overrideEndpoint: true)
    }

    /// Takes the device out of the A/B tests of the given keys.
    func exitABTests(forKeys keys: [String]) {
        logI("exitABTests", "an exit from A/B tests is requested, keyCount: [\(keys.count)]")

        guard isRemoteConfigCallAllowed("exitABTests", "A/B test exit", requiresNetworking: false) else { return }

        logD("exitABTests", "an exit request will be added to the request queue, keys: [\(Self.describe(keys))]")
        sendABRequest(method: QS.abOptOut, keys: keys, overrideEndpoint: false)
    }

    private func sendABRequest(method: String, keys: [String], overrideEndpoint: Bool) {
        var queryString = "\(core.network.builder.queryEssentials())&\(QS.method)=\(method)"
        queryString += "&\(QS.rcKeys)=\(CountlyJSON.escapedString(from: keys, logger: log))"

        if overrideEndpoint {
            queryString = core.network.builder.withEndpointOverride(queryString, endpoint: Endpoint.output + Endpoint.sdk)
        }

        core.network.enqueueAndProceed(queryString)
    }

    // MARK: - Variants and experiments, for testing

    /// Query string shared by the three testing calls: the essentials, the method,
    /// any call specific parameters, the app version, then the checksum.
    ///
    /// The order is fixed here rather than at each call site because it is the
    /// order the checksum is computed over.
    private func testingQueryString(method: String, parameters: String = "") -> String {
        var queryString = "\(core.network.builder.queryEssentials())&\(QS.method)=\(method)"
        queryString += parameters
        queryString += "&\(QS.appVersion)=\(core.appVersion.urlEscaped)"
        return core.network.builder.finishImmediateRequest(queryString)
    }

    /// Reduces the server's variant payload to the variant names per key.
    ///
    /// The server sends `{"key": [{"name": "A", ...}, ...]}`, and every SDK caches
    /// only the names: Android's `convertVariantsJsonToMap` and the reference SDK's
    /// equivalent both do this walk. Doing it here rather than in each bridge keeps
    /// one copy of the shape, which is how the push payload keys ended up
    /// duplicated.
    ///
    /// An entry that is already a string is kept, as the reference SDK does.
    /// Android drops those, but the server does not send them, so accepting them
    /// costs nothing and losing data a previous integration kept is the worse of
    /// the two risks.
    private static func variantNames(from payload: [String: Any], logger: Logger?) -> [String: [String]] {
        var result: [String: [String]] = [:]

        for (key, value) in payload.sorted(by: { $0.key < $1.key }) {
            guard let entries = value as? [Any] else {
                logger?.d(moduleName, "variantNames", "skipping a variant entry whose value is not an array, key: [\(key)], receivedType: [\(type(of: value))]")
                continue
            }

            var names: [String] = []
            for entry in entries {
                if let name = (entry as? [String: Any])?[Key.variantName] as? String {
                    names.append(name)
                } else if let name = entry as? String {
                    names.append(name)
                } else {
                    logger?.d(moduleName, "variantNames", "skipping a variant with no name, key: [\(key)], receivedType: [\(type(of: entry))]")
                }
            }

            result[key] = names
        }

        return result
    }

    /// Every variant from the last testing download.
    func testingGetAllVariants() -> [String: [String]] {
        logI("testingGetAllVariants", "all locally cached A/B variants are requested")

        stateLock.lock()
        defer { stateLock.unlock() }
        logD("testingGetAllVariants", "all locally cached variants are read, variantKeyCount: [\(localCachedVariants.count)], variantKeys: [\(Self.describe(localCachedVariants.keys))]")
        return localCachedVariants
    }

    /// The variants of one key from the last testing download.
    func testingGetVariants(forKey key: String) -> [String] {
        logI("testingGetVariants", "the locally cached A/B variants of a key are requested, key: [\(key)]")

        stateLock.lock()
        defer { stateLock.unlock() }
        let variants = localCachedVariants[key] ?? []
        logD("testingGetVariants", "locally cached variants are read for a key, key: [\(key)], variantCount: [\(variants.count)], keyIsKnown: [\(localCachedVariants[key] != nil)]")
        return variants
    }

    /// Every experiment from the last testing download.
    func testingGetAllExperimentInfo() -> [String: CountlyExperimentInformation] {
        logI("testingGetAllExperimentInfo", "all locally cached experiment information is requested")

        stateLock.lock()
        defer { stateLock.unlock() }
        logD("testingGetAllExperimentInfo", "all locally cached experiments are read, experimentCount: [\(localCachedExperiments.count)], experimentIDs: [\(Self.describe(localCachedExperiments.keys))]")
        return localCachedExperiments
    }

    /// Downloads which variants exist, so a tester can pick one.
    func testingDownloadVariantInformation(completion: @escaping RCVariantCallback) {
        logI("testingDownloadVariantInformation", "a download of the available A/B variants is requested")

        guard isRemoteConfigCallAllowed("testingDownloadVariantInformation", "variants download", requiresNetworking: true) else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        let queryString = testingQueryString(method: Key.fetchVariant)
        let request = core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)

        logD("testingDownloadVariantInformation", "variants download is starting, path: [\(request.url?.path ?? "")]")

        let task = core.network.instantTask(with: request) { [weak self] data, response, error in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                DispatchQueue.main.async { completion(.error, error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let variants = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                let nsError = error as NSError?
                self.logD("testingDownloadVariantInformation", "variants request failed, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
                DispatchQueue.main.async { completion(Self.failureResult(for: error), error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            let flattened = Self.variantNames(from: variants, logger: self.log)

            self.stateLock.lock()
            self.localCachedVariants = flattened
            self.stateLock.unlock()
            self.logD("testingDownloadVariantInformation", "variants request successfully completed, the locally cached variants are replaced, variantKeyCount: [\(flattened.count)], variantKeys: [\(Self.describe(flattened.keys))]")
            DispatchQueue.main.async { completion(.success, nil) }
        }
        guard let task else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        task.resume()
    }

    /// Downloads the experiments this device is part of.
    func testingDownloadExperimentInformation(completion: @escaping RCVariantCallback) {
        logI("testingDownloadExperimentInformation", "a download of the experiments this device is part of is requested")

        guard isRemoteConfigCallAllowed("testingDownloadExperimentInformation", "experiment download", requiresNetworking: true) else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        let queryString = testingQueryString(method: Key.fetchExperiments)
        let request = core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)

        logD("testingDownloadExperimentInformation", "experiment download is starting, path: [\(request.url?.path ?? "")]")

        let task = core.network.instantTask(with: request) { [weak self] data, response, error in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                DispatchQueue.main.async { completion(.error, error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil, statusCode == 200 else {
                let nsError = error as NSError?
                self.logD("testingDownloadExperimentInformation", "experiment request failed, statusCode: [\(statusCode)], responseSize: [\(data?.count ?? 0)], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
                DispatchQueue.main.async { completion(Self.failureResult(for: error), error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            let parsed = CountlyJSON.object(from: data, logger: self.log)

            // The documented shape is an object carrying a `jsonArray` of
            // experiments. A bare array is accepted too, and anything else yields
            // no experiments rather than an error: this is a testing helper, and a
            // shape the SDK did not expect must never be able to take the host
            // application down with it.
            let entries: [[String: Any]]
            let responseShape: String
            if let container = parsed as? [String: Any] {
                entries = (container[Key.experimentArray] as? [[String: Any]]) ?? []
                responseShape = "object"
            } else if let array = parsed as? [[String: Any]] {
                entries = array
                responseShape = "array"
            } else {
                entries = []
                responseShape = "unrecognised"
            }

            if entries.isEmpty {
                self.logD("testingDownloadExperimentInformation", "the experiment response carried no experiments, responseShape: [\(responseShape)], responseSize: [\(data?.count ?? 0)]")
            }

            var experiments: [String: CountlyExperimentInformation] = [:]
            for entry in entries {
                guard let experimentID = entry["id"] as? String else { continue }
                experiments[experimentID] = CountlyExperimentInformation(
                    experimentID: experimentID,
                    experimentName: (entry["name"] as? String) ?? "",
                    experimentDescription: (entry["description"] as? String) ?? "",
                    currentVariant: (entry["currentVariant"] as? String) ?? "",
                    variants: (entry["variants"] as? [String: Any]) ?? [:])
            }

            if experiments.count != entries.count {
                self.logD("testingDownloadExperimentInformation", "some experiment entries carry no id and were dropped, receivedEntryCount: [\(entries.count)], keptExperimentCount: [\(experiments.count)]")
            }

            self.stateLock.lock()
            self.localCachedExperiments = experiments
            self.stateLock.unlock()

            self.logD("testingDownloadExperimentInformation", "experiment request successfully completed, the locally cached experiments are replaced, responseShape: [\(responseShape)], experimentCount: [\(experiments.count)], experimentIDs: [\(Self.describe(experiments.keys))]")
            DispatchQueue.main.async { completion(.success, nil) }
        }
        guard let task else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        task.resume()
    }

    /// Forces this device into a named variant.
    func testingEnrollIntoVariant(key: String, variantName: String, completion: @escaping RCVariantCallback) {
        logI("testingEnrollIntoVariant", "enrollment into a named A/B variant is requested, key: [\(key)], variantName: [\(variantName)]")

        guard !key.isEmpty, !variantName.isEmpty else {
            logE("testingEnrollIntoVariant", "key or variant name is empty, variant enrollment will be skipped")
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        // This is the only one of the three testing calls that writes state on the
        // server, so it is the one where an ungated call does lasting damage: it
        // would enrol a device whose user declined remote config, and in temporary
        // mode it would enrol the placeholder ID.
        guard isRemoteConfigCallAllowed("testingEnrollIntoVariant", "variant enrollment", requiresNetworking: true) else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        let queryString = testingQueryString(
            method: Key.enrollVariant,
            parameters: "&\(Key.key)=\(key.urlEscaped)&\(Key.variant)=\(variantName.urlEscaped)")
        // Enrollment writes state, so it goes to the input endpoint rather than
        // the read endpoint the fetches use.
        let request = core.network.instantRequest(queryString: queryString, path: Endpoint.input)

        logD("testingEnrollIntoVariant", "variant enrollment is starting, key: [\(key)], variantName: [\(variantName)], path: [\(request.url?.path ?? "")]")

        let task = core.network.instantTask(with: request) { [weak self] data, response, error in
            // The caller is answered even once a halt has released the module.
            guard let self else {
                DispatchQueue.main.async { completion(.error, error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let answer = CountlyJSON.object(from: data, logger: nil) as? [String: Any]

            // Only {"result": "Success"} means the server enrolled the device.
            guard error == nil, statusCode == 200, answer?["result"] as? String == "Success" else {
                let nsError = error as NSError?
                self.logD("testingEnrollIntoVariant", "variant enrollment request failed, key: [\(key)], variantName: [\(variantName)], statusCode: [\(statusCode)], result: [\(answer?["result"] as? String ?? "")], error: [\(nsError?.localizedDescription ?? "")], domain: [\(nsError?.domain ?? "")], code: [\(nsError?.code ?? 0)]")
                DispatchQueue.main.async { completion(Self.failureResult(for: error), error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            // The enrollment changed which values apply. The cache is cleared
            // first: refetching alone is gated on automatic triggers, so without
            // this an integration with triggers off keeps serving the old
            // variant's values forever.
            self.logD("testingEnrollIntoVariant", "variant enrollment successfully completed, the cached values will be cleared and downloaded again, key: [\(key)], variantName: [\(variantName)]")
            self.clearCachedRemoteConfig()
            self.downloadRemoteConfigAutomatically()
            DispatchQueue.main.async { completion(.success, nil) }
        }
        guard let task else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }
        task.resume()
    }

    // MARK: - Callbacks

    /// Registers a callback notified after each download.
    @discardableResult
    func registerDownloadCallback(_ callback: @escaping RCDownloadCallback) -> RCCallbackToken {
        stateLock.lock()
        nextCallbackToken &+= 1
        let token = RCCallbackToken(value: nextCallbackToken)
        downloadCallbacks[token] = callback
        let count = downloadCallbacks.count
        stateLock.unlock()
        logI("registerDownloadCallback", "download callback is registered, callbackCount: [\(count)]")
        return token
    }

    /// Removes one registered callback.
    func removeDownloadCallback(_ token: RCCallbackToken) {
        stateLock.lock()
        let removed = downloadCallbacks.removeValue(forKey: token) != nil
        let count = downloadCallbacks.count
        stateLock.unlock()

        if removed {
            logI("removeDownloadCallback", "download callback is removed, remainingCallbackCount: [\(count)]")
        } else {
            logW("removeDownloadCallback", "nothing was removed, the token does not belong to a registered download callback")
        }
    }

    /// Drops every registered download callback.
    func removeAllDownloadCallbacks() {
        stateLock.lock()
        let removedCount = downloadCallbacks.count
        downloadCallbacks.removeAll()
        stateLock.unlock()
        logI("removeAllDownloadCallbacks", "all download callbacks are removed, removedCallbackCount: [\(removedCount)]")
    }

    // MARK: - Clearing

    /// Called on a user change.
    ///
    /// With value caching on the values are kept but marked as the previous user's,
    /// which lets an application keep rendering something while the new values
    /// download. With it off they are erased, which is the safer default.
    func clearCachedRemoteConfig() {
        lock.lock()
        defer { lock.unlock() }

        logD("clearCachedRemoteConfig", "cached remote config values are updated for the user change, valueCachingEnabled: [\(isValueCachingEnabled)], action: [\(isValueCachingEnabled ? "marked as stale" : "erased")], cachedKeyCount: [\(cachedRemoteConfig.count)]")

        if isValueCachingEnabled {
            for (key, data) in cachedRemoteConfig {
                cachedRemoteConfig[key] = CountlyRCData(value: data.value, isCurrentUsersData: false)
            }
        } else {
            cachedRemoteConfig.removeAll()
        }
        persistCache()
    }

    /// Erases every cached value.
    func clearAll() {
        logI("clearAll", "erasing every remote config value is requested")

        lock.lock()
        defer { lock.unlock() }
        logD("clearAll", "all remote config values will be erased, clearedKeyCount: [\(cachedRemoteConfig.count)]")
        cachedRemoteConfig.removeAll()
        persistCache()
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        stateLock.lock()
        let droppedCallbackCount = downloadCallbacks.count
        downloadCallbacks.removeAll()
        localCachedVariants.removeAll()
        localCachedExperiments.removeAll()
        stateLock.unlock()

        logD("halt", "remote config module is halted, callbacks and testing caches are dropped, clearStorage: [\(clearStorage)], droppedCallbackCount: [\(droppedCallbackCount)]")
        if clearStorage {
            clearAll()
        }
    }
}
