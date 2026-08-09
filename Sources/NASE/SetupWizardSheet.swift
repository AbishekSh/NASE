import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SetupWizardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppViewModel

    @State private var winePath: String = ""
    @State private var dxmtSource: String = ""
    @State private var dxvkSource: String = ""
    @State private var bottleName: String = ""
    @State private var showRecommendedBootstrapConfirmation: Bool = false
    @State private var showAdvanced: Bool = false

    private enum SetupScreen { case start, running, ready }

    private var screen: SetupScreen {
        if model.isDependencyBootstrapRunning { return .running }
        if model.dependencyBootstrapPhase == .ready || model.compatibilityProfileIsReady(.dxmt) { return .ready }
        return .start
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    switch screen {
                    case .ready:
                        readyPanel
                    case .running:
                        runningPanel
                    case .start:
                        startPanel
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }

            Divider()

            HStack {
                Button("Close") {
                    model.closeSetupWizard()
                    dismiss()
                }
                Spacer()
                if screen == .ready {
                    Button("Done") {
                        model.closeSetupWizard()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 640)
        .background(themeBackground)
        .task {
            model.refreshRuntimeCenter()
            model.refreshDependencyStatus()
            winePath = model.backendContext.winePath
            dxmtSource = model.backendContext.dxmtSource
            dxvkSource = model.backendContext.dxvkSource
            bottleName = model.backendContext.bottleName
        }
        .alert("Set Up NASE?", isPresented: $showRecommendedBootstrapConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Set Up") {
                model.startRecommendedBootstrap(confirmRosettaLicense: true)
            }
        } message: {
            Text("NASE will download and install its own managed Wine, Winetricks, GStreamer, and DXMT components, then set up Steam — all inside its own folder. On Apple Silicon this also accepts Apple's Rosetta 2 license if Rosetta is missing.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome to NASE")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(themeForeground)
            Text("One click gets your Windows games running on macOS.")
                .font(.subheadline)
                .foregroundStyle(themeMutedForeground)
        }
    }

    // MARK: - Start

    private var startPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            wizardCard(
                title: "Let's get NASE ready",
                subtitle: "NASE installs everything it needs on its own — a managed Wine runtime, Metal graphics support, and Steam. This usually takes a few minutes on the first run."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    readinessSummary

                    Button {
                        showRecommendedBootstrapConfirmation = true
                    } label: {
                        Label("Set Up NASE", systemImage: "wand.and.stars")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)

                    Text("Everything is downloaded into NASE's own folder and checksum-verified. Nothing is installed system-wide — no Homebrew or Terminal steps required.")
                        .font(.footnote)
                        .foregroundStyle(themeMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.dependencyBootstrapPhase == .failed {
                recommendedEnvironmentProgress
            }

            advancedDisclosure
        }
    }

    private var readinessSummary: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                checklistRow(title: "macOS & Python", detail: dependencyDetail(named: "Python"))
                checklistRow(title: "Rosetta 2 (Apple Silicon)", detail: dependencyDetail(named: "Rosetta 2"))
                checklistRow(title: "Managed Wine", detail: model.detectedWinePathStatus(winePath))
                checklistRow(title: "Graphics (DXMT)", detail: firstMeaningfulDXMTStatus)
                checklistRow(title: "Steam", detail: model.latestSetupResult == nil ? "PENDING: Installed during setup" : finishSubtitle)
            }
            .padding(.top, 10)
        } label: {
            Label("What NASE will set up", systemImage: "list.bullet.clipboard")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
        }
        .tint(themePrimary)
    }

    // MARK: - Running

    private var runningPanel: some View {
        wizardCard(
            title: "Setting up NASE",
            subtitle: "Downloading and installing managed components. Keep NASE open — this can take a few minutes."
        ) {
            recommendedEnvironmentProgress
        }
    }

    // MARK: - Ready

    private var readyPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            wizardCard(
                title: "You're ready to play",
                subtitle: "NASE finished setting up your managed Steam and Metal environment."
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    guideBlock
                    HStack(spacing: 10) {
                        Button {
                            model.perform(
                                OperationCard(
                                    kind: .openSteam,
                                    title: "Open Steam",
                                    detail: "Launch Windows Steam without waiting for it to exit.",
                                    symbolName: "play.circle"
                                )
                            )
                        } label: {
                            Label("Open Steam to sign in", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Go to Library") {
                            model.closeSetupWizard()
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let setup = model.latestSetupResult {
                DisclosureGroup {
                    statusBlock(lines: setup.steps.map { "\($0.status.uppercased()): \($0.name)" } + setup.warnings + setup.errors)
                        .padding(.top, 10)
                } label: {
                    Label("Setup details", systemImage: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(themeForeground)
                }
                .tint(themePrimary)
            }
        }
    }

    // MARK: - Advanced (hidden by default)

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Most people never need this. Use it only to point NASE at your own Wine build, graphics payloads, or a specific bottle name. The one-click setup fills these in for you.")
                    .font(.footnote)
                    .foregroundStyle(themeMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                advancedWineSection
                advancedGraphicsSection
                advancedBottleSection
            }
            .padding(.top, 12)
        } label: {
            Label("Advanced setup", systemImage: "slider.horizontal.3")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
        }
        .tint(themePrimary)
        .padding(18)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var advancedWineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Wine & Winetricks")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            labeledField("Wine Path", text: $winePath) {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: false) {
                    winePath = path
                }
            }
            statusBlock(lines: [managedWineStatus, managedWinetricksStatus])
        }
    }

    private var advancedGraphicsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Graphics Payloads")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            labeledField("DXMT Source", text: $dxmtSource) {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: true) {
                    dxmtSource = path
                }
            }
            HStack(spacing: 10) {
                Button {
                    model.installRecommendedDXMT()
                } label: {
                    Label("Install Verified DXMT 0.71", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.installingRuntimeID != nil)
                if model.installingRuntimeID == "dxmt-0.71" {
                    ProgressView().controlSize(.small)
                }
            }
            statusBlock(lines: managedDXMTStatuses)

            Text("DXVK-macOS (experimental)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
                .padding(.top, 4)
            labeledField("DXVK Source", text: $dxvkSource) {
                if let path = pickPath(canChooseFiles: true, canChooseDirectories: true) {
                    dxvkSource = path
                }
            }
            HStack(spacing: 10) {
                Button {
                    if let runtime = model.runtimeCatalog.first(where: { $0.id == "dxvk-macos-1.10.3-20230507-repack" }) {
                        model.installManagedRuntime(runtime)
                    }
                } label: {
                    Label("Install Verified DXVK-macOS", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .disabled(model.installingRuntimeID != nil)

                Button {
                    model.installDXVKFromWizard(
                        winePath: winePath,
                        dxmtSource: dxmtSource,
                        dxvkSource: dxvkSource,
                        bottleName: bottleName
                    )
                } label: {
                    Label("Install Into Bottle", systemImage: "shippingbox")
                }
                .buttonStyle(.bordered)
                .disabled(!canInstallDXVK || model.isBusy)
            }
            statusBlock(lines: model.validateDXVKSourceForWizard(dxvkSource))
        }
    }

    private var advancedBottleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Managed Bottle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            labeledField("Bottle Name", text: $bottleName, browseAction: nil)
            Text("The prefix lives under ~/Library/Application Support/NASE/bottles/<BottleName>.")
                .font(.footnote)
                .foregroundStyle(themeMutedForeground)
            if !model.managedBottleNames.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.managedBottleNames, id: \.self) { name in
                            Button(name) { bottleName = name }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Status helpers

    private var managedWineStatus: String {
        let status = model.detectedWinePathStatus(winePath)
        return status.hasPrefix("OK:")
            ? status
            : "READY TO INSTALL: NASE will download and select Wine Stable 11."
    }

    private var managedWinetricksStatus: String {
        let status = model.detectedWinetricksStatus()
        return status.hasPrefix("OK:")
            ? status
            : "READY TO INSTALL: NASE will download its pinned Winetricks script."
    }

    private var managedDXMTStatuses: [String] {
        let statuses = model.validateDXMTSourceForWizard(dxmtSource)
        if statuses.contains(where: {
            $0.hasPrefix("OK: DXMT payload folders look valid")
                || $0.hasPrefix("OK: DXMT source is a .tar.gz archive")
        }) {
            return statuses
        }
        return ["READY TO INSTALL: NASE will download, verify, and select DXMT 0.71."]
    }

    private var finishSubtitle: String {
        if let job = model.recentBackendJobs.first(where: { $0.action == "Setup Metal" }) {
            switch job.status {
            case .completed:
                return "OK: Steam is ready in the managed bottle."
            case .failed, .cancelled, .interrupted:
                return "FAIL: Setup did not finish. Rerun Set Up NASE."
            case .queued, .started, .cancelling:
                return "Setup is still running."
            }
        }
        return "PENDING: Installed during setup"
    }

    private var canInstallDXVK: Bool {
        model.validateDXVKSourceForWizard(dxvkSource).contains(where: {
            $0.hasPrefix("OK: DXVK payload looks valid") || $0.hasPrefix("OK: DXVK source is a .tar.gz archive")
        })
    }

    private var recommendedEnvironmentProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Group {
                    if model.isDependencyBootstrapRunning {
                        ProgressView().controlSize(.regular)
                    } else if model.dependencyBootstrapPhase == .ready {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.orange)
                    }
                }
                .font(.title2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(recommendedEnvironmentProgressTitle)
                        .font(.headline)
                        .foregroundStyle(themeForeground)
                    Text(model.dependencyBootstrapMessage)
                        .font(.subheadline)
                        .foregroundStyle(model.dependencyBootstrapPhase == .failed ? Color.red : themeMutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text("\(Int((model.dependencyBootstrapProgress * 100).rounded()))%")
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(themeMutedForeground)
            }

            ProgressView(value: model.dependencyBootstrapProgress, total: 1)
                .progressViewStyle(.linear)
                .tint(model.dependencyBootstrapPhase == .failed ? Color.orange : themePrimary)
                .accessibilityLabel("Recommended environment installation progress")
                .accessibilityValue("\(Int((model.dependencyBootstrapProgress * 100).rounded())) percent")

            if model.dependencyBootstrapPhase == .failed {
                Button("Open Setup Logs") {
                    model.openRecommendedBootstrapLogs()
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(themePanelRaised)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(themePrimary.opacity(0.45), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var recommendedEnvironmentProgressTitle: String {
        switch model.dependencyBootstrapPhase {
        case .idle: return "Recommended Environment"
        case .checking: return "Checking Your Mac"
        case .installing: return "Downloading and Installing"
        case .configuring: return "Configuring Managed Runtimes"
        case .profileSetup: return "Preparing Steam"
        case .ready: return "Setup Complete"
        case .failed: return "Setup Needs Attention"
        }
    }

    private func dependencyDetail(named name: String) -> String {
        guard let check = model.latestDependencyResult?.checks.first(where: { $0.name == name }) else {
            return "PENDING: Checking \(name)…"
        }
        return "\(check.status.uppercased()): \(check.detail)"
    }

    private var firstMeaningfulDXMTStatus: String {
        let statuses = model.validateDXMTSourceForWizard(dxmtSource)
        if let best = statuses.first(where: { $0.hasPrefix("FAIL:") }) {
            return best
        }
        if let best = statuses.first(where: { $0.contains("payload") || $0.contains(".tar.gz") }) {
            return best
        }
        return statuses.first ?? "PENDING: Installed during setup"
    }

    private var guideBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting Started")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            setupBullet("Go to the Steam tab and use Open Steam to sign in and install games.")
            setupBullet("Use Refresh after installs so the launcher can discover new games.")
            setupBullet("Need compatibility help for a game? Open Settings → Doctor or Winetricks.")
        }
        .padding(14)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Small building blocks

    private func wizardCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(themeForeground)
                Text(subtitle)
                    .foregroundStyle(themeMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themePanel)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func labeledField(_ title: String, text: Binding<String>, browseAction: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            HStack(spacing: 10) {
                TextField(title, text: text)
                    .textFieldStyle(.roundedBorder)
                if let browseAction {
                    Button("Browse") { browseAction() }
                }
            }
        }
    }

    private func statusBlock(lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(line.hasPrefix("FAIL:") ? Color.red : (line.hasPrefix("WARN:") ? Color.orange : themeForeground))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func checklistRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: detail.hasPrefix("OK:") ? "checkmark.circle.fill" : (detail.hasPrefix("FAIL:") ? "xmark.circle.fill" : "clock.fill"))
                .foregroundStyle(detail.hasPrefix("OK:") ? themePrimary : (detail.hasPrefix("FAIL:") ? Color.red : Color.orange))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(themeForeground)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupBullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(themePrimary)
                .padding(.top, 1)
            Text(text)
                .foregroundStyle(themeForeground)
        }
    }

    private func pickPath(canChooseFiles: Bool, canChooseDirectories: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private var themeBackground: Color { colorScheme == .dark ? Color(hex: "#20231F") : Color(hex: "#EEF3EC") }
    private var themePanel: Color { colorScheme == .dark ? Color(hex: "#2A302C") : Color(hex: "#F7FBF5") }
    private var themePanelRaised: Color { colorScheme == .dark ? Color(hex: "#353D38") : Color(hex: "#DEE8DE") }
    private var themePrimary: Color { Color(hex: "#6DBB7A") }
    private var themeForeground: Color { colorScheme == .dark ? Color(hex: "#F3F6F2") : Color(hex: "#162019") }
    private var themeMutedForeground: Color { colorScheme == .dark ? Color(hex: "#AEB7AF") : Color(hex: "#55635A") }
}
