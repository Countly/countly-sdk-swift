//
//  UserProfileModule.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Keys of the user profile payload.
enum UserProfileKey {
    static let name = "name"
    static let username = "username"
    static let email = "email"
    static let organization = "organization"
    static let phone = "phone"
    static let gender = "gender"
    static let picture = "picture"
    static let picturePath = "picturePath"
    static let birthYear = "byear"
    static let custom = "custom"

    /// Set of the fields the server stores at the top level rather than under
    /// `custom`.
    static let predefined: Set<String> = [
        name, username, email, organization, phone, gender, picture, picturePath, birthYear,
    ]

    /// Marker that carries a local picture path through the request queue, so the
    /// connection manager knows to turn the request into a multipart upload. It is
    /// removed before the request is sent.
    static let localPicturePath = "kCountlyLocalPicturePath"
}

/// Modifier operations the server applies to a user property.
enum UserPropertyModifier: String {
    case setOnce = "$setOnce"
    case increment = "$inc"
    case multiply = "$mul"
    case max = "$max"
    case min = "$min"
    case push = "$push"
    case addToSet = "$addToSet"
    case pull = "$pull"

    /// Whether the operand is a list of values collected in call order.
    var collectsValues: Bool {
        switch self {
        case .push, .addToSet, .pull: return true
        default: return false
        }
    }

    /// The pending operand and a new one of the same modifier, combined the way
    /// the server would have applied them one after the other: increments add
    /// up, multiplications multiply, the highest or lowest value is kept, the
    /// first setOnce value is kept and list values are collected.
    func combined(_ pending: Any, with new: Any) -> Any {
        func number(_ value: Any) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
        switch self {
        case .increment: return number(pending) + number(new)
        case .multiply: return number(pending) * number(new)
        case .max: return Swift.max(number(pending), number(new))
        case .min: return Swift.min(number(pending), number(new))
        case .setOnce: return pending
        case .push, .addToSet, .pull: return Self.values(pending) + Self.values(new)
        }
    }

    /// An operand as the list a list modifier sends.
    static func values(_ operand: Any) -> [Any] {
        (operand as? [Any]) ?? [operand]
    }
}

/// Collects everything known about the current user and sends it as one request.
///
/// Properties are staged rather than sent immediately, so setting five of them in
/// a row costs one request. Anything pending is flushed before a session or an
/// event goes out, because the server attributes those to whatever profile it
/// currently holds. Every call needs the "users" consent; without it the call is
/// ignored and a save discards what is pending.
final class UserProfileModule: ModuleBase {

    override class var moduleName: String { "UserProfile" }

    /// Predefined fields. `NSNull` means "clear on the server".
    private var predefinedFields: [String: Any] = [:]

    /// Custom properties set directly. `NSNull` means "clear on the server".
    private var customProperties: [String: Any] = [:]

    /// Custom property modifier operations, one modifier per property.
    private var customModifications: [String: [String: Any]] = [:]

    /// Local picture path, sent in its own multipart request.
    private var pictureLocalPath: String?

    private let lock = NSRecursiveLock()

    // MARK: - State

