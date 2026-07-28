import AppKit
import CryptoKit
import Foundation
import Observation
import UniformTypeIdentifiers

private enum LibraryStorageKey {
    static let nativeApps = "library.nativeApps"
    static let wineApps = "library.wineApps"
    static let pinnedIDs = "library.pinnedIDs"
    static let steamOrder = "library.steamOrder"
    static let hiddenSteamAppIDs = "library.hiddenSteamAppIDs"
    static let gameSettings = "library.gameSettings"
    static let sourceHealth = "library.sourceHealth"
    static let wineRuntimes = "library.wineRuntimes"
    static let didCompleteInitialSetup = "library.didCompleteInitialSetup"
}

private enum MemoryLimit {
    static let activityLogCharacters = 120_000
    static let displayedLogBytes = 256 * 1024
}

private struct StoredLibraryItem: Codable {
    let pinID: String?
    let title: String
    let runner: String
    let installPath: String
    let launchPath: String?
    let status: String?
}

struct StoredGameSettings: Codable {
    var launchArguments: String = ""
    var workingDirectoryPath: String = ""
    var environmentText: String = ""
    var graphicsBackend: GraphicsBackendOption = .dxmt
    var launchExecutablePath: String = ""
    var customBannerPath: String = ""
    var collection: GameCollection = .none
    var assignedBottleName: String = ""
    var assignedExternalPrefix: String = ""
    var legacyDirectXEnabled: Bool?
    var legacyDirectXSource: String?
    var graphicsBackendWasExplicitlySelected: Bool?
}

fileprivate struct SteamLocalMetadata {
    var playtimeMinutes: Int?
    var lastPlayed: Date?
}

struct DisplayedLogEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let text: String
}

struct WinetricksComponentStatus: Identifiable, Hashable {
    enum State: Hashable {
        case installed
        case missing
        case unavailable
    }

    let id: String
    let title: String
    let state: State
    let detail: String
}

enum BackendDebugSection: String, CaseIterable, Identifiable {
    case activityLog = "Activity Log"
    case bridgeCommands = "Backend Bridge"

    var id: String { rawValue }
}

enum BackendPreflightState: Equatable {
    case unchecked
    case checking
    case bootstrapRequired
    case ready
}

@MainActor
@Observable
final class AppViewModel {
    let sidebarSections: [SidebarSection] = [
        SidebarSection(id: "libraries", title: "Libraries", runners: [.home, .mac, .steam, .wine, .epic, .gog]),
    ]

    var selectedRunner: RunnerKind? = .home
    var selectedGame: LibraryGame?
    var searchText: String = ""
    var rightPanelMessage: String = "Select a runner to see setup state and actions."
    var activityLog: String = "SwiftUI shell ready.\n"
    private var provisioningProfiles: Set<GraphicsBackendOption> = []
    var isBusy: Bool {
        isDependencyBootstrapRunning
            || isActionRunning(.setupMetal)
            || isActionRunning(.doctorFix)
            || isActionRunning(.installDXMT)
            || isActionRunning(.installDXVK)
            || isActionRunning(.installD3DMetal)
            || isActionRunning(.attachSteamLibraries(.dxmt))
    }
    var isRefreshingSteamGames: Bool {
        isActionRunning(.listGames)
    }
    var isD3DMetalDiscoveryRunning: Bool {
        isActionRunning(.discoverD3DMetal)
    }
    var hasDetectedD3DMetalRuntime: Bool {
        let source = URL(fileURLWithPath: backendContext.d3dMetalSource)
        let framework = source.appendingPathComponent("external/D3DMetal.framework")
        let sharedLibrary = source.appendingPathComponent("external/libd3dshared.dylib")
        let windowsModules = source.appendingPathComponent("wine/x86_64-windows")
        return FileManager.default.fileExists(atPath: framework.path)
            && FileManager.default.fileExists(atPath: sharedLibrary.path)
            && FileManager.default.fileExists(atPath: windowsModules.path)
    }
    var d3DMetalRuntimeLocation: String {
        backendContext.d3dMetalSource
    }
    var isShowingSettings: Bool = false
    var isShowingGameSettings: Bool = false
    var isShowingGameDetails: Bool = false
    var isShowingLogViewer: Bool = false
    var isShowingWinetricks: Bool = false
    var isShowingSetupWizard: Bool = false
    var isShowingEpicSetup: Bool = false
    var isShowingGOGSetup: Bool = false
    var isCheckingForUpdates: Bool = false
    var isDownloadingUpdate: Bool = false
    var updateStatusMessage: String = "Updates have not been checked yet."
    var availableUpdate: NASEUpdateManifest?
    private(set) var isUninstallingNASE: Bool = false
    private(set) var uninstallStatusMessage: String = ""
    var backendContext: BackendContext = .default()
    var hasAttemptedSteamDetection: Bool = false
    var sortOption: LibrarySortOption = .manual
    var collectionFilter: GameCollection?
    var sourceFilter: LibrarySourceFilter = .all
    var editingGamePinID: String?
    var selectedLogText: String = ""
    var selectedLogTitle: String = "Logs"
    var selectedLogEntries: [DisplayedLogEntry] = []
    var selectedLogEntryID: String?
    var expandedDebugSections: Set<BackendDebugSection> = []

    private(set) var activeBackendJobs: [BackendJob] = []
    private(set) var recentBackendJobs: [BackendJob] = []
    private(set) var latestDoctorResult: BackendStructuredResult?
    private(set) var latestDependencyResult: BackendStructuredResult?
    private(set) var dependencyBootstrapPhase: DependencyBootstrapPhase = .idle
    private(set) var dependencyBootstrapMessage: String = "Ready to prepare the recommended environment."
    private(set) var dependencyBootstrapProgress: Double = 0
    private(set) var latestSetupResult: BackendStructuredResult?
    private(set) var latestScanResult: BackendStructuredResult?
    private(set) var latestAdviceResult: BackendStructuredResult?
    private(set) var wineRuntimes: [WineRuntimeRecord] = []
    private(set) var runtimeCatalog: [ManagedRuntime] = []
    private(set) var installedManagedRuntimes: [ManagedRuntime] = []
    private(set) var steamIdentityStatus: SteamIdentityStatus?
    private(set) var discoveredSteamGames: [LibraryGame] = []
    private(set) var epicGames: [LibraryGame] = []
    private(set) var epicSourceStatus: BackendSourceStatus?
    private(set) var epicSetupMessage: String = "Checking Epic setup…"
    private(set) var gogGames: [LibraryGame] = []
    private(set) var gogSourceStatus: BackendSourceStatus?
    private(set) var gogSetupMessage: String = "Checking GOG setup…"
    private(set) var installingDependencyID: String?
    private(set) var installingRuntimeID: String?
    private(set) var backendPreflightState: BackendPreflightState = .unchecked
    private(set) var nativeApps: [LibraryGame] = []
    private(set) var wineApps: [LibraryGame] = []
    private(set) var pinnedGameIDs: [String] = []
    private(set) var steamOrderIDs: [String] = []
    private(set) var hiddenSteamAppIDs: [String] = []
    private(set) var sourceHealth: [RunnerKind: HealthStatus] = [.home: .healthy, .mac: .healthy, .steam: .unknown, .wine: .unknown]
    private(set) var gameSettingsByPinID: [String: StoredGameSettings] = [:]
    private(set) var launchStatusByPinID: [String: GameLaunchStatus] = [:]
    private(set) var launchSessionByPinID: [String: GameLaunchSession] = [:]
    private var launchStateGeneration = 0
    @ObservationIgnored private var launchSessionMonitor: Task<Void, Never>?
    fileprivate var steamMetadataByAppID: [String: SteamLocalMetadata] = [:]
    private var runningHealthChecks = Set<RunnerKind>()
    private var isRefreshingLaunchSessions = false

    var managedBottleNames: [String] {
        let root = appSupportRootURL.appendingPathComponent("bottles", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [backendContext.bottleName].uniquedPreservingOrder()
        }

        let names = contents.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            guard !url.lastPathComponent.hasSuffix("-D3DMetal") else { return nil }
            return url.lastPathComponent
        }

