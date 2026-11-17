import Foundation
import CryptoKit
import Darwin

public enum BackgroundProjectPlanner {
    /// Creates a new private job directory, native artwork, and the renderer job.
    /// Existing directories are refused so source assets and earlier jobs survive.
    public static func prepare(project: URL, mediaRoot: URL, intro: URL, showDate: Date,
                               workDirectory: URL, frames: Int = 17_982,
                               probe: (URL) throws -> [String: Any]) throws -> Data {
        guard (1...17_982).contains(frames) else { throw BackgroundPlanningError.invalid("Background length must be 1–17982 frames") }
        try Task.checkCancellation()
        let root = mediaRoot.standardizedFileURL.resolvingSymlinksInPath()
        let project = project.standardizedFileURL.resolvingSymlinksInPath()
        let intro = intro.standardizedFileURL.resolvingSymlinksInPath()
        let psd = root.appendingPathComponent("Chabot News Backgrounds/Text Crawl.psd")
        for file in [project, intro, psd] {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw BackgroundPlanningError.invalid("Missing source file: \(file.path)")
            }
        }
        let sequences = try PremiereProject.load(project: project, mediaRoot: root)
        let introFrames = try completeIntroFrames(probe(intro))
        var panels: [[String: Any]] = []
        for comp in layout.keys.sorted() {
            try Task.checkCancellation()
            var segments: [[String: Any]] = [], remaining = frames
            if comp == 1 {
                while remaining > 0 {
                    let count = min(remaining, introFrames)
                    segments.append(["path": intro.path, "source_in_seconds": 0, "frames": count])
                    remaining -= count
                }
            } else {
                guard let sequence = sequences["Comp \(comp)"] else { throw BackgroundPlanningError.invalid("Missing Comp \(comp) sequence") }
                for cut in sequence.cuts where remaining > 0 {
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
        let job: [String: Any] = [
            "template": "chabot-v27-native-1", "pipeline": "metal-native-hybrid",
            "date": formatter.string(from: showDate), "frames": frames,
            "frame_rate": "30000/1001", "duration_seconds": Double(frames) * 1001 / 30000,
            "intro": intro.path, "project": project.path, "psd_template": psd.path,
            "project_sha256": try hash(project), "psd_sha256": try hash(psd),
            "panels": panels, "bands": crawl.bands, "crawl": crawl.metadata,
            "limitations": ["The fixed Chabot v27 layout is reconstructed from the supplied Adobe template.",
                            "Native date text, scaling, deinterlacing and color conversion may differ from Adobe's rasterization."]
        ]
        let data = try JSONSerialization.data(withJSONObject: job, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: work.appendingPathComponent("job.json"), options: .withoutOverwriting)
        return data
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
