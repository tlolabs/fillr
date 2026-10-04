import AppKit
import AppPreferences
import Combine
import Foundation
import UserNotifications
import UpdatePolicy

@MainActor
final class FillrStore: ObservableObject {
    @Published private(set) var snapshot: EngineSnapshot?
    @Published private(set) var folder: URL?
    @Published private(set) var isBuilding = false
    @Published private(set) var openPreferenceEditors = 0
    var updatesBlocked: Bool { !UpdatePolicy.canInstall(building: isBuilding, openEditors: openPreferenceEditors) }
    func beginPreferencesEditing() { openPreferenceEditors += 1 }
    func endPreferencesEditing() { openPreferenceEditors = max(0, openPreferenceEditors - 1) }
    @Published private(set) var overlayVisible = false
    @Published var alertMessage: String?
    @Published private(set) var lastOutput: URL?
    @Published private(set) var mediaPolicy: MediaPolicy

    private var bridge: EngineBridge?
    private var pollTimer: Timer?
    private var wasReady = false
    private let overlay = OverlayController()

    init() {
        PreferencesMigration.migrate()
        if let saved = UserDefaults.standard.data(forKey: "mediaPolicy"),
           let decoded = try? JSONDecoder().decode(MediaPolicy.self, from: saved) {
            mediaPolicy = decoded
        } else {
            mediaPolicy = MediaPolicy()
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        if let path = UserDefaults.standard.string(forKey: "downloadFolder") {
            openFolder(URL(fileURLWithPath: path))
        }
    }

    func chooseFolder() {
        guard !isBuilding else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose CNN download folder"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { openFolder(url) }
    }

    func openFolder(_ url: URL) {
        guard !isBuilding else { return }
        do {
            let next = try EngineBridge(folder: url, policy: mediaPolicy)
            bridge = next
            folder = url
            snapshot = nil
            wasReady = false
            UserDefaults.standard.set(url.path, forKey: "downloadFolder")
            poll()
        } catch { alertMessage = error.localizedDescription }
    }

    func refresh() { bridge?.refresh(); poll() }

    @discardableResult
    func updateMediaPolicy(_ policy: MediaPolicy) -> Bool {
        do {
            try bridge?.setPolicy(policy)
            mediaPolicy = policy
            UserDefaults.standard.set(try JSONEncoder().encode(policy), forKey: "mediaPolicy")
            refresh()
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func poll() {
        guard let bridge else { return }
        do {
            let next = try bridge.snapshot()
            let ready = next.status == "ready"
            if ready && !wasReady { notifyReady() }
            wasReady = ready
            snapshot = next
        } catch { alertMessage = error.localizedDescription }
    }

    func build() {
        guard !isBuilding, snapshot?.status == "ready", let bridge else { return }
        isBuilding = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try bridge.build() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBuilding = false
                switch result {
                case .success(let output): self.lastOutput = URL(fileURLWithPath: output.output_folder)
                case .failure(let error): self.alertMessage = error.localizedDescription
                }
                self.poll()
            }
        }
    }

    func openLastOutput() {
        if let lastOutput { NSWorkspace.shared.open(lastOutput) }
    }

    func toggleOverlay() {
        overlayVisible.toggle()
        overlay.setVisible(overlayVisible, store: self)
    }

    private func notifyReady() {
        let content = UNMutableNotificationContent()
        content.title = "Chabot News footage is ready"
        content.body = "You can stop downloading and build the 14 Comp folders."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
