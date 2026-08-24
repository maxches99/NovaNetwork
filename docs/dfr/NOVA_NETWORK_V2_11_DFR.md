# NovaNetwork 2.11 DFR

## 1. Metadata

- Feature name: NovaNetwork 2.11 — Declarative Endpoints (`@Endpoint` macro) and OpenAPI generation
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, QA, Docs
- Status: `Implementation complete; pre-release CI gates pending`
- Approval source: user-directed implementation on 2026-08-24
- Target version: 2.11.0
- Source baseline: 2.10 (`main`)
- Related artifacts:
  - Release notes: `docs/WHATS_NEW_v2.11.md`
  - Traceability pack: `docs/TRACEABILITY_PACK_v2.11.md`
  - Test policy: `docs/UNIT_TEST_POLICY.md`
  - DocC article: `Sources/NovaNetworkClient/NovaNetworkClient.docc/DeclarativeEndpoints.md`

## 2. Goal and Scope

### Goal

Remove the hand-written boilerplate from endpoint declarations. A developer should describe *what*
an operation is — method, path, parameters, response type — and get request construction for free,
either by annotating a Swift type with `@Endpoint` or by generating endpoint types from an existing
OpenAPI document. Both paths must produce code that targets one shared, well-tested runtime
contract, and neither may add a dependency to consumers who do not use them.

### User value

Today every operation requires a hand-written `makeRequest()`: string interpolation for path
parameters, manual `URLQueryItem` arrays, manual header dictionaries, manual JSON body encoding.
That code is repetitive, easy to get subtly wrong (missing percent-encoding, an optional silently
serialized as `"nil"`, a forgotten `Content-Type`), and invisible to review because every endpoint
looks almost the same. Teams that already own an OpenAPI document write that code twice — once in
the spec, once in Swift — and the two drift.

### Scope split

- MVP / required for 2.11:
  - shared runtime contract in `NovaNetworkCore`: `EndpointDefinition`, `EndpointRequestBuilder`,
    `EndpointParameterConvertible`, parameter serialization styles, typed construction errors;
  - `@Endpoint` attached macro with `@Path` / `@Query` / `@Header` / `@Body` parameter markers and
    actionable diagnostics, gated behind an opt-in SwiftPM trait;
  - OpenAPI 3.0.x / 3.1.x reader (JSON plus a documented YAML subset), Swift emitter, CLI, and
    SwiftPM command plugin;
  - CI lanes for the trait-enabled build and for generator determinism;
  - documentation: DocC article, tutorial, README, website, examples.
- Nice-to-have after MVP:
  - `oneOf` / `anyOf` schema modelling as Swift enums;
  - form-urlencoded and multipart request bodies from the spec;
  - a build-plugin variant that regenerates on every build;
  - macro-generated `ResponseDecoding` selection per operation.

### Non-goals

- Replacing `Endpoint`; `@Endpoint` and the generator both *produce* ordinary `Endpoint` conformances.
- A general-purpose YAML parser. Only the subset OpenAPI documents use is supported, and anything
  outside it must fail loudly with a located error rather than parse incorrectly.
- Server-side code generation, mock server generation, or spec validation/linting.
- Making swift-syntax a dependency of the default package graph.
- Runtime behavior changes to coalescing, retry, caching, or telemetry.

### Definition of Done

- [x] DFR updated and approved
- [x] Code implemented
- [x] Tests added/updated per matrix, unit coverage stays above 90%
- [x] Telemetry reviewed (see AR-1)
- [x] "What's New" added
- [x] Traceability pack added
- [x] Documentation (DocC, README, website, examples) updated
- [x] Rollout plan documented

## 3. User Value

### User problem

A `NovaNetworkClient` adopter with fifty operations writes fifty near-identical `makeRequest()`
implementations. The mistakes that survive review are the quiet ones: an unencoded path parameter
that breaks on a slash, an optional query value serialized as the string `"nil"`, an array
parameter joined the way this one server happens not to want. None of these are visible in a diff
that looks like every other endpoint in the file.

Adopters who own an OpenAPI document have the same information already written down, in a form a
machine can read. They should not be retyping it.

### Success metrics

