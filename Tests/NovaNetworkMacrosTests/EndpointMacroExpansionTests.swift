#if EndpointMacros
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacrosGenericTestSupport
import Testing
@testable import NovaNetworkMacrosPlugin

// Requirements: FR-8 (generated conformance), FR-15 (diagnostics), EC-3, EC-11, EC-12.
// Tests: T-8.1, T-15.1, T-15.2.

private let macroSpecs: [String: MacroSpec] = [
    "Endpoint": MacroSpec(type: EndpointMacro.self, conformances: ["EndpointDefinition"]),
    "Path": MacroSpec(type: EndpointParameterMarkerMacro.self),
    "Query": MacroSpec(type: EndpointParameterMarkerMacro.self),
    "Header": MacroSpec(type: EndpointParameterMarkerMacro.self),
    "Body": MacroSpec(type: EndpointParameterMarkerMacro.self),
]

/// Bridges swift-syntax's assertion failures into swift-testing issues.
private func recordFailure(_ failure: TestFailureSpec) {
    Issue.record(
        Comment(rawValue: failure.message),
        sourceLocation: SourceLocation(
            fileID: failure.location.fileID,
            filePath: failure.location.filePath,
            line: failure.location.line,
            column: failure.location.column
        )
    )
}

private func assertExpansion(
    _ source: String,
    _ expanded: String,
    diagnostics: [DiagnosticSpec] = []
) {
    assertMacroExpansion(
        source,
        expandedSource: expanded,
        diagnostics: diagnostics,
        macroSpecs: macroSpecs,
        failureHandler: recordFailure
    )
}

@Suite
struct EndpointMacroExpansionTests {
    @Test
    func expansionGeneratesTheRequestBuilderCallsAConsumerWouldWriteByHand() {
        assertExpansion(
            """
            @Endpoint(.get, "/users/{id}/posts", response: [Post].self)
            struct GetUserPosts {
                let id: Int
                var limit: Int?
                @Query("sort_by") var sortBy: String?
                @Header("X-Trace") var trace: String?
            }
            """,
            """
            struct GetUserPosts {
                let id: Int
                var limit: Int?
                var sortBy: String?
                var trace: String?
            }

            extension GetUserPosts: EndpointDefinition {
                typealias Response = [Post]

                func makeRequest() throws -> NovaNetworkCore.APIRequest {
                    var builder = NovaNetworkCore.EndpointRequestBuilder(
                        method: .get,
                        baseURL: self.baseURL,
                        path: "/users/{id}/posts"
                    )
                    try builder.setPath("id", self.id)
                    builder.addQuery("limit", self.limit)
                    builder.addQuery("sort_by", self.sortBy)
                    builder.setHeader("X-Trace", self.trace)
                    return try builder.build(timeout: self.timeout, additionalHeaders: self.additionalHeaders)
                }
            }
            """
        )
    }

    @Test
    func aParameterlessEndpointBindsTheBuilderWithLetAndNeedsNoResponseArgument() {
        assertExpansion(
            """
            @Endpoint(.get, "https://status.example.com/health")
            struct HealthCheck {
                typealias Response = Status
            }
            """,
            """
            struct HealthCheck {
                typealias Response = Status
            }

            extension HealthCheck: EndpointDefinition {
                var baseURL: Foundation.URL {
                    Foundation.URL(string: "https://status.example.com")!
                }

                func makeRequest() throws -> NovaNetworkCore.APIRequest {
                    let builder = NovaNetworkCore.EndpointRequestBuilder(
                        method: .get,
                        baseURL: self.baseURL,
                        path: "/health"
                    )
                    return try builder.build(timeout: self.timeout, additionalHeaders: self.additionalHeaders)
                }
            }
            """
        )
    }

    @Test
    func bodyIsEncodedAfterHeadersSoAnExplicitContentTypeSurvives() {
        assertExpansion(
            """
            @Endpoint(.post, "/users", response: User.self)
            public struct CreateUser {
                @Body var payload: NewUser
                @Header("Content-Type") var contentType: String
            }
            """,
            """
            public struct CreateUser {
                var payload: NewUser
                var contentType: String
            }

            extension CreateUser: EndpointDefinition {
                public typealias Response = User

                public func makeRequest() throws -> NovaNetworkCore.APIRequest {
                    var builder = NovaNetworkCore.EndpointRequestBuilder(
                        method: .post,
                        baseURL: self.baseURL,
                        path: "/users"
                    )
                    builder.setHeader("Content-Type", self.contentType)
                    try builder.setJSONBody(self.payload, encoder: self.jsonEncoder)
                    return try builder.build(timeout: self.timeout, additionalHeaders: self.additionalHeaders)
                }
            }
            """
        )
    }
}

