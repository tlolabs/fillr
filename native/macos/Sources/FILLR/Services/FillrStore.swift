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

    private struct SavedConfiguration {
        let policy: MediaPolicy
        let sort: SortSettings
        let policyData: Data?
        let sortData: Data?
    }

    // Transfer a newly opened engine exactly once so stale completions can
    // destroy it on the engine queue without a main-queue capture retaining it.
    private final class PendingEngine: @unchecked Sendable {
        private let lock = NSLock()
        private var engine: (any EngineSession)?

        init(_ engine: (any EngineSession)?) { self.engine = engine }

        func take() -> (any EngineSession)? {
            lock.withLock {
                defer { engine = nil }
                return engine
            }
        }
    }

    private let defaults: UserDefaults
    private let makeBridge: @Sendable (URL, MediaPolicy, SortSettings) throws -> any EngineSession
    private var bridge: (any EngineSession)?
    private var settingsRevision: UInt64 = 0
    private var acceptedRevision: UInt64 = 0
    private var acceptedConfiguration: SavedConfiguration
    private var pollTimer: Timer?
    private var wasReady = false
    private let overlay = OverlayController()
    private let dockIcon = DockIconController()
    @Published private(set) var iconPreviewRunning = false
    private let engineQueue = DispatchQueue(label: "org.tlo.fillr.engine", qos: .userInitiated)
    private var engineEpoch: UInt64 = 0
    private var isPolling = false

    init(defaults: UserDefaults = .standard, startServices: Bool = true,
         makeBridge: @escaping @Sendable (URL, MediaPolicy, SortSettings) throws -> any EngineSession = {
             try EngineBridge(folder: $0, policy: $1, settings: $2)
         }) {
        self.defaults = defaults
        self.makeBridge = makeBridge
        if startServices { PreferencesMigration.migrate(defaults: defaults) }
        let initialPolicy: MediaPolicy
        let initialSort: SortSettings
        if let saved = defaults.data(forKey: "mediaPolicy"),
           let decoded = try? JSONDecoder().decode(MediaPolicy.self, from: saved) {
            initialPolicy = decoded
        } else {
            initialPolicy = MediaPolicy()
        }
        if let saved = defaults.data(forKey: "sortSettings"),
           let decoded = try? JSONDecoder().decode(SortSettings.self, from: saved),
           (try? decoded.validate()) != nil {
            initialSort = decoded
        } else {
            initialSort = SortSettings()
        }
        mediaPolicy = initialPolicy
        sortSettings = initialSort
        acceptedConfiguration = SavedConfiguration(policy: initialPolicy, sort: initialSort,
            policyData: defaults.data(forKey: "mediaPolicy"), sortData: defaults.data(forKey: "sortSettings"))
        guard startServices else { return }
        iconPreviewRunning = true
        dockIcon.start { [weak self] in self?.iconPreviewRunning = false }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // A preview launch must not start watching a previously saved media folder.
        if !CommandLine.arguments.contains("--preview-icon"),
           let path = defaults.string(forKey: "downloadFolder") {
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
        let oldBridge = PendingEngine(bridge)
        bridge = nil
        folder = url
        snapshot = nil
        dockIcon.update(available: 0, total: sortSettings.total_ms)
        wasReady = false
        defaults.set(url.path, forKey: "downloadFolder")

        // The worker starts inside the bridge initializer. Hold rejected-file
        // deletion until the latest preferences have been applied below.
        var policy = mediaPolicy
        policy.delete_rejected = false
        let settings = sortSettings
        let makeBridge = self.makeBridge
        let engineQueue = self.engineQueue
        engineQueue.async { [weak self, policy] in
            withExtendedLifetime(oldBridge.take()) {} // Dispose away from MainActor
            do {
                let pending = PendingEngine(try makeBridge(url, policy, settings))
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.engineEpoch == epoch else {
                        // Destroying a Rust engine joins its scanning worker.
                        // A superseded open must release it away from the UI.
                        engineQueue.async { withExtendedLifetime(pending.take()) {} }
                        return
                    }
                    guard let next = pending.take() else { return }
                    self.bridge = next
                    let configuration = SavedConfiguration(policy: self.mediaPolicy, sort: self.sortSettings,
                        policyData: self.defaults.data(forKey: "mediaPolicy"), sortData: self.defaults.data(forKey: "sortSettings"))
                    self.applyConfiguration(configuration, to: next, epoch: epoch, revision: self.settingsRevision)
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
            let configuration = SavedConfiguration(policy: policy, sort: sort, policyData: policyData, sortData: sortData)
            settingsRevision &+= 1
            defaults.set(policyData, forKey: "mediaPolicy")
            defaults.set(sortData, forKey: "sortSettings")
            self.mediaPolicy = policy
            self.sortSettings = sort
            snapshot = nil
            wasReady = false

            if let bridge {
                applyConfiguration(configuration, to: bridge, epoch: engineEpoch, revision: settingsRevision)
            } else {
                acceptedConfiguration = configuration
                acceptedRevision = settingsRevision
            }
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    private func applyConfiguration(_ configuration: SavedConfiguration, to bridge: any EngineSession,
                                    epoch: UInt64, revision: UInt64) {
        engineQueue.async { [weak self, bridge] in
            let result = Result { try bridge.setConfiguration(policy: configuration.policy, settings: configuration.sort) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success:
                    if revision >= self.acceptedRevision {
                        self.acceptedConfiguration = configuration
                        self.acceptedRevision = revision
                    }
                case .failure(let error):
                    // An older save, or a save to a replaced engine, cannot
                    // undo newer preferences or modify their persisted data.
                    guard self.engineEpoch == epoch, self.settingsRevision == revision else { return }
                    let saved = self.acceptedConfiguration
                    self.settingsRevision &+= 1
                    self.defaults.set(saved.policyData, forKey: "mediaPolicy")
                    self.defaults.set(saved.sortData, forKey: "sortSettings")
                    self.mediaPolicy = saved.policy
                    self.sortSettings = saved.sort
                    self.alertMessage = error.localizedDescription
                }
                guard self.engineEpoch == epoch else { return }
                self.poll()
            }
        }
    }

    func poll() {
        guard let bridge, !isPolling else { return }
        isPolling = true
        let epoch = engineEpoch
        let revision = settingsRevision
        engineQueue.async { [weak self, bridge] in
            let result = Result { try bridge.snapshot() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.engineEpoch == epoch, self.settingsRevision == revision else { return }
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
        engineQueue.async { [weak self] in
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
