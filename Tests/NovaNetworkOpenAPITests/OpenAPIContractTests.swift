import Foundation
import Testing
import NovaNetworkClient
import NovaNetworkCore
@testable import NovaNetworkOpenAPI

// Requirements: FR-CONTRACT-1…9, EC-CONTRACT-1…5, AR-CONTRACT-1…3
// (docs/dfr/NOVA_NETWORK_V3_7_DFR.md §C). Tests: T-20.1…T-20.10.

private let petstore: OpenAPIContract = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Examples/OpenAPIPetstore/petstore.yaml")
    // swiftlint:disable:next force_try
    return try! OpenAPIContract(specText: String(contentsOf: url, encoding: .utf8))
}()

private let json = ["Content-Type": "application/json; charset=utf-8"]

private func validate(
    _ path: String,
    method: String = "GET",
    status: Int = 200,
    headers: [String: String] = json,
    in contract: OpenAPIContract = petstore,
    _ body: String
) -> [ContractViolation] {
    contract.validate(
        method: method,
        url: URL(string: "https://api.petstore.example.com\(path)")!,
        statusCode: status,
        headers: headers,
        body: Data(body.utf8)
    ).violations
}

private func contract(_ yaml: String) throws -> OpenAPIContract {
    try OpenAPIContract(specText: yaml)
}

/// A contract with one `GET /thing` returning the given schema.
private func contract(returning schema: String) throws -> OpenAPIContract {
    let indented = schema.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "                " + $0 }
        .joined(separator: "\n")
    return try contract("""
    openapi: 3.1.0
    info:
      title: T
      version: "1"
    paths:
      /thing:
        get:
          responses:
            "200":
              description: ok
              content:
                application/json:
                  schema:
    \(indented)
    """)
}

private let breaking = ContractViolationSeverity.breaking
private let drift = ContractViolationSeverity.drift

@Suite
struct OpenAPIContractMatchingTests {
    @Test // T-20.1
    func aContractIsBuiltFromYAMLOrJSONAndNeedsPaths() throws {
        #expect(throws: GenerationError.self) { try contract("openapi: 3.1.0\ninfo:\n  title: T\n") }
        #expect(throws: SpecParseError.self) { try contract("paths: [") }

        let fromJSON = try contract(#"{"openapi":"3.1.0","paths":{"/a":{"get":{"responses":{"204":{"description":"none"}}}}}}"#)
        #expect(validate("/a", method: "GET", status: 204, in: fromJSON, "") == [])

        // The petstore's server is `https://{host}/v1`: the base path survives the variable.
        #expect(validate("/v1/pets", "[]") == [])
        // And a request without the base path still matches.
        #expect(validate("/pets", "[]") == [])
    }

    @Test // T-20.2
    func theOperationAndResponseAreFoundByMethodPathAndStatus() throws {
        #expect(validate("/v1/nothing", method: "POST", status: 201, "{}") == [
            ContractViolation(kind: .undocumentedOperation, pointer: "", severity: drift),
        ])
        #expect(validate("/v1/pets/1", method: "GET", status: 500, "{}") == [
            ContractViolation(kind: .undocumentedStatusCode(500), pointer: "", severity: drift),
        ])
        #expect(validate("/v1/pets", method: "GET", "not json") == [
            ContractViolation(kind: .invalidJSON, pointer: "", severity: breaking),
        ])

        // A literal segment outranks a parameter, and `2XX` and `default` are fallbacks.
        let ranked = try contract("""
        openapi: 3.1.0
        paths:
          /users/{id}:
            get:
              responses:
                "2XX":
                  description: ok
                  content:
                    application/json:
                      schema:
                        type: object
          /users/me:
            get:
              responses:
                default:
                  description: ok
                  content:
                    application/json:
                      schema:
                        type: array
        """)
        let report = ranked.validate(method: "get", url: URL(string: "https://x/users/me")!, statusCode: 299, body: Data("[]".utf8))
        #expect(report.violations == [])
        #expect(report.operationPath == "/users/me")
        #expect(report.method == "GET")
        #expect(validate("/users/7", method: "GET", status: 203, in: ranked, "{}") == [])
        #expect(validate("/users/7", method: "GET", status: 203, in: ranked, "[]") == [
            ContractViolation(kind: .typeMismatch(expected: "object", actual: "array"), pointer: "", severity: breaking),
        ])
    }
}

