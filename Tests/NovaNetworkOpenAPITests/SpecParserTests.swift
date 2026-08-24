import Foundation
import Testing
@testable import NovaNetworkOpenAPI

// Requirements: FR-17 (JSON and YAML subset read identically), EC-8 (located errors for
// unsupported syntax). Tests: T-17.1, T-17.2.

private let yamlDocument = """
# A comment line
openapi: "3.1.0"
info:
  title: Petstore
  version: 1.0.0        # trailing comment
  retries: 3
  public: true
  contact: null
servers:
  - url: https://api.example.com/v1
    description: Production
  - url: https://staging.example.com
tags: [pets, store]
limits: {maxItems: 20, enabled: false}
description: |
  First line
  Second line
summary: >
  folded over
  two lines
quoted: "a: colon, and a # hash"
single: 'it''s quoted'
"""

private let jsonDocument = """
{
  "openapi": "3.1.0",
  "info": {
    "title": "Petstore",
    "version": "1.0.0",
    "retries": 3,
    "public": true,
    "contact": null
  },
  "servers": [
    {"url": "https://api.example.com/v1", "description": "Production"},
    {"url": "https://staging.example.com"}
  ],
  "tags": ["pets", "store"],
  "limits": {"maxItems": 20, "enabled": false}
}
"""

@Suite
struct SpecParserTests {
    @Test
    func blockMappingsSequencesAndScalarsAreRead() throws {
        let document = try SpecParser.parse(yamlDocument)

        #expect(document["openapi"]?.stringValue == "3.1.0")
        #expect(document["info"]?["title"]?.stringValue == "Petstore")
        #expect(document["info"]?["version"]?.stringValue == "1.0.0")
        #expect(document["info"]?["retries"]?.intValue == 3)
        #expect(document["info"]?["public"]?.boolValue == true)
        #expect(document["info"]?["contact"]?.isNull == true)
    }

    @Test
    func aMappingWrittenInlineAfterADashIsReadAsOneEntry() throws {
        let servers = try #require(SpecParser.parse(yamlDocument)["servers"]?.arrayValue)

        #expect(servers.count == 2)
        #expect(servers[0]["url"]?.stringValue == "https://api.example.com/v1")
        #expect(servers[0]["description"]?.stringValue == "Production")
        #expect(servers[1]["url"]?.stringValue == "https://staging.example.com")
        #expect(servers[1]["description"] == nil)
    }

    @Test
    func flowCollectionsAreReadInBothPositions() throws {
        let document = try SpecParser.parse(yamlDocument)

        #expect(document["tags"]?.arrayValue?.compactMap(\.stringValue) == ["pets", "store"])
        #expect(document["limits"]?["maxItems"]?.intValue == 20)
        #expect(document["limits"]?["enabled"]?.boolValue == false)
    }

    @Test
    func blockScalarsKeepOrFoldTheirLineBreaks() throws {
        let document = try SpecParser.parse(yamlDocument)

        #expect(document["description"]?.stringValue == "First line\nSecond line")
        #expect(document["summary"]?.stringValue == "folded over two lines")
    }

    @Test
    func quotingProtectsColonsHashesAndApostrophes() throws {
        let document = try SpecParser.parse(yamlDocument)

        #expect(document["quoted"]?.stringValue == "a: colon, and a # hash")
        #expect(document["single"]?.stringValue == "it's quoted")
    }

    @Test
    func keyOrderFollowsTheDocumentRatherThanADictionarysHashing() throws {
        let info = try #require(SpecParser.parse(yamlDocument)["info"]?.objectValue)

        #expect(info.keys == ["title", "version", "retries", "public", "contact"])
    }

    @Test
    func theSameDocumentInJSONAndYAMLParsesToTheSameValue() throws {
        let fromJSON = try SpecParser.parse(jsonDocument)
        let fromYAML = try SpecParser.parse(yamlDocument)

        #expect(fromJSON["info"] == fromYAML["info"])
        #expect(fromJSON["servers"] == fromYAML["servers"])
        #expect(fromJSON["tags"] == fromYAML["tags"])
        #expect(fromJSON["limits"] == fromYAML["limits"])
    }

    @Test
    func jsonEscapesAreApplied() throws {
        let document = try SpecParser.parse(#"{"text": "line\nbreak é \"quoted\""}"#)

        #expect(document["text"]?.stringValue == "line\nbreak é \"quoted\"")
    }

    @Test
    func anEmptyDocumentIsNull() throws {
        #expect(try SpecParser.parse("") == .null)
        #expect(try SpecParser.parse("# only a comment\n") == .null)
    }

    @Test
    func aLeadingDocumentMarkerIsAccepted() throws {
        #expect(try SpecParser.parse("---\nopenapi: 3.0.0\n")["openapi"]?.stringValue == "3.0.0")
    }
}

@Suite
struct SpecParserErrorTests {
    private func parseError(_ text: String) throws -> SpecParseError {
        do {
            _ = try SpecParser.parse(text)
            Issue.record("Expected a parse error")
            return SpecParseError(message: "", line: 0, column: 0)
        } catch let error as SpecParseError {
            return error
        }
    }

    @Test
    func tabsUsedForIndentationAreRejectedWithTheirLocation() throws {
        let error = try parseError("info:\n\ttitle: Petstore\n")

        #expect(error.message.contains("Tabs"))
        #expect(error.line == 2)
        #expect(error.column == 1)
    }

    @Test
    func anUnterminatedQuoteIsRejected() throws {
        let error = try parseError("title: \"unterminated\n")

        #expect(error.message.contains("Unterminated"))
        #expect(error.line == 1)
    }

    @Test
    func anchorsAndAliasesAreRejectedRatherThanGuessedAt() throws {
        let anchor = try parseError("defaults: &base\n  a: 1\n")
        let tag = try parseError("value: !!str 5\n")

        #expect(anchor.message.contains("Anchors"))
        #expect(tag.message.contains("tags"))
    }

    @Test
    func aSecondDocumentInTheStreamIsRejected() throws {
        let error = try parseError("openapi: 3.0.0\n---\nopenapi: 3.1.0\n")

        #expect(error.message.contains("Multi-document"))
        #expect(error.line == 2)
    }

    @Test
    func anUnterminatedFlowCollectionIsRejected() throws {
        let error = try parseError("tags: [a, b\n")

        #expect(error.message.contains("Unterminated flow sequence"))
    }

    @Test
    func inconsistentIndentationIsRejectedWithTheExpectedWidth() throws {
        let error = try parseError("info:\n  title: A\n     version: B\n")

        #expect(error.message.contains("indentation"))
        #expect(error.line == 3)
    }

    @Test
    func theErrorDescriptionCarriesLineAndColumn() {
        let error = SpecParseError(message: "Boom.", line: 4, column: 7)

        #expect(error.errorDescription == "4:7: Boom.")
    }
}
