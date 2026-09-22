import Foundation

/// Pure presentation policy for a library. It does not discover games, mutate
/// persisted state, or know which view is displaying the result.
enum LibraryOrdering {
    static func order(
        _ games: [LibraryGame],
        by option: LibrarySortOption,
        manualOrderIDs: [String] = [],
        lastPlayed: (LibraryGame) -> Date?
    ) -> [LibraryGame] {
        switch option {
        case .manual:
            guard !manualOrderIDs.isEmpty else { return games }
            let byID = Dictionary(uniqueKeysWithValues: games.map { ($0.pinID, $0) })
            let ordered = manualOrderIDs.compactMap { byID[$0] }
            let knownIDs = Set(manualOrderIDs)
            let newlyDiscovered = games
                .filter { !knownIDs.contains($0.pinID) }
                .sorted(by: availabilityThenTitle)
            return ordered + newlyDiscovered
        case .availability:
            return games.sorted(by: availabilityThenTitle)
        case .title:
            return games.sorted(by: titleThenIdentity)
        case .size:
            return games.sorted {
                let lhs = numericSizeValue(for: $0.statsText)
                let rhs = numericSizeValue(for: $1.statsText)
                return lhs == rhs ? titleThenIdentity($0, $1) : lhs > rhs
            }
        case .recent:
            return games.sorted {
                let lhs = lastPlayed($0) ?? .distantPast
                let rhs = lastPlayed($1) ?? .distantPast
                return lhs == rhs ? availabilityThenTitle($0, $1) : lhs > rhs
            }
        }
    }

    private static func availabilityThenTitle(_ lhs: LibraryGame, _ rhs: LibraryGame) -> Bool {
        let lhsRank = availabilityRank(lhs)
        let rhsRank = availabilityRank(rhs)
        return lhsRank == rhsRank ? titleThenIdentity(lhs, rhs) : lhsRank < rhsRank
    }

    private static func availabilityRank(_ game: LibraryGame) -> Int {
        if game.installURL != nil || game.status.localizedCaseInsensitiveCompare("Installed") == .orderedSame {
            return 0
        }
        return 1
    }

    private static func titleThenIdentity(_ lhs: LibraryGame, _ rhs: LibraryGame) -> Bool {
        let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhs.pinID < rhs.pinID
    }

    private static func numericSizeValue(for statsText: String?) -> Double {
        guard let statsText else { return 0 }
        let parts = statsText.split(separator: "•").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let sizePart = parts.first else { return 0 }
        let scanner = Scanner(string: sizePart)
        guard let value = scanner.scanDouble() else { return 0 }
        let unit = sizePart.replacingOccurrences(of: "[0-9. ]", with: "", options: .regularExpression).lowercased()
        switch unit {
        case "kb": return value * 1_000
        case "mb": return value * 1_000_000
        case "gb": return value * 1_000_000_000
        case "tb": return value * 1_000_000_000_000
        default: return value
        }
    }
}
