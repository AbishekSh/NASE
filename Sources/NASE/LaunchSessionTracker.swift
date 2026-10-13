import AppKit
import Foundation

/// Watches one PID for termination via kqueue (EVFILT_PROC/NOTE_EXIT) so a
/// game's exit is observed the instant it happens instead of waiting for the
/// next poll. This only tells us "wake up and reconcile now" — reconcile
/// against the backend's session record remains the source of truth for
/// whether the game actually exited.
private final class ExitWatcher {
    let pid: Int
    private let source: DispatchSourceProcess

    init(pid: Int, onExit: @escaping () -> Void) {
        self.pid = pid
        source = DispatchSource.makeProcessSource(identifier: pid_t(pid), eventMask: .exit, queue: .main)
        source.setEventHandler(handler: onExit)
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

/// Decides when the app reconciles launch sessions with the backend.
///
/// A game's card only clears when a reconcile runs after the game exits, so
/// this polls on a timer, refreshes when NASE becomes active and while a
/// launch is being handed off, and reacts the moment a watched process exits.
/// It owns timing only: what the sessions mean for each game stays with the
/// caller, through `onSessions` and `onBackendUnreachable`.
@MainActor
final class LaunchSessionTracker {
    /// Fetches the backend's sessions; nil means the backend did not answer.
    var fetchSessions: @Sendable () async -> [GameLaunchSession]? = { nil }
    var onSessions: ([GameLaunchSession]) -> Void = { _ in }
    /// Called when a poll fails or times out, so the caller can fall back to
    /// checking the processes it already knows about.
    var onBackendUnreachable: (_ timedOut: Bool) -> Void = { _ in }

    private let pollInterval: Duration
    private let pollTimeout: Duration
    private let handoffInterval: Duration
    private var poller: Task<Void, Never>?
    private var pollerGeneration = 0
    private var activationObserver: NSObjectProtocol?
    private var exitWatchersBySessionID: [String: [ExitWatcher]] = [:]
    private var isRefreshing = false
    private var pollAttempt = 0

    init(
        pollInterval: Duration = .seconds(3),
        pollTimeout: Duration = .seconds(20),
        handoffInterval: Duration = .seconds(2)
    ) {
        self.pollInterval = pollInterval
        self.pollTimeout = pollTimeout
        self.handoffInterval = handoffInterval
    }

    var isPolling: Bool {
        poller.map { !$0.isCancelled } ?? false
    }

    /// Start polling, and reconcile immediately whenever NASE comes back to
    /// the foreground so a game closed in the background clears on first sight.
    func start() {
        ensurePolling()
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ensurePolling()
                self?.refresh()
            }
        }
    }

    /// Start the poller, or restart it if it ever finished.
    ///
    /// This loop is what turns "the game exited" into "the card cleared". It
    /// previously exited for good on the first `Task.sleep` cancellation and
    /// nothing re-armed it, which left games showing "Running" indefinitely.
    func ensurePolling() {
        if isPolling { return }
        pollerGeneration &+= 1
        let generation = pollerGeneration
        poller = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNow()
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    // Only a real cancellation should end the poller.
                    if Task.isCancelled { break }
                }
            }
            // Leave the slot empty so this poller can always be re-armed, unless
            // a newer poller already took it.
            if self?.pollerGeneration == generation {
                self?.poller = nil
            }
        }
    }

    /// Stop polling and drop exit watchers, as when NASE is uninstalling itself.
    func stop() {
        poller?.cancel()
        poller = nil
        exitWatchersBySessionID.removeAll()
    }

    func refresh() {
        Task { [weak self] in
            await self?.refreshNow()
        }
    }

    /// Reconcile launch state against the backend once.
    ///
    /// Every exit path must clear `isRefreshing`, and the backend call must be
    /// bounded: a single call that never returns used to wedge the in-flight
    /// flag permanently, silently killing every later poll and leaving finished
    /// games stuck on "Running" until the app was relaunched.
    func refreshNow() async {
        guard !isRefreshing else { return }
        pollAttempt &+= 1
        let attempt = pollAttempt
        isRefreshing = true
        // Watchdog: if this call never comes back, release the in-flight flag
        // anyway so the next tick can try again. Bumping the attempt token stops
        // the abandoned call from later clearing a newer poll's flag; a late
        // reply is otherwise harmless and just applies its sessions when it lands.
        let watchdog = Task { [weak self, pollTimeout] in
            try? await Task.sleep(for: pollTimeout)
            guard let self, !Task.isCancelled, self.pollAttempt == attempt else { return }
            self.pollAttempt &+= 1
            self.isRefreshing = false
            self.onBackendUnreachable(true)
        }
        let fetch = fetchSessions
        let sessions = await Task.detached(priority: .utility) { await fetch() }.value
        watchdog.cancel()
        if pollAttempt == attempt {
            isRefreshing = false
        }
        if let sessions {
            onSessions(sessions)
        } else {
            onBackendUnreachable(false)
        }
    }

    /// Re-check every couple of seconds after a launch is handed off, until
    /// `isPending` reports the launch has settled or been superseded.
    func followHandoff(while isPending: @escaping () -> Bool) {
        Task { [weak self, handoffInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: handoffInterval)
                } catch {
                    return
                }
                guard let self, isPending() else { return }
                await self.refreshNow()
                if !isPending() {
                    return
                }
            }
        }
    }

    /// Keep one exit watcher per PID of each active session, so a game's exit
    /// triggers a reconcile immediately rather than on the next poll.
    func watch(_ activeSessions: [GameLaunchSession]) {
        let activeSessionIDs = Set(activeSessions.map(\.sessionID))
        for sessionID in exitWatchersBySessionID.keys where !activeSessionIDs.contains(sessionID) {
            exitWatchersBySessionID.removeValue(forKey: sessionID)
        }
        for session in activeSessions {
            let currentPIDs = Set(session.pids)
            guard !currentPIDs.isEmpty else { continue }
            let watchedPIDs = Set((exitWatchersBySessionID[session.sessionID] ?? []).map(\.pid))
            guard currentPIDs != watchedPIDs else { continue }
            let sessionID = session.sessionID
            exitWatchersBySessionID[sessionID] = currentPIDs.map { pid in
                ExitWatcher(pid: pid) { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.handleWatchedExit(sessionID: sessionID)
                    }
                }
            }
        }
    }

    private func handleWatchedExit(sessionID: String) {
        guard exitWatchersBySessionID[sessionID] != nil else { return }
        refresh()
    }
}
