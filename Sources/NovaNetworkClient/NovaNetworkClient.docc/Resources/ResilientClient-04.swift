import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

@main
struct ResilientClient {
    static func main() async {
        var configuration = NetworkClientConfiguration()
        configuration.retryPolicy = RetryPolicy(
            maxAttempts: 3,
            baseDelayNanoseconds: 200_000_000,
            maxDelayNanoseconds: 2_000_000_000
        )
        configuration.defaultCachePolicy = .cacheFirst(maxAge: 30)
        configuration.networkObserver = { event in
            print("Network event: \(event)")
        }
    }
}
