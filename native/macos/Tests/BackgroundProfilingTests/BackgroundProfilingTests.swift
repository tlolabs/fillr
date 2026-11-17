import BackgroundProfiling
import CryptoKit
import Foundation
import XCTest

final class BackgroundProfilingTests: XCTestCase {
    func testOnlyCompletedVerifiedBackendMatchesCanWin() throws {
        let hardware = scan()
        let requestedHardware = settings(queue: 2)
        let software = settings(queue: 1, hardware: false)
        let trials = [
            try trial(settings: requestedHardware, elapsed: 1, hardware: nil),
            try trial(settings: software, elapsed: 4, hardware: false),
            try trial(settings: settings(queue: 3), elapsed: 0.1, hardware: true, status: "failed")
        ]
        let report = BackgroundBenchmarkReport(mode: .quick, source: .actualProject, hardware: hardware,
            workloadFingerprint: "test", trials: trials, expectedTrialCount: 3)
        XCTAssertEqual(report.successfulConfigurations.count, 1)
        XCTAssertEqual(report.recommendation(for: .fastest)?.settings, software)
        XCTAssertNotNil(trials[0].failureReason)
        XCTAssertFalse(trials[2].eligible)
    }

    func testIncompleteFramesAndBackendFallbackAreRejected() throws {
        let requested = settings(queue: 2)
        let partial = try trial(settings: requested, elapsed: 1, hardware: true, completed: 59)
        let fallback = try trial(settings: requested, elapsed: 1, hardware: false)
        XCTAssertFalse(partial.eligible)
        XCTAssertFalse(fallback.eligible)
    }

    func testThoroughUsesMedianAndRequiresEveryWindow() throws {
        let first = settings(queue: 2), second = settings(queue: 1)
        let trials = try [1.0, 10.0, 10.0].enumerated().map {
            try trial(settings: first, elapsed: $0.element, hardware: true, repetition: $0.offset)
        } + [5.0, 5.0, 5.0].enumerated().map {
            try trial(settings: second, elapsed: $0.element, hardware: true, repetition: $0.offset)
        }
        let report = BackgroundBenchmarkReport(mode: .thorough, source: .actualProject, hardware: scan(),
            workloadFingerprint: "test", trials: trials, expectedTrialCount: 6)
        XCTAssertEqual(report.recommendation(for: .fastest)?.settings, second)
        let incomplete = BackgroundBenchmarkReport(mode: .thorough, source: .actualProject, hardware: scan(),
            workloadFingerprint: "test", trials: Array(trials.dropLast()), expectedTrialCount: 6)
        XCTAssertTrue(incomplete.successfulConfigurations.isEmpty)
    }

    func testBalancedUsesMeasuredNearFastestWithFewerResources() throws {
        let fastest = settings(queue: 4), balanced = settings(queue: 2), responsive = settings(queue: 1)
        let trials = try [
            trial(settings: fastest, elapsed: 1, hardware: true),
            trial(settings: balanced, elapsed: 1.05, hardware: true),
            trial(settings: responsive, elapsed: 2, hardware: true)
        ]
        let report = BackgroundBenchmarkReport(mode: .quick, source: .builtIn, hardware: scan(),
            workloadFingerprint: "test", trials: trials, expectedTrialCount: 3)
        XCTAssertEqual(report.recommendation(for: .fastest)?.settings, fastest)
        XCTAssertEqual(report.recommendation(for: .balanced)?.settings, balanced)
        XCTAssertEqual(report.recommendation(for: .responsive)?.settings, responsive)
    }

    func testCancelledBenchmarkNeverAppliesPartialWinner() throws {
        let trials = try [trial(settings: settings(queue: 2), elapsed: 2, hardware: true)]
        let report = BackgroundBenchmarkReport(mode: .quick, source: .builtIn, hardware: scan(),
            workloadFingerprint: "test", trials: trials, expectedTrialCount: 3, cancelled: true)
        XCTAssertNil(report.recommendation(for: .fastest))
    }

