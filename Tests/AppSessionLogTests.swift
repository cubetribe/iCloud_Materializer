import XCTest
@testable import iCloudMaterializer

final class AppSessionLogTests: XCTestCase {
    func testSessionLogCreatesSessionAndLatestFiles() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let logger = AppSessionLog(
            fileManager: fileManager,
            baseDirectoryURL: workspace,
            sessionDate: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(fileManager.fileExists(atPath: logger.sessionLogURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: logger.latestLogURL.path))
    }

    func testSessionLogAppendsStructuredJsonLinesToBothFiles() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let logger = AppSessionLog(
            fileManager: fileManager,
            baseDirectoryURL: workspace,
            sessionDate: Date(timeIntervalSince1970: 0)
        )
        logger.append(level: .error, category: "test", message: "Hydration failed", path: "/tmp/source")

        let sessionContents = try String(contentsOf: logger.sessionLogURL, encoding: .utf8)
        let latestContents = try String(contentsOf: logger.latestLogURL, encoding: .utf8)

        XCTAssertTrue(sessionContents.contains("\"category\":\"test\""))
        XCTAssertTrue(sessionContents.contains("\"message\":\"Hydration failed\""))
        XCTAssertTrue(sessionContents.contains("\"level\":\"error\""))
        XCTAssertTrue(latestContents.contains("\"message\":\"Hydration failed\""))
    }
}
