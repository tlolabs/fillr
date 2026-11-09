import AppKit
import SwiftUI

/// SwiftUI's defaultSize only sizes new windows. This window-local bridge also
/// applies a selected preset to an existing window without reaching other scenes.
struct LayoutWindowSizing: NSViewRepresentable {
    let layout: WindowLayout
    var resizeRequestID: UUID? = nil

    func makeNSView(context: Context) -> WindowView {
        WindowView(layout: layout, resizeRequestID: resizeRequestID)
    }

    func updateNSView(_ nsView: WindowView, context: Context) {
        nsView.layoutChoice = layout
        nsView.resizeRequestID = resizeRequestID
        nsView.scheduleUpdate()
    }

    final class WindowView: NSView {
        var layoutChoice: WindowLayout
        var resizeRequestID: UUID?
        private var appliedLayout: WindowLayout?
        private var appliedResizeRequestID: UUID?
        private weak var appliedWindow: NSWindow?
        private var exitFullScreenObserver: NSObjectProtocol?

        init(layout: WindowLayout, resizeRequestID: UUID? = nil) {
            layoutChoice = layout
            self.resizeRequestID = resizeRequestID
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        deinit {
            if let exitFullScreenObserver {
                NotificationCenter.default.removeObserver(exitFullScreenObserver)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let exitFullScreenObserver {
                NotificationCenter.default.removeObserver(exitFullScreenObserver)
                self.exitFullScreenObserver = nil
            }
            if let window {
                exitFullScreenObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main
                ) { [weak self] _ in self?.scheduleUpdate() }
            }
            scheduleUpdate()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func scheduleUpdate() {
            // Let SwiftUI finish updating the content's minimum dimensions first.
            DispatchQueue.main.async { [weak self] in self?.applyLayout() }
        }

        private func applyLayout() {
            guard let window else { return }

            let newlyAttached = appliedWindow !== window
            if newlyAttached {
                // SwiftUI's defaultSize handles new windows; AppKit may already
                // have restored a user-resized frame. Keep that initial frame.
                appliedWindow = window
                appliedLayout = layoutChoice
                appliedResizeRequestID = resizeRequestID
            }
            // Let AppKit own the full-screen frame. Keep a changed layout pending
            // until didExitFullScreenNotification schedules another update.
            guard !window.styleMask.contains(.fullScreen) else { return }
            window.contentMinSize = layoutChoice.minimumSize
            guard !newlyAttached,
                  appliedLayout != layoutChoice || appliedResizeRequestID != resizeRequestID else { return }

            let currentFrame = window.frame
            let contentRect = NSRect(origin: .zero, size: layoutChoice.preferredSize)
            let preferredFrameSize = window.frameRect(forContentRect: contentRect).size
            let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame

            var frame = NSRect(
                x: currentFrame.minX,
                y: currentFrame.maxY - preferredFrameSize.height,
                width: preferredFrameSize.width,
                height: preferredFrameSize.height
            )
            if let visibleFrame {
                frame.size.width = min(frame.width, visibleFrame.width)
                frame.size.height = min(frame.height, visibleFrame.height)
                frame.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(currentFrame.maxY - frame.height, visibleFrame.minY), visibleFrame.maxY - frame.height)
            }

            appliedLayout = layoutChoice
            appliedResizeRequestID = resizeRequestID
            appliedWindow = window
            window.setFrame(frame, display: true, animate: window.isVisible)
        }
    }
}
