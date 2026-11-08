import Combine
import Foundation
@testable import FILLR
import XCTest

final class SettingsConcurrencyTests: XCTestCase {
    @MainActor
    func testReplacingOpenedEngineDisposesItOffMainThread() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let disposed = expectation(description: "previous engine disposed")
        let store = FillrStore(defaults: defaults, startServices: false) { url, _, _ in
            if url.path == "/first" {
                return StubEngine(onDeinit: {
                    XCTAssertFalse(Thread.isMainThread, "Replacing the watched folder must not join its scan worker on the UI thread")
                    disposed.fulfill()
                })
            }
            return StubEngine()
        }
        await open(store, path: "/first")
        store.openFolder(URL(fileURLWithPath: "/second"))
        await fulfillment(of: [disposed], timeout: 5)
        XCTAssertEqual(store.folder?.path, "/second")
    }

    @MainActor
    func testSupersededOpeningDisposesEngineOffMainThread() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let opening = expectation(description: "first engine opening")
        let releaseOpening = DispatchSemaphore(value: 0)
        let disposed = expectation(description: "superseded engine disposed")
        let currentEngine = StubEngine()
        let store = FillrStore(defaults: defaults, startServices: false) { url, _, _ in
            if url.path == "/first" {
                opening.fulfill()
                releaseOpening.wait()
                return StubEngine(onDeinit: {
                    XCTAssertFalse(Thread.isMainThread, "Destroying an engine waits for its scan worker and must not block the UI")
                    disposed.fulfill()
                })
            }
            return currentEngine
        }
        store.openFolder(URL(fileURLWithPath: "/first"))
        await fulfillment(of: [opening], timeout: 5)
        store.openFolder(URL(fileURLWithPath: "/second"))
        releaseOpening.signal()
        await fulfillment(of: [disposed], timeout: 5)
        XCTAssertEqual(store.folder?.path, "/second")
    }

    @MainActor
    func testSaveDuringOpeningUsesLatestSettingsBeforePublishingSnapshot() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let opening = expectation(description: "engine opening")
        let releaseOpening = DispatchSemaphore(value: 0)
        let engine = StubEngine()
        let store = FillrStore(defaults: defaults, startServices: false) { _, policy, _ in
            XCTAssertFalse(policy.delete_rejected, "Startup must not delete using an obsolete policy")
            opening.fulfill()
            releaseOpening.wait()
            return engine
        }
        store.openFolder(URL(fileURLWithPath: "/test"))
        await fulfillment(of: [opening], timeout: 5)

        var policy = MediaPolicy()
        policy.delete_rejected = false
        let sort = SortSettings(folder_count: 3, folder_prefix: "Latest", total_ms: 60_000)
        XCTAssertTrue(store.updateSettings(policy: policy, sort: sort))
        let snapshot = expectation(description: "configured snapshot")
        let observation = store.$snapshot.compactMap { $0 }.first().sink { _ in snapshot.fulfill() }
        releaseOpening.signal()
        await fulfillment(of: [snapshot], timeout: 5)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(engine.lastSettings, sort)
        XCTAssertFalse(engine.lastPolicy!.delete_rejected)
        XCTAssertEqual(store.sortSettings, sort)
    }

    @MainActor
    func testOlderFailureCannotOverwriteLaterSuccessfulSave() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let firstSave = expectation(description: "first save started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let engine = StubEngine(beforeConfiguration: { settings in
            if settings.folder_prefix == "First" {
                firstSave.fulfill()
                releaseFirst.wait()
                throw BridgeError.message("first save failed")
            }
        })
        let store = FillrStore(defaults: defaults, startServices: false) { _, _, _ in engine }
        await open(store)
        let first = SortSettings(folder_count: 2, folder_prefix: "First", total_ms: 60_000)
        let second = SortSettings(folder_count: 4, folder_prefix: "Second", total_ms: 120_000)
        XCTAssertTrue(store.updateSettings(policy: MediaPolicy(), sort: first))
        await fulfillment(of: [firstSave], timeout: 5)
        XCTAssertTrue(store.updateSettings(policy: MediaPolicy(), sort: second))

        let snapshot = expectation(description: "newest settings snapshot")
        let observation = store.$snapshot.compactMap { $0 }.first().sink { _ in snapshot.fulfill() }
        releaseFirst.signal()
        await fulfillment(of: [snapshot], timeout: 5)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(store.sortSettings, second)
        XCTAssertEqual(engine.lastSettings, second)
        XCTAssertEqual(try JSONDecoder().decode(SortSettings.self, from: defaults.data(forKey: "sortSettings")!), second)
        XCTAssertNil(store.alertMessage)
    }

    @MainActor
    func testTwoFailedSavesRestoreLastAcceptedSettings() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }
        let firstSave = expectation(description: "first failed save started")
        let releaseFirst = DispatchSemaphore(value: 0)
        let engine = StubEngine(beforeConfiguration: { settings in
            if settings.folder_prefix == "First" {
                firstSave.fulfill()
                releaseFirst.wait()
            }
            if settings.folder_prefix != "Comp" { throw BridgeError.message("save failed") }
        })
        let store = FillrStore(defaults: defaults, startServices: false) { _, _, _ in engine }
        await open(store)
        XCTAssertTrue(store.updateSettings(policy: MediaPolicy(), sort: SortSettings(folder_count: 2, folder_prefix: "First", total_ms: 60_000)))
        await fulfillment(of: [firstSave], timeout: 5)
        XCTAssertTrue(store.updateSettings(policy: MediaPolicy(), sort: SortSettings(folder_count: 4, folder_prefix: "Second", total_ms: 120_000)))
        let failed = expectation(description: "latest save failed")
        let observation = store.$alertMessage.compactMap { $0 }.first().sink { _ in failed.fulfill() }
        releaseFirst.signal()
        await fulfillment(of: [failed], timeout: 5)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(store.sortSettings, SortSettings())
        XCTAssertNil(defaults.data(forKey: "sortSettings"))
        XCTAssertEqual(engine.lastSettings, SortSettings())
    }

    @MainActor
    private func open(_ store: FillrStore, path: String = "/test") async {
        let opened = expectation(description: "initial snapshot")
        let observation = store.$snapshot.compactMap { $0 }.first().sink { _ in opened.fulfill() }
        store.openFolder(URL(fileURLWithPath: path))
        await fulfillment(of: [opened], timeout: 5)
        withExtendedLifetime(observation) {}
    }

    private let defaultsSuite = "com.tlolabs.fillr.settings-tests.\(UUID().uuidString)"
    private func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: defaultsSuite)! }
}

private final class StubEngine: EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private var policy: MediaPolicy?
    private var settings: SortSettings?
    private let beforeConfiguration: @Sendable (SortSettings) throws -> Void
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void = {},
         beforeConfiguration: @escaping @Sendable (SortSettings) throws -> Void = { _ in }) {
        self.onDeinit = onDeinit
        self.beforeConfiguration = beforeConfiguration
    }

    deinit { onDeinit() }

    var lastPolicy: MediaPolicy? { lock.withLock { policy } }
    var lastSettings: SortSettings? { lock.withLock { settings } }

    func setConfiguration(policy: MediaPolicy, settings: SortSettings) throws {
        try beforeConfiguration(settings)
        lock.withLock { self.policy = policy; self.settings = settings }
    }

    func snapshot() throws -> EngineSnapshot {
        EngineSnapshot(api_version: 1, folder: "/test", status: "checking", available_ms: 0, remaining_ms: 0,
            clips: [], pending: [], downloads: [], excluded: [], duplicate_log: [], rejection_log: [], plan: nil, message: "")
    }

    func refresh() {}
    func build() throws -> BuildResponse.Result { throw BridgeError.message("Unexpected test build") }
}
