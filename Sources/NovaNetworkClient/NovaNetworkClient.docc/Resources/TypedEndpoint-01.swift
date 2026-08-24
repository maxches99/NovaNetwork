import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

struct TodoEndpoint: Endpoint {
    typealias Response = Todo

    let id: Int
}
