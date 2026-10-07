//
//  CountlySwiftSDKMigration.h
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

// The interface CountlySwiftSDKMigration.m declares for itself, so this package's
// tests can call it. An application adds only the .m file.

#import <Foundation/Foundation.h>

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
