import XCTest
@testable import UpdatePolicy

final class UpdatePolicyTests: XCTestCase {
    private func accepts(_ version: String, current: String = "1.9.0", url: String? = nil,
                         display: String? = nil, type: String = "application") -> Bool {
        UpdatePolicy.accepts(current: current, proposed: version, displayed: display ?? version,
            url: URL(string: url ?? "https://github.com/tlolabs/fillr/releases/download/v\(version)/FILLR-\(version)-macos-universal.zip"),
            installationType: type)
    }
    func testStableNewerUsesNumericComparison() { XCTAssertTrue(accepts("1.10.0")) }
    func testSameAndDowngradeRejected() {
        XCTAssertFalse(accepts("1.9.0")); XCTAssertFalse(accepts("1.8.9"))
    }
    func testMalformedAndPrereleaseVersionsRejected() {
        for value in ["1.10", "01.10.0", "1.10.0-beta.1", "1.10.0+build", "1.10.0\n", "1.10.65536"] {
            XCTAssertFalse(accepts(value))
        }
    }
    func testOtherApplicationPlatformArchitectureAndEndpointRejected() {
        for filename in ["OTHER-1.10.0-macos-universal.zip", "FILLR-1.10.0-windows-x64.msix", "FILLR-1.10.0-macos-x86_64.zip"] {
            XCTAssertFalse(accepts("1.10.0", url: "https://github.com/tlolabs/fillr/releases/download/v1.10.0/\(filename)"))
        }
        XCTAssertFalse(accepts("1.10.0", url: "https://example.org/update.zip"))
        XCTAssertFalse(accepts("1.10.0", display: "2.0.0"))
        XCTAssertFalse(accepts("1.10.0", type: "package"))
    }
    func testActiveAndUnsavedWorkBlocksInstallation() {
        XCTAssertTrue(UpdatePolicy.canInstall(building: false, openEditors: 0))
        XCTAssertFalse(UpdatePolicy.canInstall(building: true, openEditors: 0))
        XCTAssertFalse(UpdatePolicy.canInstall(building: false, openEditors: 1))
        XCTAssertFalse(UpdatePolicy.canInstall(building: true, openEditors: 2))
    }
}
