import AppKit
import Combine

@MainActor
final class FillrAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: FillrStore?
    private var keyMonitor: Any?
    private var hold: QuitHold?
    private var holdTimer: Timer?
    private var confirmedHold = false
    private var isConfirmingQuit = false
    private var terminationPending = false
    private var buildObservation: AnyCancellable?
    private var feedback: QuitFeedbackPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        cancelHold()
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelHold()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let quitKey = event.charactersIgnoringModifiers?.lowercased() == "q"
        if event.type == .keyDown, quitKey, modifiers == .command {
            guard !terminationPending, !isConfirmingQuit else { return nil }
            if hold == nil && !event.isARepeat { beginHold() }
            return nil
        }
        if event.type == .keyUp, quitKey {
            let wasHolding = hold != nil
            cancelHold()
            return wasHolding ? nil : event
        }
        if event.type == .flagsChanged, modifiers != .command {
            cancelHold()
        } else if event.type == .keyDown {
            cancelHold()
        }
        return event
    }

    private func beginHold() {
        hold = QuitHold(startedAt: ProcessInfo.processInfo.systemUptime)
        let panel = feedbackPanel()
        panel.showHold(progress: 0)
        let timer = Timer(timeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceHold() }
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceHold() {
        guard let hold else { return }
        let progress = hold.progress(at: ProcessInfo.processInfo.systemUptime)
        feedback?.showHold(progress: progress)
        guard progress >= 1 else { return }
        cancelHold()
        confirmedHold = true
        NSApp.terminate(nil)
        confirmedHold = false
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        hold = nil
        if !terminationPending { feedback?.orderOut(nil) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        if isConfirmingQuit { return .terminateCancel }
        cancelHold()
        var confirmed = confirmedHold
        let decision = QuitPolicy.decision(building: store?.isBuilding == true,
            openEditors: store?.openPreferenceEditors ?? 0, confirmed: confirmed)
        if decision == .confirm {
            let alert = NSAlert()
            alert.messageText = store?.isBuilding == true ? "Quit after the folder build finishes?" : "Quit FILLR?"
            alert.informativeText = store?.isBuilding == true
                ? "FILLR will finish moving files safely, then quit. Any unsaved Settings changes will be discarded."
                : "Any unsaved Settings changes will be discarded. You can also hold ⌘Q to quit."
            alert.addButton(withTitle: store?.isBuilding == true ? "Quit When Finished" : "Quit")
            alert.addButton(withTitle: "Cancel")
            alert.buttons.last?.keyEquivalent = "\u{1b}"
            isConfirmingQuit = true
            let response = alert.runModal()
            isConfirmingQuit = false
            guard response == .alertFirstButtonReturn else { return .terminateCancel }
            confirmed = true
        }
        // The build may have finished while the confirmation was on screen.
        guard QuitPolicy.decision(building: store?.isBuilding == true,
            openEditors: store?.openPreferenceEditors ?? 0, confirmed: confirmed) == .waitForBuild,
              let store else { return .terminateNow }
        terminationPending = true
        feedbackPanel().showWaiting { [weak self, weak sender] in
            guard let self, self.terminationPending else { return }
            self.terminationPending = false
            self.buildObservation = nil
            self.feedback?.orderOut(nil)
            sender?.reply(toApplicationShouldTerminate: false)
        }
        buildObservation = store.$isBuilding
            .filter { !$0 }
            .prefix(1)
            .sink { [weak self, weak sender] _ in
                // terminateLater runs a modal run loop. Schedule in that mode
                // as well as the normal mode, after the build completion ends.
                RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                    MainActor.assumeIsolated {
                        guard let self, self.terminationPending else { return }
                        self.terminationPending = false
                        self.buildObservation = nil
                        self.feedback?.orderOut(nil)
                        sender?.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
        return .terminateLater
    }

    private func feedbackPanel() -> QuitFeedbackPanel {
        if let feedback { return feedback }
        let panel = QuitFeedbackPanel()
        feedback = panel
        return panel
    }
}

/// A nonactivating panel leaves the held shortcut with the original responder.
@MainActor
private final class QuitFeedbackPanel: NSPanel {
    private let heading = NSTextField(labelWithString: "Hold ⌘Q to quit")
    private let detail = NSTextField(wrappingLabelWithString: "Release to keep FILLR open.")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Keep FILLR Open", target: nil, action: nil)
    private var cancelWaiting: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 130),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = true
        worksWhenModal = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        heading.font = .boldSystemFont(ofSize: 16)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar
        cancelButton.target = self
        cancelButton.action = #selector(cancelPendingQuit)
        let stack = NSStackView(views: [heading, detail, progress, cancelButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 14
        material.addSubview(stack)
        contentView = material
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: material.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: material.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: material.centerYAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    func showHold(progress value: Double) {
        heading.stringValue = "Hold ⌘Q to quit"
        detail.stringValue = "Release to keep FILLR open."
        progress.doubleValue = value
        progress.isHidden = false
        cancelButton.isHidden = true
        ignoresMouseEvents = true
        show()
    }

    func showWaiting(cancel: @escaping () -> Void) {
        cancelWaiting = cancel
        heading.stringValue = "Finishing folder build…"
        detail.stringValue = "FILLR will quit after the files have been moved safely."
        progress.isHidden = true
        cancelButton.isHidden = false
        ignoresMouseEvents = false
        show()
    }

    private func show() {
        if !isVisible {
            if let window = NSApp.keyWindow {
                setFrameOrigin(NSPoint(x: window.frame.midX - frame.width / 2, y: window.frame.midY - frame.height / 2))
            } else { center() }
            orderFront(nil)
        }
    }

    @objc private func cancelPendingQuit() {
        cancelWaiting?()
        cancelWaiting = nil
    }
}
