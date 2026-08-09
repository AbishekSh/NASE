import AppKit
import SwiftUI

struct EpicSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: AppViewModel
    @State private var authorizationCode = ""
    @State private var showLogoutConfirmation = false

    private var legendaryRuntime: ManagedRuntime? {
        model.runtimeCatalog.first { $0.id == "legendary-python-0.20.34-macos" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Epic Games Setup")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                    Text("Connect your account without installing the Windows Epic Games Launcher.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            GroupBox("1. Epic client") {
                HStack(spacing: 12) {
                    Image(systemName: model.epicSourceStatus?.available == true ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(model.epicSourceStatus?.available == true ? .green : .orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.epicSourceStatus?.available == true ? "Legendary is ready" : "Install Legendary")
                            .fontWeight(.semibold)
                        Text(legendaryRuntime?.notes ?? "NASE downloads and checksum-verifies its pinned standalone macOS build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.installLegendary() } label: {
                        if model.installingRuntimeID == "legendary-python-0.20.34-macos" {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Installing…")
                            }
                        } else {
                            Text(legendaryRuntime?.installed == true ? "Installed" : "Install")
                        }
                    }
                    .disabled(legendaryRuntime?.installed == true || model.installingRuntimeID != nil)
                }
                .padding(8)
            }

            GroupBox("2. Sign in") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.epicSourceStatus?.authenticated == true {
                        Label("Epic Games account connected", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Button("Sign Out", role: .destructive) { showLogoutConfirmation = true }
                    } else {
                        Text("Open Epic's login page, sign in, then copy either the authorizationCode value or the complete JSON response below.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open Epic Login") {
                                if let url = URL(string: "https://legendary.gl/epiclogin") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .disabled(model.epicSourceStatus?.available != true)
                            SecureField("Authorization code or JSON response", text: $authorizationCode)
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") {
                                model.authenticateEpic(code: authorizationCode)
                                authorizationCode = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.epicSourceStatus?.available != true || authorizationCode.isEmpty)
                        }
                    }
                }
                .padding(8)
            }

            Text(model.epicSetupMessage)
                .font(.caption)
                .foregroundStyle(model.epicSetupMessage.localizedCaseInsensitiveContains("failed") || model.epicSetupMessage.localizedCaseInsensitiveContains("error") ? .red : .secondary)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(24)
        .frame(width: 720, height: 440)
        .task {
            model.refreshRuntimeCenter()
            model.refreshEpicSourceStatus()
        }
        .alert("Sign Out of Epic Games?", isPresented: $showLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { model.logoutEpic() }
        } message: {
            Text("This removes the Epic authentication stored in NASE's private Legendary configuration. Installed games are not deleted.")
        }
    }
}
