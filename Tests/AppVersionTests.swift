import XCTest
@testable import iCloudMaterializer

final class AppVersionTests: XCTestCase {
    func testParsesSemanticVersionFromRootFileContents() {
        let version = AppVersion(parsing: "1.2.3\n")

        XCTAssertEqual(version?.rawValue, "1.2.3")
    }

    func testRejectsInvalidSemanticVersion() {
        XCTAssertNil(AppVersion(parsing: "1.2"))
        XCTAssertNil(AppVersion(parsing: "1.2.beta"))
        XCTAssertNil(AppVersion(parsing: "version-1.2.3"))
    }

    func testMainBundleContainsSemanticVersionResource() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "VERSION", withExtension: nil))
        let contents = try String(contentsOf: url, encoding: .utf8)
        let version = try XCTUnwrap(AppVersion(parsing: contents))

        XCTAssertEqual(AppVersion.load(from: .main), version)
    }
}
