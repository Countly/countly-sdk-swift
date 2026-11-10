//
//  CountlySDKLimitsConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Caps the SDK applies to anything the host application passes in.
///
/// The defaults are the cross-SDK values. Raising a limit means larger requests
/// and more server-side storage per data point, so the server may still reject or
/// trim what it receives.
@objcMembers
public final class CountlySDKLimitsConfig: NSObject {

    /// Maximum length of any key: event names, segmentation keys, user property
    /// names, view names, trace names. Default 128.
    public var maxKeyLength: Int = DefaultLimits.maxKeyLength

    /// Maximum length of any string value. Default 256.
    public var maxValueSize: Int = DefaultLimits.maxValueSize

    /// Maximum length of a user profile picture URL, which is allowed to be
    /// longer than an ordinary value. Default 4096.
    public var maxValueSizePicture: Int = DefaultLimits.maxValueSizePicture

    /// Maximum number of crash breadcrumbs retained. Default 100.
    public var maxBreadcrumbCount: Int = DefaultLimits.maxBreadcrumbCount

    /// Maximum number of entries in one segmentation dictionary. Default 100.
    public var maxSegmentationValues: Int = DefaultLimits.maxSegmentationValues

    /// Maximum length of a single stack trace line. Default 200.
    public var maxStackTraceLineLength: Int = DefaultLimits.maxStackTraceLineLength

    /// Maximum number of stack trace lines kept per thread. Default 30.
    public var maxStackTraceLinesPerThread: Int = DefaultLimits.maxStackTraceLinesPerThread

    public override init() {}

    /// Takes every value of `other`, for the snapshot an instance runs on.
    func copyValues(from other: CountlySDKLimitsConfig) {
        maxKeyLength = other.maxKeyLength
        maxValueSize = other.maxValueSize
        maxValueSizePicture = other.maxValueSizePicture
        maxBreadcrumbCount = other.maxBreadcrumbCount
        maxSegmentationValues = other.maxSegmentationValues
        maxStackTraceLineLength = other.maxStackTraceLineLength
        maxStackTraceLinesPerThread = other.maxStackTraceLinesPerThread
    }

    /// Puts the default back for every limit below one, in place, and reports
    /// each with its name, the refused value and the default.
    ///
    /// A zero or negative limit would silently discard all data, so it is ignored
    /// rather than used, and never raised to one.
    func resetInvalidValues(_ reject: (String, Int, Int) -> Void) {
        let checks: [(String, ReferenceWritableKeyPath<CountlySDKLimitsConfig, Int>, Int)] = [
            ("maxKeyLength", \.maxKeyLength, DefaultLimits.maxKeyLength),
            ("maxValueSize", \.maxValueSize, DefaultLimits.maxValueSize),
            ("maxValueSizePicture", \.maxValueSizePicture, DefaultLimits.maxValueSizePicture),
            ("maxBreadcrumbCount", \.maxBreadcrumbCount, DefaultLimits.maxBreadcrumbCount),
            ("maxSegmentationValues", \.maxSegmentationValues, DefaultLimits.maxSegmentationValues),
            ("maxStackTraceLineLength", \.maxStackTraceLineLength, DefaultLimits.maxStackTraceLineLength),
            ("maxStackTraceLinesPerThread", \.maxStackTraceLinesPerThread, DefaultLimits.maxStackTraceLinesPerThread),
        ]
        for (name, keyPath, fallback) in checks where self[keyPath: keyPath] < 1 {
            reject(name, self[keyPath: keyPath], fallback)
            self[keyPath: keyPath] = fallback
        }
    }
}
