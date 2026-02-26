import Foundation

struct PersistedOfflineWriteEnvelope: Codable {
    let schemaVersion: Int
    let entry: PersistedOfflineWriteEntry
}

struct PersistedOfflineWriteEntry: Codable {
    struct PersistedQueryItem: Codable {
        let name: String
        let value: String?
    }

    let queueID: String
    let requestKey: String
    let position: Int
    let enqueuedAt: Date
    let method: URLMethod
    let url: URL
    let queryItems: [PersistedQueryItem]
    let headers: [String: String]
    let body: Data?
    let timeout: TimeInterval
    let attempt: Int
    let nextRetryAt: Date?
    let lastFailureReason: String?
    let stateRaw: String
    let updatedAt: Date
}

extension PersistedOfflineWriteEntry {
    init(from entry: OfflineWriteStoreEntry) {
        self.queueID = entry.receipt.queueID
        self.requestKey = entry.receipt.requestKey
        self.position = entry.receipt.position
        self.enqueuedAt = entry.receipt.enqueuedAt
        self.method = entry.request.method
        self.url = entry.request.url
        self.queryItems = entry.request.queryItems.map { PersistedQueryItem(name: $0.name, value: $0.value) }
        self.headers = entry.request.headers
        self.body = entry.request.body
        self.timeout = entry.request.timeout
        self.attempt = entry.attempt
        self.nextRetryAt = entry.nextRetryAt
        self.lastFailureReason = entry.lastFailureReason
        self.stateRaw = entry.state.rawValue
        self.updatedAt = entry.updatedAt
    }

    func toRuntimeEntry() -> OfflineWriteStoreEntry? {
        guard let state = OfflineQueueEntryState(rawValue: stateRaw) else {
            return nil
        }

        let receipt = QueuedWriteReceipt(
            queueID: queueID,
            requestKey: requestKey,
            position: position,
            enqueuedAt: enqueuedAt
        )
        let request = APIRequest(
            method: method,
            url: url,
            queryItems: queryItems.map { URLQueryItem(name: $0.name, value: $0.value) },
            headers: headers,
            body: body,
            timeout: timeout
        )
        return OfflineWriteStoreEntry(
            receipt: receipt,
            request: request,
            attempt: attempt,
            nextRetryAt: nextRetryAt,
            lastFailureReason: lastFailureReason,
            state: state,
            updatedAt: updatedAt
        )
    }
}

extension OfflineQueueEntryState {
    init?(rawValue: String) {
        switch rawValue {
        case OfflineQueueEntryState.queued.rawValue:
            self = .queued
        case OfflineQueueEntryState.replayScheduled.rawValue:
            self = .replayScheduled
        case OfflineQueueEntryState.replaying.rawValue:
            self = .replaying
        case OfflineQueueEntryState.retryWaiting.rawValue:
            self = .retryWaiting
        case OfflineQueueEntryState.deadLetter.rawValue:
            self = .deadLetter
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .queued:
            return "queued"
        case .replayScheduled:
            return "replayScheduled"
        case .replaying:
            return "replaying"
        case .retryWaiting:
            return "retryWaiting"
        case .deadLetter:
            return "deadLetter"
        }
    }
}
