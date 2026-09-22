import XCTest
@testable import NASE

final class LibraryOrderingTests: XCTestCase {
    func testAvailabilityGroupsInstalledThenSortsEachGroupByTitle() {
        let games = [
            game("Zulu Owned", installed: false),
            game("Zulu Installed", installed: true),
            game("Alpha Owned", installed: false),
            game("Alpha Installed", installed: true),
        ]

        let ordered = LibraryOrdering.order(games, by: .availability) { _ in nil }

        XCTAssertEqual(
            ordered.map(\.title),
            ["Alpha Installed", "Zulu Installed", "Alpha Owned", "Zulu Owned"]
        )
    }

    func testNewlyDiscoveredGameJoinsItsAlphabeticalGroup() {
        let previous = [game("Beta", installed: false), game("Delta", installed: false)]
        let refreshed = previous + [game("Charlie", installed: false)]

        let ordered = LibraryOrdering.order(refreshed, by: .availability) { _ in nil }

        XCTAssertEqual(ordered.map(\.title), ["Beta", "Charlie", "Delta"])
    }

    func testManualOrderIsPreserved() {
        let games = [game("Zulu", installed: false), game("Alpha", installed: true)]
        XCTAssertEqual(
            LibraryOrdering.order(
                games,
                by: .manual,
                manualOrderIDs: [games[1].pinID, games[0].pinID]
            ) { _ in nil }.map(\.title),
            ["Alpha", "Zulu"]
        )
    }

    func testManualOrderPlacesNewGamesPredictablyWithoutMutatingSavedOrder() {
        let beta = game("Beta", installed: false)
        let delta = game("Delta", installed: false)
        let alpha = game("Alpha", installed: true)

        let ordered = LibraryOrdering.order(
            [beta, delta, alpha],
            by: .manual,
            manualOrderIDs: [delta.pinID, beta.pinID]
        ) { _ in nil }

        XCTAssertEqual(ordered.map(\.title), ["Delta", "Beta", "Alpha"])
    }

    private func game(_ title: String, installed: Bool) -> LibraryGame {
        LibraryGame(
            backendID: title,
            title: title,
            runner: .steam,
            capsule: "Steam",
            status: installed ? "Installed" : "Owned",
            installURL: installed ? URL(fileURLWithPath: "/games/\(title)") : nil
        )
    }
}
