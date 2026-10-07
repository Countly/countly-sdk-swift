//
//  CountlySwiftSDKMigration.m
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

// For an application going back from the Countly Swift SDK to countly-sdk-ios.
//
// The Swift SDK keeps its request queue in "CountlyRequests.sqlite", which
// countly-sdk-ios does not read. Add this file to the application target and the
// queue moves into "Countly.dat" as the application loads, before countly-sdk-ios
// reads it, so no request recorded under the Swift SDK is lost. There is nothing
// to call and nothing to set up. Once the queue has moved, a launch only finds
// that the database is gone. While the Swift SDK is still linked, nothing runs.
//
// SQLite is linked through the module import below, which Xcode does by default.
// A target that turns modules off (CLANG_ENABLE_MODULES) adds libsqlite3.tbd.
//
// Define COUNTLY_MIGRATION_NO_AUTORUN to choose the moment yourself, calling
// +[CountlySwiftSDKMigration migrateRequestQueue] before starting countly-sdk-ios.

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <sqlite3.h>

@interface CountlySwiftSDKMigration : NSObject

/// Moves the queue in the directory countly-sdk-ios keeps its files in. See
/// +migrateRequestQueueInDirectory:.
+ (BOOL)migrateRequestQueue;

/// Moves the Swift SDK's queue in `directory` into the "Countly.dat" there, in
/// front of the requests that file already holds.
///
/// Returns YES when nothing is left to move, and NO when a file could not be read
/// or written now. Everything is then left as it was, for the next launch to try
/// again. Running it again after it moved the queue changes nothing.
+ (BOOL)migrateRequestQueueInDirectory:(NSURL *)directory;

/// Whether the Swift SDK is linked into this process, in which case its queue is
/// where it belongs and nothing is moved at load.
+ (BOOL)isSwiftSDKLinked;

@end

/// Where countly-sdk-ios keeps its queue.
static NSString *const kLegacyFileName = @"Countly.dat";
static NSString *const kQueueKey = @"kCountlyQueuedRequestsPersistencyKey";

/// Where the Swift SDK keeps its queue, and the schema of that database it writes.
static NSString *const kDatabaseFileName = @"CountlyRequests.sqlite";
static NSString *const kPendingFileName = @"CountlyRequests.pending";
static const sqlite3_int64 kSchemaVersion = 1;

@implementation CountlySwiftSDKMigration

#ifndef COUNTLY_MIGRATION_NO_AUTORUN
/// Runs before main, and so before countly-sdk-ios can read its queue.
+ (void)load
{
    @autoreleasepool
    {
        if (!self.isSwiftSDKLinked)
        {
            [self migrateRequestQueue];
        }
    }
}
#endif

+ (BOOL)isSwiftSDKLinked
{
    // The Swift SDK's CountlyInstance class, by its runtime name.
    return NSClassFromString(@"_TtC7Countly15CountlyInstance") != nil;
}

+ (BOOL)migrateRequestQueue
{
    return [self migrateRequestQueueInDirectory:self.storageDirectory];
}

/// The directory both SDKs keep their files in: Application Support, Caches on
/// tvOS, and on macOS a folder named after the bundle identifier inside it.
+ (NSURL *)storageDirectory
{
#if TARGET_OS_TV
    NSSearchPathDirectory directory = NSCachesDirectory;
#else
    NSSearchPathDirectory directory = NSApplicationSupportDirectory;
#endif
    NSURL *url = [NSFileManager.defaultManager URLsForDirectory:directory inDomains:NSUserDomainMask].lastObject;
    if (!url)
    {
        url = [NSURL fileURLWithPath:NSTemporaryDirectory()];
    }
#if TARGET_OS_OSX
    NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (bundleIdentifier)
    {
        url = [url URLByAppendingPathComponent:bundleIdentifier];
    }
#endif
    return url;
}

