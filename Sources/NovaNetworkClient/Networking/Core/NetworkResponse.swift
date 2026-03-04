import Foundation

public struct NetworkResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func headerValue(for name: String) -> String? {
        let target = name.lowercased()
        return headers.first { $0.key.lowercased() == target }?.value
    }
}
