import Foundation

enum RunnerKind: String, CaseIterable, Identifiable {
    case home = "Home"
    case mac = "macOS"
    case steam = "Steam"
    case wine = "Wine"
    case epic = "Epic Games"
    case gog = "GOG"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .home:
            "house.fill"
        case .mac:
            "laptopcomputer"
        case .steam:
            "shippingbox.circle"
        case .wine:
            "wineglass"
        case .epic:
            "sparkles.rectangle.stack"
        case .gog:
            "square.stack.3d.up"
        }
    }

    var accentName: String {
        switch self {
        case .home:
            "HomeAccent"
        case .mac:
            "MacAccent"
        case .steam:
            "SteamAccent"
        case .wine:
            "WineAccent"
        case .epic:
            "SoonAccent"
        case .gog:
            "SoonAccent"
        }
    }

    var isAvailable: Bool {
        switch self {
        case .home, .mac, .steam, .wine, .epic, .gog:
            true
        }
    }

    var subtitle: String {
        switch self {
        case .home:
            "Pinned apps from every source"
        case .mac:
            "Native library and local launches"
        case .steam:
            "Windows Steam via managed Wine"
        case .wine:
            "Prefixes, runtime health, Metal stack"
        case .epic:
            "Epic library via Legendary"
        case .gog:
            "DRM-free library via GOG Download Client"
        }
    }
}

struct SidebarSection: Identifiable {
    let id: String
    let title: String
    let runners: [RunnerKind]
}

enum GraphicsBackendOption: String, CaseIterable, Identifiable, Codable {
    case dxmt = "DXMT"
    case dxvk = "DXVK-macOS"
    case d3dmetal = "D3DMetal"
    case none = "None"

    var id: String { rawValue }

    var cliValue: String {
        switch self {
        case .dxmt:
            return "dxmt"
        case .dxvk:
            return "dxvk"
        case .d3dmetal:
            return "d3dmetal"
        case .none:
            return "none"
        }
    }

    var compatibilityProfileID: String {
        switch self {
        case .dxmt: "dxmt-wine-stable-11-v1"
        case .d3dmetal: "d3dmetal-gptk-v1"
        case .dxvk: "dxvk-macos-pinned-v1"
        case .none: "plain-wine-v1"
        }
    }

    var bottleSuffix: String {
        switch self {
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        case .dxvk: "DXVK-macOS"
        case .none: "Plain"
        }
    }

    var profileSummary: String {
        switch self {
        case .dxmt: "Wine Stable 11 + DXMT 0.71"
        case .d3dmetal: "Sikarugir Wine 10 r6 + complete D3DMetal runtime bundle"
        case .dxvk: "Sikarugir Wine 10 r6 + matching winevulkan + DXVK-macOS 1.10.3 + MoltenVK 1.4.1"
        case .none: "Selected Wine runtime with built-in graphics"
        }
    }
}

enum GameCollection: String, CaseIterable, Identifiable, Codable {
    case none = "None"
    case favorites = "Favorites"
    case finished = "Finished"
    case testing = "Testing"
    case broken = "Broken"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .none:
            return "tray"
        case .favorites:
            return "star.fill"
        case .finished:
            return "checkmark.seal.fill"
        case .testing:
            return "testtube.2"
        case .broken:
            return "exclamationmark.triangle.fill"
        }
    }
}

enum LibrarySortOption: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case title = "Title"
    case size = "Size"
    case recent = "Recent"

    var id: String { rawValue }
}

enum GameStatusFilterOption: String, CaseIterable, Identifiable {
    case all = "All"
    case installed = "Installed"
    case installers = "Installers"

    var id: String { rawValue }
}

enum HealthStatus: String, Codable {
    case unknown
    case healthy
    case warning
    case error
}

enum BackendJobStatus: String, Codable, Hashable {
    case queued
    case started
    case cancelling
    case completed
    case failed
    case cancelled
    case interrupted
}

enum SetupWizardStep: String, CaseIterable, Identifiable {
    case welcome = "Welcome"
    case wine = "Wine"
    case winetricks = "Winetricks"
    case graphics = "Graphics"
    case bottle = "Bottle"
    case steam = "Steam"
    case finish = "Finish"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .welcome:
            return "What the setup flow will do"
        case .wine:
            return "Detect Wine and explain install steps"
        case .winetricks:
            return "Detect Winetricks and explain install steps"
        case .graphics:
            return "Choose the DXMT payload for Metal support"
        case .bottle:
            return "Pick the managed bottle to create and maintain"
        case .steam:
            return "Run the managed Steam + Metal setup flow"
        case .finish:
            return "Review the result and open Steam"
        }
    }
}

struct BackendJob: Identifiable, Hashable {
    let id: String
    let action: String
    let status: BackendJobStatus
    let message: String
    let progress: Double?
    let completedSteps: Int?
    let totalSteps: Int?
}

enum GameLaunchPhase: String, Codable, Hashable {
    case launching = "Launching..."
    case running = "Running"
    case stopping = "Stopping..."
    case exited = "Exited"
    case failed = "Failed"

    init(sessionStatus: String) {
        switch sessionStatus {
        case "running":
            self = .running
        case "stopping":
            self = .stopping
        case "failed":
            self = .failed
        case "launching":
            self = .launching
        default:
            self = .exited
        }
    }

    var isActive: Bool {
        switch self {
        case .launching, .running, .stopping:
            true
        case .exited, .failed:
            false
        }
    }
}

struct GameLaunchStatus: Hashable, Codable {
    let phase: GameLaunchPhase
    let message: String
    let updatedAt: Date
}

