import XCTest
@testable import iCloudMaterializer

final class HydrationPrimerTests: XCTestCase {
    func testReadPressureModeTouchesDirectoriesAndFiles() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = workspace.appendingPathComponent("Project", isDirectory: true)
        let nestedDirectory = projectRoot.appendingPathComponent("src", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("main.swift", isDirectory: false)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        try Data("print(\"hello\")".utf8).write(to: nestedFile)
        defer { try? fileManager.removeItem(at: workspace) }

        let report = try await HydrationPrimer.prime(
            candidates: [
                HydrationPrimingCandidate(url: nestedDirectory, relativePath: "src"),
                HydrationPrimingCandidate(url: nestedFile, relativePath: "src/main.swift")
            ],
            hydrationMode: .readPressureOnly,
            readPressureConcurrency: 2
        )

        XCTAssertEqual(report.requestedCount, 0)
        XCTAssertEqual(report.readPressureDirectoryCount, 1)
        XCTAssertEqual(report.readPressureFileCount, 1)
        XCTAssertEqual(report.readPressureFailureCount, 0)
    }

    func testPrimeProjectCapsReadPressureBreadthPerProject() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectRoot = workspace.appendingPathComponent("Project", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        for index in 0..<80 {
            let fileURL = projectRoot.appendingPathComponent("file-\(index).txt", isDirectory: false)
            try Data("hello-\(index)".utf8).write(to: fileURL)
        }

        let report = try await HydrationPrimer.primeProject(
            projectURL: projectRoot,
            transferPolicy: .exactCopy,
            scanDepth: 40,
            hydrationMode: .readPressureOnly,
            readPressureConcurrency: 4
        )

        XCTAssertEqual(report.requestedCount, 0)
        XCTAssertEqual(report.readPressureDirectoryCount, 1)
        XCTAssertEqual(report.readPressureFileCount, 48)
        XCTAssertEqual(report.readPressureFailureCount, 0)
        XCTAssertEqual(report.readPressureTimeoutCount, 0)
    }
}
