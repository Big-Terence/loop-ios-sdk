import Foundation

/// Durable, best-effort record of an **explicit** consent choice that has not yet
/// been acknowledged by the backend.
///
/// Why this exists (the sacred invariant): Loop is opt-out by default, so the ONLY
/// way a user's explicit opt-out is honoured is if it reaches the backend as a
/// consent event. But a choice can be made *before* the user exists server-side —
/// e.g. the user toggles marketing OFF during onboarding, before the first
/// `/v1/register` has created the backend user, so `/v1/consent` answers 404. If we
/// dropped it there, `register` would later materialise the user default-opted-in
/// and a flow could deliver to someone who explicitly opted out.
///
/// So every explicit choice is written here first and only removed once the backend
/// acknowledges it (2xx). It survives app restarts and is replayed right after a
/// successful device registration (when the user is guaranteed to exist), so an
/// explicit opt-out is never lost. This is app-process state (registration runs in
/// the app, not the NSE), so plain `UserDefaults` — namespaced — is the right store.
enum PendingConsentStore {
    static let defaultsKey = "com.loop.sdk.pendingConsent"

    private static let lock = NSLock()
    private static var defaults: UserDefaults { .standard }

    /// Record (or overwrite) the latest explicit choice for `externalId`/`category`.
    static func record(externalId: String, category: String, action: String) {
        mutate { root in
            var byCategory = root[externalId] ?? [:]
            byCategory[category] = action
            root[externalId] = byCategory
        }
    }

    /// Remove the pending entry ONLY if it still holds `action`. Guarding on the
    /// action prevents a late ack of a superseded choice (opt_out → opt_in flip
    /// while a retry was in flight) from clearing the newer, still-pending choice.
    static func clear(externalId: String, category: String, ifAction action: String) {
        mutate { root in
            guard var byCategory = root[externalId], byCategory[category] == action else { return }
            byCategory[category] = nil
            root[externalId] = byCategory.isEmpty ? nil : byCategory
        }
    }

    /// The unacknowledged choices for `externalId` as `[category: action]`.
    static func pending(externalId: String) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        return load()[externalId] ?? [:]
    }

    // MARK: storage

    private static func mutate(_ body: (inout [String: [String: String]]) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var root = load()
        body(&root)
        save(root)
    }

    private static func load() -> [String: [String: String]] {
        guard let data = defaults.data(forKey: defaultsKey),
              let obj = try? JSONDecoder().decode([String: [String: String]].self, from: data)
        else { return [:] }
        return obj
    }

    private static func save(_ root: [String: [String: String]]) {
        if root.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(root) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
