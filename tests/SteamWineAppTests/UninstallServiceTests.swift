import Foundation
import Testing
@testable import SteamWineApp

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
    if let cache = plan.auxiliaryURLs.first(where: { $0.path.contains("/Caches/") }) {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: temporary) }

    let cleanupPlan = NASEUninstallPlan(
        managedDataURL: plan.managedDataURL,
        auxiliaryURLs: plan.auxiliaryURLs,
        preferenceDomains: [],
        applicationURL: plan.applicationURL
    )
    try NASEUninstallService.eraseOwnedData(plan: cleanupPlan, removeManagedData: true)

    #expect(!FileManager.default.fileExists(atPath: plan.managedDataURL.path))
    #expect(FileManager.default.fileExists(atPath: externalMarker.path))
    #expect(FileManager.default.fileExists(atPath: application.path))
}

@Test func keepingManagedDataStillClearsAuxiliaryFiles() throws {
    let temporary = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let plan = NASEUninstallPlan.make(
        homeURL: temporary,
        applicationURL: temporary.appendingPathComponent("SteamWineApp")
    )
    try FileManager.default.createDirectory(
        at: plan.managedDataURL,
        withIntermediateDirectories: true
    )
    let cache = try #require(plan.auxiliaryURLs.first(where: { $0.path.contains("/Caches/") }))
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }

    let cleanupPlan = NASEUninstallPlan(
        managedDataURL: plan.managedDataURL,
        auxiliaryURLs: plan.auxiliaryURLs,
        preferenceDomains: [],
        applicationURL: plan.applicationURL
    )
    try NASEUninstallService.eraseOwnedData(plan: cleanupPlan, removeManagedData: false)

    #expect(FileManager.default.fileExists(atPath: plan.managedDataURL.path))
    #expect(!FileManager.default.fileExists(atPath: cache.path))
    #expect(plan.applicationURL == nil)
}
