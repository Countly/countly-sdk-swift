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
public final class CountlySDKLimitsConfig {

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

    public init() {}

    /// Raises every limit below one back to its default, in place.
    ///
    /// A zero or negative limit would silently discard all data, which is a worse
    /// outcome than ignoring the misconfiguration.
    func clampToMinimums() {
        func clamp(_ value: Int, _ fallback: Int) -> Int {
            value < 1 ? fallback : value
        }

        maxKeyLength = clamp(maxKeyLength, DefaultLimits.maxKeyLength)
        maxValueSize = clamp(maxValueSize, DefaultLimits.maxValueSize)
        maxValueSizePicture = clamp(maxValueSizePicture, DefaultLimits.maxValueSizePicture)
        maxBreadcrumbCount = clamp(maxBreadcrumbCount, DefaultLimits.maxBreadcrumbCount)
        maxSegmentationValues = clamp(maxSegmentationValues, DefaultLimits.maxSegmentationValues)
        maxStackTraceLineLength = clamp(maxStackTraceLineLength, DefaultLimits.maxStackTraceLineLength)
        maxStackTraceLinesPerThread = clamp(maxStackTraceLinesPerThread, DefaultLimits.maxStackTraceLinesPerThread)
    }
}
