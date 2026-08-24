# Traceability Pack v2.11

## Contract

- DFR: `docs/dfr/NOVA_NETWORK_V2_11_DFR.md`
- Scope: the shared declarative runtime (`EndpointDefinition`, `EndpointRequestBuilder`,
  `EndpointParameterConvertible`), the trait-gated `@Endpoint` macro and its parameter markers, and
  the OpenAPI 3.0/3.1 reader, Swift emitter, CLI, and SwiftPM command plugin.

## Requirement to implementation mapping

| Requirement IDs | Implementation |
|---|---|
| FR-1 | `Sources/NovaNetworkCore/EndpointDefinition.swift` |
| FR-2, FR-4, FR-6, FR-7, EC-1, EC-2, EC-3 | `Sources/NovaNetworkCore/EndpointRequestBuilder.swift` |
| FR-3, FR-5, EC-4 | `Sources/NovaNetworkCore/EndpointParameterConvertible.swift` |
| FR-8, FR-11, FR-12, FR-13, NFR-6 | `Sources/NovaNetworkMacrosPlugin/EndpointMacro.swift` |
| FR-9, FR-10, FR-14 | `Sources/NovaNetworkMacrosPlugin/EndpointParameter.swift` |
| FR-15, UR-3, EC-11, EC-12 | `Sources/NovaNetworkMacrosPlugin/MacroDiagnostics.swift` |
| FR-16, NFR-1 | `Package.swift` (`traits:`, trait-conditioned target dependencies), `Sources/NovaNetworkMacros/EndpointMacros.swift` |
| FR-17, EC-8 | `Sources/NovaNetworkOpenAPI/SpecParser.swift`, `FlowScanner.swift`, `SpecValue.swift` |
| FR-18, FR-22, EC-5, EC-9 | `Sources/NovaNetworkOpenAPI/SwiftNaming.swift`, `SwiftEndpointEmitter.swift` |
| FR-19, FR-20, FR-21, FR-24, EC-6, EC-7, EC-10 | `Sources/NovaNetworkOpenAPI/OpenAPIReader.swift`, `OpenAPIModel.swift` |
| FR-23, UR-1, UR-4 | `Sources/NovaNetworkOpenAPI/SwiftEndpointEmitter.swift`, `Examples/OpenAPIPetstore` |
| FR-25, DR-2 | `Sources/NovaNetworkOpenAPIGenerator/main.swift`, `Plugins/GenerateOpenAPIEndpoints/Plugin.swift` |
| FR-26 | `SwiftEndpointEmitter.namespaceSection`, `EndpointParameterConvertible` `Date` conformance |
| DR-1, DR-3, AR-1 | no persistence or telemetry surface changed; generated code embeds only the server URL |
| UR-2 | DocC comments on every new public symbol, `DeclarativeEndpoints.md`, `DeclareEndpointsWithMacro.tutorial` |
| NFR-2 | Linux CI gate extended to `NovaNetworkOpenAPI`; no Apple-only import in new runtime code |
| NFR-3 | `api-breaking-changes-gate`, no new entries in `docs/api-breakage-allowlist.txt` |
| NFR-4 | coverage gate scope extended to `Sources/NovaNetworkOpenAPI` |
| NFR-5 | `T-18.2` |

## Requirement to test mapping

| Test IDs | Requirement IDs | Type | Executable reference |
|---|---|---|---|
| T-1.1, T-21.2 | FR-1, EC-10 | unit | `EndpointDefinitionDefaultsTests` |
| T-2.1, T-4.1, T-4.2, T-5.1, T-6.1, T-11.2 | FR-2, FR-4, FR-5, FR-6, EC-1, EC-4 | unit | `EndpointRequestBuilderTests` |
| T-3.1 | FR-3 | unit | `EndpointParameterConvertibleTests` |
| T-7.1 | FR-7, EC-2, EC-3 | unit | `EndpointDefinitionErrorTests` |
| T-8.1, T-12.1, T-13.1 | FR-8, FR-12, FR-13, NFR-6 | unit (expansion) | `EndpointMacroExpansionTests` |
| T-9.1, T-10.1, T-11.1, T-14.1 | FR-9, FR-10, FR-11, FR-14 | unit (compiled macro) | `EndpointMacroBehaviorTests` |
| T-15.1, T-15.2 | FR-15, UR-3, EC-3, EC-11, EC-12 | unit (diagnostics) | `EndpointMacroDiagnosticTests` |
| T-16.1 | FR-16, NFR-1 | CI | `endpoint-macros-trait` job |
| T-17.1, T-17.2 | FR-17, EC-8 | unit | `SpecParserTests`, `SpecParserErrorTests`, `FlowScannerDetailTests` |
| T-18.1, T-18.2 | FR-18, EC-9, NFR-5 | unit | `OpenAPIGenerationOutputTests`, `SwiftNamingTests` |
| T-19.1, T-19.2 | FR-19, EC-7 | unit | `GeneratedPetstoreTypeTests`, `OpenAPIGenerationWarningTests` |
| T-20.1 | FR-20 | unit | `GeneratedPetstoreRequestTests` |
| T-21.1 | FR-21 | unit | `GeneratedPetstoreTypeTests` |
| T-22.1 | FR-22, EC-5 | unit | `GeneratedPetstoreTypeTests`, `SwiftNamingTests` |
| T-23.1 | FR-23 | build | `NovaNetworkPetstoreGenerated` target (depends on `NovaNetworkCore` only), `generatedCodeImportsOnlyTheRuntimeAndNeverTheMacro` |
| T-24.1, T-24.2 | FR-24, DR-3, EC-6 | unit | `OpenAPIGenerationWarningTests` |
| T-25.1 | FR-25, DR-2 | CI | `openapi-generator` job (runs the CLI, fails on any diff) |
| T-26.1 | FR-26 | unit | `GeneratedPetstoreTypeTests` |
| T-27.1 | AR-1 | integration | `GeneratedEndpointExecutionTests` |
| T-GATE-1...5 | NFR-1...NFR-4 | CI | zero-dependency check, trait build/test, coverage gate, API breakage gate, Linux gate |

## Coverage at merge

| Scope | Line coverage |
|---|---|
| `Sources/NovaNetworkClient` + `Sources/NovaNetworkCore` (existing gate) | 90.20% |
| New `NovaNetworkCore` files (`EndpointDefinition`, `EndpointRequestBuilder`, `EndpointParameterConvertible`) | 98.85% |
| `Sources/NovaNetworkOpenAPI` (added to the gate) | 93.05% |

## Security and data contract

- No persisted state, on-disk format, or schema version changed.
- Generated source embeds the resolved server URL and nothing else from the document:
  `securitySchemes` are never read into output, asserted by `securitySchemeSecretsNeverReachGeneratedSource`.
- The command plugin declares exactly one permission, `writeToPackageDirectory`, and the CLI writes
  only the path passed as `--output`.
- The macro runs at compile time in the compiler's plugin sandbox and performs no I/O.

## Verification gaps

- The `nova-openapi` CLI's argument parsing lives in an executable target and is exercised by the
  `openapi-generator` CI job rather than by unit tests; the generator library beneath it is unit
  tested directly.
- The trait-enabled configuration is built and tested on macOS only. The Linux gate compiles the
  generator but not the macro, which needs a swift-syntax build on that platform.
