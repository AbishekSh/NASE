import AppKit
import Foundation

struct NASEUninstallPlan: Equatable {
    let managedDataURL: URL
    let auxiliaryURLs: [URL]
    let preferenceDomains: [String]
    let applicationURL: URL?

    static func make(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationURL: URL = Bundle.main.bundleURL
    ) -> NASEUninstallPlan {
        let library = homeURL.appendingPathComponent("Library", isDirectory: true)
        let identifiers = ["com.nase.launcher", "NASE", "SteamWineApp"]
        var auxiliaryURLs: [URL] = []
        for identifier in identifiers {
            auxiliaryURLs.append(
                library.appendingPathComponent("Preferences/\(identifier).plist", isDirectory: false)
            )
            auxiliaryURLs.append(
                library.appendingPathComponent("Caches/\(identifier)", isDirectory: true)
            )
            auxiliaryURLs.append(
                library.appendingPathComponent("HTTPStorages/\(identifier)", isDirectory: true)
            )
            auxiliaryURLs.append(
                library.appendingPathComponent(
                    "Saved Application State/\(identifier).savedState",
                    isDirectory: true
                )
            )
        }

        return NASEUninstallPlan(
            managedDataURL: library.appendingPathComponent(
                "Application Support/MySteamWine",
                isDirectory: true
            ),
            auxiliaryURLs: auxiliaryURLs,
            preferenceDomains: identifiers,
            applicationURL: recyclableApplicationURL(applicationURL)
        )
    }

    private static func recyclableApplicationURL(_ url: URL) -> URL? {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(
                atPath: standardized.appendingPathComponent("Contents/MacOS", isDirectory: true).path
              )
        else {
            return nil
        }
        let path = standardized.path
        guard !path.contains("/Library/Developer/Xcode/DerivedData/"),
              !path.contains("/.build/")
        else {
            return nil
        }
        return standardized
    }
}

enum NASEUninstallError: LocalizedError {
    case couldNotTrashApplication(String)
    case cleanupFailed([String])

    var errorDescription: String? {
        switch self {
        case .couldNotTrashApplication(let detail):
            return "NASE could not move its app bundle to the Trash. \(detail)"
        case .cleanupFailed(let paths):
            return "NASE could not remove: \(paths.joined(separator: ", "))."
        }
    }
}

enum NASEUninstallService {
    static func eraseOwnedData(
        plan: NASEUninstallPlan,
        removeManagedData: Bool,
        fileManager: FileManager = .default
    ) throws {
        var failedPaths: [String] = []
        let targets = (removeManagedData ? [plan.managedDataURL] : []) + plan.auxiliaryURLs
        for target in targets {
            guard fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.removeItem(at: target)
            } catch {
                failedPaths.append(target.path)
            }
        }
        for domain in plan.preferenceDomains {
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        if !failedPaths.isEmpty {
            throw NASEUninstallError.cleanupFailed(failedPaths)
        }
    }

    @MainActor
    static func moveApplicationToTrash(_ applicationURL: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([applicationURL]) { _, error in
                if let error {
                    continuation.resume(
                        throwing: NASEUninstallError.couldNotTrashApplication(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