@Suite
struct OpenAPIContractSchemaTests {
    @Test // T-20.3
    func typesRequiredNullAndEnumsAreChecked() throws {
        #expect(validate("/v1/pets/1", #"{"name":"Rex","id":1,"tag":null,"status":"sold"}"#) == [])

        #expect(validate("/v1/pets/1", #"{"name":"Rex","id":true}"#) == [
            ContractViolation(kind: .typeMismatch(expected: "integer", actual: "boolean"), pointer: "/id", severity: breaking),
        ])
        #expect(validate("/v1/pets/1", #"{"name":"Rex","id":1.5}"#) == [
            ContractViolation(kind: .typeMismatch(expected: "integer", actual: "number"), pointer: "/id", severity: breaking),
        ])
        #expect(validate("/v1/pets/1", #"{"id":1}"#) == [
            ContractViolation(kind: .missingRequiredField("name"), pointer: "", severity: breaking),
        ])
        #expect(validate("/v1/pets/1", #"{"name":null,"id":1}"#) == [
            ContractViolation(kind: .nullNotAllowed, pointer: "/name", severity: breaking),
        ])
        #expect(validate("/v1/pets/1", #"{"name":"Rex","id":1,"status":"adopted"}"#) == [
            ContractViolation(kind: .unexpectedEnumValue("adopted"), pointer: "/status", severity: breaking),
        ])
        #expect(validate("/v1/pets", #"[{"name":"Rex","id":1},{"name":7,"id":2}]"#) == [
            ContractViolation(kind: .typeMismatch(expected: "string", actual: "integer"), pointer: "/1/name", severity: breaking),
        ])

        let numbers = try contract(returning: "type: object\nproperties:\n  n:\n    type: number\n  b:\n    type: boolean")
        #expect(validate("/thing", method: "GET", in: numbers, #"{"n":1,"b":false}"#) == [])
        #expect(validate("/thing", method: "GET", in: numbers, #"{"n":1.25,"b":0}"#) == [
            ContractViolation(kind: .typeMismatch(expected: "boolean", actual: "integer"), pointer: "/b", severity: breaking),
        ])
        let nullType = try contract(returning: "type: [string, \"null\"]")
        #expect(validate("/thing", method: "GET", in: nullType, "null") == [])
        #expect(validate("/thing", method: "GET", in: nullType, "\"s\"") == [])
    }

    @Test // T-20.4
    func referencesAndCompositionAreFollowedAsDeepAsTheDataGoes() throws {
        let nested = #"{"name":"a","id":1,"parent":{"name":"b","id":2,"parent":{"name":"c","id":"three"}}}"#
        #expect(validate("/v1/pets/1", nested) == [
            ContractViolation(kind: .typeMismatch(expected: "integer", actual: "string"), pointer: "/parent/parent/id", severity: breaking),
        ])

        // oneOf / anyOf: one matching member is enough; none is breaking.
        #expect(validate("/v1/pets/1/photo", headers: ["Content-Type": "application/vnd.petstore+json"], #"{"payload":"x","nickname":null}"#) == [])
        #expect(validate("/v1/pets/1/photo", headers: ["Content-Type": "application/vnd.petstore+json"], #"{"payload":3}"#) == [])
        #expect(validate("/v1/pets/1/photo", headers: ["Content-Type": "application/vnd.petstore+json"], #"{"payload":true}"#) == [
            ContractViolation(kind: .noMatchingSchema, pointer: "/payload", severity: breaking),
        ])

        // A reference cycle in the spec itself ends rather than looping.
        let selfReferencing = try contract("""
        openapi: 3.1.0
        paths:
          /a:
            get:
              responses:
                "200":
                  description: ok
                  content:
                    application/json:
                      schema:
                        $ref: "#/components/schemas/A"
        components:
          schemas:
            A:
              $ref: "#/components/schemas/B"
            B:
              $ref: "#/components/schemas/A"
        """)
        #expect(validate("/a", method: "GET", in: selfReferencing, "{}") == [])
    }

    @Test // T-20.5
    func undocumentedFieldsAreDriftUnlessTheSchemaAllowsOrForbidsThem() throws {
        // A field from one allOf member is documented for the whole object.
        #expect(validate("/v1/pets/1", #"{"name":"Rex","id":1,"color":"brown"}"#) == [
            ContractViolation(kind: .undocumentedField("color"), pointer: "", severity: drift),
        ])
        // additionalProperties with a schema validates the extra values instead.
        let labels = ["Content-Type": "application/vnd.petstore+json"]
        #expect(validate("/v1/pets/1/photo", headers: labels, #"{"labels":{"a":"x","b":2}}"#) == [
            ContractViolation(kind: .typeMismatch(expected: "string", actual: "integer"), pointer: "/labels/b", severity: breaking),
        ])

        let closed = try contract(returning: "type: object\nadditionalProperties: false\nproperties:\n  a:\n    type: string")
        #expect(validate("/thing", method: "GET", in: closed, #"{"a":"x","b":1}"#) == [
            ContractViolation(kind: .undocumentedField("b"), pointer: "", severity: breaking),
        ])
        let open = try contract(returning: "type: object\nadditionalProperties: true\nproperties:\n  a:\n    type: string")
        #expect(validate("/thing", method: "GET", in: open, #"{"a":"x","b":1}"#) == [])
        let escaped = try contract(returning: "type: object\nproperties:\n  o:\n    type: object\n    properties:\n      x:\n        type: string")
        #expect(validate("/thing", method: "GET", in: escaped, #"{"o":{"a/b~c":1}}"#) == [
            ContractViolation(kind: .undocumentedField("a/b~c"), pointer: "/o", severity: drift),
        ])
    }

    @Test // T-20.9
    func bodiesThatAreNotJSONOrNotDescribedAreLeftAlone() throws {
        #expect(validate("/v1/pets/1", headers: ["Content-Type": "text/html"], "<html>") == [])
        #expect(validate("/v1/pets/1", method: "DELETE", status: 204, "anything at all") == [])
        #expect(validate("/v1/pets", headers: [:], "[]") == [])
    }

    @Test
    func violationsReadAsLogLines() {
        let lines = [
            ContractViolation(kind: .undocumentedOperation, pointer: "", severity: drift),
            ContractViolation(kind: .undocumentedStatusCode(418), pointer: "", severity: drift),
            ContractViolation(kind: .invalidJSON, pointer: "", severity: breaking),
            ContractViolation(kind: .typeMismatch(expected: "integer", actual: "string"), pointer: "/id", severity: breaking),
            ContractViolation(kind: .missingRequiredField("name"), pointer: "", severity: breaking),
            ContractViolation(kind: .nullNotAllowed, pointer: "/name", severity: breaking),
            ContractViolation(kind: .unexpectedEnumValue("adopted"), pointer: "/status", severity: breaking),
            ContractViolation(kind: .noMatchingSchema, pointer: "/payload", severity: breaking),
            ContractViolation(kind: .undocumentedField("color"), pointer: "", severity: drift),
        ].map(\.description)

        #expect(lines == [
            "drift: body: operation is not in the spec",
            "drift: body: status 418 is not in the spec",
            "breaking: body: body is not valid JSON",
            "breaking: /id: expected integer, got string",
            "breaking: body: required field 'name' is missing",
            "breaking: /name: null is not allowed",
            "breaking: /status: 'adopted' is not one of the enum values",
            "breaking: /payload: matches none of the oneOf/anyOf schemas",
            "drift: body: field 'color' is not in the spec",
        ])
    }
}

