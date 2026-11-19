import CBackgroundEngine
import Foundation
import Metal
import XCTest

final class NativeBackgroundEngineTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fillr-native-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func object(_ value: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let pointer = try XCTUnwrap(value, "Native API returned no report")
        defer { fillr_background_free_string(pointer) }
        let data = Data(String(cString: pointer).utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func encoded(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func fixture(in directory: URL, frames: Int32 = 3) throws -> [String: Any] {
        try directory.path.withCString { try object(fillr_background_test_job($0, frames)) }
    }

    private func render(job: String, output: URL, settings: [String: Any], preCancelled: Bool = false) throws -> [String: Any] {
        let context = try XCTUnwrap(fillr_background_create())
        defer { fillr_background_destroy(context) }
        if preCancelled { fillr_background_cancel(context) }
        let options = try encoded(settings)
        return try job.withCString { source in
            try output.path.withCString { path in
                try options.withCString { settings in
                    try object(fillr_background_render(context, source, path, settings, nil, nil))
                }
            }
        }
    }

    func testMalformedAndIncompleteProductionJobsNeverPublishOutput() throws {
        let directory = try temporaryDirectory()
        let malformedOutput = directory.appendingPathComponent("malformed.mp4")
        let malformed = try render(job: "{not-json", output: malformedOutput, settings: [:])
        XCTAssertEqual(malformed["status"] as? String, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: malformedOutput.path))

        let shortOutput = directory.appendingPathComponent("short-production.mp4")
        let short = try render(job: "{\"frames\":3}", output: shortOutput, settings: [:])
        XCTAssertEqual(short["status"] as? String, "failed")
        XCTAssertTrue((short["error"] as? String)?.contains("existing Chabot layout") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shortOutput.path))
    }

    func testLongProductionJobsPassFrameCoverageChecksAndKeepSevenDayLimit() throws {
        let output = try temporaryDirectory().appendingPathComponent("long-validation.mp4")
        let panel: [String: Any] = [
            "comp": 1, "geometry": ["width": 1, "height": 1, "visible_width": 1,
                                   "visible_height": 1, "x": 0, "y": 0],
            "segments": [["path": "/fixture/source.mov", "source_in_seconds": 0, "frames": 20_000]]
        ]
        let job: [String: Any] = ["frames": 20_000, "frame_rate": "30000/1001",
                                  "panels": Array(repeating: panel, count: 15), "bands": [[:], [:]]]
        let validLength = try render(job: encoded(job), output: output, settings: [:])
        XCTAssertEqual(validLength["error"] as? String, "Invalid Chabot crawl tile",
                       "A production timeline longer than ten minutes must pass job and source frame validation")
        let maximum = 7 * 24 * 60 * 60 * 30_000 / 1_001
        let excessive = try render(job: encoded(["frames": maximum + 1]), output: output, settings: [:])
        XCTAssertEqual(excessive["error"] as? String, "Invalid setting: frames")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testCancelledJobNeverPublishesOutput() throws {
        let output = try temporaryDirectory().appendingPathComponent("cancelled.mp4")
        let result = try render(job: "{}", output: output, settings: [:], preCancelled: true)
        XCTAssertEqual(result["status"] as? String, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testInvalidSettingsAndWrongSchemaReturnErrorsAcrossCABI() throws {
        let directory = try temporaryDirectory()
        let output = directory.appendingPathComponent("bad-options.mp4")
        let invalidSettings = try render(job: "{}", output: output, settings: ["decoder_threads": 999])
        XCTAssertEqual(invalidSettings["status"] as? String, "failed")
        XCTAssertTrue((invalidSettings["error"] as? String)?.contains("decoder_threads") == true)
        let wrongTypes = try render(job: "{\"frames\":3,\"panels\":5}", output: output,
                                    settings: ["benchmark": true])
        XCTAssertEqual(wrongTypes["status"] as? String, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testIntegerSettingsRejectWrappedValuesAndBooleansAcrossCABI() throws {
        let output = try temporaryDirectory().appendingPathComponent("invalid-integers.mp4")
        let invalid: [Any] = [Int64(4_294_967_297), Int64(-4_294_967_295), true, 1.5, "1", NSNull()]
        for key in ["decoder_threads", "source_queue_frames", "encoder_inflight_frames"] {
            for value in invalid {
                let result = try render(job: "{}", output: output, settings: [key: value])
                XCTAssertEqual(result["status"] as? String, "failed")
                XCTAssertEqual(result["error"] as? String, "Invalid setting: \(key)", "\(key)=\(value)")
            }
        }
        // Valid integral numeric bounds must still reach job validation.
        let valid = try render(job: "{}", output: output,
            settings: ["decoder_threads": 16, "source_queue_frames": 4, "encoder_inflight_frames": 8])
        XCTAssertEqual(valid["error"] as? String, "The Chabot job has no positive frame count")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testJobAndSegmentFramesRejectWrappedValuesAndBooleansBeforeOpeningMedia() throws {
        let output = try temporaryDirectory().appendingPathComponent("invalid-frames.mp4")
        let invalid: [Any] = [Int64(4_294_967_297), Int64(-4_294_967_295), true]
        for value in invalid {
            let result = try render(job: encoded(["frames": value]), output: output, settings: ["benchmark": true])
            XCTAssertEqual(result["error"] as? String, "Invalid setting: frames", "job frames=\(value)")

            let panel: [String: Any] = [
                "comp": 1, "geometry": ["width": 1, "height": 1, "visible_width": 1,
                                       "visible_height": 1, "x": 0, "y": 0],
                "segments": [["path": "/fixture/source.mpg", "source_in_seconds": 0, "frames": value]]
            ]
            let job: [String: Any] = ["frames": 1, "frame_rate": "30000/1001",
                                      "panels": Array(repeating: panel, count: 15), "bands": [[:], [:]]]
            let segmentResult = try render(job: encoded(job), output: output, settings: ["benchmark": true])
            XCTAssertEqual(segmentResult["error"] as? String, "Invalid setting: frames", "segment frames=\(value)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSyntheticMPEG2FootageUsesBundledLibraryAndPreservesExistingFiles() throws {
        let directory = try temporaryDirectory()
        let job = try fixture(in: directory)
        XCTAssertEqual(job["frame_rate"] as? String, "30000/1001")
        XCTAssertEqual((job["panels"] as? [Any])?.count, 15)
        XCTAssertEqual((job["bands"] as? [Any])?.count, 2)
        let panels = try XCTUnwrap(job["panels"] as? [[String: Any]])
        let segments = try XCTUnwrap(panels.first?["segments"] as? [[String: Any]])
        let source = try XCTUnwrap(segments.first?["path"] as? String)
        let initialBytes = try Data(contentsOf: URL(fileURLWithPath: source))
        let metadata = try source.withCString { try object(fillr_background_probe($0)) }
        XCTAssertEqual(metadata["status"] as? String, "complete")
        XCTAssertEqual(metadata["codec_name"] as? String, "mpeg2video")
        XCTAssertEqual(metadata["width"] as? Int, 1920)
        XCTAssertEqual(metadata["height"] as? Int, 1080)
        XCTAssertEqual(metadata["frame_rate"] as? String, "30000/1001")
        let second = try fixture(in: directory)
        XCTAssertEqual(second["status"] as? String, "failed")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source)), initialBytes)
    }

    func testTinyHardwareRenderVerifiesEveryFrameAndRefusesOverwrite() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device is unavailable in this test environment") }
        let directory = try temporaryDirectory()
        let job = try fixture(in: directory)
        let output = directory.appendingPathComponent("tiny.mp4")
        let result = try render(job: encoded(job), output: output, settings: ["benchmark": true, "hardware_encode": true])
        try skipUnavailableEncoder(result)
        XCTAssertEqual(result["status"] as? String, "complete", "\(result["error"] ?? result)")
        let verification = try XCTUnwrap(result["verification"] as? [String: Any])
        XCTAssertEqual(verification["full_decode"] as? Bool, true)
        XCTAssertEqual(verification["frame_count"] as? Int, 3)
        let encoder = try XCTUnwrap(result["encoder"] as? [String: Any])
        XCTAssertEqual(encoder["hardware"] as? Bool, true)
        XCTAssertEqual(encoder["frames_dropped"] as? Int, 0)
        let bytes = try Data(contentsOf: output)
        let repeated = try render(job: encoded(job), output: output, settings: ["benchmark": true])
        XCTAssertEqual(repeated["status"] as? String, "failed")
        XCTAssertEqual(try Data(contentsOf: output), bytes)
    }

    func testMPEG2TrimDecodesHeaderAndExactPresentationOrderPreroll() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device is unavailable in this test environment") }
        let directory = try temporaryDirectory()
        var job = try fixture(in: directory, frames: 60)
        var panels = try XCTUnwrap(job["panels"] as? [[String: Any]])
        for index in panels.indices {
            var segments = try XCTUnwrap(panels[index]["segments"] as? [[String: Any]])
            segments[0]["frames"] = 8
            segments[0]["source_in_seconds"] = 30.0 * 1001.0 / 30000.0
            panels[index]["segments"] = segments
        }
        job["frames"] = 8
        job["panels"] = panels
        let output = directory.appendingPathComponent("trimmed-mpeg2.mp4")
        let result = try render(job: encoded(job), output: output,
            settings: ["benchmark": true, "hardware_decode": false, "hardware_encode": true])
        try skipUnavailableEncoder(result)
        XCTAssertEqual(result["status"] as? String, "complete", "\(result["error"] ?? result)")
        XCTAssertEqual((result["verification"] as? [String: Any])?["frame_count"] as? Int, 8)
        let sources = try XCTUnwrap(result["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 15)
        for source in sources {
            XCTAssertEqual(source["returned_frames"] as? Int, 8)
            XCTAssertEqual(source["discarded_seek_preroll_frames"] as? Int, 30)
            XCTAssertEqual(source["cloned_final_frames"] as? Int, 0)
            let segments = try XCTUnwrap(source["segments"] as? [[String: Any]])
            XCTAssertEqual(segments.first?["decode_preroll_frames"] as? Int, 30)
            XCTAssertEqual(segments.first?["preroll_strategy"] as? String, "decode_from_start_preserve_mpeg2_headers")
        }
    }

    func testRepeatedRendersWithLongUnicodeOutputPathsVerifyAndCleanUp() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device is unavailable in this test environment") }
        let directory = try temporaryDirectory()
        let job = try encoded(fixture(in: directory))
        for folder in ["Output with spaces", "Café footage 🎬", String(repeating: "Long path ", count: 18)] {
            let destination = directory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for attempt in 0..<3 {
                let output = destination.appendingPathComponent("Chabot News Background Café \(attempt).mp4")
                let result = try render(job: job, output: output,
                    settings: ["benchmark": true, "hardware_encode": true])
                try skipUnavailableEncoder(result)
                XCTAssertEqual(result["status"] as? String, "complete", "\(result["error"] ?? result)")
                let verification = try XCTUnwrap(result["verification"] as? [String: Any])
                XCTAssertEqual(verification["full_decode"] as? Bool, true)
                XCTAssertEqual(verification["frame_count"] as? Int, 3)
                let original = try Data(contentsOf: output)
                let repeated = try render(job: job, output: output, settings: ["benchmark": true])
                XCTAssertEqual(repeated["error"] as? String, "Output video already exists")
                XCTAssertEqual(try Data(contentsOf: output), original)
                XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path)
                    .contains { $0.hasPrefix(".fillr-background-") })
            }
        }
    }

    func testExplicitSoftwareEncoderCannotBeReportedAsHardware() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device is unavailable in this test environment") }
        let directory = try temporaryDirectory()
        let job = try fixture(in: directory)
        let output = directory.appendingPathComponent("software.mp4")
        let result = try render(job: encoded(job), output: output,
            settings: ["benchmark": true, "hardware_decode": false, "hardware_encode": false])
        try skipUnavailableEncoder(result)
        // Some OS software encoders omit the active-backend property. That is
        // an unavailable verified candidate, never evidence of either backend.
        if result["status"] as? String == "failed",
           (result["error"] as? String)?.contains("did not confirm the active encoder backend") == true {
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertNil((result["encoder"] as? [String: Any])?["hardware"])
            return
        }
        XCTAssertEqual(result["status"] as? String, "complete", "\(result["error"] ?? result)")
        let encoder = try XCTUnwrap(result["encoder"] as? [String: Any])
        XCTAssertEqual(encoder["hardware"] as? Bool, false)
        XCTAssertEqual(encoder["requested_hardware"] as? Bool, false)
    }

    private func skipUnavailableEncoder(_ result: [String: Any]) throws {
        guard result["status"] as? String != "complete" else { return }
        let message = result["error"] as? String ?? ""
        if message.contains("Create H.264 compression session failed: OSStatus") ||
            message.contains("No Metal GPU is available") {
            throw XCTSkip("Native codec/GPU service is unavailable: \(message)")
        }
    }
}
