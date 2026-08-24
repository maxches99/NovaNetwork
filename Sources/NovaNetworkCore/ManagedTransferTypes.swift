import Foundation

/// Stable identity for a managed transfer operation.
public struct TransferID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    /// String representation persisted in transfer journals and background task metadata.
    public let rawValue: String

    /// Creates an identifier from a persisted string.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates a new random transfer identifier.
    public init() {
        self.init(rawValue: UUID().uuidString)
    }

    /// Human-readable identifier value.
    public var description: String { rawValue }
}

/// Kind of work performed by a managed transfer.
public enum ManagedTransferKind: String, Codable, Sendable, Equatable {
    /// Request-body upload.
    case upload
    /// Response-body download.
    case download
}

/// Durable lifecycle state for a managed transfer.
public enum ManagedTransferState: String, Codable, Sendable, Equatable {
    /// Transfer is accepted but has not started preparation.
    case queued
    /// Request, files, and server capabilities are being prepared.
    case preparing
    /// Bytes are actively moving.
    case transferring
    /// Work is intentionally or system-suspended.
    case suspended
    /// A partial operation is being resumed.
    case resuming
    /// Persisted state is being reconciled after process relaunch.
    case restoring
    /// Output is being validated and atomically finalized.
    case finalizing
    /// Transfer completed successfully.
    case completed
    /// Transfer ended with an error.
    case failed
    /// Transfer was cancelled.
    case cancelled

    /// Whether no further lifecycle transition is allowed.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

/// Execution environment requested for a managed transfer.
public enum TransferExecutionMode: Codable, Sendable, Equatable {
    /// Execute while the host process remains active.
    case foreground
    /// Use an Apple background URLSession owned by the supplied identifier.
    case background(sessionIdentifier: String)
}

/// Resume behavior for interrupted transfers.
public enum TransferResumePolicy: String, Codable, Sendable, Equatable {
    /// Never reuse partial transfer state.
    case disabled
    /// Resume when the server and persisted metadata support it, otherwise restart safely.
    case automatic
    /// Resume only when a validator is available; otherwise restart safely.
    case requiresValidator
}

/// Integrity checks applied before a downloaded file becomes visible at its destination.
public enum TransferIntegrityPolicy: Codable, Sendable, Equatable {
    /// Do not perform an additional integrity check.
    case none
    /// Require an exact final byte count.
    case expectedByteCount(Int64)
    /// Require a lowercase or uppercase hexadecimal SHA-256 digest.
    case expectedSHA256(String)
    /// Require both byte count and SHA-256 digest to match.
    case expectedByteCountAndSHA256(byteCount: Int64, sha256: String)
}

/// URLSession network scheduling preferences for a managed transfer.
public struct TransferNetworkPolicy: Codable, Sendable, Equatable {
    /// Whether the transfer may use cellular access.
    public let allowsCellularAccess: Bool
    /// Whether the transfer may use an expensive network path.
    public let allowsExpensiveNetworkAccess: Bool
    /// Whether the transfer may use a constrained network path.
    public let allowsConstrainedNetworkAccess: Bool
    /// Whether the system may defer the transfer for optimal conditions.
    public let isDiscretionary: Bool
    /// Relative URLSession task priority, clamped to `0...1`.
    public let priority: Double

    /// Creates transfer network scheduling preferences.
    public init(
        allowsCellularAccess: Bool = true,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = true,
        isDiscretionary: Bool = false,
        priority: Double = 0.5
    ) {
        self.allowsCellularAccess = allowsCellularAccess
        self.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        self.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        self.isDiscretionary = isDiscretionary
        self.priority = min(1, max(0, priority))
    }
}

/// Behavior when the consumer stops iterating a managed transfer event stream.
public enum TransferConsumerTerminationPolicy: String, Codable, Sendable, Equatable {
    /// Keep the transfer running independently of an individual event consumer.
    case keepRunning
    /// Cancel the transfer after the consumer terminates iteration.
    case cancelTransfer
}

/// Options controlling managed transfer execution, recovery, integrity, and scheduling.
public struct ManagedTransferOptions: Codable, Sendable, Equatable {
    /// Foreground or background execution selection.
    public let execution: TransferExecutionMode
    /// Interrupted-transfer resume behavior.
    public let resume: TransferResumePolicy
    /// Final output integrity requirement.
    public let integrity: TransferIntegrityPolicy
    /// Network path and scheduling preferences.
    public let networkPolicy: TransferNetworkPolicy
    /// Behavior when an event consumer terminates.
    public let consumerTerminationPolicy: TransferConsumerTerminationPolicy

