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

        try await store.close()
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }
}
