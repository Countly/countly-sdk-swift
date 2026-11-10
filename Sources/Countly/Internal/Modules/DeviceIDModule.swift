//
//  DeviceIDModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Owns the identity every request is attributed to.
///
/// The ID is resolved once at init and persisted, so the same device keeps the
/// same identity across launches. Changing it is the only operation in the SDK
/// that can split or join a user's history, which is why it has two explicit
/// forms: with a server side merge, and without.
final class DeviceIDModule: ModuleBase {

    override class var moduleName: String { "DeviceID" }

    /// The identity sent as `device_id`. Never empty once init has run.
    private(set) var deviceID: String {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _deviceID
        }
        set {
            stateLock.lock()
            _deviceID = newValue
            stateLock.unlock()
        }
    }

    /// Guards the ID, which requests are built and judged with on other threads
    /// while a change replaces it.
    private let stateLock = NSLock()
    private var _deviceID = ""
    private var _mergeCount = 0

    /// How many times the device ID was changed with merge in this run. The
    /// connection test reads it to tell whether the user it was armed for still
    /// exists on the server.
    var mergeCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _mergeCount
    }

    /// Whether the SDK is holding everything back until a real ID arrives.
    var isTemporary: Bool { deviceID == TemporaryDeviceID.value }

    /// How the current ID was obtained, as reported in the `t` parameter.
    var deviceIDType: DeviceIDType {
        if isTemporary { return .temporary }
        if core.keyValueStore.isCustomDeviceID { return .developerSupplied }
        return .sdkGenerated
    }

    /// The ID temporary mode is left for once init finishes, when a launch found the
    /// stored placeholder and a provided ID at the same time.
    private var temporaryExitAfterInit: String?

    // MARK: - Init

    /// Resolves the ID for this launch.
    ///
    /// A stored ID wins unless the host application asked for a reset, so an
    /// application that hardcodes no device ID keeps the identity it had.
    func initialize(with config: CountlyConfig) {
        let stored = core.keyValueStore.deviceID

        logI("initialize", "resolving the device ID for this launch, storedIDPresent: [\(stored != nil)], configIDProvided: [\(!(config.deviceID ?? "").isEmpty)], temporaryModeRequested: [\(config.temporaryDeviceIDMode)], resetStoredIDRequested: [\(config.resetStoredDeviceID)]")

        let provided = (config.deviceID ?? "").isEmpty ? nil : config.deviceID

        if config.resetStoredDeviceID {
            handOverBeforeReset(stored: stored)
        }

        if stored == nil || config.resetStoredDeviceID {
            // Temporary mode only applies when no ID was provided: an application
            // that knows who the user is does not want them held as anonymous.
            var requested = provided
            if config.temporaryDeviceIDMode {
                if provided == nil {
                    requested = TemporaryDeviceID.value
                } else {
                    logW("initialize", "temporary device ID mode is requested together with a device ID, the provided ID wins and temporary mode is not entered")
                }
            }
            storeCustomDeviceIDState(requested)
            apply(requested)
        } else {
            deviceID = stored ?? ""
            logD("initialize", "device ID restored from storage, valueLength: [\(deviceID.count)]")
            logV("initialize", "restored device ID value detail, deviceID: [\(deviceID)]")

            // The previous run ended in temporary mode and this one knows the user:
            // leave the placeholder once init is complete, so the held requests are
            // rewritten to the real identity.
            if isTemporary, let provided {
                logI("initialize", "a device ID is provided while the stored one is the temporary placeholder, temporary mode will be left after init")
                temporaryExitAfterInit = provided
            }
        }

        // A request still carrying the placeholder outside temporary mode, from a
        // run that ended while leaving it or from a reset, would block the queue
        // for good: the drain never sends a placeholder head.
        if !isTemporary {
            core.requestQueueStore.replaceTemporaryDeviceIDs(with: deviceID, typeValue: deviceIDType.wireValue)
        }

        logI("initialize", "device ID resolved, type: [\(deviceIDType)], typeValue: [\(deviceIDType.wireValue)], isTemporary: [\(isTemporary)]")
    }

    /// Hands what the stored user left behind back to that user before a reset
    /// clears their device ID: the recorded events go into a request under the
    /// stored ID, and a push token sent for it is taken back. Then the generated
    /// ID and the device ID kept from before temporary mode are dropped, so the
    /// reset resolves as on a first launch.
    private func handOverBeforeReset(stored: String?) {
        if let stored, stored != TemporaryDeviceID.value {
            let typeValue = (core.keyValueStore.isCustomDeviceID ? DeviceIDType.developerSupplied : .sdkGenerated).wireValue
            logD("initialize", "the stored device ID is reset, what its user recorded is filed under it first")
            core.modules.events.moveRecordedEvents(intoRequestFor: stored, typeValue: typeValue)
            core.modules.push.clearTokenForLeavingUser(deviceID: stored, typeValue: typeValue)
        }

        // The generated UUID is kept apart from the active ID, so a reset that left it would resolve to the same ID again.
        if core.keyValueStore.generatedUUID != nil {
            logD("initialize", "the stored device ID is reset, the generated ID it may have come from is dropped too")
            core.keyValueStore.generatedUUID = nil
        }
        clearPreTemporaryState()
    }

    /// Resolves an ID and persists it.
    private func apply(_ candidate: String?) {
        logD("apply", "device ID will be resolved and persisted, providedLength: [\(candidate?.count ?? 0)]")
        logV("apply", "provided device ID value detail, deviceID: [\(candidate ?? "")]")

        deviceID = ensafe(candidate)
        logV("apply", "resolved device ID value detail, deviceID: [\(deviceID)]")

        core.keyValueStore.deviceID = deviceID
        logD("apply", "device ID persisted, valueLength: [\(deviceID.count)], type: [\(deviceIDType)]")
    }

    /// Turns an absent ID into a usable one.
    ///
    /// The generated UUID is stored separately from the active ID, so switching to
    /// a developer supplied ID and back returns the same generated value rather
    /// than inventing a second identity for the same device.
    private func ensafe(_ candidate: String?) -> String {
        if let candidate, !candidate.isEmpty { return candidate }

        if let existing = core.keyValueStore.generatedUUID {
            logD("ensafe", "no device ID was provided, the previously generated one will be reused")
            return existing
        }

        let generated = UUID().uuidString
        core.keyValueStore.generatedUUID = generated
        logD("ensafe", "no device ID was provided, a new one was generated for this device")
        return generated
    }

    private func storeCustomDeviceIDState(_ candidate: String?) {
        let isCustom = !(candidate ?? "").isEmpty && candidate != TemporaryDeviceID.value
        logD("storeCustomDeviceIDState", "device ID origin recorded, developerSupplied: [\(isCustom)], previousDeveloperSupplied: [\(core.keyValueStore.isCustomDeviceID)]")
        core.keyValueStore.isCustomDeviceID = isCustom
    }

    private func clearPreTemporaryState() {
        guard core.keyValueStore.preTemporaryDeviceID != nil else { return }
        core.keyValueStore.preTemporaryDeviceID = nil
        core.keyValueStore.preTemporaryIsCustomDeviceID = false
    }

    // MARK: - Public operations

    /// Sets the ID, choosing the merge behavior from the current ID's origin.
    ///
    /// A developer supplied ID being replaced by another developer supplied ID is
    /// a different user, so no merge. Replacing a generated ID means the same
    /// person just identified themselves, so the histories are merged. In
    /// temporary mode the new ID only ends the mode.
    func setID(_ newID: String) {
        core.logGatherer.deviceIDChangeBegins()
        defer { core.logGatherer.deviceIDChangeEnds() }
        logI("setID", "changing the device ID, valueProvided: [\(!newID.isEmpty)]")
        logV("setID", "device ID value detail for the change whose merge behavior the SDK chooses, deviceID: [\(newID)]")

        guard isUsable(newID, "setID") else { return }

        let merge = deviceIDType != .developerSupplied
        logD("setID", "merge behavior resolved from the origin of the current device ID, currentType: [\(deviceIDType)], onServerMerge: [\(merge)]")
        changeDeviceID(newID, onServer: merge)
    }

    /// Changes the ID and asks the server to merge the old identity into it.
    func changeDeviceIDWithMerge(_ newID: String?) {
        core.logGatherer.deviceIDChangeBegins()
        defer { core.logGatherer.deviceIDChangeEnds() }
        logI("changeDeviceIDWithMerge", "changing the device ID with a server side merge, valueProvided: [\(!(newID ?? "").isEmpty)]")
        logV("changeDeviceIDWithMerge", "device ID value detail for the merging change, deviceID: [\(newID ?? "")]")
        guard let newID, isUsable(newID, "changeDeviceIDWithMerge") else { return }
        changeDeviceID(newID, onServer: true)
    }

    /// Changes the ID and starts a fresh identity, discarding user scoped state.
    func changeDeviceIDWithoutMerge(_ newID: String?) {
        core.logGatherer.deviceIDChangeBegins()
        defer { core.logGatherer.deviceIDChangeEnds() }
        logI("changeDeviceIDWithoutMerge", "changing the device ID without a server side merge, valueProvided: [\(!(newID ?? "").isEmpty)]")
        logV("changeDeviceIDWithoutMerge", "device ID value detail for the non merging change, deviceID: [\(newID ?? "")]")
        guard let newID, isUsable(newID, "changeDeviceIDWithoutMerge") else { return }
        changeDeviceID(newID, onServer: false)
    }

    /// Switches into temporary mode: nothing leaves the device until a real ID is
    /// set, and everything recorded meanwhile is rewritten to that ID. Works like
    /// a change without merge to the placeholder.
    func enableTemporaryDeviceIDMode() {
        core.logGatherer.deviceIDChangeBegins()
        defer { core.logGatherer.deviceIDChangeEnds() }
        logI("enableTemporaryDeviceIDMode", "switching to temporary device ID mode, currentType: [\(deviceIDType)], alreadyTemporary: [\(isTemporary)]")
        changeDeviceID(TemporaryDeviceID.value, onServer: false)
    }

    /// Leaves temporary mode and releases the held requests.
    ///
    /// With an ID, works like setting that ID in temporary mode. Without one, the
    /// SDK returns to the device ID, and its type, that was in use when the mode
    /// was entered at runtime, or generates one when the mode began at init.
    func disableTemporaryDeviceIDMode(_ newID: String?) {
        core.logGatherer.deviceIDChangeBegins()
        defer { core.logGatherer.deviceIDChangeEnds() }
        logI("disableTemporaryDeviceIDMode", "leaving temporary device ID mode, valueProvided: [\(!(newID ?? "").isEmpty)], isTemporary: [\(isTemporary)]")

        guard core.hasStarted else {
            logW("disableTemporaryDeviceIDMode", "omitting the call, the SDK has not been started yet")
            return
        }

        guard isTemporary else {
            logW("disableTemporaryDeviceIDMode", "omitting the call, the SDK is not in temporary device ID mode")
            return
        }

        if let newID, !newID.isEmpty {
            changeDeviceID(newID, onServer: false)
            return
        }

        if let previous = core.keyValueStore.preTemporaryDeviceID, !previous.isEmpty, previous != TemporaryDeviceID.value {
            let isCustom = core.keyValueStore.preTemporaryIsCustomDeviceID
            logD("disableTemporaryDeviceIDMode", "no device ID is provided, the device ID in use before temporary mode is restored, developerSupplied: [\(isCustom)]")
            leaveTemporaryMode(to: previous, isCustom: isCustom)
        } else {
            logD("disableTemporaryDeviceIDMode", "no device ID is provided and none was in use before temporary mode, a generated one is used")
            leaveTemporaryMode(to: ensafe(nil), isCustom: false)
        }
    }

    /// Whether a device ID call got an ID it can use. An empty one is ignored with
    /// a warning.
    private func isUsable(_ newID: String, _ function: String) -> Bool {
        guard newID.isEmpty else { return true }
        logW(function, "omitting the call, an empty string is not a valid device ID")
        core.healthTracker.recordLogCode(HealthLogCode.invalidDeviceID)
        return false
    }

    private func changeDeviceID(_ candidate: String?, onServer: Bool) {
        var onServer = onServer
        let previousType = deviceIDType

        logD("changeDeviceID", "applying the device ID change, valueProvided: [\(!(candidate ?? "").isEmpty)], onServer: [\(onServer)], previousType: [\(previousType)], wasTemporary: [\(isTemporary)]")
        logV("changeDeviceID", "device ID change value detail, providedDeviceID: [\(candidate ?? "")], currentDeviceID: [\(deviceID)]")

        guard core.hasStarted else {
            logW("changeDeviceID", "omitting the device ID change, the SDK has not been started yet")
            return
        }

        let resolved = ensafe(candidate)

        guard resolved != deviceID else {
            logD("changeDeviceID", "omitting the call, the provided device ID is identical to the current one, type: [\(previousType)]")
            return
        }

        // Leaving temporary mode is not a user change: it is the same user finally
        // getting an identity, so everything held back is rewritten and released.
        if isTemporary {
            leaveTemporaryMode(to: resolved, isCustom: !(candidate ?? "").isEmpty)
            return
        }

        if resolved == TemporaryDeviceID.value, onServer {
            logW("changeDeviceID", "the temporary device ID cannot be set with a server side merge, onServer is overridden as false")
            onServer = false
        }

        if onServer {
            changeWithMerge(to: resolved, candidate: candidate, previousType: previousType)
        } else {
            changeWithoutMerge(to: resolved, candidate: candidate, previousType: previousType)
        }
    }

    /// Replaces the placeholder with a real ID in every queued request and
    /// releases them. No merge request is sent: the server never saw the
    /// placeholder.
    private func leaveTemporaryMode(to newID: String, isCustom: Bool) {
        logI("leaveTemporaryMode", "leaving temporary device ID mode and switching back to normal mode, developerSupplied: [\(isCustom)]")

        core.keyValueStore.isCustomDeviceID = isCustom
        clearPreTemporaryState()
        apply(newID)
        logI("leaveTemporaryMode", "the requests held under the temporary device ID will be rewritten to the new identity rather than merged, newType: [\(deviceIDType)], typeValue: [\(deviceIDType.wireValue)]")
        core.requestQueueStore.replaceTemporaryDeviceIDs(with: newID, typeValue: deviceIDType.wireValue)
        // Persisted before anything else: the real device ID is already on
        // disk, so a rewrite left only in memory would leave a queue whose head
        // still carries the placeholder, which the drain refuses forever.
        core.requestQueueStore.saveSync()
        logD("leaveTemporaryMode", "the temporary device ID hold is released, the request queue will be drained and the configuration refreshed")
        core.network.proceedOnQueue()
        core.serverConfig.fetch(config: core.config)
        core.modules.remoteConfig.downloadRemoteConfigAutomatically()
        core.modules.push.temporaryDeviceIDReplaced(by: newID)
        core.modules.content.temporaryDeviceIDModeLeft()
        core.healthTracker.sendHealthCheck(isDeviceIDTemporary: false,
                                           networkingEnabled: core.serverConfig.networkingEnabled)
    }

    /// The same user under a new ID: the server merges the old identity into the
    /// new one. The session, the views, the timed events and consent continue.
    private func changeWithMerge(to newID: String, candidate: String?, previousType: DeviceIDType) {
        let oldDeviceID = deviceID
        storeCustomDeviceIDState(candidate)
        apply(newID)
        stateLock.lock()
        _mergeCount += 1
        stateLock.unlock()
        logI("changeDeviceID", "the previous identity will be merged into the new device ID on the server, previousType: [\(previousType)], newType: [\(deviceIDType)]")

        core.modules.push.deviceIDMerged(from: oldDeviceID, into: newID)
        core.modules.remoteConfig.clearCachedRemoteConfig()
        // The behavior settings and the remote config follow once the server has
        // accepted this request, see `mergeRequestWasAccepted()`.
        sendOldDeviceID(oldDeviceID)
    }

    /// A different user: what the leaving user recorded goes out under the old
    /// ID, the session, consent and the user scoped state end with them, and the
    /// new user starts clean.
    private func changeWithoutMerge(to newID: String, candidate: String?, previousType: DeviceIDType) {
        let entersTemporaryMode = newID == TemporaryDeviceID.value
        logI("changeDeviceID", "the device ID change starts a new user, views are stopped, pending data is sent under the previous device ID, the session is restarted, consents are removed, timed events and the content zone are cleared, previousType: [\(previousType)], entersTemporaryMode: [\(entersTemporaryMode)]")

        let modules = core.modules!

        // Under the leaving user's device ID.
        modules.views.stopAllViewsForIdentityChange()
        modules.events.sendEventsWithSaveIfNeeded()
        modules.push.clearTokenForLeavingUser()
        let endedSession = modules.sessions.endSessionForIdentityChange(includingManual: false)
        // Before the switch, so the gathered lines it queues carry the old device ID.
        core.logGatherer.stopForDeviceIDChange()
        modules.consent.removeAllConsentsForDeviceIDChange()

        if entersTemporaryMode {
            core.keyValueStore.preTemporaryDeviceID = deviceID
            core.keyValueStore.preTemporaryIsCustomDeviceID = previousType == .developerSupplied
        }
        storeCustomDeviceIDState(candidate)
        apply(newID)

        // For the new user.
        modules.content.exitContentZone()
        modules.events.clearAllTimedEvents()
        modules.remoteConfig.clearCachedRemoteConfig()
        modules.sessions.beginSessionAfterIdentityChange(wasAutomatic: endedSession)
        core.serverConfig.fetch(config: core.config)
        modules.remoteConfig.downloadRemoteConfigAutomatically()
        modules.views.startViewForCurrentScreenAfterIdentityChange()
        modules.push.deviceIDChangedWithoutMerge()
        logD("changeDeviceID", "the new user is in place after the device ID change, newType: [\(deviceIDType)], isTemporary: [\(isTemporary)]")
    }

    /// Tells the server which identity to merge into the current one.
    private func sendOldDeviceID(_ oldDeviceID: String) {
        logD("sendOldDeviceID", "the device ID merge request will be enqueued, oldValueLength: [\(oldDeviceID.count)]")
        logV("sendOldDeviceID", "merged away device ID value detail, oldDeviceID: [\(oldDeviceID)]")
        let queryString = "\(core.network.builder.queryEssentials())&\(QS.deviceIDOld)=\(oldDeviceID.urlEscaped)"
        core.network.enqueueAndProceed(queryString)
    }

    /// Called once the server has accepted a merge request. Only now are the
    /// behavior settings and the remote config fetched for the merged user: a
    /// fetch reaching the server before the merge would create the new user first,
    /// and the merge would then join two users instead of moving one.
    func mergeRequestWasAccepted() {
        guard core.hasStarted, !isTemporary else { return }
        logD("mergeRequestWasAccepted", "the server accepted the device ID merge, the behavior settings and the remote config are fetched for the merged user")
        core.serverConfig.fetch(config: core.config)
        core.modules.remoteConfig.downloadRemoteConfigAutomatically()
    }

    // MARK: - Lifecycle

    override func didInit() {
        guard let provided = temporaryExitAfterInit else { return }
        temporaryExitAfterInit = nil
        logD("didInit", "leaving the temporary device ID mode found in storage with the ID provided at init")
        core.logGatherer.deviceIDChangeBegins()
        defer { core.logGatherer.deviceIDChangeEnds() }
        changeDeviceID(provided, onServer: false)
    }

    override func halt(clearStorage: Bool) {
        if clearStorage {
            deviceID = ""
        }
    }
}
