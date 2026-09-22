import CoreGraphics
import Foundation

/// Persistence for user-created keyboard layouts.
///
/// Built-in layouts live in code; only layouts the user built are stored here.
/// A damaged file is set aside rather than overwritten, so a bad read can never
/// destroy work the user did.
struct KeyboardLayoutStore {
    static let schemaVersion = 1

    let fileURL: URL

    static func standard(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> KeyboardLayoutStore {
        KeyboardLayoutStore(
            fileURL: NASEDataPaths.rootURL(homeURL: homeURL)
                .appendingPathComponent("input", isDirectory: true)
                .appendingPathComponent("keyboard-layouts.json", isDirectory: false)
        )
    }

    private struct Document: Codable {
        var schemaVersion: Int
        var layouts: [KeyboardLayout]
    }

    struct LoadResult {
        var layouts: [KeyboardLayout]
        var warning: String?
    }

    /// Read stored layouts, degrading to an empty list with a warning rather
    /// than throwing: an unreadable layout file must not stop the app, and must
    /// not silently look like "the user has no layouts" either.
    func load(fileManager: FileManager = .default) -> LoadResult {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return LoadResult(layouts: [], warning: nil)
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return LoadResult(
                layouts: [],
                warning: "NASE could not read your saved keyboard layouts at \(fileURL.path)."
            )
        }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            let movedTo = setAsideDamagedFile(fileManager: fileManager)
            return LoadResult(
                layouts: [],
                warning: movedTo.map {
                    "Your keyboard layout file could not be read. It was kept at \($0.lastPathComponent) and NASE started with no custom layouts."
                } ?? "Your keyboard layout file could not be read."
            )
        }
        // A newer schema is left completely alone. Guessing at fields NASE does
        // not understand risks writing back a file that loses them.
        guard document.schemaVersion <= Self.schemaVersion else {
            return LoadResult(
                layouts: [],
                warning: "Your keyboard layouts were saved by a newer version of NASE and were not loaded. Update NASE to use them."
            )
        }

        var valid: [KeyboardLayout] = []
        var rejected = 0
        for var layout in document.layouts {
            layout.isBuiltIn = false
            guard (try? layout.validate()) != nil else {
                rejected += 1
                continue
            }
            guard KeyboardLayout.builtIn(id: layout.id) == nil else {
                rejected += 1
                continue
            }
            valid.append(layout)
        }
        return LoadResult(
            layouts: valid,
            warning: rejected == 0
                ? nil
                : "\(rejected) saved keyboard layout(s) were skipped because they are no longer valid."
        )
    }

    /// Replace the stored layouts atomically, so an interrupted write cannot
    /// leave a half-written file behind.
    func save(_ layouts: [KeyboardLayout], fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = Document(
            schemaVersion: Self.schemaVersion,
            layouts: layouts.filter { !$0.isBuiltIn }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)

        let temporary = fileURL.appendingPathExtension("tmp")
        try data.write(to: temporary, options: .atomic)
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
    }

    private func setAsideDamagedFile(fileManager: FileManager) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("keyboard-layouts.damaged-\(stamp).json")
        do {
            try fileManager.moveItem(at: fileURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
