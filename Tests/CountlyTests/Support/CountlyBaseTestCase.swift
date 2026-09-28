//
//  CountlyBaseTestCase.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import SQLite3
import XCTest
@testable import Countly

/// Base class for every suite that starts an SDK instance.
///
/// Each test gets its own uniquely named instance, so its storage namespace, its
/// request queue and its device ID belong to that test alone and nothing leaks into
/// the next one. That is only possible because this SDK is per instance rather than
/// a process-wide singleton; the reference SDK's tests have to purge shared state
/// between cases instead.
///
/// Every started instance is halted with `clearStorage: true` in `tearDown`, which
/// deletes the queue file and the `UserDefaults` keys the test wrote.
class CountlyBaseTestCase: XCTestCase {

    static let appKey = "appkey"
    static let deviceID = "deviceId"
    static let host = "https://testing.count.ly"

    /// Started instances, halted in reverse order at the end of the test.
    private var started: [CountlyInstance] = []

    /// Request queue stores the test opened itself. Each deletes its files in
    /// `tearDown`, so a sync it still has queued cannot write a file back later.
    private var openedStores: [RequestQueueStore] = []

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        for instance in started.reversed() {
            instance.halt(clearStorage: true)
        }
        started.removeAll()
        for store in openedStores {
            store.deleteFile()
        }
        openedStores.removeAll()
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Instances

    /// A configuration pointing at the mock transport, with the values every test
    /// wants: a fixed device ID so requests are comparable, debug logging so a
    /// failing test says why, and no consent requirement.
    func baseConfig(instanceName: String? = nil) -> CountlyConfig {
        let config = CountlyConfig()
        config.appKey = Self.appKey
        config.host = Self.host
        config.deviceID = Self.deviceID
        config.instanceName = instanceName ?? uniqueInstanceName()
        config.enableDebug = true
        config.internalLogLevel = .error
        config.urlSessionConfiguration = MockURLProtocol.sessionConfiguration()
        // Automatic sessions would put a `begin_session` at the head of every
        // queue and shift every index a test asserts on. Suites that are about
        // sessions turn this back off.
        config.manualSessionHandling = true
        return config
    }

    /// Starts an instance for `config` and schedules its teardown.
    @discardableResult
    func start(_ config: CountlyConfig) -> CountlyInstance {
        let instance = Countly.instance(named: config.instanceName)
        instance.start(with: config)
        started.append(instance)
        return instance
    }

    /// Starts an instance with the base configuration, optionally adjusted.
    @discardableResult
    func startInstance(_ adjust: (CountlyConfig) -> Void = { _ in }) -> CountlyInstance {
        let config = baseConfig()
        adjust(config)
        return start(config)
    }

