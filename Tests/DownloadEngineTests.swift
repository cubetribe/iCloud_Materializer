import XCTest
@testable import iCloudMaterializer

final class DownloadEngineTests: XCTestCase {
    func testPollDelayStaysResponsiveEvenWhenBackoffScheduleIsLarge() {
        let engine = DownloadEngine()
        let schedule: [Duration] = [.seconds(0), .seconds(2), .seconds(5), .seconds(15)]

        XCTAssertEqual(engine.pollDelay(forAttempt: 0, schedule: schedule).timeInterval, 0.25, accuracy: 0.001)
        XCTAssertEqual(engine.pollDelay(forAttempt: 1, schedule: schedule).timeInterval, 2.0, accuracy: 0.001)
        XCTAssertEqual(engine.pollDelay(forAttempt: 2, schedule: schedule).timeInterval, 2.0, accuracy: 0.001)
        XCTAssertEqual(engine.pollDelay(forAttempt: 3, schedule: schedule).timeInterval, 2.0, accuracy: 0.001)
        XCTAssertEqual(engine.pollDelay(forAttempt: 99, schedule: schedule).timeInterval, 2.0, accuracy: 0.001)
    }

    func testPollDelayFallsBackToOneSecondWhenScheduleIsEmpty() {
        let engine = DownloadEngine()

        XCTAssertEqual(engine.pollDelay(forAttempt: 0, schedule: []).timeInterval, 1.0, accuracy: 0.001)
    }

    func testCoolingDelayUsesConfiguredScheduleAndClampsToMinimum() {
        let engine = DownloadEngine()
        let schedule: [Duration] = [.seconds(0), .seconds(30), .seconds(180)]

        XCTAssertEqual(engine.coolingDelay(forRestartCount: 0, schedule: schedule).timeInterval, 1.0, accuracy: 0.001)
        XCTAssertEqual(engine.coolingDelay(forRestartCount: 1, schedule: schedule).timeInterval, 30.0, accuracy: 0.001)
        XCTAssertEqual(engine.coolingDelay(forRestartCount: 99, schedule: schedule).timeInterval, 180.0, accuracy: 0.001)
    }

    func testJobConfigurationClampsSharedHydrationLookaheadToConservativeGlobalBudget() {
        let singleWorker = JobConfiguration(
            jobID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/source", isDirectory: true),
            destinationURL: URL(fileURLWithPath: "/tmp/destination", isDirectory: true),
            transferPolicy: .exactCopy,
            priorityPolicy: .naturalOrder,
            workerCount: 1,
            hydrationWindow: 4,
            retryCount: 1,
            backoffSchedule: [.seconds(0)],
            maxHydrationWait: .seconds(30),
            allowTargetQuarantine: false,
            enableFinderFallback: false
        )
        let multiWorker = JobConfiguration(
            jobID: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/source", isDirectory: true),
            destinationURL: URL(fileURLWithPath: "/tmp/destination", isDirectory: true),
            transferPolicy: .exactCopy,
            priorityPolicy: .naturalOrder,
            workerCount: 4,
            hydrationWindow: 12,
            retryCount: 1,
            backoffSchedule: [.seconds(0)],
            maxHydrationWait: .seconds(30),
            allowTargetQuarantine: false,
            enableFinderFallback: false
        )

        XCTAssertEqual(singleWorker.maxActiveHydrations, 4)
        XCTAssertEqual(singleWorker.effectiveHydrationPrefetchBuffer, 8)
        XCTAssertEqual(singleWorker.maxRequestedHydrations, 12)

        XCTAssertEqual(multiWorker.maxActiveHydrations, 48)
        XCTAssertEqual(multiWorker.effectiveHydrationPrefetchBuffer, 24)
        XCTAssertEqual(multiWorker.maxRequestedHydrations, 72)
    }

