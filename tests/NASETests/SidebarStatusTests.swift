import XCTest
@testable import NASE

final class SidebarStatusTests: XCTestCase {
    private func status(
        preflight: BackendPreflightState = .ready,
        setup: DependencyBootstrapPhase = .idle,
        work: Bool = false,
        health: HealthStatus? = nil,
        ready: Bool = false,
        external: Bool = false
    ) -> SidebarStatus {
        SidebarStatus.resolve(preflight: preflight, setup: setup, hasWork: work,
                              lastCheck: health, profileReady: ready, usesExternalPrefix: external)
    }

    func testIdleHelperDoesNotImplyWindowsReadiness() {
        XCTAssertEqual(status(), .setupNeeded)
        XCTAssertEqual(status(health: .healthy), .setupNeeded)
        XCTAssertEqual(status(setup: .ready), .setupNeeded)
        XCTAssertEqual(status(ready: true), .ready)
    }

    func testPreflightOverridesOldReadinessAndActivity() {
        XCTAssertEqual(status(preflight: .unchecked, ready: true), .checking)
        XCTAssertEqual(status(preflight: .checking, ready: true), .checking)
        XCTAssertEqual(status(preflight: .bootstrapRequired, work: true, ready: true), .unavailable)
    }

    func testSetupAndRepairProgressOverrideEarlierFailure() {
        XCTAssertEqual(status(setup: .installing, health: .error), .settingUp)
        XCTAssertEqual(status(setup: .failed, work: true), .working)
        XCTAssertEqual(status(setup: .failed, ready: true), .setupFailed)
    }

    func testIssuesAreVisibleEvenWithReadyProfile() {
        XCTAssertEqual(status(health: .warning, ready: true), .needsAttention)
        XCTAssertEqual(status(health: .error, ready: true), .needsAttention)
        XCTAssertEqual(status(health: .healthy, ready: true), .ready)
    }

    func testManagedProfileDoesNotCertifyImportedEnvironment() {
        XCTAssertEqual(status(ready: true, external: true), .unverified)
        XCTAssertEqual(status(external: true), .unverified)
    }
}
