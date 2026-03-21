import XCTest
@testable import iCloudMaterializer

final class PreflightEngineTests: XCTestCase {
    func testEvaluateBlocksRunUntilManualChecksAreConfirmed() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("Source", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let report = PreflightEngine().evaluate(
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            transferPolicy: .exactCopy,
            confirmations: []
        )

        XCTAssertFalse(report.canStart)
        XCTAssertEqual(
            Set(report.blockingChecks.map(\.id)),
            Set([
                PreflightEngine.syncThisMacCheckID,
                PreflightEngine.finderStatusCheckID,
                PreflightEngine.permissionsCheckID,
                PreflightEngine.thirdPartySyncCheckID
            ])
        )
    }

    func testEvaluateFlagsGitScanRiskUntilGitIsExplicitlyExcluded() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("Source", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("Destination", isDirectory: true)
        let gitObjects = sourceRoot.appendingPathComponent(".git/objects/aa", isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try fileManager.createDirectory(at: gitObjects, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let warningReport = PreflightEngine().evaluate(
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            transferPolicy: TransferPolicy(mode: .codingProject),
            confirmations: []
        )
        let warningCheck = try XCTUnwrap(warningReport.checks.first(where: { $0.id == "scan-risk-git" }))
        XCTAssertEqual(warningCheck.state, .warning)

        let excludedReport = PreflightEngine().evaluate(
            sourceURL: sourceRoot,
            destinationURL: destinationRoot,
            transferPolicy: TransferPolicy(mode: .codingProject, customExcludedDirectoryNames: [".git"]),
            confirmations: []
        )
        let excludedCheck = try XCTUnwrap(excludedReport.checks.first(where: { $0.id == "scan-risk-git" }))
        XCTAssertEqual(excludedCheck.state, .passed)
    }
}
