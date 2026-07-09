import Foundation
import PushlaneCore

// End-to-end smoke: exercises the REAL SDK code path (Pushlane.configure → identify →
// registerDeviceToken → track → Transport → HTTP) against a running Ingest Worker.
// Usage: swift run pushlane-smoke [apiBase] [tenantId] [externalId] [publishableKey]

let args = CommandLine.arguments
let apiBase = URL(string: args.count > 1 ? args[1] : "http://localhost:8787")!
let tenantId = args.count > 2 ? args[2] : "00000000-0000-0000-0000-0000000000aa"
let externalId = args.count > 3 ? args[3] : "sdk_smoke_user"
let publishableKey = args.count > 4 ? args[4] : nil // `lpk_…` → Authorization: Bearer (A2)

print("[pushlane-smoke] apiBase=\(apiBase) tenant=\(tenantId) externalId=\(externalId) key=\(publishableKey != nil ? "set" : "none")")

Pushlane.configure(apiBase: apiBase, tenantId: tenantId, publishableKey: publishableKey)
Pushlane.identify(externalId)
print("[pushlane-smoke] detected APNs environment: \(Pushlane.shared.currentEnvironment.rawValue)")

// 1) register a (fake) device token — proves the /v1/register subscription path.
var token = Data(count: 32)
token.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
Pushlane.shared.registerDeviceToken(token)

// 2) track a real event — proves register→event→flow→send via the SDK.
Pushlane.track("workout_completed", ["duration": 25, "type": "run"])

// Transport posts are fire-and-forget (URLSession dataTask); keep the CLI alive so
// the requests complete before exit.
print("[pushlane-smoke] sent register + workout_completed; waiting for delivery…")
Thread.sleep(forTimeInterval: 5)
print("[pushlane-smoke] done — verify the subscription (Supabase) + event/trace (ClickHouse).")
