import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// The immutable state the event tap reads on its own thread.
///
/// Everything the hot path needs is a value type so the callback can take one
/// snapshot under an uncontended lock and never touch main-actor state.
struct KeyboardRemapGate: Sendable, Equatable {
    var isArmed: Bool = false
    /// Each launched game's own substitution table, keyed by its processes.
    ///
    /// Per-PID rather than one shared table because two games can run at the
    /// same time with different layouts, and each must only ever see its own.
    var remapsByPID: [pid_t: [CGKeyCode: CGKeyCode]] = [:]
    /// Updated from the main actor when the focused application changes, so the
    /// callback compares two integers instead of calling into AppKit.
    var frontmostPID: pid_t = 0
    /// Incremented whenever macOS disables the tap, so the UI can explain a
    /// remap that silently stopped applying.
    var timeoutCount: Int = 0
    /// Incremented by the panic chord. A counter rather than a flag because the
    /// service must be able to tell "the user panicked" from "the gate happens
    /// to be closed", and a later re-arm must not erase the request.
    var panicCount: Int = 0

    /// A remap applies only while NASE has armed one *and* the focused
    /// application is one of the launched game's own processes. Wine gives each
    /// `wine game.exe` its own process and Cocoa app, so this is genuinely
    /// per-game rather than per-prefix.
    var focusedRemaps: [CGKeyCode: CGKeyCode]? {
        guard isArmed, frontmostPID > 0 else { return nil }
        guard let table = remapsByPID[frontmostPID], !table.isEmpty else { return nil }
        return table
    }

    var appliesToFocusedApplication: Bool { focusedRemaps != nil }

    func substitute(for keyCode: CGKeyCode) -> CGKeyCode? {
        focusedRemaps?[keyCode]
    }
}

/// Owns the CoreGraphics event tap and the thread it runs on.
///
/// The tap sits upstream of `winemac.drv`: it rewrites the key event before
/// Wine ever translates it, so a remap reaches the game no matter which Windows
/// input API the game reads — window messages, DirectInput, or Raw Input.
///
/// This type is `@unchecked Sendable` because it hands a pointer to itself to a
/// C callback. Its mutable state is either behind `gate` (the hot path) or
/// `handleLock` (start/stop only).
final class KeyboardRemapTap: @unchecked Sendable {
    private let gate = OSAllocatedUnfairLock(initialState: KeyboardRemapGate())

    private let handleLock = NSLock()
    private var tapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?

    /// ⌃⌥⌘K disarms every remap. It is checked before the focus gate so it
    /// still works when the gate itself is what is misbehaving, and it is never
    /// remapped or consumed.
    private static let panicKeyCode = NASEKeyCode.k
    private static let panicFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    var snapshot: KeyboardRemapGate {
        gate.withLock { $0 }
    }

    var isRunning: Bool {
        handleLock.withLock { tapPort != nil }
    }

    // MARK: - Gate updates

    func update(_ mutate: (inout KeyboardRemapGate) -> Void) {
        gate.withLock { mutate(&$0) }
    }

    // MARK: - Lifecycle

