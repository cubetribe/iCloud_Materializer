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
