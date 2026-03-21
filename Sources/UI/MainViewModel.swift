import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class MainViewModel {
    private static let maxLogEntries = 250
    private static let maxVisibleBatchProjects = 40
    private static let batchProjectLeadCount = 6
    private static let batchProjectContextRadius = 6
    private static let batchProjectTailCount = 6

    var sourceURL: URL?
    var destinationURL: URL?
    var runMode: RunMode = .singleProject
    var batchOrderingMode: BatchOrderingMode = .newestFirst {
        didSet {
            guard batchOrderingMode != oldValue else { return }
            rebuildBatchPreview()
        }
    }
    var rescueProfile: RescueProfile = .conservative {
        didSet {
            guard rescueProfile != oldValue else { return }
            applyRescueProfileDefaults(rescueProfile)
            refreshPreflight()
            rebuildBatchPreview()
        }
    }
    var transferMode: TransferMode = .exactCopy
    var priorityMode: TransferPriorityMode = .criticalFirst
    var batchNamingMode: BatchNamingMode = .suffix
    var batchSuffix: String = "Lokal"
    var customExcludedDirectoryNamesText: String = ""
    var customExcludedFileExtensionsText: String = ""
    var snapshot: JobSnapshot = .idle(source: nil, destination: nil)
    var batchSnapshot: BatchSnapshot = .idle(sourceRoot: nil, destinationRoot: nil, suffix: "Suffix: -Lokal")
    var batchProjects: [BatchProjectPlan] = []
    var preflightReport: PreflightReport = .empty
    var confirmedPreflightCheckIDs: Set<String> = []
    var activities: [WorkerActivity] = []
    var logs: [LogEntry] = []
    var failures: [FailureRecord] = []
    var pendingConflict: PromotionConflictState?
    var workerCount: Int = RescueProfile.conservative.defaultWorkerCount
    var hydrationWindow: Int = RescueProfile.conservative.defaultHydrationWindow
    var retryCount: Int = RescueProfile.conservative.defaultRetryCount
    var isPaused = false
    private(set) var lastProgressAt: Date?

    private let coordinator = MaterializerCoordinator()
    private let batchCoordinator = BatchCoordinator()
    private let preflightEngine = PreflightEngine()
    private var pauseController: PauseController?
    private var jobTask: Task<Void, Never>?

    var isRunning: Bool {
        if batchSnapshot.state == .running {
            return true
        }
        switch snapshot.phase {
        case .idle, .completed, .completedWithWarnings, .failed, .cancelled:
            return false
        default:
            return true
        }
    }

    var canStart: Bool {
        sourceURL != nil && destinationURL != nil && !isRunning && preflightReport.canStart
    }

    var errorText: String? {
        batchSnapshot.lastError ?? snapshot.lastError
    }

    var sessionLogPath: String {
        AppSessionLog.shared.sessionLogURL.path
    }

    var latestLogPath: String {
        AppSessionLog.shared.latestLogURL.path
    }

    var visibleBatchProjects: [BatchProjectPlan] {
        guard batchProjects.count > Self.maxVisibleBatchProjects else {
            return batchProjects
        }

        let currentIndex = max((batchSnapshot.currentProjectIndex ?? 1) - 1, 0)
        let lead = Array(batchProjects.prefix(Self.batchProjectLeadCount))
        let contextStart = max(0, currentIndex - Self.batchProjectContextRadius)
        let contextEnd = min(batchProjects.count, currentIndex + Self.batchProjectContextRadius + 1)
        let context = Array(batchProjects[contextStart..<contextEnd])
        let tail = Array(batchProjects.suffix(Self.batchProjectTailCount))

        var visible: [BatchProjectPlan] = []
        var seen: Set<UUID> = []
        for project in lead + context + tail where seen.insert(project.id).inserted {
            visible.append(project)
        }
        return visible
    }

    var hiddenBatchProjectCount: Int {
        max(0, batchProjects.count - visibleBatchProjects.count)
    }

    func runHealthState(now: Date) -> RunHealthState? {
        RunHealthState.evaluate(isRunning: isRunning, lastProgressAt: lastProgressAt, now: now)
    }

    var transferPolicy: TransferPolicy {
        TransferPolicy(
            mode: transferMode,
            customExcludedDirectoryNames: [customExcludedDirectoryNamesText],
            customExcludedFileExtensions: [customExcludedFileExtensionsText]
        )
    }

    var priorityPolicy: TransferPriorityPolicy {
        TransferPriorityPolicy(mode: priorityMode)
    }

    var workerRange: ClosedRange<Int> {
        rescueProfile.workerRange
    }

    var hydrationRange: ClosedRange<Int> {
        rescueProfile.hydrationRange
    }

    var currentHydrationPrefetchWindow: Int {
        rescueProfile.hydrationPrefetchWindow
    }

    var currentProjectPrefetchWindow: Int {
        rescueProfile.projectPrefetchWindow
    }

    var rescueProfileSummary: String {
        let batchPrefetch = currentProjectPrefetchWindow == 0
            ? "batch prewarm off"
            : "batch prewarm \(currentProjectPrefetchWindow) project(s) ahead"
        let hydrationLookahead = currentHydrationPrefetchWindow == 0
            ? "hydration lookahead off"
            : "hydration lookahead \(currentHydrationPrefetchWindow)"
        let directoryWarmup = rescueProfile == .aggressive ? "deep directory warmup on" : "directory warmup modest"
        return "\(clampedWorkerCount) workers, hydration window \(clampedHydrationWindow), \(batchPrefetch), \(hydrationLookahead), \(directoryWarmup)."
    }

    var rescueProfileDetail: String {
        rescueProfile.subtitle
    }

    var batchOrderingDetail: String {
        batchOrderingMode.subtitle
    }

    var batchNamingFieldPrompt: String {
        switch batchNamingMode {
        case .suffix:
            return "Suffix, e.g. Lokal or -Lokal"
        case .prefix:
            return "Prefix, e.g. Lokal or Lokal-"
        case .template:
            return "Template with {name}, e.g. {name}-Lokal"
        }
    }

    var batchNamingPreviewText: String {
        let configuration = BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: URL(fileURLWithPath: "/tmp/source-root", isDirectory: true),
            destinationRootURL: URL(fileURLWithPath: "/tmp/destination-root", isDirectory: true),
            namingMode: batchNamingMode,
            orderingMode: batchOrderingMode,
            suffix: batchSuffix,
            rescueProfile: rescueProfile,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: rescueProfile.defaultWorkerCount,
            hydrationWindow: rescueProfile.defaultHydrationWindow,
            retryCount: rescueProfile.defaultRetryCount,
            backoffSchedule: rescueProfile.backoffSchedule,
            maxHydrationWait: .seconds(1),
            hydrationPrefetchWindow: rescueProfile.hydrationPrefetchWindow,
            hydrationHotSlotDuration: rescueProfile.hydrationHotSlotDuration,
            enableFinderFallback: false
        )
        let sample = configuration.targetFolderName(for: "ExampleProject")
        return "Each direct subfolder becomes its own project run. Targets will be created under the destination root as `\(sample)`."
    }

    var batchNamingSummary: String {
        let configuration = BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: URL(fileURLWithPath: "/tmp/source-root", isDirectory: true),
            destinationRootURL: URL(fileURLWithPath: "/tmp/destination-root", isDirectory: true),
            namingMode: batchNamingMode,
            orderingMode: batchOrderingMode,
            suffix: batchSuffix,
            rescueProfile: rescueProfile,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: rescueProfile.defaultWorkerCount,
            hydrationWindow: rescueProfile.defaultHydrationWindow,
            retryCount: rescueProfile.defaultRetryCount,
            backoffSchedule: rescueProfile.backoffSchedule,
            maxHydrationWait: .seconds(1),
            hydrationPrefetchWindow: rescueProfile.hydrationPrefetchWindow,
            hydrationHotSlotDuration: rescueProfile.hydrationHotSlotDuration,
            enableFinderFallback: false
        )
        return configuration.namingSummary
    }

    func chooseSourceFolder() {
        sourceURL = FolderAccessManager.selectFolder(
            title: runMode == .singleProject ? "Choose iCloud Source Folder" : "Choose Batch Source Root",
            message: runMode == .singleProject
                ? "Select the iCloud Drive project folder to materialize."
                : "Select the root folder whose direct subfolders should each run as their own project."
        )
        refreshIdleSnapshot()
    }

    func chooseDestinationFolder() {
        destinationURL = FolderAccessManager.selectFolder(
            title: runMode == .singleProject ? "Choose Local Destination Folder" : "Choose Batch Destination Root",
            message: runMode == .singleProject
                ? "Select a local destination outside iCloud Drive."
                : "Select the local root where the suffixed batch project copies should be created."
        )
        refreshIdleSnapshot()
    }

    func start() {
        guard let sourceURL, let destinationURL else {
            snapshot.lastError = PipelineError.missingFolderSelection.localizedDescription
            AppSessionLog.shared.append(
                level: .error,
                category: "ui",
                message: "Start blocked because source or destination is missing"
            )
            return
        }
        refreshPreflight()
        guard preflightReport.canStart else {
            snapshot.lastError = preflightReport.blockingSummary ?? "Resolve the required preflight checks before starting."
            AppSessionLog.shared.append(
                level: .warning,
                category: "ui",
                message: "Start blocked by preflight: \(snapshot.lastError ?? "unknown preflight issue")"
            )
            return
        }

        switch runMode {
        case .singleProject:
            let existingTarget = destinationURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: existingTarget.path) {
                pendingConflict = PromotionConflictState(existingTarget: existingTarget)
                AppSessionLog.shared.append(
                    level: .warning,
                    category: "ui",
                    message: "Start paused because destination already exists",
                    path: existingTarget.path
                )
                return
            }
            startSingleRun(sourceURL: sourceURL, destinationURL: destinationURL, allowTargetQuarantine: false)
        case .batchQueue:
            startBatchRun(sourceURL: sourceURL, destinationURL: destinationURL)
        }
    }

    func startAfterQuarantineApproval() {
        pendingConflict = nil
        guard let sourceURL, let destinationURL else { return }
        AppSessionLog.shared.append(
            level: .warning,
            category: "ui",
            message: "User approved quarantine of existing destination before retry"
        )
        startSingleRun(sourceURL: sourceURL, destinationURL: destinationURL, allowTargetQuarantine: true)
    }

    func pauseOrResume() {
        guard let pauseController, isRunning else { return }
        Task {
            if isPaused {
                await pauseController.resume()
                isPaused = false
                AppSessionLog.shared.append(level: .info, category: "ui", message: "Run resumed by user")
            } else {
                await pauseController.pause()
                isPaused = true
                AppSessionLog.shared.append(level: .warning, category: "ui", message: "Run paused by user")
            }
        }
    }

    func cancel() {
        guard let pauseController else { return }
        AppSessionLog.shared.append(level: .warning, category: "ui", message: "Cancellation requested by user")
        Task {
            await pauseController.cancel()
        }
        jobTask?.cancel()
    }

    func exportLog() {
        guard let url = FolderAccessManager.selectLogExportURL(suggestedName: "iCloudMaterializer-log.json") else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let lines = try logs.map { entry in
                String(decoding: try encoder.encode(entry), as: UTF8.self)
            }
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            AppSessionLog.shared.append(
                level: .info,
                category: "ui",
                message: "User exported in-memory log snapshot",
                path: url.path
            )
        } catch {
            snapshot.lastError = error.localizedDescription
            AppSessionLog.shared.append(
                level: .error,
                category: "ui",
                message: "Exporting in-memory log snapshot failed: \(error.localizedDescription)"
            )
        }
    }

    func revealCurrentLog() {
        NSWorkspace.shared.activateFileViewerSelecting([AppSessionLog.shared.sessionLogURL])
    }

    func openLogFolder() {
        NSWorkspace.shared.open(AppSessionLog.shared.directoryURL)
    }

    func setPreflightConfirmation(id: String, isConfirmed: Bool) {
        if isConfirmed {
            confirmedPreflightCheckIDs.insert(id)
        } else {
            confirmedPreflightCheckIDs.remove(id)
        }
        refreshPreflight()
    }

    func rebuildBatchPreview() {
        refreshPreflight()
        guard runMode == .batchQueue else {
            batchProjects = []
            batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchNamingSummary)
            return
        }
        guard let sourceURL, let destinationURL else {
            batchProjects = []
            batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchNamingSummary)
            return
        }

        let configuration = makeBatchConfiguration(sourceURL: sourceURL, destinationURL: destinationURL)
        do {
            let preview = try batchCoordinator.preview(configuration: configuration)
            batchProjects = preview.projects
            batchSnapshot = preview.snapshot
        } catch {
            batchProjects = []
            batchSnapshot = BatchSnapshot(
                batchID: configuration.batchID,
                state: .idle,
                sourceRootPath: sourceURL.path,
                destinationRootPath: destinationURL.path,
                suffix: batchNamingSummary,
                totalProjects: 0,
                completedProjects: 0,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: 0,
                readyForDeletionProjects: 0,
                currentProjectIndex: nil,
                currentProjectName: nil,
                startedAt: nil,
                finishedAt: nil,
                lastError: error.localizedDescription
            )
        }
    }

    private func startSingleRun(sourceURL: URL, destinationURL: URL, allowTargetQuarantine: Bool) {
        let resumeJobID = JobConfiguration.resumeJobID(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            targetFolderName: nil,
            transferPolicy: transferPolicy
        )
        let configuration = JobConfiguration(
            jobID: resumeJobID,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            preflightReport: preflightReport,
            rescueProfile: rescueProfile,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: clampedWorkerCount,
            hydrationWindow: clampedHydrationWindow,
            retryCount: max(1, retryCount),
            backoffSchedule: rescueProfile.backoffSchedule,
            maxHydrationWait: .seconds(300),
            shouldCreateArchive: false,
            hydrationPrefetchWindow: currentHydrationPrefetchWindow,
            hydrationHotSlotDuration: rescueProfile.hydrationHotSlotDuration,
            allowTargetQuarantine: allowTargetQuarantine,
            enableFinderFallback: true
        )
        AppSessionLog.shared.append(
            level: .info,
            category: "job",
            message: "Starting single rescue run",
            path: sourceURL.path
        )
        prepareForRun(sourceURL: sourceURL, destinationURL: destinationURL)
        snapshot.jobID = configuration.jobID
        let relay = ViewUpdateRelay { [weak self] updates in
            guard let self else { return }
            await self.consume(buffered: updates)
        }
        jobTask = Task {
            await coordinator.run(configuration: configuration, pauseController: pauseController!) { [weak self] update in
                guard self != nil else { return }
                await relay.enqueue(update)
            }
            await relay.flush()
        }
    }

    private func startBatchRun(sourceURL: URL, destinationURL: URL) {
        let configuration = makeBatchConfiguration(sourceURL: sourceURL, destinationURL: destinationURL)
        AppSessionLog.shared.append(
            level: .info,
            category: "batch",
            message: "Starting batch rescue run with order \(batchOrderingMode.title)",
            path: sourceURL.path
        )
        prepareForRun(sourceURL: sourceURL, destinationURL: destinationURL)
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchNamingSummary)
        batchSnapshot.batchID = configuration.batchID
        batchProjects = []
        let relay = ViewUpdateRelay { [weak self] updates in
            guard let self else { return }
            await self.consume(buffered: updates)
        }
        jobTask = Task {
            await batchCoordinator.run(configuration: configuration, pauseController: pauseController!) { [weak self] update in
                guard self != nil else { return }
                await relay.enqueue(update)
            }
            await relay.flush()
        }
    }

    private func makeBatchConfiguration(sourceURL: URL, destinationURL: URL) -> BatchConfiguration {
        BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: sourceURL,
            destinationRootURL: destinationURL,
            namingMode: batchNamingMode,
            orderingMode: batchOrderingMode,
            suffix: batchSuffix,
            rescueProfile: rescueProfile,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: clampedWorkerCount,
            hydrationWindow: clampedHydrationWindow,
            retryCount: max(1, retryCount),
            backoffSchedule: rescueProfile.backoffSchedule,
            maxHydrationWait: .seconds(300),
            shouldCreateArchive: false,
            hydrationPrefetchWindow: currentHydrationPrefetchWindow,
            hydrationHotSlotDuration: rescueProfile.hydrationHotSlotDuration,
            enableFinderFallback: true,
            projectPrefetchWindow: currentProjectPrefetchWindow
        )
    }

    private func prepareForRun(sourceURL: URL, destinationURL: URL) {
        logs.removeAll()
        activities.removeAll()
        failures.removeAll()
        snapshot = .idle(source: sourceURL, destination: destinationURL)
        snapshot.preflightReport = preflightReport
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchNamingSummary)
        pauseController = PauseController()
        isPaused = false
        lastProgressAt = Date()
    }

    private func consume(buffered updates: BufferedJobUpdates) {
        if let snapshot = updates.snapshot {
            consume(update: .snapshot(snapshot))
        }
        for entry in updates.logs {
            consume(update: .log(entry))
        }
        if let failures = updates.failures {
            consume(update: .failures(failures))
        }
        if let activities = updates.activities {
            consume(update: .activities(activities))
        }
        if let snapshot = updates.batchSnapshot {
            consume(update: .batchSnapshot(snapshot))
        }
        if let projects = updates.batchProjects {
            consume(update: .batchProjects(projects))
        }
    }

    private func consume(update: JobUpdate) {
        switch update {
        case .snapshot(let snapshot):
            if snapshotHasProgress(from: self.snapshot, to: snapshot) {
                lastProgressAt = Date()
            }
            self.snapshot = snapshot
        case .log(let entry):
            lastProgressAt = entry.createdAt
            logs.append(entry)
            if logs.count > Self.maxLogEntries {
                logs.removeFirst(logs.count - Self.maxLogEntries)
            }
        case .failures(let failures):
            if !failures.isEmpty {
                lastProgressAt = failures.last?.createdAt ?? Date()
            }
            self.failures = failures.sorted { $0.createdAt < $1.createdAt }
        case .activities(let activities):
            if activities != self.activities {
                lastProgressAt = Date()
            }
            self.activities = activities
        case .batchSnapshot(let snapshot):
            if batchSnapshotHasProgress(from: self.batchSnapshot, to: snapshot) {
                lastProgressAt = Date()
            }
            self.batchSnapshot = snapshot
        case .batchProjects(let projects):
            if projects != self.batchProjects {
                lastProgressAt = Date()
            }
            self.batchProjects = projects
        }
    }

    private func refreshIdleSnapshot() {
        snapshot = .idle(source: sourceURL, destination: destinationURL)
        snapshot.lastError = nil
        refreshPreflight()
        snapshot.preflightReport = preflightReport
        activities = []
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchNamingSummary)
        batchProjects = []
        lastProgressAt = nil
        if runMode == .batchQueue {
            rebuildBatchPreview()
        }
    }

    private func refreshPreflight() {
        preflightReport = preflightEngine.evaluate(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            transferPolicy: transferPolicy,
            confirmations: confirmedPreflightCheckIDs
        )
    }

    private var clampedWorkerCount: Int {
        min(max(workerCount, workerRange.lowerBound), workerRange.upperBound)
    }

    private var clampedHydrationWindow: Int {
        min(max(hydrationWindow, hydrationRange.lowerBound), hydrationRange.upperBound)
    }

    private func applyRescueProfileDefaults(_ profile: RescueProfile) {
        workerCount = profile.defaultWorkerCount
        hydrationWindow = profile.defaultHydrationWindow
        retryCount = profile.defaultRetryCount
    }

    private func snapshotHasProgress(from old: JobSnapshot, to new: JobSnapshot) -> Bool {
        old.phase != new.phase ||
        old.phaseDetail != new.phaseDetail ||
        old.currentPath != new.currentPath ||
        old.totalDiscovered != new.totalDiscovered ||
        old.totalDownloaded != new.totalDownloaded ||
        old.totalCopied != new.totalCopied ||
        old.totalFailed != new.totalFailed ||
        old.processedChunks != new.processedChunks ||
        old.activeWorkerCount != new.activeWorkerCount ||
        old.preflightReport != new.preflightReport ||
        old.hydrationMetrics != new.hydrationMetrics ||
        old.finishedAt != new.finishedAt ||
        old.lastError != new.lastError
    }

    private func batchSnapshotHasProgress(from old: BatchSnapshot, to new: BatchSnapshot) -> Bool {
        old.state != new.state ||
        old.completedProjects != new.completedProjects ||
        old.warningProjects != new.warningProjects ||
        old.failedProjects != new.failedProjects ||
        old.conflictedProjects != new.conflictedProjects ||
        old.readyForDeletionProjects != new.readyForDeletionProjects ||
        old.currentProjectIndex != new.currentProjectIndex ||
        old.currentProjectName != new.currentProjectName ||
        old.finishedAt != new.finishedAt ||
        old.lastError != new.lastError
    }
}

