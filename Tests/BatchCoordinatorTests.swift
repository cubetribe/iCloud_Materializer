import XCTest
@testable import iCloudMaterializer

final class BatchCoordinatorTests: XCTestCase {
    func testPlanProjectsUsesDirectSubfoldersAndAppliesSuffix() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("Alpha", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("Beta", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("_Materializer_Archives", isDirectory: true), withIntermediateDirectories: true)
        try Data("ignore me".utf8).write(to: sourceRoot.appendingPathComponent("README.txt", isDirectory: false))
        try fileManager.createDirectory(at: destinationRoot.appendingPathComponent("Beta-Lokal", isDirectory: true), withIntermediateDirectories: true)

        let coordinator = BatchCoordinator()
        let plans = try coordinator.planProjects(configuration: makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot))

        XCTAssertEqual(plans.map { $0.sourceFolderName }, ["Alpha", "Beta"])
        XCTAssertEqual(plans.map { $0.targetFolderName }, ["Alpha-Lokal", "Beta-Lokal"])
        XCTAssertEqual(plans.first?.state, .pending)
        XCTAssertEqual(plans.last?.state, .conflicted)
    }

    func testPlanProjectsDefaultsToNewestProjectsFirst() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let older = sourceRoot.appendingPathComponent("Alpha", isDirectory: true)
        let newer = sourceRoot.appendingPathComponent("Beta", isDirectory: true)
        try fileManager.createDirectory(at: older, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: newer, withIntermediateDirectories: true)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10)], ofItemAtPath: older.path)
        try fileManager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 20)], ofItemAtPath: newer.path)

        let coordinator = BatchCoordinator()
        var configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        configuration.orderingMode = .newestFirst
        let plans = try coordinator.planProjects(configuration: configuration)

        XCTAssertEqual(plans.map(\.sourceFolderName), ["Beta", "Alpha"])
    }

    func testPreviewRestoresCompletedProjectsFromPersistedBatchState() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(named: "Alpha", in: sourceRoot)
        try createFixture(named: "Beta", in: sourceRoot)

        let configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        let alphaTarget = destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true)
        try fileManager.createDirectory(at: alphaTarget, withIntermediateDirectories: true)

        let restoredProject = BatchProjectPlan(
            id: UUID(),
            sourceURL: sourceRoot.appendingPathComponent("Alpha", isDirectory: true),
            destinationRootURL: destinationRoot,
            sourceFolderName: "Alpha",
            targetFolderName: "Alpha-Lokal",
            state: .completed,
            detail: "Local rescue finished.",
            archiveURL: nil,
            deletionManifestURL: nil,
            readyForDeletion: false,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20)
        )
        let persisted = PersistedBatchRun(
            snapshot: BatchSnapshot(
                batchID: configuration.batchID,
                state: .completedWithWarnings,
                sourceRootPath: sourceRoot.path,
                destinationRootPath: destinationRoot.path,
                suffix: configuration.suffix,
                totalProjects: 2,
                completedProjects: 1,
                warningProjects: 0,
                failedProjects: 1,
                conflictedProjects: 0,
                readyForDeletionProjects: 1,
                currentProjectIndex: nil,
                currentProjectName: nil,
                startedAt: Date(timeIntervalSince1970: 10),
                finishedAt: Date(timeIntervalSince1970: 20),
                lastError: "Previous batch failed after Alpha"
            ),
            projects: [restoredProject],
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try writePersistedBatch(persisted, to: configuration.resumeStateURL)

        let coordinator = BatchCoordinator()
        let preview = try coordinator.preview(configuration: configuration)

        XCTAssertEqual(preview.snapshot.completedProjects, 1)
        XCTAssertEqual(preview.projects.first?.state, .completed)
        XCTAssertFalse(preview.projects.first?.readyForDeletion == true)
        XCTAssertEqual(preview.projects.last?.state, .pending)
    }

    func testRunSkipsRestorableCompletedProjectsOnResume() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(named: "Alpha", in: sourceRoot)
        try createFixture(named: "Beta", in: sourceRoot)

        let configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        let alphaTarget = destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true)
        try fileManager.createDirectory(at: alphaTarget, withIntermediateDirectories: true)
        try Data("DATABASE_URL=postgres://local".utf8).write(to: alphaTarget.appendingPathComponent(".env", isDirectory: false))

        let restoredProject = BatchProjectPlan(
            id: UUID(),
            sourceURL: sourceRoot.appendingPathComponent("Alpha", isDirectory: true),
            destinationRootURL: destinationRoot,
            sourceFolderName: "Alpha",
            targetFolderName: "Alpha-Lokal",
            state: .completed,
            detail: "Local rescue finished.",
            archiveURL: nil,
            deletionManifestURL: nil,
            readyForDeletion: false,
            startedAt: Date(timeIntervalSince1970: 10),
            finishedAt: Date(timeIntervalSince1970: 20)
        )
        let persisted = PersistedBatchRun(
            snapshot: BatchSnapshot(
                batchID: configuration.batchID,
                state: .running,
                sourceRootPath: sourceRoot.path,
                destinationRootPath: destinationRoot.path,
                suffix: configuration.suffix,
                totalProjects: 2,
                completedProjects: 1,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: 0,
                readyForDeletionProjects: 1,
                currentProjectIndex: 2,
                currentProjectName: "Beta",
                startedAt: Date(timeIntervalSince1970: 10),
                finishedAt: nil,
                lastError: nil
            ),
            projects: [restoredProject],
            updatedAt: Date(timeIntervalSince1970: 21)
        )
        try writePersistedBatch(persisted, to: configuration.resumeStateURL)

        let recorder = BatchUpdateRecorder()
        let coordinator = BatchCoordinator()
        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let batchSnapshot = await recorder.lastBatchSnapshot()
        XCTAssertEqual(batchSnapshot?.state, .completed)
        XCTAssertEqual(batchSnapshot?.completedProjects, 2)

        let plans = await recorder.lastBatchProjects()
        XCTAssertEqual(plans.map { $0.state }, [.completed, .completed])
        XCTAssertTrue(plans.allSatisfy { !$0.readyForDeletion })
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Beta-Lokal", isDirectory: true).path))
        XCTAssertFalse(fileManager.fileExists(atPath: configuration.archiveRootURL.appendingPathComponent("Alpha.zip", isDirectory: false).path))
        XCTAssertFalse(fileManager.fileExists(atPath: configuration.archiveRootURL.appendingPathComponent("Beta.zip", isDirectory: false).path))
        XCTAssertTrue(plans.first(where: { $0.sourceFolderName == "Beta" })?.detail?.contains("Automatic archive creation is disabled during rescue mode.") == true)
    }

    func testRunProcessesProjectsSequentially() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(named: "Alpha", in: sourceRoot)
        try createFixture(named: "Beta", in: sourceRoot)

        let recorder = BatchUpdateRecorder()
        let coordinator = BatchCoordinator()
        let configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)

        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let batchSnapshot = await recorder.lastBatchSnapshot()
        XCTAssertEqual(batchSnapshot?.state, .completed)
        XCTAssertEqual(batchSnapshot?.completedProjects, 2)

        let plans = await recorder.lastBatchProjects()
        XCTAssertEqual(plans.map { $0.state }, [.completed, .completed])
        XCTAssertTrue(plans.allSatisfy { !$0.readyForDeletion })
        XCTAssertTrue(plans.allSatisfy { $0.deletionManifestURL != nil })

        let archiveRoot = sourceRoot.appendingPathComponent("_Materializer_Archives", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Beta-Lokal", isDirectory: true).path))
        XCTAssertFalse(fileManager.fileExists(atPath: archiveRoot.appendingPathComponent("Alpha.zip", isDirectory: false).path))
        XCTAssertFalse(fileManager.fileExists(atPath: archiveRoot.appendingPathComponent("Beta.zip", isDirectory: false).path))
        XCTAssertFalse(plans.compactMap { $0.deletionManifestURL }.allSatisfy { fileManager.fileExists(atPath: $0.path) })
        XCTAssertTrue(plans.allSatisfy { $0.detail?.contains("Automatic archive creation is disabled during rescue mode.") == true })
    }

    func testRunCanPrepareDeletionArtifactsWhenArchiveCreationIsEnabled() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(named: "Alpha", in: sourceRoot)
        try createFixture(named: "Beta", in: sourceRoot)

        let recorder = BatchUpdateRecorder()
        let coordinator = BatchCoordinator()
        let configuration = makeConfiguration(
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            shouldCreateArchive: true
        )

        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let batchSnapshot = await recorder.lastBatchSnapshot()
        XCTAssertEqual(batchSnapshot?.state, .completed)

        let plans = await recorder.lastBatchProjects()
        XCTAssertTrue(plans.allSatisfy { $0.readyForDeletion })
        XCTAssertTrue(fileManager.fileExists(atPath: configuration.archiveRootURL.appendingPathComponent("Alpha.zip", isDirectory: false).path))
        XCTAssertTrue(fileManager.fileExists(atPath: configuration.archiveRootURL.appendingPathComponent("Beta.zip", isDirectory: false).path))
        XCTAssertTrue(plans.compactMap { $0.deletionManifestURL }.allSatisfy { fileManager.fileExists(atPath: $0.path) })
    }

    func testDefaultPrefetchCandidatesRespectTransferPolicyExclusions() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = workspace.appendingPathComponent("Alpha", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try fileManager.createDirectory(at: projectRoot.appendingPathComponent("src", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectRoot.appendingPathComponent("node_modules", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: projectRoot.appendingPathComponent(".venv", isDirectory: true), withIntermediateDirectories: true)
        try Data("DATABASE_URL=postgres://local".utf8).write(to: projectRoot.appendingPathComponent(".env", isDirectory: false))

        let candidates = BatchCoordinator.prefetchCandidateURLs(
            projectURL: projectRoot,
            transferPolicy: TransferPolicy(mode: .codingProject),
            childLimit: 8,
            fileManager: fileManager
        )

        let candidateNames = Set(candidates.map(\.lastPathComponent))
        XCTAssertTrue(candidateNames.contains("Alpha"))
        XCTAssertTrue(candidateNames.contains("src"))
        XCTAssertTrue(candidateNames.contains(".env"))
        XCTAssertFalse(candidateNames.contains("node_modules"))
        XCTAssertFalse(candidateNames.contains(".venv"))
    }

    func testPrefetchCandidatesTraverseNestedDirectoriesWithinBudget() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = workspace.appendingPathComponent("Alpha", isDirectory: true)
        let nested = projectRoot.appendingPathComponent("src/FeatureA", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try Data("hello".utf8).write(to: nested.appendingPathComponent("view.swift", isDirectory: false))

        let candidates = BatchCoordinator.prefetchCandidateURLs(
            projectURL: projectRoot,
            transferPolicy: .exactCopy,
            childLimit: 8,
            fileManager: fileManager
        )

        let rootPath = projectRoot.standardizedFileURL.path
        let relativePaths = Set(candidates.map { url in
            let candidatePath = url.standardizedFileURL.path
            if candidatePath == rootPath {
                return projectRoot.lastPathComponent
            }
            return candidatePath.replacingOccurrences(of: "\(rootPath)/", with: "")
        })
        XCTAssertTrue(relativePaths.contains("Alpha"))
        XCTAssertTrue(relativePaths.contains("src"))
        XCTAssertTrue(relativePaths.contains("src/FeatureA"))
        XCTAssertTrue(relativePaths.contains("src/FeatureA/view.swift"))
    }

    func testRunPrefetchesUpcomingProjectRoots() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(named: "Alpha", in: sourceRoot)
        try createFixture(named: "Beta", in: sourceRoot)
        try createFixture(named: "Gamma", in: sourceRoot)

        let prefetchRecorder = BatchPrefetchRecorder()
        let recorder = BatchUpdateRecorder()
        let coordinator = BatchCoordinator(projectPrefetcher: { url, _, _ in
            await prefetchRecorder.record(url)
        })
        var configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        configuration.projectPrefetchWindow = 2

        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let prefetchedNames = Set(await prefetchRecorder.paths().map { $0.lastPathComponent })

        XCTAssertEqual(prefetchedNames, Set(["Beta", "Gamma"]))
    }

    func testRunPrefetchesUpcomingProjectRootsAgainAfterResumeWithPersistedHint() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("BatchSource", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("BatchDestination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(named: "Alpha", in: sourceRoot)
        try createFixture(named: "Beta", in: sourceRoot)
        try createFixture(named: "Gamma", in: sourceRoot)

        var configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        configuration.projectPrefetchWindow = 2

        let persisted = PersistedBatchRun(
            snapshot: BatchSnapshot(
                batchID: configuration.batchID,
                state: .cancelled,
                sourceRootPath: sourceRoot.path,
                destinationRootPath: destinationRoot.path,
                suffix: configuration.suffix,
                totalProjects: 3,
                completedProjects: 0,
                warningProjects: 0,
                failedProjects: 0,
                conflictedProjects: 0,
                readyForDeletionProjects: 0,
                currentProjectIndex: 1,
                currentProjectName: "Alpha",
                startedAt: Date(timeIntervalSince1970: 10),
                finishedAt: Date(timeIntervalSince1970: 20),
                lastError: "Batch run cancelled."
            ),
            projects: [
                BatchProjectPlan(
                    id: UUID(),
                    sourceURL: sourceRoot.appendingPathComponent("Beta", isDirectory: true),
                    destinationRootURL: destinationRoot,
                    sourceFolderName: "Beta",
                    targetFolderName: "Beta-Lokal",
                    state: .pending,
                    detail: "Project directory warmup requested.",
                    archiveURL: nil,
                    deletionManifestURL: nil,
                    readyForDeletion: false,
                    startedAt: nil,
                    finishedAt: nil
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 21)
        )
        try writePersistedBatch(persisted, to: configuration.resumeStateURL)

        let prefetchRecorder = BatchPrefetchRecorder()
        let recorder = BatchUpdateRecorder()
        let coordinator = BatchCoordinator(projectPrefetcher: { url, _, _ in
            await prefetchRecorder.record(url)
        })

        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let prefetchedNames = Set(await prefetchRecorder.paths().map { $0.lastPathComponent })
        let plans = await recorder.lastBatchProjects()

        XCTAssertEqual(prefetchedNames, Set(["Beta", "Gamma"]))
        XCTAssertFalse(plans.first(where: { $0.sourceFolderName == "Beta" })?.detail?.contains("Project directory warmup requested.") ?? false)
    }

    private func makeConfiguration(
        sourceRoot: URL,
        destinationRoot: URL,
        shouldCreateArchive: Bool = false,
        orderingMode: BatchOrderingMode = .alphabetical
    ) -> BatchConfiguration {
        BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: sourceRoot,
            destinationRootURL: destinationRoot,
            orderingMode: orderingMode,
            suffix: "Lokal",
            transferPolicy: .exactCopy,
            priorityPolicy: TransferPriorityPolicy(mode: .criticalFirst),
            workerCount: 2,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0), .seconds(1)],
            maxHydrationWait: .seconds(30),
            shouldCreateArchive: shouldCreateArchive,
            enableFinderFallback: false
        )
    }

    private func createFixture(named name: String, in sourceRoot: URL) throws {
        let fileManager = FileManager.default
        let projectRoot = sourceRoot.appendingPathComponent(name, isDirectory: true)
        let backend = projectRoot.appendingPathComponent("backend", isDirectory: true)
        try fileManager.createDirectory(at: backend, withIntermediateDirectories: true)
        try Data("DATABASE_URL=postgres://local".utf8).write(to: projectRoot.appendingPathComponent(".env", isDirectory: false))
        try Data("print(\"hello\")".utf8).write(to: backend.appendingPathComponent("main.swift", isDirectory: false))
    }

    private func writePersistedBatch(_ persisted: PersistedBatchRun, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(persisted)
        try data.write(to: url, options: .atomic)
    }
}

private actor BatchPrefetchRecorder {
    private var recorded: [URL] = []

    func record(_ url: URL) {
        recorded.append(url)
    }

    func paths() -> [URL] {
        recorded
    }
}

private actor BatchUpdateRecorder {
    private var batchSnapshots: [BatchSnapshot] = []
    private var batchProjects: [[BatchProjectPlan]] = []

    func record(_ update: JobUpdate) {
        switch update {
        case .batchSnapshot(let snapshot):
            batchSnapshots.append(snapshot)
        case .batchProjects(let projects):
            batchProjects.append(projects)
        case .snapshot, .log, .failures, .activities:
            break
        }
    }

    func lastBatchSnapshot() -> BatchSnapshot? {
        batchSnapshots.last
    }

    func lastBatchProjects() -> [BatchProjectPlan] {
        batchProjects.last ?? []
    }
}