    func testHydrationSessionKeepsPrefetchBoundedButAllowsActivePromotion() async {
        final class RequestRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []

            func record(_ url: URL) {
                lock.lock()
                paths.append(url.lastPathComponent)
                lock.unlock()
            }

            func recordedPaths() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return paths
            }
        }

        let recorder = RequestRecorder()
        let session = HydrationSession(maxRequestedHydrations: 2) { url in
            recorder.record(url)
        }
        let targets = ["one", "two", "three"].map { name in
            HydrationTarget(
                relativePath: name,
                sourceURL: URL(fileURLWithPath: "/tmp/\(name)")
            )
        }

        await session.prefetch(targets: targets)

        let requestedAfterPrefetch = await session.requestedHydrationCount()
        let thirdIssuedBeforeActivation = await session.requestWasIssued(for: "three")
        XCTAssertEqual(requestedAfterPrefetch, 2)
        XCTAssertEqual(recorder.recordedPaths(), ["one", "two"])
        XCTAssertFalse(thirdIssuedBeforeActivation)

        await session.activate(target: targets[2])

        let requestedAfterActivation = await session.requestedHydrationCount()
        let thirdIssuedAfterActivation = await session.requestWasIssued(for: "three")
        XCTAssertEqual(requestedAfterActivation, 3)
        XCTAssertEqual(recorder.recordedPaths(), ["one", "two", "three"])
        XCTAssertTrue(thirdIssuedAfterActivation)

        await session.finishActive(path: "one", isReady: true)

        let requestedAfterReady = await session.requestedHydrationCount()
        let readyStateAfterFinish = await session.readyState(for: "one")
        XCTAssertEqual(requestedAfterReady, 2)
        XCTAssertTrue(readyStateAfterFinish)
    }

    func testHydrationSessionDoesNotReissueRequestForReadyPath() async {
        final class RequestRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []

            func record(_ url: URL) {
                lock.lock()
                paths.append(url.lastPathComponent)
                lock.unlock()
            }

            func recordedPaths() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return paths
            }
        }

        let recorder = RequestRecorder()
        let session = HydrationSession(maxRequestedHydrations: 4) { url in
            recorder.record(url)
        }
        let target = HydrationTarget(
            relativePath: "one",
            sourceURL: URL(fileURLWithPath: "/tmp/one")
        )

        await session.prefetch(targets: [target])
        await session.activate(target: target)
        await session.finishActive(path: "one", isReady: true)
        await session.prefetch(targets: [target])

        let requestedAfterReady = await session.requestedHydrationCount()
        let readyState = await session.readyState(for: "one")
        XCTAssertEqual(recorder.recordedPaths(), ["one"])
        XCTAssertEqual(requestedAfterReady, 0)
        XCTAssertTrue(readyState)
    }

    func testShouldCoolOnlyWhenSlotExpiredAndOtherWorkCanAdvance() {
        let engine = DownloadEngine()
        let now = Date()
        let item = ScannedItem(
            id: UUID(),
            relativePath: "workspace/file.txt",
            kind: .file,
            expectedSize: 1,
            isHidden: false,
            isUbiquitous: true,
            isLocalReady: false,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: .pending,
            lastError: nil
        )
        let active = ActiveHydration(
            item: item,
            sourceURL: URL(fileURLWithPath: "/tmp/workspace/file.txt"),
            firstRequestedAt: now.addingTimeInterval(-20),
            slotStartedAt: now.addingTimeInterval(-7),
            nextPollAt: now,
            pollAttempt: 0,
            restartCount: 0
        )

        XCTAssertTrue(engine.shouldCool(
            active: active,
            now: now,
            hasQueuedWork: true,
            otherInflightCount: 0,
            hotSlotDuration: .seconds(6)
        ))
        XCTAssertTrue(engine.shouldCool(
            active: active,
            now: now,
            hasQueuedWork: false,
            otherInflightCount: 1,
            hotSlotDuration: .seconds(6)
        ))
        XCTAssertFalse(engine.shouldCool(
            active: active,
            now: now,
            hasQueuedWork: false,
            otherInflightCount: 0,
            hotSlotDuration: .seconds(6)
        ))

        let freshActive = ActiveHydration(
            item: item,
            sourceURL: URL(fileURLWithPath: "/tmp/workspace/file.txt"),
            firstRequestedAt: now.addingTimeInterval(-20),
            slotStartedAt: now.addingTimeInterval(-2),
            nextPollAt: now,
            pollAttempt: 0,
            restartCount: 0
        )
        XCTAssertFalse(engine.shouldCool(
            active: freshActive,
            now: now,
            hasQueuedWork: true,
            otherInflightCount: 1,
            hotSlotDuration: .seconds(6)
        ))
    }
}

