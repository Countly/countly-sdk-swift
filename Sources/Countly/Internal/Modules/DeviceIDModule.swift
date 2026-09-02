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
    private(set) var deviceID: String = ""

    /// Whether the SDK is holding everything back until a real ID arrives.
    var isTemporary: Bool { deviceID == TemporaryDeviceID.value }

    /// How the current ID was obtained, as reported in the `t` parameter.
    var deviceIDType: DeviceIDType {
        if isTemporary { return .temporary }
        if core.keyValueStore.isCustomDeviceID { return .developerSupplied }
        return .sdkGenerated
    }

    // MARK: - Init

    /// Resolves the ID for this launch.
    ///
    /// A stored ID wins unless the host application asked for a reset, so an
    /// application that hardcodes no device ID keeps the identity it had.
    func initialize(with config: CountlyConfig) {
        let stored = core.keyValueStore.deviceID

        logI("initialize", "resolving the device ID for this launch, storedIDPresent: [\(stored != nil)], configIDProvided: [\(!(config.deviceID ?? "").isEmpty)], temporaryModeRequested: [\(config.temporaryDeviceIDMode)], resetStoredIDRequested: [\(config.resetStoredDeviceID)]")

        if stored == nil || config.resetStoredDeviceID {
            let requested = config.temporaryDeviceIDMode ? TemporaryDeviceID.value : config.deviceID
            storeCustomDeviceIDState(requested)
            apply(requested)
        } else {
            deviceID = stored ?? ""
            logD("initialize", "device ID restored from storage, valueLength: [\(deviceID.count)]")
            logV("initialize", "restored device ID value detail, deviceID: [\(deviceID)]")
        }

        logI("initialize", "device ID resolved, type: [\(deviceIDType)], typeValue: [\(deviceIDType.wireValue)], isTemporary: [\(isTemporary)]")
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

    // MARK: - Public operations

    /// Sets the ID, choosing the merge behavior from the current ID's origin.
    ///
    /// A developer supplied ID being replaced by another developer supplied ID is
    /// a different user, so no merge. Replacing a generated ID means the same
    /// person just identified themselves, so the histories are merged.
    func setID(_ newID: String) {
        logI("setID", "changing the device ID, valueProvided: [\(!newID.isEmpty)]")
        logV("setID", "device ID value detail for the change whose merge behavior the SDK chooses, deviceID: [\(newID)]")

        guard !newID.isEmpty else {
            logW("setID", "omitting the call, passing an empty string as the device ID is not allowed")
            return
        }

        let merge = deviceIDType != .developerSupplied
        logD("setID", "merge behavior resolved from the origin of the current device ID, currentType: [\(deviceIDType)], onServerMerge: [\(merge)]")
        changeDeviceID(newID, onServer: merge)
    }

    /// Changes the ID and asks the server to merge the old identity into it.
    func changeDeviceIDWithMerge(_ newID: String?) {
        logI("changeDeviceIDWithMerge", "changing the device ID with a server side merge, valueProvided: [\(!(newID ?? "").isEmpty)]")
        logV("changeDeviceIDWithMerge", "device ID value detail for the merging change, deviceID: [\(newID ?? "")]")
        changeDeviceID(newID, onServer: true)
    }

    /// Changes the ID and starts a fresh identity, discarding user scoped state.
    func changeDeviceIDWithoutMerge(_ newID: String?) {
        logI("changeDeviceIDWithoutMerge", "changing the device ID without a server side merge, valueProvided: [\(!(newID ?? "").isEmpty)]")
        logV("changeDeviceIDWithoutMerge", "device ID value detail for the non merging change, deviceID: [\(newID ?? "")]")
        changeDeviceID(newID, onServer: false)
    }

    /// Switches into temporary mode: nothing leaves the device until a real ID is
    /// set, and everything recorded meanwhile is rewritten to that ID.
    func enableTemporaryDeviceIDMode() {
        logI("enableTemporaryDeviceIDMode", "switching to temporary device ID mode, currentType: [\(deviceIDType)], alreadyTemporary: [\(isTemporary)]")
        changeDeviceID(TemporaryDeviceID.value, onServer: false)
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

        if (candidate ?? "").isEmpty {
            logW("changeDeviceID", "passing nil or an empty string as the device ID is deprecated and will not be allowed in the future")
        }

        let resolved = ensafe(candidate)

        guard resolved != deviceID else {
            logD("changeDeviceID", "omitting the call, the provided device ID is identical to the current one, type: [\(previousType)]")
            return
        }

        // Recorded only once the change is going ahead. Doing it above the guard,
        // which is what the Objective-C SDK does, lets a host that reads the current
        // ID and hands it straight back reclassify an SDK generated ID as developer
        // supplied: nothing is sent, but `t` flips to 0 and the next real change
        // then splits the user's history instead of merging it.
        storeCustomDeviceIDState(candidate)

        // Leaving temporary mode is not a user change: it is the same user finally
        // getting an identity, so everything held back is rewritten and released.
        if isTemporary {
            logI("changeDeviceID", "leaving temporary device ID mode and switching back to normal mode")

            apply(resolved)
            logI("changeDeviceID", "the requests held under the temporary device ID will be rewritten to the new identity rather than merged, newType: [\(deviceIDType)], typeValue: [\(deviceIDType.wireValue)]")
            core.requestQueueStore.replaceTemporaryDeviceIDs(with: resolved, typeValue: deviceIDType.wireValue)
            // Persisted before anything else: the real device ID is already on
            // disk, so a rewrite left only in memory would leave a queue whose head
            // still carries the placeholder, which the drain refuses forever.
            core.requestQueueStore.saveSync()
            logD("changeDeviceID", "the temporary device ID hold is released, the request queue will be drained and the configuration refreshed")
            core.network.proceedOnQueue()
            core.serverConfig.fetch(config: core.config)
            core.modules.remoteConfig.downloadRemoteConfigAutomatically()
            core.healthTracker.sendHealthCheck(isDeviceIDTemporary: false,
                                               networkingEnabled: core.serverConfig.networkingEnabled)
            return
        }

        if resolved == TemporaryDeviceID.value, onServer {
            logW("changeDeviceID", "the temporary device ID cannot be set with a server side merge, onServer is overridden as false")
            onServer = false
        }

        if onServer {
            let oldDeviceID = deviceID
            apply(resolved)
            logI("changeDeviceID", "the previous identity will be merged into the new device ID on the server, previousType: [\(previousType)], newType: [\(deviceIDType)]")
            sendOldDeviceID(oldDeviceID)
        } else {
            logI("changeDeviceID", "the device ID change starts a new user, the session is restarted, consents are cancelled and timed events are dropped, previousType: [\(previousType)]")

            // The session belongs to the old identity, so it is closed before the
            // switch and reopened after it.
            core.modules.sessions.suspend()
            apply(resolved)
            core.modules.consent.cancelAllConsentsWithoutSending()
            core.modules.sessions.resume()
            core.modules.events.clearAllTimedEvents()
            logD("changeDeviceID", "the new user is in place after the device ID change, newType: [\(deviceIDType)], isTemporary: [\(isTemporary)]")
        }

        core.modules.remoteConfig.clearCachedRemoteConfig()

        if resolved != TemporaryDeviceID.value {
            core.modules.remoteConfig.downloadRemoteConfigAutomatically()
        } else {
            logD("changeDeviceID", "remote config will not be downloaded, the new device ID is the temporary one")
        }
    }

    /// Tells the server which identity to merge into the current one.
    private func sendOldDeviceID(_ oldDeviceID: String) {
        logD("sendOldDeviceID", "the device ID merge request will be enqueued, oldValueLength: [\(oldDeviceID.count)]")
        logV("sendOldDeviceID", "merged away device ID value detail, oldDeviceID: [\(oldDeviceID)]")
        let queryString = "\(core.network.builder.queryEssentials())&\(QS.deviceIDOld)=\(oldDeviceID.urlEscaped)"
        core.network.enqueueAndProceed(queryString)
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        if clearStorage {
            deviceID = ""
        }
    }
}
