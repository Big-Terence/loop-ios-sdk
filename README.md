# Loop iOS SDK

The Superwall of push — native iOS instrumentation for events, attributes, push
registration, open-tracking and rich notifications. iOS 16+, SwiftPM.

`LoopCore` is pure Foundation (builds + `swift test`s on macOS). `LoopPush`,
`LoopInApp` and `LoopNotificationService` guard their UIKit/UserNotifications APIs
with `#if canImport(UIKit)` / `#if os(iOS)`.

## Install (SwiftPM)

```swift
.package(url: "https://github.com/<org>/loop-ios", from: "0.1.0")
// then add the products you need: LoopCore, LoopPush, LoopInApp
// + LoopNotificationService in your NotificationServiceExtension target.
```

## Integrate (AppDelegate)

```swift
import LoopCore
import LoopPush
import LoopInApp

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
    Loop.configure(apiBase: URL(string: "https://ingest.yourapp.com")!,
                   tenantId: "<your-tenant-id>")
    Loop.identify(currentUser.id)        // your stable external id (R1)
    LoopInApp.start()                    // 30s background→foreground = new IAM session
    LoopPush.register()                  // sets the UN delegate BEFORE return → catches cold-launch taps
    return true
}

func application(_ app: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    LoopPush.didRegister(deviceToken: token)   // env auto-detected (sandbox vs prod)
}
func application(_ app: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error) {
    LoopPush.didFailToRegister(error: error)
}
```

Track events (typed values; the backend coerces against the catalogue, never infers):

```swift
Loop.track("workout_completed", ["duration": 42, "type": "run"])
```

## NotificationServiceExtension (rich media)

Create a separate NSE target (suffixed bundle id, shared App Group) and subclass:

```swift
import LoopNotificationService
class NotificationService: LoopNotificationService {}
```

It downloads `image_url`/`loop_media`, fixes the attachment file extension, and
calls `contentHandler` on **every** branch (so a push never silently degrades).

## Why this SDK is different

- **APNs environment auto-detected** at runtime from `embedded.mobileprovision`
  (`ApnsEnvironment.detect()`), shipped with the token — *not* `#if DEBUG`, which
  is wrong on TestFlight (Release build, sandbox APNs). Kills the #1 `BadDeviceToken`
  bug at the source; the debugger checks the token env first.
- **External-id first-class** (`Loop.identify`): one user = many subscriptions,
  deduped server-side (no OneSignal duplicate-user bug).
- **Open-tracking** captures cold-launch-via-tap, foreground and background opens,
  attaching `message_id`/`flow_id`/`node_id` from the payload.
- **MurmurHash3 bucketing** is bit-identical to the backend (`Murmur3.hash32`),
  so A/B assignment is stable across device and server.

## Install via prompt / MCP

The dashboard's **Settings → Install SDK** screen generates a ready-to-paste prompt
for Cursor/Claude Code and an MCP server that installs the SDK, places event tags,
and verifies the integration live. This package is what that flow installs.

## Test

```bash
swift test            # LoopCore unit tests (parity vectors, env detection, session, envelope)
```
