import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkClientTestSupport
import NovaNetworkCore
import NovaNetworkDiagnostics

// Requirements: FR-HARCAS-1, FR-HARCAS-3 end to end (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §H).
// Tests: T-25.6.

private struct ItemsServer: NetworkTransport {
    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        NetworkResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json", "Set-Cookie": "sid=s3cret"],
            body: Data(#"{"items":["lamp","desk"]}"#.utf8)
        )
    }
}

@Suite
struct HARToCassetteRoundTripTests {
    @Test // T-25.6
    func aHARExportedOnOneDeviceReplaysAsACassetteOnAnother() async throws {
        let request = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/items")!,
            headers: ["Authorization": "Bearer s3cret"]
        )

        // The tester's device: real traffic, recorded, exported.
        let recorder = DiagnosticsRecorder()
        var recording = NetworkClientConfiguration()
        recording.transport = ItemsServer()
        recording.telemetryHooks = recorder.hooks
        let tester = NetworkClient(configuration: recording)
        _ = try await tester.load(request: request, authScope: nil)
        try await waitUntil("the response is recorded") {
            await recorder.snapshot().first?.responseBody?.captured != nil
        }
        let har = try await recorder.exportHAR()

        // The developer's machine: the HAR becomes a cassette, and the cassette answers offline.
        let conversion = try Cassette.fromHAR(har)
        #expect(conversion.skipped.isEmpty)
        #expect(!String(decoding: try conversion.cassette.serialized(), as: UTF8.self).contains("s3cret"))

        let replaying = NetworkClient(transport: CassetteTransport(mode: .replay, cassette: conversion.cassette))
        let body = try await replaying.load(request: request, authScope: nil)
        #expect(String(decoding: body, as: UTF8.self) == #"{"items":["lamp","desk"]}"#)
    }
}
