import AppKit
import CryptoKit
import Foundation

struct NASEUpdateManifest: Codable, Hashable {
    let version: String
    let build: String
    let downloadURL: String
    let sha256: String
    let releaseNotesURL: String?
    let minimumMacOS: String
    let publishedAt: String
    let signature: String

    enum CodingKeys: String, CodingKey {
        case version, build, sha256, signature
        case downloadURL = "download_url"
        case releaseNotesURL = "release_notes_url"
        case minimumMacOS = "minimum_macos"
        case publishedAt = "published_at"
    }

    var canonicalData: Data {
        [version, build, downloadURL, sha256.lowercased(), releaseNotesURL ?? "", minimumMacOS, publishedAt]
            .joined(separator: "\n")
            .data(using: .utf8) ?? Data()
    }
}

enum NASEUpdateError: LocalizedError {
    case notConfigured
    case invalidManifestURL
    case invalidSigningKey
    case invalidSignature
    case invalidDownloadURL
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Updates are not configured in this development build."
        case .invalidManifestURL: "The update feed URL is invalid."
        case .invalidSigningKey: "The app's update verification key is invalid."
        case .invalidSignature: "The update manifest signature could not be verified."
        case .invalidDownloadURL: "The update download URL is invalid."
        case .checksumMismatch: "The downloaded update did not match its signed checksum."
        }
    }
}

enum NASEUpdateService {
    static func check() async throws -> NASEUpdateManifest {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NASEUpdateManifestURL") as? String,
              !value.isEmpty else { throw NASEUpdateError.notConfigured }
        guard let url = URL(string: value), url.scheme == "https" else {
            throw NASEUpdateError.invalidManifestURL
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NASEUpdateError.invalidManifestURL
        }
        let manifest = try JSONDecoder().decode(NASEUpdateManifest.self, from: data)
        try verify(manifest)
        return manifest
    }

    static func verify(_ manifest: NASEUpdateManifest) throws {
        guard let keyValue = Bundle.main.object(forInfoDictionaryKey: "NASEUpdatePublicKey") as? String,
              let keyData = Data(base64Encoded: keyValue),
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else {
            throw NASEUpdateError.invalidSigningKey
        }
        guard let signature = Data(base64Encoded: manifest.signature),
              publicKey.isValidSignature(signature, for: manifest.canonicalData) else {
            throw NASEUpdateError.invalidSignature
        }
    }

    static func isNewer(_ manifest: NASEUpdateManifest) -> Bool {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let versionOrder = currentVersion.compare(manifest.version, options: .numeric)
        if versionOrder == .orderedAscending { return true }
        return versionOrder == .orderedSame && currentBuild.compare(manifest.build, options: .numeric) == .orderedAscending
    }

    static func downloadAndOpen(_ manifest: NASEUpdateManifest) async throws -> URL {
        guard let url = URL(string: manifest.downloadURL), url.scheme == "https" else {
            throw NASEUpdateError.invalidDownloadURL
        }
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NASEUpdateError.invalidDownloadURL
        }
        guard try sha256(of: temporaryURL) == manifest.sha256.lowercased() else {
            throw NASEUpdateError.checksumMismatch
        }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        let extensionName = url.pathExtension.isEmpty ? "dmg" : url.pathExtension
        let destination = downloads.appendingPathComponent("NASE-\(manifest.version).\(extensionName)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        _ = await MainActor.run { NSWorkspace.shared.open(destination) }
        return destination
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
