import XCTest
@testable import LoopCore

final class LoopCoreTests: XCTestCase {

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
        XCTAssertEqual(ctx["sdk"] as? String, "loop-ios")
    }
}