    /// Create the tap on a dedicated thread.
    ///
    /// The tap deliberately does not run on the main run loop: a SwiftUI render
    /// pass long enough to stall the callback would make macOS disable the tap
    /// mid-game.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        handleLock.withLock { tapThread = nil }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.runTapLoop(signalling: ready)
            ready.signal()
        }
        thread.name = "com.nase.keyboard-remap"
        thread.qualityOfService = .userInteractive
        handleLock.withLock { tapThread = thread }
        thread.start()

        // A tap that cannot be created fails immediately, so a bounded wait
        // distinguishes "refused" from "still starting" without blocking the UI.
        _ = ready.wait(timeout: .now() + 2)
        return isRunning
    }

    func stop() {
        gate.withLock { $0.isArmed = false }
        let (port, source, loop) = handleLock.withLock {
            let values = (tapPort, runLoopSource, tapRunLoop)
            tapPort = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
            return values
        }
        // Disable synchronously: once this returns, no further event can be
        // rewritten, even though the run loop takes a moment longer to exit.
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
        }
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            if let port {
                CFMachPortInvalidate(port)
            }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(loop)
    }

    private func runTapLoop(signalling ready: DispatchSemaphore) {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: keyboardRemapTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let loop = CFRunLoopGetCurrent()
        handleLock.withLock {
            tapPort = port
            runLoopSource = source
            tapRunLoop = loop
        }
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        ready.signal()

        CFRunLoopRun()
        teardownOnTapThread()
    }

    private func teardownOnTapThread() {
        let (port, source, loop) = handleLock.withLock {
            let values = (tapPort, runLoopSource, tapRunLoop)
            tapPort = nil
            runLoopSource = nil
            tapRunLoop = nil
            tapThread = nil
            return values
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source, let loop {
            CFRunLoopRemoveSource(loop, source, .commonModes)
        }
    }

    // MARK: - Hot path

    /// Internal rather than fileprivate so tests can drive the real callback
    /// with a synthesized event. It touches no CoreGraphics state of its own
    /// when the tap is not running, so it is testable without Accessibility.
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback was too slow, or on certain user
        // input. Without re-enabling here a remap would stop applying silently.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gate.withLock { $0.timeoutCount += 1 }
            if let port = handleLock.withLock({ tapPort }) {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return nil
        }

        guard type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        let flags = event.flags
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == Self.panicKeyCode, flags.isSuperset(of: Self.panicFlags) {
            gate.withLock {
                $0.isArmed = false
                $0.panicCount += 1
            }
            return Unmanaged.passUnretained(event)
        }

        // Command combinations are never rewritten, so ⌘Q and ⌘Tab keep working
        // while a full-screen Wine game holds focus.
        if flags.contains(.maskCommand) {
            return Unmanaged.passUnretained(event)
        }

        guard let substitute = gate.withLock({ $0.substitute(for: keyCode) }) else {
            return Unmanaged.passUnretained(event)
        }

        // Mutating in place preserves the event's timing and cannot re-enter
        // this tap, which posting a synthetic event would. Both keyDown and
        // keyUp go through the same stateless rule, so a remapped key can never
        // stick down in the game.
        Self.rewrite(event: event, to: substitute)
        return Unmanaged.passUnretained(event)
    }
}

extension KeyboardRemapTap {
    /// Make `event` look like a genuine press of `target`.
    ///
    /// Setting the key code alone is not enough. macOS marks arrows and the
    /// navigation cluster with the Fn flag, marks arrows with the numeric-pad
    /// flag, and carries a Unicode payload describing the character. Left
    /// unchanged, those fields still describe the key the user actually
    /// pressed, and the resulting event matches no real key — which is why a
    /// key-code-only rewrite can arrive at a Wine game as nothing at all.
    static func rewrite(event: CGEvent, to target: CGKeyCode) {
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(target))

        let traits = NASEKeyCode.traits(for: target)
        var flags = event.flags
        flags.remove([.maskSecondaryFn, .maskNumericPad])
        if traits.needsFunctionFlag { flags.insert(.maskSecondaryFn) }
        if traits.needsNumericPadFlag { flags.insert(.maskNumericPad) }
        event.flags = flags

        if var unicode = traits.unicode {
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unicode)
        }
    }
}

/// Pass-through is the first thing this callback does. Every path that is not a
/// confirmed in-game substitution returns the original event untouched, so a
/// bug here cannot swallow the user's keystrokes system-wide.
private let keyboardRemapTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyboardRemapTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(type: type, event: event)
}

// MARK: - Service

enum KeyboardRemapPermission: Equatable {
    case granted
    case denied

    var isGranted: Bool { self == .granted }
}

/// Per-game keyboard remapping for NASE-launched Windows games.
///
/// This never touches Wine, a prefix, the registry, or a launch environment, so
/// it stays entirely on the SwiftUI side of the app/backend boundary. The only
/// thing it needs from the backend is the set of PIDs `sessions.py` already
/// tracks for a running game.
@MainActor
@Observable
final class KeyboardRemapService {
    private(set) var permission: KeyboardRemapPermission = .denied
    private(set) var isTapRunning: Bool = false
    private(set) var lastError: String?
    private(set) var activeGamePIDCount: Int = 0
    /// Running games, whether or not they have a layout assigned. Without this
    /// the status line cannot tell "no game is running" from "a game is running
    /// but nothing is assigned to it" — two states with different fixes.
    private(set) var activeGameCount: Int = 0
    private(set) var isApplyingToFocusedGame: Bool = false
    private(set) var disableCount: Int = 0
    /// Set when Accessibility looks granted in System Settings but this process
    /// cannot use it. macOS decides a process's Accessibility trust when it
    /// starts, so a grant made while NASE is running does not reach it.
    private(set) var needsRelaunchToApplyPermission = false

