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
}
