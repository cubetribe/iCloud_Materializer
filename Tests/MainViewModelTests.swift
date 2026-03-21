import XCTest
@testable import iCloudMaterializer

@MainActor
final class MainViewModelTests: XCTestCase {
    func testSwitchingToAggressiveRescueAppliesAggressiveDefaults() {
        let viewModel = MainViewModel()

        XCTAssertEqual(viewModel.rescueProfile, .conservative)
        XCTAssertEqual(viewModel.workerCount, RescueProfile.conservative.defaultWorkerCount)
        XCTAssertEqual(viewModel.hydrationWindow, RescueProfile.conservative.defaultHydrationWindow)
        XCTAssertEqual(viewModel.hydrationMode, RescueProfile.conservative.defaultHydrationMode)

        viewModel.rescueProfile = .aggressive

        XCTAssertEqual(viewModel.workerCount, RescueProfile.aggressive.defaultWorkerCount)
        XCTAssertEqual(viewModel.hydrationWindow, RescueProfile.aggressive.defaultHydrationWindow)
        XCTAssertEqual(viewModel.hydrationMode, RescueProfile.aggressive.defaultHydrationMode)
        XCTAssertEqual(viewModel.retryCount, RescueProfile.aggressive.defaultRetryCount)
        XCTAssertEqual(viewModel.workerRange, RescueProfile.aggressive.workerRange)
        XCTAssertEqual(viewModel.hydrationRange, RescueProfile.aggressive.hydrationRange)
        XCTAssertEqual(viewModel.currentHydrationPrefetchWindow, RescueProfile.aggressive.hydrationPrefetchWindow)
        XCTAssertEqual(viewModel.currentProjectPrefetchWindow, RescueProfile.aggressive.projectPrefetchWindow)
    }

    func testSwitchingBackToConservativeRestoresConservativeDefaults() {
        let viewModel = MainViewModel()
        viewModel.rescueProfile = .aggressive
        viewModel.workerCount = 12
        viewModel.hydrationWindow = 18
        viewModel.retryCount = 4

        viewModel.rescueProfile = .conservative

        XCTAssertEqual(viewModel.workerCount, RescueProfile.conservative.defaultWorkerCount)
        XCTAssertEqual(viewModel.hydrationWindow, RescueProfile.conservative.defaultHydrationWindow)
        XCTAssertEqual(viewModel.hydrationMode, RescueProfile.conservative.defaultHydrationMode)
        XCTAssertEqual(viewModel.retryCount, RescueProfile.conservative.defaultRetryCount)
        XCTAssertEqual(viewModel.currentHydrationPrefetchWindow, 0)
        XCTAssertEqual(viewModel.currentProjectPrefetchWindow, 0)
    }

    func testVisibleBatchProjectsShowsWindowAroundCurrentProjectForLargeQueues() {
        let viewModel = MainViewModel()
        viewModel.batchProjects = (0..<120).map(makeProject(index:))
        viewModel.batchSnapshot = BatchSnapshot(
            batchID: UUID(),
            state: .running,
            sourceRootPath: "/tmp/source",
            destinationRootPath: "/tmp/destination",
            suffix: "Suffix: -Lokal",
            totalProjects: 120,
            completedProjects: 38,
            warningProjects: 0,
            failedProjects: 0,
            conflictedProjects: 0,
            readyForDeletionProjects: 0,
            currentProjectIndex: 40,
            currentProjectName: "Project-39",
            startedAt: Date(),
            finishedAt: nil,
            lastError: nil
        )

        let visibleProjects = viewModel.visibleBatchProjects

        XCTAssertLessThan(visibleProjects.count, viewModel.batchProjects.count)
        XCTAssertTrue(visibleProjects.contains(where: { $0.sourceFolderName == "Project-39" }))
        XCTAssertTrue(visibleProjects.contains(where: { $0.sourceFolderName == "Project-0" }))
        XCTAssertTrue(visibleProjects.contains(where: { $0.sourceFolderName == "Project-119" }))
        XCTAssertEqual(viewModel.hiddenBatchProjectCount, viewModel.batchProjects.count - visibleProjects.count)
    }

    func testVisibleBatchProjectsKeepsSmallQueuesUntouched() {
        let viewModel = MainViewModel()
        viewModel.batchProjects = (0..<8).map(makeProject(index:))

        XCTAssertEqual(viewModel.visibleBatchProjects, viewModel.batchProjects)
        XCTAssertEqual(viewModel.hiddenBatchProjectCount, 0)
    }

    private func makeProject(index: Int) -> BatchProjectPlan {
        let sourceURL = URL(fileURLWithPath: "/tmp/source/Project-\(index)", isDirectory: true)
        return BatchProjectPlan(
            id: UUID(),
            sourceURL: sourceURL,
            destinationRootURL: URL(fileURLWithPath: "/tmp/destination", isDirectory: true),
            sourceFolderName: "Project-\(index)",
            targetFolderName: "Project-\(index)-Lokal",
            state: .pending,
            detail: nil,
            archiveURL: nil,
            deletionManifestURL: nil,
            readyForDeletion: false,
            startedAt: nil,
            finishedAt: nil
        )
    }
}
