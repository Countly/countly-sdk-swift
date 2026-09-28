//
//  CountlyRCData.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// A remote config value plus whether it belongs to the current user.
///
/// After a device ID change without merge the cached values still exist but no
/// longer describe the new user. `isCurrentUsersData` is `false` until a fresh
/// download replaces them, which lets the host application decide whether to use
/// a stale value or wait.
public final class CountlyRCData {

    /// The value as the server sent it: a string, number, boolean, array or
    /// dictionary. `nil` when the key is not known.
    public let value: Any?

    /// `false` when the value was downloaded for a different user than the
    /// current one.
    public let isCurrentUsersData: Bool

    public init(value: Any?, isCurrentUsersData: Bool) {
        self.value = value
        self.isCurrentUsersData = isCurrentUsersData
    }
}

/// One cached remote config value as it is archived: exactly as the Objective-C
/// Countly SDK archives its `CountlyRCData`, under the same class name and keys.
///
/// Both SDKs read and write the same user defaults key, so the shape is shared.
/// An application moving from that SDK keeps its cached values, and one going
/// back to it finds them again. An archive naming a class the running process
/// does not have decodes to nothing, and the Objective-C SDK takes any entry that
/// is not its own class for one, which ends in an unrecognized selector crash.
/// `CountlyArchive` applies the class name.
final class ArchivedRCData: NSObject, NSCoding {

    /// The class name archives carry, the Objective-C SDK's own.
    static let archivedClassName = "CountlyRCData"

    let value: Any?
    let isCurrentUsersData: Bool

    init(value: Any?, isCurrentUsersData: Bool) {
        self.value = value
        self.isCurrentUsersData = isCurrentUsersData
        super.init()
    }

    init?(coder: NSCoder) {
        // The key names are the selector names the reference encoded under.
        value = coder.decodeObject(forKey: "value")
        isCurrentUsersData = coder.decodeBool(forKey: "isCurrentUsersData")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(value, forKey: "value")
        coder.encode(isCurrentUsersData, forKey: "isCurrentUsersData")
    }
}

/// One A/B experiment and the variant this device is in.
public final class CountlyExperimentInformation {

    public let experimentID: String
    public let experimentName: String
    public let experimentDescription: String
    public let currentVariant: String
    public let variants: [String: Any]

    public init(experimentID: String,
                experimentName: String,
                experimentDescription: String,
                currentVariant: String,
                variants: [String: Any]) {
        self.experimentID = experimentID
        self.experimentName = experimentName
        self.experimentDescription = experimentDescription
        self.currentVariant = currentVariant
        self.variants = variants
    }
}

/// Called after a remote config download.
///
/// - Parameters:
///   - result: Whether the download reached the server and was usable.
///   - error: Populated when `result` is not `.success`.
///   - fullValueUpdate: `true` when every key was refreshed, `false` for a
///     partial download of specific or omitted keys.
///   - downloadedValues: The values this download produced.
/// Handle to one registered remote config download callback.
///
/// Returned by `registerDownloadCallback` and passed back to
/// `removeDownloadCallback`. A Swift closure cannot be compared for identity, so
/// the reference SDKs' "hand the same function back" form has no equivalent here;
/// this is the identity instead. Opaque on purpose: nothing outside the SDK has a
/// reason to construct or inspect one.
public struct RCCallbackToken: Hashable, Sendable {
    let value: UInt64
}

public typealias RCDownloadCallback = (_ result: RequestResult,
                                       _ error: Error?,
                                       _ fullValueUpdate: Bool,
                                       _ downloadedValues: [String: CountlyRCData]) -> Void

/// Called after an A/B variant operation.
public typealias RCVariantCallback = (_ result: RequestResult, _ error: Error?) -> Void
