import AppKit
@testable import FILLR
import XCTest

final class IconPreferencesTests: XCTestCase {
    @MainActor
    func testNewAndUnknownPreferencesUseCleanIcon() {
        let suite = "com.tlolabs.fillr.icon-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(FillrStore(defaults: defaults, startServices: false, iconResourceURL: nil).iconStyle, .clean)
        defaults.set("removed-design", forKey: DockIconStyle.preferenceKey)
        XCTAssertEqual(FillrStore(defaults: defaults, startServices: false, iconResourceURL: nil).iconStyle, .clean)
    }

    @MainActor
    func testEverySelectionPersistsAcrossRelaunch() throws {
        let suite = "com.tlolabs.fillr.icon-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let resources = try makeArtwork()
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: resources)
            NSApplication.shared.applicationIconImage = nil
        }
        // Existing classic preferences retain their stable identifier when the
        // new tribute design is introduced.
        defaults.set("classic", forKey: DockIconStyle.preferenceKey)
        let store = FillrStore(defaults: defaults, startServices: false, iconResourceURL: resources)
        XCTAssertEqual(store.iconStyle, .classic)
        for (style, savedValue) in [(DockIconStyle.macOS, "macOS"), (.clean, "clean"), (.classic, "classic")] {
            store.setIconStyle(style)
            XCTAssertEqual(store.iconStyle, style)
            XCTAssertEqual(defaults.string(forKey: DockIconStyle.preferenceKey), savedValue)
            let relaunched = FillrStore(defaults: defaults, startServices: false, iconResourceURL: resources)
            XCTAssertEqual(relaunched.iconStyle, style)
        }
    }

    @MainActor
    func testMissingAlternateDoesNotSaveBrokenChoice() {
        let suite = "com.tlolabs.fillr.icon-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FillrStore(defaults: defaults, startServices: false, iconResourceURL: nil)
        for style in [DockIconStyle.classic, .macOS] {
            store.setIconStyle(style)
            XCTAssertEqual(store.iconStyle, .clean)
            XCTAssertNil(defaults.string(forKey: DockIconStyle.preferenceKey))
            XCTAssertNotNil(store.alertMessage)
        }
    }

    // A tiny valid resource bundle exercises selection and persistence without
    // depending on an installed app or changing the user's real preferences.
    private func makeArtwork() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32)!
        pixel.setColor(.clear, atX: 0, y: 0)
        let png = pixel.representation(using: .png, properties: [:])!
        let names = ["01-housing", "02-inner-face", "03-bezel-edges", "04-status-scale",
                     "05-gauge-ticks", "06-gauge-labels", "07-fillr-label", "08-pump", "09-pivot", "10-needle"]
        for style in DockIconStyle.allCases {
            let directory = root.appendingPathComponent(style.resourceDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names { try png.write(to: directory.appendingPathComponent(name + ".png")) }
            try Data("{\"pivot\":[512,512],\"probePoint\":[400,500],\"sweepDegrees\":90,\"halfSweepDegrees\":45}".utf8)
                .write(to: directory.appendingPathComponent("artwork.json"))
        }
        return root
    }
}
