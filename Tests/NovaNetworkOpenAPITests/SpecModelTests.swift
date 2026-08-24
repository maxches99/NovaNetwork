import Foundation
import Testing
@testable import NovaNetworkOpenAPI

// Requirements: FR-17 (document model), FR-18 (deterministic naming), FR-22 (identifier mapping),
// EC-5 (keywords and invalid identifiers), EC-8 (located parse errors).
// Tests: T-17.2, T-18.1, T-22.1.

@Suite
struct SpecValueTests {
    @Test
    func eachAccessorReadsOnlyItsOwnCase() {
        let values: [SpecValue] = [.null, .bool(true), .number(4), .string("s"), .array([.null]), .object(SpecObject())]

        #expect(values.compactMap(\.stringValue) == ["s"])
        #expect(values.compactMap(\.boolValue) == [true])
        #expect(values.compactMap(\.intValue) == [4])
        #expect(values.compactMap(\.doubleValue) == [4])
        #expect(values.compactMap(\.arrayValue).count == 1)
        #expect(values.compactMap(\.objectValue).count == 1)
        #expect(values.filter(\.isNull).count == 1)
    }

    @Test
    func subscriptingANonObjectYieldsNothingRatherThanTrapping() {
        #expect(SpecValue.array([.null])["key"] == nil)
        #expect(SpecValue.string("s")["key"] == nil)
    }

    @Test
    func onlyWholeNumbersInRangeReadAsIntegers() {
        #expect(SpecValue.number(1.5).intValue == nil)
        #expect(SpecValue.number(1e30).intValue == nil)
        #expect(SpecValue.number(-3).intValue == -3)
    }

    @Test
    func objectKeysKeepInsertionOrderAcrossUpdatesAndRemovals() {
        var object = SpecObject([("a", .number(1)), ("b", .number(2))])
        object["a"] = .number(3)
        object["c"] = .number(4)

        #expect(object.keys == ["a", "b", "c"])
        #expect(object["a"]?.intValue == 3)
        #expect(object.pairs.map(\.key) == ["a", "b", "c"])

        object["b"] = nil
        #expect(object.keys == ["a", "c"])
        #expect(SpecObject().isEmpty)
    }
}

@Suite
struct SwiftTypeReferenceTests {
    @Test
    func everyShapeRendersAsTheSwiftItStandsFor() {
        #expect(SwiftTypeReference.named("Pet").rendered == "Pet")
        #expect(SwiftTypeReference.array(.named("Pet")).rendered == "[Pet]")
        #expect(SwiftTypeReference.dictionary(.named("Pet")).rendered == "[String: Pet]")
        #expect(SwiftTypeReference.optional(.named("Pet")).rendered == "Pet?")
        #expect(SwiftTypeReference.indirect(.named("Pet")).rendered == "Indirect<Pet>")
    }

    @Test
    func optionalityNeverStacks() {
        let once = SwiftTypeReference.named("Pet").madeOptional

        #expect(once.rendered == "Pet?")
        #expect(once.madeOptional.rendered == "Pet?")
        #expect(once.isOptional)
        #expect(!SwiftTypeReference.named("Pet").isOptional)
    }

    @Test
    func dateDetectionAndBaseNameLookThroughEveryContainer() {
        let nested = SwiftTypeReference.optional(.array(.dictionary(.indirect(.named("Date")))))

        #expect(nested.mentionsDate)
        #expect(nested.baseName == "Date")
        #expect(!SwiftTypeReference.array(.named("Pet")).mentionsDate)
    }

    @Test
    func everyGeneratedTypeReportsItsName() {
        let types: [GeneratedType] = [
            .object(name: "A", properties: [], documentation: nil),
            .stringEnum(name: "B", cases: [], documentation: nil),
            .alias(name: "C", target: .named("Int"), documentation: nil),
            .anyJSON(name: "D"),
            .indirectBox(name: "E"),
        ]

        #expect(types.map(\.name) == ["A", "B", "C", "D", "E"])
    }

    @Test
    func generationErrorsDescribeThemselvesWithTheirLocation() {
        let error = GenerationError(message: "Boom.", location: "#/paths")

        #expect(error.errorDescription == "#/paths: Boom.")
    }
}

@Suite
struct SwiftNamingTests {
    @Test
    func separatorsAndCamelCaseBoundariesBothSplitWords() {
        #expect(SwiftNaming.typeName("pet_status") == "PetStatus")
        #expect(SwiftNaming.typeName("pet-status") == "PetStatus")
        #expect(SwiftNaming.typeName("petStatus") == "PetStatus")
        #expect(SwiftNaming.typeName("HTTPStatus") == "HTTPStatus")
        #expect(SwiftNaming.typeName("PET_ID") == "PetId")
    }

    @Test
    func namesThatCannotStartAnIdentifierAreMadeLegal() {
        #expect(SwiftNaming.typeName("2fa") == "_2fa")
        #expect(SwiftNaming.typeName("") == "Value")
        #expect(SwiftNaming.typeName("///") == "Value")
    }

