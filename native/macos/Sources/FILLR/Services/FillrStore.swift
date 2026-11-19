import AppKit
import AppPreferences
import BackgroundPlanning
import Combine
import Foundation
import UserNotifications
import UpdatePolicy

@MainActor
final class FillrStore: ObservableObject {
    enum FolderOpenState: Equatable {
        case idle
        case opening
        case failed(String)
    }

    @Published private(set) var snapshot: EngineSnapshot?
    @Published private(set) var downloadSnapshot: EngineSnapshot?
    @Published private(set) var downloadProgressError: String?
    @Published private(set) var retiredDownloadSources: Set<String> = []
    @Published private(set) var folder: URL?
    @Published private(set) var folderOpenState: FolderOpenState = .idle
    @Published private(set) var isBuilding = false
    @Published private(set) var isBackgroundBusy = false
    @Published private(set) var isTranscoding = false
    let background: BackgroundController
    let downloads: DownloadTranscodeController
    var downloadSpeeds: [DownloadInfo] { downloads.enabled ? downloads.downloadSpeeds : snapshot?.downloads ?? [] }
    var footageProgress: DownloadFootageProgress {
        DownloadFootageProgress(collection: snapshot, sources: downloadSnapshot,
            conversionEnabled: downloads.enabled, targetMS: sortSettings.total_ms,
            retiredSources: retiredDownloadSources)
    }
    var waitingForConversions: Bool {
        downloads.enabled && snapshot?.status != "ready" && snapshot?.status != "error"
            && downloadProgressError == nil && footageProgress.remainingMS == 0
            && footageProgress.pendingConversionCount > 0
    }
    var backgroundFootagePlan: BackgroundFootagePlan? {
        guard sortSettings.folder_count == 14 else { return nil }
        guard let snapshot, snapshot.status == "ready", let plan = snapshot.plan else {
            if (snapshot?.clips.isEmpty ?? true), (snapshot?.pending.isEmpty ?? true),
               footageProgress.pendingConversionCount == 0 { return exportedFootagePlan }
            return nil
        }
        let root = URL(fileURLWithPath: snapshot.folder, isDirectory: true)
        return BackgroundFootagePlan(assignments: plan.assignments.map { assignment in
            BackgroundFootageAssignment(comp: assignment.comp,
                sources: assignment.filenames.map { root.appendingPathComponent($0) })
        })
    }

    private func updateBackgroundFootage() {
        background.configureCollection(plan: backgroundFootagePlan,
            useAllFootage: sortSettings.use_all_clips, selected: folder != nil)
    }
    var hasActiveBuild: Bool { isBuilding || isBackgroundBusy || isTranscoding }
    @Published private(set) var openPreferenceEditors = 0
    var updatesBlocked: Bool { !UpdatePolicy.canInstall(building: hasActiveBuild, openEditors: openPreferenceEditors) }
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
    private let servicesStarted: Bool
    private let makeBridge: @Sendable (URL, MediaPolicy, SortSettings) throws -> any EngineSession
    private let makeProgressBridge: (@Sendable (URL, MediaPolicy, SortSettings) throws -> any EngineSession)?
    private var bridge: (any EngineSession)?
    private var progressBridge: (any EngineSession)?
    private var progressSettingsValid = false
    private var exportedFootagePlan: BackgroundFootagePlan?
    private var settingsRevision: UInt64 = 0
    private var acceptedRevision: UInt64 = 0
    private var acceptedConfiguration: SavedConfiguration
    private var pollTimer: Timer?
    private var wasReady = false
    private let overlay = OverlayController()
    private let dockIcon: DockIconController
    @Published private(set) var iconStyle: DockIconStyle
    let iconThumbnails: [DockIconStyle: NSImage]
    @Published private(set) var iconPreviewRunning = false
    private let engineQueue = DispatchQueue(label: "org.tlo.fillr.engine", qos: .userInitiated)
    private var engineEpoch: UInt64 = 0
    private var isPolling = false
    private var backgroundObservation: AnyCancellable?
    private var downloadObservation: AnyCancellable?
    private var downloadSpeedObservation: AnyCancellable?
    private var downloadsSuspendedForQuit = false

