import BackgroundPlanning
import BackgroundProfiling
import Combine
import Foundation
@testable import FILLR
import XCTest

final class BackgroundCollectionProfilingTests: XCTestCase {
    private func preferences() throws -> UserDefaults {
        let name = "org.fillr.tests.collection-profiling." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func plan(_ names: [String] = ["a.bin", "b.bin"]) -> BackgroundFootagePlan {
        BackgroundFootagePlan(assignments: [
            BackgroundFootageAssignment(comp: 2, sources: names.map { URL(fileURLWithPath: "/fixture/" + $0) })
        ])
    }

    @MainActor
    func testFirstResolvedCollectionPreservesSavedBenchmarkAndUnchangedRefreshes() throws {
        let defaults = try preferences()
        let saved = BackgroundBenchmarkReport(mode: .quick, source: .actualProject,
            hardware: BackgroundHardwareScanner.scan(), workloadFingerprint: "fixture",
            trials: [], expectedTrialCount: 1)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
        let state: [String: Any] = ["version": 1, "selectedProfile": "fastest", "overrides": [String: Any](),
                                    "benchmark": encoded, "workloadChanged": false]
        defaults.set(try JSONSerialization.data(withJSONObject: state), forKey: "backgroundHardwareProfile.v1")
        let controller = BackgroundController(defaults: defaults)
        controller.configureCollection(plan: nil, useAllFootage: true, selected: true)
        controller.configureCollection(plan: plan(), useAllFootage: true, selected: true)
        controller.configureCollection(plan: plan(), useAllFootage: true, selected: true)
        controller.configureCollection(plan: nil, useAllFootage: true, selected: true)
        controller.configureCollection(plan: plan(), useAllFootage: true, selected: true)
        XCTAssertEqual(controller.profiler.benchmark?.id, saved.id)
        XCTAssertFalse(controller.profiler.workloadChanged)
    }

    @MainActor
    func testResolvedSourceOrderAndDurationChangesInvalidateWithoutRepeatedNoOpSaves() throws {
        let controller = BackgroundController(defaults: try preferences())
        controller.configureCollection(plan: plan(), useAllFootage: true, selected: true)
        var invalidations = 0
        var publishedPlans = 0, publishedModes = 0, publishedSelections = 0
        let observation = controller.profiler.$workloadChanged.dropFirst().sink { if $0 { invalidations += 1 } }
        let planObservation = controller.$footagePlan.dropFirst().sink { _ in publishedPlans += 1 }
        let modeObservation = controller.$useAllFootage.dropFirst().sink { _ in publishedModes += 1 }
        let selectionObservation = controller.$collectionSelected.dropFirst().sink { _ in publishedSelections += 1 }
        controller.configureCollection(plan: plan(), useAllFootage: true, selected: true)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(publishedPlans, 0)
        XCTAssertEqual(publishedModes, 0)
        XCTAssertEqual(publishedSelections, 0)
        controller.configureCollection(plan: plan(["c.bin", "b.bin"]), useAllFootage: true, selected: true)
        XCTAssertEqual(invalidations, 1)
        controller.configureCollection(plan: nil, useAllFootage: true, selected: true)
        controller.configureCollection(plan: plan(["c.bin", "b.bin"]), useAllFootage: true, selected: true)
        XCTAssertEqual(invalidations, 1)
        controller.configureCollection(plan: plan(["b.bin", "c.bin"]), useAllFootage: true, selected: true)
        XCTAssertEqual(invalidations, 2)
        controller.configureCollection(plan: plan(["b.bin", "c.bin"]), useAllFootage: false, selected: true)
        controller.configureCollection(plan: plan(["b.bin", "c.bin"]), useAllFootage: false, selected: true)
        XCTAssertEqual(invalidations, 3)
        XCTAssertTrue(controller.profiler.workloadChanged)
        withExtendedLifetime((observation, planObservation, modeObservation, selectionObservation)) {}
    }

    @MainActor
    func testProjectOverrideIgnoresInactiveCollectionChangesAndInvalidatesSourceTransitions() throws {
        let defaults = try preferences()
        let project = URL(fileURLWithPath: "/fixture/same.prproj")
        defaults.set(project.path, forKey: "background.project")
        let controller = BackgroundController(defaults: defaults)
        controller.configureCollection(plan: plan(), useAllFootage: true, selected: true)
        var invalidations = 0
        let observation = controller.profiler.$workloadChanged.dropFirst().sink { if $0 { invalidations += 1 } }
        controller.useProject(project)
        XCTAssertEqual(invalidations, 1, "The source changes even when the saved project path is unchanged")
        controller.configureCollection(plan: plan(["c.bin"]), useAllFootage: true, selected: true)
        XCTAssertEqual(invalidations, 1, "Inactive collection changes must not invalidate the explicit project")
        controller.configureCollection(plan: plan(["c.bin"]), useAllFootage: false, selected: true)
        XCTAssertEqual(invalidations, 2, "Duration mode also applies to the explicit project")
        controller.useCurrentCollection()
        controller.useCurrentCollection()
        XCTAssertEqual(invalidations, 3)
        XCTAssertNotNil(controller.footagePlan)
        controller.useProject(project)
        controller.useProject(project)
        XCTAssertEqual(invalidations, 4)
        XCTAssertNil(controller.footagePlan)
        withExtendedLifetime(observation) {}
    }
}