    /// Whether anything is staged and not yet sent.
    var hasUnsyncedChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingChangeCount > 0
    }

    /// How many changes are staged. The caller holds `lock`.
    private var pendingChangeCount: Int {
        predefinedFields.count + customProperties.count + customModifications.count + (pictureLocalPath == nil ? 0 : 1)
    }

    /// Whether profile calls may run, logging when they may not.
    private func hasConsent(_ function: String) -> Bool {
        guard core.modules.consent.hasConsent(for: .userDetails) else {
            logD(function, "no consent for user details, the call is ignored")
            return false
        }
        return true
    }

    // MARK: - Setting properties

    /// Truncates a string value to the limit that applies to its key.
    ///
    /// The two picture fields carry a URL rather than a profile value, and have
    /// their own larger limit. Anything that is not a string is returned as it is.
    private func truncatedValue(_ value: Any, forKey key: String, _ explanation: String) -> Any {
        guard let stringValue = value as? String else { return value }

        let isPicture = key == UserProfileKey.picture || key == UserProfileKey.picturePath
        return isPicture
            ? limits.truncatedPictureValue(stringValue, explanation)
            : limits.truncatedValue(stringValue, explanation)
    }

    /// Sets one property, routing predefined keys to their own fields.
    func setProperty(_ key: String, value: Any?) {
        logI("setProperty", "user property will be set, key: [\(key)], valueProvided: [\(value != nil)]")

        guard let value else {
            warnIgnored("setProperty", "a nil value is not set, an empty string clears a property, key: [\(key)]")
            return
        }
        setProperties([key: value])
    }

    /// Sets several properties at once, routing predefined keys to their own
    /// fields.
    ///
    /// An empty string clears the property on the server; a null value is ignored
    /// with a warning. A new value for a key replaces a pending value, and a key
    /// with a pending modifier has that saved first.
    func setProperties(_ data: [String: Any]) {
        guard !data.isEmpty else {
            warnIgnored("setProperties", "the call is ignored as no data was provided")
            return
        }
        guard hasConsent("setProperties") else { return }

        logI("setProperties", "user properties will be applied, keys: [\(data.keys.sorted())], count: [\(data.count)]")

        var appliedCount = 0
        var skippedCount = 0

        for (key, rawValue) in data {
            guard !key.isEmpty, !(rawValue is NSNull) else {
                warnIgnored("setProperties", "a property with an empty key or a null value is ignored, an empty string clears a property, key: [\(key)]")
                skippedCount += 1
                continue
            }

            let clears = (rawValue as? String)?.isEmpty == true
            let value: Any = clears ? NSNull() : truncatedValue(rawValue, forKey: key, "setProperties")

            if UserProfileKey.predefined.contains(key) {
                lock.lock()
                let accepted = assignPredefined(key, value: value)
                lock.unlock()
                if accepted {
                    appliedCount += 1
                } else {
                    skippedCount += 1
                }
                continue
            }

            guard core.serverConfig.shouldRecordUserProperty(key) else {
                logD("setProperties", "key is filtered out by server config user property filter while setting properties, key: [\(key)], omitting entry")
                skippedCount += 1
                continue
            }

            let candidate: Any? = clears ? NSNull() : storableValue(value)
            guard let storable = candidate else {
                warnIgnored("setProperties", "the value type is not supported, key: [\(key)], type: [\(type(of: value))]")
                skippedCount += 1
                continue
            }

            stageCustomValue(storable, forKey: limits.truncatedKey(key, "setProperties"), function: "setProperties")
            appliedCount += 1
        }

        logD("setProperties", "user properties processing finished, appliedCount: [\(appliedCount)], skippedCount: [\(skippedCount)], unsyncedChangesPending: [\(hasUnsyncedChanges)]")

        guard appliedCount > 0 else { return }
        userPropertiesChanged()
        saveIfCacheLimitReached()
    }

    /// Sets a custom property without routing predefined keys.
    ///
    /// Separate from `setProperty` because it stages the value without flushing
    /// pending events, which is what a caller batching many properties wants.
    func setCustomProperty(_ key: String, value: Any?) {
        logI("setCustomProperty", "custom user property will be set, key: [\(key)], valueProvided: [\(value != nil)]")

        guard let value, !(value is NSNull), !key.isEmpty else {
            warnIgnored("setCustomProperty", "the call is ignored, the key is empty or the value is null, key: [\(key)]")
            return
        }
        guard hasConsent("setCustomProperty") else { return }

        guard core.serverConfig.shouldRecordUserProperty(key) else {
            logD("setCustomProperty", "custom property key is filtered out by server config user property filter, key: [\(key)], omitting call")
            return
        }

        let clears = (value as? String)?.isEmpty == true
        let candidate: Any? = clears ? NSNull() : storableValue(value)
        guard let storable = candidate else {
            warnIgnored("setCustomProperty", "custom property value type is not supported, key: [\(key)], type: [\(type(of: value))]")
            return
        }

        let stored = truncatedValue(storable, forKey: key, "setCustomProperty")
        logV("setCustomProperty", "custom user property value detail as stored, key: [\(key)], value: [\(stored)]")
        stageCustomValue(stored, forKey: limits.truncatedKey(key, "setCustomProperty"), function: "setCustomProperty")
        saveIfCacheLimitReached()
    }

    /// Clears a custom property on the server.
    func unsetCustomProperty(_ key: String) {
        logI("unsetCustomProperty", "custom user property will be unset, key: [\(key)]")
        guard hasConsent("unsetCustomProperty") else { return }

        guard core.serverConfig.shouldRecordUserProperty(key) else {
            logD("unsetCustomProperty", "custom property key is filtered out by server config user property filter, key: [\(key)], omitting call")
            return
        }

        let truncatedKey = limits.truncatedKey(key, "unsetCustomProperty")
        stageCustomValue(NSNull(), forKey: truncatedKey, function: "unsetCustomProperty")
        logD("unsetCustomProperty", "custom user property is staged for clearing on the server, key: [\(truncatedKey)]")
        saveIfCacheLimitReached()
    }

    /// Stages a value for a custom property. A pending value of the key is
    /// replaced; a pending modifier is saved first, since the server cannot apply
    /// both to one property in one request.
    private func stageCustomValue(_ value: Any, forKey key: String, function: String) {
        lock.lock()
        let hasPendingModifier = customModifications[key] != nil
        lock.unlock()

        if hasPendingModifier {
            logD(function, "the key has a pending modifier, it is saved before the new value is staged, key: [\(key)]")
            save()
        }

        lock.lock()
        customProperties[key] = value
        lock.unlock()
        logV(function, "custom user property value detail as stored, key: [\(key)], value: [\(value)]")
    }

    // MARK: - Modifiers

    /// Sets a property only if it has no value yet.
    func setOnce(_ key: String, value: Any) { modify(.setOnce, key: key, value: value) }

    /// Adds one to a numeric property.
    func increment(_ key: String) { incrementBy(key, value: 1) }

    /// Adds an amount to a numeric property.
    func incrementBy(_ key: String, value: Double) { modify(.increment, key: key, value: value) }

    /// Multiplies a numeric property.
    func multiply(_ key: String, value: Double) { modify(.multiply, key: key, value: value) }

    /// Keeps the larger of the stored and the given value.
    func max(_ key: String, value: Double) { modify(.max, key: key, value: value) }

    /// Keeps the smaller of the stored and the given value.
    func min(_ key: String, value: Double) { modify(.min, key: key, value: value) }

    /// Appends to a list property, duplicates allowed.
    func push(_ key: String, value: Any) { modify(.push, key: key, value: value) }

    /// Appends to a list property only if it is not already there.
    func pushUnique(_ key: String, value: Any) { modify(.addToSet, key: key, value: value) }

    /// Removes from a list property.
    func pull(_ key: String, value: Any) { modify(.pull, key: key, value: value) }

    /// Stages one modifier operation.
    ///
    /// The same modifier called again on a key is combined with the pending one,
    /// see `UserPropertyModifier.combined(_:with:)`. A different change pending for
    /// the key, another modifier or a value, is saved first, since the server
    /// cannot apply two of them to one property in one request.
    private func modify(_ modifier: UserPropertyModifier, key: String, value: Any) {
        logI("modify", "user property modifier will be applied, modifier: [\(modifier.rawValue)], key: [\(key)]")

        guard !key.isEmpty, !(value is NSNull) else {
            warnIgnored("modify", "the call is ignored, the key is empty or the value is null, modifier: [\(modifier.rawValue)], key: [\(key)]")
            return
        }
        guard hasConsent("modify") else { return }

        guard let storable = storableValue(value) else {
            warnIgnored("modify", "modifier value type is not supported, modifier: [\(modifier.rawValue)], key: [\(key)], type: [\(type(of: value))]")
            return
        }

        guard core.serverConfig.shouldRecordUserProperty(key) else {
            logD("modify", "modifier key is filtered out by server config user property filter, key: [\(key)], omitting call")
            return
        }

        var stored = storable
        if let stringValue = storable as? String {
            stored = limits.truncatedValue(stringValue, "modify")
        }
        if modifier.collectsValues {
            stored = UserPropertyModifier.values(stored)
        }

        let truncatedKey = limits.truncatedKey(key, "modify")
        logV("modify", "modifier operand value detail as stored, modifier: [\(modifier.rawValue)], key: [\(truncatedKey)], value: [\(stored)]")

        lock.lock()
        let pendingModifier = customModifications[truncatedKey]?.keys.first
        let hasPendingValue = customProperties[truncatedKey] != nil
        lock.unlock()

        if hasPendingValue || (pendingModifier != nil && pendingModifier != modifier.rawValue) {
            logD("modify", "the key has a different pending change, it is saved before the modifier is staged, key: [\(truncatedKey)], pendingModifier: [\(pendingModifier ?? "value")], modifier: [\(modifier.rawValue)]")
            save()
        }

        lock.lock()
        if let pending = customModifications[truncatedKey]?[modifier.rawValue] {
            customModifications[truncatedKey] = [modifier.rawValue: modifier.combined(pending, with: stored)]
            logD("modify", "the operand is combined with the pending one of the same modifier, modifier: [\(modifier.rawValue)], key: [\(truncatedKey)]")
        } else {
            customModifications[truncatedKey] = [modifier.rawValue: stored]
        }
        let total = customModifications.count
        lock.unlock()

        logD("modify", "modification stored, modifier: [\(modifier.rawValue)], key: [\(truncatedKey)], totalModifications: [\(total)]")
        saveIfCacheLimitReached()
    }

    // MARK: - Predefined fields

    /// Assigns a predefined field, returning whether the value was accepted. The
    /// caller holds `lock`.
    ///
    /// A rejected value must not count as a change, or the SDK would flush events
    /// and send a user details request carrying nothing.
    private func assignPredefined(_ key: String, value: Any) -> Bool {
        let isNull = value is NSNull

        logD("assignPredefined", "predefined user property will be assigned, key: [\(key)], clears: [\(isNull)]")
        logV("assignPredefined", "predefined user property value detail, key: [\(key)], value: [\(value)]")

        switch key {
        case UserProfileKey.name, UserProfileKey.username, UserProfileKey.email,
             UserProfileKey.organization, UserProfileKey.phone, UserProfileKey.gender,
             UserProfileKey.picture:
            predefinedFields[key] = isNull ? NSNull() : String(describing: value)
            return true

        case UserProfileKey.picturePath:
            guard !isNull else {
                pictureLocalPath = nil
                return true
            }
            #if !(os(iOS) || os(visionOS))
            // Nothing uploads a local file on this platform, and sent as text the path would leak a folder name.
            logW("assignPredefined", "a local picture path can only be uploaded on iOS and visionOS, the value is dropped")
            return false
            #else
            let path = String(describing: value)
            // An unreadable path would produce a multipart request with no file,
            // which the server rejects, so it is dropped here instead.
            if !LocalPicturePath.isReadable(path) {
                logW("assignPredefined", "provided picture path file can not be opened, pathLength: [\(path.count)], value will be dropped")
                pictureLocalPath = nil
            } else {
                pictureLocalPath = path
            }
            return true
            #endif

        case UserProfileKey.birthYear:
            guard !isNull else {
                predefinedFields[key] = NSNull()
                return true
            }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded(), number.intValue >= 0 else {
                warnIgnored("assignPredefined", "the birth year is ignored, it has to be a whole number, key: [\(key)], type: [\(type(of: value))]")
                return false
            }
            predefinedFields[key] = number.intValue
            return true

        default:
            return false
        }
    }

    // MARK: - Sending

    /// Sends everything staged and clears it.
    ///
    /// Without the "users" consent nothing is sent and the pending changes are
    /// discarded.
    ///
    /// - Returns: whether the save went ahead. The caller needs to know, because a
    ///   save that declines has not flushed the pending events either, and those
    ///   still have to be sent by someone.
    @discardableResult
    func save() -> Bool {
        logI("save", "user details will be saved")

        guard core.hasStarted else {
            logW("save", "user details save will be ignored as SDK is not initialized yet")
            return false
        }

        guard core.modules.consent.hasConsent(for: .userDetails) else {
            if hasUnsyncedChanges {
                logD("save", "no consent for user details, the pending changes are discarded")
                clearUserDetails()
            }
            return false
        }

        guard hasUnsyncedChanges else {
            logD("save", "no unsynced user details changes, save will be skipped")
            return false
        }

        // Events first: an event recorded before a profile change belongs to the
        // profile as it was.
        logD("save", "the recorded events are sent before the user details request so they keep the profile they were recorded under, pendingEventCount: [\(core.modules.events.pendingEventCount)]")
        core.modules.events.sendEvents()

        var queuedRequestCount = 0

        if let payload = serializedUserDetails() {
            logD("save", "serialized user details request will be sent, payloadLength: [\(payload.count)]")
            logV("save", "serialized user details payload detail, payload: [\(payload)]")
            sendUserDetails(payload)
            queuedRequestCount += 1
        }

        lock.lock()
        let localPath = pictureLocalPath
        // A remote picture URL supersedes a local file, but an explicit clear is
        // not a URL: `setProperties(["picture": "", "picturePath": path])` means
        // "drop whatever is on the server and upload this file", and reading the
        // key's mere presence would suppress the upload and then discard the
        // staged path along with everything else.
        let hasPictureURL = !(predefinedFields[UserProfileKey.picture] is NSNull)
            && predefinedFields[UserProfileKey.picture] != nil
        lock.unlock()

        // The picture upload is a multipart request of its own, and a remote
        // picture URL supersedes a local file.
        if let localPath, !hasPictureURL {
            logD("save", "local picture path will be sent in a separate request, pathLength: [\(localPath.count)]")
            sendUserDetails(CountlyJSON.escapedString(from: [UserProfileKey.localPicturePath: localPath], logger: log))
            queuedRequestCount += 1
        } else if localPath != nil {
            logD("save", "the staged local picture path is dropped because a remote picture URL was set alongside it")
        }

        logD("save", "user details save finished, queuedRequestCount: [\(queuedRequestCount)]")

        clearUserDetails()
        return true
    }

    /// Saves automatically once the pending changes reach the server's "upcl"
    /// limit. Nothing pending is ever dropped because of it.
    private func saveIfCacheLimitReached() {
        lock.lock()
        let count = pendingChangeCount
        lock.unlock()

        let limit = core.serverConfig.userPropertyCacheLimit
        guard limit > 0, count >= limit else { return }
        logD("saveIfCacheLimitReached", "the pending user property changes reached the cache limit and are saved, pendingChangeCount: [\(count)], limit: [\(limit)]")
        save()
    }

    private func sendUserDetails(_ payload: String) {
        guard !payload.isEmpty else {
            // The serializer reports the failure that produced this, so raising a
            // second error here would count the same incident twice on the wire.
            logD("sendUserDetails", "an empty user details payload will not be sent")
            return
        }
        let queryString = "\(core.network.builder.queryEssentials())&\(QS.userDetails)=\(payload)"
        core.network.enqueueAndProceed(queryString)
    }

    /// Builds the `user_details` payload, or `nil` when nothing is staged.
    private func serializedUserDetails() -> String? {
        lock.lock()
        defer { lock.unlock() }

        var payload: [String: Any] = predefinedFields

        var custom: [String: Any] = [:]
        if !customProperties.isEmpty {
            // Both limits apply here; the modifiers below take neither, on either reference.
            custom.merge(limits.limited(customProperties, "user details custom properties")) { _, new in new }
        }
        if !customModifications.isEmpty {
            custom.merge(customModifications) { _, new in new }
        }
        if !custom.isEmpty {
            payload[UserProfileKey.custom] = custom
        }

        logD("serializedUserDetails", "user details serialized, fields: [\(payload.keys.sorted())], customKeys: [\(custom.keys.sorted())]")

        guard !payload.isEmpty else {
            logD("serializedUserDetails", "nothing is staged in the user details payload, no request will be built")
            return nil
        }

        // `escapedString` answers with an empty string when the object cannot be
        // represented as JSON. Sending that would put `user_details=` on the wire
        // with nothing after it, and `save` would then clear every staged property
        // as if the server had received them. Reporting nothing to send is what
        // keeps the properties staged for the next attempt.
        let escaped = CountlyJSON.escapedString(from: payload, logger: log)
        guard !escaped.isEmpty else {
            // The serializer already reports this as an error, so this line only
            // names the fields that stay staged for the next attempt.
            logD("serializedUserDetails", "user details could not be serialized and will not be sent, fields: [\(payload.keys.sorted())]")
            return nil
        }
        return escaped
    }

    /// Drops everything staged without sending it.
    func clearUserDetails() {
        lock.lock()
        defer { lock.unlock() }

        logD("clearUserDetails", "user details will be cleared, customPropertyCount: [\(customProperties.count)], modificationCount: [\(customModifications.count)]")

        predefinedFields.removeAll()
        customProperties.removeAll()
        customModifications.removeAll()
        pictureLocalPath = nil
    }

    /// Public alias, kept so the intent reads the same as the API name.
    func clear() {
        logI("clear", "all user details and modifications will be cleared")
        clearUserDetails()
    }

    /// Flushes pending events so they reach the server before the profile change.
    private func userPropertiesChanged() {
        guard core.hasStarted else {
            logD("userPropertiesChanged", "SDK is not started yet, pending events will not be flushed")
            return
        }
        logD("userPropertiesChanged", "user properties changed, the recorded events are flushed first so they keep the previous profile, pendingEventCount: [\(core.modules.events.pendingEventCount)]")
        core.modules.events.sendEvents()
    }

    /// Logs an ignored call or value as a warning and counts it.
    private func warnIgnored(_ function: String, _ message: String) {
        logW(function, message)
        core.healthTracker.recordLogCode(HealthLogCode.invalidValue)
    }

    /// The value as the server stores it, or `nil` when it cannot be stored.
    ///
    /// Scalars follow the same rule as segmentation, so a date becomes epoch
    /// milliseconds and a non-finite number is refused here too. The one rule of
    /// the profile's own is that a list is refused whole when any element is,
    /// since half a list is not what the caller asked to store.
    private func storableValue(_ value: Any) -> Any? {
        if let list = value as? [Any] {
            let converted = list.compactMap(storableValue)
            return converted.count == list.count ? converted : nil
        }
        return limits.supportedValue(value)
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        clearUserDetails()
    }
}
