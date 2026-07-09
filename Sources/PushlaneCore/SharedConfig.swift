import Foundation
#if canImport(Security)
import Security
#endif

/// Cross-process configuration shared between the app and its
/// NotificationServiceExtension via the shared **App Group** Keychain.
///
/// The NSE runs in a SEPARATE process and never sees the app's runtime
/// `Pushlane.shared` state. To emit the `received` deliverability event from the NSE
/// we persist the minimum it needs (ingest base URL, tenant, write-key, the
/// current external id + APNs env) into the App Group at `Pushlane.configure` /
/// `Pushlane.identify`, and read it back in the NSE.
public struct PushlaneSharedConfig: Codable, Sendable, Equatable {
    public var apiBase: URL
    public var tenantId: String
    public var publishableKey: String?
    /// The id last passed to `Pushlane.identify` — required to attribute `received`.
    public var externalId: String?
    public var environment: ApnsEnvironment?
    /// Install source detected by the app (the NSE can't reliably detect its own) so the
    /// `received` event carries the same TestFlight/App Store signal as `track` events.
    public var installSource: InstallSource?

    public init(
        apiBase: URL,
        tenantId: String,
        publishableKey: String? = nil,
        externalId: String? = nil,
        environment: ApnsEnvironment? = nil,
        installSource: InstallSource? = nil
    ) {
        self.apiBase = apiBase
        self.tenantId = tenantId
        self.publishableKey = publishableKey
        self.externalId = externalId
        self.environment = environment
        self.installSource = installSource
    }
}

/// Reads/writes `PushlaneSharedConfig` for the app ⇄ NSE handoff. The app and the
/// NSE must use the SAME App Group id (`Pushlane.configure(appGroup:)` == the NSE's
/// `pushlaneAppGroup`). No-ops cleanly when the store can't be opened.
///
/// L15 — the config carries the publishable key and the external id, so it now
/// lives in the **Keychain** (generic password, `kSecAttrAccessGroup` = the App
/// Group id, `AfterFirstUnlock` so the NSE can read it for pushes that arrive
/// while the device is locked) instead of a cleartext plist. iOS lets App Group
/// ids double as Keychain access groups, so the existing App Group entitlement
/// on both targets is enough — no integrator change required.
///
/// Migration is transparent and one-way: a value still sitting in the legacy
/// App Group `UserDefaults` is read once, promoted to the Keychain, and the
/// plist copy is deleted. Writes are **fail-closed**: when the Keychain is
/// unavailable (missing entitlement, transient error) the config is simply NOT
/// persisted — never written back to the cleartext plist. Losing the NSE
/// `received` event until a Keychain write succeeds beats leaving the
/// publishable key readable on disk.
public enum PushlaneAppGroupStore {
    // legacy keys kept across the Loop→Pushlane rebrand (device identity continuity) — do not change
    static let key = "com.loop.sdk.sharedConfig.v1"
    static let keychainService = "com.loop.sdk.sharedConfig"

    public static func save(_ config: PushlaneSharedConfig, appGroup: String) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        // L15 — the legacy cleartext copy is retired unconditionally: after a
        // save, the only acceptable resting place for the key is the Keychain.
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: key)
        // Fail closed: on Keychain failure the config is not persisted at all
        // (`keychainWrite` logs the OSStatus). `load` then comes up empty and
        // the next `Pushlane.configure`/`identify` retries the write.
        _ = keychainWrite(data, appGroup: appGroup)
    }

    public static func load(appGroup: String) -> PushlaneSharedConfig? {
        if let data = keychainRead(appGroup: appGroup) {
            return try? JSONDecoder().decode(PushlaneSharedConfig.self, from: data)
        }
        // One-time transparent migration from the legacy UserDefaults plist.
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: key) else { return nil }
        if keychainWrite(data, appGroup: appGroup) {
            defaults.removeObject(forKey: key) // only once safely in the Keychain
        }
        return try? JSONDecoder().decode(PushlaneSharedConfig.self, from: data)
    }

    public static func clear(appGroup: String) {
        keychainDelete(appGroup: appGroup)
        UserDefaults(suiteName: appGroup)?.removeObject(forKey: key)
    }

    // MARK: Keychain plumbing (generic password shared via the App Group)

    #if canImport(Security)
    private static func baseQuery(appGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: appGroup,
            // Force the iOS-style data-protection keychain on macOS too, so
            // access-group semantics are identical across both platforms.
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func keychainWrite(_ data: Data, appGroup: String) -> Bool {
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(baseQuery(appGroup: appGroup) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(appGroup: appGroup)
            add[kSecValueData as String] = data
            // AfterFirstUnlock: the NSE must read this while the device is locked
            // (pushes arrive any time after first unlock). Never synchronized to
            // iCloud (default), so the key stays on-device.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess {
            // L15 — never fall back to cleartext. Status code only, no values;
            // -34018 (errSecMissingEntitlement) means the App Group is missing
            // from the target's Keychain/App Groups entitlements.
            PushlaneLog.error("Shared-config Keychain write failed (OSStatus \(status)) — config not persisted, cleartext fallback refused.")
        }
        return status == errSecSuccess
    }

    private static func keychainRead(appGroup: String) -> Data? {
        var query = baseQuery(appGroup: appGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func keychainDelete(appGroup: String) {
        SecItemDelete(baseQuery(appGroup: appGroup) as CFDictionary)
    }
    #else
    private static func keychainWrite(_ data: Data, appGroup: String) -> Bool { false }
    private static func keychainRead(appGroup: String) -> Data? { nil }
    private static func keychainDelete(appGroup: String) {}
    #endif
}
