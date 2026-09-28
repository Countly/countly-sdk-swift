//
//  StorageNamespace.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Decides where an instance's data lives on disk and in user defaults.
///
/// The default instance gets the empty namespace, which means it reads and writes
/// exactly the paths and keys earlier Countly SDKs used on this device. That is
/// what makes adopting multi-instance a drop-in change: an application that
/// upgrades keeps its device ID and its queued requests.
///
/// A named instance gets `<name sanitized>_<hash>` appended to every path and
/// key. The hash is there because sanitizing is lossy: `a.b` and `a-b` both
/// sanitize to `a_b`, and without the hash they would share a store.
struct StorageNamespace: Equatable {

    /// Registry key of the default instance. The `[CLY]_` prefix is reserved, so
    /// a host application choosing its own names cannot collide with it.
    static let defaultInstanceName = "[CLY]_default_instance"

    /// Empty for the default instance.
    let suffix: String

    /// The namespace of the default instance: legacy paths, no suffix.
    static let `default` = StorageNamespace(suffix: "")

    /// Builds the namespace for a named instance.
    ///
    /// Passing the default instance name, an empty name, or `nil` yields the
    /// default namespace.
    init(instanceName: String?) {
        guard let name = instanceName,
              !name.isEmpty,
              name != StorageNamespace.defaultInstanceName else {
            suffix = ""
            return
        }
        suffix = StorageNamespace.sanitize(name)
    }

    private init(suffix: String) {
        self.suffix = suffix
    }

    /// Whether this is the default instance's namespace.
    var isDefault: Bool { suffix.isEmpty }

    /// Namespaces a user defaults key.
    func key(_ base: String) -> String {
        isDefault ? base : "\(base)_\(suffix)"
    }

    /// Namespaces a directory name, the same way as a key.
    func directoryName(_ base: String) -> String {
        key(base)
    }

    /// Namespaces a file name, keeping its extension in place.
    func fileName(_ base: String, extension fileExtension: String) -> String {
        isDefault ? "\(base).\(fileExtension)" : "\(base)_\(suffix).\(fileExtension)"
    }

    /// Reduces a name to file-safe characters and appends a hash of the original.
    ///
    /// The hash is computed over the untouched name, so two names that sanitize
    /// to the same string still get different namespaces.
    static func sanitize(_ name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let safe = String(name.map { allowed.contains($0) ? $0 : "_" })
        return "\(safe)_\(String(fnv1a(name), radix: 16))"
    }

    /// FNV-1a over the UTF-8 bytes. Chosen for being short, stable across
    /// processes and platforms, and dependency free. It is not a security hash
    /// and is not used as one.
    static func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return hash
    }
}
