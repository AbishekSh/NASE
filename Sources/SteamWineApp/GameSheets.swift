import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DragBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.black.opacity(0.75))
            .clipShape(Capsule())
    }
}

struct GameSettingsSheet: View {
    @Bindable var model: AppViewModel
    let game: LibraryGame

    @State private var launchArguments: String = ""
    @State private var workingDirectoryPath: String = ""
    @State private var environmentText: String = ""
    @State private var graphicsBackend: GraphicsBackendOption = .dxmt
    @State private var launchExecutablePath: String = ""
    @State private var customBannerPath: String = ""
    @State private var collection: GameCollection = .none
    @State private var assignedBottleName: String = ""
    @State private var assignedExternalPrefix: String = ""
    @State private var legacyDirectXEnabled: Bool = false
    @State private var legacyDirectXSource: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.title2.weight(.bold))
                    Text("Launch preferences")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    model.closeGameSettings()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    settingsSection("Quick Start", subtitle: "Pick how this title should launch without having to think about backend commands.") {
                        labeledField("Extra Launch Arguments", text: $launchArguments)
                        labeledField("Working Folder", text: $workingDirectoryPath, browse: pickDirectory)
                        labeledField("Launch File", text: $launchExecutablePath, browse: pickExecutable)
                    }
                    if game.runner == .steam {
                        Text("If you set a launch executable here, this Steam title will launch through that executable instead of the plain App ID path whenever custom per-game settings are needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if game.runner == .wine {
                        settingsSection("Game File", subtitle: "Folder-based imports can point at the exact EXE you want to use.") {
                            HStack(spacing: 10) {
                                Button("Choose from Imported Folder") {
                                    if let value = pickExecutableFromInstallFolder() {
                                        launchExecutablePath = value
                                        if workingDirectoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            workingDirectoryPath = URL(fileURLWithPath: value).deletingLastPathComponent().path
                                        }
                                    }
                                }
                                .disabled(!hasDirectoryInstallRoot)

                                if !hasDirectoryInstallRoot {
                                    Text("Import a folder-based game to use this shortcut.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    settingsSection("Appearance", subtitle: "Swap in your own banner art for the library card.") {
                        labeledField("Custom Banner", text: $customBannerPath, browse: pickImage)
                    }
                    settingsSection("Container", subtitle: "Override the default bottle or external prefix for just this title.") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Assigned Bottle")
                                .font(.subheadline.weight(.semibold))
                            Picker("Assigned Bottle", selection: $assignedBottleName) {
                                Text("Default").tag("")
                                ForEach(model.managedBottleNames, id: \.self) { name in
                                    Text(name).tag(name)
                                }
                            }
                            .pickerStyle(.menu)
                            .disabled(!assignedExternalPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            if !assignedExternalPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Using an external prefix overrides the bottle selection.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        labeledField("Assigned External Prefix", text: $assignedExternalPrefix, browse: pickDirectory)
                        if !assignedBottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear Bottle Assignment") {
                                assignedBottleName = ""
                            }
                            .buttonStyle(.borderless)
                        }
                        if !assignedExternalPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button("Clear External Prefix") {
                                assignedExternalPrefix = ""
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    settingsSection("Rendering", subtitle: "Choose the graphics path this title should prefer.") {
                        let detectedArchitecture = model.windowsExecutableArchitecture(
                            atPath: launchExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        Picker("Graphics Backend", selection: $graphicsBackend) {
                            ForEach(GraphicsBackendOption.allCases) { backend in
                                Text(backend.rawValue).tag(backend)
                            }
                        }
                        .pickerStyle(.segmented)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: graphicsBackend == .dxvk ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                                .foregroundStyle(graphicsBackend == .dxvk ? .orange : .green)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(graphicsBackend.profileSummary)
                                    .font(.subheadline.weight(.semibold))
                                Text("Uses dedicated bottle: \(profileBottleName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if graphicsBackend == .dxvk {
                                    Text("Unavailable until the complete matched Vulkan stack is installed.")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                if detectedArchitecture == "32-bit x86 (WoW64)" {
                                    Text("32-bit application detected. Wine will use WoW64.")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                    if graphicsBackend == .d3dmetal {
                                        Text("D3DMetal is 64-bit only. Choose DXMT or None for this application.")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }

                        let effectiveOverrides = model.effectiveGraphicsOverrides(
                            for: game,
                            graphicsBackend: graphicsBackend,
                            assignedBottleName: assignedBottleName,
                            assignedExternalPrefix: assignedExternalPrefix,
                            environmentText: environmentText
                        )

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Effective Graphics Overrides")
                                .font(.subheadline.weight(.semibold))
                            overrideRow("Target", effectiveOverrides.targetLabel)
                            overrideRow("Prefix", effectiveOverrides.prefixPath, monospaced: true)
                            overrideRow("Backend", effectiveOverrides.graphicsBackend.rawValue)
                            overrideRow(
                                "Registry",
                                effectiveOverrides.registryOverrides.isEmpty
                                    ? "No persistent DLL overrides found in this prefix."
                                    : effectiveOverrides.registryOverrides.joined(separator: "\n"),
                                monospaced: true
                            )
                            overrideRow(
                                "Launch",
                                effectiveOverrides.launchOverrides ?? "No extra launch-time WINEDLLOVERRIDES for this app.",
                                monospaced: true
                            )
                            if !effectiveOverrides.compatibilityWarnings.isEmpty {
                                overrideRow(
                                    "Warning",
                                    effectiveOverrides.compatibilityWarnings.joined(separator: "\n")
                                )
                            }
                            if !effectiveOverrides.environmentWarnings.isEmpty {
                                overrideRow(
                                    "Custom Env",
                                    effectiveOverrides.environmentWarnings.joined(separator: "\n"),
                                    monospaced: true
                                )
                                Text("These environment variables can override what the launcher would normally apply.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    settingsSection("Library", subtitle: "Use collections to keep testing, favorites, and finished games tidy.") {
                        Picker("Collection", selection: $collection) {
                            ForEach(GameCollection.allCases) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    settingsSection("Advanced", subtitle: "Optional environment variables for one-off compatibility tweaks.") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Environment Variables")
                                .font(.subheadline.weight(.semibold))
                            TextEditor(text: $environmentText)
                                .frame(minHeight: 160)
                                .padding(8)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    settingsSection("Legacy DirectX Acceleration", subtitle: "Translate 32-bit DirectDraw/Direct3D 1–7 through a private D3D11 overlay without modifying Steam's game files.") {
                        Toggle("Enable per-game dgVoodoo2 overlay", isOn: $legacyDirectXEnabled)
                        labeledField("dgVoodoo2 ZIP or Folder", text: $legacyDirectXSource, browse: pickLegacyDirectXSource)
                            .disabled(!legacyDirectXEnabled)
                        Text("You must obtain dgVoodoo2 yourself. Enabling this confirms that you accept its license. NASE copies only the 32-bit wrapper DLLs into a removable overlay; the shared installation is left untouched.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if legacyDirectXEnabled && graphicsBackend == .d3dmetal {
                            Text("Legacy acceleration requires a 32-bit D3D11 backend. Choose DXMT or None, not D3DMetal.")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        Button("Reset Installed Overlay", role: .destructive) {
                            model.resetLegacyDirectXOverlay(for: game)
                        }
                        .disabled(model.isBusy)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Divider()

            HStack {
                Button("Cancel") {
                    model.closeGameSettings()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    model.saveSettings(
                        for: game,
                        launchArguments: launchArguments,
                        workingDirectoryPath: workingDirectoryPath,
                        environmentText: environmentText,
                        graphicsBackend: graphicsBackend,
                        launchExecutablePath: launchExecutablePath,
                        customBannerPath: customBannerPath,
                        collection: collection,
                        assignedBottleName: assignedBottleName,
                        assignedExternalPrefix: assignedExternalPrefix,
                        legacyDirectXEnabled: legacyDirectXEnabled,
                        legacyDirectXSource: legacyDirectXSource
                    )
                    model.closeGameSettings()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    legacyDirectXEnabled
                        && (legacyDirectXSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || graphicsBackend == .d3dmetal)
                )
            }
            .padding(24)
            .background(.regularMaterial)
        }
        .frame(width: 680, height: 640)
        .task {
            let settings = model.settings(for: game)
            launchArguments = settings.launchArguments
            workingDirectoryPath = settings.workingDirectoryPath
            environmentText = settings.environmentText
            graphicsBackend = settings.graphicsBackend
            launchExecutablePath = settings.launchExecutablePath
            customBannerPath = settings.customBannerPath
            collection = settings.collection
            assignedBottleName = settings.assignedBottleName
            assignedExternalPrefix = settings.assignedExternalPrefix
            legacyDirectXEnabled = settings.legacyDirectXEnabled == true
            legacyDirectXSource = settings.legacyDirectXSource ?? ""
        }
    }

    private var profileBottleName: String {
        let base = assignedBottleName.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(base.isEmpty ? model.backendContext.bottleName : base)-\(graphicsBackend.bottleSuffix)"
    }

    private func labeledField(_ title: String, text: Binding<String>, browse: (() -> String?)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
                if let browse {
                    Button("Browse") {
                        if let value = browse() {
                            text.wrappedValue = value
                        }
                    }
                }
            }
        }
    }

    private func settingsSection<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
            content()
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func overrideRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .subheadline)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pickDirectory() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func pickExecutable() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe"),
            UTType(filenameExtension: "bat"),
            UTType(filenameExtension: "cmd"),
            UTType(filenameExtension: "msi"),
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func pickLegacyDirectXSource() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [UTType.zip]
        panel.allowsMultipleSelection = false
        panel.prompt = "Select dgVoodoo2"
        panel.message = "Choose the official dgVoodoo2 ZIP archive or extracted folder."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private var hasDirectoryInstallRoot: Bool {
        guard let installURL = game.installURL else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: installURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func pickExecutableFromInstallFolder() -> String? {
        guard let installURL = game.installURL, hasDirectoryInstallRoot else {
            return pickExecutable()
        }

        let panel = NSOpenPanel()
        panel.directoryURL = installURL
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "exe"),
            UTType(filenameExtension: "bat"),
            UTType(filenameExtension: "cmd"),
            UTType(filenameExtension: "msi"),
        ].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Launch EXE"
        panel.message = "Select the Windows executable this entry should launch."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func pickImage() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .image]
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

struct GameDetailsSheet: View {
    @Bindable var model: AppViewModel
    let game: LibraryGame

    var body: some View {
        let settings = model.settings(for: game)
        let launchStatus = model.launchStatus(for: game)

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.title2.weight(.bold))
                    Text(game.runner.rawValue)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    model.closeGameDetails()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionHeader("Artwork")
                    BannerArtwork(
                        url: game.bannerURL,
                        title: game.title,
                        height: 220,
                        installURL: game.installURL,
                        runner: game.runner,
                        appid: game.backendID,
                        steamCacheURL: model.steamLibraryCacheURL
                    )

                    sectionHeader("Actions")
                    if let launchStatus {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(launchColor(for: launchStatus.phase))
                                    .frame(width: 9, height: 9)
                                Text(launchStatus.phase.rawValue)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(launchStatus.updatedAt, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(launchStatus.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        Button(game.status.localizedCaseInsensitiveContains("installer") ? "Run Installer" : "Play") {
                            model.launch(game)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Debug") {
                            model.debugLaunch(game)
                        }

                        Button("Logs") {
                            model.openLogViewer(for: game)
                        }

                        Button("Settings") {
                            model.openGameSettingsFromDetails(for: game)
                        }

                        if launchStatus != nil {
                            Button("Clear Status") {
                                model.clearLaunchStatus(for: game)
                            }
                        }
                    }

                    sectionHeader("Details")
                    VStack(alignment: .leading, spacing: 12) {
                        metadataRow("Source", game.runner.rawValue)
                        if let installSize = model.installSizeText(for: game) {
                            metadataRow("Install Size", installSize)
                        }
                        if let playtime = model.playtimeText(for: game) {
                            metadataRow("Playtime", playtime)
                        }
                        if let lastPlayed = model.lastPlayedText(for: game) {
                            metadataRow("Last Played", lastPlayed)
                        }
                        metadataRow("Collection", settings.collection.rawValue)
                        metadataRow("Target", targetSummary(settings))
                        ForEach(model.explicitMetadataRows(for: game), id: \.label) { row in
                            metadataRow(row.label, row.value)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(16)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if game.runner == .wine {
                        sectionHeader("Wine Target")
                        VStack(alignment: .leading, spacing: 12) {
                            Text("This entry can use a custom executable, working directory, environment variables, graphics backend, and assigned bottle or prefix.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("Open Game Settings") {
                                model.openGameSettingsFromDetails(for: game)
                            }
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(24)
            }
        }
        .frame(width: 760, height: 700)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.headline.weight(.semibold))
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline)
        }
    }

    private func launchColor(for phase: GameLaunchPhase) -> Color {
        switch phase {
        case .launching:
            return Color(hex: "#D9B650")
        case .stopping:
            return Color(hex: "#D96C6C")
        case .running:
            return Color(hex: "#6DBB7A")
        case .exited:
            return .secondary
        case .failed:
            return Color(hex: "#D96C6C")
        }
    }

    private func targetSummary(_ settings: StoredGameSettings) -> String {
        if !settings.assignedExternalPrefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return settings.assignedExternalPrefix
        }
        if !settings.assignedBottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return settings.assignedBottleName
        }
        return "Default target"
    }
}

struct LogViewerSheet: View {
    @Bindable var model: AppViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selectedLogTitle)
                    .font(.title3.weight(.bold))
                Spacer()
                if !model.selectedLogEntries.isEmpty {
                    Picker("Log File", selection: $model.selectedLogEntryID) {
                        ForEach(model.selectedLogEntries) { entry in
                            Text(entry.title).tag(Optional(entry.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
                Button("Copy") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(model.selectedLogEntry?.text ?? model.selectedLogText, forType: .string)
                }
                Button("Refresh") {
                    model.refreshLogViewer()
                }
                Button("Done") {
                    model.closeLogViewer()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            VStack(spacing: 0) {
                if let highlightedError = highlightedErrorExcerpt {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Likely Error")
                            .font(.headline)
                        Text(highlightedError)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                }

                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        Text(logText)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .padding(24)
                            .id("log-top")
                    }
                    .onChange(of: model.selectedLogEntryID) { _, _ in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo("log-top", anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(width: 860, height: 640)
    }

    private var logText: String {
        model.selectedLogEntry?.text ?? model.selectedLogText
    }

    private var highlightedErrorExcerpt: String? {
        let interestingLines = logText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter {
                let lowered = $0.lowercased()
                return lowered.contains("err:")
                    || lowered.contains("error")
                    || lowered.contains("exception")
                    || lowered.contains("fatal")
                    || lowered.contains("unhandled")
            }

        guard !interestingLines.isEmpty else { return nil }
        return interestingLines.suffix(8).joined(separator: "\n")
    }
}