    /// Creates managed transfer options.
    public init(
        execution: TransferExecutionMode = .foreground,
        resume: TransferResumePolicy = .automatic,
        integrity: TransferIntegrityPolicy = .none,
        networkPolicy: TransferNetworkPolicy = .init(),
        consumerTerminationPolicy: TransferConsumerTerminationPolicy = .keepRunning
    ) {
        self.execution = execution
        self.resume = resume
        self.integrity = integrity
        self.networkPolicy = networkPolicy
        self.consumerTerminationPolicy = consumerTerminationPolicy
    }
}

/// Validator used to protect a partial download from a changed server resource.
public struct TransferResourceValidator: Codable, Sendable, Equatable {
    /// Entity tag returned by the server, when available.
    public let eTag: String?
    /// Last-Modified value returned by the server, when available.
    public let lastModified: String?

    /// Creates a resource validator.
    public init(eTag: String? = nil, lastModified: String? = nil) {
        self.eTag = eTag
        self.lastModified = lastModified
    }

    /// Header value suitable for an `If-Range` request.
    public var ifRangeValue: String? { eTag ?? lastModified }
}

/// Durable, credential-free view of one managed transfer.
public struct ManagedTransferSnapshot: Codable, Sendable, Equatable {
    /// Stable transfer identity.
    public let id: TransferID
    /// Upload or download operation kind.
    public let kind: ManagedTransferKind
    /// Current durable lifecycle state.
    public let state: ManagedTransferState
    /// Original creation time.
    public let createdAt: Date
    /// Time of the latest state or progress update.
    public let updatedAt: Date
    /// Completed byte count.
    public let completedBytes: Int64
    /// Expected total byte count, when known.
    public let totalBytes: Int64?
    /// Request URL without headers or credentials.
    public let requestURL: URL
    /// HTTP method raw value.
    public let method: String
    /// Execution, resume, integrity, and network policy selected for the transfer.
    public let options: ManagedTransferOptions
    /// Final download destination, when applicable.
    public let destinationURL: URL?
    /// Existing-destination behavior for a managed download.
    public let destinationPolicy: DownloadDestinationPolicy
    /// Private partial-file location used for resumable download.
    public let partialFileURL: URL?
    /// Server validator associated with partial bytes.
    public let validator: TransferResourceValidator?
    /// Server-created resumable upload resource URL.
    public let uploadURL: URL?
    /// Server-confirmed resumable upload offset.
    public let uploadOffset: Int64?
    /// Background URLSession identifier, when applicable.
    public let sessionIdentifier: String?
    /// Background URLSession task identifier, when known.
    public let taskIdentifier: Int?
    /// Sanitized terminal or recovery reason.
    public let lastErrorReason: String?

    /// Creates a durable transfer snapshot.
    public init(
        id: TransferID,
        kind: ManagedTransferKind,
        state: ManagedTransferState,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedBytes: Int64 = 0,
        totalBytes: Int64? = nil,
        requestURL: URL,
        method: String,
        options: ManagedTransferOptions = .init(),
        destinationURL: URL? = nil,
        destinationPolicy: DownloadDestinationPolicy = .failIfExists,
        partialFileURL: URL? = nil,
        validator: TransferResourceValidator? = nil,
        uploadURL: URL? = nil,
        uploadOffset: Int64? = nil,
        sessionIdentifier: String? = nil,
        taskIdentifier: Int? = nil,
        lastErrorReason: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.createdAt = Self.normalizedToMillisecondPrecision(createdAt)
        self.updatedAt = Self.normalizedToMillisecondPrecision(updatedAt)
        self.completedBytes = max(0, completedBytes)
        self.totalBytes = totalBytes.flatMap { $0 >= 0 ? $0 : nil }
        self.requestURL = requestURL
        self.method = method
        self.options = options
        self.destinationURL = destinationURL
        self.destinationPolicy = destinationPolicy
        self.partialFileURL = partialFileURL
        self.validator = validator
        self.uploadURL = uploadURL
        self.uploadOffset = uploadOffset.flatMap { $0 >= 0 ? $0 : nil }
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.lastErrorReason = lastErrorReason
    }