    @MainActor
    func testSelectionAndManualOverridesPersistAndInvalidValuesDoNot() throws {
        let name = "org.fillr.tests.background.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profiler = BackgroundProfiler(defaults: defaults, hardwareProvider: { self.scan() })
        profiler.selectedProfile = .responsive
        profiler.overrides = BackgroundSettingsOverrides(decoderThreads: 3, sourceQueueFrames: 3)
        let restored = BackgroundProfiler(defaults: defaults, hardwareProvider: { self.scan() })
        XCTAssertEqual(restored.selectedProfile, .responsive)
        XCTAssertEqual(restored.effectiveSettings.decoderThreads, 3)
        XCTAssertEqual(restored.effectiveSettings.sourceQueueFrames, 3)
        XCTAssertEqual(restored.effectiveSettings.encoderInflightFrames, 2)
        restored.overrides = BackgroundSettingsOverrides(decoderThreads: 100)
        XCTAssertEqual(restored.effectiveSettings.decoderThreads, 3)
        XCTAssertNotNil(restored.error)
        restored.resetOverrides()
        XCTAssertEqual(restored.effectiveSettings.decoderThreads, 1)
        XCTAssertTrue(restored.recommendationSummary.contains("has not been measured"))
        restored.markWorkloadChanged()
        let invalidated = BackgroundProfiler(defaults: defaults, hardwareProvider: { self.scan() })
        XCTAssertTrue(invalidated.workloadChanged)
    }

    func testHardwareAndAppChangesInvalidateMeasurement() {
        let report = BackgroundBenchmarkReport(mode: .quick, source: .builtIn, hardware: scan(),
            workloadFingerprint: "test", trials: [], expectedTrialCount: 1)
        XCTAssertFalse(report.isStale(for: scan()))
        XCTAssertTrue(report.isStale(for: scan(version: "2")))
        XCTAssertTrue(report.isStale(for: scan(memory: 16 * 1024 * 1024 * 1024)))
    }

