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
        let plans = try coordinator.planProjects(configuration: BatchConfiguration(
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
        ))

        XCTAssertEqual(plans.map { $0.sourceFolderName }, ["Alpha", "Beta"])
        XCTAssertEqual(plans.map { $0.targetFolderName }, ["Alpha-Lokal", "Beta-Lokal"])
        XCTAssertEqual(plans.first?.state, .pending)
        XCTAssertEqual(plans.last?.state, .conflicted)
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
        let configuration = BatchConfiguration(
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
        XCTAssertTrue(plans.allSatisfy(\.readyForDeletion))
        XCTAssertTrue(plans.allSatisfy { $0.deletionManifestURL != nil })

        let archiveRoot = sourceRoot.appendingPathComponent("_Materializer_Archives", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Alpha-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent("Beta-Lokal", isDirectory: true).path))
        XCTAssertTrue(fileManager.fileExists(atPath: archiveRoot.appendingPathComponent("Alpha.zip", isDirectory: false).path))
        XCTAssertTrue(fileManager.fileExists(atPath: archiveRoot.appendingPathComponent("Beta.zip", isDirectory: false).path))
        XCTAssertTrue(plans.compactMap(\.deletionManifestURL).allSatisfy { fileManager.fileExists(atPath: $0.path) })
    }

    private func createFixture(named name: String, in sourceRoot: URL) throws {
        let fileManager = FileManager.default
        let projectRoot = sourceRoot.appendingPathComponent(name, isDirectory: true)
        let backend = projectRoot.appendingPathComponent("backend", isDirectory: true)
        try fileManager.createDirectory(at: backend, withIntermediateDirectories: true)
        try Data("DATABASE_URL=postgres://local".utf8).write(to: projectRoot.appendingPathComponent(".env", isDirectory: false))
        try Data("print(\"hello\")".utf8).write(to: backend.appendingPathComponent("main.swift", isDirectory: false))
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
