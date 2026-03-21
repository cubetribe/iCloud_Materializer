import XCTest
@testable import iCloudMaterializer

final class VerificationEngineTests: XCTestCase {
    func testVerificationPassesAndIgnoresFinderArtifacts() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("hello.txt")
        try Data("hello".utf8).write(to: fileURL)
        let symlinkURL = root.appendingPathComponent("link")
        try fileManager.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: "folder/hello.txt")
        try Data().write(to: root.appendingPathComponent(".DS_Store"))

        let items = [
            ScannedItem(id: UUID(), relativePath: "folder", kind: .directory, expectedSize: 0, isHidden: false, isUbiquitous: false, isLocalReady: true, downloadStatusRaw: nil, symlinkDestination: nil, state: .copied, lastError: nil),
            ScannedItem(id: UUID(), relativePath: "folder/hello.txt", kind: .file, expectedSize: 5, isHidden: false, isUbiquitous: false, isLocalReady: true, downloadStatusRaw: nil, symlinkDestination: nil, state: .copied, lastError: nil),
            ScannedItem(id: UUID(), relativePath: "link", kind: .symlink, expectedSize: 0, isHidden: false, isUbiquitous: false, isLocalReady: true, downloadStatusRaw: nil, symlinkDestination: "folder/hello.txt", state: .copied, lastError: nil)
        ]

        let engine = VerificationEngine()
        let result = try await engine.verify(expectedItems: items, at: root)

        XCTAssertEqual(result.verifiedCount, 3)
        XCTAssertEqual(result.verifiedBytes, 5)
    }

    func testVerificationCanBeCancelledDuringProgressWalk() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        var items: [ScannedItem] = []
        for index in 0..<60 {
            let fileURL = root.appendingPathComponent("file\(index).txt", isDirectory: false)
            let contents = "payload-\(index)"
            try Data(contents.utf8).write(to: fileURL)
            items.append(
                ScannedItem(
                    id: UUID(),
                    relativePath: "file\(index).txt",
                    kind: .file,
                    expectedSize: Int64(contents.utf8.count),
                    isHidden: false,
                    isUbiquitous: false,
                    isLocalReady: true,
                    downloadStatusRaw: nil,
                    symlinkDestination: nil,
                    state: .copied,
                    lastError: nil
                )
            )
        }

        let pauseController = PauseController()
        let recorder = VerificationProgressRecorder(cancelAfter: 4, pauseController: pauseController)

        do {
            _ = try await VerificationEngine().verify(
                expectedItems: items,
                at: root,
                pauseController: pauseController
            ) { path in
                await recorder.record(path)
            }
            XCTFail("Expected verification cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let recordedCount = await recorder.count()
        XCTAssertGreaterThanOrEqual(recordedCount, 4)
        XCTAssertLessThan(recordedCount, items.count)
    }
}

private actor VerificationProgressRecorder {
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
