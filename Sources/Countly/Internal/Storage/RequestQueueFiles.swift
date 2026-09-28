//
//  RequestQueueFiles.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import Foundation

/// One queued request and its place in the queue.
struct QueuedRequest: Sendable {

    /// Only ever grows, so sorting by it is the queue order.
    let sequence: UInt64
    var request: String
}

/// The request queue on disk.
///
/// One file per request, so sending a request deletes one small file instead of
/// rewriting the whole queue, and a file that cannot be read costs that request
/// alone. The layout, under the storage directory:
///
/// - `CountlyRequests/state.json`: the current generation and the mirror token.
/// - `CountlyRequests/<generation>/<sequence>.req`: one request, UTF-8.
/// - `Countly.dat`: the whole queue, archived exactly as `CountlyPersistency`
///   archives it, for the instances that mirror it. An application that goes back
///   to countly-sdk-ios finds its queue there.
///
/// The store hands over its whole queue after every change and the files are
/// brought in line with it, so a write that failed is simply made again by the
/// next sync. Requests rewritten in place, such as a temporary device ID becoming
/// the real one, are written as a new generation and switched to by replacing the
/// state file, which is atomic: a process killed half way through leaves the
/// previous generation in force rather than a queue that is half rewritten.
///
/// The mirror carries the state's token, which the Objective-C SDK drops since it
/// writes back only the queue. A `Countly.dat` without the token of the state in
/// force is therefore newer than the request files, and its queue is taken over.
///
/// Confined to the store's write queue, apart from `load()`, which runs before
/// anything else can reach it, and `writeFromCrashHandler(_:)`. That confinement
/// is what makes the unchecked `Sendable` true.
final class RequestQueueFiles: @unchecked Sendable {

    private static let module = "RequestQueue"

    private static let stateFileName = "state.json"
    private static let requestExtension = "req"

    /// How long the mirror waits for further changes before it is written, so a
    /// drain of many requests rewrites it a few times rather than once each.
    private static let mirrorDelay: TimeInterval = 1

    /// What `state.json` holds.
    private struct State: Codable {
        var version = 1
        var generation: Int
        var mirrorToken: String
    }

    /// What was found where `state.json` belongs.
    private enum StoredState {
        case missing
        case unreadable
        case found(State)
    }

    /// A `Countly.dat` that decoded.
    private struct LegacyFile {
        let requests: [String]

        /// The token of the state it mirrors, `nil` when the Objective-C SDK wrote it.
        let token: String?
    }

    private let rootURL: URL
    private let legacyURL: URL
    private let mirrorsLegacyFile: Bool
    private let writeQueue: DispatchQueue
    private weak var logger: Logger?

    /// The generation in force, or the one a pending commit comes after.
    private var generation = 0

    /// Whether no generation holds the queue yet, so the next sync writes all of it
    /// as a new one: after a take over, and when no request files exist at all.
    private var needsCommit = false

    /// The token of the state in force. `nil` while no state this object can name
    /// is in force, and the mirror is not written until one is.
    private var mirrorToken: String?

    /// The sequences with a file in `generation` that this object looks after.
    private var onDisk: Set<UInt64> = []

    /// The store's rewrite count the generation in force was written at.
    private var committedRewriteCount = 0

    /// The queue as last handed over. The mirror is written from it.
    private var latest: [QueuedRequest] = []

    /// Whether earlier generations, and a named instance's legacy file, are left to
    /// remove now that the generation in force is known to be the right one.
    private var hasLeftovers = false

    private var isMirrorDirty = false
    private var isMirrorScheduled = false

    /// - Parameter mirrorsLegacyFile: Whether `Countly.dat` is kept current for the
    ///   Objective-C SDK. Only the default instance's data is where that SDK looks.
    init(namespace: StorageNamespace, mirrorsLegacyFile: Bool, writeQueue: DispatchQueue, logger: Logger?) {
        let directory = StorageLocation.directoryURL(logger: logger)
        rootURL = directory.appendingPathComponent(namespace.directoryName("CountlyRequests"), isDirectory: true)
        legacyURL = directory.appendingPathComponent(namespace.fileName("Countly", extension: "dat"))
        self.mirrorsLegacyFile = mirrorsLegacyFile
        self.writeQueue = writeQueue
        self.logger = logger
    }

    // MARK: - Loading

