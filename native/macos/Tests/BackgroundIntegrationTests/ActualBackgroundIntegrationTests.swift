import BackgroundPlanning
import BackgroundProfiling
import Foundation
import XCTest

/// Opt-in integration evidence against owner-supplied media. Ordinary tests use
/// synthetic fixtures and do not depend on a proprietary asset tree.
final class ActualBackgroundIntegrationTests: XCTestCase {
    func testActualBackgroundBenchmarkAndFullRenderWhenRequested() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mediaPath = environment["FILLR_BACKGROUND_TEST_MEDIA"],
              let introPath = environment["FILLR_BACKGROUND_TEST_INTRO"] else {
            throw XCTSkip("Actual Chabot media integration is opt-in through FILLR_BACKGROUND_TEST_MEDIA and FILLR_BACKGROUND_TEST_INTRO.")
        }
        let media = URL(fileURLWithPath: mediaPath)
        let parent = URL(fileURLWithPath: environment["FILLR_BACKGROUND_TEST_OUTPUT"] ?? NSTemporaryDirectory())
        let directory = parent.appendingPathComponent("native-chabot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 12)))
        let job = try BackgroundProjectPlanner.prepare(
            project: media.appendingPathComponent("Chabot News Backgrounds/CC 2027/Footage.prproj"),
            mediaRoot: media, intro: URL(fileURLWithPath: introPath), showDate: date,
            workDirectory: directory.appendingPathComponent("artwork"),
            probe: { try NativeBackgroundClient.probe($0) })
        let suite = "com.tlolabs.fillr.background-integration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profiler = await MainActor.run { BackgroundProfiler(defaults: UserDefaults(suiteName: suite)!) }
        let mode: BackgroundBenchmarkMode = environment["FILLR_BACKGROUND_TEST_THOROUGH"] == "1" ? .thorough : .quick
        await profiler.runBenchmark(job: job, sourceDirectory: media, mode: mode, workDirectory: directory)
        let evidence = await MainActor.run { (profiler.benchmark, profiler.effectiveSettings, profiler.error) }
        let benchmark = try XCTUnwrap(evidence.0, evidence.2 ?? "No actual-footage benchmark report")
        XCTAssertEqual(benchmark.source, .actualProject)
        XCTAssertTrue(benchmark.isComplete)
        XCTAssertFalse(benchmark.successfulConfigurations.isEmpty, evidence.2 ?? "No verified native settings")
        guard !benchmark.successfulConfigurations.isEmpty else { return }
        print("Native actual-footage evidence: \(directory.path)")
        guard environment["FILLR_BACKGROUND_TEST_FULL_RENDER"] == "1" else { return }
        let output = directory.appendingPathComponent("Chabot Background Native.mp4")
        let report = try NativeBackgroundClient.render(job: job, output: output, settings: evidence.1) { completed, total in
            if completed % 1_800 == 0 || completed == total { print("Native full render: \(completed)/\(total)") }
        }
        try report.jsonData.write(to: directory.appendingPathComponent("render-report.json"), options: .withoutOverwriting)
        XCTAssertTrue(report.success, report.error ?? "Native render failed")
        XCTAssertEqual(report.completedFrames, 17_982)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let metadata = try NativeBackgroundClient.probe(output)
        XCTAssertEqual(metadata["codec_name"] as? String, "h264")
        XCTAssertEqual((metadata["width"] as? NSNumber)?.intValue, 1920)
        XCTAssertEqual((metadata["height"] as? NSNumber)?.intValue, 1080)
        XCTAssertEqual((metadata["frame_count"] as? NSNumber)?.intValue, 17_982)
    }
}
