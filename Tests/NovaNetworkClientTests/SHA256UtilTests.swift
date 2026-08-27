import Foundation
import Testing
@testable import NovaNetworkClient
// PortableSHA256 is internal to NovaNetworkCore, and @testable on the client does not reach it.
// The suite exercising it directly only compiles where CryptoKit is absent, which is why this was
// invisible until the tests ran on Linux.
@testable import NovaNetworkCore

// Requirements: FR-LINUX-1 (SHA256Util produces identical digests regardless of which
// implementation branch -- CryptoKit or the Linux-only PortableSHA256 -- is compiled in).

@Suite
struct SHA256UtilTests {
    @Test
    func hexOfEmptyStringMatchesTheNISTTestVector() {
        #expect(SHA256Util.hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test
    func hexOfAbcMatchesTheNISTTestVector() {
        #expect(SHA256Util.hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func hexOfTheStandardTwoBlockMessageMatchesTheNISTTestVector() {
        let message = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        #expect(SHA256Util.hex(message) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test
    func hexOfOneMillionRepeatedCharactersMatchesTheNISTTestVector() {
        let message = String(repeating: "a", count: 1_000_000)
        #expect(SHA256Util.hex(message) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test
    func hexIsDeterministicForTheSameInput() {
        let first = SHA256Util.hex("some fingerprint input")
        let second = SHA256Util.hex("some fingerprint input")
        #expect(first == second)
    }

    @Test
    func hexDiffersForDifferentInputs() {
        #expect(SHA256Util.hex("a") != SHA256Util.hex("b"))
    }

    @Test
    func hexOfFileAtURLMatchesHexOfItsContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Larger than one chunk, to exercise multi-read streaming.
        let content = Data((0..<200_000).map { UInt8($0 % 251) })
        let fileURL = directory.appendingPathComponent("payload.bin")
        try content.write(to: fileURL)

        let expected = SHA256Util.hex(content)
        let actual = try SHA256Util.hex(fileAt: fileURL, chunkSize: 4_096)
        #expect(actual == expected)
    }
}

#if !canImport(CryptoKit)
@Suite
struct PortableSHA256Tests {
    @Test
    func matchesTheNISTTestVectorsDirectly() {
        var empty = PortableSHA256()
        empty.update(Data())
        #expect(empty.finalizeHex() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        var abc = PortableSHA256()
        abc.update(Data("abc".utf8))
        #expect(abc.finalizeHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test
    func incrementalUpdatesProduceTheSameDigestAsOneShot() {
        var streamed = PortableSHA256()
        streamed.update(Data("ab".utf8))
        streamed.update(Data("c".utf8))

        var oneShot = PortableSHA256()
        oneShot.update(Data("abc".utf8))

        #expect(streamed.finalizeHex() == oneShot.finalizeHex())
    }

    @Test
    func updatesAtNonBlockAlignedBoundariesStillProduceTheCorrectDigest() {
        let message = String(repeating: "a", count: 1_000_000)
        let bytes = Array(message.utf8)
        var hasher = PortableSHA256()
        var index = 0
        let oddChunkSize = 17
        while index < bytes.count {
            let end = min(index + oddChunkSize, bytes.count)
            hasher.update(Data(bytes[index..<end]))
            index = end
        }
        #expect(hasher.finalizeHex() == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
#endif
