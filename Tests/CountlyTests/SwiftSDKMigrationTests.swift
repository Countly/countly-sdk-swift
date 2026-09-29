//
//  SwiftSDKMigrationTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import SQLite3
import XCTest
import CountlySwiftSDKMigration
@testable import Countly

/// `Migration/CountlySwiftSDKMigration.m`, the one file an application going back
/// to countly-sdk-ios adds: it moves this SDK's queue into the `Countly.dat` that SDK
/// reads, loses nothing, and brings nothing back twice.
///
/// Each test writes the files with this SDK on a named namespace, then moves them,
/// under the names the default instance gives them, into a directory of its own,
/// where the migration runs as it would on the application's storage directory.
final class SwiftSDKMigrationTests: CountlyBaseTestCase {

    private var directory: URL!
    private var namespace: StorageNamespace!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CountlySwiftSDKMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        namespace = StorageNamespace(instanceName: uniqueInstanceName())
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        if let namespace {
            RequestQueueStore(namespace: namespace, logger: nil).deleteFile()
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// The files of the default instance's queue in the test's directory.
    private var files: RequestQueueDatabase.Files {
        RequestQueueDatabase.Files(namespace: .default, directory: directory)
    }

    /// Runs `body` on a store of the test's namespace, then saves and closes it, as
    /// the end of the process would.
    private func withStore(_ body: (RequestQueueStore) throws -> Void) rethrows {
        let store = RequestQueueStore(namespace: namespace, logger: nil)
        try body(store)
        store.saveSync()
    }

    /// Appends a request with the name `name`.
    private func enqueue(_ store: RequestQueueStore, _ name: String) {
        store.enqueue("app_key=k&n=\(name)", appVersion: "1.0", trackingEnabled: true)
    }

    /// A request named `name` under `sequence`.
    private func request(_ sequence: Int64, _ name: String) -> QueuedRequest {
        QueuedRequest(sequence: sequence, request: "app_key=k&n=\(name)")
    }

    /// Moves the test namespace's queue files into the test's directory.
    private func moveFilesIntoDirectory() throws {
        let source = queueFiles(namespace)
        let pairs = Array(zip(RequestQueueDatabase.sqliteFiles(of: source.database), RequestQueueDatabase.sqliteFiles(of: files.database)))
            + [(source.pending, files.pending), (source.legacy, files.legacy)]
        for (from, to) in pairs where FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// Runs the migration on the test's directory.
    @discardableResult
    private func migrate() -> Bool {
        CountlySwiftSDKMigration.migrateRequestQueue(inDirectory: directory)
    }

    /// Archives `requests` into the test directory's `Countly.dat`, as countly-sdk-ios
    /// saves its queue.
    private func writeCountlyDat(_ requests: [String]) throws {
        try NSKeyedArchiver.archivedData(withRootObject: [PersistencyKey.queuedRequests: requests], requiringSecureCoding: false)
            .write(to: files.legacy, options: .atomic)
    }

    /// The queue countly-sdk-ios finds in the test's directory.
    private func legacyQueue() throws -> [String] {
        let root = try CountlyArchive.decodeRoot(from: Data(contentsOf: files.legacy)) as? [String: Any]
        return try XCTUnwrap(root?[PersistencyKey.queuedRequests] as? [String], "Countly.dat holds no queue")
    }

    /// The files of this SDK's queue still in the test's directory.
    private func swiftFilesLeft() -> [String] {
        (RequestQueueDatabase.sqliteFiles(of: files.database) + [files.pending])
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.lastPathComponent)
    }

    // MARK: - Tests

    /// The queue as this SDK last held it is what countly-sdk-ios finds, and none of
    /// this SDK's files is left.
    func testTheQueueMovesIntoCountlyDatAndTheDatabaseGoes() throws {
        var queued: [String] = []
        try withStore { store in
            for index in 0..<3 {
                enqueue(store, "\(index)")
            }
            store.removeHead(try XCTUnwrap(store.head))
            queued = store.snapshot
        }
        try moveFilesIntoDirectory()

        XCTAssertTrue(migrate())
        XCTAssertEqual(try legacyQueue(), queued)
        XCTAssertEqual(swiftFilesLeft(), [], "a file of this SDK's queue was left behind")
    }

    /// Once the queue has moved, a launch changes nothing.
    func testRunningAgainChangesNothing() throws {
        withStore { enqueue($0, "0") }
        try moveFilesIntoDirectory()
        XCTAssertTrue(migrate())
        let moved = try Data(contentsOf: files.legacy)

        XCTAssertTrue(migrate())
        XCTAssertEqual(try Data(contentsOf: files.legacy), moved)
    }

    /// Without this SDK's files there is nothing to move, and the queue of
    /// countly-sdk-ios is not touched.
    func testWithoutTheSwiftSDKsFilesNothingIsTouched() throws {
        try LegacyStorageMigrationTests.legacyQueueFile.write(to: files.legacy)

        XCTAssertTrue(migrate())
        XCTAssertEqual(try Data(contentsOf: files.legacy), LegacyStorageMigrationTests.legacyQueueFile)
    }

    /// countly-sdk-ios may have run before the file was added, and queued requests
    /// of its own. They are kept, after this SDK's, which are older.
    func testTheQueueGoesInFrontOfWhatCountlySDKiOSQueuedMeanwhile() throws {
        var queued: [String] = []
        withStore { store in
            enqueue(store, "0")
            enqueue(store, "1")
            queued = store.snapshot
        }
        try moveFilesIntoDirectory()
        try LegacyStorageMigrationTests.legacyQueueFile.write(to: files.legacy)
        let queuedByObjC = try legacyQueue()
        XCTAssertEqual(queuedByObjC.count, 3)

        XCTAssertTrue(migrate())
        XCTAssertEqual(try legacyQueue(), queued + queuedByObjC)
    }

    /// A `Countly.dat` whose removal failed after this SDK merged it adds nothing: a
    /// request this SDK sent since does not come back.
    func testACountlyDatThisSDKAlreadyMergedAddsNothing() throws {
        try LegacyStorageMigrationTests.legacyQueueFile.write(to: legacyQueueFileURL(namespace))
        var remaining: [String] = []
        try withStore { store in
            store.removeHead(try XCTUnwrap(store.head))
            remaining = store.snapshot
        }
        XCTAssertEqual(remaining.count, 2)
        try LegacyStorageMigrationTests.legacyQueueFile.write(to: legacyQueueFileURL(namespace))
        try moveFilesIntoDirectory()

        XCTAssertTrue(migrate())
        XCTAssertEqual(try legacyQueue(), remaining)
    }

    /// The pending file the crash handler writes holds the whole queue of the rows
    /// it was written from, and replaces them.
    func testAPendingFileFromTheCrashHandlerIsFoldedIn() throws {
        do {
            let database = RequestQueueDatabase(namespace: namespace, logger: nil)
            XCTAssertNotNil(database.attach(skippingPendingFile: nil))
            let lineage = try XCTUnwrap(database.sync([request(1, "0"), request(2, "1")], pendingToken: nil))
            // The head was sent, and a crash report queued.
            XCTAssertNotNil(database.writePendingFile([request(2, "1"), request(3, "crash")], lineage: lineage, durableMaxSequence: 2, replacing: []))
        }
        try moveFilesIntoDirectory()

        XCTAssertTrue(migrate())
        XCTAssertEqual(TestUtils.names(try legacyQueue()), ["1", "crash"])
        XCTAssertEqual(swiftFilesLeft(), [])
    }

    /// A pending file written by a launch that could not read the database adds the
    /// requests that launch queued, after the rows.
    func testAPendingFileFromALaunchThatCouldNotReadTheDatabaseIsFoldedIn() throws {
        do {
            let database = RequestQueueDatabase(namespace: namespace, logger: nil)
            XCTAssertNotNil(database.attach(skippingPendingFile: nil))
            XCTAssertNotNil(database.sync([request(1, "0"), request(2, "1")], pendingToken: nil))
            XCTAssertNotNil(database.writePendingFile([request(1, "meanwhile")], lineage: nil, durableMaxSequence: 0, replacing: []))
        }
        try moveFilesIntoDirectory()

        XCTAssertTrue(migrate())
        XCTAssertEqual(TestUtils.names(try legacyQueue()), ["0", "1", "meanwhile"])
    }

    /// A pending file whose removal failed after this SDK folded it in adds nothing:
    /// its lineage still matches the rows, but the database names its token.
    func testAPendingFileThisSDKAlreadyFoldedInAddsNothing() throws {
        do {
            let database = RequestQueueDatabase(namespace: namespace, logger: nil)
            XCTAssertNotNil(database.attach(skippingPendingFile: nil))
            let lineage = try XCTUnwrap(database.sync([request(1, "0"), request(2, "1")], pendingToken: nil))
            let atTheCrash = [request(2, "1"), request(3, "crash")]
            let token = try XCTUnwrap(database.writePendingFile(atTheCrash, lineage: lineage, durableMaxSequence: 2, replacing: []))
            let leftover = try Data(contentsOf: pendingFileURL(namespace))

            // The next launch folds it in and commits its token, then sends a request.
            XCTAssertNotNil(database.sync(atTheCrash, pendingToken: token))
            XCTAssertNotNil(database.sync([request(3, "crash")], pendingToken: nil))
            try leftover.write(to: pendingFileURL(namespace))
        }
        try moveFilesIntoDirectory()

        XCTAssertTrue(migrate())
        XCTAssertEqual(TestUtils.names(try legacyQueue()), ["crash"], "a request already sent came back from a pending file already folded in")
    }

    /// A database that cannot be read now, as data protection leaves it on a locked
    /// device, leaves every file as it was, and the next launch moves the queue.
    func testADatabaseThatCannotBeReadNowLeavesEverythingAsItWas() throws {
        withStore { enqueue($0, "0") }
        try moveFilesIntoDirectory()
        try writeCountlyDat(["app_key=k&n=queued-by-objc"])
        let before = try Data(contentsOf: files.legacy)

        try setPermissions(0o000, files.database)
        defer { try? setPermissions(0o644, files.database) }
        XCTAssertFalse(migrate())
        XCTAssertEqual(try Data(contentsOf: files.legacy), before)

        try setPermissions(0o644, files.database)
        XCTAssertTrue(migrate())
        XCTAssertEqual(TestUtils.names(try legacyQueue()), ["0", "queued-by-objc"])
    }

    /// A database a later version of this SDK wrote may hold a schema this file does
    /// not know, and is left as it was.
    func testADatabaseOfALaterSchemaIsLeftAsItWas() throws {
        withStore { enqueue($0, "0") }
        try moveFilesIntoDirectory()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(files.database.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = 2", nil, nil, nil), SQLITE_OK)
        sqlite3_close_v2(database)

        XCTAssertFalse(migrate())
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.legacy.path))
    }

    /// Coming back to this SDK after countly-sdk-ios sent part of the moved queue
    /// brings back only what it did not send.
    func testThisSDKReadsTheMovedQueueBack() throws {
        withStore { store in
            enqueue(store, "0")
            enqueue(store, "1")
        }
        try moveFilesIntoDirectory()
        XCTAssertTrue(migrate())

        let moved = try legacyQueue()
        try writeCountlyDat([moved[1], "app_key=k&n=queued-by-objc"])
        try FileManager.default.moveItem(at: files.legacy, to: legacyQueueFileURL(namespace))

        let store = openStore(namespace)
        XCTAssertEqual(TestUtils.names(store.snapshot), ["1", "queued-by-objc"])
        store.saveSync()
        XCTAssertEqual(TestUtils.names(databaseRows(namespace)), ["1", "queued-by-objc"])
    }

    /// The migration does nothing at load while this SDK is linked, which it tells by
    /// the runtime name of `CountlyInstance`.
    func testTheMigrationKnowsThisSDKIsLinked() {
        XCTAssertTrue(CountlySwiftSDKMigration.isSwiftSDKLinked(), "CountlyInstance is no longer found by the name the migration file looks for")
    }
}
