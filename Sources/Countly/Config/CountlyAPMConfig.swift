//
//  CountlyAPMConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Application performance monitoring settings.
@objcMembers
public final class CountlyAPMConfig: NSObject {

    /// Reports how long the application spends in the foreground and in the
    /// background as APM traces.
    public var enableForegroundBackgroundTracking: Bool = false

    /// Reports the time from process start to the first foreground as an app
    /// start trace.
    public var enableAppStartTimeTracking: Bool = false

    /// Defers the app start trace until the host application calls
    /// `appLoadingFinished()`, instead of ending it at the first foreground.
    public var enableManualAppLoadedTrigger: Bool = false

    /// Overrides the process start timestamp used for the app start trace, in
    /// milliseconds since the epoch. Useful when the host application knows its
    /// real launch moment better than the SDK does. Zero means no override.
    public var appStartTimestampOverride: Int64 = 0

    public override init() {}
}
