//
//  CrashHandlerInstaller.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation
import Darwin

/// Owns the process-wide crash handlers and fans crashes out to every instance
/// that asked for them.
///
/// There is only one uncaught exception handler and one signal disposition per
/// process, so this cannot be per instance. The registry is what lets several
/// Countly instances each report the same crash to their own server.
///
/// The signal path runs in a context where almost nothing is legal: no locks that
/// might be held, no allocation that might block, no logging that would re-enter
/// the health tracker's dispatch queues. What happens there is kept to capturing
/// a backtrace and calling straight through.
final class CrashHandlerInstaller {

    static let shared = CrashHandlerInstaller()

    private let subscribers = WeakRegistry<CrashModule>()
    private let lock = NSLock()
    private var isInstalled = false

    /// The handler that was in place before the SDK installed its own, so a host
    /// application's or another SDK's handler still runs.
    private var previousUncaughtExceptionHandler: (@convention(c) (NSException) -> Void)?

    private init() {}

    /// Signals that mean the process is going down in a way worth reporting.
    private static let handledSignals: [Int32] = [
        SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGPIPE, SIGTRAP,
    ]

    // MARK: - Registration

    /// Adds a module and installs the handlers on first use.
    func register(_ module: CrashModule) {
        subscribers.add(module)

        lock.lock()
        let shouldInstall = !isInstalled
        if shouldInstall { isInstalled = true }
        lock.unlock()

        if shouldInstall { install() }
    }

    /// Removes a module, uninstalling the handlers once nobody is left.
    ///
    /// Unlike the view controller swizzle these are given back: leaving a signal
    /// disposition pointing at a halted SDK would swallow crashes the host
    /// application's own handler should see.
    func deregister(_ module: CrashModule) {
        let wasLast = subscribers.remove(module)

        lock.lock()
        let shouldUninstall = wasLast && isInstalled
        if shouldUninstall { isInstalled = false }
        lock.unlock()

        if shouldUninstall { uninstall() }
    }

    /// The modules to report a crash to.
    fileprivate func activeModules() -> [CrashModule] {
        subscribers.current()
    }

    // MARK: - Installation

    private func install() {
        previousUncaughtExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(countlyUncaughtExceptionHandler)

        #if os(iOS) || os(tvOS) || os(visionOS) || os(macOS)
        for signalCode in Self.handledSignals {
            signal(signalCode, countlySignalHandler)
        }
        #endif
    }

    private func uninstall() {
        // The pointer is left in place: `uninstall` runs from inside the crash
        // path (the handler stops reporting once it has recorded), and the handler
        // still has to chain to it afterwards.
        NSSetUncaughtExceptionHandler(previousUncaughtExceptionHandler)

        #if os(iOS) || os(tvOS) || os(visionOS) || os(macOS)
        for signalCode in Self.handledSignals {
            signal(signalCode, SIG_DFL)
        }
        #endif
    }

    /// Chains to whatever handler was installed before the SDK's.
    fileprivate func callPreviousHandler(_ exception: NSException) {
        lock.lock()
        let previous = previousUncaughtExceptionHandler
        lock.unlock()
        previous?(exception)
    }

    /// Name of a signal, for the crash reason.
    ///
    /// Spelled out rather than read from `sys_signame`, which Swift imports as a
    /// fixed-size tuple that cannot be indexed at runtime.
    static func name(for signalCode: Int32) -> String {
        switch signalCode {
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE: return "SIGFPE"
        case SIGBUS: return "SIGBUS"
        case SIGPIPE: return "SIGPIPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(signalCode)"
        }
    }

    /// Reports one crash to every registered module.
    fileprivate func dispatch(name: String, reason: String, stackTrace: [String]) {
        for module in activeModules() {
            module.handleAutoDetectedCrash(name: name, reason: reason, stackTrace: stackTrace)
        }
    }
}

/// Installed as the process uncaught exception handler.
private let countlyUncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    CrashHandlerInstaller.shared.dispatch(
        name: exception.name.rawValue,
        reason: exception.reason ?? exception.name.rawValue,
        stackTrace: exception.callStackSymbols)

    CrashHandlerInstaller.shared.callPreviousHandler(exception)
}

/// Installed as the disposition for fatal signals.
///
/// The backtrace is captured here rather than reconstructed later, because by the
/// time anything else runs the frames are gone. The first frame is dropped: it is
/// this handler itself.
private let countlySignalHandler: @convention(c) (Int32) -> Void = { signalCode in
    let maxFrames = 128
    var stack = [UnsafeMutableRawPointer?](repeating: nil, count: maxFrames)
    let frameCount = backtrace(&stack, Int32(maxFrames))

    var frames: [String] = []
    // Guarded rather than assumed: an unwalkable stack yields zero frames, and
    // `1..<0` would trap inside the handler and replace the crash being reported.
    if frameCount > 1, let symbols = backtrace_symbols(&stack, frameCount) {
        for index in 1..<Int(frameCount) {
            if let line = symbols[index] {
                frames.append(String(cString: line))
            }
        }
        free(symbols)
    }

    CrashHandlerInstaller.shared.dispatch(
        name: "Fatal Signal",
        reason: "App terminated by \(CrashHandlerInstaller.name(for: signalCode))",
        stackTrace: frames)
}