        return ([backendContext.bottleName] + names).uniquedPreservingOrder()
    }

    var allManagedSteamBottleNames: [String] {
        let root = appSupportRootURL.appendingPathComponent("bottles", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.compactMap { url -> String? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            return url.lastPathComponent
        } ?? []
        return ([backendContext.bottleName] + names.sorted()).uniquedPreservingOrder()
    }

    var selectedWineRuntimeID: String? {
        wineRuntimes.first(where: { $0.executablePath == backendContext.winePath })?.id
    }

    var wineRuntimeSummary: String {
        if let runtime = wineRuntimes.first(where: { $0.executablePath == backendContext.winePath }) {
            return runtime.name
        }
        return URL(fileURLWithPath: backendContext.winePath).lastPathComponent
    }

    init() {
        nativeApps = loadStoredItems(forKey: LibraryStorageKey.nativeApps)
        wineApps = loadStoredItems(forKey: LibraryStorageKey.wineApps)
        pinnedGameIDs = UserDefaults.standard.stringArray(forKey: LibraryStorageKey.pinnedIDs) ?? []
        steamOrderIDs = UserDefaults.standard.stringArray(forKey: LibraryStorageKey.steamOrder) ?? []
        hiddenSteamAppIDs = UserDefaults.standard.stringArray(forKey: LibraryStorageKey.hiddenSteamAppIDs) ?? []
        gameSettingsByPinID = loadGameSettings()
        sourceHealth = loadSourceHealth()
        wineRuntimes = loadWineRuntimes()
        migrateLegacyImportedAppIdentity()
        refreshWineRuntimes()
        selectedGame = nil
        if !UserDefaults.standard.bool(forKey: "onboarding.hasSeenSetupWizard") {
            isShowingSetupWizard = true
        }
    }

    var operationCards: [OperationCard] {
        switch selectedRunner ?? .home {
        case .steam:
            var cards = [
                OperationCard(kind: .doctor, title: "Inspect Environment", detail: "Check Wine, DXMT, Steam, and the current bottle when something feels off.", symbolName: "stethoscope"),
                OperationCard(kind: .installDXMT, title: "Install DXMT", detail: "Reinstall DXMT into the current bottle or prefix from the configured DXMT source.", symbolName: "shippingbox.circle"),
                OperationCard(kind: .installD3DMetal, title: "Install D3DMetal", detail: "Install a configured D3DMetal payload into the current bottle or prefix.", symbolName: "sparkle.magnifyingglass"),
                OperationCard(kind: .winecfg, title: "Wine Configuration", detail: "Open winecfg for the current managed bottle or external prefix.", symbolName: "slider.horizontal.3"),
                OperationCard(kind: .winetricks, title: "Winetricks", detail: "Install runtime components like corefonts, vcrun, or dotnet into the current target.", symbolName: "shippingbox"),
                OperationCard(kind: .killWine, title: "Kill All Wine Processes", detail: "Force-stop Wine and game processes across every NASE bottle.", symbolName: "xmark.circle"),
                OperationCard(kind: .openSteam, title: "Open Steam", detail: "Launch Windows Steam without waiting for it to exit.", symbolName: "play.circle"),
                OperationCard(kind: .refreshGames, title: "Refresh Games", detail: "Pull the current Steam manifest list from the Python backend.", symbolName: "arrow.clockwise"),
            ]
            if selectedGame?.runner == .steam {
                cards.append(OperationCard(kind: .launchSelectedGame, title: "Launch Selected", detail: "Launch the selected Steam title through the managed backend.", symbolName: "gamecontroller"))
            }
            return cards
        case .wine:
            return [
                OperationCard(kind: .doctor, title: "Inspect Environment", detail: "Check the current Wine setup and collect a clean summary.", symbolName: "stethoscope"),
                OperationCard(kind: .doctorFix, title: "Repair Environment", detail: "Apply safe DXMT and prefix repairs, then rerun checks.", symbolName: "cross.case"),
                OperationCard(kind: .installDXMT, title: "Install DXMT", detail: "Reinstall DXMT into the current bottle or prefix from the configured DXMT source.", symbolName: "shippingbox.circle"),
                OperationCard(kind: .installD3DMetal, title: "Install D3DMetal", detail: "Install a configured D3DMetal payload into the current bottle or prefix.", symbolName: "sparkle.magnifyingglass"),
                OperationCard(kind: .winecfg, title: "Wine Configuration", detail: "Open winecfg for the current managed bottle or external prefix.", symbolName: "slider.horizontal.3"),
                OperationCard(kind: .winetricks, title: "Winetricks", detail: "Install runtime components like corefonts, vcrun, or dotnet into the current target.", symbolName: "shippingbox"),
                OperationCard(kind: .killWine, title: "Kill All Wine Processes", detail: "Force-stop Wine and game processes across every NASE bottle.", symbolName: "xmark.circle"),
            ]
        case .home, .mac:
            return []
        case .epic, .gog:
            return []
        }
    }

    var filteredGames: [LibraryGame] {
        let source = sourceGames.map(enrichedGame)
        let filteredBySource = source.filter(matchesSourceFilter)
        let filteredByCollection = filteredBySource.filter { game in
            guard let collectionFilter else { return true }
            return settings(for: game).collection == collectionFilter
        }
        let searched = filteredByCollection.filter(matchesSearch)
        return sortGames(searched)
    }

    func games(for runner: RunnerKind) -> [LibraryGame] {
        switch runner {
        case .home:
            return pinnedGames
        case .mac:
            return nativeApps
        case .steam:
            return discoveredSteamGames
        case .wine:
            return wineApps
        case .epic:
            return epicGames
        case .gog:
            return gogGames
        }
    }

    func gameCount(for runner: RunnerKind) -> Int {
        games(for: runner).count
    }

    var bridgeCommands: [BackendCommand] {
        BackendBridge.commands(for: selectedRunner ?? .steam, context: effectiveBackendContext(), selectedGame: selectedGame)
    }

    var libraryEmptyMessage: String {
        switch selectedRunner ?? .home {
        case .home:
            return pinnedGames.isEmpty
                ? "Pin apps from Steam, macOS, or Wine so your favorites show up here."
                : "Pinned apps from every source show up here."
        case .steam:
            if isRefreshingSteamGames {
                return "Refreshing installed Steam games..."
            }
            if !hasAttemptedSteamDetection {
                return "Detecting installed Steam games..."
            }
            return "No installed Steam games were found in the current target. Check the backend settings, then run Refresh Games."
        case .wine:
            return "Add Windows games, folders, or installers with the + button."
        case .mac:
            return "Add native macOS apps with the + button."
        case .epic:
            return epicSourceStatus?.message ?? "Use Epic Setup to install the source client and connect your account."
        case .gog:
            return gogSourceStatus?.message ?? "Use GOG Setup to install the source client and connect your account."
        }
    }

    var settingsSummary: String {
        if let externalPrefix = backendContext.externalPrefix, !externalPrefix.isEmpty {
            return "\(wineRuntimeSummary) • External prefix: \(externalPrefix)"
        }
        return "\(wineRuntimeSummary) • Managed bottle: \(backendContext.bottleName)"
    }

    private var appSupportRootURL: URL {
        NASEDataPaths.migrateLegacyDataIfNeeded()
    }

    var steamLibraryCacheURL: URL? {
        let prefixURL: URL
        if let externalPrefix = backendContext.externalPrefix, !externalPrefix.isEmpty {
            prefixURL = URL(fileURLWithPath: externalPrefix, isDirectory: true)
        } else {
            prefixURL = appSupportRootURL
                .appendingPathComponent("bottles", isDirectory: true)
                .appendingPathComponent(backendContext.bottleName, isDirectory: true)
                .appendingPathComponent("prefix", isDirectory: true)
        }

        return prefixURL
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/appcache/librarycache", isDirectory: true)
    }

    var currentOperationJob: BackendJob? {
        activeBackendJobs.first
    }

    var hasActiveBackendWork: Bool {
        activeBackendJobs.contains { [.queued, .started, .cancelling].contains($0.status) }
    }

    var currentOperationResult: BackendStructuredResult? {
        if let currentOperationJob {
            switch currentOperationJob.action {
            case "Doctor", "Doctor + Fix":
                return latestDoctorResult
            case "Setup Metal":
                return latestSetupResult
            default:
                break
            }
        }

        return latestSetupResult ?? latestDoctorResult ?? latestAdviceResult ?? latestScanResult
    }

    var shouldShowSteamEmptyStateActions: Bool {
        (selectedRunner ?? .home) == .steam && !isRefreshingSteamGames
    }

    var shouldShowAddButton: Bool {
        guard let selectedRunner else { return false }
        return selectedRunner == .mac || selectedRunner == .wine
    }

    var shouldShowWineAddMenu: Bool {
        selectedRunner == .wine
    }

    var editingGame: LibraryGame? {
        guard let editingGamePinID else { return nil }
        return allLibraryGames.first(where: { $0.pinID == editingGamePinID })
    }

    var selectedRunnerActionTitle: String {
        switch selectedRunner ?? .home {
        case .mac:
            return "Add macOS Apps"
        case .wine:
            return "Add Wine Apps"
        default:
            return "Add"
        }
    }

    func launchStatus(for game: LibraryGame) -> GameLaunchStatus? {
        launchStatusByPinID[game.pinID]
    }

    func canStop(_ game: LibraryGame) -> Bool {
        launchSessionByPinID[game.pinID]?.isActive == true
    }

    func clearLaunchStatus(for game: LibraryGame) {
        launchStatusByPinID.removeValue(forKey: game.pinID)
        launchSessionByPinID.removeValue(forKey: game.pinID)
    }

    private func clearWindowsLaunchStateAfterEmergencyStop() {
        launchStateGeneration += 1
        let windowsGameIDs = Set(
            (discoveredSteamGames + wineApps + epicGames + gogGames).map(\.pinID)
        )
        launchStatusByPinID = launchStatusByPinID.filter { pinID, _ in
            !windowsGameIDs.contains(pinID)
        }
        launchSessionByPinID = launchSessionByPinID.filter { pinID, _ in
            !windowsGameIDs.contains(pinID)
        }
    }

    func stop(_ game: LibraryGame) {
        guard let session = launchSessionByPinID[game.pinID], session.isActive else { return }
        setLaunchStatus(.launching, for: game, message: "Stopping...")
        let context = effectiveContext(for: game)
        Task.detached(priority: .userInitiated) {
            do {
                let response = try await BackendBridge.execute(.stopGame(sessionID: session.sessionID), context: context)
                await MainActor.run {
                    self.applyLaunchSessions(response.sessions)
                    self.setLaunchStatus(.exited, for: game, message: response.sessions.first?.message ?? "Stopped by user.")
                    self.rightPanelMessage = "Stopped \(game.title)."
                }
            } catch {
                await MainActor.run {
                    self.setLaunchStatus(.failed, for: game, message: error.localizedDescription)
                    self.rightPanelMessage = "Could not stop \(game.title)."
                }
            }
        }
    }

    private func refreshLaunchSessions() {
        guard !isRefreshingLaunchSessions else { return }
        isRefreshingLaunchSessions = true
        let context = backendContext
        Task.detached(priority: .utility) {
            let response = try? await BackendBridge.execute(.listSessions, context: context)
            await MainActor.run {
                self.isRefreshingLaunchSessions = false
                if let response {
                    self.applyLaunchSessions(response.sessions)
                }
            }
        }
    }

    private func reconcileLaunchStateAfterHandoff(for game: LibraryGame, generation: Int) {
        Task { [weak self] in
            for delay in [1, 2, 3, 5] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard let self, generation == self.launchStateGeneration else { return }
                self.refreshLaunchSessions()
                if self.launchStatusByPinID[game.pinID]?.phase != .launching {
                    return
                }
            }
        }
    }

    private func applyLaunchSessions(_ sessions: [GameLaunchSession]) {
        for game in nativeApps + discoveredSteamGames + wineApps {
            if let session = sessions.last(where: { launchSession($0, belongsTo: game) }) {
                launchSessionByPinID[game.pinID] = session
                let phase: GameLaunchPhase = switch session.status {
                case "running": .running
                case "launching", "stopping": .launching
                case "failed": .failed
                default: .exited
                }
                setLaunchStatus(phase, for: game, message: session.message)
            } else if [.running, .launching].contains(launchStatusByPinID[game.pinID]?.phase) {
                setLaunchStatus(.exited, for: game, message: "Game process exited.")
                launchSessionByPinID.removeValue(forKey: game.pinID)
            }
        }
    }

    private func launchSession(_ session: GameLaunchSession, belongsTo game: LibraryGame) -> Bool {
        if let backendID = game.backendID, !backendID.isEmpty, session.appid == backendID {
            return true
        }
        guard game.runner == .wine,
              let sessionExecutable = session.executable,
              let launchURL = resolvedLaunchURL(for: game)
        else {
            return false
        }
        return URL(fileURLWithPath: sessionExecutable).standardizedFileURL.path
            == launchURL.standardizedFileURL.path
    }

    func selectRunner(_ runner: RunnerKind) {
        selectedRunner = runner
        selectedGame = filteredGames.first

        switch runner {
        case .home:
            rightPanelMessage = "Home keeps your pinned apps from every source in one place."
        case .mac:
            rightPanelMessage = "Add native macOS apps here and launch them from one library."
        case .steam:
            rightPanelMessage = "Steam is ready for setup, launch, and refresh."
            if !hasAttemptedSteamDetection && !isActionRunning(.listGames) {
                refreshSteamGames(announce: false)
            }
        case .wine:
            rightPanelMessage = "Add Windows executables or folders here and launch them through Wine."
        case .epic:
            rightPanelMessage = "Checking Epic Games support…"
            refreshEpicLibrary(forceRefresh: false)
        case .gog:
            rightPanelMessage = "Checking GOG support…"
            refreshGOGLibrary(forceRefresh: false)
        }
    }

    func selectGame(_ game: LibraryGame) {
        selectedGame = game
    }

    func openSettings() {
        isShowingSettings = true
    }

    func openSetupWizard() {
        isShowingSetupWizard = true
    }

    func openEpicSetup() {
        isShowingEpicSetup = true
        refreshEpicSourceStatus()
    }

    func openGOGSetup() {
        isShowingGOGSetup = true
        refreshGOGSourceStatus()
    }

    func refreshGOGSourceStatus() {
        Task {
            do {
                let response = try await BackendBridge.execute(.sourceStatus(source: "gog"), context: backendContext)
                gogSourceStatus = response.sourceStatus
                gogSetupMessage = response.sourceStatus?.message ?? "GOG status is unavailable."
            } catch {
                rightPanelMessage = error.localizedDescription
                gogSetupMessage = error.localizedDescription
            }
        }
    }

    func installGOGClient() {
#if arch(arm64)
        let runtimeID = "gogdl-1.2.2-macos-arm64"
#else
        let runtimeID = "gogdl-1.2.2-macos-x86_64"
#endif
        guard runtimeCatalog.contains(where: { $0.id == runtimeID }) else {
            refreshRuntimeCenter()
            rightPanelMessage = "Loading the GOG client runtime…"
            return
        }
        installingRuntimeID = runtimeID
        executeDetached(.installRuntime(id: runtimeID), successMessage: "GOG client installed. Continue with sign-in.", context: backendContext)
        gogSetupMessage = "Installing and verifying the GOG client…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshRuntimeCenter()
            refreshGOGSourceStatus()
        }
    }

    func authenticateGOG(code: String) {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            gogSetupMessage = "Paste the callback URL from GOG first."
            return
        }
        gogSetupMessage = "Connecting to GOG…"
        Task {
            do {
                let response = try await BackendBridge.executeStreaming(.gogAuthenticate(code: cleaned), context: backendContext) { _ in }
                gogSourceStatus = response.sourceStatus
                gogSetupMessage = "GOG account connected."
                rightPanelMessage = "GOG account connected."
                refreshGOGLibrary(forceRefresh: true)
            } catch {
                appendLog("GOG sign-in failed:\n\(error.localizedDescription)")
                gogSetupMessage = error.localizedDescription
                rightPanelMessage = error.localizedDescription
                refreshGOGSourceStatus()
            }
        }
    }

    func logoutGOG() {
        Task {
            do {
                let response = try await BackendBridge.executeStreaming(.gogLogout, context: backendContext) { _ in }
                gogSourceStatus = response.sourceStatus
                gogGames = []
                gogSetupMessage = "GOG account signed out."
                rightPanelMessage = "GOG account signed out."
            } catch {
                gogSetupMessage = error.localizedDescription
            }
        }
    }

    func refreshEpicSourceStatus() {
        Task {
            do {
                let response = try await BackendBridge.execute(.sourceStatus(source: "epic"), context: backendContext)
                epicSourceStatus = response.sourceStatus
                epicSetupMessage = response.sourceStatus?.message ?? "Epic status is unavailable."
            } catch {
                rightPanelMessage = error.localizedDescription
                epicSetupMessage = error.localizedDescription
            }
        }
    }

    func installLegendary() {
        guard let runtime = runtimeCatalog.first(where: { $0.id == "legendary-python-0.20.34-macos" }) else {
            refreshRuntimeCenter()
            rightPanelMessage = "Loading the Legendary runtime…"
            return
        }
        let action = BackendAction.installRuntime(id: runtime.id)
        installingRuntimeID = runtime.id
        executeDetached(action, successMessage: "Legendary installed. Continue with Epic sign-in.", context: backendContext)
        epicSetupMessage = "Installing and verifying Legendary…"
        Task {
            try? await Task.sleep(for: .seconds(2))
            refreshRuntimeCenter()
            refreshEpicSourceStatus()
        }
    }

    func authenticateEpic(code: String) {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            rightPanelMessage = "Paste the authorization code from Epic first."
            return
        }
        epicSetupMessage = "Connecting to Epic Games…"
        Task {
            do {
                let response = try await BackendBridge.executeStreaming(.epicAuthenticate(code: cleaned), context: backendContext) { _ in }
                epicSourceStatus = response.sourceStatus
                appendLog(response.output)
                rightPanelMessage = "Epic Games account connected."
                epicSetupMessage = "Epic Games account connected."
                refreshEpicLibrary(forceRefresh: true)
            } catch {
                appendLog("Epic sign-in failed:\n\(error.localizedDescription)")
                rightPanelMessage = error.localizedDescription
                epicSetupMessage = error.localizedDescription
                refreshEpicSourceStatus()
            }
        }
    }

    func logoutEpic() {
        Task {
            do {
                let response = try await BackendBridge.executeStreaming(.epicLogout, context: backendContext) { _ in }
                epicSourceStatus = response.sourceStatus
                epicGames = []
                appendLog(response.output)
                rightPanelMessage = "Epic Games account signed out."
                epicSetupMessage = "Epic Games account signed out."
            } catch {
                rightPanelMessage = error.localizedDescription
                epicSetupMessage = error.localizedDescription
            }
        }
    }

    func closeSetupWizard() {
        UserDefaults.standard.set(true, forKey: "onboarding.hasSeenSetupWizard")
        isShowingSetupWizard = false
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusMessage = "Checking for updates…"
        Task {
            do {
                let manifest = try await NASEUpdateService.check()
                await MainActor.run {
                    self.availableUpdate = NASEUpdateService.isNewer(manifest) ? manifest : nil
                    self.updateStatusMessage = self.availableUpdate == nil
                        ? "NASE is up to date."
                        : "NASE \(manifest.version) is available."
                    self.isCheckingForUpdates = false
                }
            } catch {
                await MainActor.run {
                    self.updateStatusMessage = error.localizedDescription
                    self.isCheckingForUpdates = false
                }
            }
        }
    }

    func downloadAvailableUpdate() {
        guard let availableUpdate, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateStatusMessage = "Downloading and verifying NASE \(availableUpdate.version)…"
        Task {
            do {
                let destination = try await NASEUpdateService.downloadAndOpen(availableUpdate)
                await MainActor.run {
                    self.updateStatusMessage = "Verified update opened from \(destination.lastPathComponent)."
                    self.isDownloadingUpdate = false
                }
            } catch {
                await MainActor.run {
                    self.updateStatusMessage = error.localizedDescription
                    self.isDownloadingUpdate = false
                }
            }
        }
    }

    func openWinetricks() {
        isShowingWinetricks = true
    }

    func openWinetricksAfterSettingsDismiss() {
        isShowingSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor in
                self?.isShowingWinetricks = true
            }
        }
    }

    func performAfterSettingsDismiss(_ operation: OperationCard) {
        isShowingSettings = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            Task { @MainActor in
                self?.perform(operation)
            }
        }
    }

    func closeWinetricks() {
        isShowingWinetricks = false
    }

    func selectWineRuntime(id: String) {
        guard let runtime = wineRuntimes.first(where: { $0.id == id }) else { return }
        backendContext = BackendContext(
            repoRoot: backendContext.repoRoot,
            pythonCommand: backendContext.pythonCommand,
            winePath: runtime.executablePath,
            dxmtSource: backendContext.dxmtSource,
            dxvkSource: backendContext.dxvkSource,
            d3dMetalSource: backendContext.d3dMetalSource,
            gptkWinePath: backendContext.gptkWinePath,
            bottleName: backendContext.bottleName,
            externalPrefix: backendContext.externalPrefix
        )
        backendContext.persist()
        rightPanelMessage = "Using \(runtime.name)."
        appendLog("Selected Wine runtime: \(runtime.name)\n\(runtime.executablePath)")
    }

    func refreshWineRuntimes() {
        var byID = Dictionary(uniqueKeysWithValues: wineRuntimes.map { ($0.id, $0) })
        for runtime in scanWineRuntimes() {
            byID[runtime.id] = runtime
        }

        let currentPath = backendContext.winePath
        if !currentPath.isEmpty {
            let fallbackID = "custom:\(currentPath)"
            if byID[fallbackID] == nil, FileManager.default.isExecutableFile(atPath: currentPath) {
                byID[fallbackID] = WineRuntimeRecord(
                    id: fallbackID,
                    name: URL(fileURLWithPath: currentPath).lastPathComponent,
                    executablePath: currentPath,
                    sourceKind: .detected,
                    containerPath: nil,
                    isManaged: false
                )
            }
        }

        wineRuntimes = byID.values.sorted {
            if $0.isManaged != $1.isManaged {
                return $0.isManaged && !$1.isManaged
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persistWineRuntimes()
    }

    func refreshRuntimeCenter() {
        guard backendPreflightState == .ready else { return }
        let context = backendContext
        Task.detached(priority: .userInitiated) {
            do {
                async let catalogResponse = BackendBridge.execute(.listRuntimeCatalog, context: context)
                async let installedResponse = BackendBridge.execute(.listInstalledRuntimes, context: context)
                let (catalog, installed) = try await (catalogResponse, installedResponse)
                await MainActor.run {
                    self.runtimeCatalog = catalog.runtimes
                    self.installedManagedRuntimes = installed.runtimes
                    self.applyManagedRuntimeSourceDefaults()
                }
            } catch {
                await MainActor.run {
                    self.appendLog("Runtime catalog refresh failed:\n\(error.localizedDescription)")
                }
            }
        }
    }

    func refreshDependencyStatus() {
        guard backendPreflightState == .ready else { return }
        let context = effectiveBackendContext()
        Task.detached(priority: .utility) {
            do {
                let response = try await BackendBridge.execute(.dependencyStatus, context: context)
                await MainActor.run {
                    self.latestDependencyResult = response.structured
                }
            } catch {
                await MainActor.run {
                    self.appendLog("Dependency check failed:\n\(error.localizedDescription)")
                }
            }
        }
    }

    func installHostDependency(id: String, confirmLicense: Bool = false) {
        guard installingDependencyID == nil else { return }
        installingDependencyID = id
        executeDetached(
            .installHostDependency(id: id, confirmLicense: confirmLicense),
            successMessage: "Installed \(id).",
            context: effectiveBackendContext()
        )
    }

    func installRecommendedDXMT() {
        guard let runtime = runtimeCatalog.first(where: { $0.id == "dxmt-0.71" }) else {
            rightPanelMessage = "Refresh Runtime Center before installing DXMT."
            refreshRuntimeCenter()
            return
        }
        installManagedRuntime(runtime)
    }

    func startRecommendedBootstrap(confirmRosettaLicense: Bool) {
        guard !isDependencyBootstrapRunning else { return }
        guard backendPreflightState == .ready else {
            dependencyBootstrapPhase = .failed
            dependencyBootstrapMessage = "The NASE backend must pass preflight before setup can begin."
            return
        }
        dependencyBootstrapPhase = .checking
        dependencyBootstrapMessage = "Checking required components..."
        dependencyBootstrapProgress = 0.05
        let initialContext = effectiveBackendContext()

        Task.detached(priority: .userInitiated) {
            do {
                let initial = try await BackendBridge.execute(.dependencyStatus, context: initialContext)
                let checks = initial.structured?.checks ?? []
                let missing = Set(checks.filter { $0.required && $0.status == "fail" }.map(\.name))
                let unsupported = missing.intersection(["macOS", "Python"])
                if !unsupported.isEmpty {
                    throw NSError(
                        domain: "SteamWineApp.DependencyBootstrap",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Update \(unsupported.sorted().joined(separator: " and ")) before continuing."]
                    )
                }
                if missing.contains("Rosetta 2") && !confirmRosettaLicense {
                    throw NSError(
                        domain: "SteamWineApp.DependencyBootstrap",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Rosetta installation requires explicit acceptance of Apple's software license."]
                    )
                }

                var completed = 0
                let workingContext = initialContext
                var managedWinePath: String?
                let installCount = ["Rosetta 2", "GStreamer 1.28.2", "Winetricks", "Wine Stable 11", "DXMT 0.71"]
                    .filter(missing.contains).count
                func report(_ message: String, completedSteps: Int) async {
                    await MainActor.run {
                        self.dependencyBootstrapPhase = .installing
                        self.dependencyBootstrapMessage = message
                        self.dependencyBootstrapProgress = 0.1 + (Double(completedSteps) / Double(max(installCount, 1))) * 0.55
                    }
                }

                if missing.contains("Rosetta 2") {
                    await report("Installing Rosetta 2...", completedSteps: completed)
                    _ = try await BackendBridge.execute(.installHostDependency(id: "rosetta", confirmLicense: true), context: workingContext)
                    completed += 1
                }
                if missing.contains("GStreamer 1.28.2") {
                    await report("Downloading and verifying private GStreamer...", completedSteps: completed)
                    _ = try await BackendBridge.execute(
                        .installHostDependency(id: "gstreamer", confirmLicense: false),
                        context: workingContext
                    )
                    completed += 1
                }
                if missing.contains("Winetricks") {
                    await report("Installing Winetricks...", completedSteps: completed)
                    _ = try await BackendBridge.execute(.installHostDependency(id: "winetricks", confirmLicense: false), context: workingContext)
                    completed += 1
                }
                if missing.contains("Wine Stable 11") {
                    await report("Downloading and verifying managed Wine Stable 11...", completedSteps: completed)
                    let response = try await BackendBridge.execute(
                        .installHostDependency(id: "wine-stable", confirmLicense: false),
                        context: workingContext
                    )
                    managedWinePath = response.runtimes.first(where: { $0.id == "wine-stable-11.0_1-gcenx" })?.executable
                    completed += 1
                }

                let detectedWinePath = await MainActor.run { self.detectInstalledWineStablePath() }
                let winePath = managedWinePath ?? detectedWinePath
                guard let winePath else {
                    throw NSError(
                        domain: "SteamWineApp.DependencyBootstrap",
                        code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Wine Stable was not found after installation. Choose an existing Wine Stable app in Settings."]
                    )
                }
                let installedHostContext = workingContext
                var configuredContext = await MainActor.run {
                    self.contextAdoptingWineStable(winePath, baseContext: installedHostContext)
                }

                if missing.contains("DXMT 0.71") {
                    await report("Downloading and verifying DXMT 0.71...", completedSteps: completed)
                    let installed = try await BackendBridge.executeStreaming(
                        .installRuntime(id: "dxmt-0.71"),
                        context: configuredContext
                    ) { update in
                        if let message = update.job?.message {
                            await MainActor.run {
                                self.dependencyBootstrapPhase = .installing
                                self.dependencyBootstrapMessage = message
                            }
                        }
                    }
                    if let source = installed.runtimes.first(where: { $0.id == "dxmt-0.71" })?.path {
                        configuredContext = configuredContext.overridingRuntimeSources(dxmtSource: source)
                    }
                    completed += 1
                }

                let adoptedContext = configuredContext
                await MainActor.run {
                    self.dependencyBootstrapPhase = .configuring
                    self.dependencyBootstrapMessage = "Saving verified runtime selections..."
                    self.dependencyBootstrapProgress = 0.72
                    self.backendContext = adoptedContext
                    self.backendContext.persist()
                    self.refreshWineRuntimes()
                }

                let verified = try await BackendBridge.execute(.dependencyStatus, context: configuredContext)
                let remaining = verified.structured?.checks.filter { $0.required && $0.status == "fail" } ?? []
                guard remaining.isEmpty else {
                    throw NSError(
                        domain: "SteamWineApp.DependencyBootstrap",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "Still missing: \(remaining.map(\.name).joined(separator: ", "))."]
                    )
                }

                await MainActor.run {
                    self.latestDependencyResult = verified.structured
                    self.dependencyBootstrapPhase = .profileSetup
                    self.dependencyBootstrapMessage = "Preparing the dedicated DXMT bottle and Steam..."
                    self.dependencyBootstrapProgress = 0.8
                }
                let profileContext = configuredContext.compatibilityContext(for: .dxmt)
                _ = try await BackendBridge.executeStreaming(.setupCompatibilityProfile(.dxmt), context: profileContext) { update in
                    if let message = update.job?.message {
                        await MainActor.run { self.dependencyBootstrapMessage = message }
                    }
                }
                _ = try await BackendBridge.execute(.openSteam, context: profileContext)

                await MainActor.run {
                    self.dependencyBootstrapPhase = .ready
                    self.dependencyBootstrapMessage = "Recommended DXMT environment is ready. Steam is opening for sign-in."
                    self.dependencyBootstrapProgress = 1
                    UserDefaults.standard.set(true, forKey: LibraryStorageKey.didCompleteInitialSetup)
                    self.refreshRuntimeCenter()
                    self.refreshDependencyStatus()
                    self.rightPanelMessage = "Recommended gaming environment is ready."
                }
            } catch {
                await MainActor.run {
                    self.dependencyBootstrapPhase = .failed
                    self.dependencyBootstrapMessage = error.localizedDescription
                    self.appendLog("Recommended environment setup failed:\n\(error.localizedDescription)")
                    self.rightPanelMessage = "Recommended environment setup needs attention."
                }
            }
        }
    }

    var isDependencyBootstrapRunning: Bool {
        [.checking, .installing, .configuring, .profileSetup].contains(dependencyBootstrapPhase)
    }

    private func detectInstalledWineStablePath() -> String? {
        let candidates = [
            "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            "/opt/homebrew/bin/wine",
            "/usr/local/bin/wine",
            backendContext.winePath,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func detectInstalledPythonPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            backendContext.pythonCommand,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func contextAdoptingWineStable(_ winePath: String, baseContext: BackendContext) -> BackendContext {
        let managedDXMT = appSupportRootURL
            .appendingPathComponent("runtimes/dxmt/dxmt-0.71", isDirectory: true)
        let detectedDXMT = FileManager.default.fileExists(atPath: managedDXMT.path) ? managedDXMT.path : nil
        return BackendContext(
            repoRoot: baseContext.repoRoot,
            pythonCommand: baseContext.pythonCommand,
            winePath: winePath,
            dxmtSource: managedRuntimeSource(kind: "dxmt") ?? detectedDXMT ?? baseContext.dxmtSource,
            dxvkSource: baseContext.dxvkSource,
            d3dMetalSource: baseContext.d3dMetalSource,
            gptkWinePath: baseContext.gptkWinePath,
            bottleName: baseContext.bottleName,
            externalPrefix: nil
        )
    }

    func openRecommendedBootstrapLogs() {
        let context = backendContext.compatibilityContext(for: .dxmt)
        let logsURL = logsDirectoryURL(for: .steam, context: context)
        let names = ["01_profile_wineboot.log", "02_profile_steam.log", "dxmt_install.log", "03_run_steam.log"]
        let entries = names.compactMap { name -> DisplayedLogEntry? in
            let url = logsURL.appendingPathComponent(name)
            guard
                FileManager.default.fileExists(atPath: url.path),
                let text = Self.readTailText(from: url, maxBytes: MemoryLimit.displayedLogBytes)
            else { return nil }
            return DisplayedLogEntry(id: name, title: name, text: text)
        }
        selectedLogTitle = "Recommended Environment Logs"
        selectedLogEntries = entries
        selectedLogEntryID = entries.first?.id
        selectedLogText = entries.first?.text ?? activityLog
        isShowingLogViewer = true
    }

    func installManagedRuntime(_ runtime: ManagedRuntime) {
        let action = BackendAction.installRuntime(id: runtime.id)
        guard !isActionRunning(action) else { return }
        installingRuntimeID = runtime.id
        appendLog("== Install Runtime ==\n\(BackendBridge.preview(action, context: backendContext))")
        rightPanelMessage = "Installing \(runtime.displayName)..."
        let activeJobID = beginBackendJob(for: action, message: "Installing \(runtime.displayName)...")
        let context = backendContext

        Task.detached(priority: .userInitiated) {
            do {
                let response = try await BackendBridge.executeStreaming(action, context: context) { update in
                    await MainActor.run {
                        self.applyStreamUpdate(update, fallbackActiveJobID: activeJobID, action: action)
                    }
                }
                await MainActor.run {
                    if let responseJob = response.job {
                        self.reconcileDetachedJob(responseJob, fallbackActiveJobID: activeJobID, action: action)
                    } else {
                        let fallbackJob = self.makeFallbackJob(for: action, status: .completed, message: "Installed \(runtime.displayName).")
                        self.completeBackendJob(activeJobID, finalJob: fallbackJob)
                    }
                    self.appendLog(response.output)
                    self.rightPanelMessage = "Installed \(runtime.displayName)."
                    self.installingRuntimeID = nil
                    self.refreshRuntimeCenter()
                    self.refreshWineRuntimes()
                    self.refreshDependencyStatus()
                }
            } catch {
                await MainActor.run {
                    let message = error.localizedDescription
                    let fallbackJob = self.makeFallbackJob(for: action, status: .failed, message: message)
                    self.completeBackendJob(activeJobID, finalJob: fallbackJob)
                    self.appendLog("Runtime install failed:\n\(message)")
                    self.rightPanelMessage = "Runtime install failed."
                    self.installingRuntimeID = nil
                }
            }
        }
    }

    func importWineAppRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Wine App"
        panel.message = "Choose a Wine app to copy into the launcher's managed runtimes folder."

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        do {
            let runtimesRoot = managedWineRuntimesRoot()
            try FileManager.default.createDirectory(at: runtimesRoot, withIntermediateDirectories: true, attributes: nil)
            let targetURL = uniqueManagedRuntimeDestination(for: sourceURL)
            try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            guard let executablePath = detectWineExecutable(in: targetURL) else {
                throw NSError(domain: "SteamWineApp.WineRuntime", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not locate a Wine executable inside \(targetURL.lastPathComponent)."])
            }

            let runtime = WineRuntimeRecord(
                id: "managed:\(targetURL.path)",
                name: targetURL.deletingPathExtension().lastPathComponent,
                executablePath: executablePath,
                sourceKind: .importedApp,
                containerPath: targetURL.path,
                isManaged: true
            )
            wineRuntimes.removeAll { $0.id == runtime.id }
            wineRuntimes.append(runtime)
            persistWineRuntimes()
            selectWineRuntime(id: runtime.id)
            refreshWineRuntimes()
        } catch {
            rightPanelMessage = "Could not import Wine app."
            appendLog("Wine runtime import failed:\n\(error.localizedDescription)")
        }
    }

    func importWineBinaryRuntime() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Wine Binary"
        panel.message = "Choose a Wine executable to register with the launcher."

        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: sourceURL.path) else {
            rightPanelMessage = "That file is not executable."
            return
        }

        let runtime = WineRuntimeRecord(
            id: "binary:\(sourceURL.path)",
            name: sourceURL.deletingPathExtension().lastPathComponent,
            executablePath: sourceURL.path,
            sourceKind: .importedBinary,
            containerPath: nil,
            isManaged: false
        )
        wineRuntimes.removeAll { $0.id == runtime.id }
        wineRuntimes.append(runtime)
        persistWineRuntimes()
        selectWineRuntime(id: runtime.id)
        refreshWineRuntimes()
    }

    func revealManagedWineRuntimes() {
        let root = managedWineRuntimesRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func detectedWinePathStatus(_ path: String) -> String {
        validateWinePath(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func detectedWinetricksPath() -> String? {
        let fileManager = FileManager.default
        let commonPaths = [
            appSupportRootURL.appendingPathComponent("runtimes/tool/winetricks-20260125/bin/winetricks").path,
            "/opt/homebrew/bin/winetricks",
            "/usr/local/bin/winetricks",
            "/opt/local/bin/winetricks",
        ]
        if let found = commonPaths.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return found
        }

        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry).appendingPathComponent("winetricks").path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    func detectedWinetricksStatus() -> String {
        if let path = detectedWinetricksPath() {
            return "OK: Winetricks found at \(path)"
        }
        return "FAIL: Winetricks was not found on this Mac"
    }

    func setupWizardCanRun(winePath: String, dxmtSource: String, bottleName: String) -> Bool {
        let cleanedBottle = bottleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return backendPreflightState == .ready
            && !cleanedBottle.isEmpty
            && !isDependencyBootstrapRunning
    }

    func validateDXMTSourceForWizard(_ path: String) -> [String] {
        validateDXMTSource(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func validateDXVKSourceForWizard(_ path: String) -> [String] {
        validateDXVKSource(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func validateD3DMetalSourceForWizard(_ path: String) -> [String] {
        validateD3DMetalSource(path.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func runSetupWizard(winePath: String, dxmtSource: String, dxvkSource: String, bottleName: String) {
        // Recommended setup owns its runtime selections. Do not persist the
        // wizard's clean-machine placeholder paths before the managed runtime
        // downloader has had a chance to replace them.
        backendContext = backendContext.overridingTarget(
            bottleName: bottleName,
            externalPrefix: nil
        )
        backendContext.persist()
        selectedRunner = .steam
        startRecommendedBootstrap(confirmRosettaLicense: true)
    }

    func installDXVKFromWizard(winePath: String, dxmtSource: String, dxvkSource: String, bottleName: String) {
        applySettings(
            winePath: winePath,
            dxmtSource: dxmtSource,
            dxvkSource: dxvkSource,
            bottleName: bottleName,
            externalPrefix: nil,
            useExternalPrefix: false
        )
        executeDetached(
            .installDXVK,
            successMessage: "Installed DXVK.",
            context: effectiveBackendContext()
        )
    }

    func detectedWinetricksComponents() -> [WinetricksComponentStatus] {
        guard let prefixURL = currentPrefixURL(for: backendContext) else {
            return [
                WinetricksComponentStatus(id: "prefix", title: "Prefix", state: .unavailable, detail: "Current bottle/prefix could not be resolved.")
            ]
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: prefixURL.path) else {
            return [
                WinetricksComponentStatus(id: "prefix", title: "Prefix", state: .unavailable, detail: "Prefix does not exist yet.")
            ]
        }

        let system32 = prefixURL.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        let syswow64 = prefixURL.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        let fonts = prefixURL.appendingPathComponent("drive_c/windows/Fonts", isDirectory: true)
        let registryText = [prefixURL.appendingPathComponent("system.reg"), prefixURL.appendingPathComponent("user.reg")]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        func exists(_ base: URL, _ name: String) -> Bool {
            fileManager.fileExists(atPath: base.appendingPathComponent(name).path)
        }

        func status(id: String, title: String, installed: Bool, detail: String) -> WinetricksComponentStatus {
            WinetricksComponentStatus(
                id: id,
                title: title,
                state: installed ? .installed : .missing,
                detail: detail
            )
        }

        let coreFontsInstalled =
            ["arial.ttf", "times.ttf", "cour.ttf", "verdana.ttf", "trebuc.ttf"]
            .contains { exists(fonts, $0) }
        let vcrun2019Installed =
            exists(system32, "vcruntime140.dll")
            || exists(system32, "msvcp140.dll")
            || exists(syswow64, "vcruntime140.dll")
            || registryText.localizedCaseInsensitiveContains("Visual C++")
        let d3dcompilerInstalled =
            exists(system32, "d3dcompiler_47.dll")
            || exists(syswow64, "d3dcompiler_47.dll")
        let dotnet48Installed =
            registryText.localizedCaseInsensitiveContains("NDP\\v4\\Full")
            || registryText.localizedCaseInsensitiveContains("dotnet")
        let xactInstalled =
            exists(system32, "xaudio2_7.dll")
            || exists(system32, "x3daudio1_7.dll")
            || exists(syswow64, "xaudio2_7.dll")
        let directPlayInstalled =
            exists(system32, "dplayx.dll")
            || exists(syswow64, "dplayx.dll")
            || registryText.localizedCaseInsensitiveContains("DirectPlay")

        return [
            status(id: "corefonts", title: "Core Fonts", installed: coreFontsInstalled, detail: coreFontsInstalled ? "Common Microsoft font files found." : "No common core font files detected."),
            status(id: "vcrun2019", title: "VC++ 2019", installed: vcrun2019Installed, detail: vcrun2019Installed ? "Visual C++ runtime files or registry entries found." : "VC++ runtime files were not found."),
            status(id: "d3dcompiler_47", title: "D3D Compiler 47", installed: d3dcompilerInstalled, detail: d3dcompilerInstalled ? "d3dcompiler_47.dll found in the prefix." : "d3dcompiler_47.dll not found in the prefix."),
            status(id: "dotnet48", title: ".NET 4.8", installed: dotnet48Installed, detail: dotnet48Installed ? ".NET registry markers found." : "No .NET 4.x registry markers were found."),
            status(id: "xact", title: "XACT", installed: xactInstalled, detail: xactInstalled ? "XAudio/X3DAudio files found." : "XACT audio runtime files were not found."),
            status(id: "directplay", title: "DirectPlay", installed: directPlayInstalled, detail: directPlayInstalled ? "DirectPlay DLL or registry markers found." : "DirectPlay was not detected."),
        ]
    }

    func performPrimaryAddAction() {
        switch selectedRunner ?? .home {
        case .mac:
            importMacApps()
        case .wine:
            importWineTargets()
        default:
            break
        }
    }

    func openWineInstaller() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe"),
            UTType(filenameExtension: "msi"),
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Installer"
        panel.message = "Choose a Windows installer to open with Wine."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let installerGame = LibraryGame(
            pinID: LibraryGame.importedPinID(runner: .wine, url: url),
            title: url.deletingPathExtension().lastPathComponent,
            runner: .wine,
            capsule: "Wine",
            status: "Installer",
            statsText: directorySizeText(url),
            installURL: url,
            launchURL: url
        )

        wineApps = mergeLibraryGames(existing: wineApps, incoming: [installerGame])
        persistStoredItems(wineApps, forKey: LibraryStorageKey.wineApps)
        selectedGame = installerGame

        executeDetached(
            .debugExecutable(
                path: url.path,
                graphicsBackend: .none,
                wineDebug: "-all",
                standalone: true
            ),
            successMessage: "Opened installer \(url.lastPathComponent).",
            context: backendContext,
            game: installerGame
        )

        let alert = NSAlert()
        alert.messageText = "Installer opened"
        alert.informativeText = "When the installer finishes, you can add the resulting app or game to the Wine library now or later."
        alert.addButton(withTitle: "Add Installed App")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            importWineTargets()
        }
    }

    func refreshGames() {
        refreshSteamGames(announce: true)
    }

    func runDoctor() {
        perform(
            OperationCard(
                kind: .doctor,
                title: "Inspect Environment",
                detail: "Check Wine, DXMT, Steam, and the current bottle.",
                symbolName: "stethoscope"
            )
        )
    }

    func togglePin(for game: LibraryGame) {
        if let index = pinnedGameIDs.firstIndex(of: game.pinID) {
            pinnedGameIDs.remove(at: index)
        } else {
            pinnedGameIDs.append(game.pinID)
        }
        persistPinnedIDs()
    }

    func isPinned(_ game: LibraryGame) -> Bool {
        pinnedGameIDs.contains(game.pinID)
    }

    func removeGameFromLibrary(_ game: LibraryGame) {
        let alert = NSAlert()
        alert.messageText = game.runner == .steam ? "Hide this Steam game from the launcher?" : "Remove this item from the library?"
        alert.informativeText = game.runner == .steam
            ? "This only hides the game from the launcher. It does not uninstall it from Steam."
            : "This only removes the saved launcher entry or path. It does not delete files from disk."
        alert.addButton(withTitle: game.runner == .steam ? "Hide Game" : "Remove Entry")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        pinnedGameIDs.removeAll { $0 == game.pinID }
        persistPinnedIDs()
        gameSettingsByPinID.removeValue(forKey: game.pinID)
        persistGameSettings()

        switch game.runner {
        case .mac:
            nativeApps.removeAll { $0.pinID == game.pinID }
            persistStoredItems(nativeApps, forKey: LibraryStorageKey.nativeApps)
        case .wine:
            wineApps.removeAll { $0.pinID == game.pinID }
            persistStoredItems(wineApps, forKey: LibraryStorageKey.wineApps)
        case .steam:
            if let appid = game.backendID, !appid.isEmpty {
                hiddenSteamAppIDs.append(appid)
                hiddenSteamAppIDs = hiddenSteamAppIDs.uniquedPreservingOrder()
                UserDefaults.standard.set(hiddenSteamAppIDs, forKey: LibraryStorageKey.hiddenSteamAppIDs)
            }
            discoveredSteamGames.removeAll { $0.pinID == game.pinID }
            steamOrderIDs.removeAll { $0 == game.pinID }
            persistSteamOrder()
        case .home:
            if let sourceGame = underlyingGame(for: game) {
                removeGameFromLibrary(sourceGame)
                return
            }
        case .epic, .gog:
            break
        }

        if editingGamePinID == game.pinID {
            closeGameDetails()
            closeGameSettings()
            closeLogViewer()
            editingGamePinID = nil
        }

        selectedGame = filteredGames.first
        rightPanelMessage = game.runner == .steam ? "Game hidden from launcher." : "Entry removed from library."
    }

    func moveGame(_ dragged: LibraryGame, before target: LibraryGame) {
        guard dragged.pinID != target.pinID else { return }

        switch selectedRunner ?? .home {
        case .home:
            reorderIDs(&pinnedGameIDs, draggedID: dragged.pinID, targetID: target.pinID)
            persistPinnedIDs()
        case .mac:
            reorderGames(&nativeApps, draggedID: dragged.pinID, targetID: target.pinID)
            persistStoredItems(nativeApps, forKey: LibraryStorageKey.nativeApps)
        case .wine:
            reorderGames(&wineApps, draggedID: dragged.pinID, targetID: target.pinID)
            persistStoredItems(wineApps, forKey: LibraryStorageKey.wineApps)
        case .steam:
            reorderGames(&discoveredSteamGames, draggedID: dragged.pinID, targetID: target.pinID)
            steamOrderIDs = discoveredSteamGames.map(\.pinID)
            persistSteamOrder()
        case .epic, .gog:
            break
        }

        selectedGame = sourceGames.first(where: { $0.pinID == dragged.pinID }) ?? selectedGame
    }

    func openSteamStorePage(for game: LibraryGame) {
        guard let storeURL = game.storeURL else { return }
        NSWorkspace.shared.open(storeURL)
    }

    func revealLocalFiles(for game: LibraryGame) {
        guard let url = game.installURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openGameSettings(for game: LibraryGame) {
        selectedGame = game
        editingGamePinID = game.pinID
        isShowingGameSettings = true
    }

    func closeGameSettings() {
        isShowingGameSettings = false
    }

    func openGameDetails(for game: LibraryGame) {
        selectedGame = game
        editingGamePinID = game.pinID
        isShowingGameDetails = true
    }

    func closeGameDetails() {
        isShowingGameDetails = false
    }

    func closeLogViewer() {
        isShowingLogViewer = false
    }

    func openGameSettingsFromDetails(for game: LibraryGame) {
        closeGameDetails()
        Task { @MainActor in
            openGameSettings(for: game)
        }
    }

    func changeAppIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image, UTType(filenameExtension: "icns")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else {
            return
        }
        NSApplication.shared.applicationIconImage = image
    }

    func launch(_ game: LibraryGame) {
        selectGame(game)

        if let profile = requiredCompatibilityProfile(for: game),
           ensureCompatibilityProfile(profile, beforeLaunching: game) {
            return
        }

        switch game.runner {
        case .steam:
            launchSteamGame(game)
        case .mac:
            guard let url = game.launchURL else {
                rightPanelMessage = "No launch target is set for \(game.title)."
                setLaunchStatus(.failed, for: game, message: "No launch target is set.")
                return
            }
            setLaunchStatus(.launching, for: game, message: "Opening macOS app...")
            let opened = NSWorkspace.shared.open(url)
            if opened {
                setLaunchStatus(.running, for: game, message: "Opened by macOS.")
                rightPanelMessage = "Opened \(game.title)."
            } else {
                setLaunchStatus(.failed, for: game, message: "macOS could not open this app.")
                rightPanelMessage = "Could not open \(game.title)."
            }
            appendLog("== Launch ==\nmacOS app\n\(url.path)")
        case .wine:
            launchWineGame(game)
        case .home:
            if let sourceGame = underlyingGame(for: game) {
                launch(sourceGame)
            }
        case .epic:
            guard let gameID = game.backendID else { return }
            if game.installURL == nil {
                executeDetached(
                    .sourceGameAction(source: "epic", gameID: gameID, operation: "install"),
                    successMessage: "Installed \(game.title). Refresh Epic when the download completes.",
                    context: backendContext,
                    game: game
                )
            } else {
                let graphics = settings(for: game).graphicsBackend
                let context = effectiveBackendContext(backendContext.compatibilityContext(for: graphics))
                executeDetached(
                    .launchSourceGame(source: "epic", gameID: gameID, graphicsBackend: graphics),
                    successMessage: "Launched \(game.title).",
                    context: context,
                    game: game
                )
            }
        case .gog:
            guard let gameID = game.backendID else { return }
            if game.installURL == nil {
                executeDetached(.sourceGameAction(source: "gog", gameID: gameID, operation: "install"),
                                successMessage: "Installed \(game.title).", context: backendContext, game: game)
            } else {
                let graphics = settings(for: game).graphicsBackend
                let context = effectiveBackendContext(backendContext.compatibilityContext(for: graphics))
                executeDetached(.launchSourceGame(source: "gog", gameID: gameID, graphicsBackend: graphics),
                                successMessage: "Launched \(game.title).", context: context, game: game)
            }
        }
    }

    func updateEpicGame(_ game: LibraryGame) {
        runEpicMaintenance(game, operation: "update")
    }

    func verifyEpicGame(_ game: LibraryGame) {
        runEpicMaintenance(game, operation: "verify")
    }

    func repairEpicGame(_ game: LibraryGame) {
        runEpicMaintenance(game, operation: "repair")
    }

    func uninstallEpicGame(_ game: LibraryGame) {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(game.title)?"
        alert.informativeText = "This deletes the Epic game files. The game remains in your owned library and can be installed again."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runEpicMaintenance(game, operation: "uninstall", confirm: true)
    }

    private func runEpicMaintenance(_ game: LibraryGame, operation: String, confirm: Bool = false) {
        guard game.runner == .epic, let gameID = game.backendID else { return }
        executeDetached(
            .sourceGameAction(source: "epic", gameID: gameID, operation: operation, confirm: confirm),
            successMessage: "Epic \(operation) completed for \(game.title).",
            context: backendContext,
            game: game
        )
    }

    func updateGOGGame(_ game: LibraryGame) { runGOGMaintenance(game, operation: "update") }
    func verifyGOGGame(_ game: LibraryGame) { runGOGMaintenance(game, operation: "verify") }
    func repairGOGGame(_ game: LibraryGame) { runGOGMaintenance(game, operation: "repair") }

    func uninstallGOGGame(_ game: LibraryGame) {
        let alert = NSAlert()
        alert.messageText = "Uninstall \(game.title)?"
        alert.informativeText = "This deletes the GOG game files. The game remains in your account."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runGOGMaintenance(game, operation: "uninstall", confirm: true)
    }

    private func runGOGMaintenance(_ game: LibraryGame, operation: String, confirm: Bool = false) {
        guard game.runner == .gog, let gameID = game.backendID else { return }
        executeDetached(.sourceGameAction(source: "gog", gameID: gameID, operation: operation, confirm: confirm),
                        successMessage: "GOG \(operation) completed for \(game.title).", context: backendContext, game: game)
    }

    func debugLaunch(_ game: LibraryGame) {
        selectGame(game)
        let settings = settings(for: game)
        let args = parseLaunchArguments(settings.launchArguments)
        let env = parseEnvironmentOverrides(settings.environmentText)
        let cwd = normalizedOptionalPath(settings.workingDirectoryPath)
        let context = effectiveContext(for: game)

        switch game.runner {
        case .steam:
            guard let appid = game.backendID, !appid.isEmpty else { return }
            executeDetached(
                .debugGame(
                    appid: appid,
                    gameArgs: args,
                    graphicsBackend: settings.graphicsBackend,
                    workingDirectory: cwd,
                    environment: env
                ),
                successMessage: "Debug launch started for \(game.title).",
                context: context,
                game: game
            )
        case .wine:
            guard let executable = resolvedLaunchURL(for: game) else {
                rightPanelMessage = "Set a launch executable for \(game.title) first."
                setLaunchStatus(.failed, for: game, message: "No launch executable is set.")
                editingGamePinID = game.pinID
                isShowingGameSettings = true
                return
            }
            executeDetached(
                .debugExecutable(
                    path: executable.path,
                    gameArgs: args,
                    graphicsBackend: settings.graphicsBackend,
                    workingDirectory: cwd,
                    environment: env,
                    standalone: true
                ),
                successMessage: "Debug launch started for \(game.title).",
                context: context,
                game: game
            )
        case .mac, .home, .epic, .gog:
            break
        }
    }

    func revealLogs(for runner: RunnerKind? = nil) {
        let logsURL = logsDirectoryURL(for: runner ?? selectedRunner ?? .steam, context: backendContext)
        NSWorkspace.shared.activateFileViewerSelecting([logsURL])
    }

    func openLogViewer(for game: LibraryGame? = nil) {
        let targetGame = game ?? selectedGame
        editingGamePinID = targetGame?.pinID
        let context = targetGame.map(effectiveContext(for:)) ?? backendContext
        let logsURL = logsDirectoryURL(for: targetGame?.runner ?? selectedRunner ?? .steam, context: context)
        let logFiles = ["04_debug_game.log", "03_run_steam.log", "02_install_steam.log", "01_wineboot.log"]
            .map { logsURL.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        let entries = logFiles.compactMap { url -> DisplayedLogEntry? in
            guard let text = Self.readTailText(from: url, maxBytes: MemoryLimit.displayedLogBytes) else { return nil }
            return DisplayedLogEntry(id: url.lastPathComponent, title: url.lastPathComponent, text: text)
        }

        selectedLogTitle = targetGame.map { "\($0.title) Logs" } ?? "Logs"
        selectedLogEntries = entries
        selectedLogEntryID = entries.first?.id
        selectedLogText = entries.first?.text ?? "No logs found yet."
        isShowingLogViewer = true
    }

    func refreshLogViewer() {
        if let game = editingGame {
            openLogViewer(for: game)
        } else {
            openLogViewer()
        }
    }

    func perform(_ operation: OperationCard) {
        let action: BackendAction
        switch operation.kind {
        case .setupMetal:
            action = .setupMetal
        case .doctor:
            action = .doctor
        case .doctorFix:
            action = .doctorFix
        case .installDXMT:
            action = .installDXMT
        case .installD3DMetal:
            action = .installD3DMetal
        case .winetricks:
            openWinetricks()
            return
        case .winecfg:
            executeDetached(
                .openWinecfg,
                successMessage: "Opened winecfg.",
                context: effectiveBackendContext()
            )
            return
        case .killWine:
            executeDetached(
                .killWine,
                successMessage: "Stopped Wine processes.",
                context: effectiveBackendContext()
            )
            return
        case .openSteam:
            openDefaultSteam()
            return
        case .refreshGames:
            refreshSteamGames(announce: true)
            return
        case .launchSelectedGame:
            guard let selectedGame, selectedGame.backendID?.isEmpty == false else {
                rightPanelMessage = "Select a Steam game first."
                return
            }
            launch(selectedGame)
            return
        }

        guard !isActionRunning(action) else { return }

        let context: BackendContext = switch action {
        case .installD3DMetal:
            effectiveBackendContext(backendContext.compatibilityContext(for: .d3dmetal))
        default:
            effectiveBackendContext()
        }

        rightPanelMessage = "Running \(operation.title)..."
        appendLog("== \(operation.title) ==\n\(BackendBridge.preview(action, context: context))")
        let activeJobID = beginBackendJob(for: action, message: "Running \(operation.title)...")
        Task.detached(priority: .userInitiated) {
            do {
                let response = try await BackendBridge.executeStreaming(action, context: context) { update in
                    await MainActor.run {
                        self.applyStreamUpdate(update, fallbackActiveJobID: activeJobID, action: action)
                    }
                }
                await MainActor.run {
                    if let responseJob = response.job {
                        self.reconcileDetachedJob(responseJob, fallbackActiveJobID: activeJobID, action: action)
                    } else {
                        let fallbackJob = self.makeFallbackJob(for: action, status: .completed, message: self.jobSuccessMessage(for: action))
                        self.completeBackendJob(activeJobID, finalJob: fallbackJob)
                    }
                    self.recordStructuredResult(response.structured, for: action)
                    switch action {
                    case .listGames:
                        self.discoveredSteamGames = self.mappedSteamGames(from: response.games)
                        if self.selectedRunner == .steam, let first = self.filteredGames.first {
                            self.selectedGame = first
                        }
                    case .doctor, .doctorFix:
                        if let structured = response.structured {
                            self.updateHealth(for: self.selectedRunner ?? .steam, from: structured)
                        } else {
                            self.updateHealth(for: self.selectedRunner ?? .steam, from: response.output)
                        }
                    default:
                        break
                    }
                    self.appendLog(response.output)
                    self.rightPanelMessage = response.job?.message ?? "\(operation.title) finished."
                }
            } catch {
                await MainActor.run {
                    if self.activeBackendJobs.contains(where: { $0.id == activeJobID }) {
                        let failedJob = self.makeFallbackJob(for: action, status: .failed, message: "\(operation.title) failed.")
                        self.completeBackendJob(activeJobID, finalJob: failedJob)
                    }
                    self.appendLog("Command failed:\n\(error.localizedDescription)")
                    self.rightPanelMessage = "\(operation.title) failed."
                }
            }
        }
    }

    func stopAllWineProcesses() {
        perform(OperationCard(
            kind: .killWine,
            title: "Stop All Wine Processes",
            detail: "Force-stop Wine and game processes across every NASE bottle.",
            symbolName: "stop.circle"
        ))
    }

    var canUninstallApplication: Bool {
        NASEUninstallPlan.make().applicationURL != nil
    }

    var uninstallApplicationPath: String {
        NASEUninstallPlan.make().applicationURL?.path
            ?? "This development build cannot move itself to the Trash."
    }

    func uninstallNASE(removeManagedData: Bool) {
        guard !isUninstallingNASE else { return }
        let plan = NASEUninstallPlan.make()
        guard let applicationURL = plan.applicationURL else {
            uninstallStatusMessage = "Build and open NASE.app before testing self-uninstall."
            return
        }
        isUninstallingNASE = true
        uninstallStatusMessage = "Stopping NASE-managed Wine processes…"
        let context = backendContext

        Task {
            do {
                _ = try await BackendBridge.execute(.killWine, context: context)
                launchSessionMonitor?.cancel()
                launchSessionMonitor = nil
                launchStateGeneration += 1
                uninstallStatusMessage = removeManagedData
                    ? "Removing NASE-managed data and settings…"
                    : "Removing NASE settings and caches…"
                try await Task.detached(priority: .utility) {
                    try NASEUninstallService.eraseOwnedData(
                        plan: plan,
                        removeManagedData: removeManagedData
                    )
                }.value
                uninstallStatusMessage = "Moving NASE.app to the Trash…"
                try await NASEUninstallService.moveApplicationToTrash(applicationURL)
                NSApplication.shared.terminate(nil)
            } catch {
                isUninstallingNASE = false
                uninstallStatusMessage = error.localizedDescription
            }
        }
    }

    func setupCompatibilityProfile(_ profile: GraphicsBackendOption) {
        let context = effectiveBackendContext(backendContext.compatibilityContext(for: profile))
        executeDetached(
            .setupCompatibilityProfile(profile),
            successMessage: "\(profile.rawValue) profile is ready.",
            context: context
        )
    }

    func repairCompatibilityProfile(_ profile: GraphicsBackendOption) {
        let context = effectiveBackendContext(backendContext.compatibilityContext(for: profile))
        executeDetached(
            .repairCompatibilityProfile(profile),
            successMessage: "\(profile.rawValue) profile was repaired and verified.",
            context: context
        )
    }

    func refreshBackendJobs() {
        Task {
            do {
                let response = try await BackendBridge.executeStreaming(.listJobs, context: backendContext) { _ in }
                await MainActor.run {
                    self.activeBackendJobs = response.jobs.filter {
                        [.queued, .started, .cancelling].contains($0.status)
                    }
                    self.recentBackendJobs = Array(response.jobs.filter {
                        ![.queued, .started, .cancelling].contains($0.status)
                    }.prefix(12))
                }
            } catch {
                // Job history is diagnostic; failure must not block the launcher.
            }
        }
    }

    func cancelBackendJob(_ job: BackendJob) {
        guard [.queued, .started, .cancelling].contains(job.status) else { return }
        Task {
            _ = try? await BackendBridge.executeStreaming(.cancelJob(id: job.id), context: backendContext) { _ in }
            await MainActor.run { self.refreshBackendJobs() }
        }
    }

    func resetCompatibilityProfile(_ profile: GraphicsBackendOption) {
        let context = effectiveBackendContext(backendContext.compatibilityContext(for: profile))
        executeDetached(
            .resetCompatibilityProfile(profile),
            successMessage: "The \(profile.rawValue) profile was deleted. Shared games were kept.",
            context: context
        )
    }

    func resetLegacyDirectXOverlay(for game: LibraryGame) {
        let settings = settings(for: game)
        let context = effectiveBackendContext(
            backendContext
                .overridingTarget(
                    bottleName: settings.assignedBottleName,
                    externalPrefix: settings.assignedExternalPrefix
                )
                .compatibilityContext(for: settings.graphicsBackend)
        )
        executeDetached(
            .resetGameOverlay(gameID: game.backendID ?? game.pinID),
            successMessage: "Removed the private legacy DirectX overlay.",
            context: context,
            game: game
        )
    }

    func discoverD3DMetal() {
        guard !isD3DMetalDiscoveryRunning else { return }
        rightPanelMessage = "Searching mounted volumes for a compatible D3DMetal runtime..."
        executeDetached(
            .discoverD3DMetal,
            successMessage: "Found and selected a matched Game Porting Toolkit installation.",
            context: backendContext
        )
    }

    func openGPTKDownload() {
        guard let url = URL(string: "https://developer.apple.com/games/game-porting-toolkit/") else { return }
        NSWorkspace.shared.open(url)
        rightPanelMessage = "Download and mount Game Porting Toolkit from Apple, then choose Find GPTK."
    }

    func importGPTK(confirmLicense: Bool) {
        executeDetached(
            .importGPTK(confirmLicense: confirmLicense),
            successMessage: "Game Porting Toolkit installed in NASE managed storage.",
            context: backendContext
        )
    }

    func attachSteamLibraries(to profile: GraphicsBackendOption) {
        let context = effectiveBackendContext(backendContext.compatibilityContext(for: profile))
        executeDetached(
            .attachSteamLibraries(profile),
            successMessage: "Shared Steam libraries attached to \(profile.rawValue).",
            context: context
        )
    }

    func refreshSteamIdentityStatus() {
        Task {
            do {
                let response = try await BackendBridge.execute(.steamIdentityStatus, context: backendContext)
                await MainActor.run { self.steamIdentityStatus = response.steamIdentity }
            } catch {
                await MainActor.run { self.rightPanelMessage = "Could not load shared Steam login status: \(error.localizedDescription)" }
            }
        }
    }

    func captureSteamIdentity(from bottle: String) {
        runSteamIdentityAction(.captureSteamIdentity(sourceBottle: bottle), success: "Protected Steam login saved.")
    }

    func provisionSteamIdentity(to bottle: String) {
        runSteamIdentityAction(.provisionSteamIdentity(targetBottle: bottle), success: "Shared Steam login applied to \(bottle).")
    }

    func forgetSteamIdentity() {
        runSteamIdentityAction(.forgetSteamIdentity, success: "NASE forgot the protected Steam login. Profile logins were unchanged.")
    }

    func signOutSteamProfile(_ bottle: String) {
        runSteamIdentityAction(.signOutSteamProfile(targetBottle: bottle), success: "Signed out Steam in \(bottle) only.")
    }

    private func runSteamIdentityAction(_ action: BackendAction, success: String) {
        Task {
            do {
                let response = try await BackendBridge.executeStreaming(action, context: backendContext) { _ in }
                await MainActor.run {
                    self.appendLog(response.output)
                    self.rightPanelMessage = success
                    self.refreshSteamIdentityStatus()
                }
            } catch {
                await MainActor.run {
                    self.appendLog("Shared Steam login action failed:\n\(error.localizedDescription)")
                    self.rightPanelMessage = error.localizedDescription
                    self.refreshSteamIdentityStatus()
                }
            }
        }
    }

    func compatibilityProfileHasSharedLibraries(_ profile: GraphicsBackendOption) -> Bool {
        let context = backendContext.compatibilityContext(for: profile)
        let config = currentPrefixURL(for: context)?
            .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps/libraryfolders.vdf")
        guard let config, let text = try? String(contentsOf: config, encoding: .utf8) else { return false }
        return text.contains("NASE Shared Library")
    }

    func compatibilityProfileIsReady(_ profile: GraphicsBackendOption) -> Bool {
        let context = backendContext.compatibilityContext(for: profile)
        return compatibilityProfileIsReady(profile, context: context)
    }

    private func compatibilityProfileIsReady(
        _ profile: GraphicsBackendOption,
        context: BackendContext
    ) -> Bool {
        let manifestURL = appSupportRootURL
            .appendingPathComponent("bottles", isDirectory: true)
            .appendingPathComponent(context.bottleName, isDirectory: true)
            .appendingPathComponent("compatibility-profile.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            payload["setup_status"] as? String == "ready",
            let storedProfile = payload["profile"] as? [String: Any]
        else { return false }
        return storedProfile["id"] as? String == profile.compatibilityProfileID
    }

    func runWinetricks(verbsText: String, interactive: Bool) {
        let verbs = verbsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !verbs.isEmpty else {
            rightPanelMessage = "Enter at least one winetricks verb."
            return
        }

        executeDetached(
            .runWinetricks(verbs: verbs, interactive: interactive),
            successMessage: "Winetricks finished for \(verbs.joined(separator: ", ")).",
            context: backendContext
        )
        closeWinetricks()
    }

    func applySettings(winePath: String, dxmtSource: String, bottleName: String, externalPrefix: String?, useExternalPrefix: Bool) {
        applySettings(
            winePath: winePath,
            dxmtSource: dxmtSource,
            dxvkSource: backendContext.dxvkSource,
            bottleName: bottleName,
            externalPrefix: externalPrefix,
            useExternalPrefix: useExternalPrefix
        )
    }

    func applySettings(winePath: String, dxmtSource: String, dxvkSource: String, bottleName: String, externalPrefix: String?, useExternalPrefix: Bool) {
        applySettings(
            winePath: winePath,
            dxmtSource: dxmtSource,
            dxvkSource: dxvkSource,
            d3dMetalSource: backendContext.d3dMetalSource,
            bottleName: bottleName,
            externalPrefix: externalPrefix,
            useExternalPrefix: useExternalPrefix
        )
    }

    func applySettings(winePath: String, dxmtSource: String, dxvkSource: String, d3dMetalSource: String, gptkWinePath: String? = nil, bottleName: String, externalPrefix: String?, useExternalPrefix: Bool) {
        let previousBottle = backendContext.bottleName
        let previousPrefix = backendContext.externalPrefix ?? ""
        let cleanedBottle = bottleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPrefix = (externalPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedWine = winePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDXMT = dxmtSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDXVK = dxvkSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedD3DMetal = d3dMetalSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedGPTKWine = (gptkWinePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        backendContext = BackendContext(
            repoRoot: backendContext.repoRoot,
            pythonCommand: backendContext.pythonCommand,
            winePath: cleanedWine.isEmpty ? backendContext.winePath : cleanedWine,
            dxmtSource: cleanedDXMT.isEmpty ? backendContext.dxmtSource : cleanedDXMT,
            dxvkSource: cleanedDXVK.isEmpty ? backendContext.dxvkSource : cleanedDXVK,
            d3dMetalSource: cleanedD3DMetal.isEmpty ? backendContext.d3dMetalSource : cleanedD3DMetal,
            gptkWinePath: cleanedGPTKWine.isEmpty ? backendContext.gptkWinePath : cleanedGPTKWine,
            bottleName: cleanedBottle.isEmpty ? "Default" : cleanedBottle,
            externalPrefix: useExternalPrefix ? cleanedPrefix : nil
        )
        backendContext.persist()

        let targetChanged = previousBottle != backendContext.bottleName || previousPrefix != (backendContext.externalPrefix ?? "")
        if targetChanged {
            hasAttemptedSteamDetection = false
            discoveredSteamGames = []
            selectedGame = nil
            if selectedRunner == .steam {
                refreshSteamGames(announce: false)
            }
        }

        rightPanelMessage = "Backend settings updated. \(settingsSummary)"
        appendLog("Settings updated.\nWine: \(backendContext.winePath)\nGPTK Wine: \(backendContext.gptkWinePath)\nDXMT: \(backendContext.dxmtSource)\nDXVK: \(backendContext.dxvkSource)\nD3DMetal: \(backendContext.d3dMetalSource)\nTarget: \(settingsSummary)")
    }

    func initialLoad() {
        refreshWineRuntimes()
        guard backendPreflightState == .unchecked else { return }
        backendPreflightState = .checking
        let context = backendContext
        Task {
            let backendReady = await BackendBridge.preflight(context: context)
            guard backendReady else {
                backendPreflightState = .bootstrapRequired
                isShowingSetupWizard = true
                rightPanelMessage = "The bundled NASE backend is unavailable. Reinstall NASE or select a supported Python runtime in Advanced Settings."
                appendLog("Backend preflight failed before source refresh.")
                return
            }
            backendPreflightState = .ready
            startBackendServices()
            refreshRuntimeCenter()
            refreshDependencyStatus()
            performInitialSetupIfNeeded()
            if !hasAttemptedSteamDetection, !isActionRunning(.listGames) {
                refreshSteamGames(announce: false)
            }
            refreshEpicLibrary(forceRefresh: false)
            refreshGOGLibrary(forceRefresh: false)
        }
    }

    private func startBackendServices() {
        guard launchSessionMonitor == nil else { return }
        refreshBackendJobs()
        launchSessionMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshLaunchSessions()
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
            }
        }
    }

    func testSettings(winePath: String, dxmtSource: String, bottleName: String, externalPrefix: String?, useExternalPrefix: Bool) -> String {
        let fileManager = FileManager.default
        let cleanedWine = winePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDXMT = dxmtSource.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBottle = bottleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPrefix = (externalPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        var results: [String] = []
        let backendScript = backendContext.repoRoot.appendingPathComponent("mysteamwine.py").path
        results.append(fileManager.fileExists(atPath: backendScript) ? "OK: mysteamwine.py found" : "FAIL: mysteamwine.py not found at repo root")
        results.append(validateWinePath(cleanedWine))
        results.append(detectedWinetricksStatus())
        results.append(contentsOf: validateDXMTSource(cleanedDXMT))

        if useExternalPrefix {
            results.append(fileManager.fileExists(atPath: cleanedPrefix) ? "OK: External prefix exists" : "FAIL: External prefix does not exist")
        } else {
            results.append(cleanedBottle.isEmpty ? "FAIL: Bottle name is empty" : "OK: Managed bottle name is set")
        }

        return results.joined(separator: "\n")
    }

    private func validateWinePath(_ path: String) -> String {
        guard !path.isEmpty else {
            return "FAIL: Wine path is empty"
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            return "FAIL: Wine path does not exist"
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            return "FAIL: Wine path exists but is not executable"
        }
        return "OK: Wine path exists and is executable"
    }

    private func performInitialSetupIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: LibraryStorageKey.didCompleteInitialSetup) else { return }

        if compatibilityProfileIsReady(.dxmt) {
            UserDefaults.standard.set(true, forKey: LibraryStorageKey.didCompleteInitialSetup)
            return
        }

        selectedRunner = .steam
        rightPanelMessage = "Set up the recommended DXMT profile to get started. Other profiles are created only when you use them."
        isShowingSetupWizard = true
    }

    private func validateDXMTSource(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return ["FAIL: DXMT source path is empty"]
        }

        let sourceURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return ["FAIL: DXMT source does not exist"]
        }

        var results = ["OK: DXMT source exists"]
        let lowercasedName = sourceURL.lastPathComponent.lowercased()
        var detectedVersion: String?
        for version in ["0.70", "0.71", "0.72", "0.73"] where lowercasedName.contains(version) || lowercasedName.contains("v\(version)") {
            detectedVersion = version
            break
        }
        if detectedVersion == nil, sourceURL.pathExtension != "gz" {
            let dllCandidates = [
                sourceURL.appendingPathComponent("x86_64-windows/d3d11.dll"),
                sourceURL.appendingPathComponent("x64/d3d11.dll"),
            ]
            for candidate in dllCandidates {
                guard let data = try? Data(contentsOf: candidate) else { continue }
                for version in ["0.70", "0.71", "0.72", "0.73"] where data.range(of: Data(version.utf8)) != nil {
                    detectedVersion = version
                    break
                }
                if detectedVersion != nil { break }
            }
        }

        if detectedVersion == "0.72" || detectedVersion == "0.73" {
            results.append("FAIL: DXMT \(detectedVersion ?? "") is known to regress this setup; use DXMT 0.70 or 0.71")
        } else if detectedVersion == "0.70" || detectedVersion == "0.71" {
            results.append("OK: DXMT version matches the validated 0.70/0.71 path")
        } else {
            results.append("WARN: DXMT 0.70 or 0.71 is recommended for the validated Wine Stable 11.0 setup")
        }

        if sourceURL.pathExtension == "gz" {
            results.append("OK: DXMT source is a .tar.gz archive")
            return results
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            results.append("FAIL: DXMT source is not a directory or .tar.gz archive")
            return results
        }

        let requiredLayoutA = [
            sourceURL.appendingPathComponent("x86_64-windows/d3d11.dll").path,
            sourceURL.appendingPathComponent("i386-windows/d3d11.dll").path,
        ]
        let requiredLayoutB = [
            sourceURL.appendingPathComponent("x64/d3d11.dll").path,
            sourceURL.appendingPathComponent("x32/d3d11.dll").path,
        ]
        let hasLayoutA = requiredLayoutA.allSatisfy(fileManager.fileExists(atPath:))
        let hasLayoutB = requiredLayoutB.allSatisfy(fileManager.fileExists(atPath:))

        if hasLayoutA || hasLayoutB {
            results.append("OK: DXMT payload folders look valid")
        } else {
            results.append("FAIL: DXMT source is missing expected x86_64-windows/i386-windows or x64/x32 payloads")
        }

        let unixCandidates = [
            sourceURL.appendingPathComponent("x86_64-unix/winemetal.so").path,
            sourceURL.appendingPathComponent("lib/wine/x86_64-unix/winemetal.so").path,
        ]
        if unixCandidates.contains(where: fileManager.fileExists(atPath:)) {
            results.append("OK: DXMT Unix-side winemetal runtime found")
        } else {
            results.append("WARN: DXMT Unix-side winemetal runtime not found")
        }

        return results
    }

    private func validateDXVKSource(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return ["FAIL: DXVK source path is empty"]
        }

        let sourceURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return ["FAIL: DXVK source does not exist"]
        }

        var results = ["OK: DXVK source exists"]
        if sourceURL.pathExtension == "gz" {
            results.append("OK: DXVK source is a .tar.gz archive")
            return results
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            results.append("FAIL: DXVK source is not a directory or .tar.gz archive")
            return results
        }

        let hasScript = [
            sourceURL.appendingPathComponent("setup_dxvk.sh").path,
            sourceURL.appendingPathComponent("setup-dxvk.sh").path,
        ].contains(where: fileManager.fileExists(atPath:))
        let payloadCandidates = [
            sourceURL.appendingPathComponent("x64/d3d11.dll").path,
            sourceURL.appendingPathComponent("x86_64-windows/d3d11.dll").path,
        ]

        if hasScript || payloadCandidates.contains(where: fileManager.fileExists(atPath:)) {
            results.append("OK: DXVK payload looks valid")
        } else {
            results.append("FAIL: DXVK source is missing setup script or DLL payload folders")
        }

        return results
    }

    private func validateD3DMetalSource(_ path: String) -> [String] {
        guard !path.isEmpty else {
            return ["FAIL: D3DMetal source path is empty"]
        }

        let sourceURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return ["FAIL: D3DMetal source does not exist"]
        }

        var results = ["OK: D3DMetal source exists"]
        if sourceURL.pathExtension == "gz" {
            results.append("OK: D3DMetal source is a .tar.gz archive")
            return results
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            results.append("FAIL: D3DMetal source is not a directory or .tar.gz archive")
            return results
        }

        let wineRoot = sourceURL.appendingPathComponent("wine")
        let windowsDirectory = wineRoot.appendingPathComponent("x86_64-windows")
        let unixDirectory = wineRoot.appendingPathComponent("x86_64-unix")
        let externalDirectory = sourceURL.appendingPathComponent("external")
        let frameworkVersioned = externalDirectory.appendingPathComponent("D3DMetal.framework/Versions/A/D3DMetal")
        let frameworkDirect = externalDirectory.appendingPathComponent("D3DMetal.framework/D3DMetal")
        let requiredFiles = ["d3d11.dll", "dxgi.dll", "d3d12.dll"]

        if requiredFiles.allSatisfy({ fileManager.fileExists(atPath: windowsDirectory.appendingPathComponent($0).path) }) {
            results.append("OK: D3DMetal Windows modules found")
        } else {
            results.append("FAIL: D3DMetal wine/x86_64-windows modules are incomplete")
        }
        results.append(fileManager.fileExists(atPath: unixDirectory.path)
            ? "OK: D3DMetal Unix Wine modules found"
            : "FAIL: D3DMetal wine/x86_64-unix is missing")
        results.append(
            fileManager.fileExists(atPath: frameworkVersioned.path) || fileManager.fileExists(atPath: frameworkDirect.path)
                ? "OK: D3DMetal.framework found"
                : "FAIL: external/D3DMetal.framework is missing"
        )
        results.append(fileManager.fileExists(atPath: externalDirectory.appendingPathComponent("libd3dshared.dylib").path)
            ? "OK: libd3dshared.dylib found"
            : "FAIL: external/libd3dshared.dylib is missing")

        return results
    }

    private var sourceGames: [LibraryGame] {
        switch selectedRunner ?? .home {
        case .home:
            pinnedGames
        case .mac:
            nativeApps
        case .steam:
            discoveredSteamGames
        case .wine:
            wineApps
        case .epic:
            epicGames
        case .gog:
            gogGames
        }
    }

    private var pinnedGames: [LibraryGame] {
        let byID = Dictionary(allLibraryGames.map { ($0.pinID, $0) }, uniquingKeysWith: { current, candidate in
            if current.installURL != nil { return current }
            return candidate
        })
        return pinnedGameIDs.compactMap { byID[$0] }
    }

    private var allLibraryGames: [LibraryGame] {
        nativeApps + discoveredSteamGames + wineApps + epicGames + gogGames
    }

    private func appendLog(_ message: String) {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if activityLog.isEmpty {
            activityLog = trimmedMessage
        } else {
            activityLog += "\n\n" + trimmedMessage
        }

        if activityLog.count > MemoryLimit.activityLogCharacters {
            let suffix = activityLog.suffix(MemoryLimit.activityLogCharacters)
            activityLog = "[Older activity output trimmed]\n\n" + suffix
        }
    }

    private static func readTailText(from url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer {
            try? handle.close()
        }

        let fileSize = (try? handle.seekToEnd()) ?? 0
        let bytesToRead = min(UInt64(maxBytes), fileSize)
        do {
            try handle.seek(toOffset: fileSize - bytesToRead)
            let data = try handle.readToEnd() ?? Data()
            let prefix = fileSize > bytesToRead ? "[Showing last \(maxBytes / 1024) KB]\n\n" : ""
            return prefix + (String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    private func refreshSteamGames(announce: Bool) {
        guard !isActionRunning(.listGames) else { return }

        let action: BackendAction = .listGames
        let activeJobID = beginBackendJob(for: action, message: announce ? "Refreshing Steam library..." : "Detecting installed Steam games...")
        hasAttemptedSteamDetection = true
        if announce {
            rightPanelMessage = "Refreshing installed Steam games..."
            appendLog("== Refresh Games ==\n\(BackendBridge.preview(action, context: backendContext))")
        } else {
            rightPanelMessage = "Detecting installed Steam games..."
        }

        Task {
            do {
                let response = try await BackendBridge.executeStreaming(action, context: backendContext) { update in
                    await MainActor.run {
                        self.applyStreamUpdate(update, fallbackActiveJobID: activeJobID, action: action)
                    }
                }
                if response.job == nil {
                    let fallbackJob = makeFallbackJob(for: action, status: .completed, message: jobSuccessMessage(for: action))
                    completeBackendJob(activeJobID, finalJob: fallbackJob)
                }
                steamMetadataByAppID = loadSteamMetadata(for: response.games)
                discoveredSteamGames = mappedSteamGames(from: response.games)
                selectedGame = filteredGames.first
                appendLog(response.output)
                rightPanelMessage = discoveredSteamGames.isEmpty
                    ? "No installed Steam games were detected."
                    : "Detected \(discoveredSteamGames.count) installed Steam game(s)."
            } catch {
                if activeBackendJobs.contains(where: { $0.id == activeJobID }) {
                    let failedJob = makeFallbackJob(for: action, status: .failed, message: "Refresh Games failed.")
                    completeBackendJob(activeJobID, finalJob: failedJob)
                }
                appendLog("Command failed:\n\(error.localizedDescription)")
                rightPanelMessage = "Steam game detection failed."
            }
        }
    }

    func refreshEpicLibrary(forceRefresh: Bool = true) {
        Task {
            do {
                let statusResponse = try await BackendBridge.execute(
                    .sourceStatus(source: "epic"),
                    context: backendContext
                )
                epicSourceStatus = statusResponse.sourceStatus
                guard let status = epicSourceStatus, status.available else {
                    epicGames = []
                    selectedGame = nil
                    rightPanelMessage = statusResponse.sourceStatus?.message ?? "Install Legendary to enable Epic Games."
                    return
                }
                guard status.authenticated else {
                    epicGames = []
                    selectedGame = nil
                    rightPanelMessage = status.message
                    return
                }
                rightPanelMessage = "Refreshing Epic Games library…"
                let response = try await BackendBridge.executeStreaming(
                    .listSourceGames(source: "epic", forceRefresh: forceRefresh),
                    context: backendContext
                ) { _ in }
                epicGames = response.sourceGames.map { game in
                    let installURL = game.installPath.map(URL.init(fileURLWithPath:))
                    return LibraryGame(
                        pinID: game.libraryID,
                        backendID: game.storeID,
                        title: game.title,
                        runner: .epic,
                        capsule: "Epic Games",
                        status: game.installed ? (game.updateAvailable ? "Update Available" : "Installed") : "Owned",
                        statsText: game.version,
                        bannerURL: game.artURL.flatMap(URL.init(string:)),
                        installURL: installURL,
                        launchURL: installURL
                    )
                }
                let hasActiveEpicOperation = activeBackendJobs.contains {
                    $0.status == .started && $0.action.localizedCaseInsensitiveContains("Epic")
                }
                if !hasActiveEpicOperation {
                    for game in epicGames where launchStatusByPinID[game.pinID]?.phase == .launching {
                        launchStatusByPinID.removeValue(forKey: game.pinID)
                    }
                }
                selectedGame = epicGames.first
                appendLog(response.output)
                rightPanelMessage = "Loaded \(epicGames.count) Epic Games title(s)."
            } catch {
                epicGames = []
                selectedGame = nil
                appendLog("Epic library refresh failed:\n\(error.localizedDescription)")
                rightPanelMessage = error.localizedDescription
            }
        }
    }

    func refreshGOGLibrary(forceRefresh: Bool = true) {
        Task {
            do {
                let statusResponse = try await BackendBridge.execute(.sourceStatus(source: "gog"), context: backendContext)
                gogSourceStatus = statusResponse.sourceStatus
                guard let status = gogSourceStatus, status.available, status.authenticated else {
                    gogGames = []
                    selectedGame = nil
                    rightPanelMessage = statusResponse.sourceStatus?.message ?? "Install the GOG client to enable GOG."
                    return
                }
                rightPanelMessage = "Refreshing GOG library…"
                let response = try await BackendBridge.executeStreaming(
                    .listSourceGames(source: "gog", forceRefresh: forceRefresh), context: backendContext
                ) { _ in }
                gogGames = response.sourceGames.map { game in
                    let installURL = game.installPath.map(URL.init(fileURLWithPath:))
                    return LibraryGame(pinID: game.libraryID, backendID: game.storeID, title: game.title,
                                       runner: .gog, capsule: "GOG", status: game.installed ? "Installed" : "Owned",
                                       statsText: game.version, bannerURL: game.artURL.flatMap(URL.init(string:)),
                                       installURL: installURL, launchURL: installURL)
                }
                selectedGame = gogGames.first
                appendLog(response.output)
                rightPanelMessage = "Loaded \(gogGames.count) GOG title(s)."
            } catch {
                gogGames = []
                selectedGame = nil
                appendLog("GOG library refresh failed:\n\(error.localizedDescription)")
                rightPanelMessage = error.localizedDescription
            }
        }
    }

    private func mappedSteamGames(from games: [BackendGame]) -> [LibraryGame] {
        let mapped = games
            .filter { shouldDisplaySteamGame($0) }
            .map { game in
                let installURL = game.installDir.map(URL.init(fileURLWithPath:))
                return LibraryGame(
                    backendID: game.appid,
                    title: game.name,
                    runner: .steam,
                    capsule: "Steam",
                    status: "Installed",
                    statsText: installURL.flatMap(directorySizeText),
                    bannerURL: steamBannerURL(for: game.appid),
                    installURL: installURL,
                    launchURL: installURL,
                    storeURL: steamStoreURL(for: game.appid)
                )
            }
        return applySteamOrder(to: mapped)
    }

    private func shouldDisplaySteamGame(_ game: BackendGame) -> Bool {
        let normalizedName = game.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if game.appid == "228980" {
            return false
        }
        if hiddenSteamAppIDs.contains(game.appid) {
            return false
        }
        return normalizedName != "steamworks common redistributables"
    }

    private func steamBannerURL(for appid: String) -> URL? {
        URL(string: "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_hero.jpg")
    }

    private func steamStoreURL(for appid: String) -> URL? {
        URL(string: "https://store.steampowered.com/app/\(appid)")
    }

    private func importMacApps() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let imported = panel.urls.map { url in
            LibraryGame(
                pinID: LibraryGame.importedPinID(runner: .mac, url: url),
                title: url.deletingPathExtension().lastPathComponent,
                runner: .mac,
                capsule: "macOS",
                status: "App",
                statsText: directorySizeText(url),
                installURL: url,
                launchURL: url
            )
        }
        nativeApps = mergeLibraryGames(existing: nativeApps, incoming: imported)
        persistStoredItems(nativeApps, forKey: LibraryStorageKey.nativeApps)
        selectedGame = filteredGames.first
    }

    private func importWineTargets() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe"),
            UTType(filenameExtension: "msi"),
            UTType(filenameExtension: "bat"),
            UTType(filenameExtension: "cmd"),
        ].compactMap { $0 }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }

        let imported = panel.urls.map { url in
            let isExe = url.pathExtension.lowercased() == "exe"
            let launchURL = isExe ? url : promptForExecutable(in: url)
            return LibraryGame(
                pinID: LibraryGame.importedPinID(runner: .wine, url: url),
                title: url.deletingPathExtension().lastPathComponent,
                runner: .wine,
                capsule: "Wine",
                status: launchURL != nil ? "Windows App" : "Choose Executable",
                statsText: directorySizeText(url),
                installURL: url,
                launchURL: launchURL
            )
        }
        wineApps = mergeLibraryGames(existing: wineApps, incoming: imported)
        for game in imported {
            var settings = gameSettingsByPinID[game.pinID] ?? defaultSettings(for: game)
            if settings.workingDirectoryPath.isEmpty {
                settings.workingDirectoryPath = game.launchURL?.deletingLastPathComponent().path ?? game.installURL?.path ?? ""
            }
            if settings.launchExecutablePath.isEmpty {
                settings.launchExecutablePath = game.launchURL?.path ?? ""
            }
            if settings.assignedExternalPrefix.isEmpty, settings.assignedBottleName.isEmpty {
                if let externalPrefix = backendContext.externalPrefix, !externalPrefix.isEmpty {
                    settings.assignedExternalPrefix = externalPrefix
                } else {
                    settings.assignedBottleName = backendContext.bottleName
                }
            }
            gameSettingsByPinID[game.pinID] = settings
        }
        persistGameSettings()
        persistStoredItems(wineApps, forKey: LibraryStorageKey.wineApps)
        selectedGame = imported.first ?? filteredGames.first
        if let missingTarget = imported.first(where: { $0.launchURL == nil }) {
            openGameSettings(for: missingTarget)
        }
    }

    private func promptForExecutable(in directory: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "exe")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Launch EXE"
        panel.message = "Select the Windows executable this entry should launch."
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func mergeLibraryGames(existing: [LibraryGame], incoming: [LibraryGame]) -> [LibraryGame] {
        var seen = Set(existing.map(\.pinID))
        var merged = existing
        for game in incoming where !seen.contains(game.pinID) {
            merged.append(game)
            seen.insert(game.pinID)
        }
        return merged
    }

    private func loadStoredItems(forKey key: String) -> [LibraryGame] {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let stored = try? JSONDecoder().decode([StoredLibraryItem].self, from: data)
        else {
            return []
        }

        return stored.compactMap { item in
            guard let runner = RunnerKind(rawValue: item.runner) else { return nil }
            let installURL = URL(fileURLWithPath: item.installPath)
            let launchURL = item.launchPath.map(URL.init(fileURLWithPath:))
            let storedStatus = item.status?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status: String
            if let storedStatus, !storedStatus.isEmpty {
                status = storedStatus
            } else {
                if runner == .wine {
                    status = launchURL == nil ? "Choose Executable" : "Windows App"
                } else {
                    status = "App"
                }
            }
            return LibraryGame(
                pinID: item.pinID ?? LibraryGame.importedPinID(runner: runner, url: installURL),
                title: item.title,
                runner: runner,
                capsule: runner == .mac ? "macOS" : "Wine",
                status: status,
                statsText: directorySizeText(installURL),
                installURL: installURL,
                launchURL: launchURL
            )
        }
    }

    private func persistStoredItems(_ games: [LibraryGame], forKey key: String) {
        let stored = games.compactMap { game -> StoredLibraryItem? in
            guard let installURL = game.installURL, game.runner == .mac || game.runner == .wine else {
                return nil
            }
            return StoredLibraryItem(
                pinID: game.pinID,
                title: game.title,
                runner: game.runner.rawValue,
                installPath: installURL.path,
                launchPath: game.launchURL?.path,
                status: game.status
            )
        }

        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func migrateLegacyImportedAppIdentity() {
        var settingsChanged = false
        var pinsChanged = false
        var migratedLegacyIDs = Set<String>()

        for game in nativeApps + wineApps {
            let legacyID = "\(game.runner.rawValue):\(game.title)"
            guard legacyID != game.pinID, !migratedLegacyIDs.contains(legacyID) else { continue }

            if gameSettingsByPinID[game.pinID] == nil, let legacySettings = gameSettingsByPinID.removeValue(forKey: legacyID) {
                gameSettingsByPinID[game.pinID] = legacySettings
                settingsChanged = true
            }
            if pinnedGameIDs.contains(legacyID) {
                pinnedGameIDs = pinnedGameIDs.map { $0 == legacyID ? game.pinID : $0 }
                pinsChanged = true
            }
            migratedLegacyIDs.insert(legacyID)
        }

        if settingsChanged {
            persistGameSettings()
        }
        if pinsChanged {
            pinnedGameIDs = Array(NSOrderedSet(array: pinnedGameIDs)) as? [String] ?? pinnedGameIDs
            persistPinnedIDs()
        }
        persistStoredItems(nativeApps, forKey: LibraryStorageKey.nativeApps)
        persistStoredItems(wineApps, forKey: LibraryStorageKey.wineApps)
    }

    private func persistPinnedIDs() {
        UserDefaults.standard.set(pinnedGameIDs, forKey: LibraryStorageKey.pinnedIDs)
    }

    private func persistSteamOrder() {
        UserDefaults.standard.set(steamOrderIDs, forKey: LibraryStorageKey.steamOrder)
    }

    private func loadGameSettings() -> [String: StoredGameSettings] {
        guard
            let data = UserDefaults.standard.data(forKey: LibraryStorageKey.gameSettings),
            let stored = try? JSONDecoder().decode([String: StoredGameSettings].self, from: data)
        else {
            return [:]
        }
        return stored
    }

    private func persistGameSettings() {
        guard let data = try? JSONEncoder().encode(gameSettingsByPinID) else { return }
        UserDefaults.standard.set(data, forKey: LibraryStorageKey.gameSettings)
    }

    private func loadSourceHealth() -> [RunnerKind: HealthStatus] {
        guard
            let data = UserDefaults.standard.data(forKey: LibraryStorageKey.sourceHealth),
            let stored = try? JSONDecoder().decode([String: HealthStatus].self, from: data)
        else {
            return [.home: .healthy, .mac: .healthy, .steam: .unknown, .wine: .unknown]
        }

        var mapped: [RunnerKind: HealthStatus] = [.home: .healthy, .mac: .healthy, .steam: .unknown, .wine: .unknown]
        for (key, value) in stored {
            if let runner = RunnerKind(rawValue: key) {
                mapped[runner] = value
            }
        }
        return mapped
    }

    private func persistSourceHealth() {
        let stored = Dictionary(uniqueKeysWithValues: sourceHealth.map { ($0.key.rawValue, $0.value) })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: LibraryStorageKey.sourceHealth)
    }

    func settings(for game: LibraryGame) -> StoredGameSettings {
        var settings = gameSettingsByPinID[game.pinID] ?? defaultSettings(for: game)
        if game.runner == .wine, settings.graphicsBackendWasExplicitlySelected != true {
            settings.graphicsBackend = .none
        }
        return settings
    }

    private func defaultSettings(for game: LibraryGame) -> StoredGameSettings {
        var settings = StoredGameSettings()
        if game.runner == .wine {
            settings.graphicsBackend = .none
        }
        return settings
    }

    func saveSettings(
        for game: LibraryGame,
        launchArguments: String,
        workingDirectoryPath: String,
        environmentText: String,
        graphicsBackend: GraphicsBackendOption,
        launchExecutablePath: String,
        customBannerPath: String,
        collection: GameCollection,
        assignedBottleName: String,
        assignedExternalPrefix: String,
        legacyDirectXEnabled: Bool,
        legacyDirectXSource: String
    ) {
        gameSettingsByPinID[game.pinID] = StoredGameSettings(
            launchArguments: launchArguments,
            workingDirectoryPath: workingDirectoryPath,
            environmentText: environmentText,
            graphicsBackend: graphicsBackend,
            launchExecutablePath: launchExecutablePath,
            customBannerPath: customBannerPath,
            collection: collection,
            assignedBottleName: assignedBottleName,
            assignedExternalPrefix: assignedExternalPrefix,
            legacyDirectXEnabled: legacyDirectXEnabled,
            legacyDirectXSource: legacyDirectXSource,
            graphicsBackendWasExplicitlySelected: true
        )
        persistGameSettings()
        selectedGame = filteredGames.first(where: { $0.pinID == game.pinID }) ?? selectedGame
    }

    func health(for runner: RunnerKind) -> HealthStatus {
        switch runner {
        case .home:
            let statuses = [sourceHealth[.steam] ?? .unknown, sourceHealth[.wine] ?? .unknown, sourceHealth[.mac] ?? .healthy]
            if statuses.contains(.error) { return .error }
            if statuses.contains(.warning) { return .warning }
            if statuses.contains(.healthy) { return .healthy }
            return .unknown
        default:
            return sourceHealth[runner] ?? .unknown
        }
    }

    private func ensureBackgroundDoctor(for runner: RunnerKind) {
        guard (runner == .steam || runner == .wine), !runningHealthChecks.contains(runner) else { return }

        runningHealthChecks.insert(runner)
        let activeJobID = beginBackendJob(for: .doctor, message: "Background doctor running for \(runner.rawValue)...")
        Task {
            defer { runningHealthChecks.remove(runner) }
            do {
                let response = try await BackendBridge.executeStreaming(.doctor, context: backendContext) { update in
                    await MainActor.run {
                        self.applyStreamUpdate(update, fallbackActiveJobID: activeJobID, action: .doctor)
                    }
                }
                if response.job == nil {
                    let fallbackJob = makeFallbackJob(for: .doctor, status: .completed, message: "Doctor finished.")
                    completeBackendJob(activeJobID, finalJob: fallbackJob)
                }
                if let structured = response.structured {
                    latestDoctorResult = structured
                    updateHealth(for: runner, from: structured)
                } else {
                    updateHealth(for: runner, from: response.output)
                }
            } catch {
                if activeBackendJobs.contains(where: { $0.id == activeJobID }) {
                    let failedJob = makeFallbackJob(for: .doctor, status: .failed, message: "Doctor failed.")
                    completeBackendJob(activeJobID, finalJob: failedJob)
                }
                sourceHealth[runner] = .warning
                persistSourceHealth()
            }
        }
    }

    private func updateHealth(for runner: RunnerKind, from output: String) {
        sourceHealth[runner] = healthStatus(from: output)
        sourceHealth[.home] = health(for: .home)
        persistSourceHealth()
    }

    private func updateHealth(for runner: RunnerKind, from structured: BackendStructuredResult) {
        sourceHealth[runner] = healthStatus(from: structured)
        sourceHealth[.home] = health(for: .home)
        persistSourceHealth()
    }

    private func healthStatus(from output: String) -> HealthStatus {
        if output.contains("FAIL:") || output.contains("[FAIL]") || output.localizedCaseInsensitiveContains("failed") {
            return .error
        }
        if output.contains("WARN:") || output.contains("[WARN]") || output.localizedCaseInsensitiveContains("warning") {
            return .warning
        }
        if output.contains("OK:") || output.contains("[OK]") {
            return .healthy
        }
        return .unknown
    }

    private func healthStatus(from structured: BackendStructuredResult) -> HealthStatus {
        switch structured.worstStatus {
        case "fail":
            return .error
        case "warn":
            return .warning
        case "ok":
            return .healthy
        default:
            break
        }

        if structured.errors.isEmpty == false {
            return .error
        }
        if structured.warnings.isEmpty == false {
            return .warning
        }
        if structured.checks.isEmpty == false || structured.steps.isEmpty == false {
            return .healthy
        }
        return .unknown
    }

    private func beginBackendJob(for action: BackendAction, message: String? = nil) -> String {
        let job = BackendJob(
            id: UUID().uuidString,
            action: actionDisplayName(action),
            status: .started,
            message: message ?? "\(actionDisplayName(action)) running...",
            progress: nil,
            completedSteps: nil,
            totalSteps: nil
        )
        activeBackendJobs.removeAll { $0.action == job.action && $0.status == .started }
        activeBackendJobs.insert(job, at: 0)
        return job.id
    }

    private func isActionRunning(_ action: BackendAction) -> Bool {
        let name = actionDisplayName(action)
        return activeBackendJobs.contains { job in
            job.action == name && (job.status == .started || job.status == .queued)
        }
    }

    private func completeBackendJob(_ activeJobID: String, finalJob: BackendJob) {
        activeBackendJobs.removeAll { $0.id == activeJobID }
        recordBackendJob(finalJob)
    }

    private func applyStreamUpdate(_ update: BackendStreamUpdate, fallbackActiveJobID: String, action: BackendAction) {
        if let structured = update.structured {
            mergeStructuredResult(structured, for: action)
        }

        guard let job = update.job else { return }

        switch job.status {
        case .started, .queued, .cancelling:
            activeBackendJobs.removeAll { $0.id == fallbackActiveJobID || $0.id == job.id || $0.action == job.action }
            activeBackendJobs.insert(job, at: 0)
        case .completed, .failed, .cancelled, .interrupted:
            activeBackendJobs.removeAll { $0.id == fallbackActiveJobID || $0.id == job.id || $0.action == job.action }
            recordBackendJob(job)
        }
    }

    private func makeFallbackJob(for action: BackendAction, status: BackendJobStatus, message: String) -> BackendJob {
        BackendJob(
            id: UUID().uuidString,
            action: actionDisplayName(action),
            status: status,
            message: message,
            progress: nil,
            completedSteps: nil,
            totalSteps: nil
        )
    }

    private func recordBackendJob(_ job: BackendJob?) {
        guard let job else { return }
        recentBackendJobs.removeAll { $0.id == job.id }
        recentBackendJobs.insert(job, at: 0)
        if recentBackendJobs.count > 12 {
            recentBackendJobs = Array(recentBackendJobs.prefix(12))
        }
    }

    private func recordStructuredResult(_ structured: BackendStructuredResult?, for action: BackendAction) {
        guard let structured else { return }

        switch action {
        case .listJobs, .cancelJob:
            break
        case .doctor, .doctorFix:
            latestDoctorResult = structured
        case .setupMetal:
            latestSetupResult = structured
        case .listGames:
            latestScanResult = structured
        default:
            break
        }
    }

    private func mergeStructuredResult(_ incoming: BackendStructuredResult, for action: BackendAction) {
        let current: BackendStructuredResult?
        switch action {
        case .doctor, .doctorFix:
            current = latestDoctorResult
        case .setupMetal:
            current = latestSetupResult
        default:
            current = nil
        }

        guard let current else {
            recordStructuredResult(incoming, for: action)
            return
        }

        let merged = BackendStructuredResult(
            action: incoming.action,
            root: incoming.root ?? current.root,
            target: incoming.target ?? current.target,
            worstStatus: incoming.worstStatus ?? current.worstStatus,
            fixes: incoming.fixes.isEmpty ? current.fixes : incoming.fixes,
            checks: incoming.checks.isEmpty ? current.checks : incoming.checks,
            steps: mergeSteps(current.steps, incoming.steps),
            signals: incoming.signals.isEmpty ? current.signals : incoming.signals,
            recommendations: incoming.recommendations.isEmpty ? current.recommendations : incoming.recommendations,
            warnings: incoming.warnings.isEmpty ? current.warnings : incoming.warnings,
            errors: incoming.errors.isEmpty ? current.errors : incoming.errors,
            tail: incoming.tail ?? current.tail,
            completedSteps: incoming.completedSteps ?? current.completedSteps,
            totalSteps: incoming.totalSteps ?? current.totalSteps,
            gptkWinePath: incoming.gptkWinePath ?? current.gptkWinePath,
            d3dMetalSource: incoming.d3dMetalSource ?? current.d3dMetalSource
        )
        recordStructuredResult(merged, for: action)
    }

    private func mergeSteps(_ existing: [BackendStepSummary], _ incoming: [BackendStepSummary]) -> [BackendStepSummary] {
        guard incoming.isEmpty == false else { return existing }
        var merged = existing
        for step in incoming {
            if let index = merged.firstIndex(where: { $0.name == step.name }) {
                merged[index] = step
            } else {
                merged.append(step)
            }
        }
        return merged
    }

    private func actionDisplayName(_ action: BackendAction) -> String {
        switch action {
        case .sourceStatus:
            return "Check Game Source"
        case .listSourceGames:
            return "Refresh Store Library"
        case .epicAuthenticate:
            return "Connect Epic Games"
        case .epicLogout:
            return "Sign Out Epic Games"
        case .gogAuthenticate:
            return "Connect GOG"
        case .gogLogout:
            return "Sign Out GOG"
        case .sourceGameAction(let source, _, let operation, _):
            return "\(source.uppercased()) \(operation.capitalized)"
        case .launchSourceGame:
            return "Launch Epic Game"
        case .steamIdentityStatus:
            return "Refresh Steam Login"
        case .captureSteamIdentity:
            return "Save Steam Login"
        case .provisionSteamIdentity:
            return "Apply Steam Login"
        case .forgetSteamIdentity:
            return "Forget Steam Login"
        case .signOutSteamProfile:
            return "Sign Out Steam Profile"
        case .listJobs:
            return "Refresh Jobs"
        case .cancelJob:
            return "Cancel Job"
        case .dependencyStatus:
            return "Check Dependencies"
        case .discoverD3DMetal:
            return "Find Game Porting Toolkit"
        case .importGPTK:
            return "Install Game Porting Toolkit"
        case .installHostDependency:
            return "Install Host Dependency"
        case .setupCompatibilityProfile:
            return "Set Up Compatibility Profile"
        case .repairCompatibilityProfile:
            return "Repair Compatibility Profile"
        case .resetCompatibilityProfile:
            return "Reset Compatibility Profile"
        case .resetGameOverlay:
            return "Reset Game Overlay"
        case .attachSteamLibraries:
            return "Attach Shared Steam Libraries"
        case .setupMetal:
            return "Finish Setup"
        case .doctor:
            return "Inspect Environment"
        case .doctorFix:
            return "Repair Environment"
        case .runWinetricks:
            return "Winetricks"
        case .installDXMT:
            return "Install DXMT"
        case .installDXVK:
            return "Install DXVK"
        case .installD3DMetal:
            return "Install D3DMetal"
        case .openWinecfg:
            return "Wine Configuration"
        case .killWine:
            return "Kill Wine"
        case .listSessions:
            return "Refresh Game Sessions"
        case .stopGame:
            return "Stop Game"
        case .openSteam:
            return "Open Steam"
        case .listGames:
            return "Refresh Games"
        case .listRuntimeCatalog:
            return "Refresh Runtime Catalog"
        case .listInstalledRuntimes:
            return "Refresh Managed Runtimes"
        case .installRuntime:
            return "Install Runtime"
        case .launchGame:
            return "Launch Game"
        case .smartLaunchGame:
            return "Smart Launch"
        case .debugGame:
            return "Debug Game"
        case .debugExecutable:
            return "Launch Executable"
        }
    }

    private func jobSuccessMessage(for action: BackendAction) -> String {
        switch action {
        case .sourceStatus:
            return "Game source status refreshed."
        case .listSourceGames:
            return "Store library refreshed."
        case .epicAuthenticate:
            return "Epic Games account connected."
        case .epicLogout:
            return "Epic Games account signed out."
        case .gogAuthenticate:
            return "GOG account connected."
        case .gogLogout:
            return "GOG account signed out."
        case .sourceGameAction(let source, _, let operation, _):
            return "\(source.uppercased()) \(operation) completed."
        case .launchSourceGame:
            return "Epic game launch sent."
        case .steamIdentityStatus:
            return "Shared Steam login status refreshed."
        case .captureSteamIdentity:
            return "Protected Steam login saved."
        case .provisionSteamIdentity:
            return "Shared Steam login applied."
        case .forgetSteamIdentity:
            return "Protected Steam login forgotten."
        case .signOutSteamProfile:
            return "Steam profile signed out."
        case .listJobs:
            return "Job history refreshed."
        case .cancelJob:
            return "Cancellation requested."
        case .dependencyStatus:
            return "Dependency check finished."
        case .discoverD3DMetal:
            return "Matched Game Porting Toolkit installation found."
        case .importGPTK:
            return "Game Porting Toolkit installed."
        case .installHostDependency:
            return "Host dependency installed."
        case .setupCompatibilityProfile:
            return "Compatibility profile is ready."
        case .repairCompatibilityProfile:
            return "Compatibility profile was repaired."
        case .resetCompatibilityProfile:
            return "Compatibility profile was reset."
        case .resetGameOverlay:
            return "Per-game overlay was reset."
        case .attachSteamLibraries:
            return "Shared Steam libraries attached."
        case .setupMetal:
            return "Setup finished."
        case .doctor:
            return "Environment check finished."
        case .doctorFix:
            return "Environment repair finished."
        case .runWinetricks:
            return "Winetricks finished."
        case .installDXMT:
            return "Installed DXMT."
        case .installDXVK:
            return "Installed DXVK."
        case .installD3DMetal:
            return "Installed D3DMetal."
        case .openWinecfg:
            return "winecfg exited."
        case .killWine:
            return "Stopped Wine processes."
        case .listSessions:
            return "Game sessions refreshed."
        case .stopGame:
            return "Game stopped."
        case .openSteam:
            return "Steam launch sent."
        case .listGames:
            return "Refresh Games finished."
        case .listRuntimeCatalog:
            return "Runtime catalog refreshed."
        case .listInstalledRuntimes:
            return "Managed runtimes refreshed."
        case .installRuntime:
            return "Runtime installed."
        case .launchGame:
            return "Launch request sent."
        case .smartLaunchGame:
            return "Launch request sent."
        case .debugGame:
            return "Debug launch started."
        case .debugExecutable:
            return "Executable launch started."
        }
    }

    private func launchSteamGame(_ game: LibraryGame) {
        guard let appid = game.backendID, !appid.isEmpty else { return }

        let settings = settings(for: game)
        let context = effectiveContext(for: game)
        let args = parseLaunchArguments(settings.launchArguments)
        let env = parseEnvironmentOverrides(settings.environmentText)
        let cwd = normalizedOptionalPath(settings.workingDirectoryPath)
        let manualExecutable = normalizedOptionalPath(settings.launchExecutablePath)

        if shouldUseDirectSteamLaunch(for: settings) {
            if let manualExecutable {
                executeDetached(
                    .debugExecutable(
                        path: manualExecutable,
                        gameArgs: args,
                        graphicsBackend: settings.graphicsBackend,
                        workingDirectory: cwd,
                        environment: env,
                        wineDebug: "-all",
                        legacyDirectXSource: settings.legacyDirectXEnabled == true ? settings.legacyDirectXSource : nil
                    ),
                    successMessage: "Launched \(game.title).",
                    context: context,
                    game: game
                )
            } else {
                executeDetached(
                    .debugGame(
                        appid: appid,
                        gameArgs: args,
                        graphicsBackend: settings.graphicsBackend,
                        workingDirectory: cwd,
                        environment: env,
                        wineDebug: "-all",
                        legacyDirectXSource: settings.legacyDirectXEnabled == true ? settings.legacyDirectXSource : nil
                    ),
                    successMessage: "Launched \(game.title).",
                    context: context,
                    game: game
                )
            }
            return
        }

        executeDetached(
            .smartLaunchGame(appid: appid, graphicsBackend: settings.graphicsBackend),
            successMessage: "Launched \(game.title).",
            context: context,
            game: game
        )
    }

    private func requiredCompatibilityProfile(for game: LibraryGame) -> GraphicsBackendOption? {
        switch game.runner {
        case .steam:
            return settings(for: game).graphicsBackend
        case .epic, .gog:
            return game.installURL == nil ? nil : settings(for: game).graphicsBackend
        case .home:
            return underlyingGame(for: game).flatMap(requiredCompatibilityProfile)
        case .mac, .wine:
            return nil
        }
    }

    /// Returns true when launch must pause while the selected profile is created.
    private func ensureCompatibilityProfile(
        _ profile: GraphicsBackendOption,
        beforeLaunching game: LibraryGame
    ) -> Bool {
        let context = effectiveContext(for: game)
        guard !compatibilityProfileIsReady(profile, context: context) else { return false }
        guard !provisioningProfiles.contains(profile) else {
            setLaunchStatus(.launching, for: game, message: "Preparing the \(profile.rawValue) profile…")
            return true
        }

        provisioningProfiles.insert(profile)
        setLaunchStatus(.launching, for: game, message: "Preparing the \(profile.rawValue) profile and Steam…")
        rightPanelMessage = "Creating \(profile.rawValue) on demand. Shared game files will be reused."
        executeDetached(
            .setupCompatibilityProfile(profile),
            successMessage: "\(profile.rawValue) is ready.",
            context: context,
            game: game
        ) {
            self.provisioningProfiles.remove(profile)
            self.launch(game)
        }
        return true
    }

    private func openDefaultSteam() {
        let profile = GraphicsBackendOption.dxmt
        let context = effectiveBackendContext(backendContext.compatibilityContext(for: profile))
        guard !compatibilityProfileIsReady(profile) else {
            executeDetached(.openSteam, successMessage: "Opened Steam.", context: context)
            return
        }
        guard !provisioningProfiles.contains(profile) else {
            rightPanelMessage = "The default DXMT profile is already being prepared."
            return
        }

        provisioningProfiles.insert(profile)
        rightPanelMessage = "Creating the default DXMT profile and Steam…"
        executeDetached(
            .setupCompatibilityProfile(profile),
            successMessage: "DXMT is ready.",
            context: context
        ) {
            self.provisioningProfiles.remove(profile)
            self.executeDetached(.openSteam, successMessage: "Opened Steam.", context: context)
        }
    }

    private func shouldUseDirectSteamLaunch(for settings: StoredGameSettings) -> Bool {
        !settings.launchArguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !settings.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !settings.environmentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !settings.launchExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !settings.assignedBottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !settings.assignedExternalPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || settings.legacyDirectXEnabled == true
    }

    private func effectiveContext(for game: LibraryGame) -> BackendContext {
        let settings = settings(for: game)
        let context = backendContext.overridingTarget(
            bottleName: settings.assignedBottleName,
            externalPrefix: settings.assignedExternalPrefix
        ).compatibilityContext(for: settings.graphicsBackend)
        return effectiveBackendContext(context)
    }

    private func setLaunchStatus(_ phase: GameLaunchPhase, for game: LibraryGame, message: String) {
        launchStatusByPinID[game.pinID] = GameLaunchStatus(
            phase: phase,
            message: message,
            updatedAt: Date()
        )
    }

    private func executeDetached(
        _ action: BackendAction,
        successMessage: String,
        context: BackendContext,
        game: LibraryGame? = nil,
        onSuccess: (() -> Void)? = nil
    ) {
        let preview = BackendBridge.preview(action, context: context)
        appendLog("== Action ==\n\(preview)")
        rightPanelMessage = "Launching..."
        if let game {
            if case .sourceGameAction(let source, _, let operation, _) = action {
                setLaunchStatus(.launching, for: game, message: "\(source.uppercased()) \(operation) in progress…")
            } else {
                setLaunchStatus(.launching, for: game, message: "Sending launch request...")
            }
        }
        let activeJobID = beginBackendJob(for: action)
        let actionLaunchGeneration = launchStateGeneration

        Task.detached(priority: .userInitiated) {
            do {
                let response = try await BackendBridge.executeStreaming(action, context: context) { update in
                    await MainActor.run {
                        self.applyStreamUpdate(update, fallbackActiveJobID: activeJobID, action: action)
                    }
                }
                await MainActor.run {
                    if let responseJob = response.job {
                        self.reconcileDetachedJob(responseJob, fallbackActiveJobID: activeJobID, action: action)
                    } else {
                        let fallbackJob = self.makeFallbackJob(for: action, status: .completed, message: self.jobSuccessMessage(for: action))
                        self.completeBackendJob(activeJobID, finalJob: fallbackJob)
                    }
                    if response.structured != nil {
                        self.recordStructuredResult(response.structured, for: action)
                    }
                    if case .discoverD3DMetal = action,
                       let winePath = response.structured?.gptkWinePath,
                       let source = response.structured?.d3dMetalSource {
                        self.backendContext = self.backendContext.overridingGPTK(
                            winePath: winePath,
                            d3dMetalSource: source
                        )
                        self.backendContext.persist()
                        self.refreshDependencyStatus()
                    }
                    if case .importGPTK = action,
                       let winePath = response.structured?.gptkWinePath,
                       let source = response.structured?.d3dMetalSource {
                        self.backendContext = self.backendContext.overridingGPTK(
                            winePath: winePath,
                            d3dMetalSource: source
                        )
                        self.backendContext.persist()
                        self.refreshDependencyStatus()
                    }
                    self.appendLog(response.output)
                    self.rightPanelMessage = response.job?.message ?? successMessage
                    if case .killWine = action {
                        self.clearWindowsLaunchStateAfterEmergencyStop()
                        self.refreshLaunchSessions()
                    }
                    if case .installHostDependency(let dependencyID, _) = action {
                        if dependencyID == "wine-stable",
                           let winePath = response.runtimes.first(where: { $0.id == "wine-stable-11.0_1-gcenx" })?.executable {
                            self.backendContext = self.contextAdoptingWineStable(
                                winePath,
                                baseContext: self.backendContext
                            )
                            self.backendContext.persist()
                            self.rightPanelMessage = "Installed and selected managed Wine Stable 11."
                        }
                        self.refreshRuntimeCenter()
                        self.refreshWineRuntimes()
                        self.refreshDependencyStatus()
                        self.installingDependencyID = nil
                    }
                    if case .installRuntime = action {
                        self.installingRuntimeID = nil
                    }
                    if let game, actionLaunchGeneration == self.launchStateGeneration {
                        if case .sourceGameAction = action {
                            self.clearLaunchStatus(for: game)
                            if game.runner == .gog {
                                self.refreshGOGLibrary(forceRefresh: false)
                            } else {
                                self.refreshEpicLibrary(forceRefresh: false)
                            }
                        } else if case .launchSourceGame = action {
                            self.setLaunchStatus(.running, for: game, message: "Store launch request completed.")
                        } else if response.sessions.isEmpty {
                            self.setLaunchStatus(.launching, for: game, message: "Waiting for the game process...")
                        } else {
                            self.applyLaunchSessions(response.sessions)
                        }
                        if self.launchStatusByPinID[game.pinID]?.phase == .launching {
                            self.reconcileLaunchStateAfterHandoff(
                                for: game,
                                generation: actionLaunchGeneration
                            )
                        }
                    }
                    onSuccess?()
                }
            } catch {
                await MainActor.run {
                    if self.activeBackendJobs.contains(where: { $0.id == activeJobID }) {
                        let failedJob = self.makeFallbackJob(for: action, status: .failed, message: "\(self.actionDisplayName(action)) failed.")
                        self.completeBackendJob(activeJobID, finalJob: failedJob)
                    }
                    let fullError = error.localizedDescription
                    self.appendLog("Command failed:\n\(fullError)")
                    self.rightPanelMessage = "Action failed."
                    if case .installHostDependency = action {
                        self.installingDependencyID = nil
                    }
                    if case .installRuntime = action {
                        self.installingRuntimeID = nil
                    }
                    if case .setupCompatibilityProfile(let profile) = action {
                        self.provisioningProfiles.remove(profile)
                    }
                    if let game, actionLaunchGeneration == self.launchStateGeneration {
                        self.setLaunchStatus(.failed, for: game, message: self.launchFailureSummary(from: fullError))
                    }
                    if self.shouldPresentFailureAlert(for: action) {
                        let alert = NSAlert()
                        alert.messageText = "Action failed"
                        alert.informativeText = self.launchFailureSummary(from: fullError)
                        alert.addButton(withTitle: "Open Full Error")
                        alert.addButton(withTitle: "OK")
                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            self.selectedLogTitle = "Action Error"
                            self.selectedLogEntries = [
                                DisplayedLogEntry(
                                    id: "launch-error",
                                    title: "Action Error",
                                    text: fullError
                                ),
                            ]
                            self.selectedLogEntryID = "launch-error"
                            self.selectedLogText = fullError
                            self.isShowingLogViewer = true
                        }
                    }
                }
            }
        }
    }

    private func reconcileDetachedJob(_ job: BackendJob, fallbackActiveJobID: String, action: BackendAction) {
        if shouldTreatStartedResponseAsFinished(for: action), job.status == .started {
            activeBackendJobs.removeAll { $0.id == fallbackActiveJobID || $0.id == job.id || $0.action == job.action }
            let completedJob = BackendJob(
                id: job.id,
                action: job.action,
                status: .completed,
                message: job.message,
                progress: 1.0,
                completedSteps: job.completedSteps,
                totalSteps: job.totalSteps
            )
            recordBackendJob(completedJob)
            return
        }

        if activeBackendJobs.contains(where: { $0.id == fallbackActiveJobID }) {
            completeBackendJob(fallbackActiveJobID, finalJob: job)
        }
    }

    private func shouldTreatStartedResponseAsFinished(for action: BackendAction) -> Bool {
        switch action {
        case .openSteam, .launchGame, .smartLaunchGame, .debugGame, .debugExecutable:
            return true
        default:
            return false
        }
    }

    private func launchWineGame(_ game: LibraryGame) {
        guard let executable = resolvedLaunchURL(for: game) else {
            rightPanelMessage = "Set a launch executable for \(game.title) first."
            editingGamePinID = game.pinID
            isShowingGameSettings = true
            return
        }

        let settings = settings(for: game)
        let args = parseLaunchArguments(settings.launchArguments)
        let env = parseEnvironmentOverrides(settings.environmentText)
        let cwd = normalizedOptionalPath(settings.workingDirectoryPath)
        let context = effectiveContext(for: game)
        let backend = game.status.localizedCaseInsensitiveContains("installer") ? GraphicsBackendOption.none : settings.graphicsBackend
        executeDetached(
            .debugExecutable(
                path: executable.path,
                gameArgs: args,
                graphicsBackend: backend,
                workingDirectory: cwd,
                environment: env,
                wineDebug: "-all",
                standalone: true
            ),
            successMessage: game.status.localizedCaseInsensitiveContains("installer") ? "Opened installer \(game.title)." : "Launched \(game.title).",
            context: context,
            game: game
        )
    }

    private func resolvedLaunchURL(for game: LibraryGame) -> URL? {
        let settings = settings(for: game)
        let launchPath = settings.launchExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !launchPath.isEmpty {
            return URL(fileURLWithPath: launchPath)
        }
        return game.launchURL
    }

    private func parseLaunchArguments(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private func parseEnvironmentOverrides(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.contains("=") }
    }

    private func normalizedOptionalPath(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func logsDirectoryURL(for runner: RunnerKind, context: BackendContext) -> URL {
        let appSupport = appSupportRootURL

        if let externalPrefix = context.externalPrefix, !externalPrefix.isEmpty {
            let resolved = URL(fileURLWithPath: externalPrefix).standardizedFileURL.path
            let digest = Insecure.SHA1.hash(data: Data(resolved.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return appSupport
                .appendingPathComponent("external-prefixes", isDirectory: true)
                .appendingPathComponent(String(digest.prefix(12)), isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
        }

        return appSupport
            .appendingPathComponent("bottles", isDirectory: true)
            .appendingPathComponent(context.bottleName, isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    private func currentPrefixURL(for context: BackendContext) -> URL? {
        if let externalPrefix = context.externalPrefix, !externalPrefix.isEmpty {
            return URL(fileURLWithPath: externalPrefix)
        }

        return appSupportRootURL
            .appendingPathComponent("bottles", isDirectory: true)
            .appendingPathComponent(context.bottleName, isDirectory: true)
            .appendingPathComponent("prefix", isDirectory: true)
    }

    private func effectiveBackendContext(_ context: BackendContext? = nil) -> BackendContext {
        let baseContext = context ?? backendContext
        return baseContext.overridingRuntimeSources(
            dxmtSource: managedRuntimeSource(kind: "dxmt"),
            dxvkSource: managedRuntimeSource(kind: "dxvk"),
            d3dMetalWinePath: managedRuntimeExecutable(id: "wine-sikarugir-10.0-r6")
        )
    }

    @discardableResult
    private func applyManagedRuntimeSourceDefaults() -> Bool {
        let managedDXMT = managedRuntimeSource(kind: "dxmt")
        let managedDXVK = managedRuntimeSource(kind: "dxvk")
        let managedD3DMetalWine = managedRuntimeExecutable(id: "wine-sikarugir-10.0-r6")
        let nextContext = backendContext.overridingRuntimeSources(
            dxmtSource: managedDXMT,
            dxvkSource: managedDXVK,
            d3dMetalWinePath: managedD3DMetalWine
        )

        guard nextContext.dxmtSource != backendContext.dxmtSource
            || nextContext.dxvkSource != backendContext.dxvkSource
            || nextContext.gptkWinePath != backendContext.gptkWinePath else {
            return false
        }

        backendContext = nextContext
        backendContext.persist()

        var changes: [String] = []
        if let managedDXMT, managedDXMT == backendContext.dxmtSource {
            changes.append("DXMT: \(managedDXMT)")
        }
        if let managedDXVK, managedDXVK == backendContext.dxvkSource {
            changes.append("DXVK: \(managedDXVK)")
        }
        if let managedD3DMetalWine, managedD3DMetalWine == backendContext.gptkWinePath {
            changes.append("D3DMetal Wine: \(managedD3DMetalWine)")
        }
        if changes.isEmpty == false {
            appendLog("Runtime Center defaults updated.\n\(changes.joined(separator: "\n"))")
        }
        return true
    }

    private func managedRuntimeSource(kind: String) -> String? {
        let fileManager = FileManager.default
        let preferredIDs: [String] = switch kind {
        case "dxmt":
            ["dxmt-0.71", "dxmt-0.70"]
        case "dxvk":
            ["dxvk-macos-1.10.3-20230507-repack"]
        default:
            []
        }

        for runtimeID in preferredIDs {
            if let runtime = installedManagedRuntimes.first(where: {
                $0.id == runtimeID && ($0.kind == kind || (kind == "dxvk" && $0.kind == "dxvk-macos"))
            }),
               let path = runtime.path,
               fileManager.fileExists(atPath: path) {
                return path
            }
        }

        let runtimeRoot = appSupportRootURL
            .appendingPathComponent("runtimes", isDirectory: true)
            .appendingPathComponent(kind, isDirectory: true)

        for runtimeID in preferredIDs {
            let runtimeURL = runtimeRoot.appendingPathComponent(runtimeID, isDirectory: true)
            if fileManager.fileExists(atPath: runtimeURL.path) {
                return runtimeURL.path
            }
        }

        if kind == "dxmt" {
            return nil
        }

        if let runtime = installedManagedRuntimes.first(where: { $0.kind == kind }),
           let path = runtime.path,
           fileManager.fileExists(atPath: path) {
            return path
        }

        return nil
    }

    private func managedRuntimeExecutable(id: String) -> String? {
        let fileManager = FileManager.default
        if let runtime = installedManagedRuntimes.first(where: { $0.id == id }),
           let executable = runtime.executable,
           fileManager.isExecutableFile(atPath: executable) {
            return executable
        }
        return nil
    }

    private func loadDllOverrides(from prefixURL: URL) -> [String] {
        let userReg = prefixURL.appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: userReg, encoding: .utf8) else { return [] }

        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        var inSection = false
        var overrides: [String] = []
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                let header = #"[Software\\Wine\\DllOverrides]"#
                inSection = line == header || line.hasPrefix(header + " ")
                continue
            }
            guard inSection, line.hasPrefix("\""), line.contains("\"=\"") else { continue }
            let parts = line.components(separatedBy: "\"=\"")
            guard parts.count == 2 else { continue }
            let key = parts[0].replacingOccurrences(of: "\"", with: "")
            let value = parts[1].replacingOccurrences(of: "\"", with: "")
            overrides.append("\(key)=\(value)")
        }
        return overrides.sorted()
    }

    private func shouldPresentFailureAlert(for action: BackendAction) -> Bool {
        switch action {
        case .openSteam, .launchGame, .debugGame, .debugExecutable:
            return false
        default:
            return true
        }
    }

    private func managedWineRuntimesRoot() -> URL {
        appSupportRootURL
            .appendingPathComponent("runtimes", isDirectory: true)
    }

    private func uniqueManagedRuntimeDestination(for sourceURL: URL) -> URL {
        let root = managedWineRuntimesRoot()
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        var candidate = root.appendingPathComponent(sourceURL.lastPathComponent)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let suffix = "\(baseName) \(index)"
            candidate = root.appendingPathComponent(ext.isEmpty ? suffix : "\(suffix).\(ext)")
            index += 1
        }
        return candidate
    }

    private func detectWineExecutable(in appURL: URL) -> String? {
        let candidates = [
            appURL.appendingPathComponent("Contents/Resources/wine/bin/wine64"),
            appURL.appendingPathComponent("Contents/Resources/wine/bin/wine"),
            appURL.appendingPathComponent("Contents/MacOS/wine64"),
            appURL.appendingPathComponent("Contents/MacOS/wine"),
        ]

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })?.path
    }

    private func scanWineRuntimes() -> [WineRuntimeRecord] {
        let fileManager = FileManager.default
        var records: [WineRuntimeRecord] = []
        var seenPaths = Set<String>()

        func appendExecutable(_ path: String, name: String, kind: WineRuntimeRecord.SourceKind, containerPath: String?, isManaged: Bool) {
            guard fileManager.isExecutableFile(atPath: path) else { return }
            guard seenPaths.insert(path).inserted else { return }
            records.append(
                WineRuntimeRecord(
                    id: "\(kind.rawValue):\(containerPath ?? path)",
                    name: name,
                    executablePath: path,
                    sourceKind: kind,
                    containerPath: containerPath,
                    isManaged: isManaged
                )
            )
        }

        let appCandidates = [
            "/Applications/Wine Stable.app",
            "/Applications/Wine Devel.app",
            "/Applications/Wine Staging.app",
            "\(NSHomeDirectory())/Applications/Wine Stable.app",
            "\(NSHomeDirectory())/Applications/Wine Devel.app",
            "\(NSHomeDirectory())/Applications/Wine Staging.app",
        ]

        for appPath in appCandidates {
            let appURL = URL(fileURLWithPath: appPath)
            if let executable = detectWineExecutable(in: appURL) {
                appendExecutable(executable, name: appURL.deletingPathExtension().lastPathComponent, kind: .detected, containerPath: appURL.path, isManaged: false)
            }
        }

        let runtimesRoot = managedWineRuntimesRoot()
        if let contents = try? fileManager.contentsOfDirectory(at: runtimesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for item in contents where item.pathExtension == "app" {
                if let executable = detectWineExecutable(in: item) {
                    appendExecutable(executable, name: item.deletingPathExtension().lastPathComponent, kind: .importedApp, containerPath: item.path, isManaged: true)
                }
            }
        }

        for stored in wineRuntimes {
            appendExecutable(stored.executablePath, name: stored.name, kind: stored.sourceKind, containerPath: stored.containerPath, isManaged: stored.isManaged)
        }

        return records
    }

    private func loadWineRuntimes() -> [WineRuntimeRecord] {
        guard
            let data = UserDefaults.standard.data(forKey: LibraryStorageKey.wineRuntimes),
            let stored = try? JSONDecoder().decode([WineRuntimeRecord].self, from: data)
        else {
            return []
        }
        return stored
    }

    private func persistWineRuntimes() {
        if let data = try? JSONEncoder().encode(wineRuntimes) {
            UserDefaults.standard.set(data, forKey: LibraryStorageKey.wineRuntimes)
        }
    }

    private func underlyingGame(for game: LibraryGame) -> LibraryGame? {
        allLibraryGames.first(where: { $0.pinID == game.pinID })
    }

    private func enrichedGame(_ game: LibraryGame) -> LibraryGame {
        let settings = settings(for: game)
        let bannerURL = customBannerURL(for: settings) ?? game.bannerURL
        let statsText = composedStatsText(for: game)

        return LibraryGame(
            id: game.id,
            pinID: game.pinID,
            backendID: game.backendID,
            title: game.title,
            runner: game.runner,
            capsule: game.capsule,
            status: game.status,
            statsText: statsText,
            bannerURL: bannerURL,
            installURL: game.installURL,
            launchURL: game.launchURL,
            storeURL: game.storeURL
        )
    }

    private func customBannerURL(for settings: StoredGameSettings) -> URL? {
        let path = settings.customBannerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func matchesSourceFilter(_ game: LibraryGame) -> Bool {
        guard selectedRunner == .home else { return true }
        switch sourceFilter {
        case .all:
            return true
        case .mac:
            return game.runner == .mac
        case .steam:
            return game.runner == .steam
        case .wine:
            return game.runner == .wine
        case .epic:
            return game.runner == .epic
        case .gog:
            return game.runner == .gog
        }
    }

    private func matchesSearch(_ game: LibraryGame) -> Bool {
        guard !searchText.isEmpty else { return true }

        let settings = settings(for: game)
        let tokens = [
            game.title,
            game.runner.rawValue,
            game.status,
            game.backendID ?? "",
            game.statsText ?? "",
            game.installURL?.path ?? "",
            game.launchURL?.path ?? "",
            settings.collection.rawValue,
            settings.assignedBottleName,
            settings.assignedExternalPrefix,
            settings.launchExecutablePath,
            settings.workingDirectoryPath,
        ]

        return tokens.contains { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private func sortGames(_ games: [LibraryGame]) -> [LibraryGame] {
        switch sortOption {
        case .manual:
            return games
        case .title:
            return games.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .size:
            return games.sorted { numericSizeValue(for: $0.statsText) > numericSizeValue(for: $1.statsText) }
        case .recent:
            return games.sorted { (steamMetadata(for: $0)?.lastPlayed ?? .distantPast) > (steamMetadata(for: $1)?.lastPlayed ?? .distantPast) }
        }
    }

    private func numericSizeValue(for statsText: String?) -> Double {
        guard let statsText else { return 0 }
        let parts = statsText.split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let sizePart = parts.first else { return 0 }
        let scanner = Scanner(string: sizePart)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = sizePart.replacingOccurrences(of: "[0-9. ]", with: "", options: .regularExpression).lowercased()
        switch unit {
        case "kb":
            return value * 1_000
        case "mb":
            return value * 1_000_000
        case "gb":
            return value * 1_000_000_000
        case "tb":
            return value * 1_000_000_000_000
        default:
            return value
        }
    }

    private func composedStatsText(for game: LibraryGame) -> String? {
        var parts: [String] = []
        if let size = game.statsText, !size.isEmpty {
            parts.append(size)
        }

        if let metadata = steamMetadata(for: game) {
            if let playtimeMinutes = metadata.playtimeMinutes, playtimeMinutes > 0 {
                let hours = Double(playtimeMinutes) / 60
                parts.append(String(format: "%.1f h", hours))
            }
            if let lastPlayed = metadata.lastPlayed {
                parts.append(relativeDateText(for: lastPlayed))
            }
        }

        let collection = settings(for: game).collection
        if collection != .none {
            parts.append(collection.rawValue)
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    func installSizeText(for game: LibraryGame) -> String? {
        let stats = game.statsText ?? composedStatsText(for: game)
        let parts = stats?.split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        return parts.first
    }

    func effectiveGraphicsOverrides(
        for game: LibraryGame,
        graphicsBackend: GraphicsBackendOption,
        assignedBottleName: String,
        assignedExternalPrefix: String,
        environmentText: String
    ) -> EffectiveGraphicsOverrides {
        let context = backendContext.overridingTarget(
            bottleName: assignedBottleName,
            externalPrefix: assignedExternalPrefix
        )
        let prefixURL = currentPrefixURL(for: context)
        let registryOverrides = prefixURL.map(loadDllOverrides(from:)) ?? []

        let launchOverrides: String? = switch graphicsBackend {
        case .dxvk:
            "d3d11=n;d3d10core=n"
        case .dxmt:
            "dxgi=n,b;d3d11=n,b;d3d10core=n,b;winemetal=n,b"
        case .d3dmetal:
            "dxgi=n,b;d3d11=n,b;d3d12=n,b;atidxx64=n,b;nvapi64=n,b;nvngx=n,b"
        case .none:
            nil
        }

        let warnings = parseEnvironmentOverrides(environmentText)
            .filter { $0.uppercased().hasPrefix("WINEDLLOVERRIDES=") || $0.uppercased().hasPrefix("DXVK_") || $0.uppercased().hasPrefix("D3DMETAL_") || $0.uppercased().hasPrefix("MESA_") }
        let compatibilityWarnings: [String] = if graphicsBackend == .dxvk {
            ["DXVK-macOS is best for Vulkan-friendly D3D10/11 games. It intentionally does not replace DXGI or D3D9; use DXMT when a title behaves better with Metal translation."]
        } else {
            []
        }

        let targetLabel: String
        if let externalPrefix = context.externalPrefix, !externalPrefix.isEmpty {
            targetLabel = "External prefix"
        } else {
            targetLabel = "Managed bottle \(context.bottleName)"
        }

        return EffectiveGraphicsOverrides(
            targetLabel: targetLabel,
            prefixPath: prefixURL?.path ?? "Prefix could not be resolved.",
            graphicsBackend: graphicsBackend,
            registryOverrides: registryOverrides,
            launchOverrides: launchOverrides,
            compatibilityWarnings: compatibilityWarnings,
            environmentWarnings: warnings
        )
    }

    func explicitMetadataRows(for game: LibraryGame) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        let settings = settings(for: game)

        if let backendID = game.backendID, !backendID.isEmpty {
            rows.append(("App ID", backendID))
        }

        if let installURL = game.installURL {
            rows.append(("Install Location", installURL.path))
        }

        if let launchURL = game.launchURL {
            rows.append(("Launch Target", launchURL.path))
        }

        let settingsExecutable = settings.launchExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !settingsExecutable.isEmpty {
            rows.append(("Override Executable", settingsExecutable))
        }

        let architecturePath = settingsExecutable.isEmpty ? game.launchURL?.path : settingsExecutable
        if let architecturePath, let architecture = windowsExecutableArchitecture(atPath: architecturePath) {
            rows.append(("Executable Architecture", architecture))
        }

        let workingDirectory = settings.workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workingDirectory.isEmpty {
            rows.append(("Working Directory", workingDirectory))
        }

        let launchArguments = settings.launchArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if !launchArguments.isEmpty {
            rows.append(("Launch Arguments", launchArguments))
        }

        let environment = settings.environmentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !environment.isEmpty {
            rows.append(("Environment", environment))
        }

        if game.runner == .steam || game.runner == .wine {
            rows.append(("Graphics Backend", settings.graphicsBackend.rawValue))
        }

        return rows
    }

    func windowsExecutableArchitecture(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]), data.count >= 64 else {
            return nil
        }
        guard data[0] == 0x4d, data[1] == 0x5a else { return nil }
        let peOffset = Int(data[0x3c])
            | (Int(data[0x3d]) << 8)
            | (Int(data[0x3e]) << 16)
            | (Int(data[0x3f]) << 24)
        guard peOffset >= 0, peOffset + 6 <= data.count,
              data[peOffset] == 0x50, data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0, data[peOffset + 3] == 0 else {
            return nil
        }
        let machine = UInt16(data[peOffset + 4]) | (UInt16(data[peOffset + 5]) << 8)
        switch machine {
        case 0x014c:
            return "32-bit x86 (WoW64)"
        case 0x8664:
            return "64-bit x86-64"
        default:
            return "Unsupported or unknown PE architecture"
        }
    }

    var selectedLogEntry: DisplayedLogEntry? {
        if let selectedLogEntryID {
            return selectedLogEntries.first(where: { $0.id == selectedLogEntryID })
        }
        return selectedLogEntries.first
    }

    private func launchFailureSummary(from text: String) -> String {
        let noisyPrefixes = [
            "[mvk-info]",
            "VK_",
            "The following ",
            "Launching ",
            "[Note] ",
        ]

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in !noisyPrefixes.contains(where: { line.hasPrefix($0) }) }

        let tail = lines.suffix(10)
        if tail.isEmpty {
            return "The launch failed. Use “Open Full Error” to inspect the complete output."
        }
        return tail.joined(separator: "\n")
    }

    func playtimeText(for game: LibraryGame) -> String? {
        guard let minutes = steamMetadata(for: game)?.playtimeMinutes, minutes > 0 else { return nil }
        let hours = Double(minutes) / 60
        return String(format: "%.1f hours", hours)
    }

    func lastPlayedText(for game: LibraryGame) -> String? {
        guard let date = steamMetadata(for: game)?.lastPlayed else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func steamMetadata(for game: LibraryGame) -> SteamLocalMetadata? {
        guard let appid = game.backendID else { return nil }
        return steamMetadataByAppID[appid]
    }

    private func relativeDateText(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Played \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func applySteamOrder(to games: [LibraryGame]) -> [LibraryGame] {
        let byID = Dictionary(uniqueKeysWithValues: games.map { ($0.pinID, $0) })
        let ordered = steamOrderIDs.compactMap { byID[$0] }
        let unordered = games.filter { !steamOrderIDs.contains($0.pinID) }
        let merged = ordered + unordered
        steamOrderIDs = merged.map(\.pinID)
        persistSteamOrder()
        return merged
    }

    private func reorderGames(_ games: inout [LibraryGame], draggedID: String, targetID: String) {
        guard
            let fromIndex = games.firstIndex(where: { $0.pinID == draggedID }),
            let toIndex = games.firstIndex(where: { $0.pinID == targetID })
        else {
            return
        }

        let moved = games.remove(at: fromIndex)
        games.insert(moved, at: toIndex)
    }

    private func reorderIDs(_ ids: inout [String], draggedID: String, targetID: String) {
        guard
            let fromIndex = ids.firstIndex(of: draggedID),
            let toIndex = ids.firstIndex(of: targetID)
        else {
            return
        }

        let moved = ids.remove(at: fromIndex)
        ids.insert(moved, at: toIndex)
    }

    private func directorySizeText(_ url: URL) -> String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }

        let totalBytes: Int64
        if isDirectory.boolValue {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            totalBytes = (enumerator?.compactMap { element in
                guard let fileURL = element as? URL else { return nil }
                let values = try? fileURL.resourceValues(forKeys: keys)
                return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
            }.reduce(0, +)) ?? 0
        } else {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            totalBytes = Int64(values?.fileSize ?? 0)
        }

        guard totalBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    private func loadSteamMetadata(for games: [BackendGame]) -> [String: SteamLocalMetadata] {
        var metadata: [String: SteamLocalMetadata] = [:]
        let groupedByRoot = Dictionary(grouping: games) { game in
            steamRootURL(forInstallPath: game.installDir)
        }

        for (steamRoot, rootGames) in groupedByRoot {
            guard let steamRoot else { continue }
            let rootMetadata = parseSteamLocalMetadata(at: steamRoot, appids: rootGames.map(\.appid))
            for (appid, value) in rootMetadata {
                metadata[appid] = value
            }
        }
        return metadata
    }

    private func steamRootURL(forInstallPath installPath: String?) -> URL? {
        guard let installPath, !installPath.isEmpty else { return nil }
        let installURL = URL(fileURLWithPath: installPath)
        return installURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func parseSteamLocalMetadata(at steamRoot: URL, appids: [String]) -> [String: SteamLocalMetadata] {
        let userdataRoot = steamRoot.appendingPathComponent("userdata", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: userdataRoot, includingPropertiesForKeys: nil) else {
            return [:]
        }

        var results: [String: SteamLocalMetadata] = [:]
        for userDirectory in contents {
            let configURL = userDirectory.appendingPathComponent("config/localconfig.vdf")
            guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { continue }
            for appid in appids {
                guard let block = firstRegexGroup(#"(?s)"\#(appid)"\s*\{(.*?)\}"#, in: text) else { continue }
                var metadata = results[appid] ?? SteamLocalMetadata()
                if let playtime = regexInt(#""Playtime"\s*"(\d+)""#, in: block) ?? regexInt(#""PlaytimeForever"\s*"(\d+)""#, in: block) {
                    metadata.playtimeMinutes = max(metadata.playtimeMinutes ?? 0, playtime)
                }
                if let lastPlayedValue = regexInt(#""LastPlayed"\s*"(\d+)""#, in: block) {
                    let date = Date(timeIntervalSince1970: TimeInterval(lastPlayedValue))
                    if (metadata.lastPlayed ?? .distantPast) < date {
                        metadata.lastPlayed = date
                    }
                }
                results[appid] = metadata
            }
        }

        return results
    }

    private func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private func regexInt(_ pattern: String, in text: String) -> Int? {
        guard let string = firstRegexGroup(pattern, in: text) else { return nil }
        return Int(string)
    }
}

private extension Array where Element: Hashable {
    func uniquedPreservingOrder() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
