//
//  CountlyCrashData.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// A crash or handled error, as handed to the crash filter callback.
///
/// The callback may mutate any field. The SDK records which fields were changed
/// and reports that as a bitfield so the server can tell a filtered report from
/// an untouched one.
@objcMembers
public final class CountlyCrashData: NSObject {

    public var stackTrace: String
    public var name: String
    public var crashDescription: String
    public var fatal: Bool
    public var breadcrumbs: [String]
    public var crashSegmentation: [String: Any]
    public var crashMetrics: [String: Any]

    /// Field checksums taken at construction, compared again after the host
    /// application's filter callback has run.
    private var checksums: [String]

    /// Per-field changed flags, in the same order as `checksums`.
    private(set) var changedFields: [Bool] = []

    /// Whether the field checksums are being kept, which is only worth doing when
    /// something can actually change the fields.
    private let tracksChanges: Bool

    init(stackTrace: String,
         name: String,
         crashDescription: String,
         crashSegmentation: [String: Any],
         breadcrumbs: [String],
         crashMetrics: [String: Any],
         fatal: Bool,
         trackChanges: Bool = true) {
        self.stackTrace = stackTrace
        self.name = name
        self.crashDescription = crashDescription
        self.crashSegmentation = crashSegmentation
        self.breadcrumbs = breadcrumbs
        self.crashMetrics = crashMetrics
        self.fatal = fatal
        self.tracksChanges = trackChanges
        self.checksums = []
        super.init()
        if trackChanges {
            self.checksums = currentChecksums()
        }
    }

    /// Breadcrumbs joined with newlines, the form the server expects.
    public var breadcrumbsAsString: String {
        breadcrumbs.map { $0 + "\n" }.joined()
    }

    /// Recomputes the checksums and records which fields differ from the values
    /// captured at construction.
    func calculateChangedFields() {
        guard tracksChanges else {
            changedFields = []
            return
        }
        changedFields = zip(checksums, currentChecksums()).map { $0 != $1 }
    }

    /// The changed-field flags packed into an integer, most significant bit
    /// first, which is what the `_ob` crash field carries.
    var changedFieldsBitfield: Int {
        var result = 0
        let count = changedFields.count
        for index in stride(from: count - 1, through: 0, by: -1) where changedFields[index] {
            result |= (1 << (count - 1 - index))
        }
        return result
    }

    /// Order matters: it defines the bit positions of the changed-field bitfield,
    /// description 64, name 32, stack trace 16, segmentation 8, breadcrumbs 4,
    /// metrics 2 and fatal 1.
    private func currentChecksums() -> [String] {
        [
            crashDescription.sha256Hex,
            name.sha256Hex,
            stackTrace.sha256Hex,
            Self.stableDescription(crashSegmentation).sha256Hex,
            Self.stableDescription(breadcrumbs).sha256Hex,
            Self.stableDescription(crashMetrics).sha256Hex,
            (fatal ? "true" : "false").sha256Hex,
        ]
    }

    /// Order-independent rendering of a collection.
    ///
    /// Only equality before and after the filter callback matters, so this needs
    /// to be stable across two readings of the same content rather than match any
    /// particular format.
    private static func stableDescription(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return "{" + dictionary.keys.sorted().map { "\($0)=\(stableDescription(dictionary[$0] as Any))" }.joined(separator: ",") + "}"
        }
        if let array = value as? [Any] {
            return "[" + array.map { stableDescription($0) }.joined(separator: ",") + "]"
        }
        return String(describing: value)
    }
}
