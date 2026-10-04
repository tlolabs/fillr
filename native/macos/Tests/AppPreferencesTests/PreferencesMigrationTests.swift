import AppPreferences
import Foundation
import XCTest

final class PreferencesMigrationTests: XCTestCase {
    func testMigratesSavedFolderPolicyAndUpdateChoice() {
        let (defaults, previous, current) = isolatedDefaults()
        defer { clear(defaults, previous, current) }
        let policy = Data(#"{"selected":"keep"}"#.utf8)
        defaults.setPersistentDomain([
            "downloadFolder": "/Users/example/CNN Downloads",
            "mediaPolicy": policy,
            "SUEnableAutomaticChecks": false
        ], forName: previous)

        PreferencesMigration.migrate(defaults: defaults, from: previous, to: current)

        let migrated = defaults.persistentDomain(forName: current)
        XCTAssertEqual(migrated?["downloadFolder"] as? String, "/Users/example/CNN Downloads")
        XCTAssertEqual(migrated?["mediaPolicy"] as? Data, policy)
        XCTAssertEqual(migrated?["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertNotNil(defaults.persistentDomain(forName: previous))
    }

    func testExistingNewPreferencesTakePriorityAndMigrationIsRepeatable() {
        let (defaults, previous, current) = isolatedDefaults()
        defer { clear(defaults, previous, current) }
        defaults.setPersistentDomain([
            "downloadFolder": "/old",
            "mediaPolicy": Data([1]),
            "SUEnableAutomaticChecks": false
        ], forName: previous)
        defaults.setPersistentDomain([
            "downloadFolder": "/new",
            "mediaPolicy": Data([2]),
            "SUEnableAutomaticChecks": true
        ], forName: current)

        PreferencesMigration.migrate(defaults: defaults, from: previous, to: current)
        PreferencesMigration.migrate(defaults: defaults, from: previous, to: current)

        let migrated = defaults.persistentDomain(forName: current)
        XCTAssertEqual(migrated?["downloadFolder"] as? String, "/new")
        XCTAssertEqual(migrated?["mediaPolicy"] as? Data, Data([2]))
        XCTAssertEqual(migrated?["SUEnableAutomaticChecks"] as? Bool, true)
    }

    private func isolatedDefaults() -> (UserDefaults, String, String) {
        let prefix = "com.tlolabs.fillr.tests.\(UUID().uuidString)"
        let current = prefix + ".current"
        return (UserDefaults(suiteName: current)!, prefix + ".previous", current)
    }

    private func clear(_ defaults: UserDefaults, _ previous: String, _ current: String) {
        defaults.removePersistentDomain(forName: previous)
        defaults.removePersistentDomain(forName: current)
    }
}
