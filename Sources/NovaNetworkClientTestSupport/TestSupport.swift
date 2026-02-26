import Foundation
import NovaNetworkClient

public actor MockTransport: NetworkTransport {
    private(set) public var calls: Int = 0
    private let result: Result<NetworkResponse, NetworkError>
    private let delayNanoseconds: UInt64

    public init(
        delayNanoseconds: UInt64 = 0,
        result: Result<NetworkResponse, NetworkError>
    ) {
        self.delayNanoseconds = delayNanoseconds
        self.result = result
    }

    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        switch result {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

public actor ScriptedTransport: NetworkTransport {
    private(set) public var calls: Int = 0
    private var scripted: [Result<NetworkResponse, NetworkError>]

    public init(scripted: [Result<NetworkResponse, NetworkError>]) {
        self.scripted = scripted
    }

    public func execute(_ request: APIRequest) async throws -> NetworkResponse {
        calls += 1
        guard !scripted.isEmpty else {
            throw NetworkError.httpStatus(code: 500, body: Data())
        }
        let next = scripted.removeFirst()
        switch next {
        case .success(let response):
            return response
        case .failure(let error):
            throw error
        }
    }
}

public actor TestRetryClock: RetryClock {
    private(set) public var sleeps: [UInt64] = []
    public init() {}

    public func sleep(nanoseconds: UInt64) async throws {
        sleeps.append(nanoseconds)
    }
}

public struct TestRetryRandom: RetryRandomGenerator {
    public let value: Double
    public init(value: Double) {
        self.value = value
    }

    public func nextDouble(in range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