    /// Rounds a timestamp to the nearest millisecond.
    ///
    /// `DiskTransferJournal` persists timestamps as `Double` seconds-since-1970; encoding and
    /// decoding a full-precision `Date()` through that representation does not always round-trip
    /// exactly (Foundation's JSON number formatting is not guaranteed bit-exact for arbitrary
    /// doubles, and empirically loses agreement roughly half the time for an unrounded
    /// timestamp). Normalizing to a millisecond boundary here, at construction time, keeps a
    /// freshly created snapshot and one round-tripped through the journal equal by `==` -- and
    /// millisecond precision is more than sufficient for transfer bookkeeping timestamps.
    private static func normalizedToMillisecondPrecision(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}

/// Sendable control surface and event stream for one managed transfer.
public struct ManagedTransferHandle: Sendable {
    /// Stable transfer identity.
    public let id: TransferID
    /// Lifecycle events for this subscription.
    public let events: AsyncStream<ManagedTransferEvent>

    private let snapshotProvider: @Sendable () async -> ManagedTransferSnapshot?
    private let cancellationAction: @Sendable () async -> Void

    /// Creates a managed transfer handle backed by coordinator operations.
    ///
    /// Library consumers normally receive handles from `NetworkClient` or a managed transfer
    /// coordinator rather than constructing them directly.
    public init(
        id: TransferID,
        events: AsyncStream<ManagedTransferEvent>,
        snapshotProvider: @escaping @Sendable () async -> ManagedTransferSnapshot?,
        cancellationAction: @escaping @Sendable () async -> Void
    ) {
        self.id = id
        self.events = events
        self.snapshotProvider = snapshotProvider
        self.cancellationAction = cancellationAction
    }

    /// Returns the latest durable snapshot, or `nil` after journal removal.
    public func snapshot() async -> ManagedTransferSnapshot? {
        await snapshotProvider()
    }

    /// Cancels the underlying transfer and emits at most one terminal cancellation event.
    public func cancel() async {
        await cancellationAction()
    }
}

/// Observable lifecycle event emitted by a managed transfer.
public enum ManagedTransferEvent: Sendable, Equatable {
    /// Durable state or metadata changed.
    case snapshot(ManagedTransferSnapshot)
    /// Byte progress changed.
    case progress(TransferProgress)
    /// Transfer completed successfully.
    case completed(ManagedTransferSnapshot)
    /// Transfer failed with a sanitized reason in its snapshot.
    case failed(ManagedTransferSnapshot)
    /// Transfer was cancelled.
    case cancelled(ManagedTransferSnapshot)
}

/// Credential-free telemetry context for managed and background transfer lifecycles.
public struct TelemetryManagedTransferContext: Sendable, Equatable {
    /// Observable managed transfer event type.
    public enum Event: String, Sendable, Equatable {
        /// A transfer identity was registered.
        case started
        /// A transfer was suspended.
        case suspended
        /// A transfer entered resumption.
        case resumed
        /// A journal snapshot was restored after relaunch.
        case restored
        /// Byte progress changed.
        case progress
        /// The transfer completed successfully.
        case completed
        /// The transfer failed.
        case failed
        /// The transfer was cancelled.
        case cancelled
        /// A byte-offset resume was attempted.
        case resumeAttempted
        /// A server accepted a byte-offset resume.
        case resumeAccepted
        /// Resume validation required a safe restart from zero.
        case resumeRestarted
        /// An Apple background URLSession task was scheduled.
        case backgroundScheduled
        /// A durable snapshot matched one live background task.
        case backgroundReconciled
        /// A durable snapshot or live task had no match.
        case backgroundOrphaned
        /// The host background-session completion handoff was invoked.
        case backgroundHandoffCompleted
    }

