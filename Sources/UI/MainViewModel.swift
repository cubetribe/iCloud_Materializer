import Foundation
import Observation

@MainActor
@Observable
final class MainViewModel {
    var sourceURL: URL?
    var destinationURL: URL?
    var snapshot: JobSnapshot = .idle(source: nil, destination: nil)
    var activities: [WorkerActivity] = []
    var logs: [LogEntry] = []
    var failures: [FailureRecord] = []
    var pendingConflict: PromotionConflictState?
    var workerCount: Int = 4
    var retryCount: Int = 3

    private let coordinator = MaterializerCoordinator()
    private var pauseController: PauseController?
    private var jobTask: Task<Void, Never>?
    private let maxLogEntries = 400

    var isRunning: Bool {
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

    func chooseSourceFolder() {
        sourceURL = FolderAccessManager.selectFolder(
            title: "Choose iCloud Source Folder",
            message: "Select the iCloud Drive project folder to materialize."
        )
        refreshIdleSnapshot()
    }

    func chooseDestinationFolder() {
        destinationURL = FolderAccessManager.selectFolder(
            title: "Choose Local Destination Folder",
            message: "Select a local destination outside iCloud Drive."
        )
        refreshIdleSnapshot()
    }

    func start() {
        guard let sourceURL, let destinationURL else {
            snapshot.lastError = PipelineError.missingFolderSelection.localizedDescription
            return
        }
        let existingTarget = destinationURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: existingTarget.path) {
            pendingConflict = PromotionConflictState(existingTarget: existingTarget)
            return
        }
        startRun(allowTargetQuarantine: false)
    }

    func startAfterQuarantineApproval() {
        pendingConflict = nil
        startRun(allowTargetQuarantine: true)
    }

    func pauseOrResume() {
        guard let pauseController else { return }
        if snapshot.phase == .materializing || snapshot.phase == .copying || snapshot.phase == .verifyingChunks || snapshot.phase == .promoting || snapshot.phase == .zipping || snapshot.phase == .scanning || snapshot.phase == .planningChunks || snapshot.phase == .finalVerifying {
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

    var isPaused = false

    private func startRun(allowTargetQuarantine: Bool) {
        guard let sourceURL, let destinationURL else { return }
        let configuration = JobConfiguration(
            jobID: UUID(),
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            workerCount: max(2, min(workerCount, 6)),
            retryCount: max(1, retryCount),
            backoffSchedule: [.seconds(0), .seconds(2), .seconds(5), .seconds(15)],
            allowTargetQuarantine: allowTargetQuarantine,
            enableFinderFallback: true
        )
        logs.removeAll()
        activities.removeAll()
        failures.removeAll()
        snapshot = .idle(source: sourceURL, destination: destinationURL)
        snapshot.jobID = configuration.jobID
        pauseController = PauseController()
        isPaused = false
        jobTask = Task {
            await coordinator.run(configuration: configuration, pauseController: pauseController!) { [weak self] update in
                guard let self else { return }
                await self.consume(update: update)
            }
        }
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
        }
    }

    private func refreshIdleSnapshot() {
        snapshot = .idle(source: sourceURL, destination: destinationURL)
        snapshot.lastError = nil
        activities = []
    }
}
