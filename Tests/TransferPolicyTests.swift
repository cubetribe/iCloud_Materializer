import XCTest
@testable import iCloudMaterializer

final class TransferPolicyTests: XCTestCase {
    func testCodingProjectModeExcludesOnlyConservativeGeneratedArtifacts() {
        let policy = TransferPolicy(
            mode: .codingProject,
            customExcludedDirectoryNames: ["tmp_cache", "src"],
            customExcludedFileExtensions: ["sqlite", "swift"]
        )

        XCTAssertEqual(policy.scanDecision(relativePath: ".venv", kind: .directory), .excludeDescendants(reason: "Excluded generated directory .venv"))
        XCTAssertEqual(policy.scanDecision(relativePath: "node_modules", kind: .directory), .excludeDescendants(reason: "Excluded generated directory node_modules"))
        XCTAssertEqual(policy.scanDecision(relativePath: "cache/data.sqlite", kind: .file), .excludeItem(reason: "Excluded file extension .sqlite"))
        XCTAssertEqual(policy.scanDecision(relativePath: "Sources/App/main.swift", kind: .file), .include)
        XCTAssertTrue(policy.ignoredCustomRules.contains("Ignored custom directory exclusion: src"))
        XCTAssertTrue(policy.ignoredCustomRules.contains("Ignored custom extension exclusion: .swift"))
    }

    func testScanEngineSkipsExcludedTreesInCodingProjectMode() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceDir = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: sourceDir.appendingPathComponent("main.swift"))

        let venvDir = root.appendingPathComponent(".venv/lib/python3.12/site-packages", isDirectory: true)
        try fileManager.createDirectory(at: venvDir, withIntermediateDirectories: true)
        try Data("compiled".utf8).write(to: venvDir.appendingPathComponent("module.pyc"))

        let nodeModulesDir = root.appendingPathComponent("node_modules/react", isDirectory: true)
        try fileManager.createDirectory(at: nodeModulesDir, withIntermediateDirectories: true)
        try Data("react".utf8).write(to: nodeModulesDir.appendingPathComponent("index.js"))

        let policy = TransferPolicy(mode: .codingProject)
        let engine = ScanEngine()

        let items = try await engine.scan(sourceRoot: root, transferPolicy: policy)

        XCTAssertEqual(items.map(\.relativePath), ["Sources", "Sources/main.swift"])
    }
}
