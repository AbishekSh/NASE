import Foundation

struct StoredLibraryItem: Codable, Equatable {
    let pinID: String?
    let title: String
    let runner: String
    let installPath: String
    let launchPath: String?
    let status: String?
}

/// Persistence boundary for user-owned library state.
///
/// Discovery remains the responsibility of the source backends. The view model
/// talks to this protocol rather than a concrete storage technology, so a JSON
/// file or SQLite implementation can replace UserDefaults without changing UI
/// or launch code.
protocol LibraryPersisting {
    func importedItems(for runner: RunnerKind) -> [StoredLibraryItem]
    func saveImportedItems(_ items: [StoredLibraryItem], for runner: RunnerKind)

    func pinnedIDs() -> [String]
    func savePinnedIDs(_ ids: [String])
    func steamOrderIDs() -> [String]
    func saveSteamOrderIDs(_ ids: [String])
    func sortOption() -> LibrarySortOption
    func saveSortOption(_ option: LibrarySortOption)
    func hiddenSteamAppIDs() -> [String]
    func saveHiddenSteamAppIDs(_ ids: [String])

    func gameSettings() -> [String: StoredGameSettings]
    func saveGameSettings(_ settings: [String: StoredGameSettings])
    func sourceHealth() -> [RunnerKind: HealthStatus]
    func saveSourceHealth(_ health: [RunnerKind: HealthStatus])
    func wineRuntimes() -> [WineRuntimeRecord]
    func saveWineRuntimes(_ runtimes: [WineRuntimeRecord])

    var didCompleteInitialSetup: Bool { get }
    func setDidCompleteInitialSetup(_ completed: Bool)
}

struct UserDefaultsLibraryPersistence: LibraryPersisting {
    private enum Key {
        static let nativeApps = "library.nativeApps"
        static let wineApps = "library.wineApps"
        static let pinnedIDs = "library.pinnedIDs"
        static let steamOrder = "library.steamOrder"
        static let sortOption = "library.sortOption"
        static let hiddenSteamAppIDs = "library.hiddenSteamAppIDs"
        static let gameSettings = "library.gameSettings"
        static let sourceHealth = "library.sourceHealth"
        static let wineRuntimes = "library.wineRuntimes"
        static let didCompleteInitialSetup = "library.didCompleteInitialSetup"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func importedItems(for runner: RunnerKind) -> [StoredLibraryItem] {
        let key: String
        switch runner {
        case .mac: key = Key.nativeApps
        case .wine: key = Key.wineApps
        default: return []
        }
        return decode([StoredLibraryItem].self, forKey: key) ?? []
    }

    func saveImportedItems(_ items: [StoredLibraryItem], for runner: RunnerKind) {
        let key: String
        switch runner {
        case .mac: key = Key.nativeApps
        case .wine: key = Key.wineApps
        default: return
        }
        encode(items, forKey: key)
    }

    func pinnedIDs() -> [String] { defaults.stringArray(forKey: Key.pinnedIDs) ?? [] }
    func savePinnedIDs(_ ids: [String]) { defaults.set(ids, forKey: Key.pinnedIDs) }
    func steamOrderIDs() -> [String] { defaults.stringArray(forKey: Key.steamOrder) ?? [] }
    func saveSteamOrderIDs(_ ids: [String]) { defaults.set(ids, forKey: Key.steamOrder) }
    func sortOption() -> LibrarySortOption {
        defaults.string(forKey: Key.sortOption).flatMap(LibrarySortOption.init(rawValue:)) ?? .availability
    }
    func saveSortOption(_ option: LibrarySortOption) { defaults.set(option.rawValue, forKey: Key.sortOption) }
    func hiddenSteamAppIDs() -> [String] { defaults.stringArray(forKey: Key.hiddenSteamAppIDs) ?? [] }
    func saveHiddenSteamAppIDs(_ ids: [String]) { defaults.set(ids, forKey: Key.hiddenSteamAppIDs) }

    func gameSettings() -> [String: StoredGameSettings] {
        decode([String: StoredGameSettings].self, forKey: Key.gameSettings) ?? [:]
    }

    func saveGameSettings(_ settings: [String: StoredGameSettings]) {
        encode(settings, forKey: Key.gameSettings)
    }

    func sourceHealth() -> [RunnerKind: HealthStatus] {
        let baseline: [RunnerKind: HealthStatus] = [
            .home: .healthy,
            .mac: .healthy,
            .steam: .unknown,
            .wine: .unknown,
        ]
        guard let stored = decode([String: HealthStatus].self, forKey: Key.sourceHealth) else {
            return baseline
        }
        return stored.reduce(into: baseline) { result, entry in
            if let runner = RunnerKind(rawValue: entry.key) {
                result[runner] = entry.value
            }
        }
    }

    func saveSourceHealth(_ health: [RunnerKind: HealthStatus]) {
        encode(Dictionary(uniqueKeysWithValues: health.map { ($0.key.rawValue, $0.value) }), forKey: Key.sourceHealth)
    }

    func wineRuntimes() -> [WineRuntimeRecord] {
        decode([WineRuntimeRecord].self, forKey: Key.wineRuntimes) ?? []
    }

    func saveWineRuntimes(_ runtimes: [WineRuntimeRecord]) {
        encode(runtimes, forKey: Key.wineRuntimes)
    }

    var didCompleteInitialSetup: Bool {
        defaults.bool(forKey: Key.didCompleteInitialSetup)
    }

    func setDidCompleteInitialSetup(_ completed: Bool) {
        defaults.set(completed, forKey: Key.didCompleteInitialSetup)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
