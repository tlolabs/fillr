import Foundation
@testable import FILLR
import XCTest

final class SortSettingsTests: XCTestCase {
    func testUseAllClipsDefaultsOnForNewAndSavedLegacySettings() throws {
        XCTAssertTrue(SortSettings().use_all_clips)
        let legacy = Data(#"{"folder_count":3,"folder_prefix":"News","total_ms":90000}"#.utf8)
        let decoded = try JSONDecoder().decode(SortSettings.self, from: legacy)
        XCTAssertTrue(decoded.use_all_clips)
        XCTAssertEqual(decoded.folder_count, 3)
        XCTAssertEqual(decoded.folder_prefix, "News")
        XCTAssertEqual(decoded.total_ms, 90_000)
    }

    func testExplicitOptOutSurvivesRoundTrip() throws {
        let settings = SortSettings(folder_count: 2, folder_prefix: "Comp", total_ms: 120_000,
            use_all_clips: false)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(SortSettings.self, from: data), settings)
        XCTAssertFalse(try JSONDecoder().decode(SortSettings.self, from: data).use_all_clips)
    }

}
