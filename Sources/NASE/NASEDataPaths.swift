import Foundation

enum NASEDataPaths {
    static let directoryName = "NASE"
    static let legacyDirectoryName = "MySteamWine"

    static func rootURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func legacyRootURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeURL
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(legacyDirectoryName, isDirectory: true)
    }

    /// On-disk cache for downsampled cover art, persisted across launches.
    static func artworkCacheURL(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        rootURL(homeURL: homeURL).appendingPathComponent("artwork-cache", isDirectory: true)
    }

    @discardableResult
    static func migrateLegacyDataIfNeeded(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> URL {
        let destination = rootURL(homeURL: homeURL)
        let legacy = legacyRootURL(homeURL: homeURL)
        if !fileManager.fileExists(atPath: destination.path),
           fileManager.fileExists(atPath: legacy.path) {
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: legacy, to: destination)
            } catch {
                return legacy
            }
        }
        guard fileManager.fileExists(atPath: destination.path) else {
            return destination
        }
        rewriteManagedPaths(
            in: defaults,
            replacing: legacy.path,
            with: destination.path
        )
        return destination
    }

    static func rewriteManagedPaths(
        in defaults: UserDefaults,
        replacing oldPath: String,
        with newPath: String
    ) {
        for (key, value) in defaults.dictionaryRepresentation() {
            let updated = replacingManagedPath(in: value, oldPath: oldPath, newPath: newPath)
            if !valuesAreEqual(value, updated) {
                defaults.set(updated, forKey: key)
            }
        }
    }

    private static func replacingManagedPath(
        in value: Any,
        oldPath: String,
        newPath: String
    ) -> Any {
        switch value {
        case let string as String:
            return string.replacingOccurrences(of: oldPath, with: newPath)
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8) else { return data }
            let updated = string.replacingOccurrences(of: oldPath, with: newPath)
            return updated == string ? data : Data(updated.utf8)
        case let array as [Any]:
            return array.map {
                replacingManagedPath(in: $0, oldPath: oldPath, newPath: newPath)
            }
        case let dictionary as [String: Any]:
            return dictionary.mapValues {
                replacingManagedPath(in: $0, oldPath: oldPath, newPath: newPath)
            }
        default:
            return value
        }
    }

    private static func valuesAreEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let lhs = lhs as? NSObject, let rhs = rhs as? NSObject {
            return lhs == rhs
        }
        return false
    }
}
