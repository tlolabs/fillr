import CryptoKit
import Foundation

public enum BackgroundBenchmarkSource: String, Codable, Sendable {
    case actualProject, actualFootage, builtIn
    public var title: String {
        switch self {
        case .actualProject: return "Actual background project and footage"
        case .actualFootage: return "Actual footage in the Chabot panel layout"
        case .builtIn: return "Built-in test footage"
        }
    }
}

public struct BackgroundBenchmarkTrial: Codable, Identifiable, Sendable {
    public let id: UUID
    public let settings: BackgroundAccelerationSettings
    public let repetition: Int
    public let sampleOffsetFrames: Int
    public let expectedFrames: Int
    public let report: NativeBackgroundReport?
    public let error: String?
    public init(id: UUID = UUID(), settings: BackgroundAccelerationSettings, repetition: Int,
                sampleOffsetFrames: Int, expectedFrames: Int, report: NativeBackgroundReport?, error: String? = nil) {
        self.id = id; self.settings = settings; self.repetition = repetition
        self.sampleOffsetFrames = sampleOffsetFrames; self.expectedFrames = expectedFrames
        self.report = report; self.error = error
    }
    public var eligible: Bool {
        guard error == nil, let report, report.success, report.completedFrames == expectedFrames else { return false }
        // Hardware capability and an encode request cannot prove the active backend.
        return report.hardwareEncoder == settings.hardwareEncode
    }
    public var failureReason: String? {
        if let error { return error }
        guard let report else { return "No native report." }
        if !report.success { return report.error ?? "Native verification did not complete." }
        if report.completedFrames != expectedFrames { return "The sample frame count is incomplete." }
        if report.hardwareEncoder == nil { return "The active encoder backend could not be confirmed." }
        if report.hardwareEncoder != settings.hardwareEncode { return "The encoder backend differed from the requested setting." }
        return nil
    }
}

public struct BackgroundMeasuredConfiguration: Codable, Sendable {
    public let settings: BackgroundAccelerationSettings
    public let medianFramesPerSecond: Double
    public let samples: Int
}

public struct BackgroundBenchmarkReport: Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let mode: BackgroundBenchmarkMode
    public let source: BackgroundBenchmarkSource
    public let hardware: BackgroundHardwareScan
    public let workloadFingerprint: String
    public let workloadJSON: Data?
    public let trials: [BackgroundBenchmarkTrial]
    public let expectedTrialCount: Int
    public let cancelled: Bool
    public init(id: UUID = UUID(), createdAt: Date = Date(), mode: BackgroundBenchmarkMode,
                source: BackgroundBenchmarkSource, hardware: BackgroundHardwareScan,
                workloadFingerprint: String, workloadJSON: Data? = nil,
                trials: [BackgroundBenchmarkTrial], expectedTrialCount: Int,
                cancelled: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.mode = mode; self.source = source
        self.hardware = hardware; self.workloadFingerprint = workloadFingerprint; self.workloadJSON = workloadJSON
        self.trials = trials; self.expectedTrialCount = expectedTrialCount; self.cancelled = cancelled
    }
    public var isComplete: Bool { !cancelled && trials.count == expectedTrialCount && expectedTrialCount > 0 }
    public var successfulConfigurations: [BackgroundMeasuredConfiguration] {
        guard isComplete else { return [] }
        let grouped = Dictionary(grouping: trials, by: \.settings)
        return grouped.compactMap { settings, values in
            guard (try? settings.validate()) != nil, values.count == mode.repetitions,
                  Set(values.map(\.repetition)).count == mode.repetitions,
                  values.allSatisfy(\.eligible) else { return nil }
            let rates = values.compactMap(\.report?.framesPerSecond).sorted()
            let middle = rates.count / 2
            let median = rates.count % 2 == 0 ? (rates[middle - 1] + rates[middle]) / 2 : rates[middle]
            return BackgroundMeasuredConfiguration(settings: settings, medianFramesPerSecond: median, samples: rates.count)
        }.sorted {
            if $0.medianFramesPerSecond == $1.medianFramesPerSecond { return $0.settings.resourceCost < $1.settings.resourceCost }
            return $0.medianFramesPerSecond > $1.medianFramesPerSecond
        }
    }
    public func recommendation(for profile: BackgroundPerformanceProfile) -> BackgroundMeasuredConfiguration? {
        let choices = successfulConfigurations
        guard let fastest = choices.first else { return nil }
        switch profile {
        case .fastest: return fastest
        case .balanced:
            return choices.filter { $0.medianFramesPerSecond >= fastest.medianFramesPerSecond * 0.9 }
                .min { $0.settings.resourceCost < $1.settings.resourceCost }
        case .responsive:
            // Prefer hardware encoding when measured successfully: fewer software
            // encoder threads are usually more useful than a small queue reduction.
            let hardware = choices.filter { $0.settings.hardwareEncode }
            return (hardware.isEmpty ? choices : hardware).min { $0.settings.resourceCost < $1.settings.resourceCost }
        }
    }
    public func isStale(for scan: BackgroundHardwareScan) -> Bool {
        if hardware.fingerprint != scan.fingerprint { return true }
        guard source != .builtIn, let workloadJSON else { return false }
        return (try? BackgroundBenchmarkJobs.fingerprint(workloadJSON)) != workloadFingerprint
    }
}

