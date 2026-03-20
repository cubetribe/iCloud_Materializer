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
            sourcePath: "/tmp/source",
            destinationPath: "/tmp/destination",
            currentPath: "folder/file.txt",
            totalDiscovered: 10,
            totalDownloaded: 3,
            totalCopied: 4,
            totalFailed: 1,
            estimatedRemainingCount: 5,
            throughputItemsPerSecond: 2.5,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: nil,
            lastError: nil
        )

        try await store.saveJobSnapshot(snapshot)
        let loaded = try await store.loadSnapshot(jobID: snapshot.jobID)

        XCTAssertEqual(loaded?.phase, .copying)
        XCTAssertEqual(loaded?.sourcePath, "/tmp/source")
        XCTAssertEqual(loaded?.currentPath, "folder/file.txt")
        XCTAssertEqual(loaded?.totalDiscovered, 10)
        XCTAssertEqual(loaded?.throughputItemsPerSecond, 2.5)

        try await store.close()
        try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent())
    }
}
