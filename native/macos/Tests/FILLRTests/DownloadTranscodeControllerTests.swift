import Combine
import Darwin
import Foundation
@testable import FILLR
import XCTest

private final class DownloadTestState: @unchecked Sendable {
    var time: TimeInterval = 0
    var calls = 0
    var trashCalls = 0
    var checks = 0
    var beginCalls = 0
    var endCalls = 0
    var messages: [String] = []
}

final class DownloadTranscodeControllerTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("fillr-download-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func scanTwice(_ worker: DownloadTranscodeWorker, state: DownloadTestState) throws {
        try worker.scan { _, _ in }
        state.time = 31
        try worker.scan { _, _ in }
    }

    private func speedSample(_ size: Int64, inode: UInt64 = 1, temporary: Bool = false,
                             companion: Bool = false, changed: Int64? = nil) -> DownloadSpeedObservation {
        DownloadSpeedObservation(filename: "clip.mpg", fingerprint: DownloadFingerprint(device: 1, inode: inode,
            size: size, modifiedSeconds: changed ?? size, modifiedNanoseconds: 0,
            changedSeconds: changed ?? size, changedNanoseconds: 0), temporary: temporary, hasCompanion: companion)
    }

    func testDownloadSpeedCountsOnlyObservedGrowthAndIncludesPauses() throws {
        var tracker = DownloadSpeedTracker()
        XCTAssertTrue(tracker.sample([speedSample(500)], now: 0).isEmpty)
        let growing = try XCTUnwrap(tracker.sample([speedSample(600)], now: 1).first)
        XCTAssertEqual(growing.observed_bytes, 100)
        XCTAssertEqual(growing.average_bytes_per_second, 100, accuracy: 0.001)
        let paused = try XCTUnwrap(tracker.sample([speedSample(600)], now: 3).first)
        XCTAssertEqual(paused.average_bytes_per_second, 100.0 / 3, accuracy: 0.001)
        _ = tracker.sample([speedSample(1000)], now: 5)
        let finished = try XCTUnwrap(tracker.sample([speedSample(1000)], now: 35).first)
        XCTAssertTrue(finished.completed)
        XCTAssertEqual(finished.observed_bytes, 500)
        XCTAssertEqual(finished.elapsed_ms, 5000)
        XCTAssertEqual(finished.average_bytes_per_second, 100, accuracy: 0.001)
        XCTAssertEqual(tracker.sample([], now: 100).first?.average_bytes_per_second, 100)
    }

    func testExistingAndPreallocatedFilesDoNotInventDownloadSpeeds() {
        var tracker = DownloadSpeedTracker()
        XCTAssertTrue(tracker.sample([speedSample(1_000_000)], now: 0).isEmpty)
        XCTAssertTrue(tracker.sample([speedSample(1_000_000, changed: 1)], now: 10).isEmpty)
        XCTAssertTrue(tracker.sample([speedSample(1_000_000, changed: 1)], now: 50).isEmpty)
        XCTAssertTrue(tracker.sample([], now: 100).isEmpty)
    }

    func testWorkFileRenameKeepsSpeedBaselineAndNeedsSettling() throws {
        var tracker = DownloadSpeedTracker()
        _ = tracker.sample([speedSample(100, temporary: true)], now: 0)
        let active = try XCTUnwrap(tracker.sample([speedSample(500, temporary: true)], now: 2).first)
        XCTAssertEqual(active.average_bytes_per_second, 200, accuracy: 0.001)
        let renamed = try XCTUnwrap(tracker.sample([speedSample(500, changed: 3)], now: 3).first)
        XCTAssertFalse(renamed.completed)
        XCTAssertEqual(renamed.observed_bytes, 400)
        let finished = try XCTUnwrap(tracker.sample([speedSample(500, changed: 3)], now: 33).first)
        XCTAssertTrue(finished.completed)
        XCTAssertEqual(finished.average_bytes_per_second, 200, accuracy: 0.001)
    }

    func testReplacementDownloadUsesNewIdentityBaseline() throws {
        var tracker = DownloadSpeedTracker()
        _ = tracker.sample([speedSample(100)], now: 0)
        _ = tracker.sample([speedSample(500)], now: 2)
        XCTAssertTrue(tracker.sample([speedSample(1000, inode: 2)], now: 3).isEmpty)
        let replacement = try XCTUnwrap(tracker.sample([speedSample(1200, inode: 2)], now: 5).first)
        XCTAssertEqual(replacement.observed_bytes, 200)
        XCTAssertEqual(replacement.average_bytes_per_second, 100, accuracy: 0.001)
    }

    func testTemporaryAndCheckpointCompanionsPreventCompletedSpeedStatus() throws {
        var tracker = DownloadSpeedTracker()
        _ = tracker.sample([speedSample(100, temporary: true)], now: 0)
        _ = tracker.sample([speedSample(500, temporary: true)], now: 2)
        let waiting = try XCTUnwrap(tracker.sample([speedSample(500, companion: true)], now: 40).first)
        XCTAssertFalse(waiting.completed)
        XCTAssertEqual(waiting.average_bytes_per_second, 10, accuracy: 0.001)
    }

    func testDownloadSpeedNamesTrackOnlyMPEGTransfersAndIgnoreCheckpointSidecars() {
        XCTAssertEqual(DownloadSpeedObserver.name("#work_file#clip.mpg")?.0, "clip.mpg")
        XCTAssertEqual(DownloadSpeedObserver.name("#work_file#clip.mpg")?.1, true)
        XCTAssertEqual(DownloadSpeedObserver.name("clip.MPEG.crdownload")?.0, "clip.MPEG")
        XCTAssertEqual(DownloadSpeedObserver.name("clip.MPEG.crdownload")?.1, true)
        XCTAssertNil(DownloadSpeedObserver.name("#chkpt_file#clip.mpg"))
        XCTAssertNil(DownloadSpeedObserver.name("Chabot News Intro.mov"))
        XCTAssertNil(DownloadSpeedObserver.name(".clip.mpg"))
    }

    func testSpeedObserverPreservesActualWorkToFinalRename() throws {
        let root = try directory()
        let work = root.appendingPathComponent("#work_file#clip.mpg")
        let final = root.appendingPathComponent("clip.mpg")
        try Data(repeating: 1, count: 100).write(to: work)
        let observer = DownloadSpeedObserver(root: root)
        XCTAssertTrue(try observer.sample(now: 0).isEmpty)
        let file = try FileHandle(forWritingTo: work)
        try file.seekToEnd()
        try file.write(contentsOf: Data(repeating: 2, count: 400))
        try file.close()
        XCTAssertEqual(try observer.sample(now: 2).first?.observed_bytes, 400)
        try FileManager.default.moveItem(at: work, to: final)
        let renamed = try XCTUnwrap(observer.sample(now: 3).first)
        XCTAssertFalse(renamed.completed)
        XCTAssertEqual(renamed.observed_bytes, 400)
        XCTAssertEqual(try observer.sample(now: 33).first?.completed, true)
    }

    @MainActor
    func testIdleAndSettlingControllerScansNeverBecomeBusy() async throws {
        let root = try directory()
        try Data("new download".utf8).write(to: root.appendingPathComponent("clip.mpg"))
        let suite = "com.tlolabs.fillr.download-idle-test." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = DownloadTranscodeController(defaults: defaults)
        var states: [Bool] = []
        let observation = controller.$isBusy.sink { states.append($0) }
        controller.start(folder: root)
        defer { controller.cancel() }
        let tick = expectation(description: "initial scan and periodic settling scan finish")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { tick.fulfill() }
        await fulfillment(of: [tick], timeout: 5)
        XCTAssertTrue(states.allSatisfy { !$0 }, "Idle file observation must leave builds, settings and quit available")
        XCTAssertFalse(controller.isBusy)
        withExtendedLifetime(observation) {}
    }

    func testDeniedActivityHandshakePreventsNativeEncodingAndTrash() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, _, _ in
            state.calls += 1
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try worker.scan(beginActive: { state.beginCalls += 1; return false }, endActive: { state.endCalls += 1 }) { _, _ in }
        XCTAssertEqual(state.beginCalls, 0, "Settling observations must not reserve activity")
        state.time = 31
        try worker.scan(beginActive: { state.beginCalls += 1; return false }, endActive: { state.endCalls += 1 }) { _, _ in }
        XCTAssertEqual(state.beginCalls, 1)
        XCTAssertEqual(state.endCalls, 0)
        XCTAssertEqual(state.calls, 0)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov").path))
    }

    func testReceiptTrashRetryNeedsActivityHandshakeAndClearsResolvedFailure() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { url in
            state.trashCalls += 1
            if state.trashCalls == 1 { throw DownloadTranscodeError.message("Trash unavailable") }
            try FileManager.default.removeItem(at: url)
            return "test-trash"
        })
        try scanTwice(worker, state: state)
        state.time = 100
        try worker.scan(beginActive: { false }) { _, _ in }
        XCTAssertEqual(state.trashCalls, 1, "An invalidated scan cannot use its receipt to delete a source")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try worker.scan(beginActive: { state.beginCalls += 1; return true }, endActive: { state.endCalls += 1 }) { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 2)
        XCTAssertEqual(state.beginCalls, 1)
        XCTAssertEqual(state.endCalls, 1)
        XCTAssertFalse(state.messages.last?.contains("Trash unavailable") ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testRemovedFailingDownloadClearsItsDiagnostic() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, _, _ in
            throw DownloadTranscodeError.message("Invalid MPEG content")
        })
        try scanTwice(worker, state: state)
        try FileManager.default.removeItem(at: source)
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.messages.last, "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.")
    }

    func testSourceRemovedWhileSettlingIsSkippedWithoutAnError() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, _, _ in
            state.calls += 1
            return "mpeg2video"
        })
        try worker.scan { _, _ in }
        try FileManager.default.removeItem(at: source)
        state.time = 31
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 0)
        XCTAssertEqual(state.messages.last, "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.")
    }

    func testSourceRemovedDuringClosedCheckDoesNotStopOtherDownloads() throws {
        let root = try directory()
        let removed = root.appendingPathComponent("a.mpg")
        let remaining = root.appendingPathComponent("b.mpg")
        try Data("removed download".utf8).write(to: removed)
        try Data("remaining download".utf8).write(to: remaining)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { url in
            if url.lastPathComponent == "a.mpg" { try FileManager.default.removeItem(at: url) }
            return true
        }, transcode: { _, target, _ in
            state.calls += 1
            try Data("verified".utf8).write(to: target)
            return "mpeg2video"
        }, trash: { url in
            state.trashCalls += 1
            try FileManager.default.removeItem(at: url)
            return "test-trash"
        })
        try worker.scan { _, _ in }
        state.time = 31
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProRes LT/a.mpg.ProResLT.mov").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProRes LT/b.mpg.ProResLT.mov").path))
        XCTAssertEqual(state.messages.last, "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.")
    }

    func testSourceRemovedDuringEncodingDiscardsProvisionalOutputWithoutRetryError() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { input, target, _ in
            state.calls += 1
            try Data("provisional".utf8).write(to: target)
            try FileManager.default.removeItem(at: input)
            throw DownloadTranscodeError.message("Native source disappeared")
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try worker.scan { _, _ in }
        state.time = 31
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertEqual(state.messages.last, "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("ProRes LT").path), [])
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
    }

    func testPublishedOutputRemovedBeforeTrashRetiresReceiptWithoutRecreatingIt() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let target = root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in
            state.checks += 1
            if state.checks == 3 { try FileManager.default.removeItem(at: target) }
            return true
        }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try worker.scan { _, _ in }
        state.time = 31
        try worker.scan { message, _ in state.messages.append(message) }
        state.time = 100
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(state.messages.last, "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.")
        XCTAssertTrue(DownloadTranscodeWorker.hasRetiredOutput(for: source, outputRoot: target.deletingLastPathComponent()))

        // A fresh worker must also respect the on-disk receipt after a restart.
        let restarted = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, _, _ in
            state.calls += 1
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try restarted.scan { _, _ in }
        state.time = 131
        try restarted.scan { _, _ in }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 0)
    }

    func testRetiredSourceNamesRequireCurrentIdentityAndExpectedOutputName() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let output = root.appendingPathComponent("ProRes LT", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let target = output.appendingPathComponent("clip.mpg.ProResLT.mov")
        let receipt = output.appendingPathComponent(".clip.mpg.ProResLT.receipt.json")
        try Data("original".utf8).write(to: source)
        try Data("converted".utf8).write(to: target)
        let saved = DownloadTranscodeWorker.Receipt(source: try DownloadFingerprint.read(source),
            output: try DownloadFingerprint.read(target), outputName: target.lastPathComponent, sourceCodec: "mpeg2video")
        try JSONEncoder().encode(saved).write(to: receipt)
        let clip = ClipInfo(filename: "clip.mpg", duration_ms: 1, size_bytes: 8, modified_ms: 0)
        XCTAssertTrue(DownloadTranscodeWorker.retiredSourceNames(root: root, sources: [clip]).isEmpty)
        try FileManager.default.removeItem(at: target)
        XCTAssertEqual(DownloadTranscodeWorker.retiredSourceNames(root: root, sources: [clip]), ["clip.mpg"])

        try Data("replacement download".utf8).write(to: source)
        XCTAssertTrue(DownloadTranscodeWorker.retiredSourceNames(root: root, sources: [clip]).isEmpty)
        let invalid = DownloadTranscodeWorker.Receipt(source: try DownloadFingerprint.read(source),
            output: saved.output, outputName: "../other.mov", sourceCodec: "mpeg2video")
        try JSONEncoder().encode(invalid).write(to: receipt)
        XCTAssertTrue(DownloadTranscodeWorker.retiredSourceNames(root: root, sources: [clip]).isEmpty)
        let traversal = ClipInfo(filename: "../clip.mpg", duration_ms: 1, size_bytes: 8, modified_ms: 0)
        XCTAssertTrue(DownloadTranscodeWorker.retiredSourceNames(root: root, sources: [traversal]).isEmpty)
    }

    func testRemovedConvertedOutputClearsTrashFailureBeforeRetryDeadline() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let target = root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { _ in
            state.trashCalls += 1
            throw DownloadTranscodeError.message("Trash unavailable")
        })
        try scanTwice(worker, state: state)
        try FileManager.default.removeItem(at: target)
        state.time = 32 // The earlier failure's retry deadline is still 91.
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 1)
        XCTAssertEqual(state.messages.last, "Watching downloads for ProRes LT conversion. Verified MPG originals move to Trash.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCompletedRetainedSourceRevalidatesChangedOutput() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let target = root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov")
        try Data("retained ProRes".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified".utf8).write(to: output)
            return "prores"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        try Data("replaced output".utf8).write(to: target)
        state.time = 100
        try worker.scan { message, _ in state.messages.append(message) }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertTrue(state.messages.last?.contains("Existing output left untouched") ?? false)
        XCTAssertEqual(try Data(contentsOf: target), Data("replaced output".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSourceChangedDuringClosedFileCheckNeverReachesEncoder() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { url in
            try Data("download resumed during lsof".utf8).write(to: url)
            return true
        }, transcode: { _, _, _ in state.calls += 1; return "mpeg2video" },
        trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.calls, 0)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data("download resumed during lsof".utf8))
    }

    func testSourceChangedDuringFinalClosedFileCheckIsNeverTrashed() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { url in
            state.checks += 1
            if state.checks == 3 { try Data("download resumed before Trash".utf8).write(to: url) }
            return true
        }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified original content".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data("download resumed before Trash".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov").path))
    }

    func testCompanionAppearingDuringClosedFileCheckPreventsEncoding() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in
            try Data("active checkpoint".utf8).write(to: root.appendingPathComponent("#chkpt_file#clip.mpg"))
            return true
        }, transcode: { _, _, _ in state.calls += 1; return "mpeg2video" })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCompanionRestartsSettlingForAnUnchangedDownload() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let companion = root.appendingPathComponent("#work_file#clip.mpg")
        try Data("placeholder".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified placeholder".utf8).write(to: output)
            return "other"
        })
        try worker.scan { _, _ in }
        try Data().write(to: companion)
        state.time = 20
        try worker.scan { _, _ in }
        try FileManager.default.removeItem(at: companion)
        state.time = 31
        try worker.scan { _, _ in }
        XCTAssertEqual(state.calls, 0)
        state.time = 51
        try worker.scan { _, _ in }
        XCTAssertEqual(state.calls, 1)
    }

    func testOnlyVerifiedPublishedMPEGIsTrashed() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified ProRes".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { url in
            let output = root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov")
            XCTAssertEqual(try Data(contentsOf: output), Data("verified ProRes".utf8))
            state.trashCalls += 1
            try FileManager.default.removeItem(at: url)
            return "test-trash"
        })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let receipt = root.appendingPathComponent("ProRes LT/.clip.mpg.ProResLT.receipt.json")
        let saved = try JSONDecoder().decode(DownloadTranscodeWorker.Receipt.self, from: Data(contentsOf: receipt))
        XCTAssertEqual(saved.trashedSource, "test-trash")
    }

    func testSourceMutationDuringConversionDiscardsOutputAndKeepsOriginal() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { input, output, _ in
            try Data("verified ProRes".utf8).write(to: output)
            try Data("new active download".utf8).write(to: input)
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertEqual(try Data(contentsOf: source), Data("new active download".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov").path))
    }

    func testCompanionAndOpenFilePreventConversion() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let companion = root.appendingPathComponent("#work_file#clip.mpg")
        try Data("original".utf8).write(to: source)
        try Data("in progress".utf8).write(to: companion)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in false }, transcode: { _, _, _ in
            state.calls += 1
            return "mpeg2video"
        })
        try scanTwice(worker, state: state)
        try FileManager.default.removeItem(at: companion)
        state.time = 62
        try worker.scan { _, _ in }
        XCTAssertEqual(state.calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCancellationPreventsPublicationAndTrash() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, cancellation in
            try Data("verified ProRes".utf8).write(to: output)
            cancellation.cancel()
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov").path))
    }

    func testChangedPublishedOutputIsNeverBlessedByReceiptOrRetry() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        let target = root.appendingPathComponent("ProRes LT/clip.mpg.ProResLT.mov")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in
            state.checks += 1
            // The third check is immediately before Trash, after publication.
            if state.checks == 3 { try Data("corrupted".utf8).write(to: target) }
            return true
        }, transcode: { _, output, _ in
            try Data("verified ProRes".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        state.time = 100
        try worker.scan { _, _ in }
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let receipt = root.appendingPathComponent("ProRes LT/.clip.mpg.ProResLT.receipt.json")
        let saved = try JSONDecoder().decode(DownloadTranscodeWorker.Receipt.self, from: Data(contentsOf: receipt))
        XCTAssertNotEqual(try DownloadFingerprint.read(target), saved.output)
    }

    func testIntroMOVIsExcludedFromDownloadCollection() throws {
        let root = try directory()
        let source = root.appendingPathComponent("Chabot News Intro.mov")
        try Data("intro".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, _, _ in
            state.calls += 1
            return "prores"
        })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.calls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testTrashFailureRetainsOriginalAndRetriesOnlyWithVerifiedOutput() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            state.calls += 1
            try Data("verified ProRes".utf8).write(to: output)
            return "mpeg2video"
        }, trash: { url in
            state.trashCalls += 1
            if state.trashCalls == 1 { throw DownloadTranscodeError.message("Trash unavailable") }
            try FileManager.default.removeItem(at: url)
            return "test-trash"
        })
        try scanTwice(worker, state: state)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(state.calls, 1)
        state.time = 100
        try worker.scan { _, _ in }
        XCTAssertEqual(state.calls, 1, "Retry must use the matching verified receipt instead of re-encoding")
        XCTAssertEqual(state.trashCalls, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func testPreexistingTargetIsNeverOverwrittenOrUsedToDeleteOriginal() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let output = root.appendingPathComponent("ProRes LT", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let target = output.appendingPathComponent("clip.mpg.ProResLT.mov")
        try Data("preexisting".utf8).write(to: target)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, _, _ in
            state.calls += 1
            return "mpeg2video"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        XCTAssertEqual(state.calls, 0)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertEqual(try Data(contentsOf: target), Data("preexisting".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testSymlinkedCollectionFolderIsRejected() throws {
        let root = try directory(), other = try directory()
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ProRes LT"), withDestinationURL: other)
        let worker = DownloadTranscodeWorker(root: root)
        XCTAssertThrowsError(try worker.prepare())
    }

    func testAlreadyProResContentIsNotAuthorizedForMPEGDeletion() throws {
        let root = try directory()
        let source = root.appendingPathComponent("clip.mpg")
        try Data("original".utf8).write(to: source)
        let state = DownloadTestState()
        let worker = DownloadTranscodeWorker(root: root, now: { state.time }, closed: { _ in true }, transcode: { _, output, _ in
            try Data("verified ProRes".utf8).write(to: output)
            state.calls += 1
            return "prores"
        }, trash: { _ in state.trashCalls += 1; return "unexpected" })
        try scanTwice(worker, state: state)
        state.time = 100
        try worker.scan { _, _ in }
        XCTAssertEqual(state.calls, 1)
        XCTAssertEqual(state.trashCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
}
