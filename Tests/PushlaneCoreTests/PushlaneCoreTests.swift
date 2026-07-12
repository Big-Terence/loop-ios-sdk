import XCTest
@testable import PushlaneCore

final class PushlaneCoreTests: XCTestCase {

    // MARK: MurmurHash3 cross-language parity (must match TS @loop/contracts + Go)
    func testMurmur3CanonicalVectors() {
        XCTAssertEqual(Murmur3.hash32(""), 0)
        XCTAssertEqual(Murmur3.hash32("", seed: 1), 0x514e_28b7)
        XCTAssertEqual(Murmur3.hash32("test"), 0xba6b_d213)
        XCTAssertEqual(Murmur3.hash32("Hello, world!"), 0xc036_3e43)
        XCTAssertEqual(Murmur3.hash32("The quick brown fox jumps over the lazy dog"), 0x2e4f_f723)
    }

    func testAssignVariantDeterministicAndDistributed() {
        let variants: [(key: String, weightBp: UInt32)] = [("A", 5000), ("B", 5000)]
        let v1 = Murmur3.assignVariant("exp-x", "user-7", variants)
        let v2 = Murmur3.assignVariant("exp-x", "user-7", variants)
        XCTAssertEqual(v1, v2) // stable per user
        var countA = 0
        for i in 0..<2000 where Murmur3.assignVariant("exp-x", "u\(i)", variants) == "A" { countA += 1 }
        XCTAssert(countA > 850 && countA < 1150, "expected ~1000 in A, got \(countA)")
    }

