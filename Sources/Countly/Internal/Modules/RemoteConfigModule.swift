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
        static let key = "key"
        static let remoteConfig = "rc"
        static let autoOptIn = "oi"
    }

    /// Storage shape of one cached value.
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
    private var localCachedVariants: [String: Any] = [:]

    /// Experiment information from the last testing download.
    private var localCachedExperiments: [String: CountlyExperimentInformation] = [:]

    /// Callbacks notified after each download.
    /// Registered download callbacks, keyed by the token handed back to whoever
    /// registered them.
    ///
    /// Keyed rather than a plain array because a Swift closure has no identity to
    /// compare against, which is how the reference SDKs find the one to remove.
    /// The token is that identity.
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
        for callback in core.config.remoteConfigGlobalCallbacks {
            _ = registerDownloadCallback(callback)
        }

        loadCache()
    }

    // MARK: - Cache

    private func loadCache() {
        let stored = core.keyValueStore.remoteConfig
        var restored: [String: CountlyRCData] = [:]
        var foundLegacyEntries = false

        for (key, raw) in stored {
            if let entry = raw as? [String: Any] {
                restored[key] = CountlyRCData(value: unwrapNull(entry[CacheKey.value]),
                                              isCurrentUsersData: (entry[CacheKey.isCurrentUsersData] as? Bool) ?? true)
            } else if let legacy = raw as? LegacyArchivedRCData {
                // Written by an earlier Objective-C Countly SDK in the same
                // application, before it was replaced by this one.
                foundLegacyEntries = true
                restored[key] = CountlyRCData(value: unwrapNull(legacy.value),
                                              isCurrentUsersData: legacy.isCurrentUsersData)
            }
        }

        cachedRemoteConfig = restored
        logD("loadCache", "remote config cache is loaded from persistency, cachedKeyCount: [\(cachedRemoteConfig.count)], migratedFromPreviousSDK: [\(foundLegacyEntries)]")

        // Rewritten in this SDK's shape so the legacy decode runs once rather than
        // on every launch for the rest of the application's life.
        if foundLegacyEntries {
            persistCache()
        }
    }

    /// `NSNull` is how a nil value survives being archived, and it has to come back
    /// as nil rather than as an `NSNull` the host application would have to know
    /// about.
    private func unwrapNull(_ value: Any?) -> Any? {
        value is NSNull ? nil : value
    }

    private func persistCache() {
        var stored: [String: Any] = [:]
        for (key, data) in cachedRemoteConfig {
            stored[key] = [
                CacheKey.value: data.value ?? NSNull(),
                CacheKey.isCurrentUsersData: data.isCurrentUsersData,
            ]
        }
        core.keyValueStore.remoteConfig = stored
    }

    // MARK: - Reading values

    /// The cached value for a key, with a `nil` value when it is not known.
    func getValue(_ key: String) -> CountlyRCData {
        lock.lock()
        defer { lock.unlock() }

        let data = cachedRemoteConfig[key]
        logD("getValue", "remote config value is read from cache, key: [\(key)], valueExists: [\(data != nil)]")
        return data ?? CountlyRCData(value: nil, isCurrentUsersData: true)
    }

    /// Every cached value.
    func getAllValues() -> [String: CountlyRCData] {
        lock.lock()
        defer { lock.unlock() }
        logD("getAllValues", "all remote config values are read from cache, cachedKeyCount: [\(cachedRemoteConfig.count)]")
        return cachedRemoteConfig
    }

    /// Reads a value and enrolls the device in its A/B test.
    ///
    /// Reading a value is what makes the device part of the experiment, so the
    /// enrollment is tied to the read rather than to the download.
    func getValueAndEnroll(_ key: String) -> CountlyRCData {
        let data = getValue(key)
        if data.value != nil {
            logD("getValueAndEnroll", "a value exists for the key, AB test enrollment will be requested, key: [\(key)]")
            enrollIntoABTests(forKeys: [key])
        } else {
            logD("getValueAndEnroll", "no value exists for the key, AB test enrollment will be skipped, key: [\(key)]")
        }
        return data
    }

    /// Reads every value and enrolls the device in all of their A/B tests.
    func getAllValuesAndEnroll() -> [String: CountlyRCData] {
        let all = getAllValues()
        if !all.isEmpty {
            logD("getAllValuesAndEnroll", "AB test enrollment will be requested for all cached keys, cachedKeyCount: [\(all.count)]")
            enrollIntoABTests(forKeys: Array(all.keys))
        } else {
            logD("getAllValuesAndEnroll", "no cached remote config values exist, AB test enrollment for all keys will be skipped")
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
            logV("downloadRemoteConfigAutomatically", "no consent for remote config, automatic download will be skipped")
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("downloadRemoteConfigAutomatically", "device ID is in temporary mode, automatic remote config download will be skipped")
            return
        }

        logD("downloadRemoteConfigAutomatically", "automatic remote config download is starting, fetchType: [full]")
        downloadValues(keys: nil, omitKeys: nil, completion: nil)
    }

    /// Downloads every key.
    func downloadKeys(completion: RCDownloadCallback?) {
        downloadValues(keys: nil, omitKeys: nil, completion: completion)
    }

    /// Downloads only the named keys.
    func downloadSpecificKeys(_ keys: [String], completion: RCDownloadCallback?) {
        downloadValues(keys: keys, omitKeys: nil, completion: completion)
    }

    /// Downloads everything except the named keys.
    func downloadOmittingKeys(_ omitKeys: [String], completion: RCDownloadCallback?) {
        downloadValues(keys: nil, omitKeys: omitKeys, completion: completion)
    }

    private func downloadValues(keys: [String]?, omitKeys: [String]?, completion: RCDownloadCallback?) {
        // Every early exit reports back. A completion that is captured and never
        // called leaves a caller waiting on it for the life of the process.
        guard core.modules.consent.hasConsent(for: .remoteConfig) else {
            logV("downloadValues", "no consent for remote config, value download will be skipped")
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }

        guard !core.modules.deviceID.isTemporary else {
            logD("downloadValues", "device ID is in temporary mode, remote config value download will be skipped")
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }

        guard core.serverConfig.networkingEnabled else {
            logD("downloadValues", "networking is disabled by the server config, remote config value download will be skipped")
            completion?(.error, CountlyError.remoteConfigGeneralAPIError.asNSError, false, [:])
            return
        }

        let isFullUpdate = keys == nil && omitKeys == nil
        logD("downloadValues", "remote config value download is starting, fetchType: [\(isFullUpdate ? "full" : "partial")], keyCount: [\(keys?.count ?? 0)], omitKeyCount: [\(omitKeys?.count ?? 0)], completionHandlerProvided: [\(completion != nil)]")

        fetch(keys: keys, omitKeys: omitKeys, isLegacy: false) { [weak self] remoteConfig, error in
            guard let self else { return }

            let downloaded = self.buildMeta(from: remoteConfig ?? [:])
            var result = RequestResult.success

            if error == nil {
                self.logD("downloadValues", "remote config value download is successful, valueCount: [\(remoteConfig?.count ?? 0)]")
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
                result = .error
                self.logD("downloadValues", "remote config value download failed, error: [\(error?.localizedDescription ?? "")]")
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

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, transportError in
            guard let self else { return }

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            var parsed: [String: Any]?
            var resolvedError = transportError

            if resolvedError == nil {
                parsed = CountlyJSON.object(from: data, logger: self.log) as? [String: Any]
                if parsed == nil {
                    resolvedError = CountlyError.remoteConfigGeneralAPIError.asNSError
                }
            }

            if resolvedError == nil, statusCode != 200 {
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
                    self?.logD("fetch", "remote config request failed, statusCode: [\(statusCode)], error: [\(resolvedError.localizedDescription)]")
                    completion(nil, resolvedError)
                } else {
                    self?.logD("fetch", "remote config request successfully completed, statusCode: [\(statusCode)], valueCount: [\(parsed?.count ?? 0)]")
                    completion(parsed, nil)
                }
            }
        }.resume()
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

        // Metrics ride along only with session consent, because they describe the
        // device rather than the config being asked for.
        if core.modules.consent.hasConsent(for: .sessions) {
            queryString += "&\(QS.metrics)=\(CountlyJSON.escapedString(from: core.metricsDictionary(), logger: log))"
        }

        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        queryString = core.network.builder.appendChecksum(queryString)

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
            logV(function, "no consent for remote config, \(action) will be skipped")
            return false
        }

        if requiresNetworking {
            guard core.serverConfig.networkingEnabled else {
                logD(function, "networking is disabled by the server config, \(action) will be skipped")
                return false
            }
        }

        guard !core.modules.deviceID.isTemporary else {
            logD(function, "device ID is in temporary mode, \(action) will be skipped")
            return false
        }

        return true
    }

    // MARK: - A/B tests

    /// Puts the device into the A/B tests of the given keys.
    func enrollIntoABTests(forKeys keys: [String]) {
        guard isRemoteConfigCallAllowed("enrollIntoABTests", "AB test enrollment", requiresNetworking: false) else { return }

        logD("enrollIntoABTests", "AB test enrollment request will be sent, keyCount: [\(keys.count)]")
        sendABRequest(method: QS.abOptIn, keys: keys, overrideEndpoint: true)
    }

    /// Takes the device out of the A/B tests of the given keys.
    func exitABTests(forKeys keys: [String]) {
        guard isRemoteConfigCallAllowed("exitABTests", "AB test exit", requiresNetworking: false) else { return }

        logD("exitABTests", "AB test exit request will be sent, keyCount: [\(keys.count)]")
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
        queryString += "&\(QS.appVersion)=\(DeviceMetrics.appVersion)"
        return core.network.builder.appendChecksum(queryString)
    }

    /// Every variant from the last testing download.
    func testingGetAllVariants() -> [String: Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        logD("testingGetAllVariants", "all locally cached variants are read, variantKeyCount: [\(localCachedVariants.count)]")
        return localCachedVariants
    }

    /// The variants of one key from the last testing download.
    func testingGetVariants(forKey key: String) -> [Any] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (localCachedVariants[key] as? [Any]) ?? []
    }

    /// Every experiment from the last testing download.
    func testingGetAllExperimentInfo() -> [String: CountlyExperimentInformation] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return localCachedExperiments
    }

    /// Downloads which variants exist, so a tester can pick one.
    func testingDownloadVariantInformation(completion: @escaping RCVariantCallback) {
        guard isRemoteConfigCallAllowed("testingDownloadVariantInformation", "variants download", requiresNetworking: true) else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        let queryString = testingQueryString(method: Key.fetchVariant)
        let request = core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)

        logD("testingDownloadVariantInformation", "variants download is starting")

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil,
                  statusCode == 200,
                  let variants = CountlyJSON.object(from: data, logger: self.log) as? [String: Any] else {
                self.logD("testingDownloadVariantInformation", "variants request failed, statusCode: [\(statusCode)]")
                DispatchQueue.main.async { completion(.error, error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            self.stateLock.lock()
            self.localCachedVariants = variants
            self.stateLock.unlock()
            self.logD("testingDownloadVariantInformation", "variants request successfully completed, variantKeyCount: [\(variants.count)]")
            DispatchQueue.main.async { completion(.success, nil) }
        }.resume()
    }

    /// Downloads the experiments this device is part of.
    func testingDownloadExperimentInformation(completion: @escaping RCVariantCallback) {
        guard isRemoteConfigCallAllowed("testingDownloadExperimentInformation", "experiment download", requiresNetworking: true) else {
            completion(.error, CountlyError.remoteConfigGeneralAPIError.asNSError)
            return
        }

        let queryString = testingQueryString(method: Key.fetchExperiments)
        let request = core.network.instantRequest(queryString: queryString, path: Endpoint.output + Endpoint.sdk)

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil, statusCode == 200 else {
                DispatchQueue.main.async { completion(.error, error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            let parsed = CountlyJSON.object(from: data, logger: self.log)

            // The documented shape is an object carrying a `jsonArray` of
            // experiments, which is what Android reads. A bare array is accepted
            // too, and anything else yields no experiments rather than an error:
            // this is a testing helper, and a shape the SDK did not expect must
            // never be able to take the host application down with it.
            let entries: [[String: Any]]
            if let container = parsed as? [String: Any] {
                entries = (container[Key.experimentArray] as? [[String: Any]]) ?? []
            } else {
                entries = (parsed as? [[String: Any]]) ?? []
            }

            if entries.isEmpty {
                self.logD("testingDownloadExperimentInformation", "the experiment response carried no experiments, responseSize: [\(data?.count ?? 0)]")
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

            self.stateLock.lock()
            self.localCachedExperiments = experiments
            self.stateLock.unlock()
            DispatchQueue.main.async { completion(.success, nil) }
        }.resume()
    }

    /// Forces this device into a named variant.
    func testingEnrollIntoVariant(key: String, variantName: String, completion: @escaping RCVariantCallback) {
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

        logD("testingEnrollIntoVariant", "variant enrollment is starting, key: [\(key)], variantName: [\(variantName)]")

        core.network.instantSession().dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            guard error == nil, statusCode == 200 else {
                DispatchQueue.main.async { completion(.error, error ?? CountlyError.remoteConfigGeneralAPIError.asNSError) }
                return
            }

            // The enrollment changed which values apply. The cache is cleared
            // first: refetching alone is gated on automatic triggers, so without
            // this an integration with triggers off keeps serving the old
            // variant's values forever.
            self.clearCachedRemoteConfig()
            self.downloadRemoteConfigAutomatically()
            DispatchQueue.main.async { completion(.success, nil) }
        }.resume()
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
        logD("registerDownloadCallback", "download callback is registered, callbackCount: [\(count)]")
        return token
    }

    /// Removes one registered callback.
    func removeDownloadCallback(_ token: RCCallbackToken) {
        stateLock.lock()
        let removed = downloadCallbacks.removeValue(forKey: token) != nil
        let count = downloadCallbacks.count
        stateLock.unlock()

        if removed {
            logD("removeDownloadCallback", "download callback is removed, remainingCallbackCount: [\(count)]")
        } else {
            logW("removeDownloadCallback", "nothing was removed, the token does not belong to a registered download callback")
        }
    }

    /// Drops every registered download callback.
    func removeAllDownloadCallbacks() {
        stateLock.lock()
        downloadCallbacks.removeAll()
        stateLock.unlock()
        logD("removeAllDownloadCallbacks", "all download callbacks are removed")
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

        logD("clearCachedRemoteConfig", "cached remote config values will be [\(isValueCachingEnabled ? "marked as stale" : "erased")], cachedKeyCount: [\(cachedRemoteConfig.count)]")

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
        lock.lock()
        defer { lock.unlock() }
        logD("clearAll", "all remote config values will be erased, clearedKeyCount: [\(cachedRemoteConfig.count)]")
        cachedRemoteConfig.removeAll()
        persistCache()
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        stateLock.lock()
        downloadCallbacks.removeAll()
        localCachedVariants.removeAll()
        localCachedExperiments.removeAll()
        stateLock.unlock()
        if clearStorage {
            clearAll()
        }
    }
}
