//
//  WeakRegistry.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Set of objects held weakly, for the handful of things the platform only gives
/// one of per process.
///
/// The view controller swizzle, the crash handlers and the APNs token are all
/// installed once and have to reach every Countly instance that asked for them.
/// Each of those keeps a registry, and the entries are weak so a halted instance
/// does not keep its modules alive.
///
/// What each owner does when the registry empties differs and stays at the call
/// site: the swizzle is never uninstalled, the crash handlers are, and the token
/// registry replays what it already has to a late subscriber.
final class WeakRegistry<Element: AnyObject> {

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: WeakBox] = [:]

    private struct WeakBox {
        weak var value: Element?
    }

    /// Adds an object.
    ///
    /// - Returns: `true` when this was the first entry, which is the moment an
    ///   owner installs whatever it is fronting.
    @discardableResult
    func add(_ element: Element) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        pruneLocked()
        let wasEmpty = entries.isEmpty
        entries[ObjectIdentifier(element)] = WeakBox(value: element)
        return wasEmpty
    }

    /// Removes an object.
    ///
    /// - Returns: `true` when that was the last entry, which is the moment an
    ///   owner may uninstall.
    @discardableResult
    func remove(_ element: Element) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        entries.removeValue(forKey: ObjectIdentifier(element))
        pruneLocked()
        return entries.isEmpty
    }

    /// The live objects, with any that have been deallocated pruned.
    ///
    /// Pruning here rather than on a timer is enough: every read is a fan-out, and
    /// a registry that is never read is not growing either.
    func current() -> [Element] {
        lock.lock()
        defer { lock.unlock() }

        pruneLocked()
        return entries.values.compactMap(\.value)
    }

    /// Whether anything live is registered.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        pruneLocked()
        return entries.isEmpty
    }

    /// Drops entries whose object has been deallocated.
    ///
    /// Every query prunes, because an instance released without `halt()` would
    /// otherwise keep counting toward "somebody is still registered" and stop the
    /// owner from uninstalling what it installed.
    private func pruneLocked() {
        for (key, box) in entries where box.value == nil {
            entries.removeValue(forKey: key)
        }
    }
}
