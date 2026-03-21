import XCTest
@testable import iCloudMaterializer

final class MaterializerCoordinatorTests: XCTestCase {
    func testCoordinatorCompletesAndVerifiesVisibleTargetForLocalTreeWithoutAutomaticZip() async throws {
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
        XCTAssertFalse(fileManager.fileExists(atPath: zipURL.path))

        let logMessages = await recorder.logMessages()
        XCTAssertTrue(logMessages.contains(where: { $0.contains("Verified visible target:") }))
        XCTAssertTrue(logMessages.contains(where: { $0.contains("Skipping automatic ZIP creation") }))
    }

    func testCoordinatorCreatesArchiveWhenExplicitlyEnabled() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("SourceProject", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(at: sourceRoot)
        let recorder = UpdateRecorder()
        let coordinator = MaterializerCoordinator()

        await coordinator.run(
            configuration: makeConfiguration(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                shouldCreateArchive: true
            ),
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let snapshot = await recorder.lastSnapshot()
        XCTAssertEqual(snapshot?.phase, .completed)

        let zipURL = sourceRoot.appendingPathComponent("\(sourceRoot.lastPathComponent).zip", isDirectory: false)
        XCTAssertTrue(fileManager.fileExists(atPath: zipURL.path))
        let zipSize = try XCTUnwrap((try fileManager.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.int64Value)
        XCTAssertGreaterThan(zipSize, 0)
    }

    func testCoordinatorFailsFastWhenPreflightBlocksRun() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("SourceProject", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(at: sourceRoot)
        let recorder = UpdateRecorder()
        let coordinator = MaterializerCoordinator()
        let preflightReport = PreflightReport(
            generatedAt: Date(),
            checks: [
                PreflightCheck(
                    id: "permissions",
                    title: "Review Privacy & Security permissions",
                    detail: "macOS access is still pending.",
                    state: .actionRequired,
                    isManual: true
                )
            ]
        )

        await coordinator.run(
            configuration: makeConfiguration(
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                preflightReport: preflightReport
            ),
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let snapshot = await recorder.lastSnapshot()
        XCTAssertEqual(snapshot?.phase, .failed)
        XCTAssertTrue(snapshot?.lastError?.contains("Preflight blocked") == true)
        XCTAssertFalse(fileManager.fileExists(atPath: destinationRoot.appendingPathComponent(sourceRoot.lastPathComponent, isDirectory: true).path))
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

    func testCoordinatorReusesPersistedDiscoveryInventoryOnRetry() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("SourceProject", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(at: sourceRoot)
        var configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        configuration.jobID = JobConfiguration.resumeJobID(
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            targetFolderName: nil,
            transferPolicy: configuration.transferPolicy
        )

        let persistedItems = try await ScanEngine().scan(sourceRoot: sourceRoot, transferPolicy: configuration.transferPolicy)
        let store = try JobStore(databaseURL: configuration.databaseURL)
        try await store.saveJobSnapshot(
            JobSnapshot(
                jobID: configuration.jobID,
                phase: .failed,
                phaseDetail: "Previous session ended during scan",
                sourcePath: sourceRoot.path,
                destinationPath: destinationRoot.path,
                currentPath: nil,
                totalDiscovered: persistedItems.count,
                totalDownloaded: 0,
                totalCopied: 0,
                totalFailed: 0,
                plannedChunks: 0,
                processedChunks: 0,
                estimatedRemainingCount: persistedItems.count,
                throughputItemsPerSecond: 0,
                throughputBytesPerSecond: 0,
                totalExpectedBytes: persistedItems.expectedBytes,
                copiedBytes: 0,
                activeWorkerCount: 0,
                estimatedRemainingSeconds: nil,
                preflightReport: nil,
                hydrationMetrics: HydrationMetrics(),
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 110),
                lastError: "Interrupted during scan"
            )
        )
        try await store.saveItems(jobID: configuration.jobID, items: persistedItems)
        try await store.close()

        let recorder = UpdateRecorder()
        let coordinator = MaterializerCoordinator()

        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let snapshot = await recorder.lastSnapshot()
        let logMessages = await recorder.logMessages()
        XCTAssertEqual(snapshot?.phase, .completed)
        XCTAssertTrue(logMessages.contains(where: { $0.contains("Resuming from persisted discovery inventory") }))

        let visibleTarget = destinationRoot.appendingPathComponent(sourceRoot.lastPathComponent, isDirectory: true)
        let verification = try await VerificationEngine().verify(expectedItems: persistedItems, at: visibleTarget)
        XCTAssertEqual(verification.verifiedCount, persistedItems.count)
    }

    func testCoordinatorDiscardsPersistedInventoryContainingInternalArtifacts() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("SourceProject", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try createFixture(at: sourceRoot)
        let archiveRoot = sourceRoot.appendingPathComponent("_Materializer_Archives", isDirectory: true)
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: archiveRoot.appendingPathComponent("fixture.zip"))

        var configuration = makeConfiguration(sourceRoot: sourceRoot, destinationRoot: destinationRoot)
        configuration.jobID = JobConfiguration.resumeJobID(
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            targetFolderName: nil,
            transferPolicy: configuration.transferPolicy
        )

        let expectedItems = try await ScanEngine().scan(sourceRoot: sourceRoot, transferPolicy: configuration.transferPolicy)
        var persistedItems = expectedItems
        persistedItems.append(
            ScannedItem(
                id: UUID(),
                relativePath: "_Materializer_Archives",
                kind: .directory,
                expectedSize: 0,
                isHidden: false,
                isUbiquitous: false,
                isLocalReady: true,
                downloadStatusRaw: nil,
                symlinkDestination: nil,
                hydrationState: .ready,
                hydrationError: nil,
                state: .pending,
                lastError: nil
            )
        )
        persistedItems.append(
            ScannedItem(
                id: UUID(),
                relativePath: "_Materializer_Archives/fixture.zip",
                kind: .file,
                expectedSize: 3,
                isHidden: false,
                isUbiquitous: false,
                isLocalReady: true,
                downloadStatusRaw: nil,
                symlinkDestination: nil,
                hydrationState: .ready,
                hydrationError: nil,
                state: .pending,
                lastError: nil
            )
        )

        let store = try JobStore(databaseURL: configuration.databaseURL)
        try await store.saveJobSnapshot(
            JobSnapshot(
                jobID: configuration.jobID,
                phase: .failed,
                phaseDetail: "Previous session ended during scan",
                sourcePath: sourceRoot.path,
                destinationPath: destinationRoot.path,
                currentPath: nil,
                totalDiscovered: persistedItems.count,
                totalDownloaded: 0,
                totalCopied: 0,
                totalFailed: 0,
                plannedChunks: 0,
                processedChunks: 0,
                estimatedRemainingCount: persistedItems.count,
                throughputItemsPerSecond: 0,
                throughputBytesPerSecond: 0,
                totalExpectedBytes: persistedItems.expectedBytes,
                copiedBytes: 0,
                activeWorkerCount: 0,
                estimatedRemainingSeconds: nil,
                preflightReport: nil,
                hydrationMetrics: HydrationMetrics(),
                startedAt: Date(timeIntervalSince1970: 100),
                finishedAt: Date(timeIntervalSince1970: 110),
                lastError: "Interrupted during scan"
            )
        )
        try await store.saveItems(jobID: configuration.jobID, items: persistedItems)
        try await store.close()

        let recorder = UpdateRecorder()
        let coordinator = MaterializerCoordinator()

        await coordinator.run(
            configuration: configuration,
            pauseController: PauseController()
        ) { update in
            await recorder.record(update)
        }

        let snapshot = await recorder.lastSnapshot()
        let logMessages = await recorder.logMessages()
        XCTAssertEqual(snapshot?.phase, .completed)
        XCTAssertTrue(logMessages.contains(where: { $0.contains("Discarding persisted discovery inventory because it contains internal rescue artifacts") }))
        XCTAssertFalse(logMessages.contains(where: { $0.contains("Resuming from persisted discovery inventory") }))

        let visibleTarget = destinationRoot.appendingPathComponent(sourceRoot.lastPathComponent, isDirectory: true)
        let verification = try await VerificationEngine().verify(expectedItems: expectedItems, at: visibleTarget)
        XCTAssertEqual(verification.verifiedCount, expectedItems.count)
        XCTAssertFalse(fileManager.fileExists(atPath: visibleTarget.appendingPathComponent("_Materializer_Archives", isDirectory: true).path))
    }

    private func makeConfiguration(
        sourceRoot: URL,
        destinationRoot: URL,
        shouldCreateArchive: Bool = false,
        preflightReport: PreflightReport? = nil
    ) -> JobConfiguration {
        JobConfiguration(
            jobID: UUID(),
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            preflightReport: preflightReport,
            transferPolicy: .exactCopy,
            priorityPolicy: .naturalOrder,
            workerCount: 2,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0), .seconds(1)],
            maxHydrationWait: .seconds(30),
            shouldCreateArchive: shouldCreateArchive,
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
