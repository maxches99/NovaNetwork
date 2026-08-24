#if EndpointMacros
@_exported import NovaNetworkCore
import Foundation

/// Generates an ``EndpointDefinition`` conformance from a method, a path template, and the
/// annotated type's stored properties.
///
/// The macro writes the `makeRequest()` you would otherwise write by hand, routing every value
/// through ``EndpointRequestBuilder`` so percent-encoding, optional omission, and array styles
/// behave the same as they do for generated and hand-written endpoints.
///
/// ```swift
/// protocol ExampleAPI: EndpointDefinition {}
/// extension ExampleAPI {
///     var baseURL: URL { URL(string: "https://api.example.com")! }
/// }
///
/// @Endpoint(.get, "/users/{id}/posts", response: [Post].self)
/// struct GetUserPosts: ExampleAPI {
///     let id: Int                       // fills {id}: the name matches the placeholder
///     var limit: Int?                   // unmarked, so it becomes ?limit=…
///     @Query("sort_by") var sortBy: String?
///     @Header("X-Trace") var trace: String?
/// }
/// ```
///
/// Each stored property takes exactly one role, resolved in this order:
///
/// 1. an explicit ``Path(_:)``, ``Query(_:style:)``, ``Header(_:)``, or ``Body(contentType:)`` marker;
/// 2. a path parameter, when the property name matches a `{placeholder}` in the template;
/// 3. a query item under the property's own name.
///
/// `baseURL`, `timeout`, `additionalHeaders`, and `jsonEncoder` are the protocol's customization
/// points, never parameters, so declaring any of them is safe. Static and computed properties are
/// ignored.
///
/// - Parameters:
///   - method: The HTTP method.
///   - path: A path template such as `/users/{id}`, or an absolute URL, which also supplies
///     `baseURL` so the type needs no other source for it.
///   - response: The decoded response type. Omit it and declare `typealias Response` yourself.
@attached(
    extension,
    conformances: EndpointDefinition,
    names: named(makeRequest), named(Response), named(baseURL)
)
public macro Endpoint(
    _ method: URLMethod,
    _ path: String,
    response: Any.Type? = nil
) = #externalMacro(module: "NovaNetworkMacrosPlugin", type: "EndpointMacro")

/// Marks a property as a path parameter, optionally under a different placeholder name.
///
/// Only needed when the property name and the `{placeholder}` differ:
///
/// ```swift
/// @Endpoint(.get, "/users/{user_id}")
/// struct GetUser: ExampleAPI {
///     typealias Response = User
///     @Path("user_id") let id: Int
/// }
/// ```
///
/// - Parameter name: The placeholder to fill. Defaults to the property's own name.
@attached(peer)
public macro Path(_ name: String? = nil) = #externalMacro(module: "NovaNetworkMacrosPlugin", type: "EndpointParameterMarkerMacro")

/// Marks a property as a query item, optionally under a different name and array style.
///
/// Unmarked properties already become query items, so reach for this to rename one to its wire
/// spelling or to change how an array is written:
///
/// ```swift
/// @Query("sort_by") var sortBy: String?
/// @Query("tag", style: .commaSeparated) var tags: [String]
/// ```
///
/// - Parameters:
///   - name: The query item name. Defaults to the property's own name.
///   - style: How multiple values are written. Defaults to ``EndpointQueryStyle/repeated``.
@attached(peer)
public macro Query(
    _ name: String? = nil,
    style: EndpointQueryStyle = .repeated
) = #externalMacro(module: "NovaNetworkMacrosPlugin", type: "EndpointParameterMarkerMacro")

/// Marks a property as a request header.
///
/// A `nil` value omits the header rather than sending an empty one; an array joins with `", "`.
///
/// - Parameter name: The header field name. Defaults to the property's own name.
@attached(peer)
public macro Header(_ name: String? = nil) = #externalMacro(module: "NovaNetworkMacrosPlugin", type: "EndpointParameterMarkerMacro")

/// Marks a property as the JSON request body.
///
/// The value is encoded with the endpoint's `jsonEncoder`, and `Content-Type: application/json` is
/// set unless a ``Header(_:)`` parameter already supplied one. At most one property per endpoint
/// may carry this marker, and `GET` and `HEAD` endpoints may not carry it at all.
///
/// - Parameter contentType: A content type to send instead of `application/json`.
@attached(peer)
public macro Body(contentType: String? = nil) = #externalMacro(module: "NovaNetworkMacrosPlugin", type: "EndpointParameterMarkerMacro")
#endif
