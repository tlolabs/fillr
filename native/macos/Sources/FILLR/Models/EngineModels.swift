import Foundation

struct ClipInfo: Decodable, Identifiable {
    let filename: String
    let duration_ms: UInt64
    let size_bytes: UInt64
    let modified_ms: UInt64
    var id: String { filename }
}

struct ExcludedInfo: Decodable, Identifiable {
    let filename: String
    let reason: String
    var id: String { filename }
}

struct CompInfo: Decodable, Identifiable {
    let comp: Int
    let filenames: [String]
    let duration_ms: UInt64
    var id: Int { comp }
}

struct BuildPlan: Decodable {
    let seed: UInt64
    let assignments: [CompInfo]
    let selected_duration_ms: UInt64
}

struct EngineSnapshot: Decodable {
    let api_version: Int
    let folder: String
    let status: String
    let available_ms: UInt64
    let remaining_ms: UInt64
    let clips: [ClipInfo]
    let pending: [String]
    let excluded: [ExcludedInfo]
    let duplicate_log: [String]
    let plan: BuildPlan?
    let message: String
}

struct BuildResponse: Decodable {
    struct Result: Decodable {
        let output_folder: String
        let selected_clips: Int
        let archived_clips: Int
        let selected_duration_ms: UInt64
    }
    let ok: Bool
    let result: Result?
    let error: String?
}

func clockText(_ milliseconds: UInt64) -> String {
    let seconds = Int((milliseconds + 999) / 1000)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
