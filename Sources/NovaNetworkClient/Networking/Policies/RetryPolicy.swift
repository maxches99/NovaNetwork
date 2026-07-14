import NovaNetworkCore
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

public enum RetryFailureCategory: String, Sendable, Hashable {
    case rateLimited = "rate_limited"
    case serverError = "server_error"
    case timeout
    case networkUnreachable = "network_unreachable"
    case other
}

public enum RetryScheduleSource: String, Sendable {
    case policy
    case serverRetryAfter = "server_retry_after"
}

public struct RetryProfile: Sendable, Equatable {
    public let maxAttempts: Int?
    public let baseDelayNanoseconds: UInt64?
    public let maxDelayNanoseconds: UInt64?
    public let jitterRange: ClosedRange<Double>?

    public init(
        maxAttempts: Int? = nil,
        baseDelayNanoseconds: UInt64? = nil,
        maxDelayNanoseconds: UInt64? = nil,
        jitterRange: ClosedRange<Double>? = nil
    ) {
        self.maxAttempts = maxAttempts.map { max(1, $0) }
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maxDelayNanoseconds = maxDelayNanoseconds
        self.jitterRange = jitterRange
    }
}

public struct RetryDelayDecision: Sendable, Equatable {
    public let delayNanoseconds: UInt64
    public let source: RetryScheduleSource
    public let category: RetryFailureCategory

    public init(
        delayNanoseconds: UInt64,
        source: RetryScheduleSource,
        category: RetryFailureCategory
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.source = source
        self.category = category
    }
}

