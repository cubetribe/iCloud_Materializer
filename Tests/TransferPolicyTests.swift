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

    func testCodingProjectModeAllowsExplicitGitExclusion() {
        let policy = TransferPolicy(
            mode: .codingProject,
            customExcludedDirectoryNames: [".git"]
        )

        XCTAssertEqual(
            policy.scanDecision(relativePath: ".git", kind: .directory),
            .excludeDescendants(reason: "Excluded generated directory .git")
        )
        XCTAssertFalse(policy.ignoredCustomRules.contains(where: { $0.contains(".git") }))
    }

    func testExactCopyModeStillExcludesInternalRescueArtifacts() {
        let policy = TransferPolicy(mode: .exactCopy)

        XCTAssertEqual(
            policy.scanDecision(relativePath: "_Materializer_Archives", kind: .directory),
            .excludeDescendants(reason: "Excluded internal rescue directory _Materializer_Archives")
        )
        XCTAssertEqual(
            policy.scanDecision(relativePath: "_Materializer_Archives/project.zip", kind: .file),
            .excludeItem(reason: "Excluded internal rescue artifact _Materializer_Archives")
        )
        XCTAssertEqual(
            policy.scanDecision(relativePath: ".icloud-materializer/job/state.sqlite", kind: .file),
            .excludeItem(reason: "Excluded internal rescue artifact .icloud-materializer")
        )
        XCTAssertEqual(policy.scanDecision(relativePath: "Sources/main.swift", kind: .file), .include)
    }

    func testScanEngineSkipsInternalRescueArtifactsInExactCopyMode() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let sourceDir = root.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try Data("print(1)".utf8).write(to: sourceDir.appendingPathComponent("main.swift"))

        let archiveRoot = root.appendingPathComponent("_Materializer_Archives", isDirectory: true)
        try fileManager.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try Data("zip".utf8).write(to: archiveRoot.appendingPathComponent("project.zip"))

        let runtimeRoot = root.appendingPathComponent(".icloud-materializer/job", isDirectory: true)
        try fileManager.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: runtimeRoot.appendingPathComponent("state.sqlite"))

        let policy = TransferPolicy(mode: .exactCopy)
        let engine = ScanEngine()

        let items = try await engine.scan(sourceRoot: root, transferPolicy: policy)

        XCTAssertEqual(items.map(\.relativePath), ["Sources", "Sources/main.swift"])
    }
}