+ (BOOL)migrateRequestQueueInDirectory:(NSURL *)directory
{
    NSURL *databaseURL = [directory URLByAppendingPathComponent:kDatabaseFileName];
    NSURL *pendingURL = [directory URLByAppendingPathComponent:kPendingFileName];
    NSURL *legacyURL = [directory URLByAppendingPathComponent:kLegacyFileName];

    NSFileManager *fileManager = NSFileManager.defaultManager;
    BOOL hasDatabase = [fileManager fileExistsAtPath:databaseURL.path];
    if (!hasDatabase && ![fileManager fileExistsAtPath:pendingURL.path])
        return YES;

    sqlite3 *database = NULL;
    NSMutableArray<NSString *> *queue = NSMutableArray.new;
    NSMutableDictionary<NSString *, NSString *> *meta = NSMutableDictionary.new;
    NSString *foldedPendingToken = nil;

    NSString *failure = hasDatabase ? [self openDatabase:&database at:databaseURL readingRowsInto:queue meta:meta] : nil;
    if (!failure)
    {
        failure = [self foldPendingFile:pendingURL into:queue meta:meta token:&foldedPendingToken];
    }
    if (!failure)
    {
        failure = [self mergeLegacyFile:legacyURL into:queue meta:meta];
    }
    if (!failure)
    {
        failure = [self writeLegacyFile:legacyURL queue:queue];
    }
    if (failure)
    {
        sqlite3_close(database);
        return [self failed:failure];
    }

    if (database)
    {
        // Emptied before it goes, so a database that could not be removed gives nothing twice.
        [self emptyDatabase:database recordingPendingToken:foldedPendingToken];
        sqlite3_close(database);
    }
    for (NSString *suffix in @[@"", @"-wal", @"-shm"])
    {
        [fileManager removeItemAtPath:[databaseURL.path stringByAppendingString:suffix] error:NULL];
    }
    [fileManager removeItemAtURL:pendingURL error:NULL];

    NSLog(@"[Countly] The request queue of the Countly Swift SDK is moved into Countly.dat for countly-sdk-ios, requestCount: [%lu]", (unsigned long)queue.count);
    return YES;
}

/// Opens the Swift SDK's database and reads its rows, oldest first, and its meta
/// values. Opened for writing as well, since only then does SQLite bring in what
/// its log holds.
///
/// Returns why it could not, or nil.
+ (NSString *)openDatabase:(sqlite3 **)database at:(NSURL *)url readingRowsInto:(NSMutableArray<NSString *> *)rows meta:(NSMutableDictionary<NSString *, NSString *> *)meta
{
    if (sqlite3_open_v2(url.fileSystemRepresentation, database, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK)
        return [self describe:*database doing:@"opening the database"];

    __block sqlite3_int64 version = 0;
    NSString *failure = [self query:"PRAGMA user_version" in:*database doing:@"reading the schema version" eachRow:^(sqlite3_stmt *statement) {
        version = sqlite3_column_int64(statement, 0);
    }];
    if (failure)
        return failure;
    if (version > kSchemaVersion)
        return [NSString stringWithFormat:@"the database was written by a later Swift SDK, schemaVersion: [%lld], a later version of this file reads it", version];
    // A database whose schema was never committed holds no queue.
    if (version < kSchemaVersion)
        return nil;

    failure = [self query:"SELECT body FROM requests ORDER BY seq" in:*database doing:@"reading the requests" eachRow:^(sqlite3_stmt *statement) {
        NSString *body = [self text:statement column:0];
        if (body)
        {
            [rows addObject:body];
        }
    }];
    if (failure)
        return failure;

    return [self query:"SELECT key, value FROM meta" in:*database doing:@"reading the meta values" eachRow:^(sqlite3_stmt *statement) {
        NSString *key = [self text:statement column:0];
        NSString *value = [self text:statement column:1];
        if (key && value)
        {
            meta[key] = value;
        }
    }];
}

/// Adds what the pending file holds that the database does not. The Swift SDK
/// writes it when the database cannot take the queue: from its crash handler, or
/// on a launch that could not read the database yet.
///
/// A pending file written from the queue these rows were committed from holds all
/// of that queue and replaces it. Any other one names the highest sequence that was
/// on disk already, and only its requests after that which the queue does not hold
/// are added. One the database names was folded in before, and adds nothing, and
/// so does one that does not decode.
///
/// Returns why it could not, or nil.
+ (NSString *)foldPendingFile:(NSURL *)url into:(NSMutableArray<NSString *> *)queue meta:(NSDictionary<NSString *, NSString *> *)meta token:(NSString * __autoreleasing *)foldedToken
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
        return nil;

    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data)
        return [NSString stringWithFormat:@"the pending file cannot be read now, error: [%@]", error.localizedDescription];

    NSDictionary *pending = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:NULL];
    NSString *token = [self value:pending key:@"token" ofClass:NSString.class];
    NSArray *entries = [self value:pending key:@"queue" ofClass:NSArray.class];
    if (!token || !entries || [token isEqualToString:meta[@"pending_token"]])
        return nil;

    long long durableMaxSequence = [[self value:pending key:@"durableMaxSequence" ofClass:NSNumber.class] longLongValue];
    NSMutableArray<NSString *> *all = NSMutableArray.new;
    NSMutableArray<NSString *> *unsaved = NSMutableArray.new;
    for (id entry in entries)
    {
        NSString *request = [self value:entry key:@"request" ofClass:NSString.class];
        NSNumber *sequence = [self value:entry key:@"sequence" ofClass:NSNumber.class];
        if (!request || !sequence)
            continue;

        [all addObject:request];
        if (sequence.longLongValue > durableMaxSequence)
        {
            [unsaved addObject:request];
        }
    }

    NSString *lineage = meta[@"lineage"];
    if (lineage && [lineage isEqual:[self value:pending key:@"lineage" ofClass:NSString.class]])
    {
        [queue setArray:all];
    }
    else
    {
        [queue addObjectsFromArray:[self requests:unsaved notIn:queue]];
    }
    *foldedToken = token;
    return nil;
}