    /// Reads the queue, taking it over from `Countly.dat` when that holds the newer
    /// of the two: on the first launch, and after the Objective-C SDK wrote it.
    ///
    /// Nothing is written or removed here. The first sync does whatever the load
    /// decided, so a launch cut short before it finds the same files again.
    ///
    /// - Returns: The queue, and the first sequence no request file uses.
    func load() -> (queue: [QueuedRequest], nextSequence: UInt64) {
        let legacy = readLegacyFile()

        switch readState() {
        case .found(let state) where mirrorsLegacyFile && legacy != nil && legacy?.token != state.mirrorToken:
            return takeOver(legacy, after: state.generation, "the legacy file is newer than the request files")
        case .found(let state):
            generation = state.generation
            mirrorToken = state.mirrorToken
            hasLeftovers = true
        case .unreadable where mirrorsLegacyFile && legacy != nil && legacy?.token == nil:
            return takeOver(legacy, after: highestGeneration() ?? 0, "the legacy file was written by the Objective-C SDK")
        case .unreadable:
            guard let newest = highestGeneration() else {
                return takeOver(legacy, after: 0, "the state file cannot be read and there are no request files")
            }
            // Only a guess, so nothing else is removed and the mirror waits for a state written here.
            generation = newest
        case .missing:
            return takeOver(legacy, after: highestGeneration() ?? 0, "there are no request files yet")
        }

        let contents = readGeneration(generation)
        onDisk = contents.managed
        latest = contents.queue
        if mirrorsLegacyFile, mirrorToken != nil, legacy?.requests != contents.queue.map(\.request) {
            isMirrorDirty = true
        }
        logger?.d(Self.module, "load", "the request files are loaded, generation: [\(generation)], restoredRequestCount: [\(contents.queue.count)], mirrorIsBehind: [\(isMirrorDirty)]")
        return (contents.queue, contents.highestSequence + 1)
    }

    /// Makes `legacy`'s queue the queue, for the first sync to write as the
    /// generation after `last`. The legacy file is not touched until then.
    private func takeOver(_ legacy: LegacyFile?, after last: Int, _ reason: String) -> (queue: [QueuedRequest], nextSequence: UInt64) {
        let requests = legacy?.requests ?? []
        let queue = requests.enumerated().map { QueuedRequest(sequence: UInt64($0.offset + 1), request: $0.element) }
        generation = last
        needsCommit = true
        latest = queue
        logger?.d(Self.module, "load", "the queue is taken over from the legacy file, reason: [\(reason)], legacyRequestCount: [\(queue.count)], mirrorsLegacyFile: [\(mirrorsLegacyFile)]")
        return (queue, UInt64(queue.count) + 1)
    }

    // MARK: - Syncing

    /// Brings the files in line with `queue`, the store's whole queue as it is now.
    ///
    /// - Parameter rewriteCount: How many times the store changed the whole queue
    ///   at once. A count the files have not caught up with is written as a new
    ///   generation rather than file by file.
    func sync(_ queue: [QueuedRequest], rewriteCount: Int) {
        let needsGeneration = needsCommit || rewriteCount != committedRewriteCount
        if mirrorsLegacyFile, needsGeneration || !queue.elementsEqual(latest, by: { $0.sequence == $1.sequence }) {
            isMirrorDirty = true
        }
        latest = queue

        if needsGeneration {
            commit(queue, rewriteCount: rewriteCount)
        } else {
            applyChanges(queue)
        }
        if hasLeftovers {
            removeLeftovers()
        }
        scheduleMirror()
    }

