import Foundation

/// Configuration handed to `Loop.configure`.
public struct LoopConfig: Sendable {
    /// Base URL of the Ingest Worker, e.g. http://localhost:8787 (dev) or the
    /// deployed Workers URL.
    public var apiBase: URL
    public var tenantId: String
    /// Publishable write-key (`lpk_…`) shown in the dashboard. When set, it is sent
    /// as `Authorization: Bearer <key>` on `/v1/events` and `/v1/register` so the
    /// worker can authenticate ingestion (A2). Optional for back-compat.
    public var publishableKey: String?
    /// App Group id shared with the NotificationServiceExtension. When set, the SDK
    /// mirrors the ingest config into App Group `UserDefaults` so the NSE (a
    /// separate process) can emit the `received` event. See README → "received".
    public var appGroup: String?

    public init(
        apiBase: URL,
        tenantId: String,
        publishableKey: String? = nil,
        appGroup: String? = nil
    ) {
        self.apiBase = apiBase
        self.tenantId = tenantId
        self.publishableKey = publishableKey
        self.appGroup = appGroup
    }
}

/// Posts envelopes to the Ingest Worker. JSON-encodes the canonical EventEnvelope
/// and POSTs to `/v1/events`. A failed send is retried with bounded backoff.
public final class Transport: @unchecked Sendable {
    private let config: LoopConfig
    private let session: URLSession
    private let encoder: JSONEncoder

    public init(config: LoopConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
        self.encoder = JSONEncoder()
    }

    public func send(_ envelope: EventEnvelope) {
        guard let body = try? encoder.encode(envelope) else { return }
        var req = URLRequest(url: config.apiBase.appendingPathComponent("v1/events"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(envelope.traceparent, forHTTPHeaderField: "traceparent")
        authorize(&req)
        req.httpBody = body
        post(req, attempt: 0)
    }

    /// Registers/updates a device subscription (token + auto-detected environment).
    public func register(externalId: String, deviceToken: String, environment: ApnsEnvironment) {
        let payload: [String: String] = [
            "tenantId": config.tenantId,
            "externalId": externalId,
            "deviceToken": deviceToken,
            "pushEnvironment": environment.rawValue,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var req = URLRequest(url: config.apiBase.appendingPathComponent("v1/register"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req)
        req.httpBody = body
        post(req, attempt: 0)
    }

    /// Attach the publishable write-key as `Authorization: Bearer <key>` (A2). No-op
    /// when no key is configured (back-compat: unauthenticated ingestion).
    private func authorize(_ req: inout URLRequest) {
        guard let key = config.publishableKey, !key.isEmpty else { return }
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private func post(_ req: URLRequest, attempt: Int) {
        session.dataTask(with: req) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let transient = error != nil || status >= 500 || status == 429
            if transient && attempt < 4 {
                let delay = pow(2.0, Double(attempt)) * 0.5
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self?.post(req, attempt: attempt + 1)
                }
            }
        }.resume()
    }
}
