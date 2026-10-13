import XCTest
@testable import NASE

@MainActor
final class BackendJobStoreTests: XCTestCase {
    private func job(_ id: String, _ action: String, _ status: BackendJobStatus, _ message: String = "") -> BackendJob {
        BackendJob(id: id, action: action, status: status, message: message, progress: nil, completedSteps: nil, totalSteps: nil)
    }

    func testPlaceholderIsReplacedByTheBackendJobAndThenItsResult() {
        let store = BackendJobStore()
        let placeholder = store.begin(actionName: "Install Runtime", message: "Installing...")
        XCTAssertTrue(store.isRunning("Install Runtime"))

        store.apply(job("backend-1", "install-runtime", .started, "Downloading"), placeholderID: placeholder)
        XCTAssertEqual(store.active.map(\.id), ["backend-1"])

        store.apply(job("backend-1", "install-runtime", .completed, "Installed"), placeholderID: placeholder)
        XCTAssertTrue(store.active.isEmpty)
        XCTAssertEqual(store.recent.map(\.message), ["Installed"])
        XCTAssertFalse(store.hasActiveWork)
    }

    func testFallbackDoesNotOverwriteAResultTheBackendAlreadyReported() {
        let store = BackendJobStore()
        let placeholder = store.begin(actionName: "Doctor", message: "Running doctor...")
        store.apply(job("backend-1", "Doctor", .failed, "Checks failed"), placeholderID: placeholder)

        store.finish(placeholderID: placeholder, with: job("fallback", "Doctor", .completed, "Doctor finished."))
        XCTAssertEqual(store.recent.map(\.id), ["backend-1"])
    }

    func testFinishClosesAPlaceholderTheBackendNeverReplaced() {
        let store = BackendJobStore()
        let placeholder = store.begin(actionName: "Kill Wine", message: "Stopping...")

        store.finish(placeholderID: placeholder, with: job("fallback", "Kill Wine", .failed, "Kill Wine failed."))
        XCTAssertTrue(store.active.isEmpty)
        XCTAssertEqual(store.recent.first?.status, .failed)
    }

    func testCancellingJobDoesNotBlockStartingTheActionAgain() {
        let store = BackendJobStore()
        let placeholder = store.begin(actionName: "Setup", message: "Setting up...")
        store.apply(job("backend-1", "Setup", .cancelling), placeholderID: placeholder)

        XCTAssertTrue(store.hasActiveWork)
        XCTAssertFalse(store.isRunning("Setup"))
    }

    func testHistoryIsSplitByStatusAndRecentListIsBounded() {
        let store = BackendJobStore()
        let finished = (0..<20).map { job("done-\($0)", "Doctor", .completed) }
        store.load(history: [job("live", "Setup", .started)] + finished)

        XCTAssertEqual(store.active.map(\.id), ["live"])
        XCTAssertEqual(store.recent.count, BackendJobStore.recentLimit)
        XCTAssertEqual(store.current?.id, "live")
    }
}