private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ContractReport] = []

    func record(_ report: ContractReport) {
        lock.lock()
        recorded.append(report)
        lock.unlock()
    }

    var all: [ContractReport] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private struct FixedTransport: NetworkTransport {
    let body: String
    func execute(_ request: APIRequest) async throws -> NetworkResponse {
        NetworkResponse(statusCode: 200, headers: json, body: Data(body.utf8))
    }
}

private func client(serving body: String, _ middleware: NetworkMiddleware) -> NetworkClient {
    NetworkClient(configuration: NetworkClientConfiguration(transport: FixedTransport(body: body), middlewares: [middleware]))
}

private let petRequest = APIRequest(method: .get, url: URL(string: "https://api.petstore.example.com/v1/pets/1")!)

@Suite
struct OpenAPIContractMiddlewareTests {
    @Test // T-20.6
    func aDifferingResponseIsReportedWithWhereAndWhatAndAConformingOneIsNot() async throws {
        let reports = Reports()
        let middleware = NetworkMiddleware.openAPIContract(petstore) { reports.record($0) }

        _ = try await client(serving: #"{"name":"Rex","id":1}"#, middleware).load(request: petRequest, authScope: nil)
        #expect(reports.all.isEmpty)

        _ = try await client(serving: #"{"name":"Rex","id":"1","color":"brown"}"#, middleware).load(request: petRequest, authScope: nil)
        #expect(reports.all == [
            ContractReport(
                method: "GET",
                path: "/v1/pets/1",
                operationPath: "/pets/{petId}",
                statusCode: 200,
                violations: [
                    ContractViolation(kind: .typeMismatch(expected: "integer", actual: "string"), pointer: "/id", severity: breaking),
                    ContractViolation(kind: .undocumentedField("color"), pointer: "", severity: drift),
                ]
            ),
        ])
    }

