import Foundation
@testable import FILLR
import XCTest

final class DownloadFootageProgressTests: XCTestCase {
    func testSourceToConvertedHandoffCountsFootageOnce() {
        let source = snapshot([clip("story.mpg", 60_000)])
        let converted = snapshot([clip("story.mpg.ProResLT.mov", 59_990)])

        let before = progress(collection: snapshot([]), sources: source)
        XCTAssertEqual(before.availableMS, 60_000)
        XCTAssertEqual(before.pendingConversionCount, 1)

        let published = progress(collection: converted, sources: source)
        XCTAssertEqual(published.availableMS, 59_990, "Use the accepted copy's actual duration during overlap")
        XCTAssertEqual(published.pendingConversionCount, 0)

        let trashed = progress(collection: converted, sources: snapshot([]))
        XCTAssertEqual(trashed.availableMS, published.availableMS)
        XCTAssertEqual(trashed.remainingMS, published.remainingMS)
    }

    func testDeletionAndMovesCanDecreaseProgress() {
        let sources = snapshot([clip("first.mpg", 40_000), clip("second.mpg", 30_000)])
        let converted = snapshot([clip("first.mpg.ProResLT.mov", 40_000)])
        XCTAssertEqual(progress(collection: converted, sources: sources).availableMS, 70_000)

        let movedSource = snapshot([clip("first.mpg", 40_000)])
        XCTAssertEqual(progress(collection: converted, sources: movedSource).availableMS, 40_000)
        XCTAssertEqual(progress(collection: snapshot([]), sources: movedSource).availableMS, 40_000,
                       "A retained source can fill in when its copy disappears")
        XCTAssertEqual(progress(collection: snapshot([]), sources: snapshot([])).remainingMS, 120_000)
    }

    func testCounterpartsKeepOriginalExtension() {
        let sources = snapshot([clip("story.mpg", 40_000), clip("story.mpeg", 30_000)])
        let converted = snapshot([clip("story.mpg.ProResLT.mov", 40_000)])
        let value = progress(collection: converted, sources: sources)
        XCTAssertEqual(value.availableMS, 70_000)
        XCTAssertEqual(value.pendingConversionCount, 1)
    }

    func testDeletedCompletedCopiesDoNotRecountRetainedSources() {
        let sources = snapshot([clip("deleted.mpg", 60_000), clip("waiting.mpg", 30_000)])
        let value = DownloadFootageProgress(collection: snapshot([]), sources: sources,
            conversionEnabled: true, targetMS: 120_000, retiredSources: ["deleted.mpg"])
        XCTAssertEqual(value.availableMS, 30_000)
        XCTAssertEqual(value.remainingMS, 90_000)
        XCTAssertEqual(value.pendingConversionCount, 1)
    }

    func testPendingAndRejectedOutputsDoNotHideCompletedSource() {
        let sources = snapshot([clip("story.mpg", 60_000)])
        let collection = EngineSnapshot(api_version: 1, folder: "/test/ProRes LT", status: "collecting",
            available_ms: 0, remaining_ms: 120_000, clips: [],
            pending: ["story.mpg.ProResLT.mov"], downloads: [],
            excluded: [ExcludedInfo(filename: "story.mpg.ProResLT.mov", reason: "Waiting for validation")],
            duplicate_log: [], rejection_log: [], plan: nil, message: "Checking footage")
        let value = progress(collection: collection, sources: sources)
        XCTAssertEqual(value.availableMS, 60_000)
        XCTAssertEqual(value.pendingConversionCount, 1)
    }

    func testOnlyMPEGSourcesContributeEvenWithUnrestrictedPolicy() {
        let sources = snapshot([clip("intro.mov", 500_000), clip("other.mp4", 500_000),
                                clip("one.MPG", 10_000), clip("two.MPEG", 20_000),
                                clip("three.M2V", 30_000), clip("empty.mpg", 0)])
        let value = progress(collection: snapshot([]), sources: sources)
        XCTAssertEqual(value.availableMS, 60_000)
        XCTAssertEqual(value.pendingConversionCount, 3)
    }

    func testDisabledConversionUsesOnlyCollection() {
        let collection = snapshot([clip("direct.mpg", 50_000)])
        let sources = snapshot([clip("queued.mpg", 90_000)])
        let value = DownloadFootageProgress(collection: collection, sources: sources,
                                            conversionEnabled: false, targetMS: 120_000)
        XCTAssertEqual(value.availableMS, 50_000)
        XCTAssertEqual(value.remainingMS, 70_000)
        XCTAssertEqual(value.pendingConversionCount, 0)
    }

    func testSourcesCanCountBeforeFirstCollectionSnapshot() {
        let value = progress(collection: nil, sources: snapshot([clip("story.mpg", 30_000)]))
        XCTAssertEqual(value.availableMS, 30_000)
        XCTAssertEqual(value.remainingMS, 90_000)
        let empty = progress(collection: nil, sources: nil)
        XCTAssertEqual(empty.availableMS, 0)
        XCTAssertEqual(empty.remainingMS, 120_000)
    }

    func testTargetClampsRemainingWithoutChangingBuildReadiness() {
        let collection = snapshot([clip("accepted.mov", 60_000)])
        let sources = snapshot([clip("queued.mpg", 70_000)])
        let value = progress(collection: collection, sources: sources)
        XCTAssertEqual(value.availableMS, 130_000)
        XCTAssertEqual(value.remainingMS, 0)
        XCTAssertEqual(value.pendingConversionCount, 1)
        XCTAssertEqual(collection.status, "collecting")
        XCTAssertEqual(collection.available_ms, 60_000)
        XCTAssertEqual(collection.remaining_ms, 60_000)
        XCTAssertNil(collection.plan)
    }

    func testOverflowSaturatesAndZeroTargetIsSafe() {
        let collection = snapshot([], available: UInt64.max - 10)
        let sources = snapshot([clip("queued.mpg", 100)])
        let value = progress(collection: collection, sources: sources)
        XCTAssertEqual(value.availableMS, UInt64.max)
        XCTAssertEqual(value.remainingMS, 0)
        let zeroTarget = DownloadFootageProgress(collection: nil, sources: sources,
                                                 conversionEnabled: true, targetMS: 0)
        XCTAssertEqual(zeroTarget.remainingMS, 0)
    }

    private func progress(collection: EngineSnapshot?, sources: EngineSnapshot?) -> DownloadFootageProgress {
        DownloadFootageProgress(collection: collection, sources: sources,
                                conversionEnabled: true, targetMS: 120_000)
    }

    private func clip(_ name: String, _ duration: UInt64) -> ClipInfo {
        ClipInfo(filename: name, duration_ms: duration, size_bytes: 1, modified_ms: 0)
    }

    private func snapshot(_ clips: [ClipInfo], available: UInt64? = nil) -> EngineSnapshot {
        let total = available ?? clips.reduce(0) { $0 + $1.duration_ms }
        return EngineSnapshot(api_version: 1, folder: "/test", status: "collecting",
            available_ms: total, remaining_ms: 120_000 - min(total, 120_000),
            clips: clips, pending: [], downloads: [], excluded: [], duplicate_log: [], rejection_log: [],
            plan: nil, message: "Collecting footage")
    }
}
