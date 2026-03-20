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
}