    // MARK: APNs environment auto-detection (the TestFlight-correct path)
    func testApsEnvironmentParsingFromEmbeddedPlist() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict>
          <key>Entitlements</key>
          <dict><key>aps-environment</key><string>production</string></dict>
        </dict></plist>
        """
        // simulate the CMS wrapper: binary noise around the embedded plist
        var blob = Data([0x30, 0x82, 0x01, 0x02, 0x00, 0xff])
        blob.append(plist.data(using: .utf8)!)
        blob.append(Data([0x00, 0x01, 0x02]))
        XCTAssertEqual(ProvisioningProfile.apsEnvironment(from: blob), "production")
        XCTAssertEqual(ProvisioningProfile.environment(forApsValue: "production"), .production)
        XCTAssertEqual(ProvisioningProfile.environment(forApsValue: "development"), .sandbox)
        XCTAssertEqual(ProvisioningProfile.environment(forApsValue: nil), .sandbox)
    }

    // MARK: Session boundary (30s background→foreground = new IAM session)
    func testSessionRotation() {
        var s = SessionManager()
        let first = s.sessionId
        let t0 = Date()
        s.didEnterBackground(at: t0)
        XCTAssertFalse(s.willEnterForeground(at: t0.addingTimeInterval(10))) // quick switch
        XCTAssertEqual(s.sessionId, first)
        s.didEnterBackground(at: t0)
        XCTAssertTrue(s.willEnterForeground(at: t0.addingTimeInterval(45))) // > 30s
        XCTAssertNotEqual(s.sessionId, first)
    }

    // MARK: Envelope encodes to the exact backend shape
    func testEnvelopeEncoding() throws {
        let env = EventEnvelope(
            tenantId: "00000000-0000-0000-0000-0000000000aa",
            externalId: "user_alice",
            name: "workout_completed",
            properties: ["duration": 42, "premium": true, "tags": .array([.string("run")])],
            context: EventContext(environment: .production, tzIana: "Europe/Paris")
        )
        let data = try JSONEncoder().encode(env)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["name"] as? String, "workout_completed")
        XCTAssertEqual(obj["externalId"] as? String, "user_alice")
        XCTAssertNotNil(obj["eventId"]) // generated at origin (R2)
        let tp = obj["traceparent"] as! String
        XCTAssert(tp.hasPrefix("00-") && tp.hasSuffix("-01")) // W3C (R3)
        let props = obj["properties"] as! [String: Any]
        XCTAssertEqual(props["duration"] as? Int, 42)
        XCTAssertEqual(props["premium"] as? Bool, true)
        let ctx = obj["context"] as! [String: Any]
        XCTAssertEqual(ctx["environment"] as? String, "production")
        XCTAssertEqual(ctx["tzIana"] as? String, "Europe/Paris")
        XCTAssertEqual(ctx["sdk"] as? String, "pushlane-ios")
    }

    // MARK: Write-key → Authorization: Bearer on /v1/events and /v1/register (A2)
    func testTransportSendsAuthorizationHeaderOnEvents() throws {
        let req = try captureRequest { transport in
            let env = EventEnvelope(
                tenantId: "t", externalId: "u", name: "received",
                context: EventContext()
            )
            transport.send(env)
        }
        XCTAssertEqual(req.url?.path, "/v1/events")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer lpk_test123")
    }

    func testTransportSendsAuthorizationHeaderOnRegister() throws {
        let req = try captureRequest { transport in
            transport.register(externalId: "u", deviceToken: "deadbeef", environment: .production)
        }
        XCTAssertEqual(req.url?.path, "/v1/register")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer lpk_test123")
    }

    func testTransportOmitsAuthHeaderWithoutKey() throws {
        let req = try captureRequest(publishableKey: nil) { transport in
            transport.send(EventEnvelope(tenantId: "t", externalId: "u", name: "x", context: EventContext()))
        }
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization")) // back-compat: unauthenticated
    }

    /// Drive a Transport through a stub URLProtocol and return the request it sent.
    private func captureRequest(
        publishableKey: String? = "lpk_test123",
        _ body: (Transport) -> Void
    ) throws -> URLRequest {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CapturingProtocol.self]
        let session = URLSession(configuration: config)
        let exp = expectation(description: "request captured")
        CapturingProtocol.captured = nil
        CapturingProtocol.onCapture = { exp.fulfill() }
        defer { CapturingProtocol.onCapture = nil }
        let transport = Transport(
            config: PushlaneConfig(apiBase: URL(string: "https://ingest.example.com")!,
                               tenantId: "t", publishableKey: publishableKey),
            session: session
        )
        body(transport)
        wait(for: [exp], timeout: 5)
        return try XCTUnwrap(CapturingProtocol.captured)
    }

    // MARK: App Group shared config (app ⇄ NSE) — Keychain-only, fail-closed (L15)
    // `swift test` runs without a Keychain access-group entitlement — exactly the
    // failure mode L15 guards against: save must persist NOTHING in cleartext.
    func testSharedConfigSaveNeverWritesCleartext() throws {
        let suite = "test.loop.sdk.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cfg = PushlaneSharedConfig(
            apiBase: URL(string: "https://ingest.example.com")!,
            tenantId: "tenant-1", publishableKey: "lpk_abc",
            externalId: "user_alice", environment: .production
        )
        PushlaneAppGroupStore.save(cfg, appGroup: suite)
        // Whatever the Keychain verdict, the key must never rest in the plist.
        XCTAssertNil(UserDefaults(suiteName: suite)?.data(forKey: PushlaneAppGroupStore.key))
        // Unentitled process ⇒ fail closed; an entitled one must round-trip faithfully.
        if let loaded = PushlaneAppGroupStore.load(appGroup: suite) {
            XCTAssertEqual(loaded, cfg)
        }
        PushlaneAppGroupStore.clear(appGroup: suite)
        XCTAssertNil(PushlaneAppGroupStore.load(appGroup: suite))
    }

    // A value written by a pre-Keychain SDK must still be readable (transparent
    // migration) and removable via `clear`.
    func testSharedConfigLegacyPlistStillLoads() throws {
        let suite = "test.loop.sdk.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let cfg = PushlaneSharedConfig(
            apiBase: URL(string: "https://ingest.example.com")!,
            tenantId: "tenant-1", publishableKey: "lpk_abc",
            externalId: "user_alice", environment: .production
        )
        UserDefaults(suiteName: suite)?.set(try JSONEncoder().encode(cfg), forKey: PushlaneAppGroupStore.key)
        let loaded = try XCTUnwrap(PushlaneAppGroupStore.load(appGroup: suite))
        XCTAssertEqual(loaded, cfg)
        PushlaneAppGroupStore.clear(appGroup: suite)
        XCTAssertNil(PushlaneAppGroupStore.load(appGroup: suite))
    }

    // MARK: NSE `received` envelope built cross-process from payload + shared config
    func testReceivedEnvelopeFromPayload() throws {
        let cfg = PushlaneSharedConfig(
            apiBase: URL(string: "https://ingest.example.com")!,
            tenantId: "tenant-1", publishableKey: "lpk_abc",
            externalId: "user_alice", environment: .production
        )
        let userInfo: [AnyHashable: Any] = [
            "message_id": "msg-1", "flow_id": "flow-1", "node_id": "node-1",
            "aps": ["alert": ["title": "hi"]],
        ]
        let env = try XCTUnwrap(Pushlane.receivedEnvelope(userInfo: userInfo, config: cfg))
        XCTAssertEqual(env.name, "received")
        XCTAssertEqual(env.externalId, "user_alice")
        XCTAssertEqual(env.tenantId, "tenant-1")
        XCTAssertEqual(env.properties["message_id"], .string("msg-1"))
        XCTAssertEqual(env.properties["flow_id"], .string("flow-1"))
        XCTAssertEqual(env.properties["node_id"], .string("node-1"))
        XCTAssertEqual(env.context.environment, .production)
    }

    // MARK: Consent — opt-out model (POST /v1/consent with category + action)

    func testConsentOptOutPostsCorrectPayload() throws {
        let req = try captureRequest { transport in
            transport.sendConsent(externalId: "user_alice", category: "marketing", optedIn: false)
        }
        XCTAssertEqual(req.url?.path, "/v1/consent")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer lpk_test123")
        let body = try XCTUnwrap(requestBody(req))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj["externalId"], "user_alice")
        XCTAssertEqual(obj["category"], "marketing")
        XCTAssertEqual(obj["action"], "opt_out")
    }

    func testConsentOptInPostsCorrectAction() throws {
        let req = try captureRequest { transport in
            transport.sendConsent(externalId: "user_alice", category: "marketing", optedIn: true)
        }
        XCTAssertEqual(req.url?.path, "/v1/consent")
        let body = try XCTUnwrap(requestBody(req))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(obj["action"], "opt_in")
    }

    func testConsentSendsAuthorizationHeader() throws {
        let req = try captureRequest { transport in
            transport.sendConsent(externalId: "user_bob", category: "marketing", optedIn: false)
        }
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer lpk_test123")
    }

    func testConsentOmitsAuthHeaderWithoutKey() throws {
        let req = try captureRequest(publishableKey: nil) { transport in
            transport.sendConsent(externalId: "user_bob", category: "marketing", optedIn: false)
        }
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: setAttributes — POST /v1/attributes (user personalisation)

    func testSetAttributesPostsToCorrectEndpointWithAuthHeader() throws {
        let req = try captureRequest { transport in
            transport.sendAttributes(externalId: "user_alice", attributes: [
                "first_name": "Alice",
                "plan": "scale",
                "trial": true,
            ])
        }
        XCTAssertEqual(req.url?.path, "/v1/attributes")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer lpk_test123")
        let body = try XCTUnwrap(requestBody(req))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["externalId"] as? String, "user_alice")
        XCTAssertEqual(obj["tenantId"] as? String, "t")
        let attrs = try XCTUnwrap(obj["attributes"] as? [String: Any])
        XCTAssertEqual(attrs["first_name"] as? String, "Alice")
        XCTAssertEqual(attrs["plan"] as? String, "scale")
        XCTAssertEqual(attrs["trial"] as? Bool, true)
    }

    func testSetAttributesOmitsAuthHeaderWithoutKey() throws {
        let req = try captureRequest(publishableKey: nil) { transport in
            transport.sendAttributes(externalId: "user_alice", attributes: ["x": 1])
        }
        XCTAssertEqual(req.url?.path, "/v1/attributes")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: Pending-consent store — an explicit opt-out survives until acked (invariant)

    func testPendingConsentRecordReplayClear() throws {
        let uid = "user_\(UUID().uuidString)"
        defer { PendingConsentStore.clear(externalId: uid, category: "marketing", ifAction: "opt_in")
                PendingConsentStore.clear(externalId: uid, category: "marketing", ifAction: "opt_out") }

        // Recorded and readable (this is what replay-after-register consumes).
        PendingConsentStore.record(externalId: uid, category: "marketing", action: "opt_out")
        XCTAssertEqual(PendingConsentStore.pending(externalId: uid), ["marketing": "opt_out"])

        // A stale ack of a superseded choice must NOT clear the newer pending one.
        PendingConsentStore.record(externalId: uid, category: "marketing", action: "opt_in")
        PendingConsentStore.clear(externalId: uid, category: "marketing", ifAction: "opt_out")
        XCTAssertEqual(PendingConsentStore.pending(externalId: uid), ["marketing": "opt_in"])

        // Acking the current choice clears it.
        PendingConsentStore.clear(externalId: uid, category: "marketing", ifAction: "opt_in")
        XCTAssertTrue(PendingConsentStore.pending(externalId: uid).isEmpty)
    }

    /// URLSession moves `httpBody` to `httpBodyStream` inside URLProtocol handlers.
    /// This helper reads from either source so body-inspection tests stay readable.
    private func requestBody(_ req: URLRequest) -> Data? {
        if let data = req.httpBody { return data }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 4096)
            if n > 0 { data.append(buf, count: n) } else { break }
        }
        return data.isEmpty ? nil : data
    }

    func testReceivedEnvelopeNilWithoutIdentity() {
        let cfg = PushlaneSharedConfig(
            apiBase: URL(string: "https://ingest.example.com")!,
            tenantId: "tenant-1", externalId: nil
        )
        // No identified user ⇒ nothing to attribute ⇒ no event (best-effort).
        XCTAssertNil(Pushlane.receivedEnvelope(userInfo: ["message_id": "m"], config: cfg))
    }
}

/// Captures the outgoing URLRequest of a Transport POST for header assertions.
final class CapturingProtocol: URLProtocol {
    nonisolated(unsafe) static var captured: URLRequest?
    nonisolated(unsafe) static var onCapture: (() -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured = request
        Self.onCapture?()
        let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
