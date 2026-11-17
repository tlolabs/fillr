import Foundation

enum BackgroundBenchmarkRunner {
    static func run(job: Data?, sourceDirectory: URL?, mode: BackgroundBenchmarkMode,
                    workDirectory: URL, hardware: BackgroundHardwareScan,
                    cancellation: BackgroundCancellation,
                    progress: @escaping @Sendable (String) -> Void) throws -> BackgroundBenchmarkReport {
        try cancellation.check()
        let directory = workDirectory.appendingPathComponent("benchmark-results", isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw BackgroundProfilingError.native("The benchmark results directory already exists. Choose a new work directory.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        progress("Preparing benchmark footage…")
        let input = try prepareInput(job: job, sourceDirectory: sourceDirectory, mode: mode,
                                     directory: directory, cancellation: cancellation)
        let fingerprint = input.source == .builtIn ? "built-in-chabot-benchmark-v1" : try BackgroundBenchmarkJobs.fingerprint(input.job)
        let candidates = candidates(for: hardware, mode: mode)
        let total = candidates.count * mode.repetitions
        let inputObject = try JSONSerialization.jsonObject(with: input.job) as! [String: Any]
        let totalFrames = (inputObject["frames"] as? NSNumber)?.intValue ?? 0
        let sampleFrames = min(mode.framesPerSample, totalFrames)
        guard sampleFrames > 0 else { throw BackgroundProfilingError.invalidJob("No footage frames are available.") }
        var trials: [BackgroundBenchmarkTrial] = []
        // Alternate the configuration order between sample windows so the last
        // candidate does not always bear the same cache/thermal conditions.
        outer: for repetition in 0..<mode.repetitions {
            let offset = mode == .quick ? 0 : Int((Double(totalFrames - sampleFrames) * Double(repetition) / 2).rounded())
            let sample = try BackgroundBenchmarkJobs.sample(input.job, frames: sampleFrames, offsetFrames: offset)
            let ordered = repetition % 2 == 0 ? candidates : candidates.reversed().map { $0 }
            for settings in ordered {
                if cancellation.isCancelled { break outer }
                let sequence = trials.count + 1
                let output = directory.appendingPathComponent(String(format: "sample-%02d.mp4", sequence))
                progress("\(mode.title) benchmark \(sequence) of \(total) — \(input.source.title)")
                let trial: BackgroundBenchmarkTrial
                do {
                    let report = try NativeBackgroundClient.render(job: sample, output: output,
                        settings: settings, cancellation: cancellation, benchmark: true)
                    trial = BackgroundBenchmarkTrial(settings: settings, repetition: repetition,
                        sampleOffsetFrames: offset, expectedFrames: sampleFrames, report: report)
                } catch {
                    trial = BackgroundBenchmarkTrial(settings: settings, repetition: repetition,
                        sampleOffsetFrames: offset, expectedFrames: sampleFrames, report: nil,
                        error: error.localizedDescription)
                }
                trials.append(trial)
                try JSONEncoder().encode(trial).write(to: output.deletingPathExtension().appendingPathExtension("json"), options: .withoutOverwriting)
            }
        }
        let report = BackgroundBenchmarkReport(mode: mode, source: input.source, hardware: hardware,
            workloadFingerprint: fingerprint, workloadJSON: input.source == .builtIn ? nil : input.job,
            trials: trials, expectedTrialCount: total,
            cancelled: cancellation.isCancelled)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .withoutOverwriting)
        return report
    }

    static func candidates(for hardware: BackgroundHardwareScan, mode: BackgroundBenchmarkMode) -> [BackgroundAccelerationSettings] {
        let base = hardware.proposedSettings(for: .fastest)
        var values = [base,
            BackgroundAccelerationSettings(hardwareDecode: false, hardwareEncode: base.hardwareEncode,
                decoderThreads: 1, sourceQueueFrames: base.sourceQueueFrames, encoderInflightFrames: 8),
            hardware.proposedSettings(for: .responsive)]
        if mode == .thorough {
            values.append(hardware.proposedSettings(for: .balanced))
            values.append(BackgroundAccelerationSettings(hardwareDecode: base.hardwareDecode,
                hardwareEncode: base.hardwareEncode, decoderThreads: min(2, max(1, hardware.logicalCPUs / 8)),
                sourceQueueFrames: min(4, max(1, base.sourceQueueFrames + 1)), encoderInflightFrames: 8))
            values.append(BackgroundAccelerationSettings(hardwareDecode: false, hardwareEncode: false,
                decoderThreads: 1, sourceQueueFrames: 1, encoderInflightFrames: 2))
        }
        var seen = Set<BackgroundAccelerationSettings>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func prepareInput(job: Data?, sourceDirectory: URL?, mode: BackgroundBenchmarkMode,
                                     directory: URL, cancellation: BackgroundCancellation) throws -> (job: Data, source: BackgroundBenchmarkSource) {
        if let job {
            _ = try BackgroundBenchmarkJobs.sample(job, frames: 1)
            return (job, .actualProject)
        }
        let media = try discoverMedia(in: sourceDirectory, cancellation: cancellation)
        let frameCount = mode.framesPerSample * mode.repetitions
        // This only provides a native layout and raster banners when actual media
        // are selected. Every source segment is replaced before benchmarking.
        let synthetic = try NativeBackgroundClient.makeTestJob(directory: directory.appendingPathComponent("test-input"), frames: frameCount)
        guard !media.isEmpty else { return (synthetic, .builtIn) }
        var usable: [(url: URL, frames: Int)] = [], failures: [String] = []
        for url in media {
            try cancellation.check()
            do {
                let info = try NativeBackgroundClient.probe(url)
                let rate = info["frame_rate"] as? String ?? info["r_frame_rate"] as? String ?? ""
                let pieces = rate.split(separator: "/").compactMap { Double($0) }
                let fps = pieces.count == 2 && pieces[1] != 0 ? pieces[0] / pieces[1] : Double(rate) ?? 0
                guard abs(fps - 30000.0 / 1001) < 0.005 else {
                    throw BackgroundProfilingError.invalidJob("\(url.lastPathComponent) does not use 29.97 fps.")
                }
                let duration = (info["duration_seconds"] as? NSNumber)?.doubleValue
                    ?? (info["duration"] as? NSNumber)?.doubleValue ?? Double(info["duration"] as? String ?? "") ?? 0
                let count = (info["frame_count"] as? NSNumber)?.intValue
                    ?? (info["nb_frames"] as? NSNumber)?.intValue ?? Int(info["nb_frames"] as? String ?? "") ?? 0
                let available = count > 0 ? count : (duration.isFinite && duration > 0 ? Int((duration * fps).rounded(.down)) : 0)
                guard available > 0 else { throw BackgroundProfilingError.invalidJob("No usable frame duration in \(url.lastPathComponent).") }
                usable.append((url, available))
                if usable.count == 15 { break }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        guard !usable.isEmpty else {
            throw BackgroundProfilingError.native("Actual footage exists but could not be benchmarked. \(failures.prefix(3).joined(separator: " "))")
        }
        var value = try JSONSerialization.jsonObject(with: synthetic) as! [String: Any]
        var panels = value["panels"] as! [[String: Any]]
        for index in panels.indices {
            let source = usable[index % usable.count]
            var remaining = frameCount, segments: [[String: Any]] = []
            while remaining > 0 {
                let take = min(source.frames, remaining)
                segments.append(["path": source.url.path, "source_in_seconds": 0.0, "frames": take])
                remaining -= take
            }
            panels[index]["segments"] = segments
        }
        value["panels"] = panels
        return (try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), .actualFootage)
    }

    private static func discoverMedia(in directory: URL?, cancellation: BackgroundCancellation) throws -> [URL] {
        guard let directory else { return [] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw BackgroundProfilingError.native("The benchmark media location is not a folder.") }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw BackgroundProfilingError.native("The actual footage folder could not be read.")
        }
        let extensions: Set<String> = ["mpg", "mpeg", "m2v", "mov", "mp4", "m4v", "mxf", "avi", "mkv", "ts", "m2ts", "mts", "webm"]
        var files: [URL] = []
        for case let url as URL in enumerator {
            try cancellation.check()
            if extensions.contains(url.pathExtension.lowercased()),
               (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