    func testSourceChangeInvalidatesWorkloadFingerprint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = directory.appendingPathComponent("clip.mpg")
        try Data([1]).write(to: clip)
        let data = try job(path: clip.path)
        let fingerprint = try BackgroundBenchmarkJobs.fingerprint(data)
        let report = BackgroundBenchmarkReport(mode: .quick, source: .actualProject, hardware: scan(),
            workloadFingerprint: fingerprint, workloadJSON: data, trials: [], expectedTrialCount: 1)
        XCTAssertFalse(report.isStale(for: scan()))
        try Data([1, 2, 3]).write(to: clip)
        XCTAssertTrue(report.isStale(for: scan()))
    }

    func testSamplingPreservesCutsAndSourceInPointsForAllPanels() throws {
        let data = try job(path: "/fixture/first.mpg")
        let sample = try BackgroundBenchmarkJobs.sample(data, frames: 60, offsetFrames: 80)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: sample) as? [String: Any])
        let panels = try XCTUnwrap(value["panels"] as? [[String: Any]])
        let bands = try XCTUnwrap(value["bands"] as? [[String: Any]])
        XCTAssertEqual(bands[0]["start_x"] as? Double ?? -1, 10 + 20 * 80 * 1001.0 / 30000, accuracy: 1e-8)
        XCTAssertEqual(panels.count, 15)
        for panel in panels {
            let segments = try XCTUnwrap(panel["segments"] as? [[String: Any]])
            XCTAssertEqual(segments.count, 2)
            XCTAssertEqual(segments[0]["frames"] as? Int, 20)
            XCTAssertEqual(segments[1]["frames"] as? Int, 40)
            XCTAssertEqual(segments[0]["source_in_seconds"] as? Double ?? -1, 2 + 80 * 1001.0 / 30000, accuracy: 1e-8)
            XCTAssertEqual(segments[1]["source_in_seconds"] as? Double, 5)
        }
        XCTAssertThrowsError(try BackgroundBenchmarkJobs.sample(data, frames: 201))
    }

    func testRepeatedSourceFingerprintPreservesMetadataAndRefreshesBetweenCalls() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("placeholder.bin")
        try Data([1, 2]).write(to: source)
        let segment: [String: Any] = ["path": source.path, "frames": 1]
        let panels = (1...15).map { ["comp": $0, "segments": [segment, segment]] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["panels": panels])
        let info = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let expectedSegment: [String: Any] = ["path": source.standardizedFileURL.path, "frames": 1,
            "file_size": try XCTUnwrap(info.fileSize),
            "modified": try XCTUnwrap(info.contentModificationDate).timeIntervalSince1970]
        let expectedPanels = (1...15).map {
            ["comp": $0, "segments": [expectedSegment, expectedSegment]] as [String: Any]
        }
        let canonical = try JSONSerialization.data(withJSONObject: ["panels": expectedPanels], options: [.sortedKeys])
        let expected = SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
        let first = try BackgroundBenchmarkJobs.fingerprint(data)
        XCTAssertEqual(first, expected)

        try Data([1, 2, 3, 4, 5]).write(to: source)
        XCTAssertNotEqual(try BackgroundBenchmarkJobs.fingerprint(data), first,
                          "Metadata reuse must end with each fingerprint call")
    }

    func testSettingsNeverModifyOutputQualityAndRejectInvalidBounds() throws {
        let options = try settings(queue: 2).nativeJSON(benchmark: true)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: options) as? [String: Any])
        XCTAssertEqual(value["benchmark"] as? Bool, true)
        XCTAssertNil(value["bitrate"])
        XCTAssertNil(value["width"])
        XCTAssertThrowsError(try BackgroundAccelerationSettings(decoderThreads: 0).validate())
        XCTAssertThrowsError(try BackgroundAccelerationSettings(sourceQueueFrames: 5).validate())
    }

    func testSampleRejectsOverflowingFrameRangesWithoutTrapping() throws {
        let data = try job(path: "/fixture/first.mpg")
        XCTAssertThrowsError(try BackgroundBenchmarkJobs.sample(data, frames: Int.max, offsetFrames: 1))
        XCTAssertThrowsError(try BackgroundBenchmarkJobs.sample(data, frames: 60, offsetFrames: Int.max))
        XCTAssertThrowsError(try BackgroundBenchmarkJobs.sample(data, frames: 1, offsetFrames: Int.max))
        let lastFrame = try BackgroundBenchmarkJobs.sample(data, frames: 1, offsetFrames: 199)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: lastFrame) as? [String: Any])
        XCTAssertEqual(value["frames"] as? Int, 1)
    }

    func testBuiltInNativeFootageCreatesNewDirectoryAndCanBeProbed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fillr-native-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobData = try NativeBackgroundClient.makeTestJob(directory: directory, frames: 3)
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: jobData) as? [String: Any])
        let panels = try XCTUnwrap(job["panels"] as? [[String: Any]])
        let first = try XCTUnwrap(panels.first?["segments"] as? [[String: Any]])
        let path = try XCTUnwrap(first.first?["path"] as? String)
        let metadata = try NativeBackgroundClient.probe(URL(fileURLWithPath: path))
        XCTAssertEqual(metadata["codec_name"] as? String, "mpeg2video")
        XCTAssertEqual(metadata["width"] as? Int, 1920)
        XCTAssertEqual(metadata["height"] as? Int, 1080)
        XCTAssertEqual(panels.count, 15)
        XCTAssertEqual((job["bands"] as? [[String: Any]])?.count, 2)
        XCTAssertThrowsError(try NativeBackgroundClient.makeTestJob(directory: directory, frames: 3))
        XCTAssertThrowsError(try NativeBackgroundClient.makeTestJob(directory: directory, frames: 1801))
    }

    private func settings(queue: Int, hardware: Bool = true) -> BackgroundAccelerationSettings {
        BackgroundAccelerationSettings(hardwareEncode: hardware, sourceQueueFrames: queue)
    }
    private func scan(version: String = "1", memory: UInt64 = 32 * 1024 * 1024 * 1024) -> BackgroundHardwareScan {
        BackgroundHardwareScan(model: "TestMac", processor: "TestCPU", logicalCPUs: 12,
            memoryBytes: memory, architecture: "arm64", operatingSystem: "testOS", applicationVersion: version,
            metalDevices: ["TestGPU"], unifiedMemory: true, hardwareH264Encode: true,
            hardwareDecodeCodecs: ["H.264"])
    }
    private func trial(settings: BackgroundAccelerationSettings, elapsed: Double, hardware: Bool?,
                       status: String = "complete", completed: Int = 60, repetition: Int = 0) throws -> BackgroundBenchmarkTrial {
        var encoder: [String: Any] = [:]
        if let hardware { encoder["hardware"] = hardware }
        let data = try JSONSerialization.data(withJSONObject: [
            "status": status, "completed_frames": completed, "elapsed_seconds": elapsed, "encoder": encoder
        ])
        return BackgroundBenchmarkTrial(settings: settings, repetition: repetition, sampleOffsetFrames: 0,
            expectedFrames: 60, report: try NativeBackgroundReport(jsonData: data))
    }
    private func job(path: String) throws -> Data {
        let panels: [[String: Any]] = (0..<15).map { index in
            ["comp": index + 1, "segments": [
                ["path": path, "source_in_seconds": 2.0, "frames": 100],
                ["path": "/fixture/second.mpg", "source_in_seconds": 5.0, "frames": 100]
            ]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "frame_rate": "30000/1001", "frames": 200, "panels": panels,
            "bands": [["path": "/work/a.png", "y": 10, "start_x": 10.0, "speed": 20.0],
                      ["path": "/work/b.png", "y": 20, "start_x": 30.0, "speed": 40.0]]
        ])
    }
}
