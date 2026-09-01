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
    var maxBreadcrumbCount: Int = DefaultLimits.maxBreadcrumbCount {
        didSet {
            logger?.d(Self.module, "maxBreadcrumbCount", "breadcrumb file limit is set, previousLimit: [\(oldValue)], limit: [\(maxBreadcrumbCount)]")
        }
    }

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
        logger?.v(Self.module, "append", "breadcrumb accepted for the custom crash log file, breadcrumb: [\(log)]")

        writeQueue.async { [weak self] in
            self?.appendOnQueue(line)
        }
    }

    /// Everything recorded so far, or `nil` when nothing has been.
    func readAll() -> String? {
        writeQueue.sync {
            guard let data = try? Data(contentsOf: fileURL) else {
                logger?.d(Self.module, "readAll", "no custom crash log file to read, no breadcrumb was recorded or the file was already consumed")
                return nil
            }

            guard let text = String(data: data, encoding: .utf8) else {
                logger?.d(Self.module, "readAll", "custom crash log file is not valid utf8 and is treated as empty, dataSize: [\(data.count)]")
                return nil
            }

            logger?.d(Self.module, "readAll", "custom crash logs are read from the custom crash log file, dataSize: [\(data.count)], lineCountSinceLastTrim: [\(lineCount)]")
            return text
        }
    }

    /// Removes the file, called once its contents have been attached to a report.
    ///
    /// Synchronous on `writeQueue`, so every breadcrumb recorded before this call
    /// is already on disk and is deleted with the rest, and none recorded after it
    /// can be lost to a delete that had not run yet.
    func deleteAll() {
        writeQueue.sync {
            let discardedLineCount = lineCount
            lineCount = 0
            let url = fileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                logger?.d(Self.module, "deleteAll", "no custom crash log file to delete")
                return
            }

            logger?.d(Self.module, "deleteAll", "custom crash log file is detected and it is being deleted, lineCountSinceLastTrim: [\(discardedLineCount)]")
            do {
                try FileManager.default.removeItem(at: url)
                logger?.d(Self.module, "deleteAll", "custom crash log file is deleted")
            } catch {
                logger?.w(Self.module, "deleteAll", "custom crash log file can not be deleted, error: [\(error.localizedDescription)]")
            }
        }
    }

    // MARK: - On the write queue

    private func appendOnQueue(_ line: String) {
        guard let data = line.data(using: .utf8) else {
            logger?.d(Self.module, "append", "breadcrumb is dropped, it can not be encoded as utf8, lineLength: [\(line.count)]")
            return
        }
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
                logger?.d(Self.module, "append", "a line is appended to the end of the existing custom crash log file, lineLength: [\(line.count)], byteCount: [\(data.count)], lineCountSinceLastTrim: [\(lineCount)]")
            } catch {
                let nsError = error as NSError
                logger?.w(Self.module, "append", "breadcrumb can not be appended to the custom crash log file, byteCount: [\(data.count)], errorDomain: [\(nsError.domain)], errorCode: [\(nsError.code)], error: [\(error.localizedDescription)]")
                return
            }
        } else {
            let existing = (try? Data(contentsOf: url)) ?? Data()
            do {
                try (existing + data).write(to: url, options: .atomic)
                lineCount += 1
                logger?.d(Self.module, "append", "a line is appended by rewriting the whole custom crash log file, lineLength: [\(line.count)], existingByteCount: [\(existing.count)], lineCountSinceLastTrim: [\(lineCount)]")
            } catch {
                let nsError = error as NSError
                logger?.w(Self.module, "append", "custom crash log file can not be written, byteCount: [\(existing.count + data.count)], errorDomain: [\(nsError.domain)], errorCode: [\(nsError.code)], error: [\(error.localizedDescription)]")
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
              let text = String(data: data, encoding: .utf8) else {
            logger?.d(Self.module, "trim", "custom crash log file can not be read back for trimming, it is left as it is, lineCountSinceLastTrim: [\(lineCount)], limit: [\(limit)]")
            return
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        let kept = lines.suffix(limit)

        logger?.d(Self.module, "trim", "custom crash log file grew past twice the breadcrumb limit and will be trimmed, fileLineCount: [\(lines.count)], droppedLineCount: [\(lines.count - kept.count)], limit: [\(limit)]")

        let rewritten = kept.joined(separator: "\n") + "\n"
        do {
            try Data(rewritten.utf8).write(to: url, options: .atomic)
            logger?.d(Self.module, "trim", "custom crash log file is trimmed to the breadcrumb limit, keptLineCount: [\(kept.count)], byteCount: [\(rewritten.utf8.count)]")
            lineCount = kept.count
        } catch {
            let nsError = error as NSError
            logger?.w(Self.module, "trim", "custom crash log file can not be trimmed, keptLineCount: [\(kept.count)], errorDomain: [\(nsError.domain)], errorCode: [\(nsError.code)], error: [\(error.localizedDescription)]")
        }
    }

    private lazy var fileURL: URL = {
        StorageLocation.directoryURL(logger: logger)
            .appendingPathComponent(namespace.fileName(Self.fileName, extension: "log"))
    }()
}
