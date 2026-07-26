import SwiftUI
import AppKit

@main
struct SteamWineApp: App {
    @State private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("SteamWineWrapper") {
            ContentView(model: model)
                .frame(minWidth: 1180, minHeight: 760)
                .task {
                    if let image = appIconImage() {
                        NSApplication.shared.applicationIconImage = image
                    }
                    activateApplication()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1420, height: 900)
    }

    private func activateApplication() {
        DispatchQueue.main.async {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    private func appIconImage() -> NSImage? {
        if let bundleURL = naseResourceURL(named: "NASE App Logo", withExtension: "icns"),
           let image = NSImage(contentsOf: bundleURL) {
            return image
        }

        if let bundleURL = naseResourceURL(named: "NASE App Logo", withExtension: "png"),
           let image = NSImage(contentsOf: bundleURL) {
            return image
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
        let repoRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let icnsURL = repoRoot.appendingPathComponent("assets/NASE App Logo.icns")
        if let image = NSImage(contentsOf: icnsURL) {
            return image
        }

        let pngURL = repoRoot.appendingPathComponent("assets/NASE App Logo.png")
        return NSImage(contentsOf: pngURL)
    }
}
