import Foundation

private enum BackendSettingsKey {
    static let pythonCommand = "backend.pythonCommand"
    static let winePath = "backend.winePath"
    static let dxmtSource = "backend.dxmtSource"
    static let dxvkSource = "backend.dxvkSource"
    static let d3dMetalSource = "backend.d3dMetalSource"
    static let gptkWinePath = "backend.gptkWinePath"
    static let bottleName = "backend.bottleName"
    static let externalPrefix = "backend.externalPrefix"
}

struct BackendCommand: Identifiable {
    let id = UUID()
    let title: String
    let command: String
}

struct BackendGame: Identifiable, Hashable {
    let id: String
    let appid: String
    let name: String
    let installDir: String?
}

struct BackendResponse {
    let output: String
    let games: [BackendGame]
    let runtimes: [ManagedRuntime]
    let sessions: [GameLaunchSession]
    let jobs: [BackendJob]
    let job: BackendJob?
    let structured: BackendStructuredResult?
    let steamIdentity: SteamIdentityStatus?
    let sourceGames: [BackendSourceGame]
    let sourceStatus: BackendSourceStatus?
}

struct BackendSourceGame: Identifiable {
    var id: String { libraryID }
    let source: String
    let storeID: String
    let libraryID: String
    let title: String
    let installed: Bool
    let installPath: String?
    let version: String?
    let updateAvailable: Bool
    let artURL: String?
}

struct BackendSourceStatus {
    let source: String
    let available: Bool
    let authenticated: Bool
    let client: String?
    let version: String?
    let message: String
}

struct SteamIdentityStatus {
    let available: Bool
    let sourceBottle: String?
    let capturedAt: Double?
    let accountCount: Int
    let provisionedProfiles: [String]
    let activeSteamProfiles: [String]
}

