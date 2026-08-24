import NovaNetworkCore
import Foundation

/// Actor-isolated owner of managed transfer snapshots, event subscriptions, and restoration.
public actor ManagedTransferCoordinator {
    private typealias EventContinuation = AsyncStream<ManagedTransferEvent>.Continuation

    private let journal: (any TransferJournal)?
    private let telemetry: NetworkTelemetryHooks.OnManagedTransferEvent?
    private var snapshotsByID: [TransferID: ManagedTransferSnapshot] = [:]
    private var subscribers: [TransferID: [UUID: EventContinuation]] = [:]
    private var cancellationActions: [TransferID: @Sendable () -> Void] = [:]

    /// Creates a coordinator with optional durable persistence.
    public init(
        journal: (any TransferJournal)? = nil,
        telemetry: NetworkTelemetryHooks.OnManagedTransferEvent? = nil
    ) {
        self.journal = journal
        self.telemetry = telemetry
    }

    /// Registers and persists a new transfer snapshot.
    ///
    /// - Throws: ``ManagedTransferError/transferAlreadyExists(_:)`` when the identity is already
    ///   registered, or a journal persistence error.
    public func register(_ snapshot: ManagedTransferSnapshot) async throws {
        if snapshotsByID[snapshot.id] != nil {
            throw ManagedTransferError.transferAlreadyExists(snapshot.id)
        }
        try await journal?.upsert(snapshot)
        snapshotsByID[snapshot.id] = snapshot
        emit(.snapshot(snapshot), for: snapshot.id)
        emitTelemetry(for: snapshot, event: .started)
    }

    /// Returns a control handle and a bounded event subscription for a registered transfer.
    public func handle(for id: TransferID) throws -> ManagedTransferHandle {
        guard let snapshot = snapshotsByID[id] else {
            throw ManagedTransferError.transferNotFound(id)
        }

        let subscriberID = UUID()
        let terminationPolicy = snapshot.options.consumerTerminationPolicy
        let stream = AsyncStream<ManagedTransferEvent>(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuation.yield(Self.event(for: snapshot))
            if snapshot.state.isTerminal {
                continuation.finish()
                return
            }
            subscribers[id, default: [:]][subscriberID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeSubscriber(subscriberID, transferID: id)
                    if terminationPolicy == .cancelTransfer {
                        await self?.cancel(id: id)
                    }
                }
            }
        }

        return ManagedTransferHandle(
            id: id,
            events: stream,
            snapshotProvider: { [weak self] in await self?.snapshot(id: id) },
            cancellationAction: { [weak self] in await self?.cancel(id: id) }
        )
    }

    /// Returns the latest snapshot for one transfer.
    public func snapshot(id: TransferID) -> ManagedTransferSnapshot? {
        snapshotsByID[id]
    }

    /// Returns every snapshot ordered by creation time and identity.
    public func snapshots() -> [ManagedTransferSnapshot] {
        snapshotsByID.values.sorted(by: Self.sortSnapshots)
    }

    /// Associates cancellation of the underlying URLSession or producer task with a transfer.
    public func attachCancellationAction(
        id: TransferID,
        action: @escaping @Sendable () -> Void
    ) throws {
        guard snapshotsByID[id] != nil else {
            throw ManagedTransferError.transferNotFound(id)
        }
        cancellationActions[id] = action
    }

    /// Applies one validated lifecycle transition and emits at most one terminal event.
    public func transition(
        id: TransferID,
        to state: ManagedTransferState,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        reason: String? = nil,
        now: Date = Date()
    ) async throws {
        guard let current = snapshotsByID[id] else {
            throw ManagedTransferError.transferNotFound(id)
        }
        guard !current.state.isTerminal else {
            throw ManagedTransferError.terminalStateAlreadyReached(id)
        }
        guard Self.canTransition(from: current.state, to: state) else {
            throw ManagedTransferError.invalidStateTransition(from: current.state, to: state)
        }

        let updated = current.replacing(
            state: state,
            updatedAt: now,
            completedBytes: completedBytes ?? current.completedBytes,
            totalBytes: totalBytes ?? current.totalBytes,
            lastErrorReason: reason ?? current.lastErrorReason
        )
        try await journal?.upsert(updated)
        snapshotsByID[id] = updated
        emit(Self.event(for: updated), for: id)
        let telemetryEvent: TelemetryManagedTransferContext.Event?
        switch state {
        case .suspended:
            telemetryEvent = .suspended
        case .resuming:
            telemetryEvent = .resumed
        case .completed:
            telemetryEvent = .completed
        case .failed:
            telemetryEvent = .failed
        case .cancelled:
            telemetryEvent = .cancelled
        default:
            telemetryEvent = nil
        }
        if let telemetryEvent {
            emitTelemetry(for: updated, event: telemetryEvent, reason: reason)
        }

        if state.isTerminal {
            cancellationActions[id] = nil
            finishSubscribers(for: id)
        }
    }

    /// Updates durable byte progress without changing lifecycle state.
    public func updateProgress(
        id: TransferID,
        completedBytes: Int64,
        totalBytes: Int64?,
        now: Date = Date()
    ) async throws {
        guard let current = snapshotsByID[id] else {
            throw ManagedTransferError.transferNotFound(id)
        }
        guard !current.state.isTerminal else {
            throw ManagedTransferError.terminalStateAlreadyReached(id)
        }
        let updated = current.replacing(
            updatedAt: now,
            completedBytes: completedBytes,
            totalBytes: totalBytes ?? current.totalBytes
        )
        try await journal?.upsert(updated)
        snapshotsByID[id] = updated
        emit(.progress(.init(completedBytes: completedBytes, totalBytes: totalBytes)), for: id)
        emitTelemetry(for: updated, event: .progress)
    }

    /// Persists a resumable download checkpoint.
    public func updateDownloadCheckpoint(
        id: TransferID,
        partialFileURL: URL,
        completedBytes: Int64,
        totalBytes: Int64?,
        validator: TransferResourceValidator?,
        now: Date = Date()
    ) async throws {
        guard let current = snapshotsByID[id] else {
            throw ManagedTransferError.transferNotFound(id)
        }
        guard current.kind == .download else {
            throw ManagedTransferError.invalidResumeCheckpoint
        }
        let updated = current.replacing(
            updatedAt: now,
            completedBytes: completedBytes,
            totalBytes: totalBytes ?? current.totalBytes,
            partialFileURL: partialFileURL,
            validator: validator
        )
        try await journal?.upsert(updated)
        snapshotsByID[id] = updated
        emit(.snapshot(updated), for: id)
    }

    /// Persists a resumable upload resource and server-confirmed offset.
    public func updateUploadCheckpoint(
        id: TransferID,
        uploadURL: URL,
        uploadOffset: Int64,
        totalBytes: Int64?,
        now: Date = Date()
    ) async throws {
        guard let current = snapshotsByID[id] else {
            throw ManagedTransferError.transferNotFound(id)
        }
        guard current.kind == .upload else {
            throw ManagedTransferError.invalidResumeCheckpoint
        }
        let updated = current.replacing(
            updatedAt: now,
            completedBytes: uploadOffset,
            totalBytes: totalBytes ?? current.totalBytes,
            uploadURL: uploadURL,
            uploadOffset: uploadOffset
        )
        try await journal?.upsert(updated)
        snapshotsByID[id] = updated
        emit(.snapshot(updated), for: id)
    }

    /// Associates a live background URLSession task with a durable transfer.
    public func attachBackgroundTask(_ descriptor: BackgroundTransferTaskDescriptor) async throws {
        guard let current = snapshotsByID[descriptor.transferID] else {
            throw ManagedTransferError.transferNotFound(descriptor.transferID)
        }
        let updated = current.replacing(
            updatedAt: Date(),
            sessionIdentifier: descriptor.sessionIdentifier,
            taskIdentifier: descriptor.taskIdentifier
        )
        try await journal?.upsert(updated)
        snapshotsByID[descriptor.transferID] = updated
        emit(.snapshot(updated), for: descriptor.transferID)
    }

    /// Cancels a transfer and emits one terminal cancellation event.
    public func cancel(id: TransferID) async {
        guard let snapshot = snapshotsByID[id], !snapshot.state.isTerminal else { return }
        cancellationActions[id]?()
        try? await transition(id: id, to: .cancelled, reason: "cancelled")
    }

    /// Removes a terminal snapshot from memory and durable storage.
    @discardableResult
    public func remove(id: TransferID) async throws -> Bool {
        guard let snapshot = snapshotsByID[id], snapshot.state.isTerminal else { return false }
        try await journal?.remove(id: id)
        snapshotsByID[id] = nil
        return true
    }

    /// Restores durable records and marks non-terminal operations as restoring.
    public func restore() async throws -> TransferJournalLoadResult {
        guard let journal else {
            return .init(
                snapshots: snapshots(),
                recoveryReport: .init(
                    scannedRecords: 0,
                    recoveredRecords: snapshotsByID.count,
                    skippedCorruptedRecords: 0,
                    skippedIncompatibleRecords: 0,
                    orphanedTemporaryRecords: 0
                )
            )
        }

        let loaded = try await journal.load()
        var restored: [ManagedTransferSnapshot] = []
        for snapshot in loaded.snapshots {
            let updated: ManagedTransferSnapshot
            if snapshot.state.isTerminal {
                updated = snapshot
            } else {
                updated = snapshot.replacing(state: .restoring, updatedAt: Date())
                try await journal.upsert(updated)
            }
            snapshotsByID[updated.id] = updated
            restored.append(updated)
            emitTelemetry(for: updated, event: .restored)
        }
        restored.sort(by: Self.sortSnapshots)
        return .init(snapshots: restored, recoveryReport: loaded.recoveryReport)
    }

    /// Reconciles durable background snapshots with live URLSession task descriptors.
    public func reconcile(
        liveTasks: [BackgroundTransferTaskDescriptor]
    ) async throws -> TransferReconciliationReport {
        let grouped = Dictionary(grouping: liveTasks, by: \.transferID)
        let backgroundSnapshots = snapshotsByID.values.filter { snapshot in
            guard !snapshot.state.isTerminal else { return false }
            if case .background = snapshot.options.execution { return true }
            return false
        }

        var reconciled: [TransferID] = []
        var orphanedSnapshots: [TransferID] = []
        var conflicts: [TransferID] = []

        for snapshot in backgroundSnapshots {
            let matches = grouped[snapshot.id] ?? []
            switch matches.count {
            case 0:
                orphanedSnapshots.append(snapshot.id)
            case 1:
                try await attachBackgroundTask(matches[0])
                if snapshot.state == .restoring {
                    try await transition(id: snapshot.id, to: .transferring)
                }
                reconciled.append(snapshot.id)
            default:
                conflicts.append(snapshot.id)
            }
        }

        let knownIDs = Set(backgroundSnapshots.map(\.id))
        let orphanedTasks = liveTasks.filter { !knownIDs.contains($0.transferID) }

        for id in reconciled {
            if let snapshot = snapshotsByID[id] {
                emitTelemetry(for: snapshot, event: .backgroundReconciled)
            }
        }
        for id in orphanedSnapshots + conflicts {
            if let snapshot = snapshotsByID[id] {
                emitTelemetry(for: snapshot, event: .backgroundOrphaned, reason: "snapshot_or_conflict")
            }
        }

        return TransferReconciliationReport(
            reconciledTransferIDs: reconciled.sorted { $0.rawValue < $1.rawValue },
            orphanedSnapshotIDs: orphanedSnapshots.sorted { $0.rawValue < $1.rawValue },
            orphanedTasks: orphanedTasks.sorted {
                if $0.transferID == $1.transferID {
                    return $0.taskIdentifier < $1.taskIdentifier
                }
                return $0.transferID.rawValue < $1.transferID.rawValue
            },
            conflictingTransferIDs: conflicts.sorted { $0.rawValue < $1.rawValue }
        )
    }

    private func emit(_ event: ManagedTransferEvent, for id: TransferID) {
        for continuation in subscribers[id]?.values ?? [:].values {
            continuation.yield(event)
        }
    }

    private func finishSubscribers(for id: TransferID) {
        let current = subscribers.removeValue(forKey: id) ?? [:]
        for continuation in current.values {
            continuation.finish()
        }
    }

    private func removeSubscriber(_ subscriberID: UUID, transferID: TransferID) {
        subscribers[transferID]?[subscriberID] = nil
        if subscribers[transferID]?.isEmpty == true {
            subscribers[transferID] = nil
        }
    }

    /// Emits an explicit credential-free telemetry event for protocol-specific activity.
    public func recordTelemetry(
        id: TransferID,
        event: TelemetryManagedTransferContext.Event,
        offset: Int64? = nil,
        reason: String? = nil
    ) {
        guard let snapshot = snapshotsByID[id] else { return }
        emitTelemetry(for: snapshot, event: event, offset: offset, reason: reason)
    }

    private func emitTelemetry(
        for snapshot: ManagedTransferSnapshot,
        event: TelemetryManagedTransferContext.Event,
        offset: Int64? = nil,
        reason: String? = nil
    ) {
        telemetry?(
            TelemetryManagedTransferContext(
                transferID: snapshot.id,
                kind: snapshot.kind,
                event: event,
                completedBytes: snapshot.completedBytes,
                totalBytes: snapshot.totalBytes,
                offset: offset,
                sessionIdentifier: snapshot.sessionIdentifier,
                taskIdentifier: snapshot.taskIdentifier,
                reason: reason
            )
        )
    }

    private static func event(for snapshot: ManagedTransferSnapshot) -> ManagedTransferEvent {
        switch snapshot.state {
        case .completed:
            return .completed(snapshot)
        case .failed:
            return .failed(snapshot)
        case .cancelled:
            return .cancelled(snapshot)
        default:
            return .snapshot(snapshot)
        }
    }

    private static func sortSnapshots(_ lhs: ManagedTransferSnapshot, _ rhs: ManagedTransferSnapshot) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.rawValue < rhs.id.rawValue
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func canTransition(from: ManagedTransferState, to: ManagedTransferState) -> Bool {
        if to == .failed || to == .cancelled { return true }
        switch (from, to) {
        case (.queued, .preparing),
             (.queued, .restoring),
             (.preparing, .transferring),
             (.preparing, .resuming),
             (.preparing, .suspended),
             (.preparing, .finalizing),
             (.transferring, .suspended),
             (.transferring, .finalizing),
             (.suspended, .resuming),
             (.suspended, .restoring),
             (.resuming, .transferring),
             (.resuming, .preparing),
             (.restoring, .preparing),
             (.restoring, .transferring),
             (.restoring, .suspended),
             (.restoring, .finalizing),
             (.finalizing, .completed):
            return true
        default:
            return false
        }
    }
}

