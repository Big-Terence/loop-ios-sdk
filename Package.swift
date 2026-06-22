// swift-tools-version: 5.9
import PackageDescription

// Loop iOS SDK — the Superwall of push. iOS 16+ (SPM). LoopCore is pure Foundation
// (so it builds + `swift test`s on macOS); LoopPush/LoopInApp/LoopNotificationService
// guard their iOS-only UIKit/UserNotifications APIs with #if canImport(UIKit).
let package = Package(
    name: "LoopSDK",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "LoopCore", targets: ["LoopCore"]),
        .library(name: "LoopPush", targets: ["LoopPush"]),
        .library(name: "LoopInApp", targets: ["LoopInApp"]),
        .library(name: "LoopNotificationService", targets: ["LoopNotificationService"]),
    ],
    targets: [
        .target(name: "LoopCore"),
        .target(name: "LoopPush", dependencies: ["LoopCore"]),
        .target(name: "LoopInApp", dependencies: ["LoopCore"]),
        .target(name: "LoopNotificationService"),
        // Dev-only end-to-end smoke: drives the real SDK code (Transport) against
        // a running Ingest Worker. `swift run loop-smoke <apiBase> <tenantId>`.
        .executableTarget(name: "loop-smoke", dependencies: ["LoopCore"]),
        .testTarget(name: "LoopCoreTests", dependencies: ["LoopCore"]),
    ]
)