| Metric | Baseline | Target | Measurement method |
|---|---:|---:|---|
| Lines of Swift per simple GET endpoint | ~18 | ≤ 8 | Count in `Examples/DeclarativeEndpoints` vs the hand-written form |
| Dependencies resolved by a default consumer | 0 | 0 | `swift package show-dependencies` with the trait disabled |
| Operations covered from a reference spec | 0 | 100% of paths in `Tests/.../Fixtures/petstore.yaml` | Generator run in CI, output compiled |
| Byte-identical output across runs | n/a | 100% | Determinism test (T-18.1) |

## 4. Rollout, Dependencies, Risks

### Rollout plan

- Feature flag: SwiftPM package trait `EndpointMacros`, **disabled by default**. The macro APIs do
  not exist unless a consumer opts in; the OpenAPI generator is a command plugin and is never part
  of a consumer build.
- Initial rollout: additive minor release 2.11.0. No existing API changes shape or behavior.
- Segments: all consumers; opt-in per package.
- Ramp plan: ship documented as adoptable per-endpoint — a codebase may mix hand-written
  `Endpoint`, `@Endpoint`, and generated endpoints in the same target.
- Rollback trigger: any macro expansion that changes the request produced by an equivalent
  hand-written endpoint; consumers roll back by disabling the trait, which removes the macro
  entirely without touching the rest of the package.

### Dependencies

- Internal: `NovaNetworkCore` (`APIRequest`, `URLMethod`, `Endpoint`).
- External: `swift-syntax` 602.0.0, **only** when the `EndpointMacros` trait is enabled. SwiftPM
  prunes it from resolution otherwise (verified: a trait-disabled build resolves zero packages).

### Risks and mitigations

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| swift-syntax compile cost scares off adopters | High | Medium | Trait-gated and off by default; SwiftPM downloads a prebuilt macro-support binary for matching toolchains |
| Hand-written YAML parser misreads a valid spec | High | Medium | Parse a documented subset only; unsupported syntax raises a located error, never a wrong value; fixture-driven tests including negative cases |
| Macro diagnostics are unclear, so failures look like compiler bugs | Medium | Medium | Every rejection path has a dedicated diagnostic with a message naming the offending declaration; diagnostics are unit-tested |
| Generated names collide or churn between runs | Medium | Low | Deterministic name derivation, sorted iteration, collision suffixing, byte-identical-output test |
| Trait-gated code rots because default CI never builds it | High | Medium | Dedicated CI job builds and tests with `--traits EndpointMacros` |

## 5. Requirements

### Functional requirements (FR)

#### Runtime contract

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-1 | `EndpointDefinition` refines `Endpoint` with a `baseURL` requirement and defaulted `additionalHeaders`, `timeout`, and `jsonEncoder` customization points | Conforming type supplying only `baseURL` and `makeRequest()` compiles; defaults are 60s timeout, empty headers, plain `JSONEncoder` | `EndpointDefinition.swift` |
| FR-2 | `EndpointRequestBuilder` builds an `APIRequest` from a method, base URL, path template, and typed parameter values | Builder output equals the hand-written `APIRequest` for the same inputs | `EndpointRequestBuilder.swift` |
| FR-3 | `EndpointParameterConvertible` serializes scalars, `RawRepresentable`, optionals, and arrays to parameter strings | `nil` contributes no value; arrays contribute one entry per element; `Bool` serializes as `true`/`false` | `EndpointParameterConvertible.swift` |
| FR-4 | Path parameters are percent-encoded against an unreserved-character allow list | A value containing `/`, `?`, `#`, or a space round-trips as an opaque single segment | T-4.1 |
| FR-5 | Query array serialization supports `repeated`, `commaSeparated`, `spaceDelimited`, and `pipeDelimited` styles | Each style produces the documented query string; `repeated` is the default | T-5.1 |
| FR-6 | JSON bodies are encoded with the definition's `jsonEncoder` and default `Content-Type: application/json` unless already set | Body bytes equal `JSONEncoder().encode(value)`; caller-supplied content type wins | T-6.1 |
| FR-7 | Construction failures throw typed `EndpointDefinitionError` cases naming the offending parameter | Missing path value, unresolved placeholder, and invalid URL each throw their own case | T-7.1 |

