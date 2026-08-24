import Foundation
import Testing
import NovaNetworkCore

// Requirements: FR-ERR-1 (Equatable), FR-ERR-2 (LocalizedError), FR-ERR-3 (error context).

private struct DummyDecodingError: Error, CustomStringConvertible {
    let field: String
    var description: String { "missing field \(field)" }
}

@Suite
struct NetworkErrorEquatableTests {
    @Test
    func payloadFreeCasesCompareByCaseAlone() {
        #expect(NetworkError.invalidResponse == NetworkError.invalidResponse)
        #expect(NetworkError.cancelled == NetworkError.cancelled)
        #expect(NetworkError.invalidResponse != NetworkError.cancelled)
    }

    @Test
    func httpStatusComparesCodeHeadersAndBody() {
        let a = NetworkError.httpStatus(code: 404, headers: ["X": "1"], body: Data("a".utf8))
        let b = NetworkError.httpStatus(code: 404, headers: ["X": "1"], body: Data("a".utf8))
        let differentCode = NetworkError.httpStatus(code: 500, headers: ["X": "1"], body: Data("a".utf8))
        let differentBody = NetworkError.httpStatus(code: 404, headers: ["X": "1"], body: Data("b".utf8))

        #expect(a == b)
        #expect(a != differentCode)
        #expect(a != differentBody)
    }

    @Test
    func clientRateLimitedComparesRetryAfter() {
        #expect(NetworkError.clientRateLimited(retryAfterSeconds: 5) == .clientRateLimited(retryAfterSeconds: 5))
        #expect(NetworkError.clientRateLimited(retryAfterSeconds: 5) != .clientRateLimited(retryAfterSeconds: 10))
        #expect(NetworkError.clientRateLimited(retryAfterSeconds: nil) == .clientRateLimited(retryAfterSeconds: nil))
    }

    @Test
    func queueCapacityExceededComparesLimit() {
        #expect(NetworkError.queueCapacityExceeded(limit: 10) == .queueCapacityExceeded(limit: 10))
        #expect(NetworkError.queueCapacityExceeded(limit: 10) != .queueCapacityExceeded(limit: 20))
    }

    @Test
    func decodingComparesUnderlyingErrorByTypeAndDescription() {
        let a = NetworkError.decoding(underlying: DummyDecodingError(field: "name"))
        let b = NetworkError.decoding(underlying: DummyDecodingError(field: "name"))
        let differentField = NetworkError.decoding(underlying: DummyDecodingError(field: "age"))

        #expect(a == b)
        #expect(a != differentField)
    }

    @Test
    func transportComparesUnderlyingURLErrorByCode() {
        let a = NetworkError.transport(underlying: URLError(.timedOut))
        let b = NetworkError.transport(underlying: URLError(.timedOut))
        let different = NetworkError.transport(underlying: URLError(.notConnectedToInternet))

        #expect(a == b)
        #expect(a != different)
    }

    @Test
    func differentUnderlyingErrorTypesAreNeverEqualEvenWithSimilarDescriptions() {
        struct OtherError: Error, CustomStringConvertible {
            var description: String { "missing field name" }
        }
        let a = NetworkError.decoding(underlying: DummyDecodingError(field: "name"))
        let b = NetworkError.decoding(underlying: OtherError())

        #expect(a != b)
    }

    @Test
    func differentCasesAreNeverEqual() {
        #expect(NetworkError.cancelled != NetworkError.circuitBreakerOpen)
        #expect(NetworkError.offlineQueueUnavailable != NetworkError.coalescerLimitExceeded)
    }
}

@Suite
struct NetworkErrorLocalizedDescriptionTests {
    @Test
    func everyCaseProducesANonEmptyDescription() {
        let errors: [NetworkError] = [
            .invalidResponse,
            .httpStatus(code: 500, headers: [:], body: Data()),
            .decoding(underlying: DummyDecodingError(field: "id")),
            .transport(underlying: URLError(.timedOut)),
            .cancelled,
            .timeoutBudgetExceeded,
            .circuitBreakerOpen,
            .coalescerLimitExceeded,
            .clientRateLimited(retryAfterSeconds: 3),
            .clientRateLimited(retryAfterSeconds: nil),
            .queueCapacityExceeded(limit: 5),
            .queueCapacityExceeded(limit: nil),
            .offlineQueueUnavailable,
            .authenticationRefreshFailed(underlying: DummyDecodingError(field: "token")),
        ]

        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty, "\(error) should have a non-empty description")
        }
    }

    @Test
    func httpStatusDescriptionMentionsTheCode() {
        let description = NetworkError.httpStatus(code: 429, headers: [:], body: Data()).errorDescription
        #expect(description?.contains("429") == true)
    }

    @Test
    func clientRateLimitedDescriptionMentionsRetryAfterWhenPresent() {
        let description = NetworkError.clientRateLimited(retryAfterSeconds: 7).errorDescription
        #expect(description?.contains("7") == true)
    }
}

@Suite
struct NetworkErrorContextTests {
    @Test
    func withRequestCapturesURLMethodAndAuthScope() throws {
        let request = APIRequest(method: .post, url: URL(string: "https://api.example.com/items")!)
        let contextual = NetworkError.invalidResponse.with(request: request, attempt: 2, authScope: "user:1")

        #expect(contextual.error == .invalidResponse)
        #expect(contextual.context.url == request.url)
        #expect(contextual.context.method == .post)
        #expect(contextual.context.attempt == 2)
        #expect(contextual.context.authScope == "user:1")
    }

    @Test
    func defaultsAttemptToOneAndAuthScopeToNil() {
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com")!)
        let contextual = NetworkError.cancelled.with(request: request)

        #expect(contextual.context.attempt == 1)
        #expect(contextual.context.authScope == nil)
    }

    @Test
    func descriptionIncludesTheUnderlyingErrorAndTheRequest() {
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com/users/1")!)
        let contextual = NetworkError.httpStatus(code: 404, headers: [:], body: Data()).with(request: request)

        let description = contextual.errorDescription ?? ""
        #expect(description.contains("404"))
        #expect(description.contains("GET"))
        #expect(description.contains("users/1"))
    }

    @Test
    func descriptionOmitsAttemptNumberWhenItIsTheFirstAttempt() {
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com")!)
        let single = NetworkError.cancelled.with(request: request, attempt: 1)
        let retried = NetworkError.cancelled.with(request: request, attempt: 3)

        #expect(single.errorDescription?.contains("attempt") == false)
        #expect(retried.errorDescription?.contains("attempt 3") == true)
    }

    @Test
    func contextualNetworkErrorEqualityComparesErrorAndContext() {
        let request = APIRequest(method: .get, url: URL(string: "https://api.example.com")!)
        let a = NetworkError.cancelled.with(request: request, attempt: 1)
        let b = NetworkError.cancelled.with(request: request, attempt: 1)
        let differentAttempt = NetworkError.cancelled.with(request: request, attempt: 2)

        #expect(a == b)
        #expect(a != differentAttempt)
    }
}