private actor BackendStreamAccumulator {
    private var buffer = Data()
    private var plainTextLines: [String] = []
    private var finalResponse: BackendResponse?

    func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    func popReadyLines() -> [String] {
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            guard let line = String(data: Data(lineData), encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            lines.append(trimmed)
        }
        return lines
    }

    func appendPlainText(_ line: String) {
        plainTextLines.append(line)
    }

    func setFinalResponse(_ response: BackendResponse) {
        finalResponse = response
    }

    func appendTrailing(_ data: Data) -> String? {
        buffer.append(data)
        guard buffer.isEmpty == false, let trailing = String(data: buffer, encoding: .utf8) else { return nil }
        buffer = Data()
        let trimmed = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func snapshot() -> (plainTextLines: [String], finalResponse: BackendResponse?) {
        (plainTextLines, finalResponse)
    }
}

private struct BackendJSONResponse: Decodable {
    let event: String?
    let ok: Bool?
    let action: String
    let status: String?
    let job_id: String?
    let message: String
    let data: BackendJSONData?
    let warnings: [String]
    let errors: [String]
}

private struct BackendJSONData: Decodable {
    let games: [BackendJSONGame]?
    let runtimes: [BackendJSONRuntime]?
    let runtime: BackendJSONRuntime?
    let checks: [BackendJSONCheck]?
    let actions: [String]?
    let steps: [BackendJSONStep]?
    let step: BackendJSONStep?
    let signals: [BackendJSONSignal]?
    let recommendations: [BackendJSONRecommendation]?
    let completed_steps: Int?
    let total_steps: Int?
    let progress: Double?
    let root: String?
    let target: String?
    let worst_status: String?
    let tail: String?
    let appid: String?
    let name: String?
    let executable: String?
    let session: BackendJSONSession?
    let sessions: [BackendJSONSession]?
    let jobs: [BackendJSONJob]?
    let gptk_wine_path: String?
    let d3dmetal_source: String?
    let available: Bool?
    let source_bottle: String?
    let captured_at: Double?
    let account_count: Int?
    let provisioned_profiles: [String]?
    let active_steam_profiles: [String]?
    let source_games: [BackendJSONSourceGame]?
    let source_status: BackendJSONSourceStatus?
}

private struct BackendJSONSourceGame: Decodable {
    let source: String
    let store_id: String
    let library_id: String
    let title: String
    let installed: Bool
    let install_path: String?
    let version: String?
    let update_available: Bool
    let art_url: String?
}

private struct BackendJSONSourceStatus: Decodable {
    let source: String
    let available: Bool
    let authenticated: Bool
    let client: String?
    let version: String?
    let message: String
}

private struct BackendJSONJob: Decodable {
    let job_id: String
    let action: String
    let status: String
    let message: String
    let progress: Double?
    let completed_steps: Int?
    let total_steps: Int?
}

private struct BackendJSONSession: Decodable {
    let session_id: String
    let appid: String?
    let game: String
    let status: String
    let strategy: String
    let graphics_backend: String
    let profile_id: String
    let bottle: String
    let prefix: String
    let executable: String?
    let install_dir: String?
    let pids: [Int]
    let message: String
}

private struct BackendJSONRuntime: Decodable {
    let id: String
    let name: String
    let version: String
    let kind: String
    let source: String?
    let download_url: String?
    let sha256: String?
    let archive_type: String?
    let install_layout: String?
    let license: String?
    let notes: String?
    let installed: Bool?
    let path: String?
    let executable: String?
    let installed_at: Double?
}

private struct BackendJSONGame: Decodable {
    let appid: String
    let name: String
    let install_dir: String?
}

private struct BackendJSONCheck: Decodable {
    let status: String
    let name: String
    let detail: String
    let required: Bool?
    let fix: String?
}

private struct BackendJSONStep: Decodable {
    let name: String
    let status: String
}

private struct BackendJSONSignal: Decodable {
    let key: String
    let detail: String
    let path: String
}

private struct BackendJSONRecommendation: Decodable {
    let verb: String
    let reason: String
}

struct BackendContext {
    let repoRoot: URL
    let pythonCommand: String
    let winePath: String
    let dxmtSource: String
    let dxvkSource: String
    let d3dMetalSource: String
    let gptkWinePath: String
    let bottleName: String
    let externalPrefix: String?

    static func `default`() -> BackendContext {
        NASEDataPaths.migrateLegacyDataIfNeeded()
        let defaults = UserDefaults.standard
        let sourceURL = URL(fileURLWithPath: #filePath)
        let sourceRepoRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bundledBackend = Bundle.main.resourceURL?.appendingPathComponent("Backend", isDirectory: true)
        let repoRoot: URL
        if let bundledBackend,
           FileManager.default.fileExists(atPath: bundledBackend.appendingPathComponent("mysteamwine.py").path) {
            repoRoot = bundledBackend
        } else {
            repoRoot = sourceRepoRoot
        }
        let bundledPython = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Frameworks/Python.framework/bin/python3")
        let storedPython = defaults.string(forKey: BackendSettingsKey.pythonCommand)
        let bundledPythonIsAvailable = FileManager.default.isExecutableFile(atPath: bundledPython.path)
        let defaultPython: String
        if bundledPythonIsAvailable, storedPython == nil || storedPython == "python3" {
            defaultPython = bundledPython.path
        } else {
            defaultPython = storedPython ?? "python3"
        }

        return BackendContext(
            repoRoot: repoRoot,
            pythonCommand: defaultPython,
            winePath: defaults.string(forKey: BackendSettingsKey.winePath) ?? "/opt/homebrew/bin/wine",
            dxmtSource: defaults.string(forKey: BackendSettingsKey.dxmtSource) ?? "\(NSHomeDirectory())/Downloads/dxmt",
            dxvkSource: defaults.string(forKey: BackendSettingsKey.dxvkSource) ?? "\(NSHomeDirectory())/Downloads/dxvk",
            d3dMetalSource: defaults.string(forKey: BackendSettingsKey.d3dMetalSource) ?? Self.detectedD3DMetalSource(),
            gptkWinePath: defaults.string(forKey: BackendSettingsKey.gptkWinePath) ?? Self.detectedGPTKWinePath(),
            bottleName: defaults.string(forKey: BackendSettingsKey.bottleName) ?? "Default",
            externalPrefix: defaults.string(forKey: BackendSettingsKey.externalPrefix)
        )
    }

    private static func detectedGPTKWinePath() -> String {
        let candidates = [
            "/opt/local/libexec/game-porting-toolkit/bin/wine",
            "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
    }

    private static func detectedD3DMetalSource() -> String {
        let candidates = [
            "/opt/local/libexec/d3dmetal",
            "\(NSHomeDirectory())/Downloads/d3dmetal",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    var targetArguments: [String] {
        if let externalPrefix, !externalPrefix.isEmpty {
            return ["--prefix", externalPrefix]
        }
        return ["--bottle", bottleName]
    }

    func persist() {
        let defaults = UserDefaults.standard
        defaults.set(pythonCommand, forKey: BackendSettingsKey.pythonCommand)
        defaults.set(winePath, forKey: BackendSettingsKey.winePath)
        defaults.set(dxmtSource, forKey: BackendSettingsKey.dxmtSource)
        defaults.set(dxvkSource, forKey: BackendSettingsKey.dxvkSource)
        defaults.set(d3dMetalSource, forKey: BackendSettingsKey.d3dMetalSource)
        defaults.set(gptkWinePath, forKey: BackendSettingsKey.gptkWinePath)
        defaults.set(bottleName, forKey: BackendSettingsKey.bottleName)
        if let externalPrefix, !externalPrefix.isEmpty {
            defaults.set(externalPrefix, forKey: BackendSettingsKey.externalPrefix)
        } else {
            defaults.removeObject(forKey: BackendSettingsKey.externalPrefix)
        }
    }

    func overridingTarget(bottleName: String?, externalPrefix: String?) -> BackendContext {
        let cleanedBottle = (bottleName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPrefix = (externalPrefix ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return BackendContext(
            repoRoot: repoRoot,
            pythonCommand: pythonCommand,
            winePath: winePath,
            dxmtSource: dxmtSource,
            dxvkSource: dxvkSource,
            d3dMetalSource: d3dMetalSource,
            gptkWinePath: gptkWinePath,
            bottleName: cleanedBottle.isEmpty ? self.bottleName : cleanedBottle,
            externalPrefix: cleanedPrefix.isEmpty ? nil : cleanedPrefix
        )
    }

    func overridingPythonCommand(_ command: String) -> BackendContext {
        BackendContext(
            repoRoot: repoRoot,
            pythonCommand: command,
            winePath: winePath,
            dxmtSource: dxmtSource,
            dxvkSource: dxvkSource,
            d3dMetalSource: d3dMetalSource,
            gptkWinePath: gptkWinePath,
            bottleName: bottleName,
            externalPrefix: externalPrefix
        )
    }

    func overridingGPTK(winePath: String, d3dMetalSource: String) -> BackendContext {
        BackendContext(
            repoRoot: repoRoot,
            pythonCommand: pythonCommand,
            winePath: self.winePath,
            dxmtSource: dxmtSource,
            dxvkSource: dxvkSource,
            d3dMetalSource: d3dMetalSource,
            gptkWinePath: winePath,
            bottleName: bottleName,
            externalPrefix: externalPrefix
        )
    }

    func overridingRuntimeSources(
        dxmtSource: String? = nil,
        dxvkSource: String? = nil,
        d3dMetalWinePath: String? = nil
    ) -> BackendContext {
        let cleanedDXMT = (dxmtSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedDXVK = (dxvkSource ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedD3DMetalWine = (d3dMetalWinePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return BackendContext(
            repoRoot: repoRoot,
            pythonCommand: pythonCommand,
            winePath: winePath,
            dxmtSource: cleanedDXMT.isEmpty ? self.dxmtSource : cleanedDXMT,
            dxvkSource: cleanedDXVK.isEmpty ? self.dxvkSource : cleanedDXVK,
            d3dMetalSource: d3dMetalSource,
            gptkWinePath: cleanedD3DMetalWine.isEmpty ? gptkWinePath : cleanedD3DMetalWine,
            bottleName: bottleName,
            externalPrefix: externalPrefix
        )
    }

    func compatibilityContext(
        for graphicsBackend: GraphicsBackendOption,
        appSupportRoot: URL? = nil
    ) -> BackendContext {
        let suffix = "-\(graphicsBackend.bottleSuffix)"
        let profileBottle = bottleName.hasSuffix(suffix) ? bottleName : "\(bottleName)\(suffix)"
        let defaultWinePath = (graphicsBackend == .d3dmetal || graphicsBackend == .dxvk) ? gptkWinePath : winePath
        let supportRoot = appSupportRoot
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NASE", isDirectory: true)
        let manifestURL = supportRoot
            .appendingPathComponent("bottles", isDirectory: true)
            .appendingPathComponent(profileBottle, isDirectory: true)
            .appendingPathComponent("compatibility-profile.json")
        let boundWinePath: String? = {
            guard
                let data = try? Data(contentsOf: manifestURL),
                let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let profile = manifest["profile"] as? [String: Any],
                profile["id"] as? String == graphicsBackend.compatibilityProfileID,
                let path = manifest["wine_path"] as? String,
                FileManager.default.isExecutableFile(atPath: path)
            else { return nil }
            return path
        }()
        return BackendContext(
            repoRoot: repoRoot,
            pythonCommand: pythonCommand,
            winePath: boundWinePath ?? defaultWinePath,
            dxmtSource: dxmtSource,
            dxvkSource: dxvkSource,
            d3dMetalSource: d3dMetalSource,
            gptkWinePath: gptkWinePath,
            bottleName: profileBottle,
            externalPrefix: nil
        )
    }
}

enum BackendAction {
    case sourceStatus(source: String)
    case listSourceGames(source: String, forceRefresh: Bool)
    case epicAuthenticate(code: String)
    case epicLogout
    case gogAuthenticate(code: String)
    case gogLogout
    case sourceGameAction(source: String, gameID: String, operation: String, confirm: Bool = false)
    case launchSourceGame(source: String, gameID: String, graphicsBackend: GraphicsBackendOption)
    case steamIdentityStatus
    case captureSteamIdentity(sourceBottle: String)
    case provisionSteamIdentity(targetBottle: String)
    case forgetSteamIdentity
    case signOutSteamProfile(targetBottle: String)
    case listJobs
    case cancelJob(id: String)
    case dependencyStatus
    case discoverD3DMetal
    case importGPTK(confirmLicense: Bool)
    case installHostDependency(id: String, confirmLicense: Bool)
    case setupCompatibilityProfile(GraphicsBackendOption)
    case repairCompatibilityProfile(GraphicsBackendOption)
    case resetCompatibilityProfile(GraphicsBackendOption)
    case resetGameOverlay(gameID: String)
    case attachSteamLibraries(GraphicsBackendOption)
    case setupMetal
    case doctor
    case doctorFix
    case runWinetricks(verbs: [String], interactive: Bool = false)
    case installDXMT
    case installDXVK
    case installD3DMetal
    case openWinecfg
    case killWine
    case listSessions
    case stopGame(sessionID: String)
    case openSteam
    case listGames
    case listRuntimeCatalog
    case listInstalledRuntimes
    case installRuntime(id: String)
    case launchGame(appid: String)
    case smartLaunchGame(appid: String, graphicsBackend: GraphicsBackendOption = .dxmt)
    case debugGame(
        appid: String,
        gameArgs: [String] = [],
        graphicsBackend: GraphicsBackendOption = .dxmt,
        workingDirectory: String? = nil,
        environment: [String] = [],
        wineDebug: String = "+timestamp,+seh,+loaddll",
        legacyDirectXSource: String? = nil
    )
    case debugExecutable(
        path: String,
        gameArgs: [String] = [],
        graphicsBackend: GraphicsBackendOption = .dxmt,
        workingDirectory: String? = nil,
        environment: [String] = [],
        wineDebug: String = "+timestamp,+seh,+loaddll",
        legacyDirectXSource: String? = nil,
        standalone: Bool = false
    )
}

enum BackendBridgeError: LocalizedError {
    case invalidUTF8
    case missingSelectedGame

    var errorDescription: String? {
        switch self {
        case .invalidUTF8:
            return "Backend output could not be decoded as UTF-8."
        case .missingSelectedGame:
            return "Select a Steam game first."
        }
    }
}

enum BackendBridge {
    static func commands(for runner: RunnerKind, context: BackendContext, selectedGame: LibraryGame?) -> [BackendCommand] {
        switch runner {
        case .home:
            return [
                BackendCommand(title: "Pinned Library", command: "Pin apps from Steam, macOS, or Wine to keep them on Home."),
            ]
        case .steam:
            var commands = [
                BackendCommand(title: "Setup Metal", command: preview(.setupMetal, context: context)),
                BackendCommand(title: "Doctor", command: preview(.doctor, context: context)),
                BackendCommand(title: "Wine Configuration", command: preview(.openWinecfg, context: context)),
                BackendCommand(title: "Open Steam", command: preview(.openSteam, context: context)),
                BackendCommand(title: "Refresh Games", command: preview(.listGames, context: context)),
            ]
            if let selectedGame, selectedGame.runner == .steam {
                commands.append(
                    BackendCommand(
                        title: "Launch Selected",
                        command: preview(.launchGame(appid: selectedGame.backendID ?? ""), context: context)
                    )
                )
            }
            return commands
        case .wine:
            return [
                BackendCommand(title: "Doctor", command: preview(.doctor, context: context)),
                BackendCommand(title: "Doctor + Fix", command: preview(.doctorFix, context: context)),
                BackendCommand(title: "Wine Configuration", command: preview(.openWinecfg, context: context)),
                BackendCommand(title: "Setup Metal", command: preview(.setupMetal, context: context)),
            ]
        case .mac:
            return [
                BackendCommand(title: "Native Library", command: "Native scanning is not wired yet."),
            ]
        case .epic:
            return [
                BackendCommand(title: "Epic Status", command: preview(.sourceStatus(source: "epic"), context: context)),
                BackendCommand(title: "Refresh Epic Library", command: preview(.listSourceGames(source: "epic", forceRefresh: true), context: context)),
            ]
        case .gog:
            return [
                BackendCommand(title: "GOG Status", command: preview(.sourceStatus(source: "gog"), context: context)),
                BackendCommand(title: "Refresh GOG Library", command: preview(.listSourceGames(source: "gog", forceRefresh: true), context: context)),
            ]
        }
    }

    static func preview(_ action: BackendAction, context: BackendContext) -> String {
        ([context.pythonCommand, "mysteamwine.py"] + arguments(for: action, context: context))
            .joined(separator: " ")
    }

    static func preflight(context: BackendContext) async -> Bool {
        let script = context.repoRoot.appendingPathComponent("mysteamwine.py")
        guard FileManager.default.fileExists(atPath: script.path) else { return false }
        let process = Process()
        if context.pythonCommand.contains("/") {
            guard FileManager.default.isExecutableFile(atPath: context.pythonCommand) else { return false }
            process.executableURL = URL(fileURLWithPath: context.pythonCommand)
            process.arguments = ["-c", "import sys; raise SystemExit(0 if (3, 10) <= sys.version_info < (3, 15) else 1)"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [
                context.pythonCommand,
                "-c",
                "import sys; raise SystemExit(0 if (3, 10) <= sys.version_info < (3, 15) else 1)",
            ]
        }
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]
        ) { _, appValue in appValue }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func execute(_ action: BackendAction, context: BackendContext) async throws -> BackendResponse {
        try await executeStreaming(action, context: context) { _ in }
    }

    static func executeStreaming(
        _ action: BackendAction,
        context: BackendContext,
        onUpdate: @escaping @Sendable (BackendStreamUpdate) async -> Void
    ) async throws -> BackendResponse {
        let process = Process()
        process.currentDirectoryURL = context.repoRoot
        if context.pythonCommand.contains("/") {
            process.executableURL = URL(fileURLWithPath: context.pythonCommand)
            process.arguments = ["mysteamwine.py"] + arguments(for: action, context: context)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [context.pythonCommand, "mysteamwine.py"] + arguments(for: action, context: context)
        }
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["PYTHONDONTWRITEBYTECODE": "1"]
        ) { _, appValue in appValue }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let input: Pipe?
        if case .epicAuthenticate(let code) = action {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
            _ = code
        } else if case .gogAuthenticate(let code) = action {
            let pipe = Pipe()
            process.standardInput = pipe
            input = pipe
            _ = code
        } else {
            input = nil
        }

        try process.run()
        if case .epicAuthenticate(let code) = action {
            input?.fileHandleForWriting.write(Data((code + "\n").utf8))
            try? input?.fileHandleForWriting.close()
        } else if case .gogAuthenticate(let code) = action {
            input?.fileHandleForWriting.write(Data((code + "\n").utf8))
            try? input?.fileHandleForWriting.close()
        }
        let result = try await collectStreamingResult(
            from: process,
            output: output,
            action: action,
            onUpdate: onUpdate
        )
        return result
    }

    static func arguments(for action: BackendAction, context: BackendContext) -> [String] {
        let base = context.targetArguments + ["--wine", context.winePath, "--jsonl"]

        switch action {
        case .sourceStatus(let source):
            return context.targetArguments + ["--jsonl", "source-status", "--source", source]
        case .listSourceGames(let source, let forceRefresh):
            return context.targetArguments + ["--jsonl", "list-source-games", "--source", source]
                + (forceRefresh ? ["--force-refresh"] : [])
        case .epicAuthenticate:
            return context.targetArguments + ["--jsonl", "epic-auth", "--authorization-code-stdin"]
        case .epicLogout:
            return context.targetArguments + ["--jsonl", "epic-logout", "--confirm"]
        case .gogAuthenticate:
            return context.targetArguments + ["--jsonl", "gog-auth", "--authorization-code-stdin"]
        case .gogLogout:
            return context.targetArguments + ["--jsonl", "gog-logout", "--confirm"]
        case .sourceGameAction(let source, let gameID, let operation, let confirm):
            return context.targetArguments + ["--jsonl", "source-game-action", "--source", source, "--game-id", gameID, "--operation", operation]
                + (confirm ? ["--confirm"] : [])
        case .launchSourceGame(let source, let gameID, let graphicsBackend):
            var args = base + [
                "--graphics-backend", graphicsBackend.cliValue,
                "--compatibility-profile", graphicsBackend.compatibilityProfileID,
                "launch-source-game", "--source", source, "--game-id", gameID,
            ]
            if graphicsBackend == .dxmt {
                args += ["--dxmt-source", context.dxmtSource]
            } else if graphicsBackend == .dxvk {
                args += ["--dxvk-source", context.dxvkSource]
            } else if graphicsBackend == .d3dmetal {
                args += ["--d3dmetal-source", context.d3dMetalSource]
            }
            return args
        case .steamIdentityStatus:
            return context.targetArguments + ["--jsonl", "steam-identity-status"]
        case .captureSteamIdentity(let sourceBottle):
            return context.targetArguments + ["--jsonl", "capture-steam-identity", "--source-bottle", sourceBottle, "--confirm"]
        case .provisionSteamIdentity(let targetBottle):
            return context.targetArguments + ["--jsonl", "provision-steam-identity", "--target-bottle", targetBottle]
        case .forgetSteamIdentity:
            return context.targetArguments + ["--jsonl", "forget-steam-identity", "--confirm"]
        case .signOutSteamProfile(let targetBottle):
            return context.targetArguments + ["--jsonl", "sign-out-steam-profile", "--target-bottle", targetBottle, "--confirm"]
        case .dependencyStatus:
            return base + ["dependency-status", "--gptk-wine", context.gptkWinePath, "--d3dmetal-source", context.d3dMetalSource]
        case .listJobs:
            return context.targetArguments + ["--jsonl", "list-jobs", "--limit", "50"]
        case .cancelJob(let id):
            return context.targetArguments + ["--jsonl", "cancel-job", "--job-id", id]
        case .discoverD3DMetal:
            return base + ["discover-d3dmetal", "--gptk-wine", context.gptkWinePath, "--d3dmetal-source", context.d3dMetalSource]
        case .importGPTK(let confirmLicense):
            return base + ["import-gptk", "--gptk-wine", context.gptkWinePath, "--d3dmetal-source", context.d3dMetalSource]
                + (confirmLicense ? ["--confirm-license"] : [])
        case .installHostDependency(let id, let confirmLicense):
            return base + ["install-host-dependency", "--dependency", id] + (confirmLicense ? ["--confirm-rosetta-license"] : [])
        case .setupCompatibilityProfile(let profile):
            var args = base + ["setup-compatibility-profile", "--profile", profile.compatibilityProfileID]
            if profile == .dxmt {
                args += ["--dxmt-source", context.dxmtSource]
            } else if profile == .dxvk {
                args += ["--dxvk-source", context.dxvkSource]
            } else if profile == .d3dmetal {
                args += ["--d3dmetal-source", context.d3dMetalSource]
            }
            return args
        case .repairCompatibilityProfile(let profile):
            var args = base + ["repair-compatibility-profile", "--profile", profile.compatibilityProfileID]
            if profile == .dxmt {
                args += ["--dxmt-source", context.dxmtSource]
            } else if profile == .dxvk {
                args += ["--dxvk-source", context.dxvkSource]
            } else if profile == .d3dmetal {
                args += ["--d3dmetal-source", context.d3dMetalSource]
            }
            return args
        case .resetCompatibilityProfile(let profile):
            return base + ["reset-compatibility-profile", "--profile", profile.compatibilityProfileID, "--confirm"]
        case .resetGameOverlay(let gameID):
            return base + ["reset-game-overlay", "--game-id", gameID, "--confirm"]
        case .attachSteamLibraries:
            return base + ["attach-steam-library", "--all"]
        case .setupMetal:
            return base + ["setup-metal", "--dxmt-source", context.dxmtSource, "--no-wait"]
        case .doctor:
            return base + ["doctor"]
        case .doctorFix:
            return base + ["doctor", "--fix", "--dxmt-source", context.dxmtSource]
        case .runWinetricks(let verbs, let interactive):
            return base
                + ["winetricks", "--verbs", verbs.joined(separator: ",")]
                + (interactive ? ["--interactive"] : [])
        case .installDXMT:
            return base + ["install-dxmt", "--dxmt-source", context.dxmtSource]
        case .installDXVK:
            return base + ["install-dxvk", "--dxvk-source", context.dxvkSource]
        case .installD3DMetal:
            return base + ["install-d3dmetal", "--d3dmetal-source", context.d3dMetalSource]
        case .openWinecfg:
            return base + ["winecfg"]
        case .killWine:
            return base + ["kill-wine", "--all-managed"]
        case .listSessions:
            return context.targetArguments + ["--json", "list-sessions"]
        case .stopGame(let sessionID):
            return base + ["stop-game", "--session-id", sessionID]
        case .openSteam:
            return base + ["run-steam", "--no-wait"]
        case .listGames:
            return context.targetArguments + ["--jsonl", "list-games"]
        case .listRuntimeCatalog:
            return context.targetArguments + ["--jsonl", "list-runtime-catalog"]
        case .listInstalledRuntimes:
            return context.targetArguments + ["--jsonl", "list-installed-runtimes"]
        case .installRuntime(let id):
            return base + ["install-runtime", "--runtime", id, "--no-bottle-install"]
        case .launchGame(let appid):
            return base + ["--graphics-backend", GraphicsBackendOption.dxmt.cliValue, "--compatibility-profile", GraphicsBackendOption.dxmt.compatibilityProfileID, "launch-game", "--appid", appid, "--dxmt-source", context.dxmtSource, "--no-wait"]
        case .smartLaunchGame(let appid, let graphicsBackend):
            var args = base
            args += ["--graphics-backend", graphicsBackend.cliValue, "--compatibility-profile", graphicsBackend.compatibilityProfileID, "smart-launch-game", "--appid", appid, "--no-wait"]
            if graphicsBackend == .dxmt {
                args += ["--dxmt-source", context.dxmtSource]
            } else if graphicsBackend == .dxvk {
                args += ["--dxvk-source", context.dxvkSource]
            } else if graphicsBackend == .d3dmetal {
                args += ["--d3dmetal-source", context.d3dMetalSource]
            }
            args += ["--probe-seconds", "8", "--no-wait"]
            return args
        case .debugGame(let appid, let gameArgs, let graphicsBackend, let workingDirectory, let environment, let wineDebug, let legacyDirectXSource):
            var args = base
            args += ["--graphics-backend", graphicsBackend.cliValue, "--compatibility-profile", graphicsBackend.compatibilityProfileID, "debug-game", "--appid", appid]
            if graphicsBackend == .dxmt {
                args += ["--dxmt-source", context.dxmtSource]
            } else if graphicsBackend == .dxvk {
                args += ["--dxvk-source", context.dxvkSource]
            } else if graphicsBackend == .d3dmetal {
                args += ["--d3dmetal-source", context.d3dMetalSource]
            }
            args += ["--no-wait", "--wine-debug=\(wineDebug)"]
            args += workingDirectoryArguments(workingDirectory)
            args += environmentArguments(environment)
            if let legacyDirectXSource, !legacyDirectXSource.isEmpty {
                args += ["--legacy-directx-source", legacyDirectXSource]
                args += ["--ensure-steam"]
            }
            args += passthroughArguments(gameArgs)
            return args
        case .debugExecutable(let path, let gameArgs, let graphicsBackend, let workingDirectory, let environment, let wineDebug, let legacyDirectXSource, let standalone):
            var args = base
            args += ["--graphics-backend", graphicsBackend.cliValue, "--compatibility-profile", graphicsBackend.compatibilityProfileID, "debug-game", "--exe", path]
            if standalone {
                args += ["--standalone"]
            }
            if graphicsBackend == .dxmt {
                args += ["--dxmt-source", context.dxmtSource]
            } else if graphicsBackend == .dxvk {
                args += ["--dxvk-source", context.dxvkSource]
            } else if graphicsBackend == .d3dmetal {
                args += ["--d3dmetal-source", context.d3dMetalSource]
            }
            args += ["--no-wait", "--wine-debug=\(wineDebug)"]
            args += workingDirectoryArguments(workingDirectory)
            args += environmentArguments(environment)
            if let legacyDirectXSource, !legacyDirectXSource.isEmpty {
                args += ["--legacy-directx-source", legacyDirectXSource]
            }
            args += passthroughArguments(gameArgs)
            return args
        }
    }

    private static func passthroughArguments(_ args: [String]) -> [String] {
        guard !args.isEmpty else { return [] }
        return ["--"] + args
    }

    private static func workingDirectoryArguments(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        return ["--cwd", value]
    }

    private static func environmentArguments(_ values: [String]) -> [String] {
        values.flatMap { ["--env", $0] }
    }

    private static func parseGames(from output: String) -> [BackendGame] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> BackendGame? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 2 else { return nil }
                let appid = String(parts[0])
                let name = String(parts[1])
                let installDir = parts.count >= 3 ? String(parts[2]) : nil
                return BackendGame(id: appid, appid: appid, name: name, installDir: installDir)
            }
    }

    private static func parseJSONResponse(from data: Data) -> BackendJSONResponse? {
        try? JSONDecoder().decode(BackendJSONResponse.self, from: data)
    }

    private static func parseJSONLine(_ line: String) -> BackendJSONResponse? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BackendJSONResponse.self, from: data)
    }

    private static func collectStreamingResult(
        from process: Process,
        output: Pipe,
        action: BackendAction,
        onUpdate: @escaping @Sendable (BackendStreamUpdate) async -> Void
    ) async throws -> BackendResponse {
        let state = BackendStreamAccumulator()
        let handle = output.fileHandleForReading
        // Await one serialized reader so a fast backend process cannot terminate
        // before detached readability-handler work stores its final JSON result.
        let reader = Task.detached(priority: .utility) {
            while true {
                let chunk = handle.availableData
                guard chunk.isEmpty == false else { break }
                await state.append(chunk)
                let lines = await state.popReadyLines()
                for trimmed in lines {
                    if let payload = parseJSONLine(trimmed) {
                        let response = makeResponse(from: payload)
                        if payload.event == "result" || payload.event == nil {
                            await state.setFinalResponse(response)
                        }
                        await onUpdate(
                            BackendStreamUpdate(
                                job: parseJob(from: payload),
                                structured: parseStructuredResult(from: payload)
                            )
                        )
                    } else {
                        await state.appendPlainText(trimmed)
                    }
                }
            }
        }

        // `Process.terminationHandler` can miss very short-lived commands when
        // it is installed after `run()`. Waiting on a utility task is safe for
        // already-terminated processes and prevents a completed backend action
        // from remaining active forever in the SwiftUI job list.
        await Task.detached(priority: .utility) {
            process.waitUntilExit()
        }.value

        await reader.value
        if let trimmed = await state.appendTrailing(Data()) {
            if trimmed.isEmpty == false {
                if let payload = parseJSONLine(trimmed) {
                    let response = makeResponse(from: payload)
                    if payload.event == "result" || payload.event == nil {
                        await state.setFinalResponse(response)
                    }
                    await onUpdate(
                        BackendStreamUpdate(
                            job: parseJob(from: payload),
                            structured: parseStructuredResult(from: payload)
                        )
                    )
                } else {
                    await state.appendPlainText(trimmed)
                }
            }
        }

        let snapshot = await state.snapshot()
        let finalResponse = snapshot.finalResponse
        let plainTextLines = snapshot.plainTextLines

        if let finalResponse {
            if process.terminationStatus != 0 {
                switch action {
                case .doctor, .doctorFix:
                    return finalResponse
                default:
                    throw NSError(
                        domain: "SteamWineApp.BackendBridge",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: finalResponse.output]
                    )
                }
            }
            return finalResponse
        }

        let plainText = plainTextLines.joined(separator: "\n")
        if process.terminationStatus != 0 {
            let message = plainText.isEmpty ? "Command failed." : plainText
            throw NSError(
                domain: "SteamWineApp.BackendBridge",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }

        let games: [BackendGame]
        switch action {
        case .listGames:
            games = parseGames(from: plainText)
        default:
            games = []
        }
        return BackendResponse(
            output: plainText.isEmpty ? "Command finished without output." : plainText,
            games: games,
            runtimes: [],
            sessions: [],
            jobs: [],
            job: nil,
            structured: nil,
            steamIdentity: nil,
            sourceGames: [],
            sourceStatus: nil
        )
    }

    private static func makeResponse(from payload: BackendJSONResponse) -> BackendResponse {
        let games = payload.data?.games?.map {
            BackendGame(id: $0.appid, appid: $0.appid, name: $0.name, installDir: $0.install_dir)
        } ?? []
        var runtimes = payload.data?.runtimes?.map { makeRuntime(from: $0) } ?? []
        if let runtime = payload.data?.runtime {
            runtimes.append(makeRuntime(from: runtime))
        }
        let job = parseJob(from: payload)
        let structured = parseStructuredResult(from: payload)
        var sessions = payload.data?.sessions?.map { makeSession(from: $0) } ?? []
        if let session = payload.data?.session {
            sessions.append(makeSession(from: session))
        }
        let jobs = payload.data?.jobs?.compactMap { makeJob(from: $0) } ?? []

        return BackendResponse(
            output: renderOutput(from: payload),
            games: games,
            runtimes: runtimes,
            sessions: sessions,
            jobs: jobs,
            job: job,
            structured: structured,
            steamIdentity: makeSteamIdentity(from: payload.data),
            sourceGames: makeSourceGames(from: payload.data),
            sourceStatus: makeSourceStatus(from: payload.data)
        )
    }

    private static func makeSourceGames(from data: BackendJSONData?) -> [BackendSourceGame] {
        data?.source_games?.map {
            BackendSourceGame(
                source: $0.source,
                storeID: $0.store_id,
                libraryID: $0.library_id,
                title: $0.title,
                installed: $0.installed,
                installPath: $0.install_path,
                version: $0.version,
                updateAvailable: $0.update_available,
                artURL: $0.art_url
            )
        } ?? []
    }

    private static func makeSourceStatus(from data: BackendJSONData?) -> BackendSourceStatus? {
        guard let status = data?.source_status else { return nil }
        return BackendSourceStatus(
            source: status.source,
            available: status.available,
            authenticated: status.authenticated,
            client: status.client,
            version: status.version,
            message: status.message
        )
    }

    private static func makeSteamIdentity(from data: BackendJSONData?) -> SteamIdentityStatus? {
        guard let available = data?.available else { return nil }
        return SteamIdentityStatus(
            available: available,
            sourceBottle: data?.source_bottle,
            capturedAt: data?.captured_at,
            accountCount: data?.account_count ?? 0,
            provisionedProfiles: data?.provisioned_profiles ?? [],
            activeSteamProfiles: data?.active_steam_profiles ?? []
        )
    }

    private static func makeJob(from payload: BackendJSONJob) -> BackendJob? {
        guard let status = BackendJobStatus(rawValue: payload.status) else { return nil }
        return BackendJob(
            id: payload.job_id,
            action: payload.action,
            status: status,
            message: payload.message,
            progress: payload.progress,
            completedSteps: payload.completed_steps,
            totalSteps: payload.total_steps
        )
    }

    private static func makeSession(from payload: BackendJSONSession) -> GameLaunchSession {
        GameLaunchSession(
            sessionID: payload.session_id,
            appid: payload.appid,
            game: payload.game,
            status: payload.status,
            strategy: payload.strategy,
            graphicsBackend: payload.graphics_backend,
            profileID: payload.profile_id,
            bottle: payload.bottle,
            prefix: payload.prefix,
            executable: payload.executable,
            installDir: payload.install_dir,
            pids: payload.pids,
            message: payload.message
        )
    }

    private static func makeRuntime(from payload: BackendJSONRuntime) -> ManagedRuntime {
        ManagedRuntime(
            id: payload.id,
            name: payload.name,
            version: payload.version,
            kind: payload.kind,
            source: payload.source,
            downloadURL: payload.download_url,
            sha256: payload.sha256,
            archiveType: payload.archive_type,
            installLayout: payload.install_layout,
            license: payload.license,
            notes: payload.notes,
            installed: payload.installed ?? (payload.path != nil),
            path: payload.path,
            executable: payload.executable,
            installedAt: payload.installed_at
        )
    }

    private static func parseJob(from payload: BackendJSONResponse) -> BackendJob? {
        guard
            let jobID = payload.job_id,
            let statusText = payload.status,
            let status = BackendJobStatus(rawValue: statusText)
        else {
            return nil
        }

        return BackendJob(
            id: jobID,
            action: payload.action,
            status: status,
            message: payload.message,
            progress: payload.data?.progress,
            completedSteps: payload.data?.completed_steps,
            totalSteps: payload.data?.total_steps
        )
    }

    private static func parseStructuredResult(from payload: BackendJSONResponse) -> BackendStructuredResult? {
        let checks = payload.data?.checks?.map {
            BackendCheckSummary(
                id: "\($0.name)|\($0.detail)",
                status: $0.status,
                name: $0.name,
                detail: $0.detail,
                required: $0.required ?? true,
                fix: $0.fix
            )
        } ?? []
        let steps = payload.data?.steps?.map {
            BackendStepSummary(
                id: "\($0.name)|\($0.status)",
                name: $0.name,
                status: $0.status
            )
        } ?? []
        let liveStep = payload.data?.step.map {
            BackendStepSummary(
                id: "\($0.name)|\($0.status)",
                name: $0.name,
                status: $0.status
            )
        }
        let fixes = payload.data?.actions ?? []
        let signals = payload.data?.signals?.map {
            BackendSignalSummary(
                id: "\($0.key)|\($0.path)",
                key: $0.key,
                detail: $0.detail,
                path: $0.path
            )
        } ?? []
        let recommendations = payload.data?.recommendations?.map {
            BackendRecommendationSummary(
                id: "\($0.verb)|\($0.reason)",
                verb: $0.verb,
                reason: $0.reason
            )
        } ?? []

        guard
            !checks.isEmpty
            || !steps.isEmpty
            || liveStep != nil
            || !fixes.isEmpty
            || !signals.isEmpty
            || !recommendations.isEmpty
            || payload.data?.root != nil
            || payload.data?.target != nil
            || payload.data?.worst_status != nil
            || payload.data?.gptk_wine_path != nil
            || payload.data?.d3dmetal_source != nil
        else {
            return nil
        }

        return BackendStructuredResult(
            action: payload.action,
            root: payload.data?.root,
            target: payload.data?.target,
            worstStatus: payload.data?.worst_status,
            fixes: fixes,
            checks: checks,
            steps: liveStep.map { [$0] } ?? steps,
            signals: signals,
            recommendations: recommendations,
            warnings: payload.warnings,
            errors: payload.errors,
            tail: payload.data?.tail,
            completedSteps: payload.data?.completed_steps,
            totalSteps: payload.data?.total_steps,
            gptkWinePath: payload.data?.gptk_wine_path,
            d3dMetalSource: payload.data?.d3dmetal_source
        )
    }

    private static func renderOutput(from payload: BackendJSONResponse) -> String {
        var lines: [String] = [payload.message]

        if let target = payload.data?.target, !target.isEmpty {
            lines.append("Target: \(target)")
        }

        if let actions = payload.data?.actions, !actions.isEmpty {
            lines.append(contentsOf: actions.map { "[FIX ] \($0)" })
        }

        if let checks = payload.data?.checks, !checks.isEmpty {
            lines.append(
                contentsOf: checks.map { "[\($0.status.uppercased())] \($0.name): \($0.detail)" }
            )
        }

        if let steps = payload.data?.steps, !steps.isEmpty {
            lines.append(
                contentsOf: steps.map { "[STEP] \($0.name): \($0.status)" }
            )
        }

        if let tail = payload.data?.tail, !tail.isEmpty {
            lines.append(tail)
        }

        if !payload.warnings.isEmpty {
            lines.append(contentsOf: payload.warnings.map { "[WARN] \($0)" })
        }

        if !payload.errors.isEmpty {
            lines.append(contentsOf: payload.errors.map { "[ERROR] \($0)" })
        }

        return lines.joined(separator: "\n")
    }
}
