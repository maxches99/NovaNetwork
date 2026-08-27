import Foundation

#if !canImport(CryptoKit)
/// A pure-Swift, dependency-free SHA-256 implementation used only where `CryptoKit` is
/// unavailable (currently Linux). Apple platforms continue to use `CryptoKit.SHA256`, unchanged.
///
/// This exists solely to compute non-secret fingerprint, cache, and idempotency keys — never to
/// protect a secret at rest (the offline queue's optional `AESGCMOfflineWriteStoreCipher` does
/// that, via `CryptoKit`, and remains Apple-only rather than gaining a hand-rolled authenticated
/// cipher). Verified against the NIST SHA-256 test vectors for the empty string, `"abc"`, the
/// 56-character multi-block vector, and one million repeated `"a"` characters, including
/// incremental updates split at non-block-aligned boundaries.
struct PortableSHA256 {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    private var state: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private var buffer = Data()
    private var totalLength: UInt64 = 0

    init() {}

    /// Feeds more bytes into the hash. May be called any number of times before ``finalizeHex()``.
    mutating func update(_ data: Data) {
        totalLength &+= UInt64(data.count)
        buffer.append(data)
        var start = buffer.startIndex
        while buffer.distance(from: start, to: buffer.endIndex) >= 64 {
            let end = buffer.index(start, offsetBy: 64)
            processChunk(buffer[start..<end])
            start = end
        }
        buffer.removeSubrange(buffer.startIndex..<start)
    }

    /// Pads and processes the final block, returning the lowercase hex digest. Consumes `self`.
    mutating func finalizeHex() -> String {
        finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Pads and processes the final block, returning the raw 32-byte digest. Consumes `self`.
    mutating func finalize() -> Data {
        let bitLength = totalLength &* 8
        var padded = buffer
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var offset = padded.startIndex
        while offset < padded.endIndex {
            let end = padded.index(offset, offsetBy: 64)
            processChunk(padded[offset..<end])
            offset = end
        }

        var digest = Data(capacity: 32)
        for word in state {
            digest.append(UInt8((word >> 24) & 0xff))
            digest.append(UInt8((word >> 16) & 0xff))
            digest.append(UInt8((word >> 8) & 0xff))
            digest.append(UInt8(word & 0xff))
        }
        return digest
    }

    private mutating func processChunk(_ chunk: Data.SubSequence) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 {
            let base = chunk.startIndex + i * 4
            w[i] = (UInt32(chunk[base]) << 24)
                | (UInt32(chunk[base + 1]) << 16)
                | (UInt32(chunk[base + 2]) << 8)
                | UInt32(chunk[base + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }

        var a = state[0], b = state[1], c = state[2], d = state[3]
        var e = state[4], f = state[5], g = state[6], h = state[7]

        for i in 0..<64 {
            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
            let ch = (e & f) ^ (~e & g)
            let temp1 = h &+ s1 &+ ch &+ Self.roundConstants[i] &+ w[i]
            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let temp2 = s0 &+ maj

            h = g; g = f; f = e; e = d &+ temp1
            d = c; c = b; b = a; a = temp1 &+ temp2
        }

        state[0] = state[0] &+ a; state[1] = state[1] &+ b
        state[2] = state[2] &+ c; state[3] = state[3] &+ d
        state[4] = state[4] &+ e; state[5] = state[5] &+ f
        state[6] = state[6] &+ g; state[7] = state[7] &+ h
    }

    private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}
#endif
