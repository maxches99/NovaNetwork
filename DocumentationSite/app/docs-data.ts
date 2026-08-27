export type TutorialStep = {
  title: string;
  explanation: string;
  code?: string;
  note?: string;
};

export type Tutorial = {
  slug: string;
  title: string;
  summary: string;
  eyebrow: string;
  duration: string;
  level: "Beginner" | "Intermediate" | "Advanced";
  symbol: string;
  tone: "blue" | "purple" | "mint" | "orange";
  outcome: string;
  steps: TutorialStep[];
};

export const tutorials: Tutorial[] = [
  {
    slug: "first-request",
    title: "Build your first request",
    summary: "Decode a public API response into a small Sendable model.",
    eyebrow: "Get started",
    duration: "10 min",
    level: "Beginner",
    symbol: "→",
    tone: "blue",
    outcome: "A complete async Swift program that loads a typed Todo value.",
    steps: [
      { title: "Describe the response", explanation: "Model only the fields the feature owns. Sendable keeps the value safe across concurrency boundaries.", code: `struct Todo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
}` },
      { title: "Build an APIRequest", explanation: "Keep URL, method, headers, and body together in a stable value.", code: `let request = APIRequest(
    method: .get,
    url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!,
    headers: ["Accept": "application/json"]
)` },
      { title: "Load a typed response", explanation: "The generic return type tells the client what to decode.", code: `let client = NetworkClient(transport: Transport())
let todo: Todo = try await client.load(
    request: request,
    authScope: "public"
)` },
    ],
  },
  {
    slug: "shared-requests",
    title: "Share concurrent requests",
    summary: "See equivalent callers join one in-flight network operation.",
    eyebrow: "Shared work",
    duration: "12 min",
    level: "Intermediate",
    symbol: "⇄",
    tone: "purple",
    outcome: "Two concurrent callers that resolve from one coalesced transport operation.",
    steps: [
      { title: "Create one stable request", explanation: "Coalescing begins with deterministic request identity.", code: `let request = APIRequest(
    method: .get,
    url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
)
let authScope = "public"` },
      { title: "Start overlapping work", explanation: "async let starts both calls before either result is awaited.", code: `async let first: Todo = client.load(
    request: request, authScope: authScope
)
async let second: Todo = client.load(
    request: request, authScope: authScope
)` },
      { title: "Await both callers", explanation: "Both consumers receive their own typed value while the underlying task is shared.", code: `let (left, right) = try await (first, second)
print(left.id, right.id)` },
    ],
  },
  {
    slug: "resilience",
    title: "Add bounded resilience",
    summary: "Choose deliberate retry, caching, and typed error boundaries.",
    eyebrow: "Production",
    duration: "15 min",
    level: "Intermediate",
    symbol: "◇",
    tone: "mint",
    outcome: "A client with bounded retries, freshness rules, and visible failure handling.",
    steps: [
      { title: "Bound retries", explanation: "Retries are an explicit product decision. Keep attempts and backoff finite.", code: `var configuration = NetworkClientConfiguration()
configuration.retryPolicy = RetryPolicy(
    maxAttempts: 3,
    baseDelayNanoseconds: 200_000_000,
    maxDelayNanoseconds: 2_000_000_000
)` },
      { title: "Choose cache freshness", explanation: "Caching serves later calls; coalescing shares only overlapping calls.", code: `configuration.defaultCachePolicy = .cacheFirst(maxAge: 30)
let client = NetworkClient(configuration: configuration)` },
      { title: "Keep failure typed", explanation: "Switch only on errors that alter product behavior.", code: `do {
    let todo: Todo = try await client.load(request: request, authScope: "public")
    print(todo.title)
} catch NetworkError.cancelled {
    print("Request cancelled")
} catch {
    print(error.localizedDescription)
}` },
    ],
  },
  {
    slug: "typed-endpoints",
    title: "Model typed endpoints",
    summary: "Move repeated server operations behind reusable endpoint types.",
    eyebrow: "Architecture",
    duration: "12 min",
    level: "Intermediate",
    symbol: "{ }",
    tone: "orange",
    outcome: "A small Endpoint type that owns its request and response contract.",
    steps: [
      { title: "Declare the contract", explanation: "The associated response keeps endpoint use sites strongly typed.", code: `struct TodoEndpoint: Endpoint {
    typealias Response = Todo
    let id: Int
}` },
      { title: "Create the request", explanation: "The endpoint owns URL construction and request defaults.", code: `func makeRequest() throws -> APIRequest {
    APIRequest(
        method: .get,
        url: URL(string: "https://jsonplaceholder.typicode.com/todos/\\(id)")!
    )
}` },
      { title: "Execute by intent", explanation: "Feature code now names the operation instead of assembling HTTP details.", code: `let todo = try await client.execute(
    endpoint: TodoEndpoint(id: 1),
    authScope: "public"
)
print(todo.title)` },
    ],
  },
  {
    slug: "auth-refresh",
    title: "Refresh authentication once",
    summary: "Recover from HTTP 401 while concurrent callers share one refresh.",
    eyebrow: "Authentication",
    duration: "18 min",
    level: "Advanced",
    symbol: "↻",
    tone: "purple",
    outcome: "A client that refreshes headers once per authentication scope and replays safely.",
    steps: [
      { title: "Create a token vault", explanation: "An actor owns mutable credential state.", code: `actor TokenVault {
    private var token = "expired-token"
    func current() -> String { token }
    func store(_ value: String) { token = value }
}` },
      { title: "Provide refreshed headers", explanation: "The refresh provider is keyed by authScope and coalesces simultaneous challenges.", code: `let provider = HTTPAuthRefreshProvider { scope in
    let token = try await refreshToken(for: scope)
    await vault.store(token)
    return ["Authorization": "Bearer \\(token)"]
}` },
      { title: "Configure bounded replay", explanation: "One refresh attempt avoids infinite authentication loops.", code: `var configuration = NetworkClientConfiguration()
configuration.httpAuthRefreshProvider = provider
configuration.httpAuthRefreshPolicy = .init(maxRefreshAttempts: 1)
let client = NetworkClient(configuration: configuration)` },
    ],
  },
  {
    slug: "batch-requests",
    title: "Load a bounded batch",
    summary: "Fetch an ordered collection without unbounded fan-out.",
    eyebrow: "Concurrency",
    duration: "14 min",
    level: "Intermediate",
    symbol: "▦",
    tone: "blue",
    outcome: "An ordered batch with an explicit concurrency ceiling and decoded values.",
    steps: [
      { title: "Create ordered requests", explanation: "Input position becomes output position even when responses complete out of order.", code: `let requests = (1...12).map { id in
    APIRequest(
        method: .get,
        url: URL(string: "https://jsonplaceholder.typicode.com/todos/\\(id)")!
    )
}` },
      { title: "Bound concurrency", explanation: "The client starts at most four child requests at once.", code: `let payloads = try await client.loadBatch(
    requests: requests,
    authScope: "public",
    batchOptions: .init(maxConcurrentRequests: 4)
)` },
      { title: "Decode in order", explanation: "The resulting payload array preserves request order.", code: `let decoder = JSONDecoder()
let todos = try payloads.map {
    try decoder.decode(Todo.self, from: $0)
}` },
    ],
  },
  {
    slug: "offline-writes",
    title: "Queue writes offline",
    summary: "Persist an idempotent write and inspect its replay state.",
    eyebrow: "Offline",
    duration: "20 min",
    level: "Advanced",
    symbol: "↓",
    tone: "orange",
    outcome: "A disk-backed write queue with bounded retention and a visible receipt.",
    steps: [
      { title: "Create a durable store", explanation: "Use an app-owned Application Support location in production.", code: `let queueURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("NovaOfflineQueue", isDirectory: true)
let store = DiskOfflineWriteStore(directoryURL: queueURL)` },
      { title: "Build an idempotent write", explanation: "A stable idempotency key lets the server recognize replayed work.", code: `let request = APIRequest(
    method: .post,
    url: URL(string: "https://jsonplaceholder.typicode.com/posts")!,
    headers: ["Idempotency-Key": UUID().uuidString],
    body: Data("{\\"title\\":\\"offline\\"}".utf8)
)` },
      { title: "Enqueue when offline", explanation: "The result distinguishes immediate completion from a durable replay receipt.", code: `let result = try await client.enqueueWrite(
    request: request,
    authScope: "user:42",
    options: .init(offlineQueuePolicy: .init(mode: .enqueueWhenOffline))
)` },
    ],
  },
  {
    slug: "realtime",
    title: "Open a realtime channel",
    summary: "Connect, consume messages, and disconnect a WebSocket cleanly.",
    eyebrow: "Realtime",
    duration: "18 min",
    level: "Advanced",
    symbol: "⌁",
    tone: "mint",
    outcome: "A reconnecting WebSocket with heartbeat and structured message consumption.",
    steps: [
      { title: "Choose lifecycle policies", explanation: "Reconnect and heartbeat behavior belongs in explicit configuration.", code: `let configuration = WebSocketConfiguration(
    url: URL(string: "wss://ws.postman-echo.com/raw")!,
    reconnectPolicy: .init(maxAttempts: 2),
    heartbeatPolicy: .init()
)` },
      { title: "Connect and send", explanation: "Connection and outbound work are async and throwable.", code: `let socket = WebSocketClient(configuration: configuration)
try await socket.connect()
try await socket.send(.text("hello from Nova"))` },
      { title: "Consume as a stream", explanation: "Messages arrive through AsyncThrowingStream and follow task cancellation.", code: `let messages = await socket.messages()
for try await message in messages {
    print(message)
    break
}
await socket.disconnect(reason: "tutorial-complete")` },
    ],
  },
  {
    slug: "declarative-endpoints",
    title: "Declare endpoints with a macro",
    summary: "Generate request construction from a method, a path template, and stored properties.",
    eyebrow: "Declarative",
    duration: "12 min",
    level: "Intermediate",
    symbol: "@",
    tone: "orange",
    outcome: "A typed endpoint whose makeRequest() is generated, executed through the same client pipeline.",
    steps: [
      { title: "Enable the macro trait", explanation: "The macro is the only part of the package that needs swift-syntax, so it is opt-in. Leave the trait off and the package resolves no dependencies at all.", code: `dependencies: [
    .package(
        url: "https://github.com/maxches99/NovaNetwork.git",
        from: "2.11.0",
        traits: ["EndpointMacros"]
    )
]` },
      { title: "Supply the base URL once", explanation: "A shared protocol keeps every operation down to the part that actually differs.", code: `protocol PetstoreAPI: EndpointDefinition {}

extension PetstoreAPI {
    var baseURL: URL {
        URL(string: "https://api.petstore.example.com/v1")!
    }
}` },
      { title: "Declare the operation", explanation: "petId fills {petId} because the names match. Unmarked properties become query items, and a nil value is omitted rather than sent empty.", code: `@Endpoint(.get, "/pets/{petId}/photos", response: [Photo].self)
struct GetPetPhotos: PetstoreAPI {
    let petId: Int
    var limit: Int?
    @Query("sort_by") var sortBy: String?
    @Header("X-Trace") var trace: String?
}` },
      { title: "Execute it like any endpoint", explanation: "Generated endpoints run through the same coalescing, caching, retry, middleware, and telemetry pipeline as hand-written ones.", code: `let photos = try await client.execute(
    endpoint: GetPetPhotos(petId: 7, limit: 20),
    authScope: "petstore"
)`, note: "Already have an OpenAPI document? swift package nova-openapi generates the same kind of types from it, with no macro and no trait required." },
    ],
  },
  {
    slug: "record-and-replay",
    title: "Record traffic, replay it offline",
    summary: "Capture a real exchange once and turn it into a deterministic fixture.",
    eyebrow: "Testing",
    duration: "10 min",
    level: "Beginner",
    symbol: "\u25C9",
    tone: "mint",
    outcome: "A committed cassette that replays the real payload with the network taken away.",
    steps: [
      { title: "Wrap the scope in a cassette", explanation: "The first run performs the real request and writes the file. Every run after that replays it, so the test is offline and deterministic.", code: `import NovaNetworkCassette

try await withCassette(at: fixtureURL, upstream: Transport()) { transport in
    let client = NetworkClient(transport: transport)
    let user: User = try await client.load(
        request: request,
        authScope: nil
    )
    #expect(user.name == "Ada")
}` },
      { title: "Check what was written", explanation: "Bodies are stored as text, keys are sorted, and there are no timestamps, so the file reads like the payload and a real change shows up as a real diff.", code: `{
  "interactions" : [
    {
      "request" : {
        "headers" : { "Authorization" : "<redacted>" },
        "method" : "GET",
        "url" : "https://api.example.com/users/1"
      },
      "response" : {
        "body" : { "text" : "{\\"id\\":1,\\"name\\":\\"Ada\\"}" },
        "status" : 200
      }
    }
  ],
  "version" : 1
}` },
      { title: "Tighten matching only where it matters", explanation: "Method and full URL match by default, query order ignored. Headers and bodies stay out unless you ask, because a nonce or trace id would break every replay invisibly.", code: `// A cache-busting parameter you do not want to match on:
CassetteMatchRule.methodAndPath

// A search endpoint that varies by payload:
CassetteMatchRule.includingBody

// Content negotiation that really is part of the identity:
CassetteMatchRule.default.matchingHeaders("Accept-Language")` },
      { title: "Replay a sequence, not a constant", explanation: "Repeated requests replay as episodes, in recorded order, so a polling or pagination flow stays a flow.", code: `let transport = CassetteTransport(
    mode: .replay,
    cassette: try Cassette.load(from: url),
    repeatPolicy: .repeatLast
)`, note: "Redaction runs as the exchange is captured, not when the file is written, so a token never reaches a value that could be serialized somewhere else." },
    ],
  },
  {
    slug: "diagnostics",
    title: "See what the client did",
    summary: "Record requests, read the retry waterfall, export a HAR for the bug report.",
    eyebrow: "Diagnostics",
    duration: "8 min",
    level: "Beginner",
    symbol: "\u2318",
    tone: "orange",
    outcome: "A live request list, a retry timeline, and a HAR file you can attach to a ticket.",
    steps: [
      { title: "Install the recorder", explanation: "Diagnostics consumes the telemetry the client already emits, so nothing about the client changes.", code: `import NovaNetworkDiagnostics

let recorder = DiagnosticsRecorder()
var configuration = NetworkClientConfiguration()
configuration.telemetryHooks = recorder.hooks
let client = NetworkClient(configuration: configuration)
recorder.startConsuming(client.events())` },
      { title: "Read one request, not three", explanation: "The client reports a start and an end per attempt and announces a retry only after the attempt failed. The recorder stitches them into the request a person actually made.", code: `GET /flaky — 200 in 598 ms
  █████████████ Attempt 1
  ············ Backoff 185 ms
               ██████████████████████████ Attempt 2
               ·························· Backoff 399 ms
                                         █ Attempt 3` },
      { title: "Trust the summary", explanation: "A transport that returns a 500 completed the exchange — nothing threw. failureRate counts HTTP errors anyway, because 0% failed beside a list of 500s would be worse than no summary.", code: `let summary = await recorder.summary()
print(summary.shortDescription)
// 4 requests · 50% failed · 25% coalesced · 66% cache hits` },
      { title: "Export it", explanation: "HAR 1.2 opens in any browser's network inspector, so a support artifact needs no new viewer.", code: `let har = try await recorder.exportHAR()
try har.write(to: url)`, note: "Credentials are redacted as a record is built, not when it is exported: a buffer holding a live token is one screenshot away from leaking it." },
    ],
  },
  {
    slug: "authentication",
    title: "Sign in with OAuth 2.0",
    summary: "PKCE, the token exchange, and one refresh shared by every caller.",
    eyebrow: "Authentication",
    duration: "14 min",
    level: "Intermediate",
    symbol: "\u26BF",
    tone: "purple",
    outcome: "A client that attaches a token, refreshes it once, and asks for a sign-in when the session really is over.",
    steps: [
      { title: "Start the flow", explanation: "Keep the verifier and the state. The callback is worthless without them, and the state check is what stops someone else's authorization code being redeemed in your user's session.", code: `let pkce = PKCEChallenge.generate()
let state = UUID().uuidString
let url = try oauth.authorizationURL(state: state, challenge: pkce)
// The app opens \`url\`: presenting a browser needs a window
// anchor, which is the app's job, not the library's.` },
      { title: "Validate what comes back", explanation: "The state is checked before anything else is read, and a mismatch throws without returning the code.", code: `let code = try oauth.authorizationCode(
    from: callbackURL,
    expectedState: state
)
let token = try await oauth.exchange(code: code, verifier: pkce.verifier)
try await authenticator.setToken(token)` },
      { title: "Wire it into the client", explanation: "The client already coordinates a single refresh across a burst of 401s and replays them. This fills in the closure it takes.", code: `var configuration = NetworkClientConfiguration()
configuration.authRefreshProvider = authenticator.refreshProvider
configuration.middleware = [authenticator.middleware]
let client = NetworkClient(configuration: configuration)` },
      { title: "Let eight callers need a token at once", explanation: "An actor is not enough on its own: it suspends at the network call, so a second caller would start a second refresh. Sharing the in-flight task means the provider sees one request.", code: `await withTaskGroup(of: Void.self) { group in
    for _ in 0..<8 {
        group.addTask { _ = try? await authenticator.validToken() }
    }
}
// The provider saw exactly one refresh.`, note: "A refresh response usually omits refresh_token, meaning keep the one you have. Dropping it there is how a session ends an hour later for no visible reason." },
    ],
  },
  {
    slug: "query-layer",
    title: "Share server state between screens",
    summary: "One entry per key, stale values that stay visible, and optimistic edits that roll back.",
    eyebrow: "Query layer",
    duration: "15 min",
    level: "Intermediate",
    symbol: "\u25F4",
    tone: "blue",
    outcome: "Two screens rendering the same resource from one request, with mutations that update both.",
    steps: [
      { title: "Ask by key", explanation: "A fresh value comes back without touching the network; a stale one comes back immediately and refreshes behind it. Two screens asking at the same moment share one fetch.", code: `let queries = QueryClient()

let user: User = try await queries.value(for: QueryKey("users", 1)) {
    try await client.load(request: request, authScope: nil)
}` },
      { title: "Render four states", explanation: "Errors are part of the state, not only thrown, so a view can show the problem beside the value it already had.", code: `for await state in await queries.states(for: QueryKey("users", 1), as: User.self) {
    switch state {
    case .idle, .loading(nil):          showSpinner()
    case let .loading(.some(user)),
         let .success(user, _):         show(user, stale: state.isStale)
    case let .failure(error, previous): show(error, keeping: previous)
    }
}` },
      { title: "Mutate optimistically", explanation: "A failure restores the exact snapshot captured before the change — not a reversed diff, which stops being correct as soon as two mutations race.", code: `try await queries.mutate(
    optimistic: [QueryKey("users", 1): editedUser],
    invalidating: [QueryKey("users", 1), "users"]
) {
    try await client.load(request: saveRequest, authScope: nil)
}` },
      { title: "Page a list", explanation: "Accumulated pages land in the cache under the query key, so the screen subscribes the way it subscribes to anything else.", code: `let feed = PagedQuery<Post, String>(key: "feed", client: queries) { cursor in
    let page: FeedPage = try await client.load(
        request: feedRequest(after: cursor), authScope: nil
    )
    return QueryPage(elements: page.posts, nextCursor: page.next)
}
let posts = try await feed.loadNextPage()`, note: "Invalidating a key nobody is watching marks it stale without refetching: filling a cache no screen reads spends the user's battery for nothing." },
    ],
  },
];

export function tutorialForSlug(slug: string) {
  return tutorials.find((tutorial) => tutorial.slug === slug);
}
