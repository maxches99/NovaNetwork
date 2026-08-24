import Foundation
import NovaNetworkClient
import NovaNetworkMacros

struct Todo: Decodable, Sendable {
    let userId: Int
    let id: Int
    let title: String
    let completed: Bool
}

struct NewPost: Encodable, Sendable {
    let userId: Int
    let title: String
    let body: String
}

struct Post: Decodable, Sendable {
    let id: Int
    let title: String
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

@Endpoint(.post, "/posts", response: Post.self)
struct CreatePost: PlaceholderAPI {
    @Body var post: NewPost
}

@main
struct DeclarativeEndpointExample {
    static func main() async {
        let client = NetworkClient()

        do {
            let todo = try await client.execute(endpoint: GetTodo(id: 1), authScope: "public")
            print("Todo \(todo.id): \(todo.title)")

            let todos = try await client.execute(
                endpoint: ListTodos(userId: 1, limit: 3),
                authScope: "public"
            )
            print("Fetched \(todos.count) todos for user 1")

            let post = try await client.execute(
                endpoint: CreatePost(post: NewPost(userId: 1, title: "Declarative", body: "Built by @Endpoint")),
                authScope: "public"
            )
            print("Created post \(post.id): \(post.title)")
        } catch {
            print("Request failed: \(error.localizedDescription)")
        }
    }
}
