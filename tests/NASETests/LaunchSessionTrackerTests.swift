import XCTest
@testable import NASE

/// Counts backend fetches across the tracker's detached tasks.
private actor FetchLog {
    private(set) var count = 0
    func record() -> Int {
        count += 1
        return count
    }
}

@MainActor
final class LaunchSessionTrackerTests: XCTestCase {
    private func session(_ id: String) -> GameLaunchSession {
        GameLaunchSession(
            sessionID: id, appid: "250900", game: "Isaac", status: "running", strategy: "steam",
            graphicsBackend: "dxmt", profileID: "dxmt-wine-stable-11-v1", bottle: "Default",
            prefix: "/prefix", executable: nil, installDir: nil, pids: [], message: "Running"
        )
    }

    func testHungPollTimesOutAndFreesTheNextPoll() async {
        let log = FetchLog()
        let tracker = LaunchSessionTracker(pollTimeout: .milliseconds(50))
        tracker.fetchSessions = {
            if await log.record() == 1 {
                try? await Task.sleep(for: .seconds(30))
            }
            return []
        }
        let timedOut = expectation(description: "watchdog fired")
        tracker.onBackendUnreachable = { didTimeOut in
            if didTimeOut { timedOut.fulfill() }
        }
        tracker.refresh()
        await fulfillment(of: [timedOut], timeout: 2)

        let answered = expectation(description: "next poll ran")
        tracker.onSessions = { _ in answered.fulfill() }
        tracker.refresh()
        await fulfillment(of: [answered], timeout: 2)
        let fetches = await log.count
        XCTAssertEqual(fetches, 2)
    }

    func testOverlappingRefreshesShareOneBackendCall() async {
        let log = FetchLog()
        let tracker = LaunchSessionTracker()
        let sessions = [session("s1")]
        tracker.fetchSessions = {
            _ = await log.record()
            try? await Task.sleep(for: .milliseconds(100))
            return sessions
        }
        var delivered: [[GameLaunchSession]] = []
        tracker.onSessions = { delivered.append($0) }

        async let first: Void = tracker.refreshNow()
        async let second: Void = tracker.refreshNow()
        _ = await (first, second)

        let fetches = await log.count
        XCTAssertEqual(fetches, 1)
        XCTAssertEqual(delivered.map { $0.map(\.sessionID) }, [["s1"]])
    }

    func testUnansweredPollFallsBackToLocalChecks() async {
        let tracker = LaunchSessionTracker()
        tracker.fetchSessions = { nil }
        var reports: [Bool] = []
        tracker.onBackendUnreachable = { reports.append($0) }
        await tracker.refreshNow()
        XCTAssertEqual(reports, [false])
    }

    func testHandoffFollowUpStopsOnceTheLaunchSettles() async {
        let log = FetchLog()
        let tracker = LaunchSessionTracker(handoffInterval: .milliseconds(10))
        tracker.fetchSessions = {
            _ = await log.record()
            return []
        }
        var pending = true
        let settled = expectation(description: "launch settled")
        tracker.onSessions = { _ in
            if pending {
                pending = false
                settled.fulfill()
            }
        }
        tracker.followHandoff { pending }
        await fulfillment(of: [settled], timeout: 2)
        try? await Task.sleep(for: .milliseconds(100))
        let fetches = await log.count
        XCTAssertEqual(fetches, 1)
    }

    func testStoppedPollerCanBeRestarted() {
        let tracker = LaunchSessionTracker(pollInterval: .seconds(60))
        tracker.ensurePolling()
        XCTAssertTrue(tracker.isPolling)
        tracker.stop()
        XCTAssertFalse(tracker.isPolling)
        tracker.ensurePolling()
        XCTAssertTrue(tracker.isPolling)
        tracker.stop()
    }
}
