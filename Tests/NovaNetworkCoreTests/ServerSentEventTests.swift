import Foundation
import Testing
import NovaNetworkCore

// Requirements: FR-SSE-1 (line parsing), FR-SSE-2 (byte decoding).

@Suite
struct ServerSentEventTests {
    @Test
    func parserDispatchesSimpleEventOnBlankLine() {
        var parser = SSELineParser()
        #expect(parser.consumeLine("data: hello") == nil)
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: nil, event: "message", data: "hello")))
    }

    @Test
    func parserJoinsMultipleDataLinesWithNewline() {
        var parser = SSELineParser()
        _ = parser.consumeLine("data: line one")
        _ = parser.consumeLine("data: line two")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: nil, event: "message", data: "line one\nline two")))
    }

    @Test
    func parserAssignsCustomEventTypeAndID() {
        var parser = SSELineParser()
        _ = parser.consumeLine("event: update")
        _ = parser.consumeLine("id: 42")
        _ = parser.consumeLine("data: payload")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: "42", event: "update", data: "payload")))
        #expect(parser.lastEventID == "42")
    }

    @Test
    func parserPersistsLastEventIDAcrossEvents() {
        var parser = SSELineParser()
        _ = parser.consumeLine("id: 1")
        _ = parser.consumeLine("data: first")
        _ = parser.consumeLine("")
        _ = parser.consumeLine("data: second")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: "1", event: "message", data: "second")))
    }

    @Test
    func parserIgnoresCommentLines() {
        var parser = SSELineParser()
        #expect(parser.consumeLine(": this is a comment") == nil)
        _ = parser.consumeLine("data: hi")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: nil, event: "message", data: "hi")))
    }

    @Test
    func parserSkipsDispatchWhenDataBufferEmpty() {
        var parser = SSELineParser()
        _ = parser.consumeLine("event: ping")
        let element = parser.consumeLine("")
        #expect(element == nil)
    }

    @Test
    func parserIgnoresIDFieldContainingNUL() {
        var parser = SSELineParser()
        _ = parser.consumeLine("id: bad\u{0000}id")
        _ = parser.consumeLine("data: x")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: nil, event: "message", data: "x")))
    }

    @Test
    func parserEmitsRetryIntervalUpdateForNumericValue() {
        var parser = SSELineParser()
        let element = parser.consumeLine("retry: 5000")
        #expect(element == .retryIntervalUpdate(5000))
    }

    @Test
    func parserIgnoresNonNumericRetryValue() {
        var parser = SSELineParser()
        let element = parser.consumeLine("retry: soon")
        #expect(element == nil)
    }

    @Test
    func parserTreatsLineWithoutColonAsFieldNameWithEmptyValue() {
        var parser = SSELineParser()
        _ = parser.consumeLine("data")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: nil, event: "message", data: "")))
    }

    @Test
    func parserStripsSingleLeadingSpaceFromValue() {
        var parser = SSELineParser()
        _ = parser.consumeLine("data:  two leading spaces collapse to one stripped")
        let element = parser.consumeLine("")
        #expect(element == .event(ServerSentEvent(id: nil, event: "message", data: " two leading spaces collapse to one stripped")))
    }

    @Test
    func decoderHandlesLFTerminatedStream() {
        var decoder = SSEDecoder()
        let bytes = Data("data: hello\n\n".utf8)
        let elements = decoder.decode(bytes)
        #expect(elements == [.event(ServerSentEvent(id: nil, event: "message", data: "hello"))])
    }

    @Test
    func decoderHandlesCRLFTerminatedStream() {
        var decoder = SSEDecoder()
        let bytes = Data("data: hello\r\n\r\n".utf8)
        let elements = decoder.decode(bytes)
        #expect(elements == [.event(ServerSentEvent(id: nil, event: "message", data: "hello"))])
    }

    @Test
    func decoderHandlesLoneCRTerminatedStream() {
        var decoder = SSEDecoder()
        let bytes = Data("data: hello\r\r".utf8)
        let elements = decoder.decode(bytes)
        #expect(elements == [.event(ServerSentEvent(id: nil, event: "message", data: "hello"))])
    }

    @Test
    func decoderHandlesLineSplitAcrossChunks() {
        var decoder = SSEDecoder()
        var elements = decoder.decode(Data("data: hel".utf8))
        #expect(elements.isEmpty)
        elements = decoder.decode(Data("lo\n\n".utf8))
        #expect(elements == [.event(ServerSentEvent(id: nil, event: "message", data: "hello"))])
    }

    @Test
    func decoderHandlesCRLFSplitAcrossChunks() {
        var decoder = SSEDecoder()
        var elements = decoder.decode(Data("data: hello\r".utf8))
        #expect(elements.isEmpty)
        elements = decoder.decode(Data("\n\r\n".utf8))
        #expect(elements == [.event(ServerSentEvent(id: nil, event: "message", data: "hello"))])
    }

    @Test
    func decoderStripsLeadingByteOrderMark() {
        var decoder = SSEDecoder()
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("data: hello\n\n".utf8))
        let elements = decoder.decode(bytes)
        #expect(elements == [.event(ServerSentEvent(id: nil, event: "message", data: "hello"))])
    }

    @Test
    func decoderFlushProcessesTrailingUnterminatedLineWithoutFabricatingAnEvent() {
        // A trailing line with no terminator at all is never followed by the blank line that
        // dispatches an event, so per spec it must not synthesize a `.event`. flush() still
        // applies the line's side effect (updating the last event ID) so it isn't silently lost.
        var decoder = SSEDecoder()
        _ = decoder.decode(Data("id: trailing".utf8))
        let flushed = decoder.flush()
        #expect(flushed == nil)
        #expect(decoder.lastEventID == "trailing")
    }

    @Test
    func decoderFlushReturnsNilWhenNothingBuffered() {
        var decoder = SSEDecoder()
        _ = decoder.decode(Data("data: hello\n\n".utf8))
        #expect(decoder.flush() == nil)
    }

    @Test
    func decoderTracksLastEventID() {
        var decoder = SSEDecoder()
        _ = decoder.decode(Data("id: abc\ndata: x\n\n".utf8))
        #expect(decoder.lastEventID == "abc")
    }

    @Test
    func decoderEmitsRetryIntervalUpdateElement() {
        var decoder = SSEDecoder()
        let elements = decoder.decode(Data("retry: 2500\n\n".utf8))
        #expect(elements == [.retryIntervalUpdate(2500)])
    }

    @Test
    func decoderHandlesMultipleEventsInOneChunk() {
        var decoder = SSEDecoder()
        let bytes = Data("data: first\n\ndata: second\n\n".utf8)
        let elements = decoder.decode(bytes)
        #expect(
            elements == [
                .event(ServerSentEvent(id: nil, event: "message", data: "first")),
                .event(ServerSentEvent(id: nil, event: "message", data: "second")),
            ]
        )
    }
}
