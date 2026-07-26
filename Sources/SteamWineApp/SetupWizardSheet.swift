import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SetupWizardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppViewModel

    @State private var selectedStep: SetupWizardStep = .welcome
    @State private var winePath: String = ""
    @State private var dxmtSource: String = ""
    @State private var dxvkSource: String = ""
    @State private var bottleName: String = ""
    @State private var showRecommendedBootstrapConfirmation: Bool = false

    private let orderedSteps = SetupWizardStep.allCases

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Setup Wizard")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("This gets a new machine from zero to a managed Steam + Metal setup without making the user piece the backend together manually.")
                    .font(.subheadline)
                    .foregroundStyle(themeMutedForeground)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(orderedSteps) { step in
                        Button {
                            selectedStep = step
                        } label: {
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(step == selectedStep ? themePrimary : stepAccent(for: step))
                                    .frame(width: 10, height: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(step.rawValue)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(themeForeground)
                                    Text(step.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(themeMutedForeground)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(step == selectedStep ? themePanelRaised : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .frame(width: 250)
            .padding(24)
            .background(themeSidebar)

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        requirementsChecklist
                        stepBody
                    }
                    .padding(24)
                }

                Divider()

                HStack {
                    Button("Close") {
                        model.closeSetupWizard()
                        dismiss()
                    }

                    Spacer()

                    if let previousStep = previousStep {
                        Button("Back") {
                            selectedStep = previousStep
                        }
                    }

                    if let nextStep = nextStep {
                        Button("Next") {
                            selectedStep = nextStep
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Done") {
                            model.closeSetupWizard()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }
            .background(themeBackground)
        }
        .frame(width: 980, height: 720)
        .task {
            model.refreshRuntimeCenter()
            model.refreshDependencyStatus()
            winePath = model.backendContext.winePath
            dxmtSource = model.backendContext.dxmtSource
            dxvkSource = model.backendContext.dxvkSource
            bottleName = model.backendContext.bottleName
        }
        .alert("Install Recommended Environment?", isPresented: $showRecommendedBootstrapConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Accept and Continue") {
                model.startRecommendedBootstrap(confirmRosettaLicense: true)
            }
        } message: {
            Text("NASE uses its bundled Python runtime. It will install missing managed Wine Stable, GStreamer, Winetricks, and DXMT components internally. On Apple Silicon this also confirms Apple's Rosetta license when Rosetta is missing.")
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch selectedStep {
        case .welcome:
            wizardCard(title: "What this flow does", subtitle: "The wizard is built to get someone new to Wine unstuck quickly.") {
                VStack(alignment: .leading, spacing: 12) {
                    setupBullet("Detect Wine and tell you exactly what to install if it is missing.")
                    setupBullet("Detect Winetricks and do the same.")
                    setupBullet("Pick the DXMT payload we use for the managed Metal path.")
                    setupBullet("Create a managed bottle under ~/Library/Application Support/NASE.")
                    setupBullet("Install Steam into that bottle and prepare it for launch.")
                    Button {
                        showRecommendedBootstrapConfirmation = true
                    } label: {
                        Label("Install Recommended Environment", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    Text("DXVK remains available later as a per-game compatibility choice. The guided setup flow is centered on the managed DXMT/Metal path we have been validating.")
                        .foregroundStyle(themeMutedForeground)
                }
            }

        case .wine:
            wizardCard(title: "Wine Detection", subtitle: model.detectedWinePathStatus(winePath)) {
                VStack(alignment: .leading, spacing: 14) {
                    labeledField("Wine Path", text: $winePath) {
                        if let path = pickPath(canChooseFiles: true, canChooseDirectories: false) {
                            winePath = path
                        }
                    }
                    guidanceBlock(
                        title: "Install Guidance",
                        lines: [
                            "1. Install Rosetta 2 if needed: `softwareupdate --install-rosetta --agree-to-license`",
                            "2. Choose Install Recommended Environment to download NASE's checksum-pinned Wine Stable runtime.",
                            "3. NASE keeps managed Wine under Application Support instead of installing a system cask.",
                        ]
                    )
                }
            }

        case .winetricks:
            wizardCard(title: "Winetricks Detection", subtitle: model.detectedWinetricksStatus()) {
                guidanceBlock(
                    title: "Install Guidance",
                    lines: [
                        "Choose Install Recommended Environment to install NASE's checksum-pinned Winetricks script.",
                        "No Homebrew installation is required.",
                        "The setup flow uses Winetricks to install Steam into the managed bottle.",
                    ]
                )
            }

        case .graphics:
            wizardCard(title: "Graphics Stack", subtitle: "Pick or download the graphics payloads the app can manage for you.") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Managed DXMT Path")
                            .font(.subheadline.weight(.semibold))
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
                            .buttonStyle(.borderedProminent)
                            .disabled(model.installingRuntimeID != nil)

                            if model.installingRuntimeID == "dxmt-0.71" {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        statusBlock(lines: model.validateDXMTSourceForWizard(dxmtSource))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Optional DXVK Path")
                            .font(.subheadline.weight(.semibold))
                        labeledField("DXVK Source", text: $dxvkSource) {
                            if let path = pickPath(canChooseFiles: true, canChooseDirectories: true) {
                                dxvkSource = path
                            }
                        }
                        Text("Experimental on macOS. DXVK also needs a compatible Wine Vulkan and MoltenVK host stack; downloading these DLLs alone does not enable Vulkan. The app keeps DXMT as the safe default.")
                            .foregroundStyle(themeMutedForeground)
                        HStack(spacing: 10) {
                            Button {
                                if let runtime = model.runtimeCatalog.first(where: {
                                    $0.id == "dxvk-macos-1.10.3-20230507-repack"
                                }) {
                                    model.installManagedRuntime(runtime)
                                }
                            } label: {
                                Label("Install Verified DXVK-macOS", systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.bordered)
                            .disabled(model.installingRuntimeID != nil)
                        }
                        statusBlock(lines: model.validateDXVKSourceForWizard(dxvkSource))
                        Button {
                            model.installDXVKFromWizard(
                                winePath: winePath,
                                dxmtSource: dxmtSource,
                                dxvkSource: dxvkSource,
                                bottleName: bottleName
                            )
                        } label: {
                            Label("Install DXVK Into This Bottle", systemImage: "shippingbox")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canInstallDXVK || model.isBusy)
                    }

                }
            }

        case .bottle:
            wizardCard(title: "Managed Bottle", subtitle: "Choose the bottle the app should create and maintain for Steam.") {
                VStack(alignment: .leading, spacing: 14) {
                    labeledField("Bottle Name", text: $bottleName, browseAction: nil)
                    Text("The prefix will live under `~/Library/Application Support/NASE/bottles/<BottleName>`.")
                        .font(.subheadline)
                        .foregroundStyle(themeMutedForeground)
                    if !model.managedBottleNames.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Existing Bottles")
                                .font(.subheadline.weight(.semibold))
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(model.managedBottleNames, id: \.self) { name in
                                        Button(name) {
                                            bottleName = name
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                    }
                }
            }

        case .steam:
            wizardCard(title: "Steam Setup", subtitle: "Run the managed Steam + Metal setup flow using the values above.") {
                VStack(alignment: .leading, spacing: 14) {
                    statusBlock(lines: [
                        model.detectedWinePathStatus(winePath),
                        model.detectedWinetricksStatus(),
                    ] + model.validateDXMTSourceForWizard(dxmtSource))

                    Button {
                        model.runSetupWizard(
                            winePath: winePath,
                            dxmtSource: dxmtSource,
                            dxvkSource: dxvkSource,
                            bottleName: bottleName
                        )
                    } label: {
                        Label("Run Setup", systemImage: "hammer")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.setupWizardCanRun(winePath: winePath, dxmtSource: dxmtSource, bottleName: bottleName) || model.isBusy)

                    if let job = model.currentOperationJob,
                       job.action == "Set Up Compatibility Profile" || job.action == "Setup Metal" {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(job.message)
                                .font(.subheadline.weight(.semibold))
                            if let progress = job.progress {
                                ProgressView(value: progress)
                                    .tint(themePrimary)
                            }
                            if let completedSteps = job.completedSteps, let totalSteps = job.totalSteps, totalSteps > 0 {
                                Text("\(completedSteps) / \(totalSteps) phases")
                                    .font(.caption)
                                    .foregroundStyle(themeMutedForeground)
                            }
                        }
                        .padding(14)
                        .background(themePanelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }

        case .finish:
            wizardCard(title: "Finish", subtitle: finishSubtitle) {
                VStack(alignment: .leading, spacing: 14) {
                    guideBlock
                    if let setup = model.latestSetupResult {
                        statusBlock(lines: setup.steps.map { "\($0.status.uppercased()): \($0.name)" } + setup.warnings + setup.errors)
                    } else {
                        Text("Run Setup first, then come back here to review the result and launch Steam.")
                            .foregroundStyle(themeMutedForeground)
                    }

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
                            Label("Open Steam", systemImage: "play.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.latestSetupResult == nil)

                        Button("Open Settings") {
                            model.closeSetupWizard()
                            dismiss()
                            model.openSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private var previousStep: SetupWizardStep? {
        guard let index = orderedSteps.firstIndex(of: selectedStep), index > 0 else { return nil }
        return orderedSteps[index - 1]
    }

    private var nextStep: SetupWizardStep? {
        guard let index = orderedSteps.firstIndex(of: selectedStep), index < orderedSteps.count - 1 else { return nil }
        return orderedSteps[index + 1]
    }

    private var finishSubtitle: String {
        if let job = model.recentBackendJobs.first(where: { $0.action == "Setup Metal" }) {
            switch job.status {
            case .completed:
                return "Setup finished. Steam should now be ready in the managed bottle."
            case .failed, .cancelled, .interrupted:
                return "Setup failed. Review the result below and rerun the setup step."
            case .queued, .started, .cancelling:
                return "Setup is still running."
            }
        }
        return "Review the current setup result and move into the Steam library."
    }

    private var canInstallDXVK: Bool {
        model.validateDXVKSourceForWizard(dxvkSource).contains(where: { $0.hasPrefix("OK: DXVK payload looks valid") || $0.hasPrefix("OK: DXVK source is a .tar.gz archive") })
    }

    private var requirementsChecklist: some View {
        wizardCard(title: "Requirements Checklist", subtitle: "This keeps the setup understandable for someone who should not have to think in Wine internals.") {
            VStack(alignment: .leading, spacing: 10) {
                checklistRow(title: "Wine", detail: model.detectedWinePathStatus(winePath))
                checklistRow(title: "Winetricks", detail: model.detectedWinetricksStatus())
                checklistRow(title: "Python", detail: dependencyDetail(named: "Python"))
                checklistRow(title: "Rosetta", detail: dependencyDetail(named: "Rosetta 2"))
                checklistRow(title: "DXMT", detail: firstMeaningfulDXMTStatus)
                checklistRow(title: "Bottle", detail: bottleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "FAIL: Bottle name is empty" : "OK: Bottle name is set to \(bottleName)")
                checklistRow(title: "Steam Setup", detail: model.latestSetupResult == nil ? "PENDING: Run the setup step to install Steam into the managed bottle" : finishSubtitle)
            }
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
        return statuses.first ?? "FAIL: DXMT source path is empty"
    }

    private var guideBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Getting Started")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            setupBullet("Go to the Steam tab and use Open Steam to sign in and install games.")
            setupBullet("Use Refresh Games after installs so the launcher can discover the new manifests.")
            setupBullet("Use Doctor or Winetricks from Settings if a game needs compatibility help.")
            setupBullet("Keep Steam on the managed bottle unless you have a specific reason to override it.")
        }
        .padding(14)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func wizardCard<Content: View>(title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(themeForeground)
                Text(subtitle)
                    .foregroundStyle(themeMutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(20)
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
                    Button("Browse") {
                        browseAction()
                    }
                }
            }
        }
    }

    private func guidanceBlock(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(themeForeground)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(themeMutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(themePanelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    private func stepAccent(for step: SetupWizardStep) -> Color {
        switch step {
        case .steam:
            return model.latestSetupResult == nil ? themePanelRaised : themePrimary
        default:
            return themePanelRaised
        }
    }

    private var themeBackground: Color { colorScheme == .dark ? Color(hex: "#20231F") : Color(hex: "#EEF3EC") }
    private var themeSidebar: Color { colorScheme == .dark ? Color(hex: "#181B18") : Color(hex: "#E4ECE3") }
    private var themePanel: Color { colorScheme == .dark ? Color(hex: "#2A302C") : Color(hex: "#F7FBF5") }
    private var themePanelRaised: Color { colorScheme == .dark ? Color(hex: "#353D38") : Color(hex: "#DEE8DE") }
    private var themePrimary: Color { Color(hex: "#6DBB7A") }
    private var themeForeground: Color { colorScheme == .dark ? Color(hex: "#F3F6F2") : Color(hex: "#162019") }
    private var themeMutedForeground: Color { colorScheme == .dark ? Color(hex: "#AEB7AF") : Color(hex: "#55635A") }
}
