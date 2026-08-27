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
final class CrashLogStore {

    private static let module = "CrashLogStore"
    private static let fileName = "CountlyCustomCrash"

    private let namespace: StorageNamespace
    private weak var logger: Logger?

    /// Serializes appends so two threads recording breadcrumbs cannot interleave
    /// inside one line.
    private let writeQueue = DispatchQueue(label: "ly.count.crashlog", qos: .utility)

    init(namespace: StorageNamespace, logger: Logger?) {
        self.namespace = namespace
        self.logger = logger
    }

    /// Appends one breadcrumb. Returns immediately; the write happens off the
    /// calling thread because breadcrumbs are recorded on hot paths.
    func append(_ log: String) {
        let line = log + "\n"
        let url = fileURL

        writeQueue.async { [weak self] in
            guard let data = line.data(using: .utf8) else { return }

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { handle.closeFile() }
                handle.seekToEndOfFile()
                handle.write(data)
                self?.logger?.v(Self.module, "append", "a line is appended to the custom crash log file, lineLength: [\(line.count)]")
            } else {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self?.logger?.w(Self.module, "append", "custom crash log file can not be created, error: [\(error.localizedDescription)]")
                }
            }
        }
    }

    /// Everything recorded so far, or `nil` when nothing has been.
    func readAll() -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        logger?.d(Self.module, "readAll", "custom crash logs are read from the custom crash log file, dataSize: [\(data.count)]")
        return String(data: data, encoding: .utf8)
    }

    /// Removes the file, called once its contents have been attached to a report.
    func deleteAll() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        logger?.d(Self.module, "deleteAll", "custom crash log file is detected and it is being deleted")
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logger?.w(Self.module, "deleteAll", "custom crash log file can not be deleted, error: [\(error.localizedDescription)]")
        }
    }

    private lazy var fileURL: URL = {
        StorageLocation.directoryURL(logger: logger)
            .appendingPathComponent(namespace.fileName(Self.fileName, extension: "log"))
    }()
}
