import XCTest
@testable import iCloudMaterializer

final class BatchNamingModeTests: XCTestCase {
    func testSuffixNamingAddsDefaultDash() {
        let configuration = makeConfiguration(mode: .suffix, value: "Lokal")
        XCTAssertEqual(configuration.targetFolderName(for: "Project"), "Project-Lokal")
    }

    func testPrefixNamingAddsTrailingDash() {
        let configuration = makeConfiguration(mode: .prefix, value: "Lokal")
        XCTAssertEqual(configuration.targetFolderName(for: "Project"), "Lokal-Project")
    }

    func testTemplateNamingUsesExplicitPlaceholder() {
        let configuration = makeConfiguration(mode: .template, value: "Archive-{name}-2026")
        XCTAssertEqual(configuration.targetFolderName(for: "Project"), "Archive-Project-2026")
    }

    func testTemplateNamingFallsBackToSuffixStyleWhenPlaceholderIsMissing() {
        let configuration = makeConfiguration(mode: .template, value: "Lokal")
        XCTAssertEqual(configuration.targetFolderName(for: "Project"), "Project-Lokal")
    }

    private func makeConfiguration(mode: BatchNamingMode, value: String) -> BatchConfiguration {
        BatchConfiguration(
            batchID: UUID(),
            sourceRootURL: URL(fileURLWithPath: "/tmp/source-root", isDirectory: true),
            destinationRootURL: URL(fileURLWithPath: "/tmp/destination-root", isDirectory: true),
            namingMode: mode,
            suffix: value,
            transferPolicy: .exactCopy,
            priorityPolicy: TransferPriorityPolicy(mode: .criticalFirst),
            workerCount: 2,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0)],
            maxHydrationWait: .seconds(1),
            enableFinderFallback: false
        )
    }
}
