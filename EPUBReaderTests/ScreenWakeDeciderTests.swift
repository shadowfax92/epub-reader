import XCTest
@testable import EPUBReader

final class ScreenWakeDeciderTests: XCTestCase {

    func testDisablesIdleTimerWhenEnabledAndActive() {
        XCTAssertTrue(ScreenWakeDecider.shouldDisableIdleTimer(keepScreenAwake: true, isActive: true))
    }

    func testKeepsNormalLockWhenEnabledButNotActive() {
        XCTAssertFalse(ScreenWakeDecider.shouldDisableIdleTimer(keepScreenAwake: true, isActive: false))
    }

    func testKeepsNormalLockWhenDisabledWhileActive() {
        XCTAssertFalse(ScreenWakeDecider.shouldDisableIdleTimer(keepScreenAwake: false, isActive: true))
    }

    func testKeepsNormalLockWhenDisabledAndNotActive() {
        XCTAssertFalse(ScreenWakeDecider.shouldDisableIdleTimer(keepScreenAwake: false, isActive: false))
    }
}
