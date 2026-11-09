import AppKit
import Combine
import SwiftUI
@testable import FILLR
import XCTest

final class WindowLayoutRenderingTests: XCTestCase {
    @MainActor
    func testLayoutsRenderAtPresetAndMinimumSizes() async throws {
        try requireDisplay()
        var renderedCases = 0
        for hasFootage in [false, true] {
            let store = await makeStore(collecting: hasFootage)
            for layout in WindowLayout.allCases {
                for (sizeName, size) in [("preset", layout.preferredSize), ("minimum", layout.minimumSize)] {
                    let (window, host) = makeWindow(store: store, layout: layout, size: size)
                    defer { window.close() }
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        window.appearance = NSAppearance(named: appearance)
                        await settle(host)
                        let context = "\(layout.title), \(sizeName), \(appearance.rawValue), collecting=\(hasFootage)"
                        XCTAssertFalse(window.isVisible, "Rendering checks must not display windows")
                        XCTAssertEqual(host.bounds.width, size.width, accuracy: 1, context)
                        XCTAssertEqual(host.bounds.height, size.height, accuracy: 1, context)
                        let png = try capture(host)
                        XCTAssertGreaterThan(png.count, 1_000, "Expected a rendered interface: \(context)")
                        try saveIfRequested(png, name: "\(layout.rawValue)-\(hasFootage ? "collecting" : "empty")-\(sizeName)-\(appearance == .aqua ? "light" : "dark")")
                        renderedCases += 1
                    }
                }
            }
        }
        XCTAssertEqual(renderedCases, 24)
    }

    @MainActor
    func testPrimaryActionAccessibilityAtPresetAndMinimumSizes() async throws {
        try requireDisplay()
        // SwiftUI may omit the entire accessibility subtree of a hidden
        // NSHostingView. Distinguish that harness limitation with a minimal
        // independent button before interpreting a missing FILLR node as a bug.
        let probe = NSHostingView(rootView: Button("Offscreen accessibility probe") {}.frame(width: 300, height: 80))
        let probeWindow = baseWindow(size: CGSize(width: 300, height: 80))
        probeWindow.contentView = probe
        defer { probeWindow.close() }
        await settle(probe)
        guard accessibilityNodes(probe).contains(where: {
            $0.label == "Offscreen accessibility probe" && $0.role == "AXButton"
        }) else {
            throw XCTSkip("Hidden NSHostingView does not expose even a plain SwiftUI Button; primary-action accessibility, clipping, and disabled-state checks are unavailable")
        }
        for hasFootage in [false, true] {
            let store = await makeStore(collecting: hasFootage)
            for layout in WindowLayout.allCases {
                for (sizeName, size) in [("preset", layout.preferredSize), ("minimum", layout.minimumSize)] {
                    let (window, host) = makeWindow(store: store, layout: layout, size: size)
                    defer { window.close() }
                    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                        window.appearance = NSAppearance(named: appearance)
                        await settle(host)
                        let context = "\(layout.title), \(sizeName), \(appearance.rawValue), collecting=\(hasFootage)"
                        let button = try XCTUnwrap(accessibilityNodes(host).first {
                            $0.label == "Build Folders" && $0.role == "AXButton"
                        }, context)
                        let contentBounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                        XCTAssertTrue(contentBounds.insetBy(dx: -2, dy: -2).contains(button.frame),
                                      "Primary action is clipped: \(context), \(button.frame), \(contentBounds)")
                        XCTAssertFalse(button.enabled ?? true, "Collecting/empty states must not allow a build: \(context)")
                    }
                }
            }
        }
    }

    @MainActor
    func testChangingWindowAppearanceUpdatesExistingHostedInterface() async throws {
        try requireDisplay()
        let store = await makeStore(collecting: true)
        let (window, host) = makeWindow(store: store, layout: .compactPanel, size: WindowLayout.compactPanel.preferredSize)
        defer { window.close() }
        let applicationAppearance = NSApplication.shared.appearance
        window.appearance = NSAppearance(named: .aqua)
        await settle(host)
        let light = try capture(host)
        window.appearance = NSAppearance(named: .darkAqua)
        await settle(host)
        let dark = try capture(host)
        XCTAssertNotEqual(light, dark, "The same hosted interface must redraw when its window appearance changes")
        XCTAssertTrue(NSApplication.shared.appearance === applicationAppearance,
                      "Rendering must not change the application's appearance override")
    }

    @MainActor
    func testSwitchingHorizontalToMiniResizesOnlyTheAssociatedWindow() async throws {
        try requireDisplay()
        let store = await makeStore(collecting: true)
        let selection = LayoutSelection()
        let host = NSHostingView(rootView: AnyView(ResizingLayoutProbe(store: store, selection: selection)))
        let window = baseWindow(size: selection.layout.preferredSize)
        window.contentView = host
        let otherWindow = baseWindow(size: CGSize(width: 420, height: 300))
        defer { window.close(); otherWindow.close() }
        let otherFrame = otherWindow.frame
        await settle(host)
        let wideFrame = window.frame
        selection.layout = .miniMonitor
        await settle(host)
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertLessThan(window.frame.width, wideFrame.width, "Selecting Mini Monitor must shrink an existing window")
        XCTAssertEqual(contentSize.width, WindowLayout.miniMonitor.preferredSize.width, accuracy: 1)
        XCTAssertEqual(contentSize.height, WindowLayout.miniMonitor.preferredSize.height, accuracy: 1)
        XCTAssertEqual(window.frame.minX, wideFrame.minX, accuracy: 1)
        XCTAssertEqual(window.frame.maxY, wideFrame.maxY, accuracy: 1)
        XCTAssertEqual(otherWindow.frame, otherFrame, "Settings or other windows must not be resized")
    }

    @MainActor
    func testAttachingSizingBridgePreservesRestoredAndUserResizedFrames() async throws {
        try requireDisplay()
        let restoredSize = CGSize(width: 650, height: 470)
        let window = baseWindow(size: restoredSize)
        defer { window.close() }
        let bridge = LayoutWindowSizing.WindowView(layout: .compactPanel)
        window.contentView = bridge
        await settle(bridge)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, restoredSize,
                       "Attaching the bridge must preserve AppKit's restored window size")

        let resizedSize = CGSize(width: 690, height: 510)
        window.setContentSize(resizedSize)
        bridge.scheduleUpdate()
        await settle(bridge)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, resizedSize,
                       "An unchanged layout must preserve the user's resized frame")

        // SwiftUI may recreate a representable while keeping the same NSWindow.
        let replacement = LayoutWindowSizing.WindowView(layout: .compactPanel)
        window.contentView = replacement
        await settle(replacement)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, resizedSize)
    }

    @MainActor
    func testExplicitlyReapplyingCurrentPresetResetsAnEnlargedWindow() async throws {
        try requireDisplay()
        let enlargedSize = CGSize(width: 650, height: 470)
        let window = baseWindow(size: enlargedSize)
        defer { window.close() }
        let bridge = LayoutWindowSizing.WindowView(layout: .compactPanel, resizeRequestID: UUID())
        window.contentView = bridge
        await settle(bridge)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, enlargedSize)

        // The menu emits a fresh request even when the selected layout is unchanged.
        bridge.resizeRequestID = UUID()
        bridge.scheduleUpdate()
        await settle(bridge)
        let presetSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(presetSize.width, WindowLayout.compactPanel.preferredSize.width, accuracy: 1)
        XCTAssertEqual(presetSize.height, WindowLayout.compactPanel.preferredSize.height, accuracy: 1)

        window.setContentSize(enlargedSize)
        bridge.scheduleUpdate()
        await settle(bridge)
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, enlargedSize,
                       "Ordinary view updates must not repeat the last explicit resize request")
    }

    @MainActor
    func testFullScreenLayoutChangeWaitsUntilWindowExitsFullScreen() async throws {
        try requireDisplay()
        let window = FullScreenSizingProbeWindow(
            contentRect: NSRect(origin: .zero, size: CGSize(width: 900, height: 600)),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let bridge = LayoutWindowSizing.WindowView(layout: .horizontalConsole)
        window.contentView = bridge
        await settle(bridge)
        let fullScreenFrame = window.frame

        window.reportFullScreen = true
        bridge.layoutChoice = .miniMonitor
        bridge.scheduleUpdate()
        await settle(bridge)
        XCTAssertEqual(window.frame, fullScreenFrame, "The bridge must leave a full-screen frame alone")

        window.reportFullScreen = false
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await settle(bridge)
        let contentSize = window.contentRect(forFrameRect: window.frame).size
        XCTAssertEqual(contentSize.width, WindowLayout.miniMonitor.preferredSize.width, accuracy: 1)
        XCTAssertEqual(contentSize.height, WindowLayout.miniMonitor.preferredSize.height, accuracy: 1)
    }

    @MainActor
    private func requireDisplay() throws {
        _ = NSApplication.shared
        guard NSScreen.main != nil else { throw XCTSkip("AppKit rendering requires an available desktop display") }
    }

    @MainActor
    private func makeStore(collecting: Bool) async -> FillrStore {
        let suite = "com.tlolabs.fillr.layout-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let snapshot = collectingSnapshot()
        let store = FillrStore(defaults: defaults, startServices: false) { _, _, _ in
            LayoutFixtureEngine(value: snapshot)
        }
        if collecting {
            let loaded = expectation(description: "synthetic collecting snapshot")
            let observation = store.$snapshot.compactMap { $0 }.first().sink { _ in loaded.fulfill() }
            store.openFolder(URL(fileURLWithPath: snapshot.folder))
            await fulfillment(of: [loaded], timeout: 5)
            withExtendedLifetime(observation) {}
        }
        return store
    }

    @MainActor
    private func baseWindow(size: CGSize) -> NSWindow {
        let screen = NSScreen.main!.visibleFrame
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameTopLeftPoint(NSPoint(x: screen.minX + 30, y: screen.maxY - 30))
        return window
    }

    @MainActor
    private func makeWindow(store: FillrStore, layout: WindowLayout, size: CGSize) -> (NSWindow, NSHostingView<AnyView>) {
        let root = ContentView(store: store, layout: layout)
            .frame(minWidth: layout.minimumSize.width, minHeight: layout.minimumSize.height)
        let host = NSHostingView(rootView: AnyView(root))
        let window = baseWindow(size: size)
        window.contentView = host
        window.setContentSize(size)
        return (window, host)
    }

    @MainActor
    private func settle(_ host: NSView) async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 40_000_000)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    @MainActor
    private func capture(_ host: NSView) throws -> Data {
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func saveIfRequested(_ png: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["FILLR_LAYOUT_QA_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private struct AccessibleNode {
        let label: String
        let role: String
        let frame: NSRect
        let enabled: Bool?
    }

    @MainActor
    private func accessibilityNodes(_ root: NSObject) -> [AccessibleNode] {
        var visited = Set<ObjectIdentifier>()
        func value(_ object: NSObject, _ key: String) -> Any? {
            let getter = NSSelectorFromString(key)
            let booleanGetter = NSSelectorFromString("is" + key.prefix(1).uppercased() + key.dropFirst())
            guard object.responds(to: getter) || object.responds(to: booleanGetter) else { return nil }
            return object.value(forKey: key)
        }
        func visit(_ object: NSObject) -> [AccessibleNode] {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            var nodes: [AccessibleNode] = []
            if let frame = value(object, "accessibilityFrame") as? NSValue {
                let label = value(object, "accessibilityLabel") as? String
                    ?? value(object, "accessibilityTitle") as? String ?? ""
                nodes.append(AccessibleNode(label: label,
                                            role: value(object, "accessibilityRole") as? String ?? "",
                                            frame: frame.rectValue,
                                            enabled: (value(object, "accessibilityEnabled") as? NSNumber)?.boolValue))
            }
            for child in value(object, "accessibilityChildren") as? [NSObject] ?? [] {
                nodes.append(contentsOf: visit(child))
            }
            return nodes
        }
        return visit(root)
    }

    private func collectingSnapshot() -> EngineSnapshot {
        let filename = "A deliberately long incoming footage filename for compact layout validation.mpg"
        return EngineSnapshot(api_version: 1,
            folder: "/synthetic-only/A deliberately long folder name for CNN downloads and compact layout validation",
            status: "checking", available_ms: 6_755_000, remaining_ms: 1_715_000,
            clips: (0..<86).map { ClipInfo(filename: "clip-\($0).mpg", duration_ms: 80_000, size_bytes: 1, modified_ms: 0) },
            pending: [filename, "pending-2.mpg", "pending-3.mpg", "pending-4.mpg"],
            downloads: [DownloadInfo(filename: filename, size_bytes: 1_000_000, observed_bytes: 500_000,
                                     elapsed_ms: 1_000, average_bytes_per_second: 500_000, completed: false)],
            excluded: [ExcludedInfo(filename: filename, reason: "Synthetic profile mismatch")],
            duplicate_log: ["Synthetic duplicate removed"], rejection_log: ["Synthetic rejection recorded"],
            plan: nil, message: "Collecting footage — waiting for stable, unique clips")
    }
}

/// Exercises the bridge's full-screen boundary without displaying a window or
/// changing the desktop's actual full-screen spaces.
private final class FullScreenSizingProbeWindow: NSWindow {
    var reportFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { reportFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

private final class LayoutFixtureEngine: EngineSession, @unchecked Sendable {
    let value: EngineSnapshot
    init(value: EngineSnapshot) { self.value = value }
    func snapshot() throws -> EngineSnapshot { value }
    func refresh() {}
    func setConfiguration(policy: MediaPolicy, settings: SortSettings) throws {}
    func build() throws -> BuildResponse.Result { throw BridgeError.message("Rendering tests must never build folders") }
}

private final class LayoutSelection: ObservableObject {
    @Published var layout = WindowLayout.horizontalConsole
}

private struct ResizingLayoutProbe: View {
    @ObservedObject var store: FillrStore
    @ObservedObject var selection: LayoutSelection
    var body: some View {
        ContentView(store: store, layout: selection.layout)
            .frame(minWidth: selection.layout.minimumSize.width, minHeight: selection.layout.minimumSize.height)
            .background(LayoutWindowSizing(layout: selection.layout))
    }
}
