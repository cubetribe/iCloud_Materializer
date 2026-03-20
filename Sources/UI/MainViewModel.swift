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
    var batchSuffix: String = "Lokal"
    var customExcludedDirectoryNamesText: String = ""
    var customExcludedFileExtensionsText: String = ""
    var snapshot: JobSnapshot = .idle(source: nil, destination: nil)
    var batchSnapshot: BatchSnapshot = .idle(sourceRoot: nil, destinationRoot: nil, suffix: "Lokal")
    var batchProjects: [BatchProjectPlan] = []
    var activities: [WorkerActivity] = []
    var logs: [LogEntry] = []
    var failures: [FailureRecord] = []
    var pendingConflict: PromotionConflictState?
    var workerCount: Int = 4
    var hydrationWindow: Int = 12
    var retryCount: Int = 3
    var isPaused = false

    private let coordinator = MaterializerCoordinator()
    private let batchCoordinator = BatchCoordinator()
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
        sourceURL != nil && destinationURL != nil && !isRunning
    }

    var errorText: String? {
        batchSnapshot.lastError ?? snapshot.lastError
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

    func rebuildBatchPreview() {
        guard runMode == .batchQueue else {
            batchProjects = []
            batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchSuffix)
            return
        }
        guard let sourceURL, let destinationURL else {
            batchProjects = []
            batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchSuffix)
            return
        }

        let configuration = makeBatchConfiguration(sourceURL: sourceURL, destinationURL: destinationURL)
        do {
            batchProjects = try batchCoordinator.planProjects(configuration: configuration)
            batchSnapshot = BatchSnapshot(
                batchID: configuration.batchID,
                state: .idle,
                sourceRootPath: sourceURL.path,
                destinationRootPath: destinationURL.path,
                suffix: batchSuffix,
                totalProjects: batchProjects.count,
                completedProjects: 0,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: batchProjects.filter { $0.state == .conflicted }.count,
                currentProjectIndex: nil,
                currentProjectName: nil,
                startedAt: nil,
                finishedAt: nil,
                lastError: nil
            )
        } catch {
            batchProjects = []
            batchSnapshot = BatchSnapshot(
                batchID: configuration.batchID,
                state: .idle,
                sourceRootPath: sourceURL.path,
                destinationRootPath: destinationURL.path,
                suffix: batchSuffix,
                totalProjects: 0,
                completedProjects: 0,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: 0,
                currentProjectIndex: nil,
                currentProjectName: nil,
                startedAt: nil,
                finishedAt: nil,
                lastError: error.localizedDescription
            )
        }
    }

    private func startSingleRun(sourceURL: URL, destinationURL: URL, allowTargetQuarantine: Bool) {
        let configuration = JobConfiguration(
            jobID: UUID(),
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: max(2, min(workerCount, 6)),
            hydrationWindow: max(4, min(hydrationWindow, 24)),
            retryCount: max(1, retryCount),
            backoffSchedule: [.seconds(0), .seconds(2), .seconds(5), .seconds(15)],
            maxHydrationWait: .seconds(300),
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
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchSuffix)
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
            suffix: batchSuffix,
            transferPolicy: transferPolicy,
            priorityPolicy: priorityPolicy,
            workerCount: max(2, min(workerCount, 6)),
            hydrationWindow: max(4, min(hydrationWindow, 24)),
            retryCount: max(1, retryCount),
            backoffSchedule: [.seconds(0), .seconds(2), .seconds(5), .seconds(15)],
            maxHydrationWait: .seconds(300),
            enableFinderFallback: true
        )
    }

    private func prepareForRun(sourceURL: URL, destinationURL: URL) {
        logs.removeAll()
        activities.removeAll()
        failures.removeAll()
        snapshot = .idle(source: sourceURL, destination: destinationURL)
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchSuffix)
        pauseController = PauseController()
        isPaused = false
    }

    private func consume(update: JobUpdate) {
        switch update {
        case .snapshot(let snapshot):
            self.snapshot = snapshot
        case .log(let entry):
            logs.append(entry)
            if logs.count > maxLogEntries {
                logs.removeFirst(logs.count - maxLogEntries)
            }
        case .failures(let failures):
            self.failures = failures.sorted { $0.createdAt < $1.createdAt }
        case .activities(let activities):
            self.activities = activities
        case .batchSnapshot(let snapshot):
            self.batchSnapshot = snapshot
        case .batchProjects(let projects):
            self.batchProjects = projects
        }
    }

    private func refreshIdleSnapshot() {
        snapshot = .idle(source: sourceURL, destination: destinationURL)
        snapshot.lastError = nil
        activities = []
        batchSnapshot = .idle(sourceRoot: sourceURL, destinationRoot: destinationURL, suffix: batchSuffix)
        batchProjects = []
        if runMode == .batchQueue {
            rebuildBatchPreview()
        }
    }
}