/// Adds the requests an existing "Countly.dat" holds that the queue does not, after
/// the queue: countly-sdk-ios wrote them after the Swift SDK's last commit. A file
/// the Swift SDK already took its requests from, which the database names by its
/// digest, adds nothing, and so does one that does not decode.
///
/// Returns why it could not, or nil.
+ (NSString *)mergeLegacyFile:(NSURL *)url into:(NSMutableArray<NSString *> *)queue meta:(NSDictionary<NSString *, NSString *> *)meta
{
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
        return nil;

    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&error];
    if (!data)
        return [NSString stringWithFormat:@"Countly.dat cannot be read now, error: [%@]", error.localizedDescription];

    if ([[self sha256Hex:data] isEqualToString:meta[@"legacy_digest"]])
        return nil;

    NSSet *classes = [NSSet setWithObjects:NSDictionary.class, NSArray.class, NSString.class, nil];
    NSDictionary *root = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:NULL];
    NSMutableArray<NSString *> *requests = NSMutableArray.new;
    for (id request in [self value:root key:kQueueKey ofClass:NSArray.class])
    {
        if ([request isKindOfClass:NSString.class])
        {
            [requests addObject:request];
        }
    }
    [queue addObjectsFromArray:[self requests:requests notIn:queue]];
    return nil;
}

/// Archives `queue` into "Countly.dat" the way countly-sdk-ios does.
///
/// Returns why it could not, or nil.
+ (NSString *)writeLegacyFile:(NSURL *)url queue:(NSArray<NSString *> *)queue
{
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:@{kQueueKey: queue} requiringSecureCoding:NO error:&error];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic error:&error])
        return [NSString stringWithFormat:@"Countly.dat could not be written, error: [%@]", error.localizedDescription];

    return nil;
}

