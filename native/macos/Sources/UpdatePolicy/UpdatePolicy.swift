import Foundation

/// FILLR's stable release contract supplements Sparkle's cryptographic checks.
public enum UpdatePolicy {
    public static func version(_ text: String) -> [UInt32]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var values: [UInt32] = []
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let value = UInt32(part), value <= 65535 else { return nil }
            values.append(value)
        }
        return values
    }

    public static func accepts(current: String, proposed: String, displayed: String,
                               url: URL?, installationType: String) -> Bool {
        guard let old = version(current), let new = version(proposed),
              old.lexicographicallyPrecedes(new), displayed == proposed,
              installationType == "application" else { return false }
        return url?.absoluteString == "https://github.com/tlolabs/fillr/releases/download/v\(proposed)/FILLR-\(proposed)-macos-universal.zip"
    }

    public static func canInstall(building: Bool, openEditors: Int) -> Bool {
        !building && openEditors == 0
    }
}
