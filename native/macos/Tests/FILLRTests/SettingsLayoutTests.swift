import AppKit
@testable import FILLR
import SwiftUI
import XCTest

final class SettingsLayoutTests: XCTestCase {
    @MainActor
    func testTimeInputsAndIconChoicesFitTheSettingsWindow() async throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("Settings rendering requires an available desktop display") }
        let suite = "com.tlolabs.fillr.settings-layout-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let resources = repository.appendingPathComponent("assets/icons")
        let store = FillrStore(defaults: defaults, startServices: false, iconResourceURL: resources)

        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let host = NSHostingView(rootView: MediaPreferencesView(store: store)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: name)
            window.contentView = host
            window.setContentSize(NSSize(width: 620, height: 640))
            defer { window.close() }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 80_000_000)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()

            if let output = ProcessInfo.processInfo.environment["FILLR_SETTINGS_QA_DIR"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent("settings-\(name.rawValue).png"))
            }
            func nativeFields(_ view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(nativeFields)
            }
            let fields = nativeFields(host)
            XCTAssertLessThanOrEqual(host.fittingSize.width, 620, "Settings must not request a wider window")
            for unit in ["Hours", "Minutes", "Seconds"] {
                let field = try XCTUnwrap(fields.first { $0.placeholderString == unit },
                                          "Missing editable \(unit) field in \(name)")
                XCTAssertTrue(field.isEditable)
                XCTAssertTrue(field.acceptsFirstResponder)
                XCTAssertGreaterThanOrEqual(field.frame.width, 64, "The \(unit) input must remain usable")
                XCTAssertGreaterThanOrEqual(field.frame.height, 20)
                XCTAssertTrue(host.bounds.contains(field.convert(field.bounds, to: host)), "The \(unit) input is clipped")
                var ancestor = field.superview
                while let view = ancestor, view !== host {
                    if let clip = view as? NSClipView {
                        XCTAssertTrue(clip.bounds.contains(field.convert(field.bounds, to: clip)),
                                      "The \(unit) input must be visible without scrolling")
                    }
                    ancestor = view.superview
                }
            }
            for style in DockIconStyle.allCases {
                XCTAssertNotNil(store.iconThumbnails[style], "The \(style.title) thumbnail must load")
            }

        }
    }

}
