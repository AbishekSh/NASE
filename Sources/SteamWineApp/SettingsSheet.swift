import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SteamIdentityAction {
    case capture(String)
    case provision(String)
    case signOut(String)
    case forget

    var isDestructive: Bool {
        switch self {
        case .signOut, .forget: return true
        case .capture, .provision: return false
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case accounts = "Accounts"
    case compatibility = "Compatibility"
    case runtimes = "Runtimes"
    case jobs = "Jobs"
    case advanced = "Advanced"

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .accounts: return "person.crop.circle"
        case .compatibility: return "checkmark.shield"
        case .runtimes: return "shippingbox"
        case .jobs: return "clock.arrow.circlepath"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    var detail: String {
        switch self {
        case .general:
            return "Updates and the default launch target"
        case .accounts:
            return "Shared sign-in and account controls"
        case .compatibility:
            return "System readiness and graphics profiles"
        case .runtimes:
            return "Install and manage Wine engines"
        case .jobs:
            return "Current work, results, and history"
        case .advanced:
            return "Repair tools, paths, commands, and logs"
        }
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppViewModel

    @State private var winePath: String = ""
    @State private var dxmtSource: String = ""
    @State private var dxvkSource: String = ""
    @State private var d3dMetalSource: String = ""
    @State private var gptkWinePath: String = ""
    @State private var bottleName: String = ""
    @State private var externalPrefix: String = ""
    @State private var useExternalPrefix: Bool = false
    @State private var validationMessage: String = ""
    @State private var pendingDependencyInstall: String?
    @State private var showDependencyConfirmation: Bool = false
    @State private var showRecommendedBootstrapConfirmation: Bool = false
    @State private var showGPTKImportConfirmation: Bool = false
    @State private var pendingProfileReset: GraphicsBackendOption?
    @State private var showProfileResetConfirmation: Bool = false
    @State private var selectedSteamIdentityBottle: String = ""
    @State private var pendingSteamIdentityAction: SteamIdentityAction?
    @State private var showSteamIdentityConfirmation: Bool = false
    @State private var showUninstallConfirmation: Bool = false
    @State private var removeManagedDataOnUninstall: Bool = true
    @State private var selectedSection: SettingsSection = .general

    var body: some View {
        VStack(spacing: 0) {
            settingsHeader
                .padding(.horizontal, 24)
                .padding(.vertical, 18)

            Divider()

            HStack(spacing: 0) {
                settingsNavigation

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        settingsSectionHeader
                        settingsSelectedContent
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            Divider()
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Test Settings") {
                    validationMessage = model.testSettings(
                        winePath: winePath,
                        dxmtSource: dxmtSource,
                        bottleName: bottleName,
                        externalPrefix: externalPrefix,
                        useExternalPrefix: useExternalPrefix
                    )
                    + "\n"
                    + model.validateDXVKSourceForWizard(dxvkSource).joined(separator: "\n")
                    + "\n"
                    + model.validateD3DMetalSourceForWizard(d3dMetalSource).joined(separator: "\n")
                    selectedSection = .advanced
                }
                Button("Save Settings") {
                    model.applySettings(
                        winePath: winePath,
                        dxmtSource: dxmtSource,
                        dxvkSource: dxvkSource,
                        d3dMetalSource: d3dMetalSource,
                        gptkWinePath: gptkWinePath,
                        bottleName: bottleName,
                        externalPrefix: externalPrefix,
                        useExternalPrefix: useExternalPrefix
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 980, height: 740)
        .background(themeBackground)
        .task {
            model.refreshWineRuntimes()
            model.refreshRuntimeCenter()
            model.refreshDependencyStatus()
            model.refreshSteamIdentityStatus()
            winePath = model.backendContext.winePath
            dxmtSource = model.backendContext.dxmtSource
            dxvkSource = model.backendContext.dxvkSource
            d3dMetalSource = model.backendContext.d3dMetalSource
            gptkWinePath = model.backendContext.gptkWinePath
            bottleName = model.backendContext.bottleName
            externalPrefix = model.backendContext.externalPrefix ?? ""
            useExternalPrefix = !(model.backendContext.externalPrefix ?? "").isEmpty
            selectedSteamIdentityBottle = model.backendContext.bottleName
        }
        .onChange(of: model.backendContext.dxmtSource) { _, newValue in
            dxmtSource = newValue
        }
        .onChange(of: model.backendContext.winePath) { _, newValue in
            winePath = newValue
        }
        .onChange(of: model.backendContext.dxvkSource) { _, newValue in
            dxvkSource = newValue
        }
        .onChange(of: model.backendContext.gptkWinePath) { _, newValue in
            gptkWinePath = newValue
        }
        .onChange(of: model.backendContext.d3dMetalSource) { _, newValue in
            d3dMetalSource = newValue
        }
        .alert("Install Dependency?", isPresented: $showDependencyConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingDependencyInstall = nil
            }
            Button("Install") {
                guard let dependency = pendingDependencyInstall else { return }
                model.installHostDependency(id: dependency, confirmLicense: dependency == "rosetta")
                pendingDependencyInstall = nil
            }
        } message: {
            Text(dependencyConfirmationMessage)
        }
        .alert("Set Up Recommended Environment?", isPresented: $showRecommendedBootstrapConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                model.startRecommendedBootstrap(confirmRosettaLicense: true)
            }
        } message: {
            Text(recommendedBootstrapConfirmationMessage)
        }
        .alert("Install Game Porting Toolkit?", isPresented: $showGPTKImportConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Accept and Install") {
                model.importGPTK(confirmLicense: true)
            }
        } message: {
            Text("NASE will copy the detected Game Porting Toolkit installation into its managed runtime folder. Continue only if you have read and accept Apple’s license included with the Toolkit.")
        }
        .alert("Delete Compatibility Profile?", isPresented: $showProfileResetConfirmation) {
            Button("Cancel", role: .cancel) { pendingProfileReset = nil }
            Button("Delete Profile", role: .destructive) {
                guard let profile = pendingProfileReset else { return }
                model.resetCompatibilityProfile(profile)
                pendingProfileReset = nil
            }
        } message: {
            Text("This removes the profile's private Steam installation, Windows prefix, renderer files, caches, and logs. Shared game files are kept, and NASE can recreate the profile the next time you use it.")
        }
        .alert("Change Shared Steam Login?", isPresented: $showSteamIdentityConfirmation) {
            Button("Cancel", role: .cancel) { pendingSteamIdentityAction = nil }
            Button(steamIdentityConfirmationButton, role: pendingSteamIdentityAction?.isDestructive == true ? .destructive : nil) {
                performPendingSteamIdentityAction()
            }
        } message: {
            Text(steamIdentityConfirmationMessage)
        }
        .alert("Uninstall NASE?", isPresented: $showUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                model.uninstallNASE(removeManagedData: removeManagedDataOnUninstall)
            }
        } message: {
            Text(uninstallConfirmationMessage)
        }
    }

    private var settingsColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 320), spacing: 14),
            GridItem(.flexible(minimum: 320), spacing: 14)
        ]
    }

    private var settingsOperationCards: [OperationCard] {
        model.operationCards.filter { operation in
            switch operation.kind {
            case .installDXMT, .installD3DMetal, .openSteam, .refreshGames, .launchSelectedGame:
                return false
            case .setupMetal, .doctor, .doctorFix, .winetricks, .winecfg, .killWine:
                return true
            }
        }
    }

    private var settingsHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(themeForeground)
                Text(model.settingsSummary)
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
                    .lineLimit(2)
            }
            Spacer()
            Button("Setup Wizard") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.openSetupWizard() }
            }
        }
    }

    private var settingsNavigation: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: section.symbolName)
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 22)
                        Text(section.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(selectedSection == section ? themeForeground : themeMutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(selectedSection == section ? themePanelRaised : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Spacer()

            if let job = model.currentOperationJob {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working")
                            .font(.caption.weight(.semibold))
                        Text(job.message)
                            .font(.caption2)
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(themeMutedForeground)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(themePanel)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onTapGesture { selectedSection = .jobs }
            }
        }
        .padding(14)
        .frame(width: 205)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(themePanel.opacity(0.55))
    }

    private var settingsSectionHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(selectedSection.rawValue)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundStyle(themeForeground)
            Text(selectedSection.detail)
                .font(.subheadline)
                .foregroundStyle(themeMutedForeground)
        }
    }

    @ViewBuilder
    private var settingsSelectedContent: some View {
        switch selectedSection {
        case .general:
            settingsReleasePanel
            settingsTargetPanel
            settingsUninstallPanel
        case .accounts:
            settingsSteamIdentityPanel
        case .compatibility:
            settingsDependencyPanel
            settingsCompatibilityProfilesPanel
        case .runtimes:
            settingsRuntimeCenterPanel
        case .jobs:
            if model.currentOperationJob != nil {
                settingsCurrentOperationPanel
            }
            if model.latestDoctorResult != nil || model.latestSetupResult != nil {
                settingsResultsPanel
            }
            settingsJobsPanel
        case .advanced:
            settingsOperationsPanel
            settingsAdvancedTargetPanel
            settingsGraphicsPanel
            settingsCommandPanel
            settingsActivityPanel
            if !validationMessage.isEmpty {
                settingsValidationPanel
            }
        }
    }

    private var settingsReleasePanel: some View {
        settingsSection("App Updates") {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.updateStatusMessage)
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
                HStack(spacing: 10) {
                    Button("Check for Updates") { model.checkForUpdates() }
                        .disabled(model.isCheckingForUpdates || model.isDownloadingUpdate)
                    if model.availableUpdate != nil {
                        Button(model.isDownloadingUpdate ? "Downloading…" : "Download Verified Update") {
                            model.downloadAvailableUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isDownloadingUpdate)
                    }
                    if model.isCheckingForUpdates || model.isDownloadingUpdate {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private var settingsUninstallPanel: some View {
        settingsSection("Uninstall NASE") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stop NASE-managed Wine processes, clear app settings and caches, and move NASE.app to the Trash.")
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)

                Toggle(
                    "Also delete managed bottles, runtimes, logs, and downloaded Epic/GOG games",
                    isOn: $removeManagedDataOnUninstall
                )

                Text("Imported executables, native Mac apps, external Wine prefixes, and Steam libraries outside NASE's managed folder are never deleted.")
                    .font(.caption)
                    .foregroundStyle(themeMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)

                Text(model.uninstallApplicationPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(themeMutedForeground)
                    .textSelection(.enabled)

                if !model.uninstallStatusMessage.isEmpty {
                    Text(model.uninstallStatusMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.isUninstallingNASE ? themeMutedForeground : .red)
                }

                HStack(spacing: 10) {
                    Button("Uninstall NASE…", role: .destructive) {
                        showUninstallConfirmation = true
                    }
                    .disabled(!model.canUninstallApplication || model.isUninstallingNASE)
                    if model.isUninstallingNASE {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
    }

    private var uninstallConfirmationMessage: String {
        if removeManagedDataOnUninstall {
            return """
            NASE.app will be moved to the Trash. Everything under ~/Library/Application Support/NASE—including managed bottles, runtimes, logs, protected Steam login data, and downloaded Epic/GOG games—will be permanently deleted.

            External prefixes, imported apps, and Steam libraries outside that folder will remain untouched.
            """
        }
        return """
        NASE.app will be moved to the Trash and its settings and caches will be removed. The managed data under ~/Library/Application Support/NASE will be kept so it can be reused after reinstalling NASE.
        """
    }

    private var settingsSteamIdentityPanel: some View {
        settingsSection("Steam Login") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: model.steamIdentityStatus?.available == true ? "checkmark.shield.fill" : "person.badge.key")
                        .foregroundStyle(model.steamIdentityStatus?.available == true ? Color.green : themeMutedForeground)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.steamIdentityStatus?.available == true ? "Protected login saved" : "No shared login saved")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(themeForeground)
                        Text(steamIdentityStatusDetail)
                            .font(.caption)
                            .foregroundStyle(themeMutedForeground)
                    }
                    Spacer()
                    Button { model.refreshSteamIdentityStatus() } label: { Image(systemName: "arrow.clockwise") }
                }

                if let active = model.steamIdentityStatus?.activeSteamProfiles, !active.isEmpty {
                    Label("Close Windows Steam in: \(active.joined(separator: ", "))", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 10) {
                    Picker("Profile", selection: $selectedSteamIdentityBottle) {
                        ForEach(model.allManagedSteamBottleNames, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 310)
                    Button("Save Login From Profile") {
                        pendingSteamIdentityAction = .capture(selectedSteamIdentityBottle)
                        showSteamIdentityConfirmation = true
                    }
                    Button("Apply Login") {
                        pendingSteamIdentityAction = .provision(selectedSteamIdentityBottle)
                        showSteamIdentityConfirmation = true
                    }
                    .disabled(model.steamIdentityStatus?.available != true)
                }

                HStack(spacing: 10) {
                    Button("Sign Out This Profile") {
                        pendingSteamIdentityAction = .signOut(selectedSteamIdentityBottle)
                        showSteamIdentityConfirmation = true
                    }
                    Button("Forget Steam Login", role: .destructive) {
                        pendingSteamIdentityAction = .forget
                        showSteamIdentityConfirmation = true
                    }
                    .disabled(model.steamIdentityStatus?.available != true)
                }

                Text("NASE copies only the required Steam authentication metadata while every Windows Steam instance is stopped. Bottles, renderers, registries, caches, and logs stay isolated. Steam may still request your password or Steam Guard when it invalidates a session.")
                    .font(.caption)
                    .foregroundStyle(themeMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var steamIdentityStatusDetail: String {
        guard let status = model.steamIdentityStatus else { return "Checking protected login status…" }
        guard status.available else { return "Sign in normally in one bottle, enable Remember Me, then fully close Steam." }
        let source = status.sourceBottle ?? "a Steam profile"
        return "Captured from \(source) • applied to \(status.provisionedProfiles.count) profile(s)"
    }

    private var steamIdentityConfirmationButton: String {
        switch pendingSteamIdentityAction {
        case .capture: return "Save Login"
        case .provision: return "Apply Login"
        case .signOut: return "Sign Out"
        case .forget: return "Forget Login"
        case nil: return "Continue"
        }
    }

    private var steamIdentityConfirmationMessage: String {
        switch pendingSteamIdentityAction {
        case .capture(let bottle):
            return "Save the remembered Steam login from \(bottle)? Every Windows Steam instance must be fully closed. Existing protected login data will be replaced."
        case .provision(let bottle):
            return "Apply the protected login to \(bottle)? Steam must be stopped in every profile. Steam Guard may still be required."
        case .signOut(let bottle):
            return "Remove remembered Steam authentication from \(bottle) only? Other profile logins and NASE's protected copy will remain."
        case .forget:
            return "Delete NASE's protected Steam login? Existing bottles remain signed in until you sign them out separately."
        case nil:
            return ""
        }
    }

    private func performPendingSteamIdentityAction() {
        switch pendingSteamIdentityAction {
        case .capture(let bottle): model.captureSteamIdentity(from: bottle)
        case .provision(let bottle): model.provisionSteamIdentity(to: bottle)
        case .signOut(let bottle): model.signOutSteamProfile(bottle)
        case .forget: model.forgetSteamIdentity()
        case nil: break
        }
        pendingSteamIdentityAction = nil
    }

    private var settingsTargetPanel: some View {
        settingsSection("Target") {
            settingsControlRow("Wine Runtime") {
                Picker("Wine Runtime", selection: Binding(
                    get: { model.selectedWineRuntimeID ?? "custom" },
                    set: { newValue in
                        guard newValue != "custom" else { return }
                        model.selectWineRuntime(id: newValue)
                        winePath = model.backendContext.winePath
                    }
                )) {
                    ForEach(model.wineRuntimes) { runtime in
                        Text("\(runtime.name) • \(runtime.displaySubtitle)").tag(runtime.id)
                    }
                    Text("Custom Path").tag("custom")
                }
                .pickerStyle(.menu)
            }

            settingsControlRow("Bottle") {
                Picker("Bottle Name", selection: $bottleName) {
                    ForEach(model.managedBottleNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var settingsAdvancedTargetPanel: some View {
        settingsSection("Backend Target") {
            settingsControlRow("Target Mode") {
                Picker("Target Mode", selection: $useExternalPrefix) {
                    Text("Managed Bottle").tag(false)
                    Text("External Prefix").tag(true)
                }
                .pickerStyle(.segmented)
            }

            labeledField("Wine Path", text: $winePath, browseAction: {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: false) {
                    winePath = path
                }
            })

            labeledField("External Prefix", text: $externalPrefix, browseAction: {
                if let path = pickPath(canChooseFiles: false, canChooseDirectories: true) {
                    externalPrefix = path
                }
            })
            .opacity(useExternalPrefix ? 1 : 0.45)
            .disabled(!useExternalPrefix)

            HStack(spacing: 10) {
                Button("Import App") {
                    model.importWineAppRuntime()
                    winePath = model.backendContext.winePath
                }
                Button("Register Binary") {
                    model.importWineBinaryRuntime()
                    winePath = model.backendContext.winePath
                }
                Button("Reveal Folder") {
                    model.revealManagedWineRuntimes()
                }
            }
        }
    }

    private var settingsGraphicsPanel: some View {
        settingsSection("Graphics") {
            labeledField("DXMT Source", text: $dxmtSource, browseAction: {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: true) {
                    dxmtSource = path
                }
            })
            labeledField("DXVK Source", text: $dxvkSource, browseAction: {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: true) {
                    dxvkSource = path
                }
            })
            labeledField("D3DMetal Source", text: $d3dMetalSource, browseAction: {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: true) {
                    d3dMetalSource = path
                }
            })
            labeledField("GPTK Wine Path", text: $gptkWinePath, browseAction: {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: false) {
                    gptkWinePath = path
                }
            })
        }
    }

    private var settingsValidationPanel: some View {
        settingsSection("Validation") {
            Text(validationMessage.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(themeMutedForeground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(themeForeground)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func settingsControlRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            Spacer()
            content()
                .frame(maxWidth: 460)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func labeledField(_ title: String, text: Binding<String>, browseAction: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            HStack(spacing: 10) {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
                if let browseAction {
                    Button("Browse") {
                        browseAction()
                    }
                }
            }
        }
        .padding(14)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func pickPath(canChooseFiles: Bool, canChooseDirectories: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private var settingsRuntimeCenterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Runtime Center")
                        .font(.headline)
                        .foregroundStyle(themeForeground)
                }
                Spacer()
                Button {
                    model.refreshRuntimeCenter()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh runtime catalog")
            }

            if model.runtimeCatalog.isEmpty {
                Text("Runtime catalog has not loaded yet.")
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(themePanelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(model.runtimeCatalog) { runtime in
                        runtimeCatalogRow(runtime)
                    }
                }
            }
        }
        .padding(16)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var settingsDependencyPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Readiness")
                        .font(.headline)
                    Text("Required host components for the recommended DXMT profile.")
                        .font(.caption)
                        .foregroundStyle(themeMutedForeground)
                }
                Spacer()
                Button {
                    model.refreshDependencyStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Check dependencies again")
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recommended Gaming Environment")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            model.compatibilityProfileIsReady(.dxmt) && model.dependencyBootstrapPhase == .idle
                                ? "Recommended DXMT environment is ready."
                                : model.dependencyBootstrapMessage
                        )
                            .font(.caption)
                            .foregroundStyle(model.dependencyBootstrapPhase == .failed ? .red : themeMutedForeground)
                    }
                    Spacer()
                    if model.isDependencyBootstrapRunning {
                        ProgressView().controlSize(.small)
                    } else if model.dependencyBootstrapPhase == .ready || model.compatibilityProfileIsReady(.dxmt) {
                        Label("Ready", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button(model.dependencyBootstrapPhase == .failed ? "Retry" : "Set Up") {
                            showRecommendedBootstrapConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if model.isDependencyBootstrapRunning || model.dependencyBootstrapProgress > 0 {
                    ProgressView(value: model.dependencyBootstrapProgress)
                }
                if model.dependencyBootstrapPhase == .failed {
                    HStack(spacing: 12) {
                        Button("Open Logs") {
                            model.openRecommendedBootstrapLogs()
                        }
                        Button("Choose Existing Installation") {
                            selectedSection = .advanced
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            .background(themePanel)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let result = model.latestDependencyResult {
                ForEach(result.checks) { check in
                    let dependencyID = dependencyID(for: check.name)
                    let isInstalling = dependencyID != nil && (
                        model.installingDependencyID == dependencyID
                        || model.installingRuntimeID == dependencyID
                        || (model.isDependencyBootstrapRunning
                            && model.dependencyBootstrapMessage.localizedCaseInsensitiveContains(check.name))
                    )
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.status == "ok" ? "checkmark.circle.fill" : (check.status == "warn" ? "exclamationmark.triangle.fill" : "xmark.circle.fill"))
                            .foregroundStyle(check.status == "ok" ? .green : (check.status == "warn" ? .orange : .red))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(check.name).font(.subheadline.weight(.semibold))
                                if !check.required {
                                    Text("Optional").font(.caption2).foregroundStyle(themeMutedForeground)
                                }
                            }
                            Text(check.detail).font(.caption).foregroundStyle(themeMutedForeground)
                            if let fix = check.fix {
                                Text(fix).font(.caption.weight(.medium))
                            }
                        }
                        Spacer()
                        if isInstalling {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Installing…").font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(themeMutedForeground)
                        } else if check.status == "fail", dependencyID != nil {
                            Button("Fix") {
                                beginDependencyInstall(for: check.name)
                            }
                            .disabled(model.isBusy || model.installingDependencyID != nil)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("Checking dependencies...")
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dependencyConfirmationMessage: String {
        switch pendingDependencyInstall {
        case "rosetta":
            return "NASE will run Apple's Rosetta installer. Continuing explicitly accepts Apple's software license agreement."
        case "wine-stable":
            return "NASE will download, checksum-verify, and install its pinned Wine Stable 11 runtime inside NASE app support."
        case "gstreamer":
            return "NASE will download and extract the checksum-pinned private GStreamer framework required by managed Wine. It will not run a system package installer."
        case "winetricks":
            return "NASE will download and checksum-verify its pinned Winetricks script inside NASE app support."
        case "python":
            return "Python is bundled with NASE. Reinstall NASE if its private runtime is unavailable."
        default:
            return "NASE will install the selected dependency."
        }
    }

    private var recommendedBootstrapConfirmationMessage: String {
        let missing = model.latestDependencyResult?.checks
            .filter { $0.required && $0.status == "fail" }
            .map(\.name) ?? []
        let summary = missing.isEmpty ? "All host dependencies are already present." : "NASE will install: \(missing.joined(separator: ", "))."
        let rosetta = missing.contains("Rosetta 2")
            ? " Continuing explicitly accepts Apple's Rosetta software license."
            : ""
        return "\(summary) It will then select Wine Stable and DXMT automatically, create the dedicated DXMT bottle, and install Steam.\(rosetta)"
    }

    private func beginDependencyInstall(for checkName: String) {
        switch checkName {
        case "DXMT 0.71":
            model.installRecommendedDXMT()
        case "Rosetta 2":
            pendingDependencyInstall = "rosetta"
            showDependencyConfirmation = true
        case "Wine Stable 11":
            pendingDependencyInstall = "wine-stable"
            showDependencyConfirmation = true
        case "GStreamer 1.28.2":
            pendingDependencyInstall = "gstreamer"
            showDependencyConfirmation = true
        case "Winetricks":
            pendingDependencyInstall = "winetricks"
            showDependencyConfirmation = true
        case "Python":
            break
        default:
            break
        }
    }

    private func dependencyID(for checkName: String) -> String? {
        switch checkName {
        case "DXMT 0.71": "dxmt-0.71"
        case "Rosetta 2": "rosetta"
        case "Wine Stable 11": "wine-stable"
        case "GStreamer 1.28.2": "gstreamer"
        case "Winetricks": "winetricks"
        case "Python": nil
        default: nil
        }
    }

    private var settingsCompatibilityProfilesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compatibility Profiles")
                    .font(.headline)
                    .foregroundStyle(themeForeground)
                Text("DXMT is the default. Plain, D3DMetal, and DXVK profiles are created only when first used; all profiles reuse shared game files.")
                    .font(.caption)
                    .foregroundStyle(themeMutedForeground)
            }

            ForEach(GraphicsBackendOption.allCases) { profile in
                let isReady = model.compatibilityProfileIsReady(profile)
                let hasSharedLibraries = model.compatibilityProfileHasSharedLibraries(profile)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: isReady ? "checkmark.seal.fill" : "checkmark.shield")
                        .frame(width: 24)
                        .foregroundStyle(themeForeground)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.rawValue)
                            .font(.subheadline.weight(.semibold))
                        Text(profile.profileSummary)
                            .font(.caption)
                            .foregroundStyle(themeMutedForeground)
                        if profile == .d3dmetal {
                            if model.isD3DMetalDiscoveryRunning {
                                HStack(spacing: 7) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Searching mounted volumes...")
                                }
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(themeMutedForeground)
                            } else if model.hasDetectedD3DMetalRuntime {
                                Label("Compatible runtime found", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.green)
                                Text(model.d3DMetalRuntimeLocation)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(themeMutedForeground)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            } else {
                                Label("No compatible runtime selected", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        if hasSharedLibraries {
                            Label("Shared game files attached", systemImage: "externaldrive.connected.to.line.below")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if !isReady {
                            Label("Created automatically on first launch", systemImage: "arrow.down.circle")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(themeMutedForeground)
                        }
                        Text("Bottle: \(bottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Default" : bottleName)-\(profile.bottleSuffix)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(themeMutedForeground)
                    }
                    Spacer()
                    if isReady {
                        Button("Repair") {
                            model.repairCompatibilityProfile(profile)
                        }
                        .disabled(model.isBusy)
                        Button("Delete", role: .destructive) {
                            pendingProfileReset = profile
                            showProfileResetConfirmation = true
                        }
                        .disabled(model.isBusy)
                        Button(hasSharedLibraries ? "Attached" : "Attach Libraries") {
                            model.attachSteamLibraries(to: profile)
                        }
                        .disabled(hasSharedLibraries || model.isBusy)
                    } else {
                        if profile == .d3dmetal {
                            Button("Get Compatible Runtime") {
                                model.openGPTKDownload()
                            }
                            Button("Find Runtime") {
                                model.discoverD3DMetal()
                            }
                            .disabled(model.isBusy || model.isD3DMetalDiscoveryRunning)
                            Button("Install") {
                                showGPTKImportConfirmation = true
                            }
                            .disabled(model.isBusy)
                        }
                        Button("Set Up") {
                            model.setupCompatibilityProfile(profile)
                        }
                        .disabled(model.isBusy)
                    }
                }
                .padding(12)
                .background(themePanel)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .padding(16)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func runtimeCatalogRow(_ runtime: ManagedRuntime) -> some View {
        let installedRuntime = model.installedManagedRuntimes.first(where: { $0.id == runtime.id })
        let isInstalled = runtime.installed || installedRuntime != nil
        let isInstalling = model.installingRuntimeID == runtime.id

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: runtime.kind == "wine" ? "wineglass" : "shippingbox")
                .font(.title3.weight(.semibold))
                .frame(width: 28)
                .foregroundStyle(themeForeground)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(runtime.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    Text(runtime.kindLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeMutedForeground)
                }

                HStack(spacing: 8) {
                    Text(runtime.source ?? "local")
                    Text(runtime.license ?? "unknown license")
                }
                .font(.caption2.monospaced())
                .foregroundStyle(themeMutedForeground)
            }

            Spacer()

            Button {
                model.installManagedRuntime(runtime)
            } label: {
                if isInstalling && !isInstalled {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(isInstalled ? "Installed" : "Install")
                }
            }
            .disabled(isInstalled || model.installingRuntimeID != nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsOperationsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tools")
                .font(.headline)
                .foregroundStyle(themeForeground)

            LazyVGrid(columns: settingsColumns, alignment: .leading, spacing: 10) {
                ForEach(settingsOperationCards) { operation in
                    Button {
                        if operation.kind == .winetricks {
                            dismiss()
                            model.openWinetricksAfterSettingsDismiss()
                        } else {
                            dismiss()
                            model.performAfterSettingsDismiss(operation)
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: operation.symbolName)
                                .font(.title3.weight(.semibold))
                                .frame(width: 28)
                                .foregroundStyle(themeForeground)
                            Text(operation.title)
                                .fontWeight(.semibold)
                                .foregroundStyle(themeForeground)
                                .lineLimit(2)
                            Spacer()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(themeMutedForeground)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(themePanel)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(operation.detail)
                    .disabled(model.isBusy)
                    .opacity(model.isBusy ? 0.65 : 1)
                }
            }
        }
        .padding(16)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsResultsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Structured Results")
                .font(.headline)
                .foregroundStyle(themeForeground)

            if let doctor = model.latestDoctorResult {
                structuredResultCard(
                    title: "Latest Doctor",
                    result: doctor,
                    accent: healthAccentColor(for: doctor.worstStatus)
                )
            }

            if let setup = model.latestSetupResult {
                structuredResultCard(
                    title: "Latest Setup",
                    result: setup,
                    accent: Color(hex: "#6DBB7A")
                )
            }

            if model.latestDoctorResult == nil && model.latestSetupResult == nil {
                Text("Run an environment check or setup pass to populate structured backend state here.")
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
            }
        }
        .padding(16)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var settingsCurrentOperationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current Operation")
                .font(.headline)
                .foregroundStyle(themeForeground)

            if let job = model.currentOperationJob {
                jobRow(job)

                if let result = model.currentOperationResult {
                    structuredResultCard(
                        title: "Live Details",
                        result: result,
                        accent: healthAccentColor(for: result.worstStatus)
                    )
                }
            } else {
                Text("No active backend work right now.")
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
            }
        }
        .padding(16)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var settingsJobsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jobs")
                .font(.headline)
                .foregroundStyle(themeForeground)

            if model.activeBackendJobs.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(themeForeground)
                        Spacer()
                        Button("Refresh") { model.refreshBackendJobs() }
                            .buttonStyle(.borderless)
                    }
                    ForEach(model.activeBackendJobs) { job in
                        jobRow(job)
                    }
                }
            }

            if model.recentBackendJobs.isEmpty == false {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(Array(model.recentBackendJobs.prefix(6))) { job in
                        jobRow(job)
                    }
                }
            }

            if model.activeBackendJobs.isEmpty && model.recentBackendJobs.isEmpty {
                Text("No backend jobs recorded yet.")
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
            }
        }
        .padding(16)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func jobRow(_ job: BackendJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(jobAccentColor(for: job.status))
                    .frame(width: 10, height: 10)
                    .padding(.top, 5)

                VStack(alignment: .leading, spacing: 4) {
                    Text(job.action)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    Text(job.message)
                        .font(.subheadline)
                        .foregroundStyle(themeMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                    if [.queued, .started, .cancelling].contains(job.status) {
                        Button(job.status == .cancelling ? "Cancelling…" : "Cancel") {
                            model.cancelBackendJob(job)
                        }
                        .disabled(job.status == .cancelling)
                    }
                    HStack(spacing: 8) {
                        Text(job.status.rawValue.capitalized)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(jobAccentColor(for: job.status))
                        if let completedSteps = job.completedSteps, let totalSteps = job.totalSteps, totalSteps > 0 {
                            Text("\(completedSteps)/\(totalSteps) phases")
                                .font(.caption)
                                .foregroundStyle(themeMutedForeground)
                        }
                    }
                }
            }

            if let progress = job.progress {
                ProgressView(value: progress)
                    .tint(jobAccentColor(for: job.status))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var settingsCommandPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.expandedDebugSections.contains(.bridgeCommands) },
                    set: { isExpanded in
                        if isExpanded {
                            model.expandedDebugSections.insert(.bridgeCommands)
                        } else {
                            model.expandedDebugSections.remove(.bridgeCommands)
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.bridgeCommands) { command in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(command.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(themeForeground)
                            Text(command.command)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(themeMutedForeground)
                                .textSelection(.enabled)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(themePanelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Backend Bridge")
                    .font(.headline)
                    .foregroundStyle(themeForeground)
            }
        }
        .padding(16)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var settingsActivityPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { model.expandedDebugSections.contains(.activityLog) },
                    set: { isExpanded in
                        if isExpanded {
                            model.expandedDebugSections.insert(.activityLog)
                        } else {
                            model.expandedDebugSections.remove(.activityLog)
                        }
                    }
                )
            ) {
                Text(model.activityLog)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(themeMutedForeground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            } label: {
                Text("Activity Log")
                    .font(.headline)
                    .foregroundStyle(themeForeground)
            }
        }
        .padding(16)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func structuredResultCard(title: String, result: BackendStructuredResult, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeForeground)
                Spacer()
                if let worstStatus = result.worstStatus {
                    Text(worstStatus.uppercased())
                        .font(.caption.weight(.bold))
                        .foregroundStyle(accent)
                }
            }

            if let target = result.target, !target.isEmpty {
                Text(target)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(themeMutedForeground)
                    .textSelection(.enabled)
            }

            if let root = result.root, !root.isEmpty {
                Text(root)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(themeMutedForeground)
                    .textSelection(.enabled)
            }

            if let completedSteps = result.completedSteps, let totalSteps = result.totalSteps, totalSteps > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Progress")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(themeForeground)
                        Spacer()
                        Text("\(completedSteps)/\(totalSteps) phases")
                            .font(.caption)
                            .foregroundStyle(themeMutedForeground)
                    }
                    ProgressView(value: Double(completedSteps), total: Double(totalSteps))
                        .tint(accent)
                }
            }

            if result.fixes.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applied Fixes")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(Array(result.fixes.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.footnote)
                            .foregroundStyle(themeMutedForeground)
                    }
                }
            }

            if result.steps.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steps")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(result.steps) { step in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(step.status.lowercased() == "ok" ? Color(hex: "#6DBB7A") : Color(hex: "#8A948C"))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            Text(step.name)
                                .font(.footnote)
                                .foregroundStyle(themeMutedForeground)
                            Spacer()
                            Text(step.status.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(themeMutedForeground)
                        }
                    }
                }
            }

            if result.checks.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Checks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(Array(result.checks.prefix(8))) { check in
                        HStack(alignment: .top, spacing: 8) {
                            Circle()
                                .fill(healthAccentColor(for: check.status))
                                .frame(width: 8, height: 8)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(check.name)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(themeForeground)
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(themeMutedForeground)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if result.checks.count > 8 {
                        Text("+ \(result.checks.count - 8) more checks in activity log")
                            .font(.caption)
                            .foregroundStyle(themeMutedForeground)
                    }
                }
            }

            if result.signals.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected Signals")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(Array(result.signals.prefix(6))) { signal in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(signal.key)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(themeForeground)
                            Text(signal.detail)
                                .font(.caption)
                                .foregroundStyle(themeMutedForeground)
                            Text(signal.path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(themeMutedForeground)
                        }
                    }
                }
            }

            if result.recommendations.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommendations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(result.recommendations) { recommendation in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recommendation.verb)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(themeForeground)
                            Text(recommendation.reason)
                                .font(.caption)
                                .foregroundStyle(themeMutedForeground)
                        }
                    }
                }
            }

            if result.warnings.isEmpty == false || result.errors.isEmpty == false {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Messages")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(themeForeground)
                    ForEach(Array(result.warnings.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(result.errors.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func healthAccentColor(for status: String?) -> Color {
        switch status?.lowercased() {
        case "fail":
            return Color.red
        case "warn":
            return Color.orange
        case "ok":
            return Color(hex: "#6DBB7A")
        default:
            return Color(hex: "#8A948C")
        }
    }

    private func jobAccentColor(for status: BackendJobStatus) -> Color {
        switch status {
        case .started, .cancelling:
            return Color(hex: "#6DBB7A")
        case .completed:
            return Color(hex: "#6DBB7A")
        case .failed, .cancelled, .interrupted:
            return Color.red
        case .queued:
            return Color(hex: "#8A948C")
        }
    }

    private var themeBackground: Color { colorScheme == .dark ? Color(hex: "#20231F") : Color(hex: "#EEF3EC") }
    private var themePanel: Color { colorScheme == .dark ? Color(hex: "#2A302C") : Color(hex: "#F7FBF5") }
    private var themePanelRaised: Color { colorScheme == .dark ? Color(hex: "#353D38") : Color(hex: "#DEE8DE") }
    private var themeForeground: Color { colorScheme == .dark ? Color(hex: "#D4DBD4") : Color(hex: "#162019") }
    private var themeMutedForeground: Color { colorScheme == .dark ? Color(hex: "#AEB7AF") : Color(hex: "#55635A") }
}
