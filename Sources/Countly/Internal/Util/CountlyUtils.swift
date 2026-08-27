//
//  CountlyUtils.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import CommonCrypto

// MARK: - String

extension String {

    /// RFC 3986 unreserved characters, the only ones left unescaped in a query
    /// parameter. Held as a constant because building it costs an allocation and
    /// the SDK escapes several values per request.
    private static let urlAllowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    /// Percent-encoding used for every query parameter the SDK sends.
    ///
    /// Anything outside the unreserved set, including `+`, `&`, `=` and `/`, is
    /// escaped, so a value can never break out of its query parameter.
    var urlEscaped: String {
        addingPercentEncoding(withAllowedCharacters: String.urlAllowedCharacters) ?? self
    }

    /// Lowercase hex SHA-256 of the UTF-8 bytes, used for request checksums.
    var sha256Hex: String {
        let data = Data(utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return Data(digest).hexString
    }

    /// How old a queued request is, from the timestamp it carries.
    ///
    /// A request with no readable timestamp reads as infinitely old, so the age
    /// based drop treats it as stale rather than keeping it forever.
    var requestAgeSeconds: TimeInterval {
        let millis = Double(valueForQueryStringKey(QS.timestamp) ?? "") ?? 0
        return Date().timeIntervalSince1970 - millis / 1000.0
    }

    /// Reads one parameter out of a query string fragment such as
    /// `app_key=x&device_id=y`. Returns `nil` when the key is absent.
    func valueForQueryStringKey(_ key: String) -> String? {
        guard let components = URLComponents(string: "http://example.com/path?" + self) else { return nil }
        return components.queryItems?.first(where: { $0.name == key })?.value
    }

    /// Number of UTF-16 code units, which is what the SDK limits count.
    var countlyLength: Int { utf16.count }

    /// Truncates to `limit` UTF-16 code units, matching the length metric used
    /// by the limit checks. Never splits the string mid-scalar.
    func countlyPrefix(_ limit: Int) -> String {
        guard utf16.count > limit else { return self }
        guard limit > 0 else { return "" }

        let utf16View = utf16
        var cut = limit

        // The cut can land inside a surrogate pair, which has no String.Index.
        // Walk back to the nearest boundary rather than forward: a limit is a
        // ceiling, and overshooting it would let an over-length value through.
        while cut > 0 {
            if let end = utf16View.index(utf16View.startIndex, offsetBy: cut, limitedBy: utf16View.endIndex),
               let boundary = String.Index(end, within: self) {
                return String(self[startIndex..<boundary])
            }
            cut -= 1
        }

        return ""
    }
}

extension Data {

    /// Lowercase hex, used for digests and for the APNs device token.
    ///
    /// Table driven rather than `String(format:)` per byte: a SHA-256 digest is
    /// 32 bytes and crash reports produce several digests each.
    var hexString: String {
        let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
        var characters = [UInt8]()
        characters.reserveCapacity(count * 2)
        for byte in self {
            characters.append(alphabet[Int(byte >> 4)])
            characters.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}

// MARK: - JSON

enum CountlyJSON {

    /// Serializes to a compact JSON string, or `nil` when the value cannot be
    /// represented. The caller decides whether a `nil` means "skip" or "error".
    static func string(from object: Any?, logger: Logger?) -> String? {
        guard let object else { return nil }

        guard JSONSerialization.isValidJSONObject(object) else {
            logger?.e("Utils", "jsonString", "object can not be represented as JSON and will be dropped, objectType: [\(type(of: object))]")
            return nil
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return String(data: data, encoding: .utf8)
        } catch {
            logger?.e("Utils", "jsonString", "JSON serialization failed and the data will be lost, objectType: [\(type(of: object))], error: [\(error.localizedDescription)]")
            return nil
        }
    }

    /// Serializes and percent-encodes in one step, the form every query
    /// parameter carrying JSON uses.
    static func escapedString(from object: Any?, logger: Logger?) -> String {
        string(from: object, logger: logger)?.urlEscaped ?? ""
    }

    /// Parses a JSON object out of raw response bytes.
    static func object(from data: Data?, logger: Logger?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            logger?.d("Utils", "jsonObject", "response could not be parsed as JSON, error: [\(error.localizedDescription)]")
            return nil
        }
    }
}

// MARK: - Segmentation sanitation

/// Applies the SDK internal limits to keys, values and segmentation dictionaries.
///
/// Held per instance because the limits themselves are per instance.
struct LimitsEnforcer {

    let limits: CountlySDKLimitsConfig
    weak var logger: Logger?

    private static let module = "Limits"

