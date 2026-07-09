// swift-tools-version: 5.9
import PackageDescription

// Pushlane iOS SDK — the Superwall of push. iOS 16+ (SPM). PushlaneCore is pure Foundation
// (so it builds + `swift test`s on macOS); PushlanePush/PushlaneInApp/PushlaneNotificationService
// guard their iOS-only UIKit/UserNotifications APIs with #if canImport(UIKit).
let package = Package(
    name: "PushlaneSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PushlaneCore", targets: ["PushlaneCore"]),
        .library(name: "PushlanePush", targets: ["PushlanePush"]),
        .library(name: "PushlaneInApp", targets: ["PushlaneInApp"]),
        .library(name: "PushlaneNotificationService", targets: ["PushlaneNotificationService"]),
    ],
    targets: [
        .target(name: "PushlaneCore"),
        .target(name: "PushlanePush", dependencies: ["PushlaneCore"]),
        .target(name: "PushlaneInApp", dependencies: ["PushlaneCore"]),
        .target(name: "PushlaneNotificationService", dependencies: ["PushlaneCore"]),
        // Dev-only end-to-end smoke: drives the real SDK code (Transport) against
        // a running Ingest Worker. `swift run pushlane-smoke <apiBase> <tenantId>`.
        .executableTarget(name: "pushlane-smoke", dependencies: ["PushlaneCore"]),
        .testTarget(name: "PushlaneCoreTests", dependencies: ["PushlaneCore"]),
    ]
)