#### `@Endpoint` macro

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-8 | `@Endpoint(.get, "/path")` on a struct generates an `EndpointDefinition` conformance and `makeRequest()` | Expansion matches the golden expansion in T-8.1 | `EndpointMacro.swift` |
| FR-9 | Stored properties bind to `{name}` placeholders by property name; `@Path("name")` overrides the binding | A property named `id` fills `{id}`; `@Path("user_id") var id` fills `{user_id}` | T-9.1 |
| FR-10 | `@Query`, `@Header`, and `@Body` markers map properties to query items, headers, and the request body | Each marker produces the corresponding builder call; a custom wire name is honored | T-10.1 |
| FR-11 | A stored property that is neither a path placeholder nor explicitly marked becomes a query item under its own name | Documented default; verified by expansion test | T-11.1 |
| FR-12 | `@Endpoint(..., response: User.self)` generates `typealias Response = User`; omitting it requires a user-declared `Response` | Both forms compile; the generated typealias appears exactly once | T-12.1 |
| FR-13 | An absolute URL as the macro's path argument generates the `baseURL` requirement; a relative path leaves `baseURL` to the conforming type | Absolute form compiles with no user-declared `baseURL` | T-13.1 |
| FR-14 | Static members, computed properties, and non-stored declarations are ignored by parameter collection | A `static let` and a computed `var` appear nowhere in the expansion | T-14.1 |
| FR-15 | Misuse produces a located diagnostic, never a malformed expansion: non-struct declaration, unparsable path, placeholder without a property, two `@Body` properties, a marker with an empty name, `@Body` on a body-less method | Each case emits its documented message and no partial member is generated | T-15.1 |
| FR-16 | The macro ships behind the `EndpointMacros` package trait | Trait disabled: `swift package show-dependencies` lists no packages and `NovaNetworkMacros` is an empty module. Trait enabled: macro is usable | T-16.1 |

#### OpenAPI generation

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| FR-17 | Read OpenAPI 3.0.x and 3.1.x documents supplied as JSON or as the documented YAML subset | The reference fixture parses identically from both encodings | T-17.1 |
| FR-18 | Emit one `EndpointDefinition`-conforming struct per operation, with a deterministic name derived from `operationId` or from method and path | Two runs over one spec produce byte-identical output; names are stable and collision-free | T-18.1 |
| FR-19 | Emit `Codable` models from `components/schemas`, including nested objects, arrays, enums, `$ref`, `allOf` merging, and `additionalProperties` maps | Generated models decode the fixture payloads | T-19.1 |
| FR-20 | Map path, query, and header parameters with their required/optional shape and array style/explode settings | An optional query parameter is emitted as an optional Swift property; `explode: false` selects `commaSeparated` | T-20.1 |
| FR-21 | Map `requestBody` `application/json` schemas to a body property; select the response type from the lowest 2xx `application/json` response; operations with no response content decode to `NoContent` | Each mapping verified against the fixture | T-21.1 |
| FR-22 | Rename identifiers that are not valid Swift, mapping wire names through `CodingKeys` when they differ | `user_id` becomes `userId` with a `CodingKeys` entry; Swift keywords are escaped | T-22.1 |
| FR-23 | Generated code depends only on `NovaNetworkCore` — never on the macro or swift-syntax | Generated fixture output compiles in a target that does not enable the trait | T-23.1 |
| FR-24 | Unsupported spec constructs are reported as warnings naming the location and are never silently dropped | `oneOf` in the fixture yields a warning and a documented fallback type | T-24.1 |
| FR-25 | Ship a CLI (`nova-openapi`) and a SwiftPM command plugin wrapping it | `swift package nova-openapi --spec … --output …` writes the file after the sandbox opt-in | T-25.1 |
| FR-26 | Emit a decoder factory configured for the date formats the spec uses | Generated `makeDecoder()` decodes an ISO 8601 `date-time` field | T-26.1 |

### UX requirements (UR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| UR-1 | The declarative form is shorter than the hand-written form it replaces for a simple GET | ≤ 8 lines including the type declaration | `Examples/DeclarativeEndpoints` |
| UR-2 | Every public symbol has a DocC comment, and the macro carries usage documentation on its declaration | Documentation build produces no missing-doc warnings for new symbols | DocC build |
| UR-3 | Diagnostics say what to do, not only what is wrong | Each message in FR-15 names the offending symbol and the expected form | T-15.1 |
| UR-4 | Generated files carry a header naming the source spec and stating that edits will be overwritten | Header present and stable across runs | T-18.1 |

### Data requirements (DR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| DR-1 | No new persisted state, on-disk format, or schema version | No change under `Networking/OfflineQueue` or `Transfers` | Diff review |
| DR-2 | Generator output is a build input, not runtime data; nothing is written outside the requested output path | Command plugin declares exactly one writable path | T-25.1 |
| DR-3 | Specs may contain credentials in `servers` variables; generated code embeds only the server URL and never `securitySchemes` values | No token, key, or credential literal appears in generated output | T-24.2 |

