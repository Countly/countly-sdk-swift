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
    /// connection manager knows to turn the request into a multipart upload.
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

    /// Whether repeated calls accumulate into a list rather than replacing.
    var accumulates: Bool {
        switch self {
        case .push, .addToSet, .pull: return true
        default: return false
        }
    }
}

/// Collects everything known about the current user and sends it as one request.
///
/// Properties are staged rather than sent immediately, so setting five of them in
/// a row costs one request. Anything pending is flushed before a session or an
/// event goes out, because the server attributes those to whatever profile it
/// currently holds.
final class UserProfileModule: ModuleBase {

    override class var moduleName: String { "UserProfile" }

    /// Predefined fields. `NSNull` means "clear on the server".
    private var predefinedFields: [String: Any] = [:]

    /// Custom properties set directly.
    private var customProperties: [String: Any] = [:]

    /// Custom property modifier operations.
    private var customModifications: [String: [String: Any]] = [:]

    /// Local picture path, sent in its own multipart request.
    private var pictureLocalPath: String?

    private let lock = NSRecursiveLock()

    // MARK: - State

    /// Whether anything is staged and not yet sent.
    var hasUnsyncedChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !predefinedFields.isEmpty
            || !customProperties.isEmpty
            || !customModifications.isEmpty
            || pictureLocalPath != nil
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
            ? core.limits.truncatedPictureValue(stringValue, explanation)
            : core.limits.truncatedValue(stringValue, explanation)
    }

    /// Sets one property, routing predefined keys to their own fields.
    func setProperty(_ key: String, value: Any?) {
        logI("setProperty", "user property will be set, key: [\(key)], valueProvided: [\(value != nil)]")
        logV("setProperty", "single user property value detail, key: [\(key)], value: [\(String(describing: value))]")

        guard let value else { return }
        setProperties([key: value])
    }

    /// Sets several properties at once, routing predefined keys to their own
    /// fields.
    ///
    /// Pass `NSNull()` as a value to clear a field. Passing an empty string clears
    /// it too: the server treats `""` as a clear and ignores `null` for predefined
    /// fields, so the empty string is the reliable form.
    func setProperties(_ data: [String: Any]) {
        guard !data.isEmpty else {
            logW("setProperties", "call will be ignored as no data was provided")
            return
        }

        logI("setProperties", "user properties will be applied, keys: [\(data.keys.sorted())], count: [\(data.count)]")
        logV("setProperties", "user properties value detail, data: [\(data)]")

        var anyChange = false

        lock.lock()
        for (key, rawValue) in data {
            var value = rawValue

            if value is NSNull {
                guard UserProfileKey.predefined.contains(key) else {
                    logD("setProperties", "provided value is null, key: [\(key)], skipping this entry")
                    continue
                }
                if assignPredefined(key, value: NSNull()) { anyChange = true }
                continue
            }

            value = truncatedValue(value, forKey: key, "setProperties")

            if UserProfileKey.predefined.contains(key) {
                if assignPredefined(key, value: value) { anyChange = true }
                continue
            }

            guard core.serverConfig.shouldRecordUserProperty(key) else {
                logD("setProperties", "key is filtered out by server config user property filter while setting properties, key: [\(key)], omitting entry")
                continue
            }

            guard isValidDataType(value) else {
                logD("setProperties", "provided value type is not supported, key: [\(key)], type: [\(type(of: value))], omitting entry")
                continue
            }

            customProperties[core.limits.truncatedKey(key, "setProperties")] = value
            anyChange = true
        }
        lock.unlock()

        logD("setProperties", "user properties processing finished, anyChange: [\(anyChange)]")
        if anyChange { userPropertiesChanged() }
    }

    /// Sets a custom property without routing predefined keys.
    ///
    /// Separate from `setProperty` because it stages the value without flushing
    /// pending events, which is what a caller batching many properties wants.
    func setCustomProperty(_ key: String, value: Any?) {
        guard let value else {
            logE("setCustomProperty", "call will be ignored as value is nil, key: [\(key)]")
            return
        }

        guard core.serverConfig.shouldRecordUserProperty(key) else {
            logD("setCustomProperty", "custom property key is filtered out by server config user property filter, key: [\(key)], omitting call")
            return
        }

        guard isValidDataType(value) else {
            logW("setCustomProperty", "custom property value type is not supported, key: [\(key)], type: [\(type(of: value))], omitting call")
            return
        }

        let stored = truncatedValue(value, forKey: key, "setCustomProperty")

        lock.lock()
        customProperties[core.limits.truncatedKey(key, "setCustomProperty")] = stored
        let total = customProperties.count
        lock.unlock()

        logD("setCustomProperty", "custom user property stored, key: [\(key)], totalCustomProperties: [\(total)]")
    }

    /// Clears a custom property on the server.
    func unsetCustomProperty(_ key: String) {
        logI("unsetCustomProperty", "custom user property will be unset, key: [\(key)]")
        lock.lock()
        customProperties[core.limits.truncatedKey(key, "unsetCustomProperty")] = NSNull()
        lock.unlock()
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
    /// Repeated list operations on the same key accumulate into an array instead of
    /// overwriting, so pushing three values before a save sends all three.
    private func modify(_ modifier: UserPropertyModifier, key: String, value: Any) {
        logI("modify", "user property modifier will be applied, modifier: [\(modifier.rawValue)], key: [\(key)]")
        logV("modify", "modifier operand value detail, modifier: [\(modifier.rawValue)], key: [\(key)], value: [\(value)]")

        guard isValidDataType(value) else {
            logW("modify", "modifier value type is not supported, modifier: [\(modifier.rawValue)], key: [\(key)], type: [\(type(of: value))], omitting call")
            return
        }

        guard core.serverConfig.shouldRecordUserProperty(key) else {
            logD("modify", "modifier key is filtered out by server config user property filter, key: [\(key)], omitting call")
            return
        }

        var stored = value
        if let stringValue = value as? String {
            stored = core.limits.truncatedValue(stringValue, "modify")
        }

        let truncatedKey = core.limits.truncatedKey(key, "modify")

        lock.lock()
        defer { lock.unlock() }

        if modifier.accumulates, let existing = customModifications[truncatedKey]?[modifier.rawValue] {
            var accumulated = (existing as? [Any]) ?? [existing]
            if let list = stored as? [Any] {
                accumulated.append(contentsOf: list)
            } else {
                accumulated.append(stored)
            }
            customModifications[truncatedKey] = [modifier.rawValue: accumulated]
        } else {
            customModifications[truncatedKey] = [modifier.rawValue: stored]
        }

        logD("modify", "modification stored, modifier: [\(modifier.rawValue)], key: [\(truncatedKey)], totalModifications: [\(customModifications.count)]")
    }

    // MARK: - Predefined fields

    /// Assigns a predefined field, returning whether the value was accepted.
    ///
    /// A rejected value must not count as a change, or the SDK would flush events
    /// and send a user details request carrying nothing.
    private func assignPredefined(_ key: String, value: Any) -> Bool {
        let isNull = value is NSNull

        logD("assignPredefined", "predefined user property will be assigned, key: [\(key)], isNull: [\(isNull)]")
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
            let path = String(describing: value)
            // An unreadable path would produce a multipart request with no file,
            // which the server rejects, so it is dropped here instead.
            if !path.isEmpty, !LocalPicturePath.isReadable(path) {
                logW("assignPredefined", "provided picture path file can not be opened, pathLength: [\(path.count)], value will be dropped")
                pictureLocalPath = nil
            } else {
                pictureLocalPath = path
            }
            return true

        case UserProfileKey.birthYear:
            guard !isNull else {
                predefinedFields[key] = NSNull()
                return true
            }
            if let number = value as? NSNumber {
                predefinedFields[key] = number
                return true
            }
            if let text = value as? String, let parsed = NumberFormatter().number(from: text) {
                predefinedFields[key] = parsed
                return true
            }
            logW("assignPredefined", "provided byear value can not be parsed as a number, key: [\(key)]")
            return false

        default:
            return false
        }
    }

    // MARK: - Sending

    /// Sends everything staged and clears it.
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
            logD("save", "no consent for user details, save will be skipped")
            return false
        }

        guard hasUnsyncedChanges else {
            logD("save", "no unsynced user details changes, save will be skipped")
            return false
        }

        // Events first: an event recorded before a profile change belongs to the
        // profile as it was.
        core.modules.events.sendEvents()

        if let payload = serializedUserDetails() {
            logD("save", "serialized user details request will be sent, payloadLength: [\(payload.count)]")
            logV("save", "serialized user details payload detail, payload: [\(payload)]")
            sendUserDetails(payload)
        }

        lock.lock()
        let localPath = pictureLocalPath
        // A remote picture URL supersedes a local file, but an explicit clear is
        // not a URL: `setProperties(["picture": NSNull(), "picturePath": path])`
        // means "drop whatever is on the server and upload this file", and reading
        // the key's mere presence would suppress the upload and then discard the
        // staged path along with everything else.
        let hasPictureURL = !(predefinedFields[UserProfileKey.picture] is NSNull)
            && predefinedFields[UserProfileKey.picture] != nil
        lock.unlock()

        // The picture upload is a multipart request of its own, and a remote
        // picture URL supersedes a local file.
        if let localPath, !hasPictureURL {
            logD("save", "local picture path will be sent in a separate request, pathLength: [\(localPath.count)]")
            sendUserDetails(CountlyJSON.escapedString(from: [UserProfileKey.localPicturePath: localPath], logger: log))
        }

        clearUserDetails()
        return true
    }

    private func sendUserDetails(_ payload: String) {
        guard !payload.isEmpty else {
            logE("sendUserDetails", "an empty user details payload will not be sent")
            return
        }
        let queryString = "\(core.network.builder.queryEssentials())&\(QS.userDetails)=\(payload)"
        core.network.enqueueAndProceed(queryString)
    }

    /// Builds the `user_details` payload, or `nil` when nothing is staged.
    private func serializedUserDetails() -> String? {
        lock.lock()
        defer { lock.unlock() }

        var payload: [String: Any] = [:]

        for (key, value) in predefinedFields where key != UserProfileKey.birthYear {
            payload[key] = value
        }

        if let birthYear = predefinedFields[UserProfileKey.birthYear] {
            // A negative year is meaningless; sending null clears the field
            // instead of storing nonsense.
            if let number = birthYear as? NSNumber, number.intValue < 0 {
                payload[UserProfileKey.birthYear] = NSNull()
            } else {
                payload[UserProfileKey.birthYear] = birthYear
            }
        }

        var custom: [String: Any] = [:]
        if !customProperties.isEmpty {
            // Capped by the server's user property limit rather than the
            // segmentation one: they are configured separately and a profile can
            // legitimately carry more properties than an event carries dimensions.
            custom.merge(cappedCustomProperties()) { _, new in new }
        }
        if !customModifications.isEmpty {
            custom.merge(customModifications) { _, new in new }
        }
        if !custom.isEmpty {
            payload[UserProfileKey.custom] = custom
        }

        logD("serializedUserDetails", "user details serialized, fields: [\(payload.keys.sorted())], customPropertyCount: [\(custom.count)]")

        guard !payload.isEmpty else { return nil }

        // `escapedString` answers with an empty string when the object cannot be
        // represented as JSON. Sending that would put `user_details=` on the wire
        // with nothing after it, and `save` would then clear every staged property
        // as if the server had received them. Reporting nothing to send is what
        // keeps the properties staged for the next attempt.
        let escaped = CountlyJSON.escapedString(from: payload, logger: log)
        guard !escaped.isEmpty else {
            logE("serializedUserDetails", "user details could not be serialized and will not be sent, fields: [\(payload.keys.sorted())]")
            return nil
        }
        return escaped
    }

    /// Custom properties trimmed to the server's configured cache limit.
    private func cappedCustomProperties() -> [String: Any] {
        let limit = core.serverConfig.userPropertyCacheLimit
        guard limit > 0, customProperties.count > limit else { return customProperties }

        // Sorted so the same overflowing profile trims the same way twice, rather
        // than dropping whichever keys the dictionary happened to order last.
        let kept = Set(customProperties.keys.sorted().prefix(limit))
        logD("cappedCustomProperties", "custom user properties exceed the server cache limit and will be trimmed, propertyCount: [\(customProperties.count)], limit: [\(limit)]")
        return customProperties.filter { kept.contains($0.key) }
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
        core.modules.events.sendEvents()
    }

    /// Whether the server can store this value: numbers, strings, and lists of
    /// those.
    private func isValidDataType(_ value: Any) -> Bool {
        if let number = value as? NSNumber { return Self.isFinite(number) }
        if value is String { return true }
        if let list = value as? [Any] { return list.allSatisfy(isValidDataType) }
        return false
    }

    /// Whether a number can be represented in JSON.
    ///
    /// `NaN` and the infinities cannot, and one of them anywhere in the profile
    /// makes `JSONSerialization` reject the whole object. The payload would then
    /// serialize to an empty string, the SDK would send `user_details=` with
    /// nothing in it, and the staged properties would be cleared as if they had
    /// been delivered. Rejecting the one bad value at the door costs the caller
    /// that value and nothing else.
    private static func isFinite(_ number: NSNumber) -> Bool {
        // Only the floating point representations can be non-finite; asking an
        // integer for its double value is a conversion, not a check.
        guard CFNumberIsFloatType(number) else { return true }
        return number.doubleValue.isFinite
    }

    // MARK: - Lifecycle

    override func halt(clearStorage: Bool) {
        clearUserDetails()
    }
}
