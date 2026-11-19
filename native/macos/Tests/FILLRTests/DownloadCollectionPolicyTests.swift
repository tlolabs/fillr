import Foundation
@testable import FILLR
import XCTest

final class DownloadCollectionPolicyTests: XCTestCase {
    func testSavedMPEGOnlyPolicyAllowsConvertedCopiesWithoutDeletingRejectedOutputs() {
        var original = MediaPolicy()
        original.allowed_extensions = ["mpg"]
        original.allowed_containers = ["mpeg"]
        original.allowed_codecs = ["mpeg2video"]
        let effective = original.proResCollectionPolicy
        XCTAssertTrue(effective.allowed_extensions.contains("mov"))
        XCTAssertTrue(effective.allowed_containers.contains("mov"))
        XCTAssertTrue(effective.allowed_codecs.contains("prores"))
        XCTAssertFalse(effective.delete_rejected)
        XCTAssertEqual(effective.scan_type, original.scan_type)
        XCTAssertEqual(effective.frame_rate, original.frame_rate)
        XCTAssertEqual(original.allowed_extensions, ["mpg"], "Do not overwrite the user's saved policy")
        XCTAssertTrue(original.delete_rejected)
    }

    func testAllowAnyListsRemainUnrestricted() {
        var original = MediaPolicy()
        original.allowed_extensions = []
        original.allowed_containers = []
        original.allowed_codecs = []
        let effective = original.proResCollectionPolicy
        XCTAssertTrue(effective.allowed_extensions.isEmpty)
        XCTAssertTrue(effective.allowed_containers.isEmpty)
        XCTAssertTrue(effective.allowed_codecs.isEmpty)
    }

    func testDownloadProgressPolicyCountsConvertibleMPEGsAndPreservesVideoProfile() {
        var original = MediaPolicy()
        original.allowed_extensions = ["mov"]
        original.allowed_containers = ["mov"]
        original.allowed_codecs = ["prores"]
        let progress = original.downloadProgressPolicy
        XCTAssertFalse(progress.delete_rejected)
        XCTAssertEqual(progress.allowed_extensions, ["mpg", "mpeg", "m2v"])
        XCTAssertTrue(progress.allowed_containers.isEmpty)
        XCTAssertEqual(progress.allowed_codecs, ["mpeg2video", "prores"])
        XCTAssertEqual(progress.enabled, original.enabled)
        XCTAssertEqual(progress.required_width, original.required_width)
        XCTAssertEqual(progress.required_height, original.required_height)
        XCTAssertEqual(progress.television_standard, original.television_standard)
        XCTAssertEqual(progress.frame_rate, original.frame_rate)
        XCTAssertEqual(progress.scan_type, original.scan_type)
        XCTAssertEqual(progress.orientation, original.orientation)
        XCTAssertEqual(progress.display_aspect_ratio, original.display_aspect_ratio)
        XCTAssertEqual(original.allowed_extensions, ["mov"])
        XCTAssertTrue(original.delete_rejected)
    }

    func testDisabledMediaFilteringStillRequiresConvertibleSources() {
        var original = MediaPolicy()
        original.enabled = false
        let progress = original.downloadProgressPolicy
        XCTAssertTrue(progress.enabled)
        XCTAssertFalse(progress.delete_rejected)
        XCTAssertEqual(progress.allowed_extensions, ["mpg", "mpeg", "m2v"])
        XCTAssertEqual(progress.allowed_codecs, ["mpeg2video", "prores"])
        XCTAssertNil(progress.required_width)
        XCTAssertNil(progress.required_height)
        XCTAssertEqual(progress.television_standard, "any")
        XCTAssertNil(progress.frame_rate)
        XCTAssertEqual(progress.scan_type, "any")
        XCTAssertEqual(progress.orientation, "any")
        XCTAssertNil(progress.display_aspect_ratio)
        XCTAssertFalse(original.enabled)
    }
}
