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
        Data(utf8).sha256Hex
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

    /// Lowercase hex SHA-256 of the bytes.
    var sha256Hex: String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        return Data(digest).hexString
    }
}

// MARK: - Dispatch

/// Runs `work` on the main thread, immediately when the caller is already there.
///
/// Not an unconditional `DispatchQueue.main.async`: the callers tear down main
/// thread state they own, and deferring that to the next run loop turn when
/// already on the main thread would let the caller return while its timers are
/// still armed and its window is still on screen.
func onMainThread(_ work: @escaping () -> Void) {
    if Thread.isMainThread {
        work()
    } else {
        DispatchQueue.main.async(execute: work)
    }
}

// MARK: - Geometry

extension CGRect {

    /// The frame a content page describes as `{x, y, w, h}` in the container's
    /// coordinate space.
    ///
    /// A dimension the page leaves out falls back to the container's own, so a page
    /// that only pins its origin still covers the space it was given rather than
    /// collapsing to nothing.
    init(contentGeometry: [String: Any], container: CGSize) {
        self.init(x: (contentGeometry["x"] as? NSNumber)?.doubleValue ?? 0,
                  y: (contentGeometry["y"] as? NSNumber)?.doubleValue ?? 0,
                  width: (contentGeometry["w"] as? NSNumber)?.doubleValue ?? Double(container.width),
                  height: (contentGeometry["h"] as? NSNumber)?.doubleValue ?? Double(container.height))
    }
}

// MARK: - Log formatting

/// How a number reads in a log line.
///
/// Interpolated straight into a message a whole number of points prints as
/// `402.0` and a count of nothing prints as `0.0`, so a line reads as though the
/// SDK measured something more precisely than it did. A whole value loses its
/// decimals here.
///
/// Nothing is rounded. A log line is evidence, and a value quietly shortened to
/// look tidy is evidence of something that did not happen: an event's `sum` and a
/// coordinate both go through this. Use `logSeconds` for a duration, which is the
/// one case where the digits past the third are noise rather than data.
extension Double {

    var logValue: String {
        guard isFinite else { return String(self) }

        // Guarded against the range where the conversion would trap. A value that
        // large is not a measurement anyway, and falls through to print in full.
        if self == rounded(), magnitude < 1e15 {
            return String(Int64(self))
        }

        // Swift's own description is the shortest text that reads back as the same
        // value, so this neither pads nor loses anything.
        return String(self)
    }

    /// A measured length of time, to milliseconds.
    ///
    /// A duration comes out of subtracting two clock readings, so it arrives with
    /// as many digits as the double holds and none of them past the third mean
    /// anything.
    var logSeconds: String {
        guard isFinite else { return String(self) }

        var text = String(format: "%.3f", self)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

extension CGFloat {

    var logValue: String { Double(self).logValue }
}

/// Geometry as a log line should carry it.
///
/// A `CGRect` interpolated straight into a message prints as
/// `(0.0, 59.0, 402.0, 815.0)`, which leaves the reader to work out which number
/// is which, and a printed `CGPoint` cannot be told from a printed `CGSize`.
/// Every geometry value in a log line goes through one of these, so a frame
/// reads the same wherever it was printed from.
extension CGPoint {

    var logValue: String { "x=\(x.logValue) y=\(y.logValue)" }
}

extension CGSize {

    var logValue: String { "w=\(width.logValue) h=\(height.logValue)" }
}

extension CGRect {

    var logValue: String { "\(origin.logValue) \(size.logValue)" }
}

/// Resolving a local picture path the host application supplied.
///
/// The documented form is a filesystem path, and integrations also pass a
/// `file://` URL because that is what most iOS APIs hand back. Both have to work,
/// and both have to be resolved the same way everywhere: the SDK checks the file
/// is readable when the property is set and reads it again when the request is
/// built, and if those two disagree the picture silently never uploads.
enum LocalPicturePath {

    /// The file URL for a path or a file URL string, or `nil` when it is neither.
    static func fileURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }

        // A string that already carries a scheme is a URL; anything else is a
        // plain path. `URL(string:)` accepts a plain path and produces a
        // scheme-less URL that nothing can read, so the order matters.
        if let url = URL(string: path), url.scheme != nil {
            return url.isFileURL ? url : nil
        }
        return URL(fileURLWithPath: path)
    }

