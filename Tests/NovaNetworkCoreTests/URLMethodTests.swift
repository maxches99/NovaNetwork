import Foundation
import Testing
import NovaNetworkCore

// Requirements: FR-CACHE-SAFE-1 (method classification), DX-METHOD-1 (`HTTPMethod` spelling).

@Suite
struct URLMethodTests {
    @Test(arguments: [URLMethod.get, .head, .options])
    func readOnlyMethodsAreSafe(method: URLMethod) {
        #expect(method.isSafe)
    }

    @Test(arguments: [URLMethod.post, .put, .patch, .delete])
    func writingMethodsAreNotSafe(method: URLMethod) {
        #expect(method.isSafe == false)
    }

    @Test(arguments: [URLMethod.get, .head])
    func onlyGetAndHeadAreCacheableWithoutAnOptIn(method: URLMethod) {
        #expect(method.isCacheableByDefault)
    }

    @Test(arguments: [URLMethod.options, .post, .put, .patch, .delete])
    func everythingElseNeedsAnOptInToBeCached(method: URLMethod) {
        #expect(method.isCacheableByDefault == false)
    }

    @Test
    func optionsIsSafeWithoutBeingCacheable() {
        // The two properties answer different questions, and OPTIONS is where they disagree.
        #expect(URLMethod.options.isSafe)
        #expect(URLMethod.options.isCacheableByDefault == false)
    }

    @Test
    func httpMethodNamesTheSameType() {
        let method: HTTPMethod = .patch
        #expect(method == URLMethod.patch)
        #expect(HTTPMethod.get.rawValue == "GET")
    }
}
