import Foundation

struct ProgressHealthSnapshot: Sendable {
    var health: RunHealthState
    var phase: JobPhase
    var detail: String?
    var path: String?
}

actor ProgressTracker {
    private var snapshot: JobSnapshot
    private var activities: [UUID: WorkerActivity] = [:]
    private var hydrationStates: [String: HydrationState] = [:]
    private let store: JobStore
    private let onUpdate: @Sendable (JobUpdate) async -> Void
    private var lastPublishedAt: Date = .distantPast
    private var lastProgressAt: Date?
    private let publishInterval: TimeInterval = 0.25

    init(
        snapshot: JobSnapshot,
        store: JobStore,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) {
        self.snapshot = snapshot
        self.store = store
        self.onUpdate = onUpdate
        self.lastProgressAt = snapshot.startedAt
    }

    func recordPreflight(_ report: PreflightReport) async throws {
        snapshot.phase = .preflight
        snapshot.phaseDetail = report.canStart ? "Preflight passed" : "Preflight needs attention"
        snapshot.currentPath = nil
        snapshot.preflightReport = report
        noteProgress()
        recalculateRates()
        try await publish(force: true)
    }

    func begin(detail: String, path: String?) async throws {
        snapshot.phase = .discovering
        snapshot.phaseDetail = detail
        snapshot.currentPath = path
        noteProgress()
        try await publish(force: true)
    }

    func restoreDiscoveredItems(_ items: [ScannedItem], detail: String) async throws {
        snapshot.phase = .discovering
        snapshot.phaseDetail = detail
        snapshot.currentPath = nil
        snapshot.totalDiscovered = items.count
        snapshot.totalDownloaded = 0
        snapshot.totalCopied = 0
        snapshot.totalFailed = 0
        snapshot.plannedChunks = 0
        snapshot.processedChunks = 0
        snapshot.estimatedRemainingCount = items.count
        snapshot.totalExpectedBytes = items.expectedBytes
        snapshot.copiedBytes = 0
        snapshot.activeWorkerCount = 0
        snapshot.finishedAt = nil
        snapshot.lastError = nil
        hydrationStates = Dictionary(uniqueKeysWithValues: items.map { ($0.relativePath, $0.hydrationState) })
        snapshot.hydrationMetrics = HydrationMetrics(timeToFirstDiscoveredSeconds: 0)
        noteProgress()
        recalculateHydrationMetrics()
        recalculateRates()
        try await publish(force: true)
    }

    func scanned(_ item: ScannedItem) async throws {
        snapshot.phase = .discovering
        snapshot.phaseDetail = "Discovering source tree"
        snapshot.currentPath = item.relativePath
        snapshot.totalDiscovered += 1
        if snapshot.hydrationMetrics.timeToFirstDiscoveredSeconds == nil,
           let startedAt = snapshot.startedAt {
            snapshot.hydrationMetrics.timeToFirstDiscoveredSeconds = Date().timeIntervalSince(startedAt)
        }
        if item.kind == .file {
            snapshot.totalExpectedBytes += item.expectedSize
        }
        hydrationStates[item.relativePath] = item.hydrationState
        recalculateHydrationMetrics()
        snapshot.estimatedRemainingCount = 0
        noteProgress()
        recalculateRates()
        try await publish(force: false)
    }

    func planned(chunkCount: Int) async throws {
        snapshot.phase = .planningChunks
        snapshot.phaseDetail = "Planned \(snapshot.plannedChunks + chunkCount) chunks"
        snapshot.currentPath = nil
        snapshot.plannedChunks += chunkCount
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        noteProgress()
        recalculateRates()
        try await publish(force: true)
    }

    func updateTopLevelPhase(_ phase: JobPhase, detail: String, path: String? = nil, force: Bool = true) async throws {
        snapshot.phase = phase
        snapshot.phaseDetail = detail
        snapshot.currentPath = path
        noteProgress()
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
        snapshot.phase = jobPhase(for: phase)
        snapshot.currentPath = path ?? snapshot.currentPath
        snapshot.phaseDetail = detail
        snapshot.activeWorkerCount = activities.count
        noteProgress()
        recalculateRates()
        try await publish(force: false)
    }

    func clearWorker(id: UUID) async throws {
        activities.removeValue(forKey: id)
        snapshot.activeWorkerCount = activities.count
        recalculateRates()
        try await publish(force: false)
    }

    func markHydrationEvent(item: ScannedItem, downloaded: Bool = false) async throws {
        snapshot.currentPath = item.relativePath
        if downloaded {
            snapshot.totalDownloaded += 1
        }
        hydrationStates[item.relativePath] = item.hydrationState
        if item.hydrationState == .ready,
           snapshot.hydrationMetrics.timeToFirstReadySeconds == nil,
           let startedAt = snapshot.startedAt {
            snapshot.hydrationMetrics.timeToFirstReadySeconds = Date().timeIntervalSince(startedAt)
        }
        if (.queued == item.hydrationState || .downloading == item.hydrationState),
           snapshot.hydrationMetrics.timeToFirstHydrationRequestSeconds == nil,
           let startedAt = snapshot.startedAt {
            snapshot.hydrationMetrics.timeToFirstHydrationRequestSeconds = Date().timeIntervalSince(startedAt)
        }
        if item.hydrationState == .requestFailed {
            snapshot.lastError = item.hydrationError ?? snapshot.lastError
        }
        recalculateHydrationMetrics()
        noteProgress()
        recalculateRates()
        try await publish(force: false)
    }

    func markCopied(item: ScannedItem) async throws {
        snapshot.currentPath = item.relativePath
        snapshot.totalCopied += 1
        if snapshot.hydrationMetrics.timeToFirstCopiedSeconds == nil,
           let startedAt = snapshot.startedAt {
            snapshot.hydrationMetrics.timeToFirstCopiedSeconds = Date().timeIntervalSince(startedAt)
        }
        if item.kind == .file {
            snapshot.copiedBytes += item.expectedSize
        }
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        noteProgress()
        recalculateRates()
        try await publish(force: false)
    }

    func rollbackCopied(itemCount: Int, bytes: Int64) async throws {
        snapshot.totalCopied = max(0, snapshot.totalCopied - itemCount)
        snapshot.copiedBytes = max(0, snapshot.copiedBytes - bytes)
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        noteProgress()
        recalculateRates()
        try await publish(force: true)
    }

    func markChunkFinished() async throws {
        snapshot.processedChunks += 1
        if snapshot.hydrationMetrics.timeToFirstVerifiedChunkSeconds == nil,
           let startedAt = snapshot.startedAt {
            snapshot.hydrationMetrics.timeToFirstVerifiedChunkSeconds = Date().timeIntervalSince(startedAt)
        }
        noteProgress()
        recalculateRates()
        try await publish(force: true)
    }

    func markFailure(_ failure: FailureRecord) async throws {
        snapshot.currentPath = failure.relativePath
        snapshot.lastError = failure.message
        snapshot.totalFailed += 1
        snapshot.estimatedRemainingCount = max(0, snapshot.totalDiscovered - snapshot.totalCopied - snapshot.totalFailed)
        noteProgress()
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
        noteProgress()
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
        noteProgress()
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
        noteProgress()
        recalculateRates()
        try await publish(force: true)
    }

    func runHealthSnapshot(now: Date) -> ProgressHealthSnapshot? {
        guard let health = RunHealthState.evaluate(
            isRunning: isActivelyRunning,
            lastProgressAt: lastProgressAt,
            now: now
        ) else {
            return nil
        }

        return ProgressHealthSnapshot(
            health: health,
            phase: snapshot.phase,
            detail: snapshot.phaseDetail,
            path: snapshot.currentPath
        )
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

        if snapshot.phase == .preflight || snapshot.phase == .discovering || snapshot.phase == .planningChunks {
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

    private func recalculateHydrationMetrics() {
        snapshot.hydrationMetrics.requestAttemptCount = hydrationStates.values.filter {
            $0 == .queued || $0 == .downloading || $0 == .stalled || $0 == .ready || $0 == .requestFailed
        }.count
        snapshot.hydrationMetrics.requestFailureCount = hydrationStates.values.filter { $0 == .requestFailed }.count
        snapshot.hydrationMetrics.queuedCount = hydrationStates.values.filter { $0 == .queued }.count
        snapshot.hydrationMetrics.downloadingCount = hydrationStates.values.filter { $0 == .downloading }.count
        snapshot.hydrationMetrics.stalledCount = hydrationStates.values.filter { $0 == .stalled }.count
        snapshot.hydrationMetrics.readyCount = hydrationStates.values.filter { $0 == .ready }.count
    }

    private func jobPhase(for livePhase: LiveActivityPhase) -> JobPhase {
        switch livePhase {
        case .preflight:
            return .preflight
        case .discovering, .scanning:
            return .discovering
        case .planning:
            return .planningChunks
        case .hydrating, .materializing:
            return .hydrating
        case .copying:
            return .copying
        case .verifying:
            return .verifyingChunks
        case .promoting:
            return .promoting
        case .zipping:
            return .zipping
        case .idle:
            return snapshot.phase
        }
    }

    private var isActivelyRunning: Bool {
        switch snapshot.phase {
        case .idle, .completed, .completedWithWarnings, .failed, .cancelled:
            return false
        default:
            return snapshot.finishedAt == nil
        }
    }

    private func noteProgress(at date: Date = Date()) {
        lastProgressAt = date
    }
}