    /// Deletes the files of requests no longer queued and writes the files of new
    /// ones. A file that fails either way is tried again by the next sync.
    private func applyChanges(_ queue: [QueuedRequest]) {
        let queued = Set(queue.map(\.sequence))
        for sequence in onDisk.subtracting(queued) {
            if removeItem(fileURL(sequence, generation: generation), "a sent or dropped request's file") {
                onDisk.remove(sequence)
            }
        }

        let unwritten = queue.filter { !onDisk.contains($0.sequence) }
        guard !unwritten.isEmpty else { return }

        try? FileManager.default.createDirectory(at: generationURL(generation), withIntermediateDirectories: true)
        for entry in unwritten {
            do {
                try Data(entry.request.utf8).write(to: fileURL(entry.sequence, generation: generation), options: .atomic)
                onDisk.insert(entry.sequence)
            } catch {
                let failure = error as NSError
                logger?.d(Self.module, "applyChanges", "a request file could not be written, it is tried again on the next sync, sequence: [\(entry.sequence)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            }
        }
    }

    /// Writes `queue` as a new generation and switches to it. A commit that fails
    /// leaves everything as it was, for the next sync to try again.
    private func commit(_ queue: [QueuedRequest], rewriteCount: Int) {
        let next = State(generation: generation + 1, mirrorToken: mirrorToken ?? UUID().uuidString)
        guard switchTo(next, queue, requiresMirror: mirrorToken == nil) else {
            logger?.d(Self.module, "commit", "the queue could not be written as a new generation, it is tried again on the next sync, generation: [\(next.generation)], requestCount: [\(queue.count)]")
            return
        }

        generation = next.generation
        mirrorToken = next.mirrorToken
        onDisk = Set(queue.map(\.sequence))
        committedRewriteCount = rewriteCount
        needsCommit = false
        hasLeftovers = true
        logger?.d(Self.module, "commit", "the queue is written as a new generation, generation: [\(next.generation)], requestCount: [\(queue.count)]")
    }

    /// Writes `queue` as the generation `next` names, then makes `next` the state
    /// in force, with the mirror written between the two.
    ///
    /// With `requiresMirror`, the switch waits until `Countly.dat` is this state's
    /// own or gone, since the next load takes over any other. A switch cut short
    /// after the mirror leaves a token no state has, so the next load takes that
    /// mirror over, and it holds this same queue.
    private func switchTo(_ next: State, _ queue: [QueuedRequest], requiresMirror: Bool) -> Bool {
        guard writeGeneration(next.generation, queue) else { return false }

        if mirrorsLegacyFile {
            if writeMirror(queue, token: next.mirrorToken) {
                isMirrorDirty = false
            } else if requiresMirror, !removeItem(legacyURL, "the legacy file the mirror could not replace") {
                return false
            }
        }
        return writeState(next)
    }

    /// Removes the generations before the one in force, and a named instance's
    /// legacy file, whose queue is in force by now.
    ///
    /// Later generations are left alone: one can be in the middle of being written,
    /// and the next commit to that number clears it.
    private func removeLeftovers() {
        hasLeftovers = false
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        for name in names {
            guard let other = Int(name), other < generation else { continue }
            removeItem(generationURL(other), "a previous generation")
        }
        if !mirrorsLegacyFile {
            removeItem(legacyURL, "the legacy file")
        }
    }

    /// Writes `queue` as a new generation, from what is on disk rather than from
    /// what this object tracks.
    ///
    /// For the crash handler on this queue's own thread: the operation it
    /// interrupted never finishes, and may be half way through changing exactly
    /// what this object tracks. The mirror is required, since the `Countly.dat` on
    /// disk can be one a pending take over has not replaced yet.
    func writeFromCrashHandler(_ queue: [QueuedRequest]) {
        var token: String?
        if case .found(let state) = readState() {
            token = state.mirrorToken
        }
        let next = State(generation: (highestGeneration() ?? 0) + 1, mirrorToken: token ?? UUID().uuidString)
        guard switchTo(next, queue, requiresMirror: true) else { return }

        // Should the process go on after all, the next sync writes the queue again over this one.
        needsCommit = true
    }

    /// Deletes every request file, the state and the mirror.
    func deleteEverything() {
        mirrorToken = nil
        isMirrorDirty = false
        onDisk.removeAll()
        latest.removeAll()
        removeItem(rootURL, "the request files")
        removeItem(legacyURL, "the legacy file")
    }

    // MARK: - Mirror

    /// Writes the mirror now if the queue changed since it was last written.
    func writeMirrorNow() {
        guard isMirrorDirty, let mirrorToken else { return }
        if writeMirror(latest, token: mirrorToken) {
            isMirrorDirty = false
        }
    }

    /// Writes the mirror a moment from now, held against suspension until then.
    private func scheduleMirror() {
        guard isMirrorDirty, mirrorToken != nil, !isMirrorScheduled else { return }
        isMirrorScheduled = true
        BackgroundTaskGuard.shared.begin()
        writeQueue.asyncAfter(deadline: .now() + Self.mirrorDelay) { [self] in
            isMirrorScheduled = false
            writeMirrorNow()
            BackgroundTaskGuard.shared.end()
        }
    }

    /// Archives `queue` into `Countly.dat` the way `CountlyPersistency` does, with
    /// the token added.
    private func writeMirror(_ queue: [QueuedRequest], token: String) -> Bool {
        let payload: [String: Any] = [
            PersistencyKey.queuedRequests: queue.map(\.request),
            PersistencyKey.queueMirrorToken: token,
        ]

        do {
            let data = CountlyArchive.encodeRoot(payload)
            try data.write(to: legacyURL, options: .atomic)
            logger?.d(Self.module, "writeMirror", "the queue is written to the legacy file the Objective-C SDK reads, requestCount: [\(queue.count)], dataSize: [\(data.count)]")
            return true
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "writeMirror", "the legacy file could not be written, it is tried again on the next change, requestCount: [\(queue.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return false
        }
    }

    // MARK: - Files

    /// The directory of one generation.
    private func generationURL(_ generation: Int) -> URL {
        rootURL.appendingPathComponent("\(generation)", isDirectory: true)
    }

    /// The file of one request, zero padded so the names sort as the queue does.
    private func fileURL(_ sequence: UInt64, generation: Int) -> URL {
        generationURL(generation).appendingPathComponent(String(format: "%020llu.%@", sequence, Self.requestExtension))
    }

    /// The highest numbered generation directory, when there is one.
    private func highestGeneration() -> Int? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootURL.path)) ?? []
        return names.compactMap { Int($0) }.max()
    }

    /// Writes a complete generation, starting from an empty directory: a directory
    /// under that number can be left over from a switch that was cut short.
    ///
    /// The files need no atomic write of their own, since nothing reads the
    /// directory before a state names it.
    private func writeGeneration(_ generation: Int, _ queue: [QueuedRequest]) -> Bool {
        let directory = generationURL(generation)
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for entry in queue {
                try Data(entry.request.utf8).write(to: fileURL(entry.sequence, generation: generation))
            }
            return true
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "writeGeneration", "a generation of request files could not be written, generation: [\(generation)], requestCount: [\(queue.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return false
        }
    }

    /// The requests of one generation, oldest first, the sequences of the files
    /// this object looks after, and the highest sequence any file uses.
    ///
    /// A file that reads but is empty or not UTF-8 is broken for good: it is looked
    /// after but not queued, so the first sync removes it. One that cannot be read
    /// at all is left alone, since a protected file on a locked device reads fine
    /// on a later launch. Names that are not request files can only be a write in
    /// progress, and are ignored.
    private func readGeneration(_ generation: Int) -> (queue: [QueuedRequest], managed: Set<UInt64>, highestSequence: UInt64) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: generationURL(generation).path)) ?? []
        let suffix = "." + Self.requestExtension
        let sequences = names.compactMap { name -> UInt64? in
            guard name.hasSuffix(suffix) else { return nil }
            return UInt64(name.dropLast(suffix.count))
        }.sorted()

        // In parallel, since the load runs on the thread that starts the SDK, usually main at launch.
        var contents = [Data?](repeating: nil, count: sequences.count)
        contents.withUnsafeMutableBufferPointer { buffer in
            let slots = UncheckedSendable(buffer)
            DispatchQueue.concurrentPerform(iterations: sequences.count) { index in
                slots.value[index] = try? Data(contentsOf: self.fileURL(sequences[index], generation: generation))
            }
        }

        var queue: [QueuedRequest] = []
        var managed: Set<UInt64> = []
        for (sequence, data) in zip(sequences, contents) {
            guard let data else {
                logger?.d(Self.module, "load", "a request file cannot be read now and is left for a later launch, sequence: [\(sequence)]")
                continue
            }
            managed.insert(sequence)
            guard !data.isEmpty, let request = String(data: data, encoding: .utf8) else {
                logger?.d(Self.module, "load", "a request file is broken and is dropped, the rest of the queue is kept, sequence: [\(sequence)], dataSize: [\(data.count)]")
                continue
            }
            queue.append(QueuedRequest(sequence: sequence, request: request))
        }
        return (queue, managed, sequences.last ?? 0)
    }

    /// `state.json`, told apart as missing, present but unreadable, and found.
    private func readState() -> StoredState {
        let url = rootURL.appendingPathComponent(Self.stateFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        do {
            return .found(try JSONDecoder().decode(State.self, from: Data(contentsOf: url)))
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "readState", "the state file cannot be read, nothing on disk is removed, errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return .unreadable
        }
    }

    /// Replaces `state.json` atomically, which is what switches generations.
    private func writeState(_ state: State) -> Bool {
        let url = rootURL.appendingPathComponent(Self.stateFileName)
        do {
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            return true
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "writeState", "the state file could not be written, generation: [\(state.generation)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return false
        }
    }

    /// `Countly.dat`, when it exists and decodes. One that does not decode is not
    /// taken over: replacing readable request files with nothing loses the queue.
    private func readLegacyFile() -> LegacyFile? {
        guard let data = try? Data(contentsOf: legacyURL) else { return nil }

        do {
            guard let root = try CountlyArchive.decodeRoot(from: data) as? [String: Any] else {
                logger?.d(Self.module, "load", "the legacy file does not hold a request queue and is ignored, dataSize: [\(data.count)]")
                return nil
            }
            return LegacyFile(requests: root[PersistencyKey.queuedRequests] as? [String] ?? [],
                              token: root[PersistencyKey.queueMirrorToken] as? String)
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "load", "the legacy file could not be decoded and is ignored, dataSize: [\(data.count)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return nil
        }
    }

    /// Removes a file or directory, treating one that is already gone as removed.
    @discardableResult
    private func removeItem(_ url: URL, _ what: String) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            let failure = error as NSError
            logger?.d(Self.module, "removeItem", "\(what) could not be removed, path: [\(url.lastPathComponent)], errorDomain: [\(failure.domain)], errorCode: [\(failure.code)], error: [\(failure.localizedDescription)]")
            return false
        }
    }
}
