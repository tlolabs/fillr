import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: NSPanel?

    func setVisible(_ visible: Bool, store: FillrStore) {
        if !visible { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 160, y: 160, width: 290, height: 100),
                styleMask: [.titled, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "FILLR Progress"
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(rootView: OverlayView(store: store))
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }
}

private struct OverlayView: View {
    @ObservedObject var store: FillrStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(store.snapshot?.status == "ready" ? "Ready to build" : "Footage remaining")
                .font(.headline)
            Text(clockText(store.snapshot?.remaining_ms ?? 8_470_000))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: Double(8_470_000 - min(store.snapshot?.remaining_ms ?? 8_470_000, 8_470_000)), total: 8_470_000)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
