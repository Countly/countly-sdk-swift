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

    /// Gathers lines for the server when a live behavior settings response asks
    /// for them. Weak: the core owns both. Capture sits above the console and
    /// delegate gates, so an operator can read the log of a build that has
    /// debugging off.
    weak var gatherer: LogGatherer?

    /// Empty for the default instance, the instance name otherwise.
    private let instanceTag: String

    init(instanceName: String?) {
        if let name = instanceName, !name.isEmpty {
            instanceTag = "[\(name)] "
        } else {
            instanceTag = ""
        }
    }

    /// Whether a line at `level` reaches the console or the delegate. Capture is
    /// not part of this, so it keeps its developer facing meaning.
    func isEnabled(_ requested: CountlyLogLevel) -> Bool {
        guard enableDebug || delegate != nil else { return false }
        return requested.rawValue <= level.rawValue
    }

    /// Whether anything at all wants a line at `level`: a developer facing sink,
    /// or the log gathering capture. This is the predicate a caller consults
    /// before building something expensive to log.
    func isWanted(_ requested: CountlyLogLevel) -> Bool {
        isEnabled(requested) || (gatherer?.isCapturing ?? false)
    }

    // MARK: - Level entry points

    func e(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        healthTracker?.logError()
        emit(.error, module, function, scope, message)
    }

    func w(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        healthTracker?.logWarning()
        emit(.warning, module, function, scope, message)
    }

    func i(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        emit(.info, module, function, scope, message)
    }

    func d(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        emit(.debug, module, function, scope, message)
    }

    func v(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        emit(.verbose, module, function, scope, message)
    }

    // MARK: - Emission

    private func emit(_ requested: CountlyLogLevel,
                      _ module: String,
                      _ function: String,
                      _ scope: LogGatheringScope?,
                      _ message: () -> String) {
        let wantsConsole = isEnabled(requested)
        let wantsCapture = gatherer?.isCapturing ?? false
        guard wantsConsole || wantsCapture else { return }

        let body = "\(instanceTag)[\(module)] \(function), \(message())"

        // Captured before the level prefix is added: a gathered line carries its
        // level in its own field and the dashboard renders it from there.
        if wantsCapture {
            gatherer?.capture(body, level: requested, scope: scope ?? LogGatheringScope.of(module: module, function: function, message: body))
        }

        guard wantsConsole else { return }

        let line = "[\(requested.label)] " + body

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
