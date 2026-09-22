import Foundation
import XCTest
@testable import NASE

final class KeyboardLayoutStoreTests: XCTestCase {
    private var directory: URL!
    private var store: KeyboardLayoutStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nase-layout-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = KeyboardLayoutStore(
            fileURL: directory.appendingPathComponent("keyboard-layouts.json")
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func layout(id: String = "user.a", name: String = "Mine") -> KeyboardLayout {
        KeyboardLayout(
            id: id,
            name: name,
            remaps: [KeyRemap(from: NASEKeyCode.w, to: NASEKeyCode.upArrow)]
        )
    }

    func testMissingFileLoadsEmptyWithoutWarning() {
        let result = store.load()
        XCTAssertTrue(result.layouts.isEmpty)
        XCTAssertNil(result.warning)
    }

    func testSaveThenLoadRoundTrips() throws {
        try store.save([layout()])
        let result = store.load()
        XCTAssertEqual(result.layouts.count, 1)
        XCTAssertEqual(result.layouts.first?.name, "Mine")
        XCTAssertEqual(result.layouts.first?.remapTable, [NASEKeyCode.w: NASEKeyCode.upArrow])
        XCTAssertNil(result.warning)
    }

    /// Built-ins ship in code; persisting them too would let a stale copy
    /// shadow an updated built-in.
    func testBuiltInLayoutsAreNotPersisted() throws {
        try store.save(KeyboardLayout.builtIns + [layout()])
        XCTAssertEqual(store.load().layouts.map(\.id), ["user.a"])
    }

    func testLoadedUserLayoutIsNeverMarkedBuiltIn() throws {
        var sneaky = layout()
        sneaky.isBuiltIn = true
        try store.save([sneaky])
        // It was filtered out by save, so write it directly to be sure load
        // also refuses to trust the flag.
        let raw = """
        {"schemaVersion":1,"layouts":[{"id":"user.b","name":"B","isBuiltIn":true,
         "remaps":[{"from":13,"to":126}]}]}
        """
        try Data(raw.utf8).write(to: store.fileURL)
        let loaded = store.load().layouts
        XCTAssertEqual(loaded.count, 1)
        XCTAssertFalse(loaded[0].isBuiltIn)
    }

    /// A damaged file must be preserved, not overwritten — it is the only copy
    /// of work the user did.
    func testDamagedFileIsSetAsideAndAppStillStarts() throws {
        try Data("{ this is not json".utf8).write(to: store.fileURL)
        let result = store.load()

        XCTAssertTrue(result.layouts.isEmpty)
        XCTAssertNotNil(result.warning)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.fileURL.path),
            "the damaged file should have been moved aside"
        )
        let salvaged = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("keyboard-layouts.damaged-") }
        XCTAssertEqual(salvaged.count, 1)
    }

    /// A file from a newer NASE is left untouched rather than partially read
    /// and written back with fields this version does not know about.
    func testNewerSchemaIsLeftAloneWithAWarning() throws {
        let raw = """
        {"schemaVersion":99,"layouts":[{"id":"user.c","name":"C","isBuiltIn":false,
         "remaps":[{"from":13,"to":126}]}]}
        """
        try Data(raw.utf8).write(to: store.fileURL)
        let result = store.load()
        XCTAssertTrue(result.layouts.isEmpty)
        XCTAssertNotNil(result.warning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testInvalidStoredLayoutIsSkippedButValidOnesSurvive() throws {
        let raw = """
        {"schemaVersion":1,"layouts":[
          {"id":"user.bad","name":"Bad","isBuiltIn":false,"remaps":[{"from":13,"to":13}]},
          {"id":"user.good","name":"Good","isBuiltIn":false,"remaps":[{"from":13,"to":126}]}
        ]}
        """
        try Data(raw.utf8).write(to: store.fileURL)
        let result = store.load()
        XCTAssertEqual(result.layouts.map(\.id), ["user.good"])
        XCTAssertNotNil(result.warning)
    }

    func testLayoutClashingWithABuiltInIDIsSkipped() throws {
        try store.save([layout(id: KeyboardLayout.builtIns[0].id, name: "Impostor")])
        XCTAssertTrue(store.load().layouts.isEmpty)
    }

    func testSaveCreatesTheInputDirectory() throws {
        let nested = KeyboardLayoutStore(
            fileURL: directory
                .appendingPathComponent("input", isDirectory: true)
                .appendingPathComponent("keyboard-layouts.json")
        )
        try nested.save([layout()])
        XCTAssertEqual(nested.load().layouts.count, 1)
    }

    func testSavingTwiceReplacesRatherThanAppends() throws {
        try store.save([layout(name: "First")])
        try store.save([layout(name: "Second")])
        let loaded = store.load().layouts
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Second")
    }
}

final class KeyboardLayoutStorePathTests: XCTestCase {
    /// The store must land under the same managed NASE tree the uninstaller and
    /// the legacy-data migration already know about.
    func testStandardStoreLivesUnderTheManagedNASEDirectory() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nase-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let store = KeyboardLayoutStore.standard(homeURL: home)
        XCTAssertTrue(
            store.fileURL.path.hasPrefix(NASEDataPaths.rootURL(homeURL: home).path),
            "layouts must live inside \(NASEDataPaths.rootURL(homeURL: home).path)"
        )
        XCTAssertEqual(store.fileURL.lastPathComponent, "keyboard-layouts.json")
        XCTAssertEqual(store.fileURL.deletingLastPathComponent().lastPathComponent, "input")

        try store.save([
            KeyboardLayout(
                id: "user.path",
                name: "Path",
                remaps: [KeyRemap(from: NASEKeyCode.a, to: NASEKeyCode.leftArrow)]
            )
        ])
        XCTAssertEqual(store.load().layouts.first?.name, "Path")
    }
}