@Suite
struct EndpointMacroDiagnosticTests {
    @Test
    func applyingTheMacroToAClassIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "/users")
            class GetUsers {
            }
            """,
            """
            class GetUsers {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Endpoint can only be applied to a struct; this is a class. Endpoints must be Sendable value types.",
                    line: 1,
                    column: 1
                ),
            ]
        )
    }

    @Test
    func aGenericEndpointIsRejectedWithAnExplanation() {
        assertExpansion(
            """
            @Endpoint(.get, "/users")
            struct GetUsers<T> {
            }
            """,
            """
            struct GetUsers<T> {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Endpoint does not support generic types. Remove the generic parameters from 'GetUsers', or write makeRequest() by hand.",
                    line: 1,
                    column: 1
                ),
            ]
        )
    }

    @Test
    func declaringTheConformanceYourselfIsRejectedRatherThanDuplicated() {
        assertExpansion(
            """
            @Endpoint(.get, "/users")
            struct GetUsers: EndpointDefinition {
            }
            """,
            """
            struct GetUsers: EndpointDefinition {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'GetUsers' already declares conformance to EndpointDefinition, which @Endpoint adds itself. Remove ': EndpointDefinition' from the declaration.",
                    line: 1,
                    column: 1
                ),
            ]
        )
    }

    @Test
    func aPlaceholderWithNoPropertyNamesTheFixInTheMessage() {
        assertExpansion(
            """
            @Endpoint(.get, "/users/{id}")
            struct GetUser {
                let identifier: Int
            }
            """,
            """
            struct GetUser {
                let identifier: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: #"Path template "/users/{id}" has no property for {id}. Add a stored property named 'id', or mark an existing one with @Path("id")."#,
                    line: 1,
                    column: 1
                ),
            ]
        )
    }

    @Test
    func aPathMarkerWithoutAMatchingPlaceholderIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "/users")
            struct GetUser {
                @Path("id") let identifier: Int
            }
            """,
            """
            struct GetUser {
                let identifier: Int
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: #"@Path("id") has no matching placeholder in "/users". Add {id} to the path, or change the marker to @Query."#,
                    line: 3,
                    column: 5
                ),
            ]
        )
    }

    @Test
    func twoBodyPropertiesAreRejectedByName() {
        assertExpansion(
            """
            @Endpoint(.post, "/users")
            struct CreateUser {
                @Body var first: NewUser
                @Body var second: NewUser
            }
            """,
            """
            struct CreateUser {
                var first: NewUser
                var second: NewUser
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "An endpoint can have one @Body property, but 'first' and 'second' are both marked. Combine them into a single body type.",
                    line: 4,
                    column: 5
                ),
            ]
        )
    }

    @Test
    func aBodyOnAGetEndpointIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "/search")
            struct Search {
                @Body var filter: Filter
            }
            """,
            """
            struct Search {
                var filter: Filter
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Body is not allowed on a GET endpoint: GET requests have no defined body semantics. Send 'filter' as a @Query parameter, or change the method.",
                    line: 3,
                    column: 5
                ),
            ]
        )
    }

    @Test
    func aPropertyWithTwoMarkersIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "/search")
            struct Search {
                @Query @Header var term: String
            }
            """,
            """
            struct Search {
                var term: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "'term' is marked both @Query and @Header; a property takes exactly one role.",
                    line: 3,
                    column: 12
                ),
            ]
        )
    }

    @Test
    func anEmptyWireNameIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "/search")
            struct Search {
                @Query("") var term: String
            }
            """,
            """
            struct Search {
                var term: String
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@Query was given an empty name. Pass a name, or omit the argument to use the property's own name.",
                    line: 3,
                    column: 12
                ),
            ]
        )
    }

    @Test
    func anInterpolatedPathIsRejectedBecausePlaceholdersMustBindAtCompileTime() {
        assertExpansion(
            """
            @Endpoint(.get, "/users/\\(suffix)")
            struct GetUsers {
            }
            """,
            """
            struct GetUsers {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: #"The path must be a plain string literal so placeholders can be bound at compile time, for example "/users/{id}"."#,
                    line: 1,
                    column: 17
                ),
            ]
        )
    }

    @Test
    func aResponseArgumentThatIsNotAMetatypeIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "/users", response: User)
            struct GetUsers {
            }
            """,
            """
            struct GetUsers {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "The response argument must be a metatype literal such as User.self.",
                    line: 1,
                    column: 37
                ),
            ]
        )
    }

    @Test
    func aSchemeThatIsNotAValidURLIsRejected() {
        assertExpansion(
            """
            @Endpoint(.get, "https:///health")
            struct HealthCheck {
            }
            """,
            """
            struct HealthCheck {
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: #"'https:///health' starts with a scheme but is not a valid URL. Use an absolute URL such as "https://api.example.com/users/{id}", or a relative path with a baseURL on the type."#,
                    line: 1,
                    column: 17
                ),
            ]
        )
    }
}
#endif
