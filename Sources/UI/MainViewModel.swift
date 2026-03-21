import Foundation
import Observation

@MainActor
@Observable
final class MainViewModel {
    var sourceURL: URL?
    var destinationURL: URL?
    var runMode: RunMode = .singleProject
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
    var workerCount: Int = 2
    var hydrationWindow: Int = 4
    var retryCount: Int = 2
    var isPaused = false
    private(set) var lastProgressAt: Date?

    private let coordinator = MaterializerCoordinator()
    private let batchCoordinator = BatchCoordinator()
    private let preflightEngine = PreflightEngine()
    private var pauseController: PauseController?
    private var jobTask: Task<Void, Never>?
    private let maxLogEntries = 400

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
            suffix: batchSuffix,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: 4,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0)],
            maxHydrationWait: .seconds(1),
            hydrationPrefetchWindow: 0,
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
            suffix: batchSuffix,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: 4,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0)],
            maxHydrationWait: .seconds(1),
            hydrationPrefetchWindow: 0,
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
            return
        }
        refreshPreflight()
        guard preflightReport.canStart else {
            snapshot.lastError = preflightReport.blockingSummary ?? "Resolve the required preflight checks before starting."
            return
        }

        switch runMode {
        case .singleProject:
            let existingTarget = destinationURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: existingTarget.path) {
                pendingConflict = PromotionConflictState(existingTarget: existingTarget)
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
        startSingleRun(sourceURL: sourceURL, destinationURL: destinationURL, allowTargetQuarantine: true)
    }

    func pauseOrResume() {
        guard let pauseController, isRunning else { return }
        Task {
            if isPaused {
                await pauseController.resume()
                isPaused = false
            } else {
                await pauseController.pause()
                isPaused = true
            }
        }
    }

    func cancel() {
        guard let pauseController else { return }
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
        } catch {
            snapshot.lastError = error.localizedDescription
        }
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
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: max(1, min(workerCount, 4)),
            hydrationWindow: max(2, min(hydrationWindow, 8)),
            retryCount: max(1, retryCount),
            backoffSchedule: [.seconds(0), .seconds(2), .seconds(5), .seconds(15)],
            maxHydrationWait: .seconds(300),
            shouldCreateArchive: false,
            hydrationPrefetchWindow: 0,
            hydrationHotSlotDuration: .seconds(6),
            allowTargetQuarantine: allowTargetQuarantine,
            enableFinderFallback: true
        )
        prepareForRun(sourceURL: sourceURL, destinationURL: destinationURL)
        snapshot.jobID = configuration.jobID
        jobTask = Task {
            await coordinator.run(configuration: configuration, pauseController: pauseController!) { [weak self] update in
                guard let self else { return }
                await self.consume(update: update)
            }
        }
    }

    private func startBatchRun(sourceURL: URL, destinationURL: URL) {
        let configuration = makeBatchConfiguration(sourceURL: sourceURL, destinationURL: destinationURL)
        prepareForRun(sourceURL: sourceURL, destinationURL: destinationURL)
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchNamingSummary)
        batchSnapshot.batchID = configuration.batchID
        batchProjects = []
        jobTask = Task {
            await batchCoordinator.run(configuration: configuration, pauseController: pauseController!) { [weak self] update in
                guard let self else { return }
                await self.consume(update: update)
            }
        }
    }

    private func makeBatchConfiguration(sourceURL: URL, destinationURL: URL) -> BatchConfiguration {
        BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: sourceURL,
            destinationRootURL: destinationURL,
            namingMode: batchNamingMode,
            suffix: batchSuffix,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: max(1, min(workerCount, 4)),
            hydrationWindow: max(2, min(hydrationWindow, 8)),
            retryCount: max(1, retryCount),
            backoffSchedule: [.seconds(0), .seconds(2), .seconds(5), .seconds(15)],
            maxHydrationWait: .seconds(300),
            shouldCreateArchive: false,
            hydrationPrefetchWindow: 0,
            enableFinderFallback: true,
            projectPrefetchWindow: 0
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
            if logs.count > maxLogEntries {
                logs.removeFirst(logs.count - maxLogEntries)
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
