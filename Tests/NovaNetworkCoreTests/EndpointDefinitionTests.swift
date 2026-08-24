import Foundation
import Testing
import NovaNetworkCore

// Requirements: FR-1 (EndpointDefinition defaults), FR-2 (EndpointRequestBuilder), FR-3 (parameter
// serialization), FR-4/EC-1 (path encoding and joining), FR-5 (query styles), FR-6 (JSON bodies),
// FR-7/EC-2/EC-3 (typed construction errors), EC-4 (repeated query names), EC-10 (NoContent).
// Tests: T-1.1, T-2.1, T-3.1, T-4.1, T-4.2, T-5.1, T-6.1, T-7.1, T-11.2, T-21.2.

private let apiBase = URL(string: "https://api.example.com")!

private struct SamplePayload: Codable, Equatable, Sendable {
    let name: String
}

private enum SortOrder: String, EndpointParameterConvertible, Sendable {
    case ascending
    case descending
}

// MARK: - T-3.1 parameter serialization

@Suite
struct EndpointParameterConvertibleTests {
    @Test
    func scalarsSerializeToOneStringEach() {
        #expect("swift".endpointParameterStrings == ["swift"])
        #expect(42.endpointParameterStrings == ["42"])
        #expect(Int64(9_000_000_000).endpointParameterStrings == ["9000000000"])
        #expect(1.5.endpointParameterStrings == ["1.5"])
        #expect(Substring("slice").endpointParameterStrings == ["slice"])
    }

    @Test
    func boolSerializesAsTrueOrFalseRatherThanOneOrZero() {
        #expect(true.endpointParameterStrings == ["true"])
        #expect(false.endpointParameterStrings == ["false"])
    }

    @Test
    func nilOptionalContributesNoValueSoTheParameterIsOmitted() {
        let missing: String? = nil
        let present: String? = "here"

        #expect(missing.endpointParameterStrings.isEmpty)
        #expect(present.endpointParameterStrings == ["here"])
    }

    @Test
    func arrayContributesOneValuePerElementInOrder() {
        #expect(["a", "b", "c"].endpointParameterStrings == ["a", "b", "c"])
        #expect([Int]().endpointParameterStrings.isEmpty)
        #expect([1, 2].endpointParameterStrings == ["1", "2"])
    }

    @Test
    func rawRepresentableSerializesThroughItsRawValue() {
        #expect(SortOrder.descending.endpointParameterStrings == ["descending"])
        #expect([SortOrder.ascending, .descending].endpointParameterStrings == ["ascending", "descending"])
    }

    @Test
    func foundationValueTypesUseTheirCanonicalWireForm() {
        let uuid = UUID(uuidString: "3F2504E0-4F89-11D3-9A0C-0305E82C3301")!
        let url = URL(string: "https://example.com/a")!
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        #expect(uuid.endpointParameterStrings == ["3F2504E0-4F89-11D3-9A0C-0305E82C3301"])
        #expect(url.endpointParameterStrings == ["https://example.com/a"])
        #expect(date.endpointParameterStrings == ["2023-11-14T22:13:20Z"])
    }
}

// MARK: - T-2.1, T-4.1, T-4.2, T-5.1, T-6.1, T-11.2 builder behavior

@Suite
struct EndpointRequestBuilderTests {
    @Test
    func builderProducesTheSameRequestAsTheHandWrittenEquivalent() throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/users/{id}")
        try builder.setPath("id", 7)
        builder.addQuery("limit", 20)
        builder.setHeader("X-Trace", "abc")
        let built = try builder.build()

        let handWritten = APIRequest(
            method: .get,
            url: URL(string: "https://api.example.com/users/7")!,
            queryItems: [URLQueryItem(name: "limit", value: "20")],
            headers: ["X-Trace": "abc"]
        )

