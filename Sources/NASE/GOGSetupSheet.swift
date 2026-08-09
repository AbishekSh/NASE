import SwiftUI

struct GOGSetupSheet: View {
    @Bindable var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var callbackURL = ""
    @State private var showLogoutConfirmation = false

    private let loginURL = URL(string: "https://auth.gog.com/auth?client_id=46899977096215655&redirect_uri=https%3A%2F%2Fembed.gog.com%2Fon_login_success%3Forigin%3Dclient&response_type=code&layout=galaxy")!

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GOG Setup").font(.largeTitle.bold())
                    Text("Connect your DRM-free library without installing GOG Galaxy.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            GroupBox("1. GOG client") {
                HStack(spacing: 14) {
                    Image(systemName: model.gogSourceStatus?.available == true ? "checkmark.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(model.gogSourceStatus?.available == true ? .green : .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.gogSourceStatus?.available == true ? "GOG client is ready" : "Install GOG Download Client").font(.headline)
                        Text("Checksum-pinned gogdl 1.2.2 manages authentication, downloads, repair, and launch metadata.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { model.installGOGClient() } label: {
                        if model.installingRuntimeID?.hasPrefix("gogdl-1.2.2") == true {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("Installing…")
                            }
                        } else {
                            Text(model.gogSourceStatus?.available == true ? "Installed" : "Install")
                        }
                    }
                    .disabled(model.gogSourceStatus?.available == true || model.installingRuntimeID != nil)
                }.padding(8)
            }

            GroupBox("2. Sign in") {
                VStack(alignment: .leading, spacing: 12) {
                    if model.gogSourceStatus?.authenticated == true {
                        Label("GOG account connected", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                        Button("Sign Out") { showLogoutConfirmation = true }
                    } else {
                        Text("Open GOG Login, sign in, then copy the complete address from the success page and paste it below.")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack {
                            Button("Open GOG Login") { NSWorkspace.shared.open(loginURL) }
                                .disabled(model.gogSourceStatus?.available != true)
                            TextField("https://embed.gog.com/on_login_success?...", text: $callbackURL)
                                .textFieldStyle(.roundedBorder)
                            Button("Connect") { model.authenticateGOG(code: callbackURL) }
                                .disabled(model.gogSourceStatus?.available != true || callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }.padding(8)
            }

            Text(model.gogSetupMessage)
                .font(.callout)
                .foregroundStyle(model.gogSetupMessage.localizedCaseInsensitiveContains("failed") || model.gogSetupMessage.localizedCaseInsensitiveContains("error") ? .red : .secondary)
            Spacer()
        }
        .padding(28)
        .frame(minWidth: 780, minHeight: 520)
        .task { model.refreshGOGSourceStatus() }
        .alert("Sign Out of GOG?", isPresented: $showLogoutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) { model.logoutGOG() }
        } message: {
            Text("This removes GOG authentication stored privately by NASE. Installed games are not deleted.")
        }
    }
}
