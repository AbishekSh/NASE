import Foundation
import Testing
@testable import NASE

@Test func uninstallPlanOnlyTargetsNASEOwnedLibraryLocations() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let application = temporary.appendingPathComponent("Applications/NASE.app", isDirectory: true)
    try FileManager.default.createDirectory(
        at: application.appendingPathComponent("Contents/MacOS", isDirectory: true),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporary) }

    let plan = NASEUninstallPlan.make(homeURL: temporary, applicationURL: application)

    #expect(plan.managedDataURL.path == temporary.appendingPathComponent(
        "Library/Application Support/NASE"
    ).path)
    #expect(plan.legacyManagedDataURL.path == temporary.appendingPathComponent(
        "Library/Application Support/MySteamWine"
    ).path)
    #expect(plan.auxiliaryURLs.allSatisfy {
        $0.standardizedFileURL.path.hasPrefix(
            temporary.appendingPathComponent("Library", isDirectory: true).standardizedFileURL.path + "/"
        )
    })
    #expect(plan.applicationURL == application.standardizedFileURL)
}

@Test func uninstallCleanupPreservesExternalPrefixesAndUserApplications() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let application = temporary.appendingPathComponent("Applications/NASE.app", isDirectory: true)
    try FileManager.default.createDirectory(
        at: application.appendingPathComponent("Contents/MacOS", isDirectory: true),
        withIntermediateDirectories: true
    )
    let externalPrefix = temporary.appendingPathComponent("Games/ExternalPrefix", isDirectory: true)
    try FileManager.default.createDirectory(at: externalPrefix, withIntermediateDirectories: true)
    let externalMarker = externalPrefix.appendingPathComponent("user.reg")
    try "keep".write(to: externalMarker, atomically: true, encoding: .utf8)

    let plan = NASEUninstallPlan.make(homeURL: temporary, applicationURL: application)
    try FileManager.default.createDirectory(
        at: plan.managedDataURL,
        withIntermediateDirectories: true
    )
    try "remove".write(
        to: plan.managedDataURL.appendingPathComponent("sessions.json"),
        atomically: true,
        encoding: .utf8
    )
    try FileManager.default.createDirectory(
        at: plan.legacyManagedDataURL,
        withIntermediateDirectories: true
    )
    if let cache = plan.auxiliaryURLs.first(where: { $0.path.contains("/Caches/") }) {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: temporary) }

    let cleanupPlan = NASEUninstallPlan(
        managedDataURL: plan.managedDataURL,
        legacyManagedDataURL: plan.legacyManagedDataURL,
        auxiliaryURLs: plan.auxiliaryURLs,
        preferenceDomains: [],
        applicationURL: plan.applicationURL
    )
    try NASEUninstallService.eraseOwnedData(plan: cleanupPlan, removeManagedData: true)

    #expect(!FileManager.default.fileExists(atPath: plan.managedDataURL.path))
    #expect(!FileManager.default.fileExists(atPath: plan.legacyManagedDataURL.path))
    #expect(FileManager.default.fileExists(atPath: externalMarker.path))
    #expect(FileManager.default.fileExists(atPath: application.path))
}

@Test func keepingManagedDataStillClearsAuxiliaryFiles() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let plan = NASEUninstallPlan.make(
        homeURL: temporary,
        applicationURL: temporary.appendingPathComponent("NASE")
    )
    try FileManager.default.createDirectory(
        at: plan.managedDataURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: plan.legacyManagedDataURL,
        withIntermediateDirectories: true
    )
    let cache = try #require(plan.auxiliaryURLs.first(where: { $0.path.contains("/Caches/") }))
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let cleanupPlan = NASEUninstallPlan(
        managedDataURL: plan.managedDataURL,
        legacyManagedDataURL: plan.legacyManagedDataURL,
        auxiliaryURLs: plan.auxiliaryURLs,
        preferenceDomains: [],
        applicationURL: plan.applicationURL
    )
    try NASEUninstallService.eraseOwnedData(plan: cleanupPlan, removeManagedData: false)

    #expect(FileManager.default.fileExists(atPath: plan.managedDataURL.path))
    #expect(FileManager.default.fileExists(atPath: plan.legacyManagedDataURL.path))
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(plan.applicationURL == nil)
}

@Test func legacyDataRootAndStoredPathsMigrateToNASE() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let legacy = NASEDataPaths.legacyRootURL(homeURL: temporary)
    let destination = NASEDataPaths.rootURL(homeURL: temporary)
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    try "keep".write(
        to: legacy.appendingPathComponent("sessions.json"),
        atomically: true,
        encoding: .utf8
    )
    let suiteName = "NASEDataPathsTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(
        legacy.appendingPathComponent("runtimes/wine/bin/wine").path,
        forKey: "backend.winePath"
    )
    defaults.set(
        Data("{\"path\":\"\(legacy.path)/bottles/Default\"}".utf8),
        forKey: "library.gameSettings"
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: temporary)
    }

    let resolved = NASEDataPaths.migrateLegacyDataIfNeeded(
        homeURL: temporary,
        defaults: defaults
    )

    #expect(resolved == destination)
    #expect(!FileManager.default.fileExists(atPath: legacy.path))
    #expect(FileManager.default.fileExists(
        atPath: destination.appendingPathComponent("sessions.json").path
    ))
    #expect(defaults.string(forKey: "backend.winePath")?.hasPrefix(destination.path) == true)
    let storedData = try #require(defaults.data(forKey: "library.gameSettings"))
    #expect(String(data: storedData, encoding: .utf8)?.contains(destination.path) == true)
    #expect(String(data: storedData, encoding: .utf8)?.contains(legacy.path) == false)
}
