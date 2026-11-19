import Combine
import Foundation
@testable import FILLR
import XCTest

final class DownloadProgressStoreTests: XCTestCase {
    @MainActor
    func testCombinedTargetDoesNotEnableBuildBeforeConvertedCollectionIsReady() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let collection = ProgressStoreEngine(snapshot: snapshot("collecting", [clip("done.mpg.ProResLT.mov", 30_000)]))
        let sources = ProgressStoreEngine(snapshot: snapshot("ready", [clip("queued.mpg", 100_000)]))
        let store = FillrStore(defaults: defaults, startServices: false,
            makeProgressBridge: { _, policy, _ in
                XCTAssertFalse(policy.delete_rejected)
                return sources
            }, makeBridge: { _, _, _ in collection })

        await open(store, path: "/test")
        XCTAssertEqual(store.footageProgress.availableMS, 130_000)
        XCTAssertEqual(store.footageProgress.remainingMS, 0)
        XCTAssertTrue(store.waitingForConversions)
        XCTAssertEqual(store.snapshot?.status, "collecting")
        XCTAssertEqual(store.downloadSnapshot?.status, "ready")
        store.build()
        XCTAssertFalse(store.isBuilding)
        XCTAssertEqual(collection.buildCount, 0)
    }

    @MainActor
    func testFolderSwitchClearsProgressAndDisposesSupersededSourceOffMainThread() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sourceOpening = expectation(description: "source open started")
        let oldSourceDisposed = expectation(description: "superseded source disposed")
        let releaseSource = DispatchSemaphore(value: 0)
        defer { releaseSource.signal() }
        let sourceSnapshot = snapshot("collecting", [clip("queued.mpg", 90_000)])
        let collectionSnapshot = snapshot("collecting", [])
        let store = FillrStore(defaults: defaults, startServices: false,
            makeProgressBridge: { url, _, _ in
                if url.path == "/old" {
                    sourceOpening.fulfill()
                    releaseSource.wait()
                    return ProgressStoreEngine(snapshot: sourceSnapshot, onDeinit: {
                        XCTAssertFalse(Thread.isMainThread)
                        oldSourceDisposed.fulfill()
                    })
                }
                return ProgressStoreEngine(snapshot: collectionSnapshot)
            }, makeBridge: { _, _, _ in ProgressStoreEngine(snapshot: collectionSnapshot) })

        store.openFolder(URL(fileURLWithPath: "/old"))
        await fulfillment(of: [sourceOpening], timeout: 5)
        let opened = expectation(description: "new folder snapshot")
        let observation = store.$snapshot.compactMap { $0 }.first().sink { _ in opened.fulfill() }
        store.openFolder(URL(fileURLWithPath: "/new"))
        XCTAssertNil(store.downloadSnapshot)
        XCTAssertEqual(store.footageProgress.availableMS, 0)
        XCTAssertEqual(store.footageProgress.remainingMS, 120_000)
        releaseSource.signal()
        await fulfillment(of: [opened, oldSourceDisposed], timeout: 5)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(store.folder?.path, "/new")
        XCTAssertEqual(store.footageProgress.availableMS, 0)
    }

    @MainActor
    func testDisabledTranscodingDoesNotCreateSourceEngine() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "downloads.transcodeEnabled")
        let collection = ProgressStoreEngine(snapshot: snapshot("collecting", [clip("direct.mpg", 20_000)]))
        let store = FillrStore(defaults: defaults, startServices: false,
            makeProgressBridge: { _, _, _ in
                XCTFail("Conversion disabled must not start a source observer")
                return collection
            }, makeBridge: { url, _, _ in
                XCTAssertEqual(url.path, "/test")
                return collection
            })

        await open(store, path: "/test")
        XCTAssertNil(store.downloadSnapshot)
        XCTAssertEqual(store.footageProgress.availableMS, 20_000)
        XCTAssertEqual(store.footageProgress.remainingMS, 100_000)
        XCTAssertFalse(store.waitingForConversions)
    }

    @MainActor
    func testFailedSourceConfigurationHidesStaleTotalsUntilSuccessfulRefresh() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let collection = ProgressStoreEngine(snapshot: snapshot("collecting", [clip("done.mov", 20_000)]))
        let sources = ProgressStoreEngine(snapshot: snapshot("collecting", [clip("queued.mpg", 90_000)]))
        let store = FillrStore(defaults: defaults, startServices: false,
            makeProgressBridge: { _, _, _ in sources }, makeBridge: { _, _, _ in collection })
        await open(store, path: "/test")
        XCTAssertEqual(store.footageProgress.availableMS, 110_000)

        sources.rejectConfiguration = true
        let failed = expectation(description: "source configuration failed")
        let failureObservation = store.$downloadProgressError.compactMap { $0 }.first().sink { _ in failed.fulfill() }
        XCTAssertTrue(store.updateSettings(policy: MediaPolicy(),
            sort: SortSettings(folder_count: 2, folder_prefix: "Comp", total_ms: 240_000)))
        await fulfillment(of: [failed], timeout: 5)
        withExtendedLifetime(failureObservation) {}
        XCTAssertNil(store.downloadSnapshot)
        let reads = sources.snapshotCount

        sources.currentSnapshot = snapshot("ready", [clip("queued.mpg", 190_000)])
        await poll(store)
        XCTAssertNil(store.downloadSnapshot)
        XCTAssertEqual(sources.snapshotCount, reads, "Invalid source settings must block further source snapshots")
        XCTAssertEqual(store.footageProgress.availableMS, 20_000)
        XCTAssertEqual(store.sortSettings.total_ms, 240_000, "Source failure must not roll back valid collection settings")

        sources.rejectConfiguration = false
        let recovered = expectation(description: "source progress refreshed")
        let recoveryObservation = store.$downloadSnapshot.compactMap { $0 }.first().sink { _ in recovered.fulfill() }
        store.refresh()
        await fulfillment(of: [recovered], timeout: 5)
        withExtendedLifetime(recoveryObservation) {}
        XCTAssertNil(store.downloadProgressError)
        XCTAssertEqual(store.footageProgress.availableMS, 210_000)
        XCTAssertEqual(store.footageProgress.remainingMS, 30_000)
    }

    @MainActor
    private func open(_ store: FillrStore, path: String) async {
        let opened = expectation(description: "collection snapshot")
        let observation = store.$snapshot.compactMap { $0 }.first().sink { _ in opened.fulfill() }
        store.openFolder(URL(fileURLWithPath: path))
        await fulfillment(of: [opened], timeout: 5)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    private func poll(_ store: FillrStore) async {
        let polled = expectation(description: "collection polled")
        let observation = store.$snapshot.dropFirst().compactMap { $0 }.first().sink { _ in polled.fulfill() }
        store.poll()
        await fulfillment(of: [polled], timeout: 5)
        withExtendedLifetime(observation) {}
    }

    private let suite = "com.tlolabs.fillr.download-progress-tests.\(UUID().uuidString)"
    private func isolatedDefaults() throws -> UserDefaults {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(try JSONEncoder().encode(SortSettings(folder_count: 2, folder_prefix: "Comp", total_ms: 120_000)),
                     forKey: "sortSettings")
        return defaults
    }

    private func clip(_ name: String, _ duration: UInt64) -> ClipInfo {
        ClipInfo(filename: name, duration_ms: duration, size_bytes: 1, modified_ms: 0)
    }

    private func snapshot(_ status: String, _ clips: [ClipInfo]) -> EngineSnapshot {
        let available = clips.reduce(0) { $0 + $1.duration_ms }
        return EngineSnapshot(api_version: 1, folder: "/test", status: status, available_ms: available,
            remaining_ms: 120_000 - min(available, 120_000), clips: clips, pending: [], downloads: [],
            excluded: [], duplicate_log: [], rejection_log: [], plan: nil, message: "Collecting footage")
    }
}

private final class ProgressStoreEngine: EngineSession, @unchecked Sendable {
    private let lock = NSLock()
    private var value: EngineSnapshot
    private var rejects = false
    private var reads = 0
    private var builds = 0
    private let onDeinit: @Sendable () -> Void
    init(snapshot: EngineSnapshot, onDeinit: @escaping @Sendable () -> Void = {}) {
        value = snapshot
        self.onDeinit = onDeinit
    }
    deinit { onDeinit() }
    var currentSnapshot: EngineSnapshot {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var rejectConfiguration: Bool {
        get { lock.withLock { rejects } }
        set { lock.withLock { rejects = newValue } }
    }
    var snapshotCount: Int { lock.withLock { reads } }
    var buildCount: Int { lock.withLock { builds } }
    func setConfiguration(policy: MediaPolicy, settings: SortSettings) throws {
        if rejectConfiguration { throw BridgeError.message("Source configuration rejected") }
    }
    func snapshot() throws -> EngineSnapshot { lock.withLock { reads += 1; return value } }
    func refresh() {}
    func build() throws -> BuildResponse.Result {
        lock.withLock { builds += 1 }
        throw BridgeError.message("Unexpected test build")
    }
}
