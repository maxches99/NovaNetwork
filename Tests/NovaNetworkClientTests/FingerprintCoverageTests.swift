import Foundation
import Testing
@testable import NovaNetworkClient

@Suite
struct FingerprintCoverageTests {
    @Test
    func canonicalizersHandleAllowlistAndSortedQuery() {
        let canonicalHeaders = HeaderCanonicalizer.canonicalHeaders(
            ["X-B": "2", "x-a": "1", "Ignore": "x"],
            inclusion: .allowlist(["X-A", "x-b"])
        )
        let noHeaders = HeaderCanonicalizer.canonicalHeaders(
            ["A": "1"],
            inclusion: .none
        )
        let allHeaders = HeaderCanonicalizer.canonicalHeaders(
            ["X-B": "2", "X-A": "1"],
            inclusion: .all
        )
        let canonicalURL = URLCanonicalizer.canonicalURLString(
            url: URL(string: "https://example.com/items")!,
            queryItems: [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a", value: "1")]
        )
        let sameNameSortedURL = URLCanonicalizer.canonicalURLString(
            url: URL(string: "https://example.com/items")!,
            queryItems: [URLQueryItem(name: "a", value: "2"), URLQueryItem(name: "a", value: "1")]
        )
        let unchangedURL = URLCanonicalizer.canonicalURLString(
            url: URL(string: "https://example.com/items?z=9")!,
            queryItems: nil
        )
        let nonJSON = BodyCanonicalizer.canonicalBody(Data("raw".utf8))

        #expect(canonicalHeaders == "x-a:1\nx-b:2")
        #expect(noHeaders.isEmpty)
        #expect(allHeaders == "x-a:1\nx-b:2")
        #expect(canonicalURL.contains("a=1&b=2"))
        #expect(sameNameSortedURL.contains("a=1&a=2"))
        #expect(unchangedURL.contains("z=9"))
        #expect(nonJSON == Data("raw".utf8))
    }
}
