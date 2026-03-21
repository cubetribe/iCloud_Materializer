import XCTest
@testable import iCloudMaterializer

final class JobStoreTests: XCTestCase {
    func testSaveAndLoadSnapshot() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.sqlite")

        let store = try JobStore(databaseURL: databaseURL)
        let snapshot = JobSnapshot(
            jobID: UUID(),
            phase: .copying,
            phaseDetail: "Copying into staging",
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            currentPath: "folder/file.txt",
            totalDiscovered: 10,
            totalDownloaded: 3,
            totalCopied: 4,
            totalFailed: 1,
            plannedChunks: 8,
            processedChunks: 3,
            estimatedRemainingCount: 5,
            throughputItemsPerSecond: 2.5,
            throughputBytesPerSecond: 2048,
            totalExpectedBytes: 10_000,
            copiedBytes: 4_096,
            activeWorkerCount: 2,
            estimatedRemainingSeconds: 12,
            preflightReport: PreflightReport(
                generatedAt: Date(timeIntervalSince1970: 90),
                checks: [
                    PreflightCheck(
                        id: "destination-writable",
                        title: "Destination is writable",
                        detail: "/tmp/destination",
                        state: .passed
                    )
                ]
            ),
            hydrationMetrics: HydrationMetrics(
                requestAttemptCount: 4,
                requestFailureCount: 1,
                queuedCount: 1,
                downloadingCount: 1,
                stalledCount: 0,
                readyCount: 2,
                timeToFirstDiscoveredSeconds: 0.4,
                timeToFirstHydrationRequestSeconds: 0.9,
                timeToFirstReadySeconds: 1.5,
                timeToFirstCopiedSeconds: 2.0,
                timeToFirstVerifiedChunkSeconds: 2.8
            ),
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            lastError: nil
        )

        try await store.saveJobSnapshot(snapshot)
        let loaded = try await store.loadSnapshot(jobID: snapshot.jobID)

        XCTAssertEqual(loaded?.phase, .copying)
        XCTAssertEqual(loaded?.phaseDetail, "Copying into staging")
        XCTAssertEqual(loaded?.sourcePath, "/tmp/source")
        XCTAssertEqual(loaded?.currentPath, "folder/file.txt")
        XCTAssertEqual(loaded?.totalDiscovered, 10)
        XCTAssertEqual(loaded?.plannedChunks, 8)
        XCTAssertEqual(loaded?.processedChunks, 3)
        XCTAssertEqual(loaded?.throughputItemsPerSecond, 2.5)
        XCTAssertEqual(loaded?.throughputBytesPerSecond, 2048)
        XCTAssertEqual(loaded?.totalExpectedBytes, 10_000)
        XCTAssertEqual(loaded?.copiedBytes, 4_096)
        XCTAssertEqual(loaded?.activeWorkerCount, 2)
        XCTAssertEqual(loaded?.estimatedRemainingSeconds, 12)
        XCTAssertEqual(loaded?.preflightReport?.checks.count, 1)
        XCTAssertEqual(loaded?.hydrationMetrics.requestAttemptCount, 4)
        XCTAssertEqual(loaded?.hydrationMetrics.readyCount, 2)
        XCTAssertEqual(loaded?.hydrationMetrics.timeToFirstVerifiedChunkSeconds, 2.8)

        try await store.close()
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }

    func testSaveAndLoadItemsRoundTripsHydrationState() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.sqlite")

        let store = try JobStore(databaseURL: databaseURL)
        let jobID = UUID()
        let items = [
            ScannedItem(
                id: UUID(),
                relativePath: "project/file.txt",
                kind: .file,
                expectedSize: 42,
                isHidden: false,
                isUbiquitous: true,
                isLocalReady: false,
                downloadStatusRaw: "notDownloaded",
                symlinkDestination: nil,
                hydrationState: .requestFailed,
                hydrationError: "Request denied",
                state: .pending,
                lastError: nil
            )
        ]

        try await store.saveItems(jobID: jobID, items: items)
        let loaded = try await store.loadItems(jobID: jobID)

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.hydrationState, .requestFailed)
        XCTAssertEqual(loaded.first?.hydrationError, "Request denied")

        try await store.close()
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }
}
