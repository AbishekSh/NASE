import XCTest
@testable import SteamWineApp

final class BackendBridgeTests: XCTestCase {
    private let context = BackendContext(
        repoRoot: URL(fileURLWithPath: "/Applications/NASE.app/Contents/Resources/Backend"),
        pythonCommand: "/Applications/NASE.app/Contents/Frameworks/Python.framework/bin/python3",
        winePath: "/managed/wine/bin/wine",
        dxmtSource: "/managed/dxmt",
        dxvkSource: "/managed/dxvk",
        d3dMetalSource: "/managed/d3dmetal",
        gptkWinePath: "/managed/gptk/bin/wine",
        bottleName: "Default",
        externalPrefix: nil
    )

    func testWineMutatingActionsCarrySelectedWinePath() {
        let actions: [BackendAction] = [
            .setupMetal,
            .doctorFix,
            .runWinetricks(verbs: ["vcrun2022"], interactive: false),
            .installDXMT,
            .installDXVK,
            .openWinecfg,
            .openSteam,
            .launchGame(appid: "123"),
        ]

        for action in actions {
            let arguments = BackendBridge.arguments(for: action, context: context)
            XCTAssertTrue(arguments.contains("--wine"), "\(action) dropped --wine")
            XCTAssertTrue(arguments.contains(context.winePath), "\(action) dropped the selected Wine path")
        }
    }

    func testRuntimeCatalogInstallDoesNotMutateCurrentBottle() {
        let arguments = BackendBridge.arguments(
            for: .installRuntime(id: "dxmt-0.71"),
            context: context
        )
        XCTAssertTrue(arguments.contains("--no-bottle-install"))
    }

    func testStandaloneWindowsAppLaunchDoesNotRequireSteamProfileSetup() {
        let arguments = BackendBridge.arguments(
            for: .debugExecutable(
                path: "/Applications/Notepad++/notepad++.exe",
                graphicsBackend: .none,
                standalone: true
            ),
            context: context
        )
        XCTAssertTrue(arguments.contains("--standalone"))
        XCTAssertTrue(arguments.contains("/Applications/Notepad++/notepad++.exe"))
    }

    func testEveryCompatibilityContextReusesProfilesBoundWineRuntime() throws {
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let wine = supportRoot.appendingPathComponent("Wine Stable")
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: wine.path, contents: Data("#!/bin/sh\n".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        for backend in GraphicsBackendOption.allCases {
            let bottleRoot = supportRoot
                .appendingPathComponent("bottles/Default-\(backend.bottleSuffix)", isDirectory: true)
            try FileManager.default.createDirectory(at: bottleRoot, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "profile": ["id": backend.compatibilityProfileID],
                "wine_path": wine.path,
                "setup_status": "ready",
            ]
            try JSONSerialization.data(withJSONObject: manifest)
                .write(to: bottleRoot.appendingPathComponent("compatibility-profile.json"))

            let profileContext = context.compatibilityContext(for: backend, appSupportRoot: supportRoot)

            XCTAssertEqual(profileContext.winePath, wine.path, "\(backend) ignored its bound Wine runtime")
        }
    }

    func testPreviewUsesConfiguredPython() {
        let preview = BackendBridge.preview(.doctor, context: context)
        XCTAssertTrue(preview.hasPrefix(context.pythonCommand))
    }

    func testImportedWineAppsUseFullPathIdentity() {
        let first = LibraryGame.importedPinID(
            runner: .wine,
            url: URL(fileURLWithPath: "/Games/First/Game.exe")
        )
        let second = LibraryGame.importedPinID(
            runner: .wine,
            url: URL(fileURLWithPath: "/Games/Second/Game.exe")
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            first,
            LibraryGame.importedPinID(
                runner: .wine,
                url: URL(fileURLWithPath: "/Games/First/../First/Game.exe")
            )
        )
    }

    func testLaunchSessionStatusesMapToDistinctUIPhases() {
        XCTAssertEqual(GameLaunchPhase(sessionStatus: "launching"), .launching)
        XCTAssertEqual(GameLaunchPhase(sessionStatus: "running"), .running)
        XCTAssertEqual(GameLaunchPhase(sessionStatus: "stopping"), .stopping)
        XCTAssertEqual(GameLaunchPhase(sessionStatus: "exited"), .exited)
        XCTAssertEqual(GameLaunchPhase(sessionStatus: "failed"), .failed)
        XCTAssertTrue(GameLaunchPhase.stopping.isActive)
        XCTAssertFalse(GameLaunchPhase.exited.isActive)
    }
}
