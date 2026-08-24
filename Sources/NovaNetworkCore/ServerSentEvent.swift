import Foundation

/// A single parsed Server-Sent Events (SSE) message.
///
/// See the WHATWG HTML "Server-sent events" specification for the wire format this models.
public struct ServerSentEvent: Sendable, Equatable, Hashable {
    /// The event's `id:` field, or `nil` if the stream has not sent one yet.
    public let id: String?
    /// The event's `event:` field, defaulting to `"message"` when the field is absent.
    public let event: String
    /// The event's `data:` field, with individual `data:` lines joined by `"\n"`.
    public let data: String

    public init(id: String?, event: String, data: String) {
        self.id = id
        self.event = event
        self.data = data
    }
}

/// One element produced while decoding an SSE byte stream.
public enum SSEParsedElement: Sendable, Equatable {
    /// A dispatched event.
    case event(ServerSentEvent)
    /// An updated reconnection time in milliseconds, from a `retry:` field.
    case retryIntervalUpdate(Int)
}

/// Errors specific to Server-Sent Events handling.
public enum ServerSentEventError: Error, Sendable, Equatable {
    /// The configured transport does not implement ``ServerSentEventTransport``.
    case transportUnsupported
    /// The reconnect policy's attempt budget was exhausted.
    case reconnectAttemptsExhausted
}

/// A pure, incremental line-level parser for the SSE wire format.
///
/// Feed complete, terminator-stripped lines to ``consumeLine(_:)``. State persists across
/// dispatched events, matching the specification's carry-over "last event ID" behavior.
public struct SSELineParser: Sendable {
    private var dataBuffer = ""
    private var eventTypeBuffer = ""
    private var lastEventIDStorage: String?

    public init() {}

    /// The most recently seen non-NUL `id:` value, persisted across dispatched events.
    public var lastEventID: String? { lastEventIDStorage }

    /// Processes one line (without its terminator) and returns a parsed element, if any.
    public mutating func consumeLine(_ line: String) -> SSEParsedElement? {
        if line.isEmpty {
            return dispatch()
        }
        if line.hasPrefix(":") {
            return nil
        }

        let (field, value) = Self.splitField(line)
        switch field {
        case "event":
            eventTypeBuffer = value
            return nil
        case "data":
            dataBuffer += value
            dataBuffer += "\n"
            return nil
        case "id":
            guard !value.contains("\u{0000}") else { return nil }
            lastEventIDStorage = value
            return nil
        case "retry":
            guard let retryValue = Int(value), retryValue >= 0 else { return nil }
            return .retryIntervalUpdate(retryValue)
        default:
            return nil
        }
    }

    private mutating func dispatch() -> SSEParsedElement? {
        defer {
            dataBuffer = ""
            eventTypeBuffer = ""
        }
        guard !dataBuffer.isEmpty else { return nil }
        var data = dataBuffer
        if data.hasSuffix("\n") {
            data.removeLast()
        }
        let type = eventTypeBuffer.isEmpty ? "message" : eventTypeBuffer
        return .event(ServerSentEvent(id: lastEventIDStorage, event: type, data: data))
    }

    private static func splitField(_ line: String) -> (String, String) {
        guard let colonIndex = line.firstIndex(of: ":") else {
            return (line, "")
        }
        let field = String(line[line.startIndex..<colonIndex])
        var valueStart = line.index(after: colonIndex)
        if valueStart < line.endIndex, line[valueStart] == " " {
            valueStart = line.index(after: valueStart)
        }
        return (field, String(line[valueStart...]))
    }
}

/// Decodes a raw SSE byte stream (UTF-8, CR/LF/CRLF line endings) into parsed elements.
///
/// Feed arbitrarily-sized ``Data`` chunks as they arrive from the transport; state persists
/// across calls so a line split across chunk boundaries is still parsed correctly.
public struct SSEDecoder: Sendable {
    private var parser = SSELineParser()
    private var pendingBytes: [UInt8] = []
    private var pendingCR = false
    private var strippedBOM = false

    public init() {}

    /// The most recently seen `id:` value, for `Last-Event-ID` reconnect headers.
    public var lastEventID: String? { parser.lastEventID }

    /// Decodes one chunk, returning zero or more parsed elements in wire order.
    public mutating func decode(_ chunk: Data) -> [SSEParsedElement] {
        var elements: [SSEParsedElement] = []
        for byte in chunk {
            guard let lineBytes = consumeByte(byte) else { continue }
            if let element = parseLine(lineBytes) {
                elements.append(element)
            }
        }
        return elements
    }

    /// Flushes a final, terminator-less trailing line at stream end, if one is buffered.
    public mutating func flush() -> SSEParsedElement? {
        guard !pendingBytes.isEmpty else { return nil }
        let lineBytes = pendingBytes
        pendingBytes.removeAll()
        return parseLine(lineBytes)
    }

    private mutating func parseLine(_ lineBytes: [UInt8]) -> SSEParsedElement? {
        var lineBytes = lineBytes
        if !strippedBOM {
            strippedBOM = true
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            if lineBytes.starts(with: bom) {
                lineBytes.removeFirst(bom.count)
            }
        }
        guard let line = String(bytes: lineBytes, encoding: .utf8) else { return nil }
        return parser.consumeLine(line)
    }

    private mutating func consumeByte(_ byte: UInt8) -> [UInt8]? {
        if pendingCR {
            pendingCR = false
            if byte == 0x0A {
                return nil
            }
        }
        if byte == 0x0D {
            pendingCR = true
            let line = pendingBytes
            pendingBytes.removeAll(keepingCapacity: true)
            return line
        }
        if byte == 0x0A {
            let line = pendingBytes
            pendingBytes.removeAll(keepingCapacity: true)
            return line
        }
        pendingBytes.append(byte)
        return nil
    }
}

/// Transport capability for consuming a `text/event-stream` response incrementally.
public protocol ServerSentEventTransport: NetworkTransport {
    /// Starts an SSE connection and yields parsed elements, including reconnection-time updates.
    ///
    /// Cancelling or terminating iteration must cancel the underlying transfer.
    func serverSentEventElements(
        _ request: APIRequest,
        authScope: String?
    ) -> AsyncThrowingStream<SSEParsedElement, Error>
}

public extension ServerSentEventTransport {
    /// A convenience view over ``serverSentEventElements(_:authScope:)`` that yields only events.
    func serverSentEvents(
        _ request: APIRequest,
        authScope: String?
    ) -> AsyncThrowingStream<ServerSentEvent, Error> {
        let elements = serverSentEventElements(request, authScope: authScope)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in elements {
                        if case .event(let event) = element {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