private extension ManagedTransferSnapshot {
    func replacing(
        state: ManagedTransferState? = nil,
        updatedAt: Date? = nil,
        completedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        partialFileURL: URL? = nil,
        validator: TransferResourceValidator? = nil,
        uploadURL: URL? = nil,
        uploadOffset: Int64? = nil,
        sessionIdentifier: String? = nil,
        taskIdentifier: Int? = nil,
        lastErrorReason: String? = nil
    ) -> ManagedTransferSnapshot {
        ManagedTransferSnapshot(
            id: id,
            kind: kind,
            state: state ?? self.state,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            completedBytes: completedBytes ?? self.completedBytes,
            totalBytes: totalBytes ?? self.totalBytes,
            requestURL: requestURL,
            method: method,
            options: options,
            destinationURL: destinationURL,
            destinationPolicy: destinationPolicy,
            partialFileURL: partialFileURL ?? self.partialFileURL,
            validator: validator ?? self.validator,
            uploadURL: uploadURL ?? self.uploadURL,
            uploadOffset: uploadOffset ?? self.uploadOffset,
            sessionIdentifier: sessionIdentifier ?? self.sessionIdentifier,
            taskIdentifier: taskIdentifier ?? self.taskIdentifier,
            lastErrorReason: lastErrorReason ?? self.lastErrorReason
        )
    }
}
