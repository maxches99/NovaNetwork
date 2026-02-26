import Foundation

public protocol RetryRandomGenerator: Sendable {
    func nextDouble(in range: ClosedRange<Double>) -> Double
}

public struct SystemRetryRandomGenerator: RetryRandomGenerator {
    public init() {}

    public func nextDouble(in range: ClosedRange<Double>) -> Double {
        Double.random(in: range)
    }
}

public protocol RetryClock: Sendable {
    func sleep(nanoseconds: UInt64) async throws
}

public struct SystemRetryClock: RetryClock {
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelayNanoseconds: UInt64
    public let maxDelayNanoseconds: UInt64
    public let jitterRange: ClosedRange<Double>?
    public let retriableHTTPStatusCodes: Set<Int>
    public let retriableURLErrorCodes: Set<URLError.Code>

    public init(
        maxAttempts: Int = 1,
        baseDelayNanoseconds: UInt64 = 200_000_000,
        maxDelayNanoseconds: UInt64 = 3_000_000_000,
        jitterRange: ClosedRange<Double>? = 0.8...1.2,
        retriableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        retriableURLErrorCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost]
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maxDelayNanoseconds = max(baseDelayNanoseconds, maxDelayNanoseconds)
        self.jitterRange = jitterRange
        self.retriableHTTPStatusCodes = retriableHTTPStatusCodes
        self.retriableURLErrorCodes = retriableURLErrorCodes
    }

    public static let none = RetryPolicy(maxAttempts: 1, jitterRange: nil)

    func shouldRetry(error: NetworkError) -> Bool {
        switch error {
        case .httpStatus(let code, _):
            return retriableHTTPStatusCodes.contains(code)
        case .transport(let underlying as URLError):
            return retriableURLErrorCodes.contains(underlying.code)
        case .cancelled:
            return false
        default:
            return false
        }
    }

    func delayNanoseconds(
        forAttempt attempt: Int,
        random: any RetryRandomGenerator = SystemRetryRandomGenerator()
    ) -> UInt64 {
        guard attempt > 0 else { return 0 }

        let exponent = min(attempt - 1, 16)
        let multiplier = UInt64(1 << exponent)
        let scaled = baseDelayNanoseconds.saturatingMultiply(multiplier)
        let capped = min(scaled, maxDelayNanoseconds)

        guard let jitterRange else { return capped }

        let factor = random.nextDouble(in: jitterRange)
        return UInt64(Double(capped) * factor)
    }
}

private extension UInt64 {
    func saturatingMultiply(_ rhs: UInt64) -> UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : value
    }
}
