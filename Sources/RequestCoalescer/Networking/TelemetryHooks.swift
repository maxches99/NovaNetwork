import Foundation

public struct TelemetryRequestContext: Sendable {
    public let key: String
    public let attempt: Int
    public let request: APIRequest

    public init(key: String, attempt: Int, request: APIRequest) {
        self.key = key
        self.attempt = attempt
        self.request = request
    }
}

public struct TelemetryResponseContext: Sendable {
    public let request: TelemetryRequestContext
    public let response: NetworkResponse?
    public let error: NetworkError?
    public let durationMilliseconds: Double

    public init(
        request: TelemetryRequestContext,
        response: NetworkResponse?,
        error: NetworkError?,
        durationMilliseconds: Double
    ) {
        self.request = request
        self.response = response
        self.error = error
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct NetworkTelemetryHooks: Sendable {
    public typealias OnRequestStart = @Sendable (TelemetryRequestContext) -> Void
    public typealias OnRequestEnd = @Sendable (TelemetryResponseContext) -> Void

    public let onRequestStart: OnRequestStart?
    public let onRequestEnd: OnRequestEnd?

    public init(
        onRequestStart: OnRequestStart? = nil,
        onRequestEnd: OnRequestEnd? = nil
    ) {
        self.onRequestStart = onRequestStart
        self.onRequestEnd = onRequestEnd
    }
}