### Analytics requirements (AR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| AR-1 | No new runtime telemetry. Declarative endpoints produce ordinary `APIRequest` values executed by the unchanged pipeline, so existing Observability Contract v2 events already cover them | Executing a generated endpoint emits exactly the same event sequence as the hand-written equivalent | T-27.1 |

### Non-functional requirements (NFR)

| ID | Requirement | Acceptance criteria | Trace links |
|---|---|---|---|
| NFR-1 | Default consumers resolve zero package dependencies | `swift package show-dependencies` output is empty with the trait disabled | T-16.1 |
| NFR-2 | All new runtime code compiles on Linux and under `-strict-concurrency=complete` | Linux Core CI job passes with the new files | CI |
| NFR-3 | Source-compatible and additive: no existing public symbol changes shape | API breaking-changes gate passes with no new allowlist entries | CI |
| NFR-4 | Unit coverage stays above 90% | Coverage gate passes | CI |
| NFR-5 | Generation of the reference spec completes in under 2 seconds | Measured in the generator test | T-18.2 |
| NFR-6 | Macro expansion adds no runtime allocation beyond the hand-written equivalent | Expansion calls the same builder the hand-written form would | T-8.1 |

### Edge cases (EC)

| ID | Scenario | Expected behavior | Trace links |
|---|---|---|---|
| EC-1 | Path template with no leading slash, or a base URL with a trailing slash | Exactly one separator in the result; no empty segment | T-4.2 |
| EC-2 | Path parameter whose value serializes to no strings (`nil`) | Throws `missingPathParameter`, no request built | T-7.1 |
| EC-3 | Placeholder in the template with no matching property | Macro diagnostic at compile time; runtime builder throws `unresolvedPathPlaceholder` | T-15.1, T-7.1 |
| EC-4 | Two properties mapped to the same query name | Both are emitted, in declaration order — HTTP allows repeats | T-11.2 |
| EC-5 | Property named with a Swift keyword, or a wire name that is not a valid identifier | Escaped with backticks or renamed with a `CodingKeys` mapping | T-22.1 |
| EC-6 | Spec with no `servers` entry | Generator emits a `baseURL` requirement instead of a literal, and warns | T-24.1 |
| EC-7 | `$ref` cycle between schemas | Detected and reported; no infinite recursion or stack overflow | T-19.2 |
| EC-8 | YAML using tabs for indentation, or a construct outside the supported subset | Located parse error naming line and column | T-17.2 |
| EC-9 | Operation with no `operationId` and a path containing several parameters | Deterministic derived name, documented rule, no collision | T-18.1 |
| EC-10 | Empty response body for a `204` operation | Decodes to `NoContent` without invoking `JSONDecoder` | T-21.2 |
| EC-11 | `@Body` on a struct whose method is `GET` | Diagnostic rejecting the combination | T-15.1 |
| EC-12 | Macro applied to a generic struct or one with an existing `Endpoint` conformance | Diagnostic rather than a duplicate-conformance compile error | T-15.2 |

## 6. State Machine and Flows

This feature is build-time; it has no runtime state machine. Two flows apply.

### Macro expansion flow

| From | Trigger | To | Notes |
|---|---|---|---|
| `unexpanded` | Compiler expands `@Endpoint` | `parsed` | Declaration read, parameters collected |
| `parsed` | Validation passes | `expanded` | Extension with conformance and `makeRequest()` emitted |
| `parsed` | Validation fails | `diagnosed` | One or more diagnostics; no partial members emitted |

### Generation flow

| From | Trigger | To | Notes |
|---|---|---|---|
| `idle` | CLI or plugin invoked | `reading` | Spec located and decoded (JSON or YAML) |
| `reading` | Decode fails | `failed` | Located error, non-zero exit, no output written |
| `reading` | Decode succeeds | `modeling` | Operations and schemas resolved, `$ref`s followed |
| `modeling` | Unsupported construct found | `modeling` | Warning recorded, fallback applied, generation continues |
| `modeling` | Model complete | `emitting` | Deterministic Swift source rendered |
| `emitting` | Write succeeds | `done` | Output path written atomically; warnings printed to stderr |

## 7. Engineering Notes

