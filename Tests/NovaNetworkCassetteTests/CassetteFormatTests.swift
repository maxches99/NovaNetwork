import Foundation
import Testing
@testable import NovaNetworkCassette

// Requirements: FR-1 (format and round-trip), FR-2 (text and binary bodies), FR-10/UR-2
// (deterministic, readable output), FR-13/DR-1 (typed errors for unreadable files).
// Tests: T-1.1, T-1.2, T-8.1, T-12.1, T-12.2.

private func temporaryURL(_ name: String = "cassette.json") -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("nova-cassette-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

private let sampleCassette = Cassette(interactions: [
    RecordedInteraction(
        request: RecordedRequest(
            method: "GET",
            url: "https://api.example.com/users/1",
            headers: ["Accept": "application/json"]
        ),
        response: RecordedResponse(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: RecordedBody(data: Data(#"{"id":1,"name":"Ada"}"#.utf8))
        )
    ),
])

@Suite
struct CassetteFormatTests {
    @Test
    func aCassetteRoundTripsThroughDiskUnchanged() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try sampleCassette.write(to: url)
        let loaded = try Cassette.load(from: url)

        #expect(loaded == sampleCassette)
        #expect(loaded.formatVersion == Cassette.currentFormatVersion)
    }

    @Test
    func utf8BodiesAreStoredAsReadableTextRatherThanBase64() throws {
        let serialized = try String(decoding: sampleCassette.serialized(), as: UTF8.self)

        #expect(serialized.contains(#""name":\"Ada\""#) || serialized.contains("Ada"))
        #expect(!serialized.contains("base64"))
        // Slashes stay unescaped so a URL in the file reads like a URL.
        #expect(serialized.contains("https://api.example.com/users/1"))
    }

    @Test
    func binaryBodiesRoundTripThroughBase64() throws {
        let bytes = Data([0x00, 0xFF, 0xFE, 0x01, 0x80])
        let cassette = Cassette(interactions: [
            RecordedInteraction(
                request: RecordedRequest(method: "GET", url: "https://example.com/blob"),
                response: RecordedResponse(status: 200, body: RecordedBody(data: bytes))
            ),
        ])

        let serialized = try cassette.serialized()
        #expect(String(decoding: serialized, as: UTF8.self).contains("base64"))

        let decoded = try JSONDecoder().decode(Cassette.self, from: serialized)
        #expect(decoded.interactions[0].response.body?.data == bytes)
    }

    @Test
    func serializationIsByteIdenticalAcrossSaves() throws {
        #expect(try sampleCassette.serialized() == sampleCassette.serialized())

        let reloaded = try JSONDecoder().decode(Cassette.self, from: sampleCassette.serialized())
        #expect(try reloaded.serialized() == sampleCassette.serialized())
    }

    @Test
    func outputIsPrettyPrintedWithSortedKeysSoDiffsAreReadable() throws {
        let serialized = try String(decoding: sampleCassette.serialized(), as: UTF8.self)
        let versionIndex = try #require(serialized.range(of: "\"version\""))
        let interactionsIndex = try #require(serialized.range(of: "\"interactions\""))

        #expect(serialized.contains("\n"))
        #expect(interactionsIndex.lowerBound < versionIndex.lowerBound, "sorted keys put interactions before version")
        #expect(serialized.hasSuffix("\n"))
    }

    @Test
    func writingCreatesIntermediateDirectories() throws {
        let url = temporaryURL("nested/deeper/cassette.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try sampleCassette.write(to: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func aMissingFileIsReportedWithItsPath() {
        let url = temporaryURL()

        #expect(throws: CassetteError.fileNotFound(path: url.path)) {
            try Cassette.load(from: url)
        }
    }

    @Test
    func aMalformedFileIsReportedRatherThanCrashing() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)

        do {
            _ = try Cassette.load(from: url)
            Issue.record("Expected a malformed-file error")
        } catch let error as CassetteError {
            guard case let .malformedFile(path, _) = error else {
                Issue.record("Expected .malformedFile, got \(error)")
                return
            }
            #expect(path == url.path)
            #expect(error.errorDescription?.contains(url.path) == true)
        }
    }

    @Test
    func aNewerFormatVersionIsRejectedWithAnActionableMessage() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 99, "interactions": []}"#.utf8).write(to: url)

        do {
            _ = try Cassette.load(from: url)
            Issue.record("Expected an unsupported-version error")
        } catch let error as CassetteError {
            guard case let .unsupportedFormatVersion(found, supported, _) = error else {
                Issue.record("Expected .unsupportedFormatVersion, got \(error)")
                return
            }
            #expect(found == 99)
            #expect(supported == Cassette.currentFormatVersion)
            #expect(error.errorDescription?.contains("re-record") == true)
        }
    }

    @Test
    func aBodyWithNeitherTextNorBase64IsRejected() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RecordedBody.self, from: Data("{}".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(RecordedBody.self, from: Data(#"{"base64": "not base64!"}"#.utf8))
        }
    }

    @Test
    func recordedBodyExposesTextOnlyWhenTheBytesAreUTF8() {
        #expect(RecordedBody(data: Data("hello".utf8)).text == "hello")
        #expect(RecordedBody(data: Data([0xFF, 0xFE])).text == nil)
    }
}
