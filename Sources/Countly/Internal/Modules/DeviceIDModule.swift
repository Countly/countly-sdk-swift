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

        if stored == nil || config.resetStoredDeviceID {
            let requested = config.temporaryDeviceIDMode ? TemporaryDeviceID.value : config.deviceID
            storeCustomDeviceIDState(requested)
            apply(requested)
        } else {
            deviceID = stored ?? ""
            logD("initialize", "device ID restored from storage, valueLength: [\(deviceID.count)]")
        }
    }

    /// Resolves an ID and persists it.
    private func apply(_ candidate: String?) {
        logD("apply", "device ID will be initialized, providedLength: [\(candidate?.count ?? 0)]")
        logV("apply", "provided device ID value detail, deviceID: [\(candidate ?? "")]")

        deviceID = ensafe(candidate)
        logV("apply", "resolved device ID value detail, deviceID: [\(deviceID)]")

        core.keyValueStore.deviceID = deviceID
    }

    /// Turns an absent ID into a usable one.
    ///
    /// The generated UUID is stored separately from the active ID, so switching to
    /// a developer supplied ID and back returns the same generated value rather
    /// than inventing a second identity for the same device.
    private func ensafe(_ candidate: String?) -> String {
        if let candidate, !candidate.isEmpty { return candidate }

        if let existing = core.keyValueStore.generatedUUID { return existing }

        let generated = UUID().uuidString
        core.keyValueStore.generatedUUID = generated
        return generated
    }

    private func storeCustomDeviceIDState(_ candidate: String?) {
        let isCustom = !(candidate ?? "").isEmpty && candidate != TemporaryDeviceID.value
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

        guard !newID.isEmpty else {
            logW("setID", "omitting the call, passing an empty string as the device ID is not allowed")
            return
        }

        let merge = deviceIDType != .developerSupplied
        changeDeviceID(newID, onServer: merge)
    }

    /// Changes the ID and asks the server to merge the old identity into it.
    func changeDeviceIDWithMerge(_ newID: String?) {
        logI("changeDeviceIDWithMerge", "changing the device ID with a server side merge, valueProvided: [\(!(newID ?? "").isEmpty)]")
        changeDeviceID(newID, onServer: true)
    }

    /// Changes the ID and starts a fresh identity, discarding user scoped state.
    func changeDeviceIDWithoutMerge(_ newID: String?) {
        logI("changeDeviceIDWithoutMerge", "changing the device ID without a server side merge, valueProvided: [\(!(newID ?? "").isEmpty)]")
        changeDeviceID(newID, onServer: false)
    }

    /// Switches into temporary mode: nothing leaves the device until a real ID is
    /// set, and everything recorded meanwhile is rewritten to that ID.
    func enableTemporaryDeviceIDMode() {
        logI("enableTemporaryDeviceIDMode", "switching to temporary device ID mode")
        changeDeviceID(TemporaryDeviceID.value, onServer: false)
    }

    private func changeDeviceID(_ candidate: String?, onServer: Bool) {
        var onServer = onServer

        logD("changeDeviceID", "applying the device ID change, valueProvided: [\(!(candidate ?? "").isEmpty)], onServer: [\(onServer)]")
        logV("changeDeviceID", "device ID change detail, deviceID: [\(candidate ?? "")], onServer: [\(onServer)]")

        guard core.hasStarted else {
            logW("changeDeviceID", "omitting the device ID change, the SDK has not been started yet")
            return
        }

        if (candidate ?? "").isEmpty {
            logW("changeDeviceID", "passing nil or an empty string as the device ID is deprecated and will not be allowed in the future")
        }

        let resolved = ensafe(candidate)

        guard resolved != deviceID else {
            logD("changeDeviceID", "omitting the call, the provided device ID is identical to the current one")
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
            core.requestQueueStore.replaceTemporaryDeviceIDs(with: resolved, typeValue: deviceIDType.wireValue)
            // Persisted before anything else: the real device ID is already on
            // disk, so a rewrite left only in memory would leave a queue whose head
            // still carries the placeholder, which the drain refuses forever.
            core.requestQueueStore.saveSync()
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
            sendOldDeviceID(oldDeviceID)
        } else {
            // The session belongs to the old identity, so it is closed before the
            // switch and reopened after it.
            core.modules.sessions.suspend()
            apply(resolved)
            core.modules.consent.cancelAllConsentsWithoutSending()
            core.modules.sessions.resume()
            core.modules.events.clearAllTimedEvents()
        }

        core.modules.remoteConfig.clearCachedRemoteConfig()

        if resolved != TemporaryDeviceID.value {
            core.modules.remoteConfig.downloadRemoteConfigAutomatically()
        }
    }

    /// Tells the server which identity to merge into the current one.
    private func sendOldDeviceID(_ oldDeviceID: String) {
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
