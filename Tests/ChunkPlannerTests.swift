import XCTest
@testable import iCloudMaterializer

final class ChunkPlannerTests: XCTestCase {
    func testPlannerBatchesRootFiles() {
        let planner = ChunkPlanner(maxFileBatchSize: 500, maxItemsPerChunk: 5_000, maxExpectedBytesPerChunk: 2_000_000_000)
        let items = (0..<501).map { index in
            ScannedItem(
                id: UUID(),
                relativePath: "root-\(index).txt",
                kind: .file,
                expectedSize: 1,
                isHidden: false,
                isUbiquitous: false,
                isLocalReady: true,
                downloadStatusRaw: nil,
                symlinkDestination: nil,
                state: .pending,
                lastError: nil
            )
        }

        let chunks = planner.plan(items: items)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].kind, .fileBatch)
        XCTAssertEqual(chunks[0].relativePaths.count, 500)
        XCTAssertEqual(chunks[1].relativePaths.count, 1)
    }

    func testPlannerSplitsLargeDirectoryAcrossChildren() {
        let planner = ChunkPlanner(maxFileBatchSize: 500, maxItemsPerChunk: 5, maxExpectedBytesPerChunk: 100)
        var items: [ScannedItem] = [
            directory("workspace"),
            directory("workspace/alpha"),
            directory("workspace/beta")
        ]
        items += (0..<4).map { file("workspace/alpha/file-\($0).txt", size: 5) }
        items += (0..<4).map { file("workspace/beta/file-\($0).txt", size: 5) }

        let chunks = planner.plan(items: items)

        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.relativePaths.count <= 5 })
    }

    func testPlannerSplitsHydrationHeavyDirectoryBeforeItBecomesOneSlowChunk() {
        let planner = ChunkPlanner(
            maxFileBatchSize: 2,
            maxItemsPerChunk: 100,
            maxExpectedBytesPerChunk: 10_000,
            maxPendingHydrationsPerChunk: 2
        )
        var items: [ScannedItem] = [directory("workspace")]
        items += (0..<4).map { index in
            file(
                "workspace/file-\(index).txt",
                size: 1,
                isUbiquitous: true,
                isLocalReady: false
            )
        }

        let chunks = planner.plan(items: items)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.relativePaths.count <= 2 })
    }

    private func file(
        _ path: String,
        size: Int64,
        isUbiquitous: Bool = false,
        isLocalReady: Bool = true
    ) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .file,
            expectedSize: size,
            isHidden: false,
            isUbiquitous: isUbiquitous,
            isLocalReady: isLocalReady,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: isLocalReady ? .localReady : .pending,
            lastError: nil
        )
    }

    private func directory(_ path: String) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .directory,
            expectedSize: 0,
            isHidden: false,
            isUbiquitous: false,
            isLocalReady: true,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: .pending,
            lastError: nil
        )
    }
}