struct GameLaunchSession: Identifiable, Hashable, Codable {
    let sessionID: String
    let appid: String?
    let game: String
    let status: String
    let strategy: String
    let graphicsBackend: String
    let profileID: String
    let bottle: String
    let prefix: String
    let executable: String?
    let installDir: String?
    let pids: [Int]
    let message: String

    var id: String { sessionID }
    var isActive: Bool { ["launching", "running", "stopping"].contains(status) }
}

struct BackendCheckSummary: Identifiable, Hashable {
    let id: String
    let status: String
    let name: String
    let detail: String
    let required: Bool
    let fix: String?
}

enum DependencyBootstrapPhase: String, Hashable {
    case idle
    case checking
    case installing
    case configuring
    case profileSetup
    case ready
    case failed
}

struct BackendStepSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let status: String
}

struct BackendSignalSummary: Identifiable, Hashable {
    let id: String
    let key: String
    let detail: String
    let path: String
}

struct BackendRecommendationSummary: Identifiable, Hashable {
    let id: String
    let verb: String
    let reason: String
}

struct BackendStructuredResult: Hashable {
    let action: String
    let root: String?
    let target: String?
    let worstStatus: String?
    let fixes: [String]
    let checks: [BackendCheckSummary]
    let steps: [BackendStepSummary]
    let signals: [BackendSignalSummary]
    let recommendations: [BackendRecommendationSummary]
    let warnings: [String]
    let errors: [String]
    let tail: String?
    let completedSteps: Int?
    let totalSteps: Int?
    let gptkWinePath: String?
    let d3dMetalSource: String?
}

struct BackendStreamUpdate: Hashable {
    let job: BackendJob?
    let structured: BackendStructuredResult?
}

struct EffectiveGraphicsOverrides: Hashable {
    let targetLabel: String
    let prefixPath: String
    let graphicsBackend: GraphicsBackendOption
    let registryOverrides: [String]
    let launchOverrides: String?
    let compatibilityWarnings: [String]
    let environmentWarnings: [String]
}

struct WineRuntimeRecord: Identifiable, Codable, Hashable {
    enum SourceKind: String, Codable, CaseIterable {
        case bundled
        case importedApp
        case importedBinary
        case detected
    }

    let id: String
    var name: String
    var executablePath: String
    var sourceKind: SourceKind
    var containerPath: String?
    var isManaged: Bool

    var displaySubtitle: String {
        switch sourceKind {
        case .bundled:
            return "Managed by the launcher"
        case .importedApp:
            return "Imported Wine app"
        case .importedBinary:
            return "Imported executable"
        case .detected:
            return "Detected on this Mac"
        }
    }
}

struct ManagedRuntime: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let version: String
    let kind: String
    let source: String?
    let downloadURL: String?
    let sha256: String?
    let archiveType: String?
    let installLayout: String?
    let license: String?
    let notes: String?
    let installed: Bool
    let path: String?
    let executable: String?
    let installedAt: Double?

    var displayName: String {
        "\(name) \(version)"
    }

    var kindLabel: String {
        switch kind {
        case "wine":
            return "Wine"
        case "dxvk":
            return "DXVK"
        case "dxmt":
            return "DXMT"
        case "d3dmetal":
            return "D3DMetal"
        case "media-runtime":
            return "Media"
        case "tool":
            return "Tool"
        case "source-client":
            return "Store Client"
        default:
            return kind.capitalized
        }
    }
}

enum LibrarySourceFilter: String, CaseIterable, Identifiable {
    case all = "All Sources"
    case mac = "macOS"
    case steam = "Steam"
    case wine = "Wine"
    case epic = "Epic Games"
    case gog = "GOG"

    var id: String { rawValue }
}

struct LibraryGame: Identifiable, Hashable {
    let id: UUID
    let pinID: String
    let backendID: String?
    let title: String
    let runner: RunnerKind
    let capsule: String
    let status: String
    let statsText: String?
    let bannerURL: URL?
    let portraitURL: URL?
    let installURL: URL?
    let launchURL: URL?
    let storeURL: URL?

    init(
        id: UUID = UUID(),
        pinID: String? = nil,
        backendID: String? = nil,
        title: String,
        runner: RunnerKind,
        capsule: String,
        status: String,
        statsText: String? = nil,
        bannerURL: URL? = nil,
        portraitURL: URL? = nil,
        installURL: URL? = nil,
        launchURL: URL? = nil,
        storeURL: URL? = nil
    ) {
        self.id = id
        self.pinID = pinID ?? "\(runner.rawValue):\(backendID ?? title)"
        self.backendID = backendID
        self.title = title
        self.runner = runner
        self.capsule = capsule
        self.status = status
        self.statsText = statsText
        self.bannerURL = bannerURL
        self.portraitURL = portraitURL
        self.installURL = installURL
        self.launchURL = launchURL
        self.storeURL = storeURL
    }

    static func importedPinID(runner: RunnerKind, url: URL) -> String {
        let normalizedPath = url.standardizedFileURL.path
            .precomposedStringWithCanonicalMapping
            .lowercased()
        return "\(runner.rawValue):path:\(normalizedPath)"
    }
}

struct OperationCard: Identifiable {
    let id = UUID()
    let kind: OperationKind
    let title: String
    let detail: String
    let symbolName: String
}

enum OperationKind {
    case setupMetal
    case doctor
    case doctorFix
    case winetricks
    case installDXMT
    case installD3DMetal
    case winecfg
    case killWine
    case openSteam
    case refreshGames
    case launchSelectedGame
}
