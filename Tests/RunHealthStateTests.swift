import XCTest
@testable import iCloudMaterializer

final class RunHealthStateTests: XCTestCase {
    func testEvaluateReturnsNilWhenNotRunning() {
        XCTAssertNil(RunHealthState.evaluate(isRunning: false, lastProgressAt: Date(), now: Date()))
    }

    func testEvaluateReportsActiveBeforeWatchThreshold() {
        let now = Date(timeIntervalSince1970: 200)
        let state = RunHealthState.evaluate(
            isRunning: true,
            lastProgressAt: Date(timeIntervalSince1970: 170),
            now: now
        )

        XCTAssertEqual(state?.level, .active)
        XCTAssertTrue(state?.message.contains("Last progress") == true)
    }

    func testEvaluateReportsWatchAfterWatchThreshold() {
        let now = Date(timeIntervalSince1970: 200)
        let state = RunHealthState.evaluate(
            isRunning: true,
            lastProgressAt: Date(timeIntervalSince1970: 90),
            now: now
        )

        XCTAssertEqual(state?.level, .watch)
        XCTAssertTrue(state?.message.contains("No progress") == true)
        XCTAssertTrue(state?.message.contains("normal") == true)
    }

    func testEvaluateReportsStalledAfterStallThreshold() {
        let now = Date(timeIntervalSince1970: 500)
        let state = RunHealthState.evaluate(
            isRunning: true,
            lastProgressAt: Date(timeIntervalSince1970: 100),
            now: now
        )

        XCTAssertEqual(state?.level, .stalled)
        XCTAssertTrue(state?.message.contains("stalled") == true)
    }
}