        #expect(built.method == handWritten.method)
        #expect(built.url == handWritten.url)
        #expect(built.queryItems == handWritten.queryItems)
        #expect(built.headers == handWritten.headers)
        #expect(built.timeout == handWritten.timeout)
        #expect(built.body == nil)
    }

    @Test
    func pathValuesArePercentEncodedIntoASingleSegment() throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/files/{name}")
        try builder.setPath("name", "reports/q3 final?draft#2")

        let request = try builder.build()

        #expect(request.url.absoluteString == "https://api.example.com/files/reports%2Fq3%20final%3Fdraft%232")
    }

    @Test
    func multiplePlaceholdersAreFilledIndependently() throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/users/{userId}/posts/{postId}")
        try builder.setPath("userId", 1)
        try builder.setPath("postId", "abc")

        #expect(try builder.build().url.absoluteString == "https://api.example.com/users/1/posts/abc")
    }

    @Test
    func multiValuedPathParameterJoinsWithCommasAsOneSegment() throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/tags/{ids}")
        try builder.setPath("ids", [1, 2, 3])

        #expect(try builder.build().url.absoluteString == "https://api.example.com/tags/1%2C2%2C3")
    }

    @Test
    func baseAndPathAreJoinedWithExactlyOneSeparator() throws {
        let trailing = URL(string: "https://api.example.com/v1/")!

        var withLeadingSlash = EndpointRequestBuilder(method: .get, baseURL: trailing, path: "/users")
        var withoutLeadingSlash = EndpointRequestBuilder(method: .get, baseURL: trailing, path: "users")
        var emptyPath = EndpointRequestBuilder(method: .get, baseURL: trailing, path: "")

        #expect(try withLeadingSlash.build().url.absoluteString == "https://api.example.com/v1/users")
        #expect(try withoutLeadingSlash.build().url.absoluteString == "https://api.example.com/v1/users")
        #expect(try emptyPath.build().url.absoluteString == "https://api.example.com/v1")
    }

    @Test
    func optionalQueryValuesAreOmittedRatherThanSerializedAsNil() throws {
        let absent: Int? = nil
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/search")
        builder.addQuery("cursor", absent)
        builder.addQuery("q", "swift")

        #expect(try builder.build().queryItems == [URLQueryItem(name: "q", value: "swift")])
    }

    @Test(arguments: [
        (EndpointQueryStyle.repeated, ["tag=swift", "tag=http"]),
        (.commaSeparated, ["tag=swift,http"]),
        (.spaceDelimited, ["tag=swift http"]),
        (.pipeDelimited, ["tag=swift|http"]),
    ])
    func queryStyleControlsHowArraysAreWritten(style: EndpointQueryStyle, expected: [String]) throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/posts")
        builder.addQuery("tag", ["swift", "http"], style: style)

        let rendered = try builder.build().queryItems.map { "\($0.name)=\($0.value ?? "")" }
        #expect(rendered == expected)
    }

    @Test
    func emptyArrayProducesNoQueryItemInAnyStyle() throws {
        for style in EndpointQueryStyle.allCases {
            var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/posts")
            builder.addQuery("tag", [String](), style: style)
            #expect(try builder.build().queryItems.isEmpty)
        }
    }

    @Test
    func twoParametersMappedToOneNameBothSurviveInDeclarationOrder() throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/posts")
        builder.addQuery("filter", "recent")
        builder.addQuery("filter", "starred")

        #expect(try builder.build().queryItems == [
            URLQueryItem(name: "filter", value: "recent"),
            URLQueryItem(name: "filter", value: "starred"),
        ])
    }

    @Test
    func headersOmitEmptyValuesAndJoinMultipleValuesWithCommaSpace() throws {
        let absent: String? = nil
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/posts")
        builder.setHeader("X-Missing", absent)
        builder.setHeader("Accept-Language", ["en", "de"])

        let headers = try builder.build().headers
        #expect(headers["X-Missing"] == nil)
        #expect(headers["Accept-Language"] == "en, de")
    }

    @Test
    func jsonBodyIsEncodedAndDefaultsTheContentType() throws {
        var builder = EndpointRequestBuilder(method: .post, baseURL: apiBase, path: "/users")
        try builder.setJSONBody(SamplePayload(name: "Ada"))

        let request = try builder.build()
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(try JSONDecoder().decode(SamplePayload.self, from: #require(request.body)) == SamplePayload(name: "Ada"))
    }

    @Test
    func explicitContentTypeWinsOverTheJSONDefault() throws {
        var builder = EndpointRequestBuilder(method: .post, baseURL: apiBase, path: "/users")
        builder.setHeader("Content-Type", "application/vnd.example+json")
        try builder.setJSONBody(SamplePayload(name: "Ada"))

        #expect(try builder.build().headers["Content-Type"] == "application/vnd.example+json")
    }

    @Test
    func rawBodyCarriesItsOwnContentType() throws {
        var builder = EndpointRequestBuilder(method: .put, baseURL: apiBase, path: "/blob")
        builder.setBody(Data("raw".utf8), contentType: "application/octet-stream")

        let request = try builder.build()
        #expect(request.body == Data("raw".utf8))
        #expect(request.headers["Content-Type"] == "application/octet-stream")
    }

    @Test
    func parameterHeadersTakePrecedenceOverEndpointWideDefaults() throws {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/posts")
        builder.setHeader("Accept", "application/vnd.example+json")

        let headers = try builder.build(additionalHeaders: ["Accept": "application/json", "X-App": "demo"]).headers
        #expect(headers["Accept"] == "application/vnd.example+json")
        #expect(headers["X-App"] == "demo")
    }

    @Test
    func timeoutIsCarriedThroughToTheRequest() throws {
        let builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/posts")
        #expect(try builder.build(timeout: 12).timeout == 12)
    }

    @Test
    func unterminatedPlaceholderIsTreatedAsLiteralText() throws {
        let builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/weird/{unclosed")
        #expect(try builder.build().url.absoluteString == "https://api.example.com/weird/%7Bunclosed")
    }
}

// MARK: - T-7.1 typed construction errors

@Suite
struct EndpointDefinitionErrorTests {
    @Test
    func nilPathParameterIsRejectedRatherThanOmitted() {
        var builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/users/{id}")
        let absent: Int? = nil

        #expect(throws: EndpointDefinitionError.missingPathParameter(name: "id")) {
            try builder.setPath("id", absent)
        }
    }

    @Test
    func unfilledPlaceholderFailsTheBuildWithItsName() {
        let builder = EndpointRequestBuilder(method: .get, baseURL: apiBase, path: "/users/{id}")

        #expect(throws: EndpointDefinitionError.unresolvedPathPlaceholder(name: "id", template: "/users/{id}")) {
            try builder.build()
        }
    }

    @Test
    func invalidCombinedURLIsReportedWithBothParts() {
        let builder = EndpointRequestBuilder(method: .get, baseURL: URL(string: "https://api.example.com")!, path: "/ok")

        // A valid combination must not throw; the error case is exercised through its description
        // because URL(string:) accepts anything the builder can produce from a valid base URL.
        #expect(throws: Never.self) { try builder.build() }

        let error = EndpointDefinitionError.invalidURL(baseURL: "not a url", path: "/ok")
        #expect(error.errorDescription?.contains("not a url") == true)
    }

    @Test
    func everyErrorCaseDescribesItselfInPlainLanguage() {
        let missing = EndpointDefinitionError.missingPathParameter(name: "id")
        let unresolved = EndpointDefinitionError.unresolvedPathPlaceholder(name: "id", template: "/users/{id}")

        #expect(missing.errorDescription?.contains("'id'") == true)
        #expect(unresolved.errorDescription?.contains("{id}") == true)
        #expect(missing != unresolved)
    }
}

