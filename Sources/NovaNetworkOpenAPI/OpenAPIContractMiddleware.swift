import Foundation
import NovaNetworkCore

/// Thrown by `NetworkMiddleware.openAPIContract(_:...)` when `failOnBreaking` is set and a response
/// would fail a decode.
public struct ContractViolationError: Error, Sendable, Equatable, LocalizedError {
    /// What was wrong with the response.
    public let report: ContractReport

    /// Creates an error from a report.
    public init(report: ContractReport) {
        self.report = report
    }

    /// The operation and its breaking violations.
    public var errorDescription: String? {
        let breaking = report.violations.filter { $0.severity == .breaking }.map(\.description)
        return "\(report.method) \(report.operationPath ?? report.path) does not match its spec: "
            + breaking.joined(separator: "; ")
    }
}

/// Remembers which violations were already reported, so a renamed field is reported once rather
/// than on every response.
private final class ReportedViolations: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<String>()

    /// The violations not reported before, marking them reported.
    func unseen(in report: ContractReport) -> [ContractViolation] {
        lock.lock()
        defer { lock.unlock() }
        return report.violations.filter { violation in
            let identity = "\(report.method) \(report.operationPath ?? report.path) \(violation.pointer) \(violation.kind)"
            return seen.insert(identity).inserted
        }
    }
}

public extension NetworkMiddleware {
    /// Checks successful responses against an OpenAPI contract and reports how they differ.
    ///
    /// ```swift
    /// let contract = try OpenAPIContract(specText: spec)
    /// configuration.addMiddleware(
    ///     .openAPIContract(contract, sampleRate: 0.05) { report in
    ///         for violation in report.violations { logger.warning("\(violation)") }
    ///     }
    /// )
    /// ```
    ///
    /// Only successful responses reach middleware: the transport throws for other status codes
    /// before this runs.
    ///
    /// - Parameters:
    ///   - contract: The specification to check against.
    ///   - sampleRate: The share of responses to check, between `0` and `1`. Checking parses the body
    ///     a second time; in production a few percent finds drift without paying for it on every
    ///     response.
    ///   - reportsEachViolationOnce: Leaves out violations already reported for the same operation,
    ///     pointer, and kind, and sends no report when nothing new is left. Defaults to `true`.
    ///   - failOnBreaking: Throws ``ContractViolationError`` for a response with a breaking violation,
    ///     for debug builds and tests. The error reaches the caller as `NetworkError.transport`.
    ///   - random: Source of sampling decisions, between `0` and `1`. Injectable for tests.
    ///   - onReport: Receives a report for each checked response that has a violation to report.
    static func openAPIContract(
        _ contract: OpenAPIContract,
        sampleRate: Double = 1,
        reportsEachViolationOnce: Bool = true,
        failOnBreaking: Bool = false,
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        onReport: @escaping @Sendable (ContractReport) -> Void
    ) -> NetworkMiddleware {
        let rate = min(max(sampleRate, 0), 1)
        let reported = ReportedViolations()

        return NetworkMiddleware(afterResponse: { request, _, response in
            guard rate > 0, rate >= 1 || random() < rate else { return response }

            let report = contract.validate(
                method: request.method.rawValue,
                url: request.url,
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body
            )
            guard !report.violations.isEmpty else { return response }

            let toReport = reportsEachViolationOnce ? reported.unseen(in: report) : report.violations
            if !toReport.isEmpty {
                onReport(
                    ContractReport(
                        method: report.method,
                        path: report.path,
                        operationPath: report.operationPath,
                        statusCode: report.statusCode,
                        violations: toReport
                    )
                )
            }
            if failOnBreaking, report.hasBreakingViolations {
                throw ContractViolationError(report: report)
            }
            return response
        })
    }
}
