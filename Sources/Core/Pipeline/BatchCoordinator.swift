import Foundation

final class BatchCoordinator: @unchecked Sendable {
    private let fileManager: FileManager
    private let coordinatorFactory: @Sendable () -> MaterializerCoordinator

    init(
        fileManager: FileManager = .default,
        coordinatorFactory: @escaping @Sendable () -> MaterializerCoordinator = { MaterializerCoordinator() }
    ) {
        self.fileManager = fileManager
        self.coordinatorFactory = coordinatorFactory
    }

    func planProjects(configuration: BatchConfiguration) throws -> [BatchProjectPlan] {
        try validateRoots(configuration: configuration)

        let childURLs = try fileManager.contentsOfDirectory(
            at: configuration.sourceRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        let projectRoots = try childURLs
            .filter { $0.lastPathComponent != ".icloud-materializer" && $0.lastPathComponent != "_Materializer_Archives" }
            .filter { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey])
                return values.isDirectory == true
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }

        guard !projectRoots.isEmpty else {
            throw PipelineError.invalidBatchSource("No direct subfolders were found in the selected batch source root.")
        }

        return projectRoots.map { projectURL in
            let targetFolderName = configuration.targetFolderName(for: projectURL.lastPathComponent)
            let targetURL = configuration.destinationRootURL.appendingPathComponent(targetFolderName, isDirectory: true)
            let hasConflict = fileManager.fileExists(atPath: targetURL.path)
            return BatchProjectPlan(
                id: UUID(),
                sourceURL: projectURL,
                destinationRootURL: configuration.destinationRootURL,
                sourceFolderName: projectURL.lastPathComponent,
                targetFolderName: targetFolderName,
                state: hasConflict ? .conflicted : .pending,
                detail: hasConflict ? "Target already exists: \(targetURL.path)" : nil,
                archiveURL: configuration.archiveRootURL.appendingPathComponent("\(projectURL.lastPathComponent).zip", isDirectory: false),
                deletionManifestURL: configuration.deletionManifestRootURL.appendingPathComponent("\(projectURL.lastPathComponent).json", isDirectory: false),
                readyForDeletion: false,
                startedAt: nil,
                finishedAt: nil
            )
        }
    }

    func run(
        configuration: BatchConfiguration,
        pauseController: PauseController,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async {
        do {
            try prepareBatchArtifacts(configuration: configuration)
            var projects = try planProjects(configuration: configuration)
            let startedAt = Date()
            await onUpdate(.batchProjects(projects))
            await onUpdate(.batchSnapshot(snapshot(for: projects, configuration: configuration, state: .running, startedAt: startedAt)))

            for index in projects.indices {
                try await pauseController.checkpoint()

                guard projects[index].state != .conflicted else {
                    continue
                }

                projects[index].state = .running
                projects[index].startedAt = Date()
                projects[index].finishedAt = nil
                projects[index].detail = "Running"
                await onUpdate(.batchProjects(projects))
                await onUpdate(.batchSnapshot(snapshot(
                    for: projects,
                    configuration: configuration,
                    state: .running,
                    currentProjectIndex: index + 1,
                    currentProjectName: projects[index].sourceFolderName,
                    startedAt: startedAt
                )))

                let recorder = BatchProjectRecorder()
                let projectName = projects[index].sourceFolderName
                let projectConfiguration = configuration.jobConfiguration(for: projects[index])
                let materializer = coordinatorFactory()

                await materializer.run(
                    configuration: projectConfiguration,
                    pauseController: pauseController
                ) { update in
                    await recorder.record(update)
                    await onUpdate(self.prefixed(update: update, projectName: projectName))
                }

                let outcome = await recorder.outcome()
                projects[index].finishedAt = Date()
                projects[index].archiveURL = projectConfiguration.finalArchiveURL
                projects[index].deletionManifestURL = configuration.deletionManifestRootURL.appendingPathComponent("\(projects[index].sourceFolderName).json", isDirectory: false)
                projects[index].detail = outcome.lastError ?? outcome.phaseDetail
                projects[index].readyForDeletion = false

                switch outcome.phase {
                case .completed:
                    projects[index].state = .completed
                    try prepareDeletionManifestIfPossible(
                        for: &projects[index],
                        outcome: outcome,
                        configuration: configuration,
                        localCopyURL: projectConfiguration.visibleTargetURL
                    )
                case .completedWithWarnings:
                    projects[index].state = .completedWithWarnings
                    try prepareDeletionManifestIfPossible(
                        for: &projects[index],
                        outcome: outcome,
                        configuration: configuration,
                        localCopyURL: projectConfiguration.visibleTargetURL
                    )
                case .cancelled:
                    projects[index].state = .cancelled
                    await onUpdate(.batchProjects(projects))
                    await onUpdate(.batchSnapshot(snapshot(
                        for: projects,
                        configuration: configuration,
                        state: .cancelled,
                        startedAt: startedAt,
                        finishedAt: Date(),
                        lastError: outcome.lastError ?? "Batch run cancelled."
                    )))
                    return
                default:
                    projects[index].state = .failed
                }

                await onUpdate(.batchProjects(projects))
                await onUpdate(.batchSnapshot(snapshot(
                    for: projects,
                    configuration: configuration,
                    state: .running,
                    startedAt: startedAt
                )))
            }

            let finalState = finalState(for: projects)
            let lastError = projects.first(where: { $0.state == .failed || $0.state == .cancelled })?.detail
            await onUpdate(.batchProjects(projects))
            await onUpdate(.batchSnapshot(snapshot(
                for: projects,
                configuration: configuration,
                state: finalState,
                startedAt: startedAt,
                finishedAt: Date(),
                lastError: lastError
            )))
        } catch is CancellationError {
            await onUpdate(.batchSnapshot(BatchSnapshot(
                batchID: configuration.batchID,
                state: .cancelled,
                sourceRootPath: configuration.sourceRootURL.path,
                destinationRootPath: configuration.destinationRootURL.path,
                suffix: configuration.suffix,
                totalProjects: 0,
                completedProjects: 0,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: 0,
                readyForDeletionProjects: 0,
                currentProjectIndex: nil,
                currentProjectName: nil,
                startedAt: Date(),
                finishedAt: Date(),
                lastError: "Batch run cancelled."
            )))
        } catch {
            await onUpdate(.batchSnapshot(BatchSnapshot(
                batchID: configuration.batchID,
                state: .failed,
                sourceRootPath: configuration.sourceRootURL.path,
                destinationRootPath: configuration.destinationRootURL.path,
                suffix: configuration.suffix,
                totalProjects: 0,
                completedProjects: 0,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: 0,
                readyForDeletionProjects: 0,
                currentProjectIndex: nil,
                currentProjectName: nil,
                startedAt: Date(),
                finishedAt: Date(),
                lastError: error.localizedDescription
            )))
        }
    }

    private func validateRoots(configuration: BatchConfiguration) throws {
        let sourcePath = configuration.sourceRootURL.standardizedFileURL.path
        let destinationPath = configuration.destinationRootURL.standardizedFileURL.path

        if sourcePath == destinationPath {
            throw PipelineError.invalidDestination("Batch destination root must not be the same as the batch source root.")
        }
        if destinationPath.hasPrefix(sourcePath + "/") {
            throw PipelineError.invalidDestination("Batch destination root must not be inside the batch source root.")
        }
    }

    private func prepareBatchArtifacts(configuration: BatchConfiguration) throws {
        try fileManager.createDirectory(at: configuration.archiveRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configuration.deletionManifestRootURL, withIntermediateDirectories: true)
    }

    private func prepareDeletionManifestIfPossible(
        for project: inout BatchProjectPlan,
        outcome: (phase: JobPhase, phaseDetail: String?, lastError: String?),
        configuration: BatchConfiguration,
        localCopyURL: URL
    ) throws {
        guard let archiveURL = project.archiveURL, fileManager.fileExists(atPath: archiveURL.path) else {
            if project.state == .completed {
                project.state = .completedWithWarnings
            }
            let suffix = "Archive missing; source deletion remains disabled."
            project.detail = [project.detail, suffix].compactMap { $0 }.joined(separator: "\n")
            project.readyForDeletion = false
            return
        }

        guard let manifestURL = project.deletionManifestURL else {
            project.readyForDeletion = false
            return
        }

        let manifest = DeletionManifest(
            batchID: configuration.batchID,
            projectID: project.id,
            projectName: project.sourceFolderName,
            sourceURL: project.sourceURL,
            localCopyURL: localCopyURL,
            archiveURL: archiveURL,
            createdAt: Date(),
            sourceDeleteSuggested: project.state == .completed,
            notes: project.state == .completed
                ? "Local copy and external batch archive were created. Source deletion is still manual."
                : "Archive exists, but the project finished with warnings. Source deletion remains manual and should wait for review."
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: .atomic)
        project.readyForDeletion = true
        project.detail = [project.detail, "Deletion manifest prepared."].compactMap { $0 }.joined(separator: "\n")
    }

    private func snapshot(
        for projects: [BatchProjectPlan],
        configuration: BatchConfiguration,
        state: BatchState,
        currentProjectIndex: Int? = nil,
        currentProjectName: String? = nil,
        startedAt: Date?,
        finishedAt: Date? = nil,
        lastError: String? = nil
    ) -> BatchSnapshot {
        BatchSnapshot(
            batchID: configuration.batchID,
            state: state,
            sourceRootPath: configuration.sourceRootURL.path,
            destinationRootPath: configuration.destinationRootURL.path,
            suffix: configuration.suffix,
            totalProjects: projects.count,
            completedProjects: projects.filter { $0.state == .completed }.count,
            warningProjects: projects.filter { $0.state == .completedWithWarnings }.count,
            failedProjects: projects.filter { $0.state == .failed || $0.state == .cancelled }.count,
            conflictedProjects: projects.filter { $0.state == .conflicted }.count,
            readyForDeletionProjects: projects.filter(\.readyForDeletion).count,
            currentProjectIndex: currentProjectIndex,
            currentProjectName: currentProjectName,
            startedAt: startedAt,
            finishedAt: finishedAt,
            lastError: lastError
        )
    }

    private func finalState(for projects: [BatchProjectPlan]) -> BatchState {
        if projects.contains(where: { $0.state == .cancelled }) {
            return .cancelled
        }
        if projects.contains(where: { $0.state == .failed }) {
            return .failed
        }
        if projects.contains(where: { $0.state == .completedWithWarnings || $0.state == .conflicted }) {
            return .completedWithWarnings
        }
        return .completed
    }

    private func prefixed(update: JobUpdate, projectName: String) -> JobUpdate {
        switch update {
        case .snapshot(var snapshot):
            if let detail = snapshot.phaseDetail, !detail.isEmpty {
                snapshot.phaseDetail = "[\(projectName)] \(detail)"
            } else {
                snapshot.phaseDetail = "[\(projectName)] \(snapshot.phase.rawValue)"
            }
            return .snapshot(snapshot)
        case .log(var entry):
            entry.message = "[\(projectName)] \(entry.message)"
            return .log(entry)
        case .failures(let failures):
            let mapped = failures.map { failure in
                FailureRecord(
                    id: failure.id,
                    relativePath: "\(projectName): \(failure.relativePath)",
                    reason: failure.reason,
                    message: failure.message,
                    recoveryMode: failure.recoveryMode,
                    createdAt: failure.createdAt
                )
            }
            return .failures(mapped)
        case .activities(let activities):
            let mapped = activities.map { activity in
                WorkerActivity(
                    id: activity.id,
                    label: "\(projectName) · \(activity.label)",
                    phase: activity.phase,
                    detail: activity.detail,
                    path: activity.path,
                    updatedAt: activity.updatedAt
                )
            }
            return .activities(mapped)
        case .batchSnapshot, .batchProjects:
            return update
        }
    }
}

private actor BatchProjectRecorder {
    private var lastSnapshot: JobSnapshot?

    func record(_ update: JobUpdate) {
        guard case .snapshot(let snapshot) = update else { return }
        lastSnapshot = snapshot
    }

    func outcome() -> (phase: JobPhase, phaseDetail: String?, lastError: String?) {
        (
            phase: lastSnapshot?.phase ?? .failed,
            phaseDetail: lastSnapshot?.phaseDetail,
            lastError: lastSnapshot?.lastError
        )
    }
}
