import XCTest
@testable import iCloudMaterializer

final class ScanEngineTests: XCTestCase {
    func testScanTopLevelWaitsUntilPausedRunIsResumed() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(at: root.appendingPathComponent("Alpha", isDirectory: true), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("Beta", isDirectory: true), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: root.appendingPathComponent("README.md"))

        let pauseController = PauseController()
        await pauseController.pause()
        let recorder = ScanItemRecorder()
        let engine = ScanEngine()

        let task = Task {
            try await engine.scanTopLevel(
                sourceRoot: root,
                transferPolicy: .exactCopy,
                pauseController: pauseController
            ) { item in
                await recorder.record(item.relativePath)
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        let countWhilePaused = await recorder.count()
        XCTAssertEqual(countWhilePaused, 0)

        await pauseController.resume()
        let items = try await task.value
        let finalCount = await recorder.count()

        XCTAssertEqual(items.map(\.relativePath), ["Alpha", "Beta", "README.md"])
        XCTAssertEqual(finalCount, 3)
    }

    func testScanSubtreeCancelsMidScanWhenPauseControllerIsCancelled() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = root.appendingPathComponent("Project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        for index in 0..<200 {
            let folder = projectRoot.appendingPathComponent("Folder\(index)", isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("payload-\(index)".utf8).write(to: folder.appendingPathComponent("file\(index).txt"))
        }

        let pauseController = PauseController()
        let recorder = ScanCancellationRecorder(cancelAfter: 6, pauseController: pauseController)
        let engine = ScanEngine()

        do {
            _ = try await engine.scanSubtree(
                sourceRoot: root,
                anchorRelativePath: "Project",
                transferPolicy: .exactCopy,
                pauseController: pauseController
            ) { item in
                await recorder.record(item.relativePath)
            }
            XCTFail("Expected scan cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let recordedCount = await recorder.count()
        XCTAssertGreaterThanOrEqual(recordedCount, 6)
        XCTAssertLessThan(recordedCount, 400)
    }
}

private actor ScanItemRecorder {
    private var items: [String] = []

    func record(_ path: String) {
        items.append(path)
    }

    func count() -> Int {
        items.count
    }
}

private actor ScanCancellationRecorder {
    private let cancelAfter: Int
    private let pauseController: PauseController
    private var recordedCount = 0
    private var didCancel = false

    init(cancelAfter: Int, pauseController: PauseController) {
        self.cancelAfter = cancelAfter
        self.pauseController = pauseController
    }

    func record(_ path: String) async {
        _ = path
        recordedCount += 1
        guard !didCancel, recordedCount >= cancelAfter else { return }
        didCancel = true
        await pauseController.cancel()
    }

    func count() -> Int {
        recordedCount
    }
}
