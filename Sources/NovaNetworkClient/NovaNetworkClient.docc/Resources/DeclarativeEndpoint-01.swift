import Foundation
import NovaNetworkClient
import NovaNetworkMacros

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

protocol PlaceholderAPI: EndpointDefinition {}

extension PlaceholderAPI {
    var baseURL: URL { URL(string: "https://jsonplaceholder.typicode.com")! }
}