    /// Truncates a key to the configured maximum key length.
    func truncatedKey(_ key: String, _ explanation: String) -> String {
        guard key.countlyLength > limits.maxKeyLength else { return key }
        logger?.d(Self.module, "truncatedKey", "key exceeds the SDK key length limit and will be truncated, target: [\(explanation)], key: [\(key)], keyLength: [\(key.countlyLength)], truncatedTo: [\(limits.maxKeyLength)]")
        return key.countlyPrefix(limits.maxKeyLength)
    }

    /// Truncates a value to the configured maximum value length.
    func truncatedValue(_ value: String, _ explanation: String) -> String {
        guard value.countlyLength > limits.maxValueSize else { return value }
        logger?.d(Self.module, "truncatedValue", "value exceeds the SDK value length limit and will be truncated, target: [\(explanation)], valueLength: [\(value.countlyLength)], truncatedTo: [\(limits.maxValueSize)]")
        logger?.v(Self.module, "truncatedValue", "truncated value detail, target: [\(explanation)], fullValue: [\(value)]")
        return value.countlyPrefix(limits.maxValueSize)
    }

    /// Truncates a user profile picture URL, which has its own larger limit.
    func truncatedPictureValue(_ value: String, _ explanation: String) -> String {
        guard value.countlyLength > limits.maxValueSizePicture else { return value }
        logger?.d(Self.module, "truncatedPictureValue", "value exceeds the SDK picture value limit and will be truncated, target: [\(explanation)], valueLength: [\(value.countlyLength)], truncatedTo: [\(limits.maxValueSizePicture)]")
        logger?.v(Self.module, "truncatedPictureValue", "truncated picture value detail, target: [\(explanation)], fullValue: [\(value)]")
        return value.countlyPrefix(limits.maxValueSizePicture)
    }

    /// Truncates every key, and every string value, of a segmentation dictionary.
    func truncated(_ dictionary: [String: Any], _ explanation: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            let newKey = truncatedKey(key, explanation + " key")
            if let stringValue = value as? String {
                result[newKey] = truncatedValue(stringValue, explanation + " value")
            } else {
                result[newKey] = value
            }
        }
        return result
    }

    /// Drops entries past the configured maximum segmentation count.
    func limited(_ dictionary: [String: Any], _ explanation: String) -> [String: Any] {
        let keys = Array(dictionary.keys)
        guard keys.count > limits.maxSegmentationValues else { return dictionary }

        let kept = Set(keys.prefix(limits.maxSegmentationValues))
        let dropped = keys.filter { !kept.contains($0) }
        logger?.d(Self.module, "limited", "segmentation exceeds the SDK segmentation value limit and will be trimmed, target: [\(explanation)], keyCount: [\(keys.count)], trimmedTo: [\(limits.maxSegmentationValues)], droppedKeyCount: [\(dropped.count)], droppedKeys: [\(dropped)]")

        return dictionary.filter { kept.contains($0.key) }
    }

    /// Truncates then trims, in that order.
    ///
    /// The order matters: trimming first would decide which keys survive using
    /// untruncated keys, so two keys that truncate to the same string could both
    /// be kept and then collide.
    func truncatedAndLimited(_ dictionary: [String: Any], _ explanation: String) -> [String: Any] {
        limited(truncated(dictionary, explanation), explanation)
    }

    /// Drops unsupported value types, then truncates and trims. The full
    /// treatment every public entry point applies.
    func sanitized(_ dictionary: [String: Any]?, _ explanation: String) -> [String: Any]? {
        guard let dictionary else { return nil }
        return truncatedAndLimited(filterSupportedDataTypes(dictionary), explanation)
    }

    /// Keeps only the value types the server accepts: numbers, strings, booleans,
    /// and arrays of those. Anything else is dropped with a log line rather than
    /// failing the whole call.
    func filterSupportedDataTypes(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            if value is NSNumber || value is String {
                result[key] = value
            } else if let array = value as? [Any] {
                result[key] = filterSupportedDataTypes(array)
            } else {
                logger?.d(Self.module, "filterSupportedDataTypes", "dropping dictionary entry with an unsupported value type, key: [\(key)], receivedType: [\(type(of: value))]")
            }
        }
        return result
    }

    /// Array counterpart of `filterSupportedDataTypes`.
    func filterSupportedDataTypes(_ array: [Any]) -> [Any] {
        array.filter { element in
            if element is NSNumber || element is String { return true }
            logger?.d(Self.module, "filterSupportedDataTypes", "dropping array element with an unsupported type, only numbers and strings are allowed, receivedType: [\(type(of: element))]")
            return false
        }
    }
}
