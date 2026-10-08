import Foundation

struct SortSettings: Codable, Equatable {
    var folder_count = 14
    var folder_prefix = "Comp"
    var total_ms: UInt64 = 8_470_000

    func validate() throws {
        guard (1...100).contains(folder_count), total_ms > 0, total_ms % 1000 == 0 else {
            throw BridgeError.message("Enter 1–100 folders and a positive total time.")
        }
        let prefix = folder_prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:<>\"|?*"))
        guard !prefix.isEmpty, prefix.utf8.count <= 80, prefix != ".", prefix != "..",
              !prefix.hasSuffix("."), prefix.rangeOfCharacter(from: invalid) == nil else {
            throw BridgeError.message("Folder prefix must be a safe name of 1 to 80 characters.")
        }
    }
}
