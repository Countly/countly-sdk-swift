//
//  CrashLogStore.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// Append-only file holding the crash breadcrumbs of the current run.
///
/// Breadcrumbs are written to disk rather than kept in memory so that the run
/// that crashes can still contribute them: the next launch reads the file, sends
/// it with the crash report, and deletes it.
///
/// Every operation runs on `writeQueue`, reads included. Ordering is the whole
/// point: a breadcrumb recorded before a `deleteAll` must not be written after it
/// and reappear in the next launch's report, which is what a store that mixed an
/// asynchronous append with a synchronous delete would do.
final class CrashLogStore {

    private static let module = "CrashLogStore"
    private static let fileName = "CountlyCustomCrash"

    private let namespace: StorageNamespace
    private weak var logger: Logger?

    /// Serializes every access so two threads recording breadcrumbs cannot
    /// interleave inside one line, and so a delete cannot overtake an append.
    private let writeQueue = DispatchQueue(label: "ly.count.crashlog", qos: .utility)

    /// How many breadcrumbs the file keeps. Only the newest this many are ever
    /// read back, so without a cap the file grows for the life of the
    /// installation while all but the tail of it is dead weight.
    ///
    /// Updated when behavior settings change the limit, which is why it is a
    /// variable rather than an init parameter.
    var maxBreadcrumbCount: Int = DefaultLimits.maxBreadcrumbCount

    /// Lines written since the file was last trimmed. Counted rather than
    /// recomputed, so the common append does not read the whole file back.
    private var lineCount = 0

    init(namespace: StorageNamespace, logger: Logger?) {
        self.namespace = namespace
        self.logger = logger
    }

    /// Appends one breadcrumb. Returns immediately; the write happens off the
    /// calling thread because breadcrumbs are recorded on hot paths.
    func append(_ log: String) {
        // A breadcrumb containing a newline would read back as several, so the
        // line separator is escaped rather than carried through.
        let line = log.replacingOccurrences(of: "\n", with: "\\n") + "\n"

        writeQueue.async { [weak self] in
            self?.appendOnQueue(line)
        }
    }

    /// Everything recorded so far, or `nil` when nothing has been.
    func readAll() -> String? {
        writeQueue.sync {
            guard let data = try? Data(contentsOf: fileURL) else { return nil }
            logger?.d(Self.module, "readAll", "custom crash logs are read from the custom crash log file, dataSize: [\(data.count)]")
            return String(data: data, encoding: .utf8)
        }
    }

    /// Removes the file, called once its contents have been attached to a report.
    ///
    /// Synchronous on `writeQueue`, so every breadcrumb recorded before this call
    /// is already on disk and is deleted with the rest, and none recorded after it
    /// can be lost to a delete that had not run yet.
    func deleteAll() {
        writeQueue.sync {
            lineCount = 0
            let url = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return }

            logger?.d(Self.module, "deleteAll", "custom crash log file is detected and it is being deleted")
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger?.w(Self.module, "deleteAll", "custom crash log file can not be deleted, error: [\(error.localizedDescription)]")
            }
        }
    }

    // MARK: - On the write queue

    private func appendOnQueue(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL

        // `FileHandle.write(_:)` raises an uncatchable Objective-C exception when
        // the write fails, which on a full disk would kill the application over a
        // breadcrumb. The throwing form is used where it exists, and the older
        // deployment targets fall back to rewriting the file, which reports a
        // failure as an error rather than a trap.
        if #available(iOS 13.4, macOS 10.15.4, tvOS 13.4, watchOS 6.2, *),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                lineCount += 1
                logger?.v(Self.module, "append", "a line is appended to the custom crash log file, lineLength: [\(line.count)]")
            } catch {
                logger?.w(Self.module, "append", "breadcrumb can not be appended to the custom crash log file, error: [\(error.localizedDescription)]")
                return
            }
        } else {
            let existing = (try? Data(contentsOf: url)) ?? Data()
            do {
                try (existing + data).write(to: url, options: .atomic)
                lineCount += 1
                logger?.v(Self.module, "append", "a line is appended to the custom crash log file, lineLength: [\(line.count)]")
            } catch {
                logger?.w(Self.module, "append", "custom crash log file can not be written, error: [\(error.localizedDescription)]")
                return
            }
        }

        trimIfNeededOnQueue()
    }

    /// Rewrites the file with only the newest `maxBreadcrumbCount` lines.
    ///
    /// Only done once the file has grown to twice the limit, so the cost of
    /// reading and rewriting is paid once per limit's worth of breadcrumbs rather
    /// than on every append.
    private func trimIfNeededOnQueue() {
        let limit = max(1, maxBreadcrumbCount)
        guard lineCount > limit * 2 else { return }

        let url = fileURL
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return }

        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .suffix(limit)

        let rewritten = kept.joined(separator: "\n") + "\n"
        do {
            try Data(rewritten.utf8).write(to: url, options: .atomic)
            logger?.d(Self.module, "trim", "custom crash log file is trimmed to the breadcrumb limit, keptLineCount: [\(kept.count)], limit: [\(limit)]")
            lineCount = kept.count
        } catch {
            logger?.w(Self.module, "trim", "custom crash log file can not be trimmed, error: [\(error.localizedDescription)]")
        }
    }

    private lazy var fileURL: URL = {
        StorageLocation.directoryURL(logger: logger)
            .appendingPathComponent(namespace.fileName(Self.fileName, extension: "log"))
    }()
}
