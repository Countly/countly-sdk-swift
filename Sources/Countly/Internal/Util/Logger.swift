//
//  Logger.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Per-instance logger.
///
/// Every `CountlyInstance` owns one. Nothing is process global, so two instances
/// can run at different log levels and a log line always says which instance
/// produced it.
///
/// Format follows the cross-SDK spec:
/// `[Countly] [<Level>] [<Module>] <function>, <message>`, with a
/// `[<instanceName>]` segment inserted for non-default instances.
///
/// Messages are passed as autoclosures, so an argument that serializes JSON or
/// builds a description costs nothing when its level is inactive. That holds at
/// every level including error and warning, which the Objective-C SDK could not
/// do because its error/warning macros had to call through unconditionally to
/// keep the health counters ticking. Here the counters are bumped first and the
/// message is only then materialized.
final class Logger {

    /// Prefix every line carries, so host applications can filter SDK output.
    static let prefix = "[Countly] "

    /// Mirrors `CountlyConfig.enableDebug`. Server behavior settings may turn
    /// this on for an app that did not ask for it.
    var enableDebug: Bool = false

    /// Lines above this level are dropped.
    var level: CountlyLogLevel = .debug

    /// Held weakly: the host application owns its delegate. The delegate path is
    /// live in release builds, unlike console output.
    weak var delegate: CountlyLoggerDelegate?

    /// Bumped on every error and warning regardless of whether logging is on,
    /// because those counters are wire data (`el` / `wl` in the health check).
    weak var healthTracker: HealthTracker?

    /// Empty for the default instance, the instance name otherwise.
    private let instanceTag: String

    init(instanceName: String?) {
        if let name = instanceName, !name.isEmpty {
            instanceTag = "[\(name)] "
        } else {
            instanceTag = ""
        }
    }

    /// Whether a line at `level` would be emitted anywhere.
    func isEnabled(_ requested: CountlyLogLevel) -> Bool {
        guard enableDebug || delegate != nil else { return false }
        return requested.rawValue <= level.rawValue
    }

    // MARK: - Level entry points

    func e(_ module: String, _ function: String = #function, _ message: @autoclosure () -> String) {
        healthTracker?.logError()
        emit(.error, module, function, message)
    }

    func w(_ module: String, _ function: String = #function, _ message: @autoclosure () -> String) {
        healthTracker?.logWarning()
        emit(.warning, module, function, message)
    }

    func i(_ module: String, _ function: String = #function, _ message: @autoclosure () -> String) {
        emit(.info, module, function, message)
    }

    func d(_ module: String, _ function: String = #function, _ message: @autoclosure () -> String) {
        emit(.debug, module, function, message)
    }

    func v(_ module: String, _ function: String = #function, _ message: @autoclosure () -> String) {
        emit(.verbose, module, function, message)
    }

    // MARK: - Emission

    private func emit(_ requested: CountlyLogLevel,
                      _ module: String,
                      _ function: String,
                      _ message: () -> String) {
        guard isEnabled(requested) else { return }

        let line = "[\(requested.label)] \(instanceTag)[\(module)] \(function), \(message())"

        // Runtime gated only. A `#if DEBUG` here would compile the console sink out
        // of every release build of the SDK, so a developer who set `enableDebug`
        // in a TestFlight build to chase a problem would get silence, and the flag
        // would quietly mean something different depending on how the SDK was
        // built. The reference gates this at runtime too.
        if enableDebug {
            Logger.print(line)
        }

        delegate?.internalLog(Logger.prefix + line, level: requested)
    }

    /// Console sink. Kept separate so tests and the crash path can reach it
    /// without going through level resolution.
    static func print(_ text: String) {
        NSLog("%@%@", prefix, text)
    }
}
