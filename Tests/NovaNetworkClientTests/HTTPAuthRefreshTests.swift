import Foundation
import Testing
@testable import NovaNetworkClient

// Requirements: FR-AUTH-1...4, EC-4...5, AR-3.

private actor AuthRefreshTransport: NetworkTransport {
    private let alwaysUnauthorized: Bool
    private var callCount = 0

    init(alwaysUnauthorized: Bool = false) {
        self.alwaysUnauthorized = alwaysUnauthorized
    }

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        callCount += 1
        if !alwaysUnauthorized, request.headers["Authorization"] == "Bearer refreshed" {
            return NetworkResponse(statusCode: 200, headers: [:], body: Data(request.url.path.utf8))
        }
        throw NetworkError.httpStatus(code: 401, headers: [:], body: Data("unauthorized".utf8))
    }

    func calls() -> Int { callCount }
}

private enum AuthProviderFailure: Error {
    case unavailable
}

private actor AuthProviderProbe {
    private var scopes: [String?] = []
    private let shouldFail: Bool
    private let delayNanoseconds: UInt64

    init(shouldFail: Bool = false, delayNanoseconds: UInt64 = 20_000_000) {
        self.shouldFail = shouldFail
        self.delayNanoseconds = delayNanoseconds
    }

    func refresh(scope: String?) async throws -> [String: String] {
        scopes.append(scope)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if shouldFail {
            throw AuthProviderFailure.unavailable
        }
        return ["Authorization": "Bearer refreshed"]
    }

    func calls() -> Int { scopes.count }
    func recordedScopes() -> [String?] { scopes }
}

private actor AuthTelemetryProbe {
    private var contexts: [TelemetryHTTPAuthRefreshContext] = []
    func append(_ context: TelemetryHTTPAuthRefreshContext) { contexts.append(context) }
    func events() -> [TelemetryHTTPAuthRefreshContext.Event] { contexts.map(\.event) }
    func last() -> TelemetryHTTPAuthRefreshContext? { contexts.last }
}

@Suite
struct HTTPAuthRefreshTests {
    private func request(_ path: String) -> APIRequest {
        APIRequest(
            method: .get,
            url: URL(string: "https://example.com/\(path)")!,
            headers: ["Authorization": "Bearer expired"]
        )
    }

    @Test
    func concurrentUnauthorizedRequestsShareOneRefresh() async throws {
        let transport = AuthRefreshTransport()
        let provider = AuthProviderProbe()
        let client = NetworkClient(
            transport: transport,
            httpAuthRefreshProvider: .init(refreshHeaders: { scope in
                try await provider.refresh(scope: scope)
            })
        )

        async let first = client.load(request: request("first"), authScope: "account:1")
        async let second = client.load(request: request("second"), authScope: "account:1")
        let values = try await [first, second]

        #expect(values.map { String(decoding: $0, as: UTF8.self) }.sorted() == ["/first", "/second"])
        #expect(await provider.calls() == 1)
        #expect(await transport.calls() == 4)
    }

    @Test
    func repeatedUnauthorizedResponseStopsAtConfiguredLimit() async {
        let transport = AuthRefreshTransport(alwaysUnauthorized: true)
        let provider = AuthProviderProbe(delayNanoseconds: 0)
        let client = NetworkClient(
            transport: transport,
            httpAuthRefreshProvider: .init(refreshHeaders: { scope in
                try await provider.refresh(scope: scope)
            }),
            httpAuthRefreshPolicy: .init(maxRefreshAttempts: 1)
        )

        do {
            _ = try await client.load(request: request("loop"), authScope: "account:1")
            Issue.record("Expected terminal unauthorized response")
        } catch let error as NetworkError {
            #expect(error.statusCode == 401)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await provider.calls() == 1)
        #expect(await transport.calls() == 2)
    }

    @Test
    func refreshFailureReturnsTypedErrorAndNeverEmitsSuccess() async {
        let transport = AuthRefreshTransport()
        let provider = AuthProviderProbe(shouldFail: true, delayNanoseconds: 0)
        let telemetry = AuthTelemetryProbe()
        let hooks = NetworkTelemetryHooks(onHTTPAuthRefresh: { context in
            Task { await telemetry.append(context) }
        })
        let client = NetworkClient(
            transport: transport,
            telemetryHooks: hooks,
            httpAuthRefreshProvider: .init(refreshHeaders: { scope in
                try await provider.refresh(scope: scope)
            })
        )

        do {
            _ = try await client.load(request: request("failure"), authScope: "account:1")
            Issue.record("Expected authentication refresh failure")
        } catch let error as NetworkError {
            #expect(error.failureReason == .authenticationRefreshFailed)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        for _ in 0..<100 {
            if await telemetry.events().contains(.failed) { break }
            await Task.yield()
        }
        #expect(await telemetry.events().contains(.started))
        #expect(await telemetry.events().contains(.failed))
        #expect(!(await telemetry.events().contains(.succeeded)))
    }

    @Test
    func differentAuthenticationScopesRefreshIndependently() async throws {
        let transport = AuthRefreshTransport()
        let provider = AuthProviderProbe()
        let client = NetworkClient(
            transport: transport,
            httpAuthRefreshProvider: .init(refreshHeaders: { scope in
                try await provider.refresh(scope: scope)
            })
        )

        async let first = client.load(request: request("one"), authScope: "account:1")
        async let second = client.load(request: request("two"), authScope: "account:2")
        _ = try await [first, second]

        #expect(await provider.calls() == 2)
        let scopes = await provider.recordedScopes().compactMap { $0 }
        #expect(Set(scopes) == Set(["account:1", "account:2"]))
    }
}