    /// Stable transfer identity.
    public let transferID: TransferID
    /// Upload or download kind.
    public let kind: ManagedTransferKind
    /// Lifecycle event.
    public let event: Event
    /// Completed bytes when known.
    public let completedBytes: Int64?
    /// Total bytes when known.
    public let totalBytes: Int64?
    /// Resume offset when applicable.
    public let offset: Int64?
    /// Non-secret background session identifier when applicable.
    public let sessionIdentifier: String?
    /// Background task identifier when applicable.
    public let taskIdentifier: Int?
    /// Sanitized reason code without request headers or credentials.
    public let reason: String?

    /// Creates a managed transfer telemetry context.
    public init(
        transferID: TransferID,
        kind: ManagedTransferKind,
        event: Event,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        offset: Int64? = nil,
        sessionIdentifier: String? = nil,
        taskIdentifier: Int? = nil,
        reason: String? = nil
    ) {
        self.transferID = transferID
        self.kind = kind
        self.event = event
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.offset = offset
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
        self.reason = reason
    }
}

/// Descriptor used to reconcile a live background URLSession task with durable state.
public struct BackgroundTransferTaskDescriptor: Codable, Sendable, Equatable {
    /// Stable transfer identity stored in the task description.
    public let transferID: TransferID
    /// Background session identifier.
    public let sessionIdentifier: String
    /// URLSession task identifier.
    public let taskIdentifier: Int

    /// Creates a background task descriptor.
    public init(transferID: TransferID, sessionIdentifier: String, taskIdentifier: Int) {
        self.transferID = transferID
        self.sessionIdentifier = sessionIdentifier
        self.taskIdentifier = taskIdentifier
    }
}

/// Result of reconciling durable snapshots with live background URLSession tasks.
public struct TransferReconciliationReport: Sendable, Equatable {
    /// Transfers mapped to exactly one durable snapshot and live task.
    public let reconciledTransferIDs: [TransferID]
    /// Durable transfers that have no matching live task.
    public let orphanedSnapshotIDs: [TransferID]
    /// Live tasks that have no matching durable snapshot.
    public let orphanedTasks: [BackgroundTransferTaskDescriptor]
    /// Transfer identities associated with multiple live tasks.
    public let conflictingTransferIDs: [TransferID]

    /// Creates a reconciliation report.
    public init(
        reconciledTransferIDs: [TransferID],
        orphanedSnapshotIDs: [TransferID],
        orphanedTasks: [BackgroundTransferTaskDescriptor],
        conflictingTransferIDs: [TransferID]
    ) {
        self.reconciledTransferIDs = reconciledTransferIDs
        self.orphanedSnapshotIDs = orphanedSnapshotIDs
        self.orphanedTasks = orphanedTasks
        self.conflictingTransferIDs = conflictingTransferIDs
    }
}

/// Typed failures produced by managed transfer infrastructure.
public enum ManagedTransferError: Error, Sendable, Equatable {
    /// No snapshot exists for the requested identity.
    case transferNotFound(TransferID)
    /// A transfer with this stable identity is already registered.
    case transferAlreadyExists(TransferID)
    /// A terminal transfer cannot transition again.
    case terminalStateAlreadyReached(TransferID)
    /// Requested lifecycle transition is not allowed by the transfer state machine.
    case invalidStateTransition(from: ManagedTransferState, to: ManagedTransferState)
    /// Server response cannot safely append to the partial file.
    case invalidResumeResponse
    /// Partial file and persisted checkpoint disagree.
    case invalidResumeCheckpoint
    /// Final byte count does not match the integrity policy.
    case byteCountMismatch(expected: Int64, actual: Int64)
    /// Final SHA-256 digest does not match the integrity policy.
    case checksumMismatch
    /// Persisted and live background tasks cannot be reconciled uniquely.
    case restorationConflict(TransferID)
    /// Background transfers are unavailable on the current platform.
    case backgroundTransfersUnavailable
    /// Resumable upload server does not support the required protocol.
    case resumableUploadUnsupported
    /// Server-reported upload offset is invalid for the source.
    case invalidUploadOffset
}