final class FinderRecoveryEngineTests: XCTestCase {
    func testRecoveryCopyStagesFilesAndSymlinksWithoutFinder() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("Source", isDirectory: true)
        let stageRoot = workspace.appendingPathComponent("Stage", isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }

        try fileManager.createDirectory(at: sourceRoot.appendingPathComponent("workspace", isDirectory: true), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: sourceRoot.appendingPathComponent("workspace/file.txt", isDirectory: false))
        try fileManager.createSymbolicLink(
            atPath: sourceRoot.appendingPathComponent("workspace/link.txt", isDirectory: false).path,
            withDestinationPath: "file.txt"
        )

        let items = [
            directory("workspace"),
            file("workspace/file.txt"),
            symlink("workspace/link.txt", destination: "file.txt")
        ]
        let engine = FinderRecoveryEngine()

        try await engine.recoverChunk(
            items: items,
            sourceRoot: sourceRoot,
            stageRoot: stageRoot,
            pauseController: PauseController()
        )

        let copiedFileURL = stageRoot.appendingPathComponent("workspace/file.txt", isDirectory: false)
        let copiedLinkURL = stageRoot.appendingPathComponent("workspace/link.txt", isDirectory: false)
        XCTAssertEqual(try String(contentsOf: copiedFileURL, encoding: .utf8), "hello")
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: copiedLinkURL.path), "file.txt")
    }

    func testRecoveryCopyCancelsProcessAndPreventsLateSideEffects() async throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceRoot = workspace.appendingPathComponent("Source", isDirectory: true)
        let stageRoot = workspace.appendingPathComponent("Stage", isDirectory: true)
        let markerURL = workspace.appendingPathComponent("late-marker.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: workspace) }

        try fileManager.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: sourceRoot.appendingPathComponent("payload.txt", isDirectory: false))

        let engine = FinderRecoveryEngine(
            processFactory: { _, _ in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", "sleep 5; printf late > \(Self.shellQuoted(markerURL.path))"]
                return process
            },
            pollIntervalNanoseconds: 50_000_000,
            terminationGraceNanoseconds: 100_000_000
        )
        let pauseController = PauseController()
        let recoveryItems = [file("payload.txt")]
        let task = Task {
            try await engine.recoverChunk(
                items: recoveryItems,
                sourceRoot: sourceRoot,
                stageRoot: stageRoot,
                pauseController: pauseController
            )
        }

        try await Task.sleep(nanoseconds: 200_000_000)
        await pauseController.cancel()

        do {
            try await task.value
            XCTFail("Expected recovery copy cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
    }

    private func file(_ path: String) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .file,
            expectedSize: 1,
            isHidden: false,
            isUbiquitous: false,
            isLocalReady: true,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: .localReady,
            lastError: nil
        )
    }

    private func directory(_ path: String) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .directory,
            expectedSize: 0,
            isHidden: false,
            isUbiquitous: false,
            isLocalReady: true,
            downloadStatusRaw: nil,
            symlinkDestination: nil,
            state: .localReady,
            lastError: nil
        )
    }

    private func symlink(_ path: String, destination: String) -> ScannedItem {
        ScannedItem(
            id: UUID(),
            relativePath: path,
            kind: .symlink,
            expectedSize: 0,
            isHidden: false,
            isUbiquitous: false,
            isLocalReady: true,
            downloadStatusRaw: nil,
            symlinkDestination: destination,
            state: .localReady,
            lastError: nil
        )
    }

    private static func shellQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
