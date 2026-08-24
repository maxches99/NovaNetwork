# Declarative Endpoints

Describe an operation once — as an annotated Swift type or as an OpenAPI document — and let the
request build itself.

## Overview

A hand-written endpoint spends most of its lines restating what its URL already says: interpolate
the path parameter, append the query items, set the headers, encode the body. That code is
repetitive, and the mistakes it hides are quiet ones — an unencoded path value that breaks on a
slash, an optional serialized as the text `"nil"`, a forgotten `Content-Type`.

Two front ends remove that work, and both produce ordinary endpoints:

| You have | Use | You get |
|---|---|---|
| A Swift type describing an operation | ``Endpoint(_:_:response:)`` (the `@Endpoint` macro) | A generated `makeRequest()` |
| An OpenAPI 3 document | `swift package nova-openapi` | Generated endpoint and model types |
| Neither, or something unusual | ``EndpointDefinition`` and ``EndpointRequestBuilder`` by hand | Full control, same behavior |

All three funnel through ``EndpointRequestBuilder``, so percent-encoding, optional omission, array
styles, and header precedence behave identically no matter which you pick. You can mix them freely
in one target — an endpoint's origin is invisible at the call site:

```swift
let pet = try await client.execute(endpoint: GetPetById(petId: 7), authScope: "petstore")
```

## The `@Endpoint` macro

### Enable the trait

The macro is the only part of this package that needs `swift-syntax`, so it lives behind a SwiftPM
trait that is **off by default**. With the trait disabled, the package resolves zero dependencies;
enable it and SwiftPM fetches swift-syntax (usually as a prebuilt binary for your toolchain):

```swift
dependencies: [
    .package(url: "https://github.com/maxches99/NovaNetwork", from: "2.11.0", traits: ["EndpointMacros"])
]
```

Then depend on the `NovaNetworkMacros` product and import it. It re-exports `NovaNetworkCore`, so
one import covers the macro and the runtime it generates calls into.

### Declare an operation

```swift
import NovaNetworkMacros

protocol PetstoreAPI: EndpointDefinition {}

extension PetstoreAPI {
    var baseURL: URL { URL(string: "https://api.petstore.example.com/v1")! }
}

@Endpoint(.get, "/pets/{petId}/photos", response: [Photo].self)
struct GetPetPhotos: PetstoreAPI {
    let petId: Int                            // fills {petId}
    var limit: Int?                           // becomes ?limit=…
    @Query("sort_by") var sortBy: String?     // becomes ?sort_by=…
    @Header("X-Trace") var trace: String?
}
```

That expands to the `makeRequest()` you would have written:

```swift
extension GetPetPhotos: EndpointDefinition {
    typealias Response = [Photo]

    func makeRequest() throws -> NovaNetworkCore.APIRequest {
        var builder = NovaNetworkCore.EndpointRequestBuilder(
            method: .get,
            baseURL: self.baseURL,
            path: "/pets/{petId}/photos"
        )
        try builder.setPath("petId", self.petId)
        builder.addQuery("limit", self.limit)
        builder.addQuery("sort_by", self.sortBy)
        builder.setHeader("X-Trace", self.trace)
        return try builder.build(timeout: self.timeout, additionalHeaders: self.additionalHeaders)
    }
}
```

### How a property gets its role

Each stored property takes exactly one role, resolved in this order:

1. an explicit ``Path(_:)``, ``Query(_:style:)``, ``Header(_:)``, or ``Body(contentType:)`` marker;
2. a **path parameter**, when the property's name matches a `{placeholder}` in the template;
3. a **query item** under the property's own name.

The query default is what keeps a simple `GET` short. Everything else is explicit.

Four names are never parameters, because they are the protocol's customization points: `baseURL`,
`timeout`, `additionalHeaders`, and `jsonEncoder`. Static and computed properties are ignored too,
so a helper on the type cannot accidentally end up in a URL.

### Values and their wire forms

Any ``EndpointParameterConvertible`` value can be a parameter. The library conforms the common
scalars, `Optional`, and `Array`; an enum with a raw value only has to declare the conformance:

```swift
enum SortOrder: String, EndpointParameterConvertible {
    case ascending, descending
}
```

Three rules follow from that protocol and cover most surprises:

- **`nil` omits.** An optional query item or header that is `nil` is not sent at all — never as the
  text `"nil"` or an empty value. A `nil` *path* parameter is an error, because leaving it out would
  change which resource the URL addresses.
- **Arrays repeat by default.** `["a", "b"]` becomes `?tag=a&tag=b`. Choose another shape with
  ``EndpointQueryStyle``: `@Query("tag", style: .commaSeparated)` sends `?tag=a,b`.
- **Path values are one segment.** They are percent-encoded against the unreserved set, so a value
  containing `/`, `?`, or `#` can never restructure the URL.

