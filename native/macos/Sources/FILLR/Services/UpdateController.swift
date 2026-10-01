import AppKit
import Combine
import Sparkle
import UpdatePolicy

/// Sparkle owns authenticated installation and recovery on macOS.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    weak var store: FillrStore?
    private var controller: SPUStandardUpdaterController?
    private var resumeInstallation: (() -> Void)?
    private var observation: AnyCancellable?
    @Published var automaticChecks = true {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }

    func start(store: FillrStore) {
        guard controller == nil else { return }
        self.store = store
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.sendsSystemProfile = false
        controller.updater.automaticallyDownloadsUpdates = false
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        do { try controller.updater.start() }
        catch { store.alertMessage = "Updates are unavailable: \(error.localizedDescription)" }
        observation = store.$isBuilding.combineLatest(store.$openPreferenceEditors).receive(on: RunLoop.main).sink { [weak self] busy, editors in
            guard !busy, editors == 0, let self, let resume = self.resumeInstallation else { return }
            self.resumeInstallation = nil
            resume()
        }
    }

    func check() {
        guard let controller else {
            store?.alertMessage = "Automatic updates are not configured in this development build. Download a signed release from GitHub."
            return
        }
        controller.checkForUpdates(nil)
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> { [] }
    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if store?.updatesBlocked == true {
            throw NSError(domain: "FILLR.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "Finish building Comp folders and save or cancel Media Preferences before updating."])
        }
    }
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        guard UpdatePolicy.accepts(
            current: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            proposed: item.versionString, displayed: item.displayVersionString,
            url: item.fileURL, installationType: item.installationType) else {
            throw NSError(domain: "FILLR.Update", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "The update does not match FILLR's stable macOS release contract."])
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard store?.updatesBlocked == true else { return false }
        resumeInstallation = installHandler
        return true
    }
}

@MainActor
final class FillrAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: FillrStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if store?.updatesBlocked == true {
            store?.alertMessage = "Finish the Comp build and save or cancel Media Preferences before quitting or updating."
            return .terminateCancel
        }
        return .terminateNow
    }
}
