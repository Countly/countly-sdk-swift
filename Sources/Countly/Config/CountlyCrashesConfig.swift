//
//  CountlyCrashesConfig.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Called before a crash report is queued.
///
/// Return `true` to drop the report. The callback may also mutate the report in
/// place, in which case the SDK reports which fields it changed.
public typealias CrashFilterCallback = (_ crash: CountlyCrashData) -> Bool

/// Crash reporting settings.
public final class CountlyCrashesConfig {

    /// Inspects, edits or drops each crash report before it is queued.
    public var crashFilterCallback: CrashFilterCallback?

    public init() {}
}