### Bodies

`@Body` encodes a property as JSON with the endpoint's `jsonEncoder` and sets
`Content-Type: application/json` unless a `@Header` parameter already supplied one:

```swift
@Endpoint(.post, "/pets", response: Pet.self)
struct CreatePet: PetstoreAPI {
    @Body var pet: NewPet
    @Header("Idempotency-Key") var idempotencyKey: String
}
```

An endpoint may have one `@Body`, and `GET` and `HEAD` endpoints may not have one at all.

### When the macro refuses

Every rejection is a diagnostic on the offending declaration, never a malformed expansion. The
macro stops for: a non-struct or generic declaration; a declaration that already states `Endpoint`
or `EndpointDefinition` conformance; an interpolated path; a `{placeholder}` no property fills; a
`@Path` marker with no matching placeholder; two `@Body` properties; a `@Body` on `GET` or `HEAD`;
two markers on one property; and an empty or non-literal wire name.

## Generating from OpenAPI

### Run the generator

```bash
swift package --allow-writing-to-package-directory nova-openapi \
  --spec openapi.yaml --output Sources/MyApp/GeneratedEndpoints.swift
```

The output is checked in and reviewed like any other source. It is deterministic — the same
document always produces the same bytes — so a regenerated file differs only when the spec did.

Generated code conforms to ``EndpointDefinition`` directly and imports only `NovaNetworkCore`: it
does **not** use the macro, and it compiles with the `EndpointMacros` trait disabled.

Options: `--namespace` names the generated namespace enum (default: the document title),
`--access internal` keeps declarations internal, `--quiet` silences warnings, and `--output -`
writes to standard output.

### What comes out

- One `struct` per operation, named from `operationId`, or from the method and path when the
  document has none: `GET /pets/{petId}/photo` becomes `GetPetsByPetIdPhoto`.
- `Codable` models from `components/schemas`, including nested objects, string enums, `$ref`,
  `allOf` merging, and `additionalProperties` maps.
- A namespace holding the server URL and a `makeDecoder()` factory. Use that decoder: a document
  with `date-time` values needs `.iso8601`, which a plain `JSONDecoder` does not apply.

```swift
let pets = try await client.execute(
    endpoint: ListPets(limit: 20, tags: ["kitten"]),
    authScope: "petstore",
    decoder: PetstoreAPI.makeDecoder()
)
```

Operations that return no content decode to ``NoContent`` without running `JSONDecoder` over an
empty body.

### What it will not do quietly

Anything the generator cannot represent faithfully becomes a warning naming its location in the
document. It never substitutes silently. The cases you are most likely to meet:

- **A multi-branch `oneOf` or `anyOf`** has no single Swift type, so the property becomes a
  generated JSON value type. The 3.1 nullable idiom — `anyOf: [{type: string}, {type: "null"}]` —
  is understood as an optional and warns about nothing.
- **A recursive schema** (a `Pet` whose `parent` is a `Pet`) cannot be a plain Swift value type, so
  the property is boxed as `Indirect<Pet>` and read through its `wrapped` property.
- **A payload with no JSON media type** is not generated; the operation keeps its other parameters.
- **A document with no `servers` entry** generates endpoints that take a `baseURL` initializer
  parameter instead of reading one from the namespace.

Credentials never reach generated code: `securitySchemes` are read for nothing, and only the server
URL is embedded.

### The supported YAML subset

The reader accepts JSON and the YAML that OpenAPI documents actually use: block mappings and
sequences, flow mappings and sequences, plain and quoted scalars, `|` and `>` block scalars,
comments, and a leading `---`. Anchors, aliases, tags, merge keys, and multi-document streams are
**rejected with a located error** rather than guessed at — a generator that misreads a spec is worse
than one that stops and says which line it stopped on.

## Writing a definition by hand

Neither front end is required. ``EndpointDefinition`` is a normal protocol, and using the builder
directly is the same amount of typing the macro saves you — with nothing hidden:

```swift
struct GetPet: EndpointDefinition {
    typealias Response = Pet
    let baseURL = URL(string: "https://api.petstore.example.com/v1")!
    let petId: Int

    func makeRequest() throws -> APIRequest {
        var builder = requestBuilder(.get, "/pets/{petId}")
        try builder.setPath("petId", petId)
        return try builder.build(timeout: timeout, additionalHeaders: additionalHeaders)
    }
}
```

## Topics

### Runtime contract

- ``EndpointDefinition``
- ``EndpointRequestBuilder``
- ``EndpointParameterConvertible``
- ``EndpointQueryStyle``
- ``EndpointDefinitionError``
- ``NoContent``

## See Also

- <doc:ChoosingAnAPI>
- <doc:ModelRequestsAsEndpoints>
- ``Endpoint``
