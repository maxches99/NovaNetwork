import Foundation
import NovaNetworkClient
import NovaNetworkPetstoreGenerated

/// Shows endpoint types generated from `petstore.yaml` by `swift package nova-openapi`.
///
/// The generated file next to this one is ordinary checked-in source: it conforms to
/// `EndpointDefinition` directly, imports only `NovaNetworkCore`, and needs neither the
/// `@Endpoint` macro nor the `EndpointMacros` package trait to compile.
///
/// The requests are printed rather than sent, because `api.petstore.example.com` is not a real
/// host. Executing one is the same call any other endpoint takes:
///
/// ```swift
/// let pet = try await client.execute(
///     endpoint: GetPetById(petId: 42),
///     authScope: "petstore",
///     decoder: PetstoreAPI.makeDecoder()
/// )
/// ```
@main
struct OpenAPIPetstoreExample {
    static func main() async {
        do {
            let list = try ListPets(limit: 20, tags: ["kitten", "rescue"]).makeRequest()
            print("List:   \(describe(list))")

            let byID = try GetPetById(petId: 42).makeRequest()
            print("Detail: \(describe(byID))")

            let create = try CreatePet(body: NewPet(name: "Ada", tag: "tabby")).makeRequest()
            print("Create: \(describe(create)) body=\(create.body.map { String(decoding: $0, as: UTF8.self) } ?? "none")")

            let remove = try DeletePetsByPetId(petId: 42).makeRequest()
            print("Delete: \(describe(remove))")

            // A 204 operation decodes without running JSONDecoder over an empty body.
            let deleted = try DeletePetsByPetId(petId: 42).decode(Data(), using: PetstoreAPI.makeDecoder())
            print("Deleted response: \(deleted)")
        } catch {
            print("Example failed: \(error)")
        }
    }

    private static func describe(_ request: APIRequest) -> String {
        let query = request.queryItems
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
        return "\(request.method.rawValue) \(request.url.absoluteString)\(query.isEmpty ? "" : "?\(query)")"
    }
}
