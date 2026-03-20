import Foundation

actor ProgressTracker {
    private var snapshot: JobSnapshot
    private var activities: [UUID: WorkerActivity] = [:]
    private let store: JobStore
    private let onUpdate: @Sendable (JobUpdate) async -> Void
    private var lastPublishedAt: Date = .distantPast
    private let publishInterval: TimeInterval = 0.25

    init(
        snapshot: JobSnapshot,
        store: JobStore,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) {
        self.snapshot = snapshot
        self.store = store
        self.onUpdate = onUpdate
    }

    func begin(detail: String, path: String?) async throws {
        snapshot.phase = .scanning
        snapshot.phaseDetail = detail
        snapshot.currentPath = path
        try await publish(force: true)
    }

    func scanned(_ item: ScannedItem) async throws {
        snapshot.phase = .scanning
        snapshot.phaseDetail = "Scanning source tree"
        snapshot.currentPath = item.relativePath
        snapshot.totalDiscovered += 1
        if item.kind == .file {
            snapshot.totalExpectedBytes += item.expectedSize
        }
        snapshot.estimatedRemainingCount = 0
        recalculateRates()
        try await publish(force: false)
    }

    func planned(chunkCount: Int) async throws {
        snapshot.phase = .planningChunks
        snapshot.phaseDetail = "Planned \(chunkCount) chunks"
        snapshot.currentPath = nil
        snapshot.plannedChunks = chunkCount
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        recalculateRates()
        try await publish(force: true)
    }

    func updateTopLevelPhase(_ phase: JobPhase, detail: String, path: String? = nil, force: Bool = true) async throws {
        snapshot.phase = phase
        snapshot.phaseDetail = detail
        snapshot.currentPath = path
        recalculateRates()
        try await publish(force: force)
    }

    func updateWorker(
        id: UUID,
        label: String,
        phase: LiveActivityPhase,
        detail: String,
        path: String?
    ) async throws {
        activities[id] = WorkerActivity(
            id: id,
            label: label,
            phase: phase,
            detail: detail,
            path: path,
            updatedAt: Date()
        )
        snapshot.currentPath = path ?? snapshot.currentPath
        snapshot.phaseDetail = detail
        snapshot.activeWorkerCount = activities.count
        recalculateRates()
        try await publish(force: false)
    }

    func clearWorker(id: UUID) async throws {
        activities.removeValue(forKey: id)
        snapshot.activeWorkerCount = activities.count
        recalculateRates()
        try await publish(force: false)
    }

    func markDownloadReady(item: ScannedItem, downloaded: Bool) async throws {
        snapshot.currentPath = item.relativePath
        if downloaded {
            snapshot.totalDownloaded += 1
        }
        recalculateRates()
        try await publish(force: false)
    }

    func markCopied(item: ScannedItem) async throws {
        snapshot.currentPath = item.relativePath
        snapshot.totalCopied += 1
        if item.kind == .file {
            snapshot.copiedBytes += item.expectedSize
        }
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        recalculateRates()
        try await publish(force: false)
    }

    func rollbackCopied(itemCount: Int, bytes: Int64) async throws {
        snapshot.totalCopied = max(0, snapshot.totalCopied - itemCount)
        snapshot.copiedBytes = max(0, snapshot.copiedBytes - bytes)
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        recalculateRates()
        try await publish(force: true)
    }

    func markChunkFinished() async throws {
        snapshot.processedChunks += 1
        recalculateRates()
        try await publish(force: true)
    }

    func markFailure(_ failure: FailureRecord) async throws {
        snapshot.currentPath = failure.relativePath
        snapshot.lastError = failure.message
        snapshot.totalFailed += 1
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        recalculateRates()
        try await publish(force: true)
    }

    func complete(phase: JobPhase, lastError: String? = nil) async throws {
        activities.removeAll()
        snapshot.phase = phase
        snapshot.phaseDetail = phase == .completed ? "Completed" : "Completed with warnings"
        snapshot.activeWorkerCount = 0
        snapshot.currentPath = nil
        snapshot.finishedAt = Date()
        snapshot.lastError = lastError
        snapshot.estimatedRemainingCount = 0
        snapshot.estimatedRemainingSeconds = 0
        recalculateRates()
        try await publish(force: true)
    }

    func cancel(message: String) async throws {
        activities.removeAll()
        snapshot.phase = .cancelled
        snapshot.phaseDetail = "Cancelled"
        snapshot.activeWorkerCount = 0
        snapshot.finishedAt = Date()
        snapshot.lastError = message
        recalculateRates()
        try await publish(force: true)
    }

    func fail(message: String) async throws {
        activities.removeAll()
        snapshot.phase = .failed
        snapshot.phaseDetail = "Failed"
        snapshot.activeWorkerCount = 0
        snapshot.finishedAt = Date()
        snapshot.lastError = message
        recalculateRates()
        try await publish(force: true)
    }

    private func publish(force: Bool) async throws {
        if !force, Date().timeIntervalSince(lastPublishedAt) < publishInterval {
            return
        }
        lastPublishedAt = Date()
        try await store.saveJobSnapshot(snapshot)
        await onUpdate(.snapshot(snapshot))
        await onUpdate(.activities(activities.values.sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.label < rhs.label
            }
            return lhs.updatedAt > rhs.updatedAt
        }))
    }

    private func recalculateRates() {
        guard let startedAt = snapshot.startedAt else {
            snapshot.throughputItemsPerSecond = 0
            snapshot.throughputBytesPerSecond = 0
            snapshot.estimatedRemainingSeconds = nil
            return
        }

        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
        snapshot.throughputItemsPerSecond = Double(snapshot.totalCopied) / elapsed
        snapshot.throughputBytesPerSecond = Double(snapshot.copiedBytes) / elapsed

        if snapshot.phase == .scanning || snapshot.phase == .planningChunks {
            snapshot.estimatedRemainingSeconds = nil
            return
        }

        let remainingItems = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        guard remainingItems > 0, snapshot.throughputItemsPerSecond > 0 else {
            snapshot.estimatedRemainingSeconds = snapshot.phase == .completed ? 0 : nil
            return
        }
        snapshot.estimatedRemainingSeconds = Double(remainingItems) / snapshot.throughputItemsPerSecond
    }
}