private struct BufferedJobUpdates: Sendable {
    var snapshot: JobSnapshot?
    var logs: [LogEntry] = []
    var failures: [FailureRecord]?
    var activities: [WorkerActivity]?
    var batchSnapshot: BatchSnapshot?
    var batchProjects: [BatchProjectPlan]?

    var isEmpty: Bool {
        snapshot == nil &&
        logs.isEmpty &&
        failures == nil &&
        activities == nil &&
        batchSnapshot == nil &&
        batchProjects == nil
    }

    mutating func merge(_ update: JobUpdate) {
        switch update {
        case .snapshot(let snapshot):
            self.snapshot = snapshot
        case .log(let entry):
            logs.append(entry)
        case .failures(let failures):
            self.failures = failures
        case .activities(let activities):
            self.activities = activities
        case .batchSnapshot(let snapshot):
            self.batchSnapshot = snapshot
        case .batchProjects(let projects):
            self.batchProjects = projects
        }
    }
}

private actor ViewUpdateRelay {
    private let flushInterval: Duration
    private let apply: @Sendable (BufferedJobUpdates) async -> Void
    private var pending = BufferedJobUpdates()
    private var flushTask: Task<Void, Never>?

    init(
        flushInterval: Duration = .milliseconds(200),
        apply: @escaping @Sendable (BufferedJobUpdates) async -> Void
    ) {
        self.flushInterval = flushInterval
        self.apply = apply
    }

    func enqueue(_ update: JobUpdate) {
        pending.merge(update)
        scheduleFlushIfNeeded()
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        let updates = pending
        pending = BufferedJobUpdates()
        guard !updates.isEmpty else { return }
        await apply(updates)
    }

    private func scheduleFlushIfNeeded() {
        guard flushTask == nil else { return }

        let flushInterval = self.flushInterval
        let apply = self.apply
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: flushInterval)
            guard let self else { return }
            let updates = await self.takePendingUpdates()
            guard !updates.isEmpty else { return }
            await apply(updates)
        }
    }

    private func takePendingUpdates() -> BufferedJobUpdates {
        flushTask = nil
        let updates = pending
        pending = BufferedJobUpdates()
        return updates
    }
}
