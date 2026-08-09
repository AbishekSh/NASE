import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

/// Loads cover art asynchronously with downsampling and two-tier caching
/// (in-memory + on-disk), so the library grid never decodes full-resolution
/// images synchronously on the main thread while scrolling.
@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    enum Source: Hashable {
        case local(URL)     // read bytes from a file on disk
        case remote(URL)    // download over HTTP
        case fileIcon(URL)  // the Finder icon for a path (fallback art)
    }

    // NSImage is not Sendable; box it to carry decoded art across the detached
    // task boundary without tripping strict-concurrency diagnostics.
    private struct ImageBox: @unchecked Sendable { let image: NSImage }

    private static let memory: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()
    private static let diskDirectory = NASEDataPaths.artworkCacheURL()

    // Main-actor isolation serializes dedup bookkeeping; the actual decode runs
    // on a detached task so the main thread is never blocked.
    private var inFlight: [String: Task<ImageBox?, Never>] = [:]

    /// Synchronous, non-blocking peek at the in-memory cache. Lets a view show
    /// already-decoded art immediately without a skeleton flash.
    func cachedImage(cacheKey: String, maxPixelSize: CGFloat) -> NSImage? {
        Self.memory.object(forKey: Self.memoryKey(cacheKey, maxPixelSize) as NSString)
    }

    func image(cacheKey: String, sources: [Source], maxPixelSize: CGFloat) async -> NSImage? {
        guard !sources.isEmpty else { return nil }
        let key = Self.memoryKey(cacheKey, maxPixelSize)
        if let cached = Self.memory.object(forKey: key as NSString) { return cached }

        let task: Task<ImageBox?, Never>
        if let existing = inFlight[key] {
            task = existing
        } else {
            let directory = Self.diskDirectory
            task = Task<ImageBox?, Never>.detached(priority: .utility) {
                (await Self.produce(key: key, sources: sources, maxPixelSize: maxPixelSize, directory: directory))
                    .map(ImageBox.init)
            }
            inFlight[key] = task
        }

        let box = await task.value
        inFlight.removeValue(forKey: key)
        if let image = box?.image { Self.memory.setObject(image, forKey: key as NSString) }
        return box?.image
    }

    // MARK: - Production (runs off the main thread via a detached task)

    private nonisolated static func produce(
        key: String,
        sources: [Source],
        maxPixelSize: CGFloat,
        directory: URL
    ) async -> NSImage? {
        let diskURL = diskURL(for: key, in: directory)
        if let data = try? Data(contentsOf: diskURL), let cgImage = downsample(data, maxPixelSize: maxPixelSize) {
            return nsImage(cgImage)
        }
        for source in sources {
            guard let data = await rawData(for: source) else { continue }
            guard let cgImage = downsample(data, maxPixelSize: maxPixelSize) else { continue }
            if let png = pngData(cgImage) { persist(png, to: diskURL, directory: directory) }
            return nsImage(cgImage)
        }
        return nil
    }

    private nonisolated static func rawData(for source: Source) async -> Data? {
        switch source {
        case .local(let url):
            return try? Data(contentsOf: url)
        case .remote(let url):
            guard let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return data
        case .fileIcon(let url):
            // Resolve on the main actor (AppKit) but hand back Sendable bytes.
            return await MainActor.run { NSWorkspace.shared.icon(forFile: url.path).tiffRepresentation }
        }
    }

    private nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private nonisolated static func nsImage(_ cgImage: CGImage) -> NSImage {
        NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private nonisolated static func pngData(_ cgImage: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private nonisolated static func persist(_ data: Data, to url: URL, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private nonisolated static func diskURL(for key: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("png")
    }

    private nonisolated static func memoryKey(_ cacheKey: String, _ maxPixelSize: CGFloat) -> String {
        "\(cacheKey)@\(Int(maxPixelSize))"
    }

    /// Deterministic, pleasant fallback color derived from a stable seed — used
    /// behind the icon on cards with no cover art. Cheap enough for `body`.
    nonisolated static func fallbackColor(for seed: String) -> Color {
        var hash = 5381
        for byte in seed.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.42, brightness: 0.40)
    }
}

/// A cover-art image backed by `ArtworkLoader`. Shows a skeleton shimmer while
/// loading and a caller-supplied fallback when no source resolves.
struct CoverArtwork<Fallback: View>: View {
    let cacheKey: String
    let sources: [ArtworkLoader.Source]
    let maxPixelSize: CGFloat
    var contentMode: ContentMode = .fill
    @ViewBuilder var fallback: () -> Fallback

    @State private var image: NSImage?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
            } else if isLoading && !sources.isEmpty {
                SkeletonPlaceholder()
            } else {
                fallback()
            }
        }
        .task(id: taskIdentity) {
            if let cached = ArtworkLoader.shared.cachedImage(cacheKey: cacheKey, maxPixelSize: maxPixelSize) {
                image = cached
                isLoading = false
                return
            }
            image = nil
            isLoading = true
            let loaded = await ArtworkLoader.shared.image(
                cacheKey: cacheKey,
                sources: sources,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
            image = loaded
            isLoading = false
        }
    }

    // Re-run the loader when the game (cacheKey) or its candidate art changes.
    private var taskIdentity: String { "\(cacheKey)#\(sources.hashValue)" }
}

/// A subtle shimmering placeholder shown while cover art loads.
struct SkeletonPlaceholder: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var animating = false

    var body: some View {
        let base = colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
        let highlight = colorScheme == .dark ? Color.white.opacity(0.10) : Color.white.opacity(0.45)
        base.overlay(
            GeometryReader { geometry in
                LinearGradient(
                    colors: [.clear, highlight, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geometry.size.width * 0.6)
                .offset(x: animating ? geometry.size.width : -geometry.size.width * 0.6)
            }
        )
        .clipped()
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                animating = true
            }
        }
    }
}