public enum BackgroundBenchmarkJobs {
    /// Crops each panel at the same timeline offset, retaining original cuts and
    /// source-in points. A malformed real job fails instead of using test footage.
    public static func sample(_ data: Data, frames: Int, offsetFrames: Int = 0) throws -> Data {
        guard frames > 0, offsetFrames >= 0,
              var job = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (job["frames"] as? NSNumber)?.intValue,
              total >= frames, offsetFrames <= total - frames,
              let sourcePanels = job["panels"] as? [[String: Any]], sourcePanels.count == 15,
              let bands = job["bands"] as? [[String: Any]], bands.count == 2,
              job["frame_rate"] as? String == "30000/1001" else {
            throw BackgroundProfilingError.invalidJob("Expected a complete Chabot job with 15 panels and two crawls.")
        }
        var panels: [[String: Any]] = []
        for var panel in sourcePanels {
            guard let segments = panel["segments"] as? [[String: Any]], !segments.isEmpty else {
                throw BackgroundProfilingError.invalidJob("A panel has no footage.")
            }
            var skip = offsetFrames, remaining = frames
            var result: [[String: Any]] = []
            for var segment in segments {
                guard let count = (segment["frames"] as? NSNumber)?.intValue, count > 0,
                      let sourceIn = (segment["source_in_seconds"] as? NSNumber)?.doubleValue,
                      sourceIn.isFinite, sourceIn >= 0, segment["path"] is String else {
                    throw BackgroundProfilingError.invalidJob("Invalid source segment.")
                }
                if skip >= count { skip -= count; continue }
                let take = min(remaining, count - skip)
                segment["source_in_seconds"] = sourceIn + Double(skip) * 1001 / 30000
                segment["frames"] = take
                result.append(segment)
                remaining -= take; skip = 0
                if remaining == 0 { break }
            }
            guard remaining == 0 else { throw BackgroundProfilingError.invalidJob("A panel is shorter than the sample.") }
            panel["segments"] = result
            panels.append(panel)
        }
        job["frames"] = frames; job["panels"] = panels
        job["bands"] = try bands.map { value -> [String: Any] in
            var band = value
            if let start = (band["start_x"] as? NSNumber)?.doubleValue,
               let speed = (band["speed"] as? NSNumber)?.doubleValue {
                let sampledStart = start + speed * Double(offsetFrames) * 1001 / 30000
                guard sampledStart.isFinite else { throw BackgroundProfilingError.invalidJob("Invalid crawl timing.") }
                band["start_x"] = sampledStart
            }
            return band
        }
        job["duration_seconds"] = Double(frames) * 1001 / 30000
        // The layout and output format stay identical; only the measured timeline
        // length is shortened. These samples are never production backgrounds.
        return try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
    }

    public static func fingerprint(_ data: Data) throws -> String {
        guard var job = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BackgroundProfilingError.invalidJob("Invalid JSON.")
        }
        // Generated artwork lives in a unique work directory. Compare its layout,
        // not that temporary path; source identities include size and modification.
        if let bands = job["bands"] as? [[String: Any]] {
            job["bands"] = bands.map { value -> [String: Any] in
                var band = value
                band.removeValue(forKey: "path"); band.removeValue(forKey: "tile_path")
                return band
            }
        }
        if let panels = job["panels"] as? [[String: Any]] {
            // Repeated cuts and panels often share footage. Read each source's
            // metadata once per fingerprint, while keeping later calls fresh.
            var sourceMetadata: [URL: (fileSize: Int, modified: TimeInterval)] = [:]
            job["panels"] = panels.map { value -> [String: Any] in
                var panel = value
                panel.removeValue(forKey: "concat")
                if let segments = panel["segments"] as? [[String: Any]] {
                    panel["segments"] = segments.map { source -> [String: Any] in
                        var segment = source
                        if let path = source["path"] as? String {
                            let url = URL(fileURLWithPath: path).standardizedFileURL
                            segment["path"] = url.path
                            let metadata: (fileSize: Int, modified: TimeInterval)
                            if let cached = sourceMetadata[url] { metadata = cached }
                            else {
                                let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                                metadata = (info?.fileSize ?? -1, info?.contentModificationDate?.timeIntervalSince1970 ?? -1)
                                sourceMetadata[url] = metadata
                            }
                            segment["file_size"] = metadata.fileSize
                            segment["modified"] = metadata.modified
                        }
                        return segment
                    }
                }
                return panel
            }
        }
        for key in ["output", "output_dir", "created_at", "test_label", "date", "show_date"] { job.removeValue(forKey: key) }
        let stable = try JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])
        return SHA256.hash(data: stable).map { String(format: "%02x", $0) }.joined()
    }
}
