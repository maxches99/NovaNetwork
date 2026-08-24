import Foundation
import Testing
import NovaNetworkCore

// Requirements: FR-MOD-1...2.

private struct CorePayload: Codable, Equatable, Sendable {
    let value: Int
}

@Suite
struct NovaNetworkCoreTests {
    @Test
    func coreRequestAndEndpointWorkWithoutUmbrellaModule() throws {
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://example.com/core")!,
            queryItems: [URLQueryItem(name: "page", value: "1")]
        )
        let endpoint = AnyEndpoint<CorePayload>(request: request)
        let data = try JSONEncoder().encode(CorePayload(value: 42))

        #expect(try endpoint.makeRequest().urlRequest().url?.absoluteString == "https://example.com/core?page=1")
        #expect(try endpoint.decode(data, using: JSONDecoder()) == CorePayload(value: 42))
    }

    @Test
    func coreTransportProtocolAcceptsSendableImplementations() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable((any NetworkTransport).self)
    }

    // Requirements: FR-TR-1, UR-2, DR-3, NFR-3, FR-POL-1.
    @Test
    func managedTransferSnapshotRoundTripsWithStableIdentityAndPolicies() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ManagedTransferSnapshot(
            id: TransferID(rawValue: "transfer-42"),
            kind: .download,
            state: .resuming,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(5),
            completedBytes: 128,
            totalBytes: 512,
            requestURL: URL(string: "https://example.com/archive.zip")!,
            method: "GET",
            options: .init(
                execution: .background(sessionIdentifier: "com.example.downloads"),
                resume: .requiresValidator,
                integrity: .expectedByteCountAndSHA256(byteCount: 512, sha256: "abc123"),
                networkPolicy: .init(
                    allowsCellularAccess: false,
                    allowsExpensiveNetworkAccess: false,
                    allowsConstrainedNetworkAccess: false,
                    isDiscretionary: true,
                    priority: 2
                ),
                consumerTerminationPolicy: .cancelTransfer
            ),
            destinationURL: URL(fileURLWithPath: "/tmp/archive.zip"),
            partialFileURL: URL(fileURLWithPath: "/tmp/archive.zip.partial"),
            validator: .init(eTag: "etag-v1"),
            sessionIdentifier: "com.example.downloads",
            taskIdentifier: 7
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ManagedTransferSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.id.rawValue == "transfer-42")
        #expect(decoded.options.networkPolicy.priority == 1)
        #expect(decoded.validator?.ifRangeValue == "etag-v1")
        #expect(!ManagedTransferState.finalizing.isTerminal)
        #expect(ManagedTransferState.completed.isTerminal)
    }

    // Requirements: FR-TR-1, NFR-3.
    @Test
    func managedTransferPublicValuesAreSendable() {
        func requireSendable<T: Sendable>(_: T.Type) {}
        requireSendable(TransferID.self)
        requireSendable(ManagedTransferSnapshot.self)
        requireSendable(ManagedTransferEvent.self)
        requireSendable(ManagedTransferHandle.self)
    }
}
