import Foundation
import NovaNetworkClient
import NovaNetworkCore

/// Where the demo's traffic goes.
enum DemoBackend: String, CaseIterable, Identifiable, Sendable {
    /// A scripted transport inside the app. No network, and every run is identical.
    case scripted
    /// Real HTTPS requests to an httpbin-compatible host.
    case live

    var id: String { rawValue }

    var title: String {
        switch self {
        case .scripted: "Scripted"
        case .live: "Live"
        }
    }

    var explanation: String {
        switch self {
        case .scripted:
            "Responses come from a transport inside the app. No network, no server, and every run is identical."
        case .live:
            "Real HTTPS requests over URLSession. The timings are whatever the network gives you, and the flaky endpoint really is a coin flip."
        }
    }
}

/// The five paths each scenario uses, resolved for the backend in use.
///
/// The live paths follow the httpbin contract, so any httpbin-compatible host works — `httpbin.org`,
/// `httpbingo.org`, or one you run yourself.
struct DemoEndpoints: Sendable {
    var base: URL
    var flaky: String
    var profile: String
    var settings: String
    var orders: String
    var slow: String

    static let scripted = DemoEndpoints(
        base: URL(string: "https://api.example.com")!,
        flaky: "/flaky",
        profile: "/profile",
        settings: "/settings",
        orders: "/orders",
        slow: "/slow"
    )

    static func live(host: URL) -> DemoEndpoints {
        DemoEndpoints(
            base: host,
            // Returns 200 or 503 at random, so the retry policy has something real to work against.
            flaky: "/status/200,503",
            profile: "/json",
            settings: "/uuid",
            orders: "/status/422",
            slow: "/delay/8"
        )
    }

    func url(_ path: String) -> URL {
        URL(string: base.absoluteString + path) ?? base
    }
}

/// A scripted transport, so the demo has something to show with no network and no server.
///
/// Each path exists to put one shape of record in the panel; see the table in the README. Non-2xx
/// statuses are thrown as `NetworkError.httpStatus`, which is what the real transport does, so the
/// client's retry and error handling behave identically either way.
actor DemoAPI: NetworkTransport {
    private var flakyAttempts = 0
    private let headers = ["Content-Type": "application/json"]

    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        switch request.url.path {
        case DemoEndpoints.scripted.flaky:
            flakyAttempts += 1
            guard flakyAttempts >= 3 else {
                try await Task.sleep(nanoseconds: 40_000_000)
                throw NetworkError.httpStatus(code: 503, headers: headers, body: body(#"{"error":"try again"}"#))
            }
            try await Task.sleep(nanoseconds: 60_000_000)
            return NetworkResponse(statusCode: 200, headers: headers, body: profile)

        case DemoEndpoints.scripted.orders:
            try await Task.sleep(nanoseconds: 60_000_000)
            throw NetworkError.httpStatus(
                code: 422,
                headers: headers,
                body: body(#"{"error":"lineItems must not be empty"}"#)
            )

        case DemoEndpoints.scripted.slow:
            try await Task.sleep(nanoseconds: 8_000_000_000)
            return NetworkResponse(statusCode: 200, headers: headers, body: profile)

        default:
            try await Task.sleep(nanoseconds: 120_000_000)
            return NetworkResponse(statusCode: 200, headers: headers, body: profile)
        }
    }

    private var profile: Data {
        body(#"{"id":42,"name":"Ada Lovelace","email":"ada@example.com"}"#)
    }

    private nonisolated func body(_ json: String) -> Data {
        Data(json.utf8)
    }
}
