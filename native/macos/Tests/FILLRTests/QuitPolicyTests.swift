import XCTest
@testable import FILLR

final class QuitPolicyTests: XCTestCase {
    func testSettingsDraftCanBeDiscardedByDeliberateQuit() {
        XCTAssertEqual(QuitPolicy.decision(building: false, openEditors: 1, confirmed: false), .confirm)
        XCTAssertEqual(QuitPolicy.decision(building: false, openEditors: 1, confirmed: true), .quitNow)
    }

    func testDeliberateQuitNeverInterruptsAnActiveFolderBuild() {
        XCTAssertEqual(QuitPolicy.decision(building: true, openEditors: 0, confirmed: false), .confirm)
        XCTAssertEqual(QuitPolicy.decision(building: true, openEditors: 0, confirmed: true), .waitForBuild)
        XCTAssertEqual(QuitPolicy.decision(building: true, openEditors: 2, confirmed: true), .waitForBuild)
        XCTAssertEqual(QuitPolicy.decision(building: false, openEditors: 2, confirmed: true), .quitNow)
    }

    func testOrdinaryQuitIsAllowedWithoutASettingsDraftOrBuild() {
        XCTAssertEqual(QuitPolicy.decision(building: false, openEditors: 0, confirmed: false), .quitNow)
    }

    func testHoldRequiresTheFullIntervalAndClampsProgress() {
        let hold = QuitHold(startedAt: 50)
        XCTAssertEqual(hold.progress(at: 49), 0)
        XCTAssertEqual(hold.progress(at: 50), 0)
        XCTAssertLessThan(hold.progress(at: 51), 1)
        XCTAssertEqual(hold.progress(at: 50 + QuitHold.duration), 1)
        XCTAssertEqual(hold.progress(at: 100), 1)
    }
}
