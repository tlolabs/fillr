import Foundation

struct SortSettings: Codable, Equatable {
    var folder_count = 14
    var folder_prefix = "Comp"
    var total_ms: UInt64 = 8_470_000
    var use_all_clips = true

    init(folder_count: Int = 14, folder_prefix: String = "Comp", total_ms: UInt64 = 8_470_000,
         use_all_clips: Bool = true) {
        self.folder_count = folder_count
        self.folder_prefix = folder_prefix
        self.total_ms = total_ms
        self.use_all_clips = use_all_clips
    }

    private enum CodingKeys: String, CodingKey {
        case folder_count, folder_prefix, total_ms, use_all_clips
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folder_count = try values.decode(Int.self, forKey: .folder_count)
        folder_prefix = try values.decode(String.self, forKey: .folder_prefix)
        total_ms = try values.decode(UInt64.self, forKey: .total_ms)
        use_all_clips = try values.decodeIfPresent(Bool.self, forKey: .use_all_clips) ?? true
    }

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
