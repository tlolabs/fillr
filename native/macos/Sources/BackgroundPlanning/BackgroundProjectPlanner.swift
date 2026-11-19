import Foundation
import CryptoKit
import Darwin

public enum BackgroundProjectPlanner {
    public static let maximumFrames = 7 * 24 * 60 * 60 * 30_000 / 1_001

    /// Creates a new private job directory, native artwork, and the renderer job.
    /// Existing directories are refused so source assets and earlier jobs survive.
    public static func prepare(project: URL?, mediaRoot: URL, intro: URL, showDate: Date,
                               workDirectory: URL, frames: Int = 17_982,
                               useAllFootage: Bool = false, footagePlan: BackgroundFootagePlan? = nil,
                               probe: (URL) throws -> [String: Any]) throws -> Data {
        guard (1...maximumFrames).contains(frames) else { throw BackgroundPlanningError.invalid("Background length must be between one frame and seven days") }
        try Task.checkCancellation()
        let root = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        let project = project?.standardizedFileURL.resolvingSymlinksInPath()
        let intro = intro.standardizedFileURL.resolvingSymlinksInPath()
        let psd = root.appendingPathComponent("Chabot News Backgrounds/Text Crawl.psd")
        for file in [intro, psd] + (footagePlan == nil ? project.map { [$0] } ?? [] : []) {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw BackgroundPlanningError.invalid("Missing source file: \(file.path)")
            }
        }
        let sourceTimelines: [Int: [SourceCut]]
        if let footagePlan {
            sourceTimelines = try planSources(footagePlan, root: root, probe: probe)
        } else {
            guard let project else { throw BackgroundPlanningError.invalid("Choose a Premiere project or a ready footage collection") }
            let sequences = try PremiereProject.load(project: project, mediaRoot: root)
            var timelines: [Int: [SourceCut]] = [:]
            for comp in layout.keys.sorted() where comp != 1 {
                guard let sequence = sequences["Comp \(comp)"] else { throw BackgroundPlanningError.invalid("Missing Comp \(comp) sequence") }
                timelines[comp] = sequence.cuts.map { SourceCut(path: $0.path, sourceInSeconds: $0.sourceInSeconds, frames: $0.frames) }
            }
            sourceTimelines = timelines
        }
        let commonFrames = try sourceTimelines.values.map { cuts in
            try cuts.reduce(0) { total, cut in
                let (next, overflow) = total.addingReportingOverflow(cut.frames)
                guard !overflow, next <= maximumFrames else { throw BackgroundPlanningError.invalid("A news timeline exceeds the seven-day background limit") }
                return next
            }
        }.min() ?? 0
        let renderFrames = useAllFootage ? commonFrames : frames
        guard (1...maximumFrames).contains(renderFrames) else { throw BackgroundPlanningError.invalid("News footage has no complete common timeline") }
        if useAllFootage, footagePlan != nil {
            for (comp, cuts) in sourceTimelines {
                let prefix = cuts.dropLast().reduce(0) { $0 + $1.frames }
                guard prefix < renderFrames else { throw BackgroundPlanningError.invalid("Comp \(comp) cannot include every assigned clip before the common endpoint; rebalance the collection") }
            }
        }
        let introFrames = try completeIntroFrames(probe(intro))
        guard (renderFrames - 1) / introFrames + 1 <= 100_000 else {
            throw BackgroundPlanningError.invalid("The intro is too short for this background length; more than 100,000 repeats would be required")
        }
        var panels: [[String: Any]] = []
        for comp in layout.keys.sorted() {
            try Task.checkCancellation()
            var segments: [[String: Any]] = [], remaining = renderFrames
            if comp == 1 {
                while remaining > 0 {
                    let count = min(remaining, introFrames)
                    segments.append(["path": intro.path, "source_in_seconds": 0, "frames": count])
                    remaining -= count
                }
            } else {
                for cut in sourceTimelines[comp] ?? [] where remaining > 0 {
                    let count = min(remaining, cut.frames)
                    segments.append(["path": cut.path.path, "source_in_seconds": cut.sourceInSeconds, "frames": count])
                    remaining -= count
                }
            }
            guard remaining == 0 else { throw BackgroundPlanningError.invalid("Comp \(comp) is \(remaining) frames too short") }
            panels.append(["comp": comp, "geometry": geometry(comp), "segments": segments])
        }
        // mkdir is exclusive; unlike createDirectory(withIntermediateDirectories:),
        // it cannot reuse a concurrently created or pre-existing destination.
        let work = workDirectory.standardizedFileURL
        guard mkdir(work.path, 0o700) == 0 else {
            throw BackgroundPlanningError.invalid("Choose a new job directory: \(work.path) (\(String(cString: strerror(errno))))")
        }
        let crawl = try BackgroundArtwork.prepare(psd: psd, showDate: showDate, workDirectory: work)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        var job: [String: Any] = [
            "template": "chabot-v27-native-1", "pipeline": "metal-native-hybrid",
            "date": formatter.string(from: showDate), "frames": renderFrames,
            "frame_rate": "30000/1001", "duration_seconds": Double(renderFrames) * 1001 / 30000,
            "intro": intro.path, "psd_template": psd.path,
            "psd_sha256": try hash(psd), "use_all_footage": useAllFootage,
            "footage_source": footagePlan == nil ? "premiere_project" : "ready_collection",
            "panels": panels, "bands": crawl.bands, "crawl": crawl.metadata,
            "limitations": ["The fixed Chabot v27 layout is reconstructed from the supplied Adobe template.",
                            "Native date text, scaling, deinterlacing and color conversion may differ from Adobe's rasterization."]
        ]
        if footagePlan == nil, let project {
            job["project"] = project.path
            job["project_sha256"] = try hash(project)
        }
        let data = try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: work.appendingPathComponent("job.json"), options: .withoutOverwriting)
        return data
    }

    private struct SourceCut {
        let path: URL
        let sourceInSeconds: Double
        let frames: Int
    }

    private struct SourceIdentity: Equatable, Hashable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        static func read(_ file: URL) throws -> SourceIdentity {
            var value = stat()
            guard file.path.withCString({ lstat($0, &value) }) == 0, value.st_mode & S_IFMT == S_IFREG else {
                throw BackgroundPlanningError.invalid("Missing or non-regular footage source: \(file.path)")
            }
            return SourceIdentity(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
        }
    }

    private static func planSources(_ plan: BackgroundFootagePlan, root: URL,
                                    probe: (URL) throws -> [String: Any]) throws -> [Int: [SourceCut]] {
        let expected = Set(layout.keys.filter { $0 != 1 })
        guard plan.assignments.count == expected.count, Set(plan.assignments.map(\.comp)) == expected else {
            throw BackgroundPlanningError.invalid("A background requires all 14 news Comps in the Chabot layout")
        }
        var identities: [URL: SourceIdentity] = [:]
        var usedFiles = Set<String>()
        var result: [Int: [SourceCut]] = [:]
        for assignment in plan.assignments {
            try Task.checkCancellation()
            guard !assignment.sources.isEmpty else { throw BackgroundPlanningError.invalid("Comp \(assignment.comp) has no footage") }
            var cuts: [SourceCut] = []
            for source in assignment.sources {
                try Task.checkCancellation()
                guard source.isFileURL, source.path.hasPrefix("/") else { throw BackgroundPlanningError.invalid("Footage sources must be absolute local file URLs") }
                let source = source.standardizedFileURL
                let identity = try SourceIdentity.read(source)
                let resolved = source.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(root.path + "/") else { throw BackgroundPlanningError.invalid("Footage resolves outside the selected media folder: \(source.path)") }
                guard usedFiles.insert("\(identity.device):\(identity.inode)").inserted else { throw BackgroundPlanningError.invalid("A footage source is assigned more than once: \(source.lastPathComponent)") }
                let metadata = try probe(resolved)
                let stream = (metadata["streams"] as? [[String: Any]])?.first { $0["codec_type"] as? String == "video" } ?? metadata
                guard let rate = (stream["avg_frame_rate"] ?? stream["frame_rate"]) as? String,
                      rate != "0/0" else { throw BackgroundPlanningError.invalid("Footage has no known 30000/1001 frame rate: \(source.lastPathComponent)") }
                let count: Int
                do { count = try completeIntroFrames(metadata) }
                catch { throw BackgroundPlanningError.invalid("Footage must have complete frames at 30000/1001: \(source.lastPathComponent)") }
                guard count <= maximumFrames else { throw BackgroundPlanningError.invalid("Footage exceeds the seven-day background limit: \(source.lastPathComponent)") }
                guard try SourceIdentity.read(source) == identity else {
                    throw BackgroundPlanningError.invalid("Footage changed while its background timeline was being prepared: \(source.path)")
                }
                identities[source] = identity
                cuts.append(SourceCut(path: resolved, sourceInSeconds: 0, frames: count))
            }
            let longest = cuts.indices.max { cuts[$0].frames < cuts[$1].frames }!
            cuts.swapAt(longest, cuts.count - 1)
            result[assignment.comp] = cuts
        }
        for (source, identity) in identities {
            guard try SourceIdentity.read(source) == identity else { throw BackgroundPlanningError.invalid("Footage changed while its background timeline was being prepared: \(source.path)") }
        }
        return result
    }

    static let layout: [Int: (Double, Double, Double)] = [
        1: (479, 270, 0.5), 2: (1199, 135, 0.25), 3: (1679, 135, 0.25),
        4: (1199, 405, 0.25), 5: (1679, 405, 0.25),
        7: (1079, 607.5, 0.125), 8: (1319, 607.5, 0.125),
        9: (1559, 607.5, 0.125), 10: (1798, 606.5, 0.125),
        11: (1079, 741.5, 0.125), 12: (1319, 741.5, 0.125),
        13: (1559, 741.5, 0.125), 14: (1798, 741.5, 0.125),
        15: (1199, 944, 0.25), 16: (1679, 945, 0.25)
    ]

    static func geometry(_ comp: Int) -> [String: Int] {
        let (cx, cy, scale) = layout[comp]!
        let width = Int((1920 * scale).rounded(.toNearestOrEven))
        let height = Int((1080 * scale).rounded(.toNearestOrEven))
        return ["width": width, "height": height,
                "x": Int((cx - Double(width) / 2).rounded(.toNearestOrEven)) + 10,
                "y": Int((cy - Double(height) / 2).rounded(.toNearestOrEven)) + 10,
                "visible_width": width - 20, "visible_height": height - 20]
    }

    static func completeIntroFrames(_ metadata: [String: Any]) throws -> Int {
        let stream = (metadata["streams"] as? [[String: Any]])?.first { $0["codec_type"] as? String == "video" } ?? metadata
        if let rate = (stream["avg_frame_rate"] ?? stream["frame_rate"]) as? String, rate != "0/0" {
            let values = rate.split(separator: "/").compactMap { Double($0) }
            let fps = values.count == 2 && values[1] != 0 ? values[0] / values[1] : Double(rate)
            guard let fps, fps.isFinite, abs(fps - 30000 / 1001.0) < 0.005 else {
                throw BackgroundPlanningError.invalid("Intro must use the template frame rate, 30000/1001")
            }
        }
        func number(_ value: Any?) -> Double? {
            if let value = value as? NSNumber { return value.doubleValue }
            if let value = value as? String { return Double(value) }
            return nil
        }
        let reportedCount = number(stream["frame_count"] ?? stream["nb_frames"])
        let exact = reportedCount.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let format = metadata["format"] as? [String: Any]
        let duration = number(stream["duration_seconds"] ?? stream["duration"] ?? format?["duration"])
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let count = exact ?? duration.map { ($0 * 30000 / 1001).rounded(.toNearestOrEven) }
        guard let count, count.isFinite, count >= 1, count <= Double(Int32.max), count.rounded(.down) == count else {
            throw BackgroundPlanningError.invalid("Intro has no valid complete frame count")
        }
        return Int(count)
    }

    private static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
    }
}
