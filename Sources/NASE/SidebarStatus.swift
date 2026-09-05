import Foundation

/// Readiness is separate from activity: an idle helper is not proof that games can launch.
enum SidebarStatus: Equatable {
    case checking, unavailable, settingUp, setupFailed, working, needsAttention, setupNeeded, ready, unverified

    static func resolve(
        preflight: BackendPreflightState,
        setup: DependencyBootstrapPhase,
        hasWork: Bool,
        lastCheck: HealthStatus?,
        profileReady: Bool,
        usesExternalPrefix: Bool
    ) -> Self {
        if preflight == .unchecked || preflight == .checking { return .checking }
        if preflight == .bootstrapRequired { return .unavailable }
        if [.checking, .installing, .configuring, .profileSetup].contains(setup) { return .settingUp }
        if hasWork { return .working }
        if setup == .failed { return .setupFailed }
        if lastCheck == .error || lastCheck == .warning { return .needsAttention }
        // A managed profile says nothing about an imported environment.
        if usesExternalPrefix { return .unverified }
        return profileReady ? .ready : .setupNeeded
    }

    var title: String {
        switch self {
        case .checking: "Checking NASE…"
        case .unavailable: "NASE needs attention"
        case .settingUp: "Setting up Windows support…"
        case .setupFailed: "Setup needs attention"
        case .working: "Working…"
        case .needsAttention: "Last check found issues"
        case .setupNeeded: "Windows setup needed"
        case .ready: "Ready"
        case .unverified: "Using an imported environment"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Checking the components NASE needs."
        case .unavailable: "NASE couldn't start its helper. Open Settings for recovery options."
        case .settingUp: "Preparing the components your Windows games need."
        case .setupFailed: "Open setup to review the problem and try again."
        case .working: "An operation is in progress."
        case .needsAttention: "Review the latest environment check in Settings."
        case .setupNeeded: "Set up Windows support to get started. Mac apps can still open."
        case .ready: "Windows setup is complete."
        case .unverified: "Check this environment in Settings before launching Windows games."
        }
    }

    var isInProgress: Bool { [.checking, .settingUp, .working].contains(self) }
    var needsAttention: Bool { [.unavailable, .setupFailed, .needsAttention].contains(self) }
    var opensSetup: Bool { self == .setupNeeded || self == .setupFailed }
    var actionTitle: String? {
        if opensSetup { return self == .setupFailed ? "Review Setup" : "Set Up NASE" }
        if needsAttention || self == .unverified { return "Open Settings" }
        return nil
    }
}
