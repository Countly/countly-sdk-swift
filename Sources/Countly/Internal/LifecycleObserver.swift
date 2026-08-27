//
//  LifecycleObserver.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif
#if os(watchOS)
import WatchKit
#endif

/// Cached application state.
///
/// Read from a notification rather than by asking the platform, because the crash
/// path needs to know whether the application was in the foreground and must not
/// make a UI call from a signal handler or a background thread.
enum AppState {

    private static let lock = NSLock()
    private static var cachedIsForeground: Bool = true
    private static var cachedIsActive: Bool = true
    private static var isObserving = false

    /// Whether the application is anywhere other than the background.
    ///
    /// This is the question a session asks: an application that is merely inactive,
    /// because a system alert or Control Center is over it, is still one the user
    /// is in, and closing its session would cut it in half.
    static var isForeground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedIsForeground
    }

    /// Whether the application is frontmost and receiving events.
    ///
    /// A stricter question than `isForeground`, and a different one: this is what
    /// the `cly_v` visibility segmentation reports, so an event recorded by a timer
    /// while Control Center is pulled down is correctly marked as not seen. The two
    /// were one flag once, which made `cly_v` claim a visibility the user did not
    /// have.
    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cachedIsActive
    }

    /// Records the state the host application reported.
    ///
    /// watchOS has no lifecycle notifications before watchOS 7, and the documented
    /// integration there is for the host to call `suspend` and `resume`. Taking its
    /// word beats a value seeded once at launch and never corrected.
    static func setActive(_ active: Bool) {
        lock.lock()
        cachedIsActive = active
        if active { cachedIsForeground = true }
        lock.unlock()
    }

    /// Starts observing. Process-wide and idempotent: the application state is a
    /// property of the process, not of a Countly instance.
    static func startObserving() {
        lock.lock()
        guard !isObserving else {
            lock.unlock()
            return
        }
        isObserving = true
        lock.unlock()

        seedFromPlatform()

        #if os(iOS) || os(tvOS) || os(visionOS)
        observe(UIApplication.didBecomeActiveNotification, foreground: true, active: true)
        observe(UIApplication.willEnterForegroundNotification, foreground: true, active: nil)
        observe(UIApplication.willResignActiveNotification, foreground: nil, active: false)
        observe(UIApplication.didEnterBackgroundNotification, foreground: false, active: false)
        #elseif os(macOS)
        observe(NSApplication.didBecomeActiveNotification, foreground: true, active: true)
        observe(NSApplication.didResignActiveNotification, foreground: false, active: false)
        #elseif os(watchOS)
        if #available(watchOS 7.0, *) {
            observe(WKExtension.applicationDidBecomeActiveNotification, foreground: true, active: true)
            observe(WKExtension.applicationWillResignActiveNotification, foreground: nil, active: false)
            observe(WKExtension.applicationDidEnterBackgroundNotification, foreground: false, active: false)
        }
        #endif
    }

    /// Reads the current state from the platform.
    ///
    /// The platform's answer is main-thread-only, so an SDK started off the main
    /// thread gets the optimistic default until this lands. That is the right way
    /// round: a foreground launch, which is almost all of them, must not be delayed
    /// or mis-seeded, and the notifications correct a background launch a moment
    /// later.
    private static func seedFromPlatform() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { seedFromPlatform() }
            return
        }

        #if os(iOS) || os(tvOS) || os(visionOS)
        let state = UIApplication.shared.applicationState
        let isForeground = state != .background
        let isActive = state == .active
        #elseif os(macOS)
        let isForeground = NSApplication.shared.isActive
        let isActive = isForeground
        #elseif os(watchOS)
        let state = WKExtension.shared().applicationState
        let isForeground = state != .background
        let isActive = state == .active
        #else
        let isForeground = true
        let isActive = true
        #endif

        // Under the same lock the readers take: the crash path reads this from
        // another thread.
        lock.lock()
        cachedIsForeground = isForeground
        cachedIsActive = isActive
        lock.unlock()
    }

    /// Observes one notification.
    ///
    /// A `nil` means the transition says nothing about that flag: resigning active
    /// does not put the application in the background, and entering the foreground
    /// does not yet make it frontmost.
    private static func observe(_ name: Notification.Name, foreground: Bool?, active: Bool?) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            lock.lock()
            if let foreground { cachedIsForeground = foreground }
            if let active { cachedIsActive = active }
            lock.unlock()
        }
    }
}

