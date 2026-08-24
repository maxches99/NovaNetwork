# What's New in 2.11

## Declarative endpoints

An endpoint's `makeRequest()` mostly restates what its URL template already says. 2.11 adds two
ways to stop writing it, and one runtime contract underneath both.

### The `@Endpoint` macro

```swift
@Endpoint(.get, "/pets/{petId}/photos", response: [Photo].self)
struct GetPetPhotos: PetstoreAPI {
    let petId: Int
    var limit: Int?
    @Query("sort_by") var sortBy: String?
    @Header("X-Trace") var trace: String?
}
```

Each stored property takes one role: an explicit `@Path`/`@Query`/`@Header`/`@Body` marker, then a
path parameter when its name matches a `{placeholder}`, then a query item under its own name.
`baseURL`, `timeout`, `additionalHeaders`, and `jsonEncoder` stay customization points and are never
parameters; static and computed properties are ignored.

### OpenAPI generation

```bash
swift package --allow-writing-to-package-directory nova-openapi \
  --spec openapi.yaml --output Sources/MyApp/GeneratedEndpoints.swift
```

Reads OpenAPI 3.0.x and 3.1.x, as JSON or as a documented YAML subset, and writes one `struct` per
operation plus `Codable` models from `components/schemas`. Output is checked in and reviewed like
any other source.

### One runtime, two front ends

Both emit calls into the new `EndpointRequestBuilder`, so serialization rules live in one tested
place: `nil` omits a query item or header but is an error for a path parameter, arrays repeat by
default (`.commaSeparated`, `.spaceDelimited`, and `.pipeDelimited` are available), path values are
percent-encoded to a single segment, and parameter-supplied headers beat endpoint-wide defaults. A
hand-written `EndpointDefinition` conformance behaves identically — the declarative forms are
shortcuts, not a separate execution path.

## The dependency stays optional

Macros need `swift-syntax`. Rather than hand that cost to every consumer, the macro sits behind the
`EndpointMacros` SwiftPM trait, **off by default**:

```swift
.package(url: "https://github.com/maxches99/NovaNetwork", from: "2.11.0", traits: ["EndpointMacros"])
```

With the trait disabled, SwiftPM prunes swift-syntax from resolution entirely — the default package
graph still resolves zero dependencies, and a CI step now fails if that ever stops being true.

The OpenAPI generator needs neither the trait nor the macro: generated code conforms to
`EndpointDefinition` directly and imports only `NovaNetworkCore`.

## What was verified

- 549 tests pass with the trait enabled, 524 with it disabled; no existing test changed behavior.
- Macro coverage is 25 tests: golden expansions, end-to-end request construction through compiled
  `@Endpoint` types, and one test per documented diagnostic.
- Generator coverage is 43 tests over a reference Petstore document, including byte-identical
  determinism, drift against the checked-in output, decoding of generated models, and every warning
  path.
- `Sources/NovaNetworkOpenAPI` joins the ≥90% unit coverage gate (93.05% at merge); the new
  `NovaNetworkCore` files are at 98.85%.
- Two new CI jobs: `endpoint-macros-trait` (zero-dependency check, trait-enabled build under
  complete concurrency checking, trait-enabled tests) and `openapi-generator` (regenerates the
  example and fails on any diff). The Linux gate now compiles `NovaNetworkOpenAPI` too.
- `Examples/OpenAPIPetstore` holds the spec, the checked-in generated file in a target that depends
  on `NovaNetworkCore` alone, and a runnable program — so "generated code needs nothing else" is a
  build failure if it stops being true, not a claim.

## Known limitations

- **YAML subset.** Block and flow collections, plain and quoted scalars, `|`/`>` block scalars,
  comments, and a leading `---` are supported. Anchors, aliases, tags, merge keys, and
  multi-document streams are rejected with a line and column rather than guessed at. Swagger 2.0 is
  not supported; convert to OpenAPI 3 first.
- **Schema composition.** `allOf` is merged. A `oneOf`/`anyOf` with one non-null branch is read as
  an optional; with more, the property becomes a generated JSON value type and the generator warns.
- **Recursive schemas** are boxed as `Indirect<…>` and read through `wrapped`, because a Swift value
  type cannot store itself — not even through an `Optional`.
- **Request bodies** are generated for JSON media types only; form-urlencoded and multipart payloads
  are reported and skipped. Cookie parameters are skipped with a warning.
- **The macro** applies to non-generic structs only, and a type may not also declare `Endpoint` or
  `EndpointDefinition` conformance itself.
- **Dates.** `format: date-time` maps to `Foundation.Date`, which needs the generated
  `makeDecoder()`; a plain `JSONDecoder` will fail on an ISO 8601 string.

## Migration notes

Additive. No existing API changed shape or behavior, the API breaking-changes gate passes with no
new allowlist entries, and nothing needs to be adopted: hand-written `Endpoint` types keep working
unchanged, and can sit beside declarative ones in the same target.

## Source traceability

- DFR: [NovaNetwork 2.11 DFR](dfr/NOVA_NETWORK_V2_11_DFR.md)
- Traceability pack: [v2.11](TRACEABILITY_PACK_v2.11.md)
- Requirement IDs: FR-1…FR-26, UR-1…UR-4, DR-1…DR-3, AR-1, NFR-1…NFR-6, EC-1…EC-12
