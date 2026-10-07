//
//  CountlyExperimentalConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Features that are still being shaped and may change without a major version.
@objcMembers
public final class CountlyExperimentalConfig: NSObject {

    /// Adds `previous_view_name` to view segmentation and `previous_event_name`
    /// to event segmentation.
    public var enablePreviousNameRecording: Bool = false

    /// Adds a `cly_v` segmentation key recording whether the application was in
    /// the foreground when the data point was recorded.
    public var enableVisibilityTracking: Bool = false

    public override init() {}
}