    init(defaults: UserDefaults = .standard, startServices: Bool = true,
         iconResourceURL: URL? = Bundle.main.resourceURL,
         makeProgressBridge: (@Sendable (URL, MediaPolicy, SortSettings) throws -> any EngineSession)? = nil,
         makeBridge: @escaping @Sendable (URL, MediaPolicy, SortSettings) throws -> any EngineSession = {
             try EngineBridge(folder: $0, policy: $1, settings: $2)
         }) {
        self.defaults = defaults
        servicesStarted = startServices
        self.makeBridge = makeBridge
        if let makeProgressBridge {
            self.makeProgressBridge = makeProgressBridge
        } else if startServices {
            self.makeProgressBridge = { try EngineBridge(folder: $0, policy: $1, settings: $2, readOnly: true) }
        } else {
            self.makeProgressBridge = nil
        }
        background = BackgroundController(defaults: defaults)
        downloads = DownloadTranscodeController(defaults: defaults)
        let initialIcon = DockIconStyle(savedValue: defaults.string(forKey: DockIconStyle.preferenceKey))
        iconStyle = initialIcon
        iconThumbnails = Dictionary(uniqueKeysWithValues: DockIconStyle.allCases.compactMap { style in
            style.thumbnail(resourceURL: iconResourceURL).map { (style, $0) }
        })
        dockIcon = DockIconController(resourceURL: iconResourceURL, style: initialIcon)
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
        backgroundObservation = background.$isBusy
            .sink { [weak self] busy in
                guard let self else { return }
                if self.isBackgroundBusy != busy { self.isBackgroundBusy = busy }
                if self.servicesStarted {
                    if busy { self.downloads.cancel() }
                    else if !self.isBuilding, !self.downloadsSuspendedForQuit { self.downloads.start(folder: self.folder) }
                }
            }
        downloadObservation = downloads.$isBusy.sink { [weak self] busy in self?.isTranscoding = busy }
        downloadSpeedObservation = downloads.$downloadSpeeds.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }
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
        guard !isBuilding, !isBackgroundBusy else { return }
        let picker = NSOpenPanel()
        picker.title = "Choose CNN download folder"
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url { openFolder(url) }
    }

    func openFolder(_ url: URL) {
        guard !isBuilding, !isBackgroundBusy else { return }
        engineEpoch &+= 1
        let epoch = engineEpoch
        let oldBridge = PendingEngine(bridge)
        let oldProgressBridge = PendingEngine(progressBridge)
        bridge = nil
        progressBridge = nil
        progressSettingsValid = false
        folder = url
        snapshot = nil
        downloadSnapshot = nil
        retiredDownloadSources = []
        downloadProgressError = nil
        exportedFootagePlan = nil
        folderOpenState = .opening
        alertMessage = nil
        dockIcon.update(available: 0, total: sortSettings.total_ms)
        wasReady = false
        updateBackgroundFootage()
        defaults.set(url.path, forKey: "downloadFolder")
        if servicesStarted, !downloadsSuspendedForQuit { downloads.start(folder: url) }

        // The worker starts inside the bridge initializer. Hold rejected-file
        // deletion until the latest preferences have been applied below.
        var policy = downloads.enabled ? mediaPolicy.proResCollectionPolicy : mediaPolicy
        policy.delete_rejected = false
        let collectionFolder = downloads.enabled ? DownloadTranscodeController.collectionFolder(for: url) : url
        let prepareCollection = servicesStarted && downloads.enabled
        let settings = sortSettings
        let makeBridge = self.makeBridge
        let makeProgressBridge = downloads.enabled ? self.makeProgressBridge : nil
        let progressPolicy = mediaPolicy.downloadProgressPolicy
        let savedExport = defaults.string(forKey: "lastExportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let engineQueue = self.engineQueue
        engineQueue.async { [weak self, policy] in
            withExtendedLifetime(oldBridge.take()) {} // Dispose away from MainActor
            withExtendedLifetime(oldProgressBridge.take()) {}
            do {
                if prepareCollection {
                    // Both queues can prepare at startup. The worker uses an
                    // exclusive mkdir with EEXIST handling, then lstat checks.
                    try DownloadTranscodeWorker(root: url).prepare()
                }
                let pending = PendingEngine(try makeBridge(collectionFolder, policy, settings))
                var progressError: String?
                let pendingProgress: PendingEngine
                do {
                    pendingProgress = PendingEngine(try makeProgressBridge?(url, progressPolicy, settings))
                } catch {
                    pendingProgress = PendingEngine(nil)
                    progressError = error.localizedDescription
                }
                let openingProgressError = progressError
                let restoredExport: BackgroundFootagePlan?
                if let savedExport,
                   savedExport.deletingLastPathComponent().standardizedFileURL == collectionFolder.standardizedFileURL {
                    restoredExport = try? BackgroundFootagePlan.loadExport(at: savedExport)
                } else {
                    restoredExport = nil
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.engineEpoch == epoch else {
                        // Destroying a Rust engine joins its scanning worker.
                        // A superseded open must release it away from the UI.
                        engineQueue.async { withExtendedLifetime(pending.take()) {} }
                        engineQueue.async { withExtendedLifetime(pendingProgress.take()) {} }
                        return
                    }
                    guard let next = pending.take() else { return }
                    self.bridge = next
                    self.progressBridge = pendingProgress.take()
                    self.downloadProgressError = openingProgressError
                    self.exportedFootagePlan = restoredExport
                    if restoredExport != nil { self.lastOutput = savedExport }
                    self.folderOpenState = .idle
                    let configuration = SavedConfiguration(policy: self.mediaPolicy, sort: self.sortSettings,
                        policyData: self.defaults.data(forKey: "mediaPolicy"), sortData: self.defaults.data(forKey: "sortSettings"))
                    self.applyConfiguration(configuration, to: next, epoch: epoch, revision: self.settingsRevision)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.engineEpoch == epoch else { return }
                    self.folderOpenState = .failed(error.localizedDescription)
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func setDownloadTranscoding(_ enabled: Bool) {
        guard !isBuilding, !isBackgroundBusy, !downloadsSuspendedForQuit else { return }
        downloads.setEnabled(enabled)
        if let folder { openFolder(folder) }
    }

    func stopDownloadTranscodingForQuit() {
        downloadsSuspendedForQuit = true
        downloads.cancel()
    }

    func resumeDownloadTranscodingAfterCancelledQuit() {
        downloadsSuspendedForQuit = false
        if servicesStarted, !isBuilding, !isBackgroundBusy { downloads.start(folder: folder) }
    }

    func refresh() {
        if case .failed = folderOpenState, let folder {
            openFolder(folder)
            return
        }
        guard let bridge else { return }
        if downloads.enabled, makeProgressBridge != nil, progressBridge == nil, let folder {
            openFolder(folder)
            return
        }
        if progressBridge != nil, !progressSettingsValid {
            let configuration = SavedConfiguration(policy: mediaPolicy, sort: sortSettings,
                policyData: defaults.data(forKey: "mediaPolicy"), sortData: defaults.data(forKey: "sortSettings"))
            applyConfiguration(configuration, to: bridge, epoch: engineEpoch, revision: settingsRevision)
            return
        }
        engineQueue.async { [bridge] in
            bridge.refresh()
        }
        if let progressBridge { engineQueue.async { progressBridge.refresh() } }
        poll()
    }

    @discardableResult
    func updateSettings(policy: MediaPolicy, sort: SortSettings) -> Bool {
        guard !hasActiveBuild else { alertMessage = "Finish the current build or benchmark before changing Settings."; return false }
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
            downloadSnapshot = nil
            retiredDownloadSources = []
            progressSettingsValid = false
            wasReady = false
            updateBackgroundFootage()

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
        let policy = downloads.enabled ? configuration.policy.proResCollectionPolicy : configuration.policy
        let progressBridge = self.progressBridge
        let hasProgressBridge = progressBridge != nil
        let progressPolicy = configuration.policy.downloadProgressPolicy
        engineQueue.async { [weak self, bridge] in
            let result = Result { try bridge.setConfiguration(policy: policy, settings: configuration.sort) }
            // The primary collection determines whether settings were accepted.
            // Progress failures must not roll back a valid build configuration.
            let progressResult: Result<Void, Error>?
            if case .success = result, let progressBridge {
                progressResult = Result { try progressBridge.setConfiguration(policy: progressPolicy, settings: configuration.sort) }
            } else {
                progressResult = nil
            }
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
                    if hasProgressBridge {
                        self.downloadProgressError = "Refresh to resume MPEG progress with the restored settings."
                    }
                }
                guard self.engineEpoch == epoch else { return }
                if revision == self.settingsRevision, let progressResult {
                    if case .failure(let error) = progressResult {
                        self.progressSettingsValid = false
                        self.downloadSnapshot = nil
                        self.downloadProgressError = error.localizedDescription
                    } else {
                        self.progressSettingsValid = true
                        self.downloadProgressError = nil
                    }
                }
                self.poll()
            }
        }
    }

    func poll() {
        guard let bridge, !isPolling else { return }
        isPolling = true
        let epoch = engineEpoch
        let revision = settingsRevision
        let progressBridge = progressSettingsValid ? self.progressBridge : nil
        let sourceFolder = folder
        engineQueue.async { [weak self, bridge] in
            let result = Result { try bridge.snapshot() }
            let progressResult = progressBridge.map { progress in Result { try progress.snapshot() } }
            var retiredSources = Set<String>()
            if let sourceFolder, case .success(let source)? = progressResult {
                retiredSources = DownloadTranscodeWorker.retiredSourceNames(root: sourceFolder, sources: source.clips)
            }
            let retired = retiredSources
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPolling = false
                guard self.engineEpoch == epoch, self.settingsRevision == revision else { return }
                self.retiredDownloadSources = retired
                if let progressResult {
                    switch progressResult {
                    case .success(let source):
                        self.downloadSnapshot = source.status == "error" ? nil : source
                        self.downloadProgressError = source.status == "error" ? source.message : nil
                    case .failure(let error):
                        self.downloadSnapshot = nil
                        self.downloadProgressError = error.localizedDescription
                    }
                }
                switch result {
                case .success(let next):
                    let ready = next.status == "ready"
                    if ready && !self.wasReady { self.notifyReady() }
                    self.wasReady = ready
                    self.snapshot = next
                    self.updateBackgroundFootage()
                    self.dockIcon.update(available: self.footageProgress.availableMS, total: self.sortSettings.total_ms)
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    func build() {
        guard !hasActiveBuild, snapshot?.status == "ready", let bridge else { return }
        isBuilding = true
        downloads.cancel()
        let loadExportPlan = sortSettings.folder_count == 14
        engineQueue.async { [weak self] in
            let result = Result {
                let output = try bridge.build()
                let exportedPlan = loadExportPlan ? try? BackgroundFootagePlan.loadExport(at: URL(fileURLWithPath: output.output_folder)) : nil
                return (output, exportedPlan)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isBuilding = false
                if self.servicesStarted, !self.downloadsSuspendedForQuit { self.downloads.start(folder: self.folder) }
                switch result {
                case .success(let (output, exportedPlan)):
                    self.lastOutput = URL(fileURLWithPath: output.output_folder)
                    self.defaults.set(output.output_folder, forKey: "lastExportFolder")
                    self.exportedFootagePlan = exportedPlan
                    self.snapshot = nil
                    self.updateBackgroundFootage()
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

    func setIconStyle(_ style: DockIconStyle) {
        guard style != iconStyle else { return }
        guard dockIcon.setStyle(style) else {
            alertMessage = "The selected app icon could not be loaded."
            return
        }
        iconStyle = style
        defaults.set(style.rawValue, forKey: DockIconStyle.preferenceKey)
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
