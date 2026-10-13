import Foundation
import Observation

extension BackendJobStatus {
    /// Still owned by a backend process: queued, running, or cancelling.
    var isActive: Bool {
        switch self {
        case .queued, .started, .cancelling:
            true
        case .completed, .failed, .cancelled, .interrupted:
            false
        }
    }
}

/// Backend jobs as the app sees them: what is running now and what finished
/// recently.
///
/// Starting a backend command shows a placeholder job immediately; the
/// backend's own job record replaces it as events stream in. The store holds
/// state only, with no process or bridge access, so its transitions are
/// testable on their own.
@MainActor
@Observable
final class BackendJobStore {
    static let recentLimit = 12

    private(set) var active: [BackendJob] = []
    private(set) var recent: [BackendJob] = []

    var current: BackendJob? { active.first }

    var hasActiveWork: Bool { active.contains { $0.status.isActive } }

    /// Whether a job with this display name is queued or running. A job that
    /// is only cancelling does not block starting the action again.
    func isRunning(_ actionName: String) -> Bool {
        active.contains { $0.action == actionName && ($0.status == .started || $0.status == .queued) }
    }

    /// Show a placeholder until the backend reports its own job; returns its id.
    func begin(actionName: String, message: String) -> String {
        let job = BackendJob(
            id: UUID().uuidString,
            action: actionName,
            status: .started,
            message: message,
            progress: nil,
            completedSteps: nil,
            totalSteps: nil
        )
        active.removeAll { $0.action == job.action && $0.status == .started }
        active.insert(job, at: 0)
        return job.id
    }

    /// Apply a job record streamed by the backend in place of the placeholder.
    func apply(_ job: BackendJob, placeholderID: String) {
        active.removeAll { $0.id == placeholderID || $0.id == job.id || $0.action == job.action }
        if job.status.isActive {
            active.insert(job, at: 0)
        } else {
            record(job)
        }
    }

    /// Close the placeholder with `job` unless the backend's result already did.
    func finish(placeholderID: String, with job: BackendJob) {
        guard active.contains(where: { $0.id == placeholderID }) else { return }
        active.removeAll { $0.id == placeholderID }
        record(job)
    }

    /// Replace both lists with the backend's durable job history.
    func load(history jobs: [BackendJob]) {
        active = jobs.filter { $0.status.isActive }
        recent = Array(jobs.filter { !$0.status.isActive }.prefix(Self.recentLimit))
    }

    private func record(_ job: BackendJob) {
        recent.removeAll { $0.id == job.id }
        recent.insert(job, at: 0)
        if recent.count > Self.recentLimit {
            recent = Array(recent.prefix(Self.recentLimit))
        }
    }
}