    /// Whether the file behind this path can actually be read.
    static func isReadable(_ path: String) -> Bool {
        guard let url = fileURL(for: path) else { return false }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    /// The file's bytes, or `nil` when it cannot be read.
    static func data(at path: String) -> Data? {
        guard let url = fileURL(for: path) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The lowercased extension, used to pick the content type.
    static func fileExtension(of path: String) -> String {
        (fileURL(for: path)?.pathExtension ?? (path as NSString).pathExtension).lowercased()
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

// MARK: - Archiving

/// Keyed archives in the shape the Objective-C SDK reads and writes.
///
/// `ArchivedRCData` goes under that SDK's class name. Reading maps the name on each
/// archive rather than for the whole process, since a process can hold that SDK's
/// own class as well. Kept in one place so the stores that archive cannot drift
/// on it.
enum CountlyArchive {

    /// Archives `root` as `NSKeyedArchiver.archivedData(withRootObject:)` does.
    ///
    /// Throws what that archiver throws, a value that cannot be archived included,
    /// so a caller gets an error rather than an exception it cannot catch.
    static func encodeRoot(_ root: Any) throws -> Data {
        _ = archivesRCDataUnderItsObjectiveCName
        return try NSKeyedArchiver.archivedData(withRootObject: root, requiringSecureCoding: false)
    }

    /// Names `ArchivedRCData` after the Objective-C SDK's class in every archive this
    /// process writes, once. The process-wide table maps this SDK's own class only.
    private static let archivesRCDataUnderItsObjectiveCName: Void = {
        NSKeyedArchiver.setClassName(ArchivedRCData.archivedClassName, for: ArchivedRCData.self)
    }()

    /// Reads back the root object of a keyed archive the SDK wrote.
    ///
    /// Secure coding is switched off deliberately: the archives hold plain
    /// property list values written by this SDK into its own storage, and the
    /// decoder cannot be given a class list for `Any`.
    ///
    /// Throws whatever `NSKeyedUnarchiver` throws, so each caller reports a
    /// corrupt store in its own terms.
    static func decodeRoot(from data: Data) throws -> Any? {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = false
        unarchiver.setClass(ArchivedRCData.self, forClassName: ArchivedRCData.archivedClassName)
        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        return root
    }
}

// MARK: - Segmentation sanitation

/// Applies the SDK internal limits to keys, values and segmentation dictionaries.
///
/// Held per instance because the limits themselves are per instance.
struct LimitsEnforcer {

    let limits: CountlySDKLimitsConfig
    weak var logger: Logger?

    /// Whose consent what this enforcer logs needs when gathered. A value it cut
    /// belongs to the feature that handed it over, and is often logged before
    /// that feature checks its own consent.
    private(set) var scope: LogGatheringScope = .unattributed

    private static let module = "Limits"

    /// This enforcer, with what it logs gathered under `scope`.
    func gathered(as scope: LogGatheringScope) -> LimitsEnforcer {
        var copy = self
        copy.scope = scope
        return copy
    }

    /// Truncates a key to the configured maximum key length.
    func truncatedKey(_ key: String, _ explanation: String) -> String {
        guard key.countlyLength > limits.maxKeyLength else { return key }
        logger?.d(Self.module, "truncatedKey", scope: scope, "key exceeds the SDK key length limit and will be truncated, target: [\(explanation)], key: [\(key)], keyLength: [\(key.countlyLength)], truncatedTo: [\(limits.maxKeyLength)]")
        return key.countlyPrefix(limits.maxKeyLength)
    }

    /// Truncates a value to the configured maximum value length.
    func truncatedValue(_ value: String, _ explanation: String) -> String {
        guard value.countlyLength > limits.maxValueSize else { return value }
        logger?.d(Self.module, "truncatedValue", scope: scope, "value exceeds the SDK value length limit and will be truncated, target: [\(explanation)], valueLength: [\(value.countlyLength)], truncatedTo: [\(limits.maxValueSize)]")
        logger?.v(Self.module, "truncatedValue", scope: scope, "truncated value detail, target: [\(explanation)], fullValue: [\(value)]")
        return value.countlyPrefix(limits.maxValueSize)
    }

    /// Truncates every frame of a stack trace to `maxStackTraceLineLength`.
    ///
    /// The frame count is deliberately not capped. Android applies
    /// `maxStackTraceLinesPerThread` only to the supplementary other-threads dump,
    /// never to the exception's own trace, and this SDK records no such dump. The
    /// crash filters read the trace after this runs, so capping it would silently
    /// stop a filter written against a deep frame from matching.
    func truncatedStackTrace(_ frames: [String], _ explanation: String) -> [String] {
        let lineLimit = max(1, limits.maxStackTraceLineLength)

        return frames.map { line in
            guard line.countlyLength > lineLimit else { return line }
            logger?.d(Self.module, "truncatedStackTrace", scope: scope, "stack trace line exceeds the SDK stack trace line length limit and will be truncated, target: [\(explanation)], lineLength: [\(line.countlyLength)], truncatedTo: [\(lineLimit)]")
            return line.countlyPrefix(lineLimit)
        }
    }

    /// Truncates a user profile picture URL, which has its own larger limit.
    func truncatedPictureValue(_ value: String, _ explanation: String) -> String {
        guard value.countlyLength > limits.maxValueSizePicture else { return value }
        logger?.d(Self.module, "truncatedPictureValue", scope: scope, "value exceeds the SDK picture value limit and will be truncated, target: [\(explanation)], valueLength: [\(value.countlyLength)], truncatedTo: [\(limits.maxValueSizePicture)]")
        logger?.v(Self.module, "truncatedPictureValue", scope: scope, "truncated picture value detail, target: [\(explanation)], fullValue: [\(value)]")
        return value.countlyPrefix(limits.maxValueSizePicture)
    }

    /// Truncates every key, and every string value, of a segmentation dictionary.
    ///
    /// Walked in sorted key order rather than the dictionary's own order, because
    /// two keys can truncate to the same string and only one value can survive.
    /// Swift seeds its hashing per process, so an unordered walk would pick a
    /// different survivor on every launch and send a different value each time.
    /// Sorted, the later key wins, and it wins the same way on every run.
    func truncated(_ dictionary: [String: Any], _ explanation: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
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
    ///
    /// Sorted for the same reason the truncation walk is: which keys survive the
    /// cut has to be the same on every run, and a dictionary's own order is not.
    func limited(_ dictionary: [String: Any], _ explanation: String) -> [String: Any] {
        let keys = dictionary.keys.sorted()
        guard keys.count > limits.maxSegmentationValues else { return dictionary }

        let kept = Set(keys.prefix(limits.maxSegmentationValues))
        let dropped = keys.filter { !kept.contains($0) }
        logger?.d(Self.module, "limited", scope: scope, "segmentation exceeds the SDK segmentation value limit and will be trimmed, target: [\(explanation)], keyCount: [\(keys.count)], trimmedTo: [\(limits.maxSegmentationValues)], droppedKeyCount: [\(dropped.count)], droppedKeys: [\(dropped)]")

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
    ///
    /// Dates are converted rather than dropped, because the server reads a date
    /// as epoch milliseconds and dropping one loses data the caller clearly meant
    /// to send.
    ///
    /// Reachable from the crash signal handler, so the drop is reported at debug.
    /// Warning level would re-enter the health tracker, whose dispatch primitives
    /// are not async-signal-safe.
    func filterSupportedDataTypes(_ dictionary: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dictionary {
            if let converted = supportedValue(value) {
                result[key] = converted
            } else if let array = value as? [Any] {
                result[key] = filterSupportedDataTypes(array)
            } else if value is Date {
                logger?.d(Self.module, "filterSupportedDataTypes", scope: scope, "dropping dictionary entry with a date that has no representable epoch value, key: [\(key)]")
            } else if value is NSNumber {
                logger?.d(Self.module, "filterSupportedDataTypes", scope: scope, "dropping dictionary entry with a number JSON cannot represent, key: [\(key)]")
            } else {
                logger?.d(Self.module, "filterSupportedDataTypes", scope: scope, "dropping dictionary entry with an unsupported value type, key: [\(key)], receivedType: [\(type(of: value))]")
            }
        }
        return result
    }

    /// Array counterpart of `filterSupportedDataTypes`.
    func filterSupportedDataTypes(_ array: [Any]) -> [Any] {
        array.compactMap { element in
            if let converted = supportedValue(element) { return converted }
            logger?.d(Self.module, "filterSupportedDataTypes", scope: scope, "dropping array element with an unsupported type, only numbers, strings and dates are allowed, receivedType: [\(type(of: element))]")
            return nil
        }
    }

    /// One scalar as the server stores it, or `nil` when it cannot be stored.
    ///
    /// The single place that decides what a segmentation scalar may be, so the
    /// dictionary walk and the array walk cannot drift apart on it.
    func supportedValue(_ value: Any) -> Any? {
        if let number = value as? NSNumber { return Self.isFinite(number) ? number : nil }
        if value is String { return value }
        if let date = value as? Date { return Self.epochMilliseconds(date) }
        return nil
    }

    /// Whether a number can be represented in JSON.
    ///
    /// `NaN` and the infinities cannot, and one of them anywhere in an object
    /// makes `JSONSerialization` reject the whole thing: a single bad segmentation
    /// value would cost every event in its batch, or a whole crash report.
    /// Refusing the one value at the door costs the caller that value alone.
    static func isFinite(_ number: NSNumber) -> Bool {
        // Only the floating point representations can be non-finite; asking an
        // integer for its double value is a conversion, not a check.
        guard CFNumberIsFloatType(number) else { return true }
        return number.doubleValue.isFinite
    }

    /// A date as the epoch milliseconds the server reads, or `nil` when it does
    /// not fit one.
    ///
    /// `Date.distantPast` and `Date.distantFuture` both fit; a date built from a
    /// non-finite interval does not, and converting one would trap.
    static func epochMilliseconds(_ date: Date) -> Int64? {
        // `Int64(exactly:)` rather than a pair of comparisons: `Double(Int64.max)`
        // rounds up to 2^63, so `<= Double(Int64.max)` admits a value one ulp
        // past the range and the conversion traps on it.
        return Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
    }
}
