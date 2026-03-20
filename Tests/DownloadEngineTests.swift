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
}