    /// Persisted user intent. The tap is only created once this is on and
    /// Accessibility has been granted.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reconcile()
        }
    }

    /// Layouts the user built, loaded from disk.
    private(set) var userLayouts: [KeyboardLayout] = []
    /// A problem loading or saving layouts, for display in Settings.
    private(set) var layoutWarning: String?

    var availableLayouts: [KeyboardLayout] { KeyboardLayout.builtIns + userLayouts }

    func layout(id: String) -> KeyboardLayout? {
        KeyboardLayout.builtIn(id: id) ?? userLayouts.first { $0.id == id }
    }

    /// Add or replace a user layout. Validation runs before anything is
    /// written, so an unusable layout never reaches disk or the tap.
    func saveLayout(_ layout: KeyboardLayout) throws {
        try layout.validate()
        var stored = layout
        stored.isBuiltIn = false
        var updated = userLayouts
        if let index = updated.firstIndex(where: { $0.id == stored.id }) {
            updated[index] = stored
        } else {
            updated.append(stored)
        }
        try store.save(updated)
        userLayouts = updated
        layoutWarning = nil
        // An edit must reach a game that already has this layout assigned.
        reconcile()
    }

    func deleteLayout(id: String) {
        let updated = userLayouts.filter { $0.id != id }
        guard updated.count != userLayouts.count else { return }
        do {
            try store.save(updated)
            userLayouts = updated
            layoutWarning = nil
        } catch {
            layoutWarning = "NASE could not delete that layout: \(error.localizedDescription)"
            return
        }
        // Any game still pointing at the deleted id resolves to nothing, which
        // closes its gate rather than falling back to some other layout.
        reconcile()
    }

    func reloadLayouts() {
        let result = store.load()
        userLayouts = result.layouts
        layoutWarning = result.warning
        reconcile()
    }

    private static let enabledKey = "input.keyboardRemapEnabled"

    @ObservationIgnored private let tap = KeyboardRemapTap()
    @ObservationIgnored private let store: KeyboardLayoutStore
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    /// PID → the layout id assigned to the game that owns it.
    @ObservationIgnored private var layoutIDsByPID: [pid_t: String] = [:]
    @ObservationIgnored private var lastSeenPanicCount = 0

    init(store: KeyboardLayoutStore = .standard()) {
        self.store = store
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        permission = AXIsProcessTrusted() ? .granted : .denied
        let loaded = store.load()
        userLayouts = loaded.layouts
        layoutWarning = loaded.warning
        observeFocusChanges()
        pushFrontmostPID()
        reconcile()
    }

    deinit {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    // MARK: - Permission

    /// Re-check whether NASE can remap keys.
    ///
    /// `AXIsProcessTrusted()` alone is not enough: it reports what this process
    /// was granted at launch, so it stays false after the user flips the switch
    /// in System Settings. Creating an event tap is the only ground truth for
    /// the capability actually needed, so that is what decides, and a failure
    /// is reported as "relaunch" rather than "denied".
    func refreshPermission() {
        if AXIsProcessTrusted() || tap.start() {
            permission = .granted
            needsRelaunchToApplyPermission = false
        } else {
            permission = .denied
            // The switch being on while the tap is refused means this session
            // predates the grant; a fresh launch will pick it up.
            needsRelaunchToApplyPermission = true
        }
        reconcile()
    }

    /// Quit so the user can reopen NASE with the grant applied.
    func quitForRelaunch() {
        NSApplication.shared.terminate(nil)
    }

    /// The exact file macOS checks against the Accessibility list.
    ///
    /// Worth showing: an unsigned build is matched by path, and a project can
    /// easily have several — SwiftPM's `.build` copy, Xcode's DerivedData copy,
    /// and a packaged NASE.app are three different files with three separate
    /// grants, all displayed in System Settings as just "NASE".
    var executablePathForPermissions: String {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
            ?? ProcessInfo.processInfo.arguments.first
            ?? "unknown"
    }

    /// Whether this build is one macOS will treat as its own separate grant.
    var isUnbundledDevelopmentBuild: Bool {
        Bundle.main.bundleIdentifier == nil
    }

    /// Show the running binary in Finder so it can be dragged straight into the
    /// Accessibility list.
    func revealExecutableInFinder() {
        let url = URL(fileURLWithPath: executablePathForPermissions)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Ask macOS to show its own Accessibility prompt. The grant is tied to the
    /// signed bundle, so development builds re-prompt after a rebuild.
    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshPermission()
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Session tracking

    /// Assign each running game's processes the layout that game selected.
    ///
    /// An empty mapping closes the gate, so a remap can never outlive the game
    /// it was meant for.
    func updateTargets(_ assignments: [pid_t: String], activeGameCount: Int) {
        guard assignments != layoutIDsByPID || activeGameCount != self.activeGameCount else { return }
        layoutIDsByPID = assignments
        activeGamePIDCount = assignments.count
        self.activeGameCount = activeGameCount
        reconcile()
    }

    /// Resolve assigned layout ids into the tables the tap reads. An id with no
    /// matching layout is dropped rather than guessed at.
    private func resolvedRemapTables() -> [pid_t: [CGKeyCode: CGKeyCode]] {
        var tables: [pid_t: [CGKeyCode: CGKeyCode]] = [:]
        for (pid, layoutID) in layoutIDsByPID {
            guard let layout = layout(id: layoutID) else { continue }
            let table = layout.remapTable
            guard !table.isEmpty else { continue }
            tables[pid] = table
        }
        return tables
    }

    /// Turn every remap off immediately, without waiting for a game to exit.
    func disarm() {
        isEnabled = false
    }

    // MARK: - Internals

    private func observeFocusChanges() {
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pushFrontmostPID()
            }
        }
    }

    private func pushFrontmostPID() {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        tap.update { $0.frontmostPID = pid }
        reconcile()
    }

    /// Turn a panic-chord press into the persisted "off" state.
    ///
    /// This must run before `reconcile` re-arms the gate, or a routine session
    /// poll would quietly undo the disarm the user just asked for.
    private func consumePanicRequest() -> Bool {
        let count = tap.snapshot.panicCount
        let disarms = Self.panicRequiresDisarm(
            panicCount: count,
            lastSeen: lastSeenPanicCount,
            isEnabled: isEnabled
        )
        lastSeenPanicCount = count
        guard disarms else { return false }
        // Assigning here re-enters `reconcile` through `didSet`, which performs
        // the actual teardown.
        isEnabled = false
        return true
    }

    /// A panic press only needs handling once, and only while remapping is on.
    ///
    /// Comparing counts rather than reading `isArmed` is what stops a routine
    /// session poll from re-arming a remap the user just panicked out of.
    nonisolated static func panicRequiresDisarm(panicCount: Int, lastSeen: Int, isEnabled: Bool) -> Bool {
        panicCount != lastSeen && isEnabled
    }

    private func reconcile() {
        if consumePanicRequest() { return }
        let wantsTap = isEnabled && permission.isGranted

        if wantsTap, !tap.isRunning {
            if tap.start() {
                lastError = nil
            } else {
                lastError = permission.isGranted
                    ? "macOS refused the keyboard event tap. Quit and reopen NASE, then try again."
                    : "NASE needs Accessibility access before it can remap keys."
            }
        } else if !wantsTap, tap.isRunning {
            tap.stop()
        }

        let tables = wantsTap ? resolvedRemapTables() : [:]
        tap.update {
            $0.isArmed = wantsTap
            $0.remapsByPID = tables
        }
        publishState()
    }

    private func publishState() {
        let state = tap.snapshot
        isTapRunning = tap.isRunning
        isApplyingToFocusedGame = state.appliesToFocusedApplication
        disableCount = state.timeoutCount
    }

    /// Whether a per-game layout would actually take effect right now.
    var isReadyToRemap: Bool {
        isEnabled && permission.isGranted && isTapRunning
    }

    /// Human-readable state for Settings.
    var statusSummary: String {
        if needsRelaunchToApplyPermission {
            return "Quit and reopen NASE to finish enabling Accessibility."
        }
        if !permission.isGranted {
            return "Accessibility access is required."
        }
        if !isEnabled {
            return "Remapping is off."
        }
        if !isTapRunning {
            return lastError ?? "The keyboard tap is not running."
        }
        // Read the observed counts, not the private dictionary, so SwiftUI
        // re-renders this line when a game starts or exits.
        if activeGamePIDCount == 0 {
            if activeGameCount > 0 {
                return "A game is running, but no keyboard layout is assigned to it. Open that game's \u{22EF} menu \u{2192} Settings \u{2192} Keyboard, pick a layout, and Save."
            }
            return "Waiting for a NASE game to launch."
        }
        if isApplyingToFocusedGame {
            return "Remapping the focused game."
        }
        return "Armed. Bring the game window to the front to remap it."
    }
}
