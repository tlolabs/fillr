import Foundation

public enum PreferencesMigration {
    public static let previousBundleIdentifier = "edu.chabot.news.backgrounder"
    public static let currentBundleIdentifier = "com.tlolabs.fillr"

    private static let preservedKeys = [
        "downloadFolder",
        "mediaPolicy",
        "SUEnableAutomaticChecks"
    ]

    public static func migrate(
        defaults: UserDefaults = .standard,
        from previous: String = previousBundleIdentifier,
        to current: String = currentBundleIdentifier
    ) {
        guard let priorValues = defaults.persistentDomain(forName: previous) else { return }
        var currentValues = defaults.persistentDomain(forName: current) ?? [:]
        var changed = false
        for key in preservedKeys where currentValues[key] == nil {
            if let value = priorValues[key] {
                currentValues[key] = value
                changed = true
            }
        }
        if changed { defaults.setPersistentDomain(currentValues, forName: current) }
    }
}