public struct RetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let retryBudget: Int?
    public let retryNonIdempotentRequests: Bool
    public let idempotencyHeaderNames: Set<String>
    public let baseDelayNanoseconds: UInt64
    public let maxDelayNanoseconds: UInt64
    public let maxRetryAfterNanoseconds: UInt64
    public let respectRetryAfterHeader: Bool
    public let jitterRange: ClosedRange<Double>?
    public let retriableHTTPStatusCodes: Set<Int>
    public let retriableURLErrorCodes: Set<URLError.Code>
    public let adaptiveProfiles: [RetryFailureCategory: RetryProfile]

    public init(
        maxAttempts: Int = 1,
        retryBudget: Int? = nil,
        retryNonIdempotentRequests: Bool = false,
        idempotencyHeaderNames: Set<String> = ["Idempotency-Key"],
        baseDelayNanoseconds: UInt64 = 200_000_000,
        maxDelayNanoseconds: UInt64 = 3_000_000_000,
        maxRetryAfterNanoseconds: UInt64 = 60_000_000_000,
        respectRetryAfterHeader: Bool = true,
        jitterRange: ClosedRange<Double>? = 0.8...1.2,
        retriableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        retriableURLErrorCodes: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost],
        adaptiveProfiles: [RetryFailureCategory: RetryProfile] = [:]
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.retryBudget = retryBudget.map { max(0, $0) }
        self.retryNonIdempotentRequests = retryNonIdempotentRequests
        self.idempotencyHeaderNames = Set(idempotencyHeaderNames.map { $0.lowercased() })
        self.baseDelayNanoseconds = baseDelayNanoseconds
        self.maxDelayNanoseconds = max(baseDelayNanoseconds, maxDelayNanoseconds)
        self.maxRetryAfterNanoseconds = max(baseDelayNanoseconds, maxRetryAfterNanoseconds)
        self.respectRetryAfterHeader = respectRetryAfterHeader
        self.jitterRange = jitterRange
        self.retriableHTTPStatusCodes = retriableHTTPStatusCodes
        self.retriableURLErrorCodes = retriableURLErrorCodes
        self.adaptiveProfiles = adaptiveProfiles
    }

    public static let none = RetryPolicy(maxAttempts: 1, jitterRange: nil)

    func shouldRetry(error: NetworkError) -> Bool {
        switch error {
        case .httpStatus(let code, _, _):
            return retriableHTTPStatusCodes.contains(code)
        case .transport(let underlying as URLError):
            return retriableURLErrorCodes.contains(underlying.code)
        case .cancelled:
            return false
        default:
            return false
        }
    }

    func shouldRetry(error: NetworkError, request: APIRequest) -> Bool {
        guard shouldRetry(error: error) else { return false }
        return requestIsRetryEligible(request)
    }

    func delayNanoseconds(
        forAttempt attempt: Int,
        random: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        profile: RetryProfile? = nil
    ) -> UInt64 {
        guard attempt > 0 else { return 0 }

        let resolvedBaseDelay = profile?.baseDelayNanoseconds ?? baseDelayNanoseconds
        let resolvedMaxDelay = max(
            resolvedBaseDelay,
            profile?.maxDelayNanoseconds ?? maxDelayNanoseconds
        )
        let exponent = min(attempt - 1, 16)
        let multiplier = UInt64(1 << exponent)
        let scaled = resolvedBaseDelay.saturatingMultiply(multiplier)
        let capped = min(scaled, resolvedMaxDelay)

        let resolvedJitterRange = profile?.jitterRange ?? jitterRange
        guard let resolvedJitterRange else { return capped }

        let factor = random.nextDouble(in: resolvedJitterRange)
        return UInt64(Double(capped) * factor)
    }

    func adaptiveDelayNanoseconds(
        forAttempt attempt: Int,
        error: NetworkError,
        random: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        now: Date = Date()
    ) -> UInt64 {
        let profile = adaptiveProfiles[failureCategory(for: error)]
        let backoff = delayNanoseconds(forAttempt: attempt, random: random, profile: profile)
        guard respectRetryAfterHeader else { return backoff }
        guard let retryAfter = retryAfterDelayNanoseconds(from: error, now: now) else {
            return backoff
        }
        return retryAfter
    }

    func delayDecision(
        forAttempt attempt: Int,
        error: NetworkError,
        random: any RetryRandomGenerator = SystemRetryRandomGenerator(),
        now: Date = Date()
    ) -> RetryDelayDecision {
        let category = failureCategory(for: error)
        let profile = adaptiveProfiles[category]
        let backoff = delayNanoseconds(forAttempt: attempt, random: random, profile: profile)
        guard respectRetryAfterHeader,
              let retryAfter = retryAfterDelayNanoseconds(from: error, now: now) else {
            return RetryDelayDecision(
                delayNanoseconds: backoff,
                source: .policy,
                category: category
            )
        }

        return RetryDelayDecision(
            delayNanoseconds: retryAfter,
            source: .serverRetryAfter,
            category: category
        )
    }

    func retryAfterDelayNanoseconds(from error: NetworkError, now: Date = Date()) -> UInt64? {
        guard case .httpStatus(_, let headers, _) = error else { return nil }
        guard let value = headerValue(name: "Retry-After", from: headers) else { return nil }

        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let clamped = min(max(0, seconds), TimeInterval(maxRetryAfterNanoseconds) / 1_000_000_000)
            return UInt64(clamped * 1_000_000_000)
        }

        let formatter = DateFormatter.retryRFC1123
        guard let date = formatter.date(from: value) else { return nil }
        let delay = max(0, date.timeIntervalSince(now))
        let clamped = min(delay, TimeInterval(maxRetryAfterNanoseconds) / 1_000_000_000)
        return UInt64(clamped * 1_000_000_000)
    }

    func canRetry(attempt: Int, retriesUsed: Int) -> Bool {
        guard attempt < maxAttempts else { return false }
        if let retryBudget {
            return retriesUsed < retryBudget
        }
        return true
    }

    func canRetry(attempt: Int, retriesUsed: Int, error: NetworkError) -> Bool {
        let categoryMaxAttempts = adaptiveProfiles[failureCategory(for: error)]?.maxAttempts
        let effectiveMaxAttempts = min(categoryMaxAttempts ?? maxAttempts, maxAttempts)
        guard attempt < effectiveMaxAttempts else { return false }
        if let retryBudget {
            return retriesUsed < retryBudget
        }
        return true
    }

    func failureCategory(for error: NetworkError) -> RetryFailureCategory {
        switch error {
        case .httpStatus(let code, _, _):
            if code == 429 { return .rateLimited }
            if (500...599).contains(code) { return .serverError }
            return .other
        case .transport(let underlying as URLError):
            switch underlying.code {
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return .networkUnreachable
            default:
                return .other
            }
        case .transport:
            return .other
        case .timeoutBudgetExceeded:
            return .timeout
        default:
            return .other
        }
    }

    private func requestIsRetryEligible(_ request: APIRequest) -> Bool {
        if retryNonIdempotentRequests {
            return true
        }
        if request.method.isRetryIdempotent {
            return true
        }

        let requestHeaderNames = Set(request.headers.keys.map { $0.lowercased() })
        return !idempotencyHeaderNames.isDisjoint(with: requestHeaderNames)
    }
}

private extension RetryPolicy {
    func headerValue(name: String, from headers: [String: String]) -> String? {
        let normalized = name.lowercased()
        return headers.first { $0.key.lowercased() == normalized }?.value
    }
}

private extension DateFormatter {
    static let retryRFC1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter
    }()
}

private extension UInt64 {
    func saturatingMultiply(_ rhs: UInt64) -> UInt64 {
        let (value, overflow) = multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : value
    }
}

private extension URLMethod {
    var isRetryIdempotent: Bool {
        switch self {
        case .get, .head, .put, .delete, .options:
            return true
        case .post, .patch:
            return false
        }
    }
}
