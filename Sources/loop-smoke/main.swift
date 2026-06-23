import Foundation
import LoopCore

// End-to-end smoke: exercises the REAL SDK code path (Loop.configure → identify →
// registerDeviceToken → track → Transport → HTTP) against a running Ingest Worker.
// Usage: swift run loop-smoke [apiBase] [tenantId] [externalId]

let args = CommandLine.arguments
let apiBase = URL(string: args.count > 1 ? args[1] : "http://localhost:8787")!
let tenantId = args.count > 2 ? args[2] : "00000000-0000-0000-0000-0000000000aa"
let externalId = args.count > 3 ? args[3] : "sdk_smoke_user"

print("[loop-smoke] apiBase=\(apiBase) tenant=\(tenantId) externalId=\(externalId)")

Loop.configure(apiBase: apiBase, tenantId: tenantId)
Loop.identify(externalId)
print("[loop-smoke] detected APNs environment: \(Loop.shared.currentEnvironment.rawValue)")

// 1) register a (fake) device token — proves the /v1/register subscription path.
var token = Data(count: 32)
token.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
Loop.shared.registerDeviceToken(token)

// 2) track a real event — proves register→event→flow→send via the SDK.
Loop.track("workout_completed", ["duration": 25, "type": "run"])

// Transport posts are fire-and-forget (URLSession dataTask); keep the CLI alive so
// the requests complete before exit.
print("[loop-smoke] sent register + workout_completed; waiting for delivery…")
Thread.sleep(forTimeInterval: 5)
print("[loop-smoke] done — verify the subscription (Supabase) + event/trace (ClickHouse).")
