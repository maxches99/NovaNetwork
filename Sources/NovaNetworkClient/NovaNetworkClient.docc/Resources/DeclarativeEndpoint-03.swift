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

@Endpoint(.get, "/todos/{id}", response: Todo.self)
struct GetTodo: PlaceholderAPI {
    let id: Int
}

@Endpoint(.get, "/todos", response: [Todo].self)
struct ListTodos: PlaceholderAPI {
    var userId: Int?
    @Query("_limit") var limit: Int?
    @Header("X-Trace") var trace: String?
}
