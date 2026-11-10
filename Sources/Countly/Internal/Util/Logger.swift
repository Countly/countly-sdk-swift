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
/// `[<Level>] [Countly] [<Module>] <function>, <message>` on the console, with a
/// `[<instanceName>]` segment inserted for non-default instances. The listener
/// gets the same line without the level, which it receives on its own.
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

    /// Mirrors `CountlyConfig.enableDebug`.
    var enableDebug: Bool = false

    /// Mirrors `CountlyConfig.disableSDKLoggingInProduction`: console lines are
    /// left out of release builds even with `enableDebug` set.
    var disableInProduction: Bool = false

    /// Whether this build is a release build. The SDK is compiled with the
    /// application's configuration, so `DEBUG` is set exactly in debug builds.
    static let isProductionBuild: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Whether console lines are printed at all.
    var printsToConsole: Bool {
        enableDebug && !(disableInProduction && Self.isProductionBuild)
    }

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
        guard printsToConsole || delegate != nil else { return false }
        return requested.rawValue <= level.rawValue
    }

    /// Whether anything at all wants a line at `level`: a developer facing sink,
    /// or the log gathering capture. This is the predicate a caller consults
    /// before building something expensive to log.
    func isWanted(_ requested: CountlyLogLevel) -> Bool {
        isEnabled(requested) || (gatherer?.isCapturing ?? false)
    }

    // MARK: - Level entry points

    /// Logs at error level. A `scope` overrides whose consent the gathered copy needs.
    func e(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        healthTracker?.logError()
        emit(.error, module, function, scope, message)
    }

    /// Logs at warning level. A `scope` overrides whose consent the gathered copy needs.
    func w(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        healthTracker?.logWarning()
        emit(.warning, module, function, scope, message)
    }

    /// Logs at info level. A `scope` overrides whose consent the gathered copy needs.
    func i(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        emit(.info, module, function, scope, message)
    }

    /// Logs at debug level. A `scope` overrides whose consent the gathered copy needs.
    func d(_ module: String, _ function: String = #function, scope: LogGatheringScope? = nil, _ message: @autoclosure () -> String) {
        emit(.debug, module, function, scope, message)
    }

    /// Logs at verbose level. A `scope` overrides whose consent the gathered copy needs.
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

        if printsToConsole {
            Logger.print("[\(requested.label)] " + Logger.prefix + body)
        }

        delegate?.internalLog(Logger.prefix + body, level: requested)
    }

    /// Console sink, for lines that already carry their level and the `[Countly]`
    /// tag. Kept separate so tests and the crash path can reach it without going
    /// through level resolution.
    static func print(_ text: String) {
        NSLog("%@", text)
    }
}
