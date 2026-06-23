import Foundation

/// APNs routing environment. The #1 dev pain (BadDeviceToken) is sending a
/// sandbox token to the production gateway or vice-versa, so the SDK AUTO-DETECTS
/// the environment at runtime from `embedded.mobileprovision` and ships it with
/// the token — NOT `#if DEBUG`, which is wrong on TestFlight (TestFlight builds
/// are Release but use the SANDBOX APNs environment).
public enum ApnsEnvironment: String, Sendable {
    case sandbox
    case production
}

public enum ProvisioningProfile {
    /// Extract the `aps-environment` entitlement ("development" | "production")
    /// from a raw embedded.mobileprovision blob. The file is a CMS/PKCS7 envelope
    /// wrapping an XML plist; we slice out the plist and read the entitlement.
    public static func apsEnvironment(from data: Data) -> String? {
        guard let plistData = embeddedPlist(in: data),
              let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any],
              let entitlements = dict["Entitlements"] as? [String: Any]
        else { return nil }
        // Modern key is "aps-environment"; some profiles use the namespaced form.
        return (entitlements["aps-environment"] as? String)
            ?? (entitlements["com.apple.developer.aps-environment"] as? String)
    }

    /// Slice the embedded `<plist>…</plist>` out of the signed blob.
    static func embeddedPlist(in data: Data) -> Data? {
        let open = Data("<plist".utf8)
        let close = Data("</plist>".utf8)
        guard let start = data.range(of: open)?.lowerBound,
              let end = data.range(of: close, in: start..<data.endIndex)?.upperBound
        else { return nil }
        return data.subdata(in: start..<end)
    }

    /// Map an aps-environment value to our routing environment.
    public static func environment(forApsValue value: String?) -> ApnsEnvironment {
        // "production" → production gateway; anything else (development/absent) → sandbox.
        value == "production" ? .production : .sandbox
    }

    /// Detect the APNs environment for the running app. Reads
    /// `embedded.mobileprovision` from the bundle; the App Store strips this file,
    /// in which case the entitlement is "production" — so a missing profile means
    /// production. The Simulator has no profile and no real APNs → treated as
    /// sandbox by the caller (no token is produced there anyway).
    public static func detect(bundle: Bundle = .main) -> ApnsEnvironment {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url)
        else {
            // No profile: App Store build (stripped) ⇒ production. The Simulator path
            // is handled by LoopPush (it never registers a real token there).
            return .production
        }
        return environment(forApsValue: apsEnvironment(from: data))
    }
}
