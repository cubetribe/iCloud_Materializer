import XCTest
@testable import iCloudMaterializer

final class MaterializerCoordinatorTests: XCTestCase {
    func testCoordinatorCompletesAndVerifiesVisibleTargetForLocalTree() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("SourceProject", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(at: sourceRoot)
        let expectedItems = try await ScanEngine().scan(sourceRoot: sourceRoot, transferPolicy: .exactCopy)
        let recorder = UpdateRecorder()
        let coordinator = MaterializerCoordinator()

        await coordinator.run(
            configuration: makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot),
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let snapshot = await recorder.lastSnapshot()
        XCTAssertEqual(snapshot?.phase, .completed)

        let visibleTarget = destinationRoot.appendingPathComponent(sourceRoot.lastPathComponent, isDirectory: true)
        let verification = try await VerificationEngine().verify(expectedItems: expectedItems, at: visibleTarget)
        XCTAssertEqual(verification.verifiedCount, expectedItems.count)

        let zipURL = sourceRoot.appendingPathComponent("\(sourceRoot.lastPathComponent).zip", isDirectory: false)
        XCTAssertTrue(fileManager.fileExists(atPath: zipURL.path))
        let zipSize = try XCTUnwrap((try fileManager.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(zipSize, 0)

        let logMessages = await recorder.logMessages()
        XCTAssertTrue(logMessages.contains(where: { $0.contains("Verified visible target:") }))
    }

    func testCoordinatorFailsIfVisibleTargetChangesAfterPromotion() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("SourceProject", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(at: sourceRoot)
        let recorder = UpdateRecorder()
        let coordinator = MaterializerCoordinator(postPromotionHook: { visibleTarget in
            let unexpectedURL = visibleTarget.appendingPathComponent("unexpected.txt", isDirectory: false)
            try Data("unexpected".utf8).write(to: unexpectedURL)
        })

        await coordinator.run(
            configuration: makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot),
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let snapshot = await recorder.lastSnapshot()
        XCTAssertEqual(snapshot?.phase, .failed)
        XCTAssertTrue(snapshot?.lastError?.contains("Unexpected item: unexpected.txt") == true)

        let zipURL = sourceRoot.appendingPathComponent("\(sourceRoot.lastPathComponent).zip", isDirectory: false)
        XCTAssertFalse(fileManager.fileExists(atPath: zipURL.path))
    }

    private func makeConfiguration(sourceRoot: URL, destinationRoot: URL) -> JobConfiguration {
        JobConfiguration(
            jobID: UUID(),
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            transferPolicy: .exactCopy,
            priorityPolicy: .naturalOrder,
            workerCount: 2,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0), .seconds(1)],
            maxHydrationWait: .seconds(30),
            allowTargetQuarantine: false,
            enableFinderFallback: false
        )
    }

    private func createFixture(at sourceRoot: URL) throws {
        let fileManager = FileManager.default
        let backend = sourceRoot.appendingPathComponent("backend", isDirectory: true)
        let frontend = sourceRoot.appendingPathComponent("frontend", isDirectory: true)
        try fileManager.createDirectory(at: backend, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: frontend, withIntermediateDirectories: true)

        try Data("DATABASE_URL=postgres://local".utf8).write(to: sourceRoot.appendingPathComponent(".env", isDirectory: false))
        try Data("print(\"hello\")".utf8).write(to: backend.appendingPathComponent("main.swift", isDirectory: false))
        try Data("{\"name\":\"fixture\"}".utf8).write(to: frontend.appendingPathComponent("package.json", isDirectory: false))
        try Data("*.build".utf8).write(to: sourceRoot.appendingPathComponent(".gitignore", isDirectory: false))
        try fileManager.createSymbolicLink(
            atPath: sourceRoot.appendingPathComponent("backend-link", isDirectory: false).path,
            withDestinationPath: "backend/main.swift"
        )
    }
}

private actor UpdateRecorder {
    private var snapshots: [JobSnapshot] = []
    private var logs: [LogEntry] = []

    func record(_ update: JobUpdate) {
        switch update {
        case .snapshot(let snapshot):
            snapshots.append(snapshot)
        case .log(let entry):
            logs.append(entry)
        case .failures, .activities, .batchSnapshot, .batchProjects:
            break
        }
    }

    func lastSnapshot() -> JobSnapshot? {
        snapshots.last
    }

    func logMessages() -> [String] {
        logs.map(\.message)
    }
}