/// Removes every row, and records the pending file folded in, so a database that
/// outlives this run moves nothing again. Forgets the digest of the "Countly.dat"
/// the Swift SDK merged as well: the file written now can have the same bytes, and
/// holds requests this database no longer does.
+ (void)emptyDatabase:(sqlite3 *)database recordingPendingToken:(NSString *)token
{
    if (sqlite3_exec(database, "BEGIN IMMEDIATE; DELETE FROM requests; DELETE FROM meta WHERE key = 'legacy_digest';", NULL, NULL, NULL) != SQLITE_OK)
    {
        sqlite3_exec(database, "ROLLBACK", NULL, NULL, NULL);
        return;
    }

    if (token)
    {
        sqlite3_stmt *statement = NULL;
        if (sqlite3_prepare_v2(database, "INSERT OR REPLACE INTO meta (key, value) VALUES ('pending_token', ?)", -1, &statement, NULL) == SQLITE_OK)
        {
            sqlite3_bind_text(statement, 1, token.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_step(statement);
        }
        sqlite3_finalize(statement);
    }

    if (sqlite3_exec(database, "COMMIT", NULL, NULL, NULL) != SQLITE_OK)
    {
        sqlite3_exec(database, "ROLLBACK", NULL, NULL, NULL);
    }
}

/// The requests of `requests` the queue does not hold, in their order, told apart
/// by body. A request's body carries its timestamp, so two different ones do not
/// match.
+ (NSArray<NSString *> *)requests:(NSArray<NSString *> *)requests notIn:(NSArray<NSString *> *)queue
{
    NSCountedSet<NSString *> *held = [NSCountedSet.alloc initWithArray:queue];
    NSMutableArray<NSString *> *missing = NSMutableArray.new;
    for (NSString *request in requests)
    {
        if ([held countForObject:request] > 0)
        {
            [held removeObject:request];
        }
        else
        {
            [missing addObject:request];
        }
    }
    return missing;
}

/// Runs `sql` and calls `eachRow` for every row it returns.
///
/// Returns why it could not, or nil.
+ (NSString *)query:(const char *)sql in:(sqlite3 *)database doing:(NSString *)what eachRow:(void (^)(sqlite3_stmt *statement))eachRow
{
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(database, sql, -1, &statement, NULL) != SQLITE_OK)
        return [self describe:database doing:what];

    int result;
    while ((result = sqlite3_step(statement)) == SQLITE_ROW)
    {
        eachRow(statement);
    }
    sqlite3_finalize(statement);
    return result == SQLITE_DONE ? nil : [self describe:database doing:what];
}

/// A text column of the current row, or nil for NULL.
+ (NSString *)text:(sqlite3_stmt *)statement column:(int)column
{
    const unsigned char *text = sqlite3_column_text(statement, column);
    if (!text)
        return nil;

    return [NSString.alloc initWithBytes:text length:(NSUInteger)sqlite3_column_bytes(statement, column) encoding:NSUTF8StringEncoding];
}

/// `dictionary[key]` when `dictionary` is a dictionary and the value is of `class`.
+ (id)value:(id)dictionary key:(NSString *)key ofClass:(Class)class
{
    if (![dictionary isKindOfClass:NSDictionary.class])
        return nil;

    id value = dictionary[key];
    return [value isKindOfClass:class] ? value : nil;
}

/// Lowercase hex SHA-256 of `data`, the digest the Swift SDK names a merged
/// "Countly.dat" by.
+ (NSString *)sha256Hex:(NSData *)data
{
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
    {
        [hex appendFormat:@"%02x", digest[index]];
    }
    return hex;
}

/// What SQLite says went wrong.
+ (NSString *)describe:(sqlite3 *)database doing:(NSString *)what
{
    if (!database)
        return [NSString stringWithFormat:@"%@ failed, error: [out of memory]", what];

    return [NSString stringWithFormat:@"%@ failed, sqliteCode: [%d], error: [%@]", what, sqlite3_extended_errcode(database), @(sqlite3_errmsg(database))];
}

/// Logs why the queue is not moved yet, and answers NO.
+ (BOOL)failed:(NSString *)reason
{
    NSLog(@"[Countly] The request queue of the Countly Swift SDK is not moved yet, and is tried again on the next launch, reason: %@", reason);
    return NO;
}

@end
