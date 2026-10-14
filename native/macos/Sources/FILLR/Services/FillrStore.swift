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
    @Published private(set) var sortSettings: SortSettings

    private var bridge: EngineBridge?
    private var pollTimer: Timer?
    private var wasReady = false
    private let overlay = OverlayController()
    private let dockIcon = DockIconController()
    @Published private(set) var iconPreviewRunning = false
    private let engineQueue = DispatchQueue(label: "org.tlo.fillr.engine", qos: .userInitiated)
    private var engineEpoch: UInt64 = 0
    private var isPolling = false

    init() {
        PreferencesMigration.migrate()
        if let saved = UserDefaults.standard.data(forKey: "mediaPolicy"),
           let decoded = try? JSONDecoder().decode(MediaPolicy.self, from: saved) {
            mediaPolicy = decoded
        } else {
            mediaPolicy = MediaPolicy()
        }
        if let saved = UserDefaults.standard.data(forKey: "sortSettings"),
           let decoded = try? JSONDecoder().decode(SortSettings.self, from: saved),
           (try? decoded.validate()) != nil {
            sortSettings = decoded
        } else {
            sortSettings = SortSettings()
        }
        iconPreviewRunning = true
        dockIcon.start { [weak self] in self?.iconPreviewRunning = false }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // A preview launch must not start watching a previously saved media folder.
        if !CommandLine.arguments.contains("--preview-icon"),
           let path = UserDefaults.standard.string(forKey: "downloadFolder") {
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
        engineEpoch &+= 1
        let epoch = engineEpoch
        let oldBridge = bridge
        bridge = nil
        folder = url
        snapshot = nil
        dockIcon.update(available: 0, total: sortSettings.total_ms)
        wasReady = false
        UserDefaults.standard.set(url.path, forKey: "downloadFolder")

        let policy = mediaPolicy
        let settings = sortSettings
        engineQueue.async { [weak self] in
            _ = oldBridge // Disposed asynchronously off MainActor
            do {
                let next = try EngineBridge(folder: url, policy: policy, settings: settings)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.engineEpoch == epoch else { return }
                    self.bridge = next
                    self.poll()
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.engineEpoch == epoch else { return }
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func refresh() {
        guard let bridge else { return }
        engineQueue.async { [bridge] in
            bridge.refresh()
        }
        poll()
    }

    @discardableResult
    func updateSettings(policy: MediaPolicy, sort: SortSettings) -> Bool {
        guard !isBuilding else { alertMessage = "Finish building folders before changing Settings."; return false }
        do {
            try EngineBridge.validate(settings: sort)
            try EngineBridge.validate(policy: policy)

            let policyData = try JSONEncoder().encode(policy)
            let sortData = try JSONEncoder().encode(sort)
            let oldPolicyData = UserDefaults.standard.data(forKey: "mediaPolicy")
            let oldSortData = UserDefaults.standard.data(forKey: "sortSettings")

            UserDefaults.standard.set(policyData, forKey: "mediaPolicy")
            UserDefaults.standard.set(sortData, forKey: "sortSettings")

            if let bridge {
                let epoch = engineEpoch
                engineQueue.async { [weak self, bridge] in
                    do {
                        try bridge.setConfiguration(policy: policy, settings: sort)
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.engineEpoch == epoch else { return }
                            self.mediaPolicy = policy
                            self.sortSettings = sort
                            self.refresh()
                        }
                    } catch {
                        UserDefaults.standard.set(oldPolicyData, forKey: "mediaPolicy")
                        UserDefaults.standard.set(oldSortData, forKey: "sortSettings")
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.engineEpoch == epoch else { return }
                            self.alertMessage = error.localizedDescription
                        }
                    }
                }
            } else {
                mediaPolicy = policy
                sortSettings = sort
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    func poll() {
        guard let bridge, !isPolling else { return }
        isPolling = true
        let epoch = engineEpoch
        engineQueue.async { [weak self, bridge] in
            let result = Result { try bridge.snapshot() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.engineEpoch == epoch else { return }
                switch result {
                case .success(let next):
                    let ready = next.status == "ready"
                    if ready && !self.wasReady { self.notifyReady() }
                    self.wasReady = ready
                    self.snapshot = next
                    self.dockIcon.update(available: next.available_ms, total: self.sortSettings.total_ms)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                }
            }
        }
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

    func previewIconAnimation() {
        guard !iconPreviewRunning else { return }
        iconPreviewRunning = true
        dockIcon.preview { [weak self] in self?.iconPreviewRunning = false }
    }

    func toggleOverlay() {
        overlayVisible.toggle()
        overlay.setVisible(overlayVisible, store: self)
    }

    private func notifyReady() {
        let content = UNMutableNotificationContent()
        content.title = "Chabot News footage is ready"
        content.body = "You can stop downloading and build the \(sortSettings.folder_count) folders."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