    @Test // T-20.7
    func eachViolationIsReportedOnceUnlessAskedOtherwise() async throws {
        let reports = Reports()
        let once = client(serving: #"{"name":"Rex","id":"1"}"#, .openAPIContract(petstore) { reports.record($0) })
        for _ in 0..<3 {
            _ = try await once.load(request: petRequest, authScope: nil, cachePolicy: .networkOnly, options: .init(coalescingMode: .disabled))
        }
        #expect(reports.all.count == 1)

        let every = Reports()
        let always = client(
            serving: #"{"name":"Rex","id":"1"}"#,
            .openAPIContract(petstore, reportsEachViolationOnce: false) { every.record($0) }
        )
        for _ in 0..<3 {
            _ = try await always.load(request: petRequest, authScope: nil, cachePolicy: .networkOnly, options: .init(coalescingMode: .disabled))
        }
        #expect(every.all.count == 3)
    }

    @Test // T-20.8
    func failOnBreakingTurnsABreakingViolationIntoAnError() async throws {
        let strict = NetworkMiddleware.openAPIContract(petstore, failOnBreaking: true) { _ in }

        await #expect {
            _ = try await client(serving: #"{"id":1}"#, strict).load(request: petRequest, authScope: nil)
        } throws: { error in
            guard case NetworkError.transport(let underlying) = error,
                  let violation = underlying as? ContractViolationError else { return false }
            return violation.report.violations == [
                ContractViolation(kind: .missingRequiredField("name"), pointer: "", severity: breaking),
            ] && violation.errorDescription == "GET /pets/{petId} does not match its spec: breaking: body: required field 'name' is missing"
        }

        // Drift alone never fails a request.
        _ = try await client(serving: #"{"name":"Rex","id":1,"color":"x"}"#, strict).load(request: petRequest, authScope: nil)
    }

    @Test // T-20.9
    func theSampleRateIsClampedAndDecidesWhatIsChecked() async throws {
        let none = Reports()
        _ = try await client(serving: #"{"id":"x"}"#, .openAPIContract(petstore, sampleRate: -1) { none.record($0) })
            .load(request: petRequest, authScope: nil)
        #expect(none.all.isEmpty)

        let sampled = Reports()
        let rolls = Rolls([0.9, 0.1])
        let middleware = NetworkMiddleware.openAPIContract(
            petstore,
            sampleRate: 0.5,
            reportsEachViolationOnce: false,
            random: { rolls.next() }
        ) { sampled.record($0) }
        let sampling = client(serving: #"{"id":"x"}"#, middleware)
        for _ in 0..<2 {
            _ = try await sampling.load(request: petRequest, authScope: nil, cachePolicy: .networkOnly, options: .init(coalescingMode: .disabled))
        }
        #expect(sampled.all.count == 1)

        let all = Reports()
        _ = try await client(serving: #"{"id":"x"}"#, .openAPIContract(petstore, sampleRate: 4) { all.record($0) })
            .load(request: petRequest, authScope: nil)
        #expect(all.all.count == 1)
    }

    @Test // T-20.10
    func conformingPetstoreTrafficProducesNoReports() async throws {
        let reports = Reports()
        let middleware = NetworkMiddleware.openAPIContract(petstore) { reports.record($0) }
        let pets = #"[{"name":"Rex","id":1,"tag":"dog","status":"available","created_at":"2026-01-01T00:00:00Z","dimensions":{"width":1,"height":2.5}}]"#
        _ = try await client(serving: pets, middleware)
            .load(request: APIRequest(method: .get, url: URL(string: "https://api.petstore.example.com/v1/pets")!), authScope: nil)

        #expect(reports.all.isEmpty)
    }
}

private final class Rolls: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double]

    init(_ values: [Double]) {
        self.values = values
    }

    func next() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? 0 : values.removeFirst()
    }
}
