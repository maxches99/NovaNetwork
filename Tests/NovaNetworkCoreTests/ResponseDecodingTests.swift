import Foundation
import Testing
@testable import NovaNetworkCore

// Requirements: FR-DEC-1 (JSON default), FR-DEC-2 (content-type negotiation).

private struct Payload: Decodable, Equatable, Sendable {
    let value: Int
}

private struct XMLDecoding: ResponseDecoding {
    func decode<T: Decodable & Sendable>(_ type: T.Type, from response: NetworkResponse) throws -> T {
        // A minimal stand-in decoder: parses "<value>N</value>" into `Payload`.
        guard let string = String(data: response.body, encoding: .utf8),
              let match = string.range(of: #"<value>(\d+)</value>"#, options: .regularExpression) else {
            throw NetworkError.decoding(underlying: NSError(domain: "XMLDecoding", code: 1))
        }
        let digits = string[match].filter(\.isNumber)
        guard let value = Int(digits), let payload = Payload(value: value) as? T else {
            throw NetworkError.decoding(underlying: NSError(domain: "XMLDecoding", code: 2))
        }
        return payload
    }
}

@Suite
struct ResponseDecodingTests {
    @Test
    func jsonResponseDecodingDecodesTheBody() throws {
        let response = NetworkResponse(statusCode: 200, headers: [:], body: Data(#"{"value":42}"#.utf8))
        let decoded = try JSONResponseDecoding().decode(Payload.self, from: response)
        #expect(decoded == Payload(value: 42))
    }

    @Test
    func jsonResponseDecodingSurfacesUnderlyingDecodingErrors() {
        let response = NetworkResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))
        #expect(throws: (any Error).self) {
            try JSONResponseDecoding().decode(Payload.self, from: response)
        }
    }

    @Test
    func mediaTypeExtractionIgnoresParametersAndIsCaseInsensitive() {
        let mediaType = ContentTypeNegotiatingResponseDecoding.mediaType(
            fromContentTypeHeader: ["Content-Type": "Application/JSON; charset=utf-8"]
        )
        #expect(mediaType == "application/json")
    }

    @Test
    func mediaTypeExtractionMatchesHeaderNameCaseInsensitively() {
        let mediaType = ContentTypeNegotiatingResponseDecoding.mediaType(
            fromContentTypeHeader: ["content-type": "text/xml"]
        )
        #expect(mediaType == "text/xml")
    }

    @Test
    func mediaTypeExtractionReturnsNilWhenHeaderIsAbsent() {
        #expect(ContentTypeNegotiatingResponseDecoding.mediaType(fromContentTypeHeader: [:]) == nil)
    }

    @Test
    func negotiationSelectsTheRegisteredDecoderForTheResponsesMediaType() throws {
        let negotiating = ContentTypeNegotiatingResponseDecoding(
            decodersByMediaType: ["application/xml": XMLDecoding()]
        )
        let response = NetworkResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/xml; charset=utf-8"],
            body: Data("<value>7</value>".utf8)
        )

        let decoded = try negotiating.decode(Payload.self, from: response)
        #expect(decoded == Payload(value: 7))
    }

    @Test
    func negotiationFallsBackToJSONWhenMediaTypeIsUnregistered() throws {
        let negotiating = ContentTypeNegotiatingResponseDecoding(
            decodersByMediaType: ["application/xml": XMLDecoding()]
        )
        let response = NetworkResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"value":9}"#.utf8)
        )

        let decoded = try negotiating.decode(Payload.self, from: response)
        #expect(decoded == Payload(value: 9))
    }

    @Test
    func negotiationFallsBackWhenContentTypeHeaderIsAbsent() throws {
        let negotiating = ContentTypeNegotiatingResponseDecoding(
            decodersByMediaType: ["application/xml": XMLDecoding()]
        )
        let response = NetworkResponse(statusCode: 200, headers: [:], body: Data(#"{"value":3}"#.utf8))

        let decoded = try negotiating.decode(Payload.self, from: response)
        #expect(decoded == Payload(value: 3))
    }

    @Test
    func negotiationHonorsACustomFallback() throws {
        let negotiating = ContentTypeNegotiatingResponseDecoding(fallback: XMLDecoding())
        let response = NetworkResponse(statusCode: 200, headers: [:], body: Data("<value>11</value>".utf8))

        let decoded = try negotiating.decode(Payload.self, from: response)
        #expect(decoded == Payload(value: 11))
    }

    @Test
    func decoderRegistrationNormalizesMediaTypeKeysOnInit() throws {
        let negotiating = ContentTypeNegotiatingResponseDecoding(
            decodersByMediaType: ["  Application/XML  ": XMLDecoding()]
        )
        let response = NetworkResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/xml"],
            body: Data("<value>5</value>".utf8)
        )

        let decoded = try negotiating.decode(Payload.self, from: response)
        #expect(decoded == Payload(value: 5))
    }
}