    /// A name no other test in the process uses, derived from the test itself so a
    /// failure log says which test owned the storage.
    func uniqueInstanceName() -> String {
        let sanitized = name.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-",
                                                  options: .regularExpression)
        return "\(sanitized)-\(instanceCounter())"
    }

    private static let counterLock = NSLock()
    private static var counter = 0

    private func instanceCounter() -> Int {
        Self.counterLock.lock()
        defer { Self.counterLock.unlock() }
        Self.counter += 1
        return Self.counter
    }

    // MARK: - Platform capabilities

    /// Whether `MockURLProtocol` actually intercepts what the SDK sends.
    ///
    /// watchOS does not honour custom `URLProtocol` subclasses: `URLSession` there
    /// ignores `protocolClasses` and goes to the network regardless. A suite that
    /// asserts on what reached the mock would not fail on watchOS so much as
    /// measure the runner's DNS, so those tests are skipped rather than left to
    /// produce a result that means nothing.
    ///
    /// Everything that asserts on the request queue instead of on the transport
    /// runs on every platform, which is the large majority of the suite.
    static var canInterceptNetwork: Bool {
        #if os(watchOS)
        return false
        #else
        return true
        #endif
    }

    /// Skips the calling test where the transport cannot be intercepted.
    func skipUnlessNetworkIsInterceptable() throws {
        try XCTSkipUnless(Self.canInterceptNetwork,
                          "watchOS ignores custom URLProtocol subclasses, so nothing reaches the mock transport")
    }

    // MARK: - Reaching inside

    /// The instance's core. Every internal assertion goes through this.
    func core(of instance: CountlyInstance) -> SDKCore {
        guard let core = instance.requireCore() else {
            XCTFail("the instance has no core; it was never started or has been halted")
            fatalError("unreachable, XCTFail above stops the test")
        }
        return core
    }

    /// Every request this instance has queued but not yet had accepted.
    func requestQueue(of instance: CountlyInstance) -> [String] {
        core(of: instance).requestQueueStore.snapshot
    }

    // MARK: - Request queue files

    /// Opens a request queue store on `namespace`, deleted with its files at the
    /// end of the test.
    func openStore(_ namespace: StorageNamespace, mirrorsLegacyFile: Bool? = nil) -> RequestQueueStore {
        let store = RequestQueueStore(namespace: namespace, logger: nil, mirrorsLegacyFile: mirrorsLegacyFile)
        openedStores.append(store)
        return store
    }

    /// The files of a namespace's request queue, as the SDK names them.
    func queueFiles(_ namespace: StorageNamespace) -> RequestQueueDatabase.Files {
        RequestQueueDatabase.Files(namespace: namespace, directory: StorageLocation.directoryURL(logger: nil))
    }

    /// A namespace's `Countly.dat`, where the Objective-C SDK keeps its queue.
    func legacyQueueFileURL(_ namespace: StorageNamespace) -> URL {
        queueFiles(namespace).legacy
    }

    /// A namespace's request queue database.
    func databaseURL(_ namespace: StorageNamespace) -> URL {
        queueFiles(namespace).database
    }

    /// Where a namespace's queue goes when its database cannot take it.
    func pendingFileURL(_ namespace: StorageNamespace) -> URL {
        queueFiles(namespace).pending
    }

    /// Replaces a namespace's database with bytes SQLite cannot read, as a fault on
    /// disk would leave it.
    func corruptDatabase(_ namespace: StorageNamespace) throws {
        for file in RequestQueueDatabase.sqliteFiles(of: databaseURL(namespace)) {
            try? FileManager.default.removeItem(at: file)
        }
        try Data(repeating: 0xAB, count: 8192).write(to: databaseURL(namespace))
    }

    /// Makes a namespace's database unreadable, as data protection does on a locked
    /// device, until the returned closure is called or the test ends.
    @discardableResult
    func makeDatabaseUnreadable(_ namespace: StorageNamespace) throws -> () throws -> Void {
        let database = databaseURL(namespace)
        let restore = { try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: database.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: database.path)
        addTeardownBlock { try? restore() }
        return restore
    }

    /// The requests committed in a namespace's database, in queue order, read over
    /// a connection of the test's own. What a process killed right now would find.
    func databaseRows(_ namespace: StorageNamespace, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        var database: OpaquePointer?
        defer { sqlite3_close_v2(database) }
        guard sqlite3_open_v2(databaseURL(namespace).path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            XCTFail("the database could not be opened", file: file, line: line)
            return []
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT body FROM requests ORDER BY seq", -1, &statement, nil) == SQLITE_OK else {
            XCTFail("the requests could not be read: \(String(cString: sqlite3_errmsg(database)))", file: file, line: line)
            return []
        }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(String(cString: sqlite3_column_text(statement, 0)))
        }
        return rows
    }

    /// Sets the POSIX permissions of a file or directory.
    func setPermissions(_ permissions: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Reports a crash to one instance the way the signal handler does: the
    /// report is stored for the next launch and nothing is sent.
    func reportAutoDetectedCrash(on instance: CountlyInstance,
                                 name: String = "SIGSEGV",
                                 reason: String = "boom",
                                 stackTrace: [String] = ["0 MyApp 0x1 boom"]) {
        core(of: instance).modules.crashes.handleAutoDetectedCrash(name: name, reason: reason, stackTrace: stackTrace)
    }
}