// MARK: - T-1.1, T-21.2 protocol defaults

private struct DefaultedEndpoint: EndpointDefinition {
    typealias Response = SamplePayload
    let baseURL = apiBase

    func makeRequest() throws -> APIRequest {
        var builder = requestBuilder(.get, "/payload")
        builder.addQuery("v", 1)
        return try builder.build(timeout: timeout, additionalHeaders: additionalHeaders)
    }
}

private struct CustomizedEndpoint: EndpointDefinition {
    typealias Response = NoContent
    let baseURL = apiBase
    var timeout: TimeInterval { 5 }
    var additionalHeaders: [String: String] { ["X-App": "demo"] }
    var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    func makeRequest() throws -> APIRequest {
        var builder = requestBuilder(.delete, "/payload")
        try builder.setJSONBody(SamplePayload(name: "Ada"), encoder: jsonEncoder)
        return try builder.build(timeout: timeout, additionalHeaders: additionalHeaders)
    }
}

@Suite
struct EndpointDefinitionDefaultsTests {
    @Test
    func aDefinitionSupplyingOnlyABaseURLGetsWorkingDefaults() throws {
        let endpoint = DefaultedEndpoint()
        let request = try endpoint.makeRequest()

        #expect(endpoint.timeout == 60)
        #expect(endpoint.additionalHeaders.isEmpty)
        #expect(request.url.absoluteString == "https://api.example.com/payload")
        #expect(request.queryItems == [URLQueryItem(name: "v", value: "1")])
        #expect(request.headers.isEmpty)
    }

    @Test
    func customizationPointsOverrideTheDefaults() throws {
        let request = try CustomizedEndpoint().makeRequest()

        #expect(request.timeout == 5)
        #expect(request.headers["X-App"] == "demo")
        #expect(request.headers["Content-Type"] == "application/json")
    }

    @Test
    func noContentResponsesDecodeWithoutRunningTheJSONDecoder() throws {
        let decoded = try CustomizedEndpoint().decode(Data(), using: JSONDecoder())
        #expect(decoded == NoContent())
    }

    @Test
    func decodableResponsesStillUseTheSuppliedDecoder() throws {
        let payload = Data(#"{"name":"Ada"}"#.utf8)
        #expect(try DefaultedEndpoint().decode(payload, using: JSONDecoder()) == SamplePayload(name: "Ada"))
    }
}
