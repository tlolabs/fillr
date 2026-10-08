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
            Text(clockText(store.snapshot?.remaining_ms ?? store.sortSettings.total_ms))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            ProgressView(value: Double(store.sortSettings.total_ms - min(store.snapshot?.remaining_ms ?? store.sortSettings.total_ms, store.sortSettings.total_ms)), total: Double(store.sortSettings.total_ms))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
