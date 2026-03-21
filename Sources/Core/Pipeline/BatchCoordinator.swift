import Foundation

final class BatchCoordinator: @unchecked Sendable {
    private let fileManager: FileManager
    private let coordinatorFactory: @Sendable () -> MaterializerCoordinator
    private let projectPrefetcher: @Sendable (URL, TransferPolicy, Int) async -> Void

    init(
        fileManager: FileManager = .default,
        coordinatorFactory: @escaping @Sendable () -> MaterializerCoordinator = { MaterializerCoordinator() },
        projectPrefetcher: @escaping @Sendable (URL, TransferPolicy, Int) async -> Void = { url, transferPolicy, scanDepth in
            let fileManager = FileManager.default
            let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isUbiquitousItemKey]
            let childLimit = BatchCoordinator.prefetchCandidateLimit(scanDepth: scanDepth)
            let candidates = BatchCoordinator.prefetchCandidateURLs(
                projectURL: url,
                transferPolicy: transferPolicy,
                childLimit: childLimit,
                fileManager: fileManager
            )
            var requested = 0
            for candidate in candidates where requested < childLimit + 1 {
                guard let values = try? candidate.resourceValues(forKeys: resourceKeys),
                      values.isUbiquitousItem == true else {
                    continue
                }
                try? fileManager.startDownloadingUbiquitousItem(at: candidate)
                requested += 1
            }
        }
    ) {
        self.fileManager = fileManager
        self.coordinatorFactory = coordinatorFactory
        self.projectPrefetcher = projectPrefetcher
    }

    static func prefetchCandidateURLs(
        projectURL: URL,
        transferPolicy: TransferPolicy,
        childLimit: Int,
        fileManager: FileManager = .default
    ) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey]
        var candidates: [URL] = [projectURL]
        guard childLimit > 0 else { return candidates }

        var queue: [URL] = [projectURL]
        while !queue.isEmpty, candidates.count < childLimit + 1 {
            let directoryURL = queue.removeFirst()
            guard let children = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsPackageDescendants]
            ) else {
                continue
            }

            let sortedChildren = children.sorted { lhs, rhs in
                let lhsValues = try? lhs.resourceValues(forKeys: resourceKeys)
                let rhsValues = try? rhs.resourceValues(forKeys: resourceKeys)
                let lhsIsDirectory = lhsValues?.isDirectory ?? false
                let rhsIsDirectory = rhsValues?.isDirectory ?? false
                if lhsIsDirectory != rhsIsDirectory {
                    return lhsIsDirectory && !rhsIsDirectory
                }
                return lhs.lastPathComponent.localizedCaseInsensitiveCompare(rhs.lastPathComponent) == .orderedAscending
            }

            for child in sortedChildren {
                guard candidates.count < childLimit + 1 else { break }
                let values = try? child.resourceValues(forKeys: resourceKeys)
                let isDirectory = values?.isDirectory == true
                let kind: ItemKind = isDirectory ? .directory : .file
                let relativePath = normalizedRelativePath(for: child, rootURL: projectURL)
                switch transferPolicy.scanDecision(relativePath: relativePath, kind: kind) {
                case .include:
                    candidates.append(child)
                    if isDirectory {
                        queue.append(child)
                    }
                case .excludeItem:
                    continue
                case .excludeDescendants:
                    continue
                }
            }
        }

        return candidates
    }

    static func prefetchCandidateLimit(scanDepth: Int) -> Int {
        let depth = max(scanDepth, 1)
        return min(max(depth * 6, 24), 256)
    }

    func preview(configuration: BatchConfiguration) throws -> (snapshot: BatchSnapshot, projects: [BatchProjectPlan]) {
        try validateRoots(configuration: configuration)
        let projects = try mergedProjects(configuration: configuration)
        let persisted = loadPersistedRun(configuration: configuration)
        let previewSnapshot = snapshot(
            for: projects,
            configuration: configuration,
            state: .idle,
            startedAt: persisted?.snapshot.startedAt,
            finishedAt: persisted?.snapshot.finishedAt,
            lastError: previewLastError(from: persisted?.snapshot, projects: projects)
        )
        return (previewSnapshot, projects)
    }

    func planProjects(configuration: BatchConfiguration) throws -> [BatchProjectPlan] {
        try preview(configuration: configuration).projects
    }

    func run(
        configuration: BatchConfiguration,
        pauseController: PauseController,
        onUpdate: @escaping @Sendable (JobUpdate) async -> Void
    ) async {
        var projects: [BatchProjectPlan] = []
        var startedAt = Date()
        var prefetchedProjectSourcePaths: Set<String> = []

        do {
            try prepareBatchArtifacts(configuration: configuration)
            let preview = try preview(configuration: configuration)
            projects = preview.projects
            startedAt = preview.snapshot.startedAt ?? Date()

            let initialSnapshot = snapshot(
                for: projects,
                configuration: configuration,
                state: .running,
                startedAt: startedAt
            )
            try savePersistedRun(snapshot: initialSnapshot, projects: projects, configuration: configuration)
            await onUpdate(.batchProjects(projects))
            await onUpdate(.batchSnapshot(initialSnapshot))

            for index in projects.indices {
                try await pauseController.checkpoint()

                if shouldSkip(projects[index]) {
                    continue
                }

                projects[index].readyForDeletion = false
                projects[index].state = .running
                projects[index].startedAt = Date()
                projects[index].finishedAt = nil
                projects[index].detail = retryDetail(for: projects[index])
                await prefetchUpcomingProjects(
                    from: index,
                    projects: &projects,
                    configuration: configuration,
                    prefetchedProjectSourcePaths: &prefetchedProjectSourcePaths
                )

                let runningSnapshot = snapshot(
                    for: projects,
                    configuration: configuration,
                    state: .running,
                    currentProjectIndex: index + 1,
                    currentProjectName: projects[index].sourceFolderName,
                    startedAt: startedAt
                )
                try savePersistedRun(snapshot: runningSnapshot, projects: projects, configuration: configuration)
                await onUpdate(.batchProjects(projects))
                await onUpdate(.batchSnapshot(runningSnapshot))

                let recorder = BatchProjectRecorder()
                let projectName = projects[index].sourceFolderName
                let projectConfiguration = configuration.jobConfiguration(for: projects[index])
                let materializer = coordinatorFactory()
                AppSessionLog.shared.append(
                    level: .info,
                    category: "batch",
                    message: "Starting batch project \(projectName)",
                    path: projects[index].sourceURL.path
                )

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
                    AppSessionLog.shared.append(
                        level: .info,
                        category: "batch",
                        message: "Batch project completed: \(projectName)",
                        path: projects[index].targetURL.path
                    )
                    try prepareDeletionManifestIfPossible(
                        for: &projects[index],
                        configuration: configuration,
                        localCopyURL: projectConfiguration.visibleTargetURL
                    )
                case .completedWithWarnings:
                    projects[index].state = .completedWithWarnings
                    AppSessionLog.shared.append(
                        level: .warning,
                        category: "batch",
                        message: "Batch project completed with warnings: \(projectName)",
                        path: projects[index].targetURL.path
                    )
                    try prepareDeletionManifestIfPossible(
                        for: &projects[index],
                        configuration: configuration,
                        localCopyURL: projectConfiguration.visibleTargetURL
                    )
                case .cancelled:
                    projects[index].state = .cancelled
                    AppSessionLog.shared.append(
                        level: .warning,
                        category: "batch",
                        message: "Batch project cancelled: \(projectName)",
                        path: projects[index].sourceURL.path
                    )
                    let cancelledSnapshot = snapshot(
                        for: projects,
                        configuration: configuration,
                        state: .cancelled,
                        startedAt: startedAt,
                        finishedAt: Date(),
                        lastError: outcome.lastError ?? "Batch run cancelled."
                    )
                    try savePersistedRun(snapshot: cancelledSnapshot, projects: projects, configuration: configuration)
                    await onUpdate(.batchProjects(projects))
                    await onUpdate(.batchSnapshot(cancelledSnapshot))
                    return
                default:
                    projects[index].state = .failed
                    AppSessionLog.shared.append(
                        level: .error,
                        category: "batch",
                        message: "Batch project failed: \(projectName). \(outcome.lastError ?? outcome.phaseDetail ?? "No detail")",
                        path: projects[index].sourceURL.path
                    )
                }

                let loopSnapshot = snapshot(
                    for: projects,
                    configuration: configuration,
                    state: .running,
                    startedAt: startedAt
                )
                try savePersistedRun(snapshot: loopSnapshot, projects: projects, configuration: configuration)
                await onUpdate(.batchProjects(projects))
                await onUpdate(.batchSnapshot(loopSnapshot))
            }

            let finalState = finalState(for: projects)
            let lastError = projects.first(where: { $0.state == .failed || $0.state == .cancelled })?.detail
            let finalSnapshot = snapshot(
                for: projects,
                configuration: configuration,
                state: finalState,
                startedAt: startedAt,
                finishedAt: Date(),
                lastError: lastError
            )
            AppSessionLog.shared.append(
                level: finalState == .completed ? .info : .warning,
                category: "batch",
                message: "Batch run finished with state \(finalState.rawValue)",
                path: configuration.sourceRootURL.path
            )
            try savePersistedRun(snapshot: finalSnapshot, projects: projects, configuration: configuration)
            await onUpdate(.batchProjects(projects))
            await onUpdate(.batchSnapshot(finalSnapshot))
        } catch is CancellationError {
            AppSessionLog.shared.append(
                level: .warning,
                category: "batch",
                message: "Batch run cancelled",
                path: configuration.sourceRootURL.path
            )
            let cancelledSnapshot = snapshot(
                for: projects,
                configuration: configuration,
                state: .cancelled,
                startedAt: startedAt,
                finishedAt: Date(),
                lastError: "Batch run cancelled."
            )
            try? savePersistedRun(snapshot: cancelledSnapshot, projects: projects, configuration: configuration)
            await onUpdate(.batchProjects(projects))
            await onUpdate(.batchSnapshot(cancelledSnapshot))
        } catch {
            AppSessionLog.shared.append(
                level: .error,
                category: "batch",
                message: "Batch run failed: \(error.localizedDescription)",
                path: configuration.sourceRootURL.path
            )
            let failedSnapshot = snapshot(
                for: projects,
                configuration: configuration,
                state: .failed,
                startedAt: startedAt,
                finishedAt: Date(),
                lastError: error.localizedDescription
            )
            try? savePersistedRun(snapshot: failedSnapshot, projects: projects, configuration: configuration)
            await onUpdate(.batchProjects(projects))
            await onUpdate(.batchSnapshot(failedSnapshot))
        }
    }

    private func freshProjects(configuration: BatchConfiguration) throws -> [BatchProjectPlan] {
        let childURLs = try fileManager.contentsOfDirectory(
            at: configuration.sourceRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .attributeModificationDateKey, .creationDateKey],
            options: [.skipsPackageDescendants]
        )

        let projectRoots = try childURLs
            .filter { !TransferPolicy.isInternalArtifactDirectoryName($0.lastPathComponent) }
            .compactMap { url -> ProjectRootDescriptor? in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .attributeModificationDateKey, .creationDateKey])
                guard values.isDirectory == true else {
                    return nil
                }
                return ProjectRootDescriptor(
                    url: url,
                    activityDate: projectActivityDate(from: values)
                )
            }
            .sorted { lhs, rhs in
                compareProjectRoots(lhs, rhs, orderingMode: configuration.orderingMode)
            }

        guard !projectRoots.isEmpty else {
            throw PipelineError.invalidBatchSource("No direct subfolders were found in the selected batch source root.")
        }

        return projectRoots.map { descriptor in
            let projectURL = descriptor.url
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
                archiveURL: configuration.shouldCreateArchive
                    ? configuration.archiveRootURL.appendingPathComponent("\(projectURL.lastPathComponent).zip", isDirectory: false)
                    : nil,
                deletionManifestURL: configuration.deletionManifestRootURL.appendingPathComponent("\(projectURL.lastPathComponent).json", isDirectory: false),
                readyForDeletion: false,
                startedAt: nil,
                finishedAt: nil
            )
        }
    }

    private func mergedProjects(configuration: BatchConfiguration) throws -> [BatchProjectPlan] {
        let fresh = try freshProjects(configuration: configuration)
        guard let persisted = loadPersistedRun(configuration: configuration) else {
            return fresh
        }

        let persistedBySourcePath = Dictionary(uniqueKeysWithValues: persisted.projects.map { ($0.sourceURL.standardizedFileURL.path, $0) })
        return fresh.map { project in
            guard let persistedProject = persistedBySourcePath[project.sourceURL.standardizedFileURL.path] else {
                return project
            }
            return merge(
                fresh: project,
                persisted: persistedProject,
                shouldCreateArchive: configuration.shouldCreateArchive
            )
        }
    }

    private func merge(
        fresh: BatchProjectPlan,
        persisted: BatchProjectPlan,
        shouldCreateArchive: Bool
    ) -> BatchProjectPlan {
        var merged = fresh
        merged.id = persisted.id
        merged.startedAt = persisted.startedAt
        merged.finishedAt = persisted.finishedAt
        merged.archiveURL = persisted.archiveURL ?? fresh.archiveURL
        merged.deletionManifestURL = persisted.deletionManifestURL ?? fresh.deletionManifestURL
        merged.detail = sanitizedDetail(persisted.detail) ?? fresh.detail

        switch persisted.state {
        case .completed:
            if isRestorableCompleted(persisted) {
                merged.state = .completed
                merged.readyForDeletion = shouldCreateArchive ? persisted.readyForDeletion : false
                merged.detail = sanitizedDetail(persisted.detail)
                if !shouldCreateArchive {
                    let suffix = "Automatic archive creation is disabled during rescue mode. Source deletion review remains off."
                    merged.detail = [merged.detail, suffix].compactMap { $0 }.joined(separator: "\n")
                }
            } else {
                merged.state = .failed
                merged.readyForDeletion = false
                merged.detail = "Persisted completed state is no longer valid. The local target is missing, so the project will rerun."
            }
        case .conflicted:
            merged.state = fresh.state == .conflicted ? .conflicted : .pending
            merged.readyForDeletion = false
            merged.detail = merged.state == .conflicted ? (sanitizedDetail(persisted.detail) ?? fresh.detail) : nil
        case .running:
            merged.state = .failed
            merged.readyForDeletion = false
            merged.detail = "Previous app session ended before this project finished. It will retry on the next batch run."
        case .completedWithWarnings, .failed, .cancelled:
            merged.state = persisted.state
            merged.readyForDeletion = false
            merged.detail = sanitizedDetail(persisted.detail)
        case .pending:
            merged.readyForDeletion = false
        }

        return merged
    }

    private func shouldSkip(_ project: BatchProjectPlan) -> Bool {
        project.state == .conflicted || isRestorableCompleted(project)
    }

    private func retryDetail(for project: BatchProjectPlan) -> String {
        switch project.state {
        case .failed:
            return "Retrying after previous failed attempt"
        case .cancelled:
            return "Retrying after previous cancelled attempt"
        case .completedWithWarnings:
            return "Retrying project after previous warnings"
        default:
            return "Running"
        }
    }

    private func prefetchUpcomingProjects(
        from currentIndex: Int,
        projects: inout [BatchProjectPlan],
        configuration: BatchConfiguration,
        prefetchedProjectSourcePaths: inout Set<String>
    ) async {
        guard configuration.projectPrefetchWindow > 0 else { return }

        var remaining = configuration.projectPrefetchWindow
        for nextIndex in projects.indices where nextIndex > currentIndex {
            guard remaining > 0 else { break }
            guard shouldPrefetch(projects[nextIndex], prefetchedProjectSourcePaths: prefetchedProjectSourcePaths) else { continue }
            let prefetchDepth = configuration.jobConfiguration(for: projects[nextIndex]).localPrefetchScanDepth
            await projectPrefetcher(projects[nextIndex].sourceURL, configuration.transferPolicy, prefetchDepth)
            prefetchedProjectSourcePaths.insert(projects[nextIndex].sourceURL.standardizedFileURL.path)
            let hint = "Project directory warmup requested."
            if projects[nextIndex].detail?.contains(hint) != true {
                projects[nextIndex].detail = [projects[nextIndex].detail, hint]
                    .compactMap { $0 }
                    .joined(separator: "\n")
            }
            remaining -= 1
        }
    }

    private func shouldPrefetch(_ project: BatchProjectPlan, prefetchedProjectSourcePaths: Set<String>) -> Bool {
        guard !prefetchedProjectSourcePaths.contains(project.sourceURL.standardizedFileURL.path) else {
            return false
        }
        switch project.state {
        case .pending, .failed, .cancelled, .completedWithWarnings:
            return true
        case .running, .completed, .conflicted:
            return false
        }
    }

    private func sanitizedDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let sanitizedLines = detail
            .split(separator: "\n")
            .map(String.init)
            .filter {
                $0 != "Project root prefetch requested." &&
                $0 != "Project directory warmup requested."
            }
        guard !sanitizedLines.isEmpty else { return nil }
        return sanitizedLines.joined(separator: "\n")
    }

    private func compareProjectRoots(
        _ lhs: ProjectRootDescriptor,
        _ rhs: ProjectRootDescriptor,
        orderingMode: BatchOrderingMode
    ) -> Bool {
        switch orderingMode {
        case .alphabetical:
            return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
        case .newestFirst:
            if lhs.activityDate != rhs.activityDate {
                return lhs.activityDate > rhs.activityDate
            }
        case .oldestFirst:
            if lhs.activityDate != rhs.activityDate {
                return lhs.activityDate < rhs.activityDate
            }
        }
        return lhs.url.lastPathComponent.localizedCaseInsensitiveCompare(rhs.url.lastPathComponent) == .orderedAscending
    }

    private func projectActivityDate(from values: URLResourceValues) -> Date {
        values.contentModificationDate ??
        values.attributeModificationDate ??
        values.creationDate ??
        .distantPast
    }

    private static func normalizedRelativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else {
            return url.lastPathComponent
        }
        let startIndex = itemPath.index(itemPath.startIndex, offsetBy: rootPath.count)
        let raw = String(itemPath[startIndex...])
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func previewLastError(from snapshot: BatchSnapshot?, projects: [BatchProjectPlan]) -> String? {
        if snapshot?.state == .running {
            return "Previous batch session ended before completion. Finished projects were kept; unfinished projects will retry on the next batch run."
        }
        return projects.first(where: { $0.state == .failed })?.detail ?? snapshot?.lastError
    }

    private func isRestorableCompleted(_ project: BatchProjectPlan) -> Bool {
        project.state == .completed &&
        fileManager.fileExists(atPath: project.targetURL.path)
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
        if configuration.shouldCreateArchive {
            try fileManager.createDirectory(at: configuration.archiveRootURL, withIntermediateDirectories: true)
        }
        try fileManager.createDirectory(at: configuration.deletionManifestRootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: configuration.resumeRootURL, withIntermediateDirectories: true)
    }

    private func loadPersistedRun(configuration: BatchConfiguration) -> PersistedBatchRun? {
        guard fileManager.fileExists(atPath: configuration.resumeStateURL.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: configuration.resumeStateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PersistedBatchRun.self, from: data)
        } catch {
            return nil
        }
    }

    private func savePersistedRun(
        snapshot: BatchSnapshot,
        projects: [BatchProjectPlan],
        configuration: BatchConfiguration
    ) throws {
        try fileManager.createDirectory(at: configuration.resumeRootURL, withIntermediateDirectories: true)
        let state = PersistedBatchRun(
            snapshot: snapshot,
            projects: projects,
            updatedAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: configuration.resumeStateURL, options: .atomic)
    }

    private func prepareDeletionManifestIfPossible(
        for project: inout BatchProjectPlan,
        configuration: BatchConfiguration,
        localCopyURL: URL
    ) throws {
        guard configuration.shouldCreateArchive else {
            project.readyForDeletion = false
            let suffix = "Automatic archive creation is disabled during rescue mode. Source deletion review remains off."
            project.detail = [project.detail, suffix].compactMap { $0 }.joined(separator: "\n")
            return
        }
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
            suffix: configuration.namingSummary,
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

private struct ProjectRootDescriptor {
    var url: URL
    var activityDate: Date
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
