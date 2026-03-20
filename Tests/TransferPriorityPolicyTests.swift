import XCTest
@testable import iCloudMaterializer

final class TransferPriorityPolicyTests: XCTestCase {
    func testCriticalFirstClassifiesEnvironmentCodeAndReports() {
        let policy = TransferPriorityPolicy(mode: .criticalFirst)

        XCTAssertEqual(policy.priority(relativePath: ".env.production", kind: .file), .critical)
        XCTAssertEqual(policy.priority(relativePath: "Sources/App/main.swift", kind: .file), .high)
        XCTAssertEqual(policy.priority(relativePath: "reports/daily/agent-report.json", kind: .file), .deferred)
        XCTAssertEqual(policy.priority(relativePath: "README.md", kind: .file), .standard)
    }

    func testChunkPlannerPrioritizesCriticalThenCoreCodeThenReports() {
        let planner = ChunkPlanner(maxFileBatchSize: 1, maxItemsPerChunk: 10, maxExpectedBytesPerChunk: 1_000)
        let policy = TransferPriorityPolicy(mode: .criticalFirst)
        let items = [
            file(".env"),
            directory("reports"),
            file("reports/agent-report.json"),
            directory("src"),
            file("src/main.py")
        ]

        let chunks = planner.plan(items: items, priorityPolicy: policy)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].relativePaths, [".env"])
        XCTAssertEqual(chunks[1].anchorRelativePath, "src")
        XCTAssertEqual(chunks[2].anchorRelativePath, "reports")
    }

    private func file(_ path: String) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .file,
            expectedSize: 1,
            isHidden: path.hasPrefix("."),
            isUbiquitous: false,
            isLocalReady: true,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: .pending,
            lastError: nil
        )
    }

    private func directory(_ path: String) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .directory,
            expectedSize: 0,
            isHidden: path.hasPrefix("."),
            isUbiquitous: false,
            isLocalReady: true,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: .pending,
            lastError: nil
        )
    }
}
