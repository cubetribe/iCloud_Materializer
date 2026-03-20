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
        let alphaArchive = configuration.archiveRootURL.appendingPathComponent("Alpha.zip", isDirectory: false)
        let alphaManifest = configuration.deletionManifestRootURL.appendingPathComponent("Alpha.json", isDirectory: false)

        try fileManager.createDirectory(at: alphaTarget, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: alphaArchive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: alphaManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: alphaArchive)
        try Data("manifest".utf8).write(to: alphaManifest)

        let restoredProject = BatchProjectPlan(
            id: UUID(),
            sourceURL: sourceRoot.appendingPathComponent("Alpha", isDirectory: true),
            destinationRootURL: destinationRoot,
            sourceFolderName: "Alpha",
            targetFolderName: "Alpha-Lokal",
            state: .completed,
            detail: "Deletion manifest prepared.",
            archiveURL: alphaArchive,
            deletionManifestURL: alphaManifest,
            readyForDeletion: true,
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
        XCTAssertTrue(preview.projects.first?.readyForDeletion == true)
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
        let alphaArchive = configuration.archiveRootURL.appendingPathComponent("Alpha.zip", isDirectory: false)
        let alphaManifest = configuration.deletionManifestRootURL.appendingPathComponent("Alpha.json", isDirectory: false)

        try fileManager.createDirectory(at: alphaTarget, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: alphaArchive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: alphaManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("DATABASE_URL=postgres://local".utf8).write(to: alphaTarget.appendingPathComponent(".env", isDirectory: false))
        try Data("zip".utf8).write(to: alphaArchive)
        try Data("manifest".utf8).write(to: alphaManifest)

        let restoredProject = BatchProjectPlan(
            id: UUID(),
            sourceURL: sourceRoot.appendingPathComponent("Alpha", isDirectory: true),
            destinationRootURL: destinationRoot,
            sourceFolderName: "Alpha",
            targetFolderName: "Alpha-Lokal",
            state: .completed,
            detail: "Deletion manifest prepared.",
            archiveURL: alphaArchive,
            deletionManifestURL: alphaManifest,
            readyForDeletion: true,
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
        XCTAssertTrue(plans.allSatisfy { $0.readyForDeletion })
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Beta-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: configuration.archiveRootURL.appendingPathComponent("Alpha.zip", isDirectory: false).path))
        XCTAssertTrue(fileManager.fileExists(atPath: configuration.archiveRootURL.appendingPathComponent("Beta.zip", isDirectory: false).path))
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
        XCTAssertTrue(plans.allSatisfy { $0.readyForDeletion })
        XCTAssertTrue(plans.allSatisfy { $0.deletionManifestURL != nil })

        let archiveRoot = sourceRoot.appendingPathComponent("_Materializer_Archives", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Beta-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: archiveRoot.appendingPathComponent("Alpha.zip", isDirectory: false).path))
        XCTAssertTrue(fileManager.fileExists(atPath: archiveRoot.appendingPathComponent("Beta.zip", isDirectory: false).path))
        XCTAssertTrue(plans.compactMap { $0.deletionManifestURL }.allSatisfy { fileManager.fileExists(atPath: $0.path) })
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
        let coordinator = BatchCoordinator(projectPrefetcher: { url in
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

    private func makeConfiguration(sourceRoot: URL, destinationRoot: URL) -> BatchConfiguration {
        BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: sourceRoot,
            destinationRootURL: destinationRoot,
            suffix: "Lokal",
            transferPolicy: .exactCopy,
            priorityPolicy: TransferPriorityPolicy(mode: .criticalFirst),
            workerCount: 2,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0), .seconds(1)],
            maxHydrationWait: .seconds(30),
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