    @Test
    func keywordsAreEscapedRatherThanRenamed() {
        #expect(SwiftNaming.propertyName("default") == "`default`")
        #expect(SwiftNaming.propertyName("self") == "`self`")
        #expect(SwiftNaming.propertyName("created_at") == "createdAt")
        #expect(SwiftNaming.enumCaseName("in progress") == "inProgress")
    }

    @Test
    func operationNamesPreferOperationIdAndFallBackToMethodAndPath() {
        #expect(SwiftNaming.operationTypeName(method: "get", path: "/pets", operationID: "listPets") == "ListPets")
        #expect(SwiftNaming.operationTypeName(method: "get", path: "/pets", operationID: "") == "GetPets")
        #expect(SwiftNaming.operationTypeName(method: "get", path: "/pets/{petId}/photo", operationID: nil) == "GetPetsByPetIdPhoto")
        #expect(SwiftNaming.operationTypeName(method: "get", path: "/", operationID: nil) == "GetRoot")
    }

    @Test
    func namespaceNamesGainAnAPISuffixOnlyWhenTheyLackOne() {
        #expect(SwiftNaming.namespaceName(title: "Petstore") == "PetstoreAPI")
        #expect(SwiftNaming.namespaceName(title: "Petstore API") == "PetstoreAPI")
    }

    @Test
    func collidingNamesAreNumberedInsteadOfOverwritingEachOther() {
        var taken: Set<String> = []

        #expect(SwiftNaming.disambiguated("GetPets", taken: &taken) == "GetPets")
        #expect(SwiftNaming.disambiguated("GetPets", taken: &taken) == "GetPets2")
        #expect(SwiftNaming.disambiguated("GetPets", taken: &taken) == "GetPets3")
    }
}

@Suite
struct FlowScannerDetailTests {
    private func parse(_ text: String) throws -> SpecValue {
        try SpecParser.parse(text)
    }

    @Test
    func aFlowCollectionMaySpanLines() throws {
        let value = try parse("""
        limits: {
          maxItems: 20,
          nested: [1, 2,
                   3],
        }
        """)

        #expect(value["limits"]?["maxItems"]?.intValue == 20)
        #expect(value["limits"]?["nested"]?.arrayValue?.compactMap(\.intValue) == [1, 2, 3])
    }

    @Test
    func commentsAndQuotedKeysAreHandledInsideFlowCollections() throws {
        let value = try parse("""
        limits: {"max-items": 20} # trailing
        """)

        #expect(value["limits"]?["max-items"]?.intValue == 20)
    }

    @Test
    func escapesInsideFlowStringsAreApplied() throws {
        let value = try parse(#"{"text": "tab\there", "quote": "\"", "solidus": "a\/b", "newline": "a\nb"}"#)

        #expect(value["text"]?.stringValue == "tab\there")
        #expect(value["quote"]?.stringValue == "\"")
        #expect(value["solidus"]?.stringValue == "a/b")
        #expect(value["newline"]?.stringValue == "a\nb")
    }

    @Test
    func singleQuotedFlowStringsDoubleTheirApostrophes() throws {
        #expect(try parse("value: ['it''s']")["value"]?.arrayValue?.first?.stringValue == "it's")
    }

    @Test
    func nullsAndBooleansAreRecognizedInFlowPosition() throws {
        let value = try parse("value: [null, ~, true, TRUE, false, 1.5]")
        let items = try #require(value["value"]?.arrayValue)

        #expect(items[0].isNull)
        #expect(items[1].isNull)
        #expect(items[2].boolValue == true)
        #expect(items[3].boolValue == true)
        #expect(items[4].boolValue == false)
        #expect(items[5].doubleValue == 1.5)
    }

    @Test
    func malformedFlowSyntaxIsRejectedWithItsLocation() throws {
        let cases = [
            "value: {a 1}",
            "value: {a: 1 b: 2}",
            "value: {a: 1",
            "value: {a: 1} extra",
            #"value: {"a": "\q"}"#,
            #"value: {"a": "\u00zz"}"#,
        ]

        for text in cases {
            #expect(throws: SpecParseError.self, "expected \(text) to be rejected") {
                _ = try parse(text)
            }
        }
    }

    @Test
    func blockScalarChompingIndicatorsAreAccepted() throws {
        let value = try parse("""
        kept: |+
          text
        stripped: >-
          folded
        """)

        #expect(value["kept"]?.stringValue == "text\n")
        #expect(value["stripped"]?.stringValue == "folded")
    }

    @Test
    func anUnsupportedBlockScalarHeaderIsRejected() {
        #expect(throws: SpecParseError.self) {
            _ = try SpecParser.parse("text: |2-\n  indented\n")
        }
    }

    @Test
    func aTrailingDocumentEndMarkerIsAccepted() throws {
        #expect(try SpecParser.parse("openapi: 3.1.0\n...\n")["openapi"]?.stringValue == "3.1.0")
    }

    @Test
    func aSequenceOfNestedBlocksUnderADashIsRead() throws {
        let value = try SpecParser.parse("""
        items:
          -
            name: first
          - name: second
        """)

        #expect(value["items"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["first", "second"])
    }
}
