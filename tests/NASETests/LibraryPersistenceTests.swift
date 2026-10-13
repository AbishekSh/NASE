import XCTest
@testable import NASE

final class LibraryPersistenceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "NASETests.LibraryPersistence.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshStoreUsesAvailabilityOrdering() {
        XCTAssertEqual(UserDefaultsLibraryPersistence(defaults: defaults).sortOption(), .availability)
    }

    func testSortOptionRoundTripsWithoutViewModelKnowledge() {
        let persistence = UserDefaultsLibraryPersistence(defaults: defaults)
        persistence.saveSortOption(.recent)
        XCTAssertEqual(persistence.sortOption(), .recent)
    }

    func testImportedItemsRemainSeparatedBySource() {
        let persistence = UserDefaultsLibraryPersistence(defaults: defaults)
        let mac = StoredLibraryItem(
            pinID: "mac:test",
            title: "Mac Test",
            runner: RunnerKind.mac.rawValue,
            installPath: "/Applications/Test.app",
            launchPath: nil,
            status: "App"
        )
        let wine = StoredLibraryItem(
            pinID: "wine:test",
            title: "Wine Test",
            runner: RunnerKind.wine.rawValue,
            installPath: "/Games/Test",
            launchPath: "/Games/Test/game.exe",
            status: "Windows App"
        )

        persistence.saveImportedItems([mac], for: .mac)
        persistence.saveImportedItems([wine], for: .wine)

        XCTAssertEqual(persistence.importedItems(for: .mac), [mac])
        XCTAssertEqual(persistence.importedItems(for: .wine), [wine])
    }
}
