// swift-tools-version:5.9

import PackageDescription

let package = Package(

    name: "Countly",

    platforms:
    [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v9),
        .visionOS(.v1)
    ],

    products:
    [
        .library(
            name: "Countly",
            targets: ["Countly"]),
        .library(
            name: "CountlyNotificationService",
            targets: ["CountlyNotificationService"]),
    ],

    targets:
    [
        .target(
            name: "Countly",
            dependencies: [],
            path: "Sources/Countly",

            linkerSettings:
            [
                .linkedFramework("Foundation"),
                .linkedFramework("UIKit", .when(platforms: [.iOS, .tvOS, .visionOS])),
                .linkedFramework("WatchKit", .when(platforms: [.watchOS])),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("UserNotifications", .when(platforms: [.iOS, .macOS, .visionOS])),
                .linkedFramework("CoreLocation"),
                .linkedFramework("WebKit", .when(platforms: [.iOS, .visionOS, .macOS])),
                .linkedFramework("CoreTelephony", .when(platforms: [.iOS])),
                .linkedLibrary("sqlite3"),
            ]),

        .target(
            name: "CountlyNotificationService",
            dependencies: [],
            path: "Sources/CountlyNotificationService"),

        // The file an application going back to countly-sdk-ios adds to its own
        // target. No product ships it; it is built here for the tests.
        .target(
            name: "CountlySwiftSDKMigration",
            dependencies: [],
            path: "Migration",
            cSettings: [.define("COUNTLY_MIGRATION_NO_AUTORUN")],
            linkerSettings: [.linkedLibrary("sqlite3")]),

        .testTarget(
            name: "CountlyTests",
            dependencies: ["Countly", "CountlySwiftSDKMigration"],
            path: "Tests/CountlyTests"
        ),

        .testTarget(
            name: "CountlyObjCTests",
            dependencies: ["Countly"],
            path: "Tests/CountlyObjCTests"
        ),
    ]
)
