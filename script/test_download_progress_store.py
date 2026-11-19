#!/usr/bin/env python3
"""Interpret the real FillrStore with isolated platform/service test doubles.

This validates Store integration without compiling or launching a FILLR app.
Native engine behavior is covered separately by the Rust tests.
"""

from pathlib import Path
import os
import subprocess
import tempfile
import unittest


STUBS = r'''
import AppKit
import Combine
import Foundation
enum PreferencesMigration { static func migrate(defaults: UserDefaults) {} }
enum UpdatePolicy { static func canInstall(building: Bool, openEditors: Int) -> Bool { !building && openEditors == 0 } }
@MainActor final class BackgroundController: ObservableObject {
    @Published var isBusy = false
    init(defaults: UserDefaults) {}
    func configureCollection(plan: BackgroundFootagePlan?, useAllFootage: Bool, selected: Bool) {}
}
struct BackgroundFootageAssignment { let comp: Int; let sources: [URL] }
struct BackgroundFootagePlan {
    let assignments: [BackgroundFootageAssignment]
    static func loadExport(at url: URL) throws -> Self { throw BridgeError.message("No export in Store source tests") }
}
@MainActor final class DownloadTranscodeController: ObservableObject {
    @Published var isBusy = false
    @Published var downloadSpeeds: [DownloadInfo] = []
    var enabled: Bool
    init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: "downloads.transcodeEnabled") == nil || defaults.bool(forKey: "downloads.transcodeEnabled")
    }
    nonisolated static func collectionFolder(for source: URL) -> URL { source.appendingPathComponent("ProRes LT") }
    func setEnabled(_ enabled: Bool) { self.enabled = enabled }
    func start(folder: URL?) {}
    func cancel() {}
}
struct DownloadTranscodeWorker {
    init(root: URL) {}
    func prepare() throws {}
    static func retiredSourceNames(root: URL, sources: [ClipInfo]) -> Set<String> { [] }
}
enum DockIconStyle: String, CaseIterable {
    case clean
    static let preferenceKey = "dockIconStyle"
    init(savedValue: String?) { self = .clean }
    func thumbnail(resourceURL: URL?) -> NSImage? { nil }
}
@MainActor final class DockIconController {
    init(resourceURL: URL?, style: DockIconStyle) {}
    func update(available: UInt64, total: UInt64) {}
    func start(completion: () -> Void) { completion() }
    func preview(completion: () -> Void) { completion() }
    func setStyle(_ style: DockIconStyle) -> Bool { true }
}
@MainActor final class OverlayController { func setVisible(_ visible: Bool, store: FillrStore) {} }
struct UNAuthorizationOptions: OptionSet {
    let rawValue: Int
    static let alert = Self(rawValue: 1)
    static let sound = Self(rawValue: 2)
}
final class UNMutableNotificationContent { var title = ""; var body = "" }
struct UNNotificationRequest { init(identifier: String, content: UNMutableNotificationContent, trigger: Any?) {} }
final class UNUserNotificationCenter {
    static func current() -> UNUserNotificationCenter { Self() }
    func requestAuthorization(options: UNAuthorizationOptions, completionHandler: (Bool, Error?) -> Void) { completionHandler(false, nil) }
    func add(_ request: UNNotificationRequest) {}
}
protocol EngineSession: AnyObject, Sendable {
    func snapshot() throws -> EngineSnapshot
    func build() throws -> BuildResponse.Result
    func refresh()
    func setConfiguration(policy: MediaPolicy, settings: SortSettings) throws
}
enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}
final class EngineBridge: EngineSession, @unchecked Sendable {
    init(folder: URL, policy: MediaPolicy, settings: SortSettings, readOnly: Bool = false) throws {
        throw BridgeError.message("Native engine unavailable in Store source tests")
    }
    func snapshot() throws -> EngineSnapshot { throw BridgeError.message("Unexpected native snapshot") }
    func build() throws -> BuildResponse.Result { throw BridgeError.message("Unexpected native build") }
    func refresh() {}
    func setConfiguration(policy: MediaPolicy, settings: SortSettings) throws {}
    static func validate(settings: SortSettings) throws { try settings.validate() }
    static func validate(policy: MediaPolicy) throws {}
}
'''


class DownloadProgressStoreSourceTests(unittest.TestCase):
    def test_actual_store_integration(self):
        root = Path(__file__).resolve().parents[1]
        paths = [
            root / "native/macos/Sources/FILLR/Models/EngineModels.swift",
            root / "native/macos/Sources/FILLR/Models/DownloadFootageProgress.swift",
            root / "native/macos/Sources/FILLR/Models/MediaPolicy.swift",
            root / "native/macos/Sources/FILLR/Models/SortSettings.swift",
            root / "native/macos/Sources/FILLR/Services/FillrStore.swift",
            root / "native/macos/Tests/FILLRTests/DownloadProgressStoreTests.swift",
        ]
        source = STUBS + "\n" + "\n".join(path.read_text() for path in paths)
        for import_line in ("@testable import FILLR\n", "import AppPreferences\n", "import UpdatePolicy\n", "import BackgroundPlanning\n", "import UserNotifications\n"):
            source = source.replace(import_line, "")
        source += '''
let standaloneSuite = DownloadProgressStoreTests.defaultTestSuite
standaloneSuite.run()
let standaloneRun = standaloneSuite.testRun!
precondition(standaloneRun.executionCount == 4, "Missing Store test execution")
exit(standaloneRun.hasSucceeded ? 0 : 1)
'''
        developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
        platform = developer / "Platforms/MacOSX.platform/Developer"
        frameworks = platform / "Library/Frameworks"
        libraries = platform / "usr/lib"
        with tempfile.TemporaryDirectory(prefix="fillr-store-tests-") as temporary:
            directory = Path(temporary)
            main = directory / "main.swift"
            main.write_text(source)
            result = subprocess.run(
                ["xcrun", "swift", "-I", str(libraries), "-F", str(frameworks), "-L", str(libraries),
                 "-module-cache-path", str(directory / "module-cache"), str(main)],
                env={**os.environ, "DYLD_FRAMEWORK_PATH": str(frameworks), "DYLD_LIBRARY_PATH": str(libraries)},
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180,
            )
            print(result.stdout)
            self.assertEqual(result.returncode, 0, result.stdout)


if __name__ == "__main__":
    unittest.main()
