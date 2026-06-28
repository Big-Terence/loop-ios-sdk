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
                   tenantId: "<your-tenant-id>",
                   publishableKey: "lpk_…",            // write-key from the dashboard (auth)
                   appGroup: "group.com.yourapp.loop") // shared with your NSE (received event)
    Loop.identify(currentUser.id)        // your stable external id (R1)
    LoopInApp.start()                    // emits `app_open` (cold launch) + tracks IAM sessions
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

`publishableKey` and `appGroup` are **optional** (back-compatible): omit them and
ingestion stays unauthenticated and the `received` event is simply not emitted.

### Write-key (auth)

Copy your publishable key (`lpk_…`) from **Settings → Install SDK** and pass it as
`publishableKey`. The SDK sends it as `Authorization: Bearer lpk_…` on every
`/v1/events` and `/v1/register` request so the worker can authenticate ingestion.
It is a *publishable* key (safe to ship in the app), not a secret.

### Events: `app_open`, sessions, custom

`LoopInApp.start()` emits an **`app_open`** event once per cold launch. Separately,
returning to the foreground after ≥30s in the background rotates the IAM session and
emits **`session_started`** — the two never double-count (a cold launch is not a
foreground-return). On push tap the SDK emits **`opened`** (see below).

Track your own events with typed values (the backend coerces against the catalogue,
it never infers from the first value — R6):

```swift
Loop.track("lesson_finished", ["lesson_id": "intro-1", "duration_sec": 42])
```

See **Recommended event catalogue** below for a ready-to-paste taxonomy.

## NotificationServiceExtension (rich media + `received`)

Create a separate NSE target (suffixed bundle id, shared App Group) and subclass.
Override `loopAppGroup` with the **same** App Group id you passed to
`Loop.configure(appGroup:)`:

```swift
import LoopNotificationService
class NotificationService: LoopNotificationService {
    override var loopAppGroup: String? { "group.com.yourapp.loop" }
}
```

The NSE does two things:

- Downloads `image_url`/`loop_media`, fixes the attachment file extension, and calls
  `contentHandler` on **every** branch (so a push never silently degrades).
- Emits a **`received`** event the moment the push lands — *delivery* tracking,
  independent of whether the user opens it. `received` carries the same
  `message_id`/`flow_id`/`node_id` as `opened`, so both attribute to the same send;
  pairing them gives you a true open-rate (`opened ÷ received`).

### App Group setup (required for `received`)

The NSE runs in a **separate process** and can't see the app's runtime state, so the
app mirrors the ingest config (base URL, tenant, write-key, current user) into an App
Group at `Loop.configure`/`Loop.identify`, and the NSE reads it back. To wire it:

1. In **Signing & Capabilities**, add the **App Groups** capability to **both** the
   app target and the NSE target, with the **same** group id (e.g.
   `group.com.yourapp.loop`).
2. Pass that id as `Loop.configure(appGroup:)` (app) and `loopAppGroup` (NSE).
3. Add `LoopNotificationService` to the NSE target only.

Without an App Group the NSE still renders rich media — it just won't emit `received`.
`received` is best-effort and **never blocks** the notification from showing.

## RevenueCat: use the same user id

Loop attributes RevenueCat revenue events (`trial_started`, `subscription_started`,
renewals, cancellations…) to a Loop user **only when RevenueCat's `appUserID` equals
the id you pass to `Loop.identify`**. Use one source of truth for both:

```swift
let uid = Loop.identifyForRevenueCat(currentUser.id)   // == Loop.identify(uid)
Purchases.configure(withAPIKey: "appl_…", appUserID: uid)
// on login: Purchases.shared.logIn(uid)
```

`identifyForRevenueCat` is a thin convenience (no dependency on the RevenueCat SDK) —
it just makes the contract one call site and returns the id to hand RevenueCat. With
the ids in sync, a "trial expiring" push fires off the RevenueCat event automatically.

## Recommended event catalogue

A copy-paste taxonomy so you instrument fast and consistently. The SDK auto-emits
`app_open`, `session_started`, `opened`, `received` and `push_registration_failed`;
the rest are yours to call via `Loop.track`.

| Event | When | Suggested properties |
|---|---|---|
| `open_app` | manual app foreground (if you want it beyond auto `app_open`) | `source` (push/deeplink/organic) |
| `onboarding_started` | first onboarding screen | `variant` |
| `onboarding_completed` | finished onboarding | `duration_sec`, `steps` |
| `signed_up` | account created | `method` (apple/google/email) |
| `logged_in` | session auth | `method` |
| `lesson_finished` | content unit done | `lesson_id`, `duration_sec`, `score` |
| `started_chat` | opened a chat/AI thread | `thread_id` |
| `message_sent` | user sent a message | `thread_id`, `length` |
| `content_created` | user produced an artifact | `type`, `id` |
| `feature_used` | a key feature engaged | `feature`, `count` |
| `paywall_viewed` | paywall shown | `placement`, `paywall_id` |
| `checkout_started` | tapped subscribe | `product_id`, `price` |
| `trial_started` | free trial began (often from RevenueCat) | `product_id`, `trial_days` |
| `subscription_started` | first paid period | `product_id`, `price`, `period` |
| `subscription_renewed` | renewal | `product_id` |
| `subscription_cancelled` | churn signal | `product_id`, `reason` |
| `purchase_completed` | one-off IAP | `product_id`, `price` |

Conventions: `snake_case` names + properties, typed values (`Int`/`Double`/`Bool`/
`String`/array), stable ids (not display labels). Properties are coerced server-side
against your catalogue; unknown props are kept raw, never dropped.

## Why this SDK is different

- **APNs environment auto-detected** at runtime from `embedded.mobileprovision`
  (`ApnsEnvironment.detect()`), shipped with the token — *not* `#if DEBUG`, which
  is wrong on TestFlight (Release build, sandbox APNs). Kills the #1 `BadDeviceToken`
  bug at the source; the debugger checks the token env first.
- **External-id first-class** (`Loop.identify`): one user = many subscriptions,
  deduped server-side (no OneSignal duplicate-user bug).
- **Open-tracking** captures cold-launch-via-tap, foreground and background opens,
  attaching `message_id`/`flow_id`/`node_id` from the payload.
- **Delivery-tracking** from the NSE: a `received` event fires when the push lands
  (separate process, App-Group config), so you get a true open-rate
  (`opened ÷ received`), not just opens.
- **MurmurHash3 bucketing** is bit-identical to the backend (`Murmur3.hash32`),
  so A/B assignment is stable across device and server.

## Install via prompt / MCP

The dashboard's **Settings → Install SDK** screen generates a ready-to-paste prompt
for Cursor/Claude Code and an MCP server that installs the SDK, places event tags,
and verifies the integration live. This package is what that flow installs.

## Test

```bash
swift test            # LoopCore unit tests: parity vectors, env detection, session,
                      # envelope, write-key auth header, App Group config, `received`
```
