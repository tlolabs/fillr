import Foundation
import Darwin

/// The authoritative ready collection layout, before any export renaming.
public struct BackgroundFootagePlan: Equatable, Sendable {
    public let assignments: [BackgroundFootageAssignment]

    public init(assignments: [BackgroundFootageAssignment]) {
        self.assignments = assignments
    }

    /// Restores the selected sources after Build Folders has moved and renamed
    /// them. The journal supplies order and membership; media are probed again
    /// by the planner before any encoding begins.
    public static func loadExport(at exportRoot: URL) throws -> BackgroundFootagePlan {
        let root = exportRoot.standardizedFileURL.resolvingSymlinksInPath()
        var rootInfo = stat()
        guard exportRoot.isFileURL, root.path.withCString({ lstat($0, &rootInfo) }) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw BackgroundPlanningError.invalid("Missing exported footage folder: \(exportRoot.path)")
        }
        let journalURL = root.appendingPathComponent("journal.json")
        var journalInfo = stat()
        guard journalURL.path.withCString({ lstat($0, &journalInfo) }) == 0,
              journalInfo.st_mode & S_IFMT == S_IFREG, journalInfo.st_size <= 4 * 1024 * 1024 else {
            throw BackgroundPlanningError.invalid("Missing, unsafe, or oversized export journal")
        }
        let journal: ExportJournal
        do { journal = try JSONDecoder().decode(ExportJournal.self, from: Data(contentsOf: journalURL)) }
        catch { throw BackgroundPlanningError.invalid("Cannot read exported footage journal: \(error.localizedDescription)") }
        let comps = [2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        guard [2, 3].contains(journal.version), journal.folder_names.count == comps.count,
              Set(journal.folder_names).count == comps.count,
              journal.folder_names.allSatisfy({ safeComponent($0) && $0 != "Unused" }) else {
            throw BackgroundPlanningError.invalid("The export must contain the 14 news folders in a supported journal")
        }
        let groups = Dictionary(uniqueKeysWithValues: zip(journal.folder_names, comps))
        var sources: [Int: [URL]] = [:]
        var seen = Set<URL>()
        for move in journal.moves {
            let parts = move.destination.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2, parts.allSatisfy(safeComponent) else {
                throw BackgroundPlanningError.invalid("Invalid media path in exported footage journal")
            }
            if parts[0] == "Unused" { continue }
            guard let comp = groups[parts[0]] else {
                throw BackgroundPlanningError.invalid("Unexpected media folder in exported footage journal")
            }
            let file = root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])
            var info = stat()
            let resolved = file.resolvingSymlinksInPath()
            guard file.path.withCString({ lstat($0, &info) }) == 0, info.st_mode & S_IFMT == S_IFREG,
                  resolved.path.hasPrefix(root.path + "/"), seen.insert(resolved).inserted else {
                throw BackgroundPlanningError.invalid("Missing, repeated, or unsafe exported footage: \(file.path)")
            }
            sources[comp, default: []].append(resolved)
        }
        guard comps.allSatisfy({ sources[$0]?.isEmpty == false }) else {
            throw BackgroundPlanningError.invalid("An exported news folder has no selected footage")
        }
        return BackgroundFootagePlan(assignments: comps.map { BackgroundFootageAssignment(comp: $0, sources: sources[$0]!) })
    }

    private static func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true
                || "/\\:".contains($0) })
    }

    private struct ExportJournal: Decodable {
        let version: Int
        let folder_names: [String]
        let moves: [ExportMove]
    }

    private struct ExportMove: Decodable { let destination: String }
}

public struct BackgroundFootageAssignment: Equatable, Sendable {
    public let comp: Int
    public let sources: [URL]

    public init(comp: Int, sources: [URL]) {
        self.comp = comp
        self.sources = sources
    }
}
