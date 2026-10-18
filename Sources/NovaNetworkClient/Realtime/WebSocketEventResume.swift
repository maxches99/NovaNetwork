import NovaNetworkCore
import Foundation

/// Where an inbound event sits in a server's ordered event stream.
public struct WebSocketEventPosition: Sendable, Equatable {
    /// The stream the event belongs to.
    ///
    /// It must equal the ID the app passed to ``WebSocketClient/registerSubscription(id:message:options:)``
    /// for that stream, because that is the subscription the client re-sends with the cursor.
    public let streamID: String
    /// The event's position in the stream. Sequences increase by one per event.
    public let sequence: UInt64

    /// Creates a position.
    public init(streamID: String, sequence: UInt64) {
        self.streamID = streamID
        self.sequence = sequence
    }
}

/// Something the client noticed while tracking event streams, for the app to act on.
public enum WebSocketEventResumeEvent: Sendable, Equatable {
    /// A subscription was re-sent after a reconnect, asking for events after `afterSequence`.
    case resumeRequested(streamID: String, afterSequence: UInt64)
    /// Events between `expectedSequence` and `receivedSequence` (exclusive) never arrived.
    ///
    /// The event at `receivedSequence` was delivered and the cursor moved past the gap. Refetch a
    /// snapshot, or mark the screen as possibly incomplete.
    case gapDetected(streamID: String, expectedSequence: UInt64, receivedSequence: UInt64)
    /// The server can no longer replay from the cursor; it has been cleared.
    ///
    /// Refetch a snapshot over HTTP and seed the cursor from it with
    /// ``WebSocketClient/seedEventCursor(_:forStream:)``.
    case resyncRequired(streamID: String)
}

/// How a server numbers its events and resumes a subscription, so a reconnect can ask for what it missed.
///
/// With a policy, ``WebSocketClient`` records the last sequence it delivered per stream. After a
/// reconnect it re-sends each registered subscription as ``resumeMessage`` with that sequence, drops
/// the events it already delivered, and reports gaps and resync signals on
/// ``WebSocketClient/eventResumeEvents()``.
///
/// ``default`` follows one JSON convention; any other protocol is three closures.
public struct WebSocketEventResumePolicy: Sendable {
    /// Reads the stream and sequence from an inbound message, or `nil` for a message that is not a
    /// sequenced event.
    public let position: @Sendable (WebSocketMessage) -> WebSocketEventPosition?
    /// Builds the subscription that asks for events after `afterSequence`, from the subscription the
    /// app registered. Returning `nil` re-sends the original.
    public let resumeMessage: @Sendable (_ subscription: WebSocketMessage, _ afterSequence: UInt64) -> WebSocketMessage?
    /// Reads the stream ID from a server's "cannot replay that far back" message, or `nil`.
    public let resyncSignal: @Sendable (WebSocketMessage) -> String?

    /// Creates a policy from the three pieces of a server's resume protocol.
    public init(
        position: @escaping @Sendable (WebSocketMessage) -> WebSocketEventPosition?,
        resumeMessage: @escaping @Sendable (_ subscription: WebSocketMessage, _ afterSequence: UInt64) -> WebSocketMessage?,
        resyncSignal: @escaping @Sendable (WebSocketMessage) -> String? = { _ in nil }
    ) {
        self.position = position
        self.resumeMessage = resumeMessage
        self.resyncSignal = resyncSignal
    }

    /// A JSON convention.
    ///
    /// - Events carry `"stream"` (a string) and `"seq"` (a non-negative integer).
    /// - A subscription that is a JSON object is resumed by adding `"afterSeq"`; any other
    ///   subscription is re-sent unchanged.
    /// - `{"type": "resync_required", "stream": "<id>"}` is the resync signal.
    public static let `default` = WebSocketEventResumePolicy(
        position: { message in
            guard let object = jsonObject(message),
                  let stream = object["stream"] as? String,
                  let sequence = object["seq"] as? Int,
                  sequence >= 0 else {
                return nil
            }
            return WebSocketEventPosition(streamID: stream, sequence: UInt64(sequence))
        },
        resumeMessage: { subscription, afterSequence in
            guard var object = jsonObject(subscription) else {
                return nil
            }
            object["afterSeq"] = afterSequence
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return .text(text)
        },
        resyncSignal: { message in
            guard let object = jsonObject(message),
                  object["type"] as? String == "resync_required" else {
                return nil
            }
            return object["stream"] as? String
        }
    )

    private static func jsonObject(_ message: WebSocketMessage) -> [String: Any]? {
        let data: Data
        switch message {
        case .text(let text):
            data = Data(text.utf8)
        case .binary(let binary):
            data = binary
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

actor WebSocketEventResumeHub {
    private var continuations: [UUID: AsyncStream<WebSocketEventResumeEvent>.Continuation] = [:]

    func makeStream() -> AsyncStream<WebSocketEventResumeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    func emit(_ event: WebSocketEventResumeEvent) {
        for continuation in continuations.values {
            continuation.yield(event)
        }
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