- **One runtime, two front ends.** The macro and the generator both emit calls into
  `EndpointRequestBuilder`. Serialization rules live in `NovaNetworkCore`, are unit-tested once,
  and are identical for hand-written, macro-generated, and spec-generated endpoints. Generated
  source stays thin and reviewable.
- **The generator does not emit macro attributes.** Generated code conforms to
  `EndpointDefinition` directly, so it compiles with the trait disabled and carries no swift-syntax
  dependency. The macro is for hand-written endpoints; the generator is for specs; neither
  requires the other.
- **Trait, not a separate package.** `EndpointMacros` is a SwiftPM trait rather than a second
  repository so the macro version cannot drift from the runtime it targets.
- **Unannotated properties default to query.** The alternative — requiring a marker on every
  property — makes the common GET case as verbose as the code being replaced. Path binding wins
  over the query default because it is explicit in the template.
- **Percent-encoding is the builder's job, never the caller's.** Path values are encoded against
  the unreserved set; query values go through `URLComponents` so existing `APIRequest` behavior is
  preserved exactly.
- **YAML subset over a YAML dependency.** Supported: block mappings and sequences, flow mappings
  and sequences, plain and quoted scalars, `|` and `>` block scalars, comments, and document
  markers. Not supported: anchors, aliases, tags, multi-document streams, complex keys. Anything
  unsupported raises a located error — the parser never guesses.
- **Dates.** `format: date-time` maps to `Foundation.Date`, which requires a decoder configured for
  ISO 8601. The generator emits a `makeDecoder()` factory so the requirement is impossible to miss,
  and the DocC article states it.

## 8. Test Matrix

| Requirement ID | Test ID | Test type | Owner | Status |
|---|---|---|---|---|
| FR-1 | T-1.1 | unit | Engineering | done |
| FR-2 | T-2.1 | unit | Engineering | done |
| FR-3 | T-3.1 | unit | Engineering | done |
| FR-4, EC-1 | T-4.1, T-4.2 | unit | Engineering | done |
| FR-5 | T-5.1 | unit | Engineering | done |
| FR-6 | T-6.1 | unit | Engineering | done |
| FR-7, EC-2, EC-3 | T-7.1 | unit | Engineering | done |
| FR-8, NFR-6 | T-8.1 | unit (macro expansion) | Engineering | done |
| FR-9 | T-9.1 | unit (macro expansion) | Engineering | done |
| FR-10 | T-10.1 | unit (macro expansion) | Engineering | done |
| FR-11, EC-4 | T-11.1, T-11.2 | unit | Engineering | done |
| FR-12 | T-12.1 | unit (macro expansion) | Engineering | done |
| FR-13 | T-13.1 | unit (macro expansion) | Engineering | done |
| FR-14 | T-14.1 | unit (macro expansion) | Engineering | done |
| FR-15, EC-3, EC-11, EC-12 | T-15.1, T-15.2 | unit (diagnostics) | Engineering | done |
| FR-16, NFR-1 | T-16.1 | integration (CI) | Engineering | done |
| FR-17, EC-8 | T-17.1, T-17.2 | unit | Engineering | done |
| FR-18, EC-9, NFR-5 | T-18.1, T-18.2 | unit | Engineering | done |
| FR-19, EC-7 | T-19.1, T-19.2 | unit | Engineering | done |
| FR-20 | T-20.1 | unit | Engineering | done |
| FR-21, EC-10 | T-21.1, T-21.2 | unit | Engineering | done |
| FR-22, EC-5 | T-22.1 | unit | Engineering | done |
| FR-23 | T-23.1 | integration (compile fixture) | Engineering | done |
| FR-24, EC-6, DR-3 | T-24.1, T-24.2 | unit | Engineering | done |
| FR-25, DR-2 | T-25.1 | integration | Engineering | done |
| FR-26 | T-26.1 | unit | Engineering | done |
| AR-1 | T-27.1 | integration | Engineering | done |

### Negative tests

- T-7.1 covers every `EndpointDefinitionError` case, including a placeholder left unresolved.
- T-15.1 and T-15.2 assert diagnostic messages for all six documented misuse cases and confirm no
  members are emitted alongside a diagnostic.
- T-17.2 asserts located errors for tabs, unterminated quotes, and unsupported anchors.
- T-19.2 asserts a reported error for a `$ref` cycle instead of a hang.
- T-24.1 asserts warnings — not silent fallbacks — for `oneOf` and for a missing `servers` entry.
- T-24.2 asserts no credential from `securitySchemes` reaches generated output.
