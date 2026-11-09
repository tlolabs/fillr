import AppKit
@testable import FILLR
import SwiftUI
import XCTest

final class IconProgressTests: XCTestCase {
    func testNamesRetainExistingSavedIdentifiers() {
        XCTAssertEqual(DockIconStyle.allCases.map(\.title), ["DMC-12", "Gradient", "6 Colors"])
        XCTAssertEqual(DockIconStyle.allCases.map(\.rawValue), ["clean", "classic", "macOS"])
    }

    func testProgressPalettesMatchTheIconArtworkSource() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let data = try Data(contentsOf: repository.appendingPathComponent("assets/icons/status-scale-palettes.json"))
        let source = try JSONDecoder().decode(ArtworkPalettes.self, from: data)
        XCTAssertEqual(IconProgressPalette.transitionWidth, source.transitionWidth)
        for (style, key) in [(DockIconStyle.classic, "Classic"), (.macOS, "MacOS")] {
            let names = try XCTUnwrap(source.scales[key]?.bands)
            let expected = try names.map { name in
                try XCTUnwrap(source.colors[name].flatMap { UInt32($0.dropFirst(), radix: 16) })
            }
            XCTAssertEqual(IconProgressPalette(style: style).bands, expected)
        }
        XCTAssertEqual(IconProgressPalette(style: .clean).bands, [0x61BB46])
    }

    @MainActor
    func testPartialProgressRevealsTheSameColorsAsTheFullTrack() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Progress rendering requires an available desktop display") }
        for style in [DockIconStyle.classic, .macOS] {
            let full = try await render(style: style, value: 100, total: 100)
            let partial = try await render(style: style, value: 25, total: 100)
            let empty = try await render(style: style, value: 0, total: 0)
            let overflow = try await render(style: style, value: UInt64.max, total: 100)
            // At x=18% both bars have collected footage. Their colors must be
            // identical: the full icon palette must not be squeezed into 25%.
            assertColorsEqual(try color(full, x: 43), try color(partial, x: 43))
            assertColorsEqual(try color(full, x: 210), try color(overflow, x: 210))
            assertColorsEqual(try color(empty, x: 210), try color(partial, x: 210))
            let collectedEnd = try color(full, x: 210)
            let trackEnd = try color(partial, x: 210)
            XCTAssertGreaterThan(abs(collectedEnd.greenComponent - trackEnd.greenComponent)
                + abs(collectedEnd.redComponent - trackEnd.redComponent)
                + abs(collectedEnd.blueComponent - trackEnd.blueComponent), 0.1)
        }
    }

    @MainActor
    private func render(style: DockIconStyle, value: UInt64, total: UInt64) async throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: IconProgressView(value: value, total: total, style: style)
            .frame(width: 240, height: 16))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 16),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        await Task.yield()
        try? await Task.sleep(nanoseconds: 40_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func color(_ bitmap: NSBitmapImageRep, x: Int) throws -> NSColor {
        // Retina captures may have two bitmap pixels per point.
        let scale = bitmap.pixelsWide / 240
        return try XCTUnwrap(bitmap.colorAt(x: x * scale, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
    }

    private func assertColorsEqual(_ first: NSColor, _ second: NSColor,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(first.redComponent, second.redComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(first.greenComponent, second.greenComponent, accuracy: 0.02, file: file, line: line)
        XCTAssertEqual(first.blueComponent, second.blueComponent, accuracy: 0.02, file: file, line: line)
    }

    private struct ArtworkPalettes: Decodable {
        let colors: [String: String]
        let transitionWidth: Double
        let scales: [String: Scale]
        struct Scale: Decodable { let bands: [String] }
    }
}
