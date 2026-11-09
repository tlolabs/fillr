import Combine
import Foundation
@testable import FILLR
import XCTest

final class FolderOpeningTests: XCTestCase {
    @MainActor
    func testOpenFailureRemainsAfterAlertDismissalAndRefreshRetries() async {
        let suite = "com.tlolabs.fillr.folder-opening-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let attempts = OpenAttempts()
        let opening = expectation(description: "first open started")
        let releaseOpening = DispatchSemaphore(value: 0)
        defer { releaseOpening.signal() }
        let store = FillrStore(defaults: defaults, startServices: false) { _, _, _ in
            if attempts.next() == 1 {
                opening.fulfill()
                releaseOpening.wait()
                throw BridgeError.message("Folder is unavailable")
            }
            return OpeningTestEngine()
        }
        XCTAssertEqual(store.folderOpenState, .idle)
        store.openFolder(URL(fileURLWithPath: "/unavailable"))
        XCTAssertEqual(store.folderOpenState, .opening)
        await fulfillment(of: [opening], timeout: 5)

        let failed = expectation(description: "failed open published")
        let failureObservation = store.$alertMessage.compactMap { $0 }.first().sink { _ in failed.fulfill() }
        releaseOpening.signal()
        await fulfillment(of: [failed], timeout: 5)
        withExtendedLifetime(failureObservation) {}

        XCTAssertEqual(store.folderOpenState, .failed("Folder is unavailable"))
        XCTAssertNil(store.snapshot)
        store.alertMessage = nil
        XCTAssertEqual(store.folderOpenState, .failed("Folder is unavailable"),
                       "Dismissing an alert must not make the failed folder appear to be scanning")

        let recovered = expectation(description: "retry produced snapshot")
        let snapshotObservation = store.$snapshot.compactMap { $0 }.first().sink { _ in recovered.fulfill() }
        store.refresh()
        XCTAssertEqual(store.folderOpenState, .opening)
        XCTAssertNil(store.alertMessage)
        await fulfillment(of: [recovered], timeout: 5)
        withExtendedLifetime(snapshotObservation) {}

        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(store.folderOpenState, .idle)
        XCTAssertEqual(store.folder?.path, "/unavailable")
        XCTAssertEqual(store.snapshot?.status, "checking")
        XCTAssertNil(store.alertMessage)
    }

    @MainActor
    func testSupersededOpenFailureCannotMarkNewFolderFailed() async {
        let suite = "com.tlolabs.fillr.folder-opening-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let opening = expectation(description: "superseded open started")
        let releaseOpening = DispatchSemaphore(value: 0)
        defer { releaseOpening.signal() }
        let store = FillrStore(defaults: defaults, startServices: false) { url, _, _ in
            if url.path == "/old" {
                opening.fulfill()
                releaseOpening.wait()
                throw BridgeError.message("Superseded failure")
            }
            return OpeningTestEngine()
        }
        var failureMessages: [String] = []
        let stateObservation = store.$folderOpenState.sink {
            if case .failed(let message) = $0 { failureMessages.append(message) }
        }
        store.alertMessage = "An earlier folder error"
        store.openFolder(URL(fileURLWithPath: "/old"))
        XCTAssertNil(store.alertMessage, "Starting another open must clear the previous error")
        await fulfillment(of: [opening], timeout: 5)

        let opened = expectation(description: "new folder snapshot")
        let snapshotObservation = store.$snapshot.compactMap { $0 }.first().sink { _ in opened.fulfill() }
        store.openFolder(URL(fileURLWithPath: "/new"))
        XCTAssertEqual(store.folderOpenState, .opening)
        releaseOpening.signal()
        await fulfillment(of: [opened], timeout: 5)
        withExtendedLifetime((stateObservation, snapshotObservation)) {}

        XCTAssertTrue(failureMessages.isEmpty)
        XCTAssertEqual(store.folder?.path, "/new")
        XCTAssertEqual(store.folderOpenState, .idle)
        XCTAssertNil(store.alertMessage)
    }
}

private final class OpenAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func next() -> Int { lock.withLock { value += 1; return value } }
}

private final class OpeningTestEngine: EngineSession, @unchecked Sendable {
    func setConfiguration(policy: MediaPolicy, settings: SortSettings) throws {}
    func snapshot() throws -> EngineSnapshot {
        EngineSnapshot(api_version: 1, folder: "/test", status: "checking", available_ms: 0, remaining_ms: 0,
            clips: [], pending: [], downloads: [], excluded: [], duplicate_log: [], rejection_log: [],
            plan: nil, message: "Collecting footage")
    }
    func refresh() {}
    func build() throws -> BuildResponse.Result { throw BridgeError.message("Unexpected test build") }
}
