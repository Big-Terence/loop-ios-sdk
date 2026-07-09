import Foundation

/// MurmurHash3 x86 32-bit — MUST be bit-identical to the TS (`@loop/contracts/hash`)
/// and Go implementations so a user lands in the same A/B variant on every tier.
/// Operates on the UTF-8 bytes of the key. Verified against the canonical vectors
/// in the test target.
public enum Murmur3 {
    public static func hash32(_ key: String, seed: UInt32 = 0) -> UInt32 {
        let data = Array(key.utf8)
        let len = data.count
        let c1: UInt32 = 0xcc9e_2d51
        let c2: UInt32 = 0x1b87_3593
        var h1 = seed
        let nblocks = len & ~3

        var i = 0
        while i < nblocks {
            var k1 = UInt32(data[i])
                | (UInt32(data[i + 1]) << 8)
                | (UInt32(data[i + 2]) << 16)
                | (UInt32(data[i + 3]) << 24)
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
            h1 = (h1 << 13) | (h1 >> 19)
            h1 = h1 &* 5 &+ 0xe654_6b64
            i += 4
        }

        var k1: UInt32 = 0
        let tail = len & 3
        if tail == 3 { k1 ^= UInt32(data[nblocks + 2]) << 16 }
        if tail >= 2 { k1 ^= UInt32(data[nblocks + 1]) << 8 }
        if tail >= 1 {
            k1 ^= UInt32(data[nblocks])
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
        }

        h1 ^= UInt32(len)
        h1 ^= h1 >> 16
        h1 = h1 &* 0x85eb_ca6b
        h1 ^= h1 >> 13
        h1 = h1 &* 0xc2b2_ae35
        h1 ^= h1 >> 16
        return h1
    }

    /// Deterministic basis-point bucket in [0,10000) for an (experimentId, unit) pair.
    public static func bucketBp(_ experimentId: String, _ unit: String) -> UInt32 {
        hash32("\(experimentId):\(unit)") % 10000
    }

    /// Stable variant assignment — variants consumed in order with cumulative bp.
    public static func assignVariant(_ experimentId: String, _ unit: String, _ variants: [(key: String, weightBp: UInt32)]) -> String? {
        guard !variants.isEmpty else { return nil }
        let point = bucketBp(experimentId, unit)
        var cumulative: UInt32 = 0
        for v in variants {
            cumulative &+= v.weightBp
            if point < cumulative { return v.key }
        }
        return variants.last?.key
    }
}
