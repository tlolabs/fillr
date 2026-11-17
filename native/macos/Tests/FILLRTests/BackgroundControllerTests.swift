import BackgroundProfiling
import Combine
import Foundation
@testable import FILLR
import XCTest

final class BackgroundControllerTests: XCTestCase {
    @MainActor
    func testBenchmarkBlocksQuitAndUpdatesSynchronouslyAndImmediateCancelIsSticky() async throws {
        let suite = "com.tlolabs.fillr.background-controller-cancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FillrStore(defaults: defaults, startServices: false)
        let finished = expectation(description: "cancelled benchmark returns to idle")
        var states: [Bool] = []
        let observation = store.background.$isBusy.removeDuplicates().sink { busy in
            states.append(busy)
            if states.count > 1, !busy { finished.fulfill() }
        }

        store.background.runBenchmark(.quick)
        // These checks deliberately run before the main actor yields. A delayed
        // busy mirror previously let quit accept this freshly started operation.
        XCTAssertTrue(store.background.isBusy)
        XCTAssertTrue(store.isBackgroundBusy)
        XCTAssertTrue(store.hasActiveBuild)
        XCTAssertTrue(store.updatesBlocked)
        store.background.cancel()

        await fulfillment(of: [finished], timeout: 10)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(states, [false, true, false])
        XCTAssertFalse(store.background.isBusy)
        XCTAssertFalse(store.isBackgroundBusy)
        XCTAssertFalse(store.hasActiveBuild)
        XCTAssertFalse(store.updatesBlocked)
        XCTAssertNil(store.background.profiler.benchmark, "Immediate cancellation must prevent native benchmark startup")
        XCTAssertTrue(store.background.status.localizedCaseInsensitiveContains("cancel"))
    }

    @MainActor
    func testDeletedSavedInputsUseBuiltInFootageWithoutAnIdleTransition() async throws {
        let suite = "com.tlolabs.fillr.background-controller-fallback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("fillr-controller-\(UUID().uuidString)")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: work)
        }
        // The URLs remain in preferences after the user's footage has been moved
        // away. Absence must reach source discovery and its built-in fallback.
        let missing = work.appendingPathComponent("deleted-footage")
        defaults.set(missing.path, forKey: "background.mediaRoot")
        defaults.set(missing.appendingPathComponent("Footage.prproj").path, forKey: "background.project")
        defaults.set(missing.appendingPathComponent("intro.mov").path, forKey: "background.intro")
        let controller = BackgroundController(defaults: defaults, workRoot: work)
        guard controller.profiler.hardware?.canRender == true else {
            throw XCTSkip("The native built-in benchmark requires an available Metal device; none is exposed by this runner")
        }
        let finished = expectation(description: "built-in fallback benchmark finishes")
        var states: [Bool] = []
        let observation = controller.$isBusy.removeDuplicates().sink { busy in
            states.append(busy)
            if states.count > 1, !busy { finished.fulfill() }
        }

        controller.runBenchmark(.quick)
        XCTAssertTrue(controller.isBusy)
        await fulfillment(of: [finished], timeout: 120)
        withExtendedLifetime(observation) {}

        let report = try XCTUnwrap(controller.profiler.benchmark,
            "Missing saved source paths must not stop preparation before built-in test footage is selected. \(controller.error ?? controller.profiler.error ?? controller.status)")
        XCTAssertEqual(report.source, .builtIn)
        XCTAssertTrue(report.isComplete, "Backend-unavailable samples may fail, but every attempted trial must remain in a completed report")
        XCTAssertFalse(report.cancelled)
        XCTAssertNil(controller.error)
        XCTAssertEqual(states, [false, true, false], "Preparation and benchmarking form one continuously busy operation")
        XCTAssertFalse(controller.isBusy)
        XCTAssertNotNil(controller.lastBenchmarkDirectory)
    }
}
