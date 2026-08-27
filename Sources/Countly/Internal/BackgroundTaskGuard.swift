//
//  BackgroundTaskGuard.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif

/// Asks the system for a little more time when the application is about to be
/// suspended.
///
/// Backgrounding is where the SDK does its most important work and has the least
/// time to do it: the session is closed, the events are flushed, a request goes
/// out and the queue is written to disk. Without this the system can suspend the
/// process part way through, and what is lost is not the request in flight, which
/// would be retried, but the disk write that was going to record it. The queue
/// then rolls back to its last written state and everything since is gone.
///
/// One task per process, not one per instance: the platform grants the extension
/// to the application, so several Countly instances asking at once must not each
/// take one out and have the first to finish end it for the others. The count is
/// what keeps it alive until the last of them is done.
final class BackgroundTaskGuard {

    static let shared = BackgroundTaskGuard()

    private let lock = NSLock()
    private var outstanding = 0

    #if os(iOS) || os(tvOS) || os(visionOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    #endif

    private init() {}

    /// Registers a piece of work that should not be cut off.
    ///
    /// Every call must be balanced by exactly one `end()`, including on the paths
    /// that fail, or the process keeps the extension until the system revokes it.
    func begin() {
        lock.lock()
        outstanding += 1
        let isFirst = outstanding == 1
        lock.unlock()

        guard isFirst else { return }

        #if os(iOS) || os(tvOS) || os(visionOS)
        // `beginBackgroundTask` is main-thread-only, and the expiration handler
        // arrives on the main thread as well.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.lock.lock()
            let stillNeeded = self.outstanding > 0 && self.identifier == .invalid
            self.lock.unlock()

            guard stillNeeded else { return }

            let identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
                // The system is out of patience. Ending the task here rather than
                // letting it expire is what stops the application being killed.
                self?.expire()
            }

            self.lock.lock()
            self.identifier = identifier
            let alreadyDone = self.outstanding == 0
            self.lock.unlock()

            // The work finished while this hop was in flight, so nothing is left
            // to protect and the task would otherwise be held until it expired.
            if alreadyDone { self.expire() }
        }
        #endif
    }

    /// Reports that a piece of work has finished.
    func end() {
        lock.lock()
        if outstanding > 0 { outstanding -= 1 }
        let isLast = outstanding == 0
        lock.unlock()

        guard isLast else { return }

        #if os(iOS) || os(tvOS) || os(visionOS)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            self.lock.lock()
            // Re-checked on the main queue: more work can have started since.
            let shouldEnd = self.outstanding == 0 && self.identifier != .invalid
            let identifier = self.identifier
            if shouldEnd { self.identifier = .invalid }
            self.lock.unlock()

            if shouldEnd { UIApplication.shared.endBackgroundTask(identifier) }
        }
        #endif
    }

    #if os(iOS) || os(tvOS) || os(visionOS)
    /// Gives the task back without waiting for the work, because the system asked.
    private func expire() {
        lock.lock()
        let identifier = self.identifier
        self.identifier = .invalid
        lock.unlock()

        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
    #endif
}
