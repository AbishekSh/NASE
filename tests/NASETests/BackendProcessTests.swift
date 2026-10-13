import XCTest
@testable import NASE

/// Runs the real bridge against a fake backend: `/bin/sh` stands in for
/// Python, and the test writes the `nase.py` script it executes.
final class BackendProcessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nase-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func backend(_ script: String) throws -> BackendContext {
        try script.write(to: root.appendingPathComponent("nase.py"), atomically: true, encoding: .utf8)
        return BackendContext(
            repoRoot: root,
            pythonCommand: "/bin/sh",
            winePath: "/usr/bin/true",
            dxmtSource: "",
            dxvkSource: "",
            d3dMetalSource: "",
            gptkWinePath: "",
            bottleName: "Test",
            externalPrefix: nil
        )
    }

    func testStreamsEventsAndReturnsTheResult() async throws {
        let context = try backend("""
        echo '{"event":"job","job_id":"j1","action":"doctor","status":"started","message":"Checking","warnings":[],"errors":[]}'
        echo 'wine noise that is not JSON'
        printf '{"event":"result","job_id":"j1","action":"doctor","status":"completed","ok":true,"message":"All good","warnings":[],"errors":[]}'
        """)
        let updates = UpdateLog()
        let response = try await BackendBridge.executeStreaming(.doctor, context: context) { update in
            await updates.record(update.job?.status)
        }
        XCTAssertEqual(response.job?.status, .completed)
        let statuses = await updates.statuses
        XCTAssertEqual(statuses, [.started, .completed])
    }

    func testFailureWithoutResultKeepsOnlyRecentOutput() async throws {
        let context = try backend("""
        i=0; while [ $i -lt 1000 ]; do echo "line $i"; i=$((i+1)); done
        exit 3
        """)
        do {
            _ = try await BackendBridge.execute(.doctor, context: context)
            XCTFail("Expected the failed command to throw")
        } catch {
            let lines = error.localizedDescription.split(separator: "\n")
            XCTAssertEqual(lines.count, 400)
            XCTAssertEqual(lines.last, "line 999")
            XCTAssertEqual((error as NSError).code, 3)
        }
    }

    func testCancellingTheTaskStopsTheBackendProcess() async throws {
        let pidFile = root.appendingPathComponent("pid")
        let context = try backend("""
        echo $$ > '\(pidFile.path)'
        echo '{"event":"job","job_id":"j1","action":"doctor","status":"started","message":"Working","warnings":[],"errors":[]}'
        sleep 30 &
        wait
        """)
        let started = expectation(description: "backend started")
        let task = Task {
            try await BackendBridge.executeStreaming(.doctor, context: context) { _ in
                started.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 5)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))

        let cancelledAt = Date()
        task.cancel()
        let result = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5)
        XCTAssertThrowsError(try result.get())
        // The bridge returns as soon as it signals the backend; give the
        // process a moment to exit and be reaped.
        let deadline = Date().addingTimeInterval(3)
        while kill(pid, 0) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(kill(pid, 0), -1, "the backend process should have exited")
    }
}

private actor UpdateLog {
    private(set) var statuses: [BackendJobStatus?] = []

    func record(_ status: BackendJobStatus?) {
        statuses.append(status)
    }
}