/// Routes application lifecycle notifications to one instance.
///
/// Each instance owns its own observer rather than sharing a process-wide one
/// that fans out, so halting an instance detaches exactly its own observation and
/// there is no shared registry to keep in sync.
final class LifecycleObserver {

    private static let module = "Lifecycle"

    private unowned let core: SDKCore
    private var tokens: [NSObjectProtocol] = []

    /// Called when the application becomes active or enters the foreground.
    var onForeground: (() -> Void)?

    /// Called when the application enters the background.
    var onBackground: (() -> Void)?

    /// Called when the application is about to resign active, before it is fully
    /// backgrounded.
    var onWillResignActive: (() -> Void)?

    /// Called when the process is about to end. Everything on this path has to be
    /// synchronous.
    var onWillTerminate: (() -> Void)?

    /// Called when the device rotated.
    var onOrientationChange: (() -> Void)?

    init(core: SDKCore) {
        self.core = core
    }

    /// Subscribes to whatever the current platform offers.
    ///
    /// A platform missing a notification is not an error: the SDK keeps working
    /// with the callbacks it does receive, and the host application can drive the
    /// rest manually.
    func register() {
        AppState.startObserving()

        #if os(iOS) || os(tvOS) || os(visionOS)
        add(UIApplication.didEnterBackgroundNotification) { [weak self] in self?.onBackground?() }
        // Observed but not acted on: the foreground work happens on
        // `didBecomeActive`, and doing it twice would begin two sessions.
        add(UIApplication.willEnterForegroundNotification) {}
        addSynchronously(UIApplication.willTerminateNotification) { [weak self] in self?.onWillTerminate?() }
        add(UIApplication.didBecomeActiveNotification) { [weak self] in self?.onForeground?() }
        add(UIApplication.willResignActiveNotification) { [weak self] in self?.onWillResignActive?() }
        #elseif os(macOS)
        addSynchronously(NSApplication.willTerminateNotification) { [weak self] in self?.onWillTerminate?() }
        // The macOS counterpart of foreground: a `begin_session` dropped because
        // the application was not yet active gets another chance here.
        add(NSApplication.didBecomeActiveNotification) { [weak self] in self?.onForeground?() }
        #endif

        #if os(iOS)
        if core.config.enableOrientationTracking {
            add(UIDevice.orientationDidChangeNotification) { [weak self] in
                self?.scheduleOrientationRecording()
            }
        }
        #endif

        core.logger.d(Self.module, "register", "lifecycle observation started, observerCount: [\(tokens.count)]")
    }

    /// Stops observing. Called from `halt`.
    func deregister() {
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        tokens.removeAll()
        orientationWorkItem?.cancel()
        orientationWorkItem = nil
        core.logger.d(Self.module, "deregister", "lifecycle observation stopped")
    }

    private func add(_ name: Notification.Name, _ handler: @escaping () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            handler()
        }
        tokens.append(token)
    }

    /// Observes without an operation queue, so the handler runs on the thread that
    /// posted the notification.
    ///
    /// Termination is the one path where this matters: an enqueued block may never
    /// get a run loop turn before the process exits, which loses the final flush.
    private func addSynchronously(_ name: Notification.Name, _ handler: @escaping () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
            handler()
        }
        tokens.append(token)
    }

    private var orientationWorkItem: DispatchWorkItem?

    /// Delays the orientation reading.
    ///
    /// The rotation notification fires while the interface is still animating, and
    /// reading the orientation immediately returns the old one.
    private func scheduleOrientationRecording() {
        orientationWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onOrientationChange?() }
        orientationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    deinit {
        deregister()
    }
}
