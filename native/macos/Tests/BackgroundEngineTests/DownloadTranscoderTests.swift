import CBackgroundEngine
import Foundation
import XCTest

final class DownloadTranscoderTests: XCTestCase {
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("fillr-transcode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }
        return result
    }

    private func object(_ pointer: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let value = try XCTUnwrap(pointer)
        defer { fillr_background_free_string(value) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: value).utf8)) as? [String: Any])
    }

    private func source(in directory: URL) throws -> URL {
        let fixtureDirectory = directory.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let report = try fixtureDirectory.path.withCString {
            try object(fillr_background_test_job($0, 3))
        }
        let panels = try XCTUnwrap(report["panels"] as? [[String: Any]])
        let segments = try XCTUnwrap(panels.first?["segments"] as? [[String: Any]])
        return URL(fileURLWithPath: try XCTUnwrap(segments.first?["path"] as? String))
    }

    func testInterlacedMPEG2PreservesBothAudioTracksAndTheirCompleteSamples() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "three-frame-two-audio", withExtension: "mpg", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: source)
        let output = try directory().appendingPathComponent("two-audio.mov")
        let report = try transcode(source, to: output)
        XCTAssertEqual(report["status"] as? String, "complete", "\(report)")
        let verification = try XCTUnwrap(report["verification"] as? [String: Any])
        XCTAssertEqual(verification["frame_count"] as? Int, 3)
        let audio = try XCTUnwrap(verification["audio_tracks"] as? [[String: Any]])
        XCTAssertEqual(audio.count, 2)
        for track in audio {
            XCTAssertEqual(track["samples"] as? Int, 5_760)
            XCTAssertEqual(track["sample_rate"] as? Int, 48_000)
            XCTAssertEqual(track["channels"] as? Int, 1)
        }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testZeroFilledMPEG2SlicePaddingDoesNotRejectCompleteVideo() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "zero-padded-slices", withExtension: "m2v", subdirectory: "Fixtures"))
        let output = try directory().appendingPathComponent("padded.mov")
        let report = try transcode(source, to: output)
        XCTAssertEqual(report["status"] as? String, "complete", "\(report)")
        let verification = try XCTUnwrap(report["verification"] as? [String: Any])
        XCTAssertEqual(verification["frame_count"] as? Int, 3)
        XCTAssertEqual(verification["source_full_decode"] as? Bool, true)
        XCTAssertEqual(verification["full_decode"] as? Bool, true)
    }

    func testAudioFirstSourcePreservesFractionalMillisecondSynchronization() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource: "offset-audio-first", withExtension: "mpg", subdirectory: "Fixtures"))
        let output = try directory().appendingPathComponent("fractional-offset.mov")
        let report = try transcode(source, to: output)
        XCTAssertEqual(report["status"] as? String, "complete", "\(report)")
        let verification = try XCTUnwrap(report["verification"] as? [String: Any])
        XCTAssertEqual(verification["frame_count"] as? Int, 3)
        let audio = try XCTUnwrap(verification["audio_tracks"] as? [[String: Any]])
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(audio.first?["stream"] as? Int, 0, "The reference stream deliberately contains audio")
        XCTAssertEqual(audio.first?["samples"] as? Int, 5_760)
        let synchronization = try XCTUnwrap(verification["synchronization"] as? [[String: Any]])
        let offset = try XCTUnwrap(synchronization.first)
        let sourceOffset = try XCTUnwrap(offset["source_offset_microseconds"] as? Int)
        let outputOffset = try XCTUnwrap(offset["output_offset_microseconds"] as? Int)
        let tolerance = try XCTUnwrap(offset["tolerance_microseconds"] as? Int)
        XCTAssertNotEqual(sourceOffset % 1_000, 0, "The fixture must exercise a fractional millisecond offset")
        XCTAssertLessThanOrEqual(abs(sourceOffset - outputOffset), tolerance)
        XCTAssertLessThan(tolerance, 50, "Verification remains tighter than a fraction of one video frame")
    }

    private func transcode(_ source: URL, to output: URL, cancelled: Bool = false) throws -> [String: Any] {
        let context = try XCTUnwrap(fillr_background_create())
        defer { fillr_background_destroy(context) }
        if cancelled { fillr_background_cancel(context) }
        return try source.path.withCString { input in
            try output.path.withCString { try object(fillr_download_transcode(context, input, $0)) }
        }
    }

    func testCompletedMPEG2BecomesFullyVerifiedProResLTWithoutChangingSource() throws {
        let directory = try directory(), source = try source(in: directory)
        let original = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("provisional.mov")
        let report = try transcode(source, to: output)
        XCTAssertEqual(report["status"] as? String, "complete", "\(report)")
        XCTAssertEqual(report["source_codec"] as? String, "mpeg2video")
        XCTAssertEqual(report["profile"] as? String, "LT")
        let verification = try XCTUnwrap(report["verification"] as? [String: Any])
        XCTAssertEqual(verification["full_decode"] as? Bool, true)
        XCTAssertEqual(verification["source_full_decode"] as? Bool, true)
        XCTAssertEqual(verification["frame_count"] as? Int, 3)
        XCTAssertEqual(try Data(contentsOf: source), original)
        let metadata = try output.path.withCString { try object(fillr_background_probe($0)) }
        XCTAssertEqual(metadata["codec_name"] as? String, "prores")
        XCTAssertEqual(metadata["width"] as? Int, 1920)
        XCTAssertEqual(metadata["height"] as? Int, 1080)
    }

    func testExistingOutputAndCancelledOrInvalidSourcesArePreserved() throws {
        let directory = try directory(), source = try source(in: directory)
        let existing = directory.appendingPathComponent("existing.mov")
        let sentinel = Data("preserved output".utf8)
        try sentinel.write(to: existing)
        let refused = try transcode(source, to: existing)
        XCTAssertEqual(refused["status"] as? String, "failed")
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)

        let cancelledOutput = directory.appendingPathComponent("cancelled.mov")
        let cancelled = try transcode(source, to: cancelledOutput, cancelled: true)
        XCTAssertEqual(cancelled["status"] as? String, "cancelled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledOutput.path))

        let invalidSource = directory.appendingPathComponent("incomplete.mpg")
        try Data("incomplete download".utf8).write(to: invalidSource)
        let invalidOutput = directory.appendingPathComponent("invalid.mov")
        let invalid = try transcode(invalidSource, to: invalidOutput)
        XCTAssertEqual(invalid["status"] as? String, "failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path))
        XCTAssertEqual(try Data(contentsOf: invalidSource), Data("incomplete download".utf8))
    }
}
