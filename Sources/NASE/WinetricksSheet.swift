import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WinetricksSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Bindable var model: AppViewModel

    @State private var verbsText: String = ""
    @State private var interactive: Bool = false
    @FocusState private var isCustomVerbsFocused: Bool

    private let commonPresets: [(label: String, verbs: String)] = [
        ("Core Fonts", "corefonts"),
        ("VC++ 2019", "vcrun2019"),
        ("D3D Compiler 47", "d3dcompiler_47"),
        (".NET 4.8", "dotnet48"),
        ("XACT", "xact"),
        ("DirectPlay", "directplay"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Winetricks")
                        .font(.title2.weight(.bold))
                    Text("Install runtime components into the current bottle or prefix.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") {
                    model.closeWinetricks()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Common Fixes")
                            .font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                            ForEach(commonPresets, id: \.label) { preset in
                                Button(preset.label) {
                                    verbsText = preset.verbs
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Verbs")
                            .font(.subheadline.weight(.semibold))
                        Text("Enter one or more Winetricks verbs, separated by commas.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $verbsText)
                            .font(.system(.body, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 78)
                            .background(editorBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(editorBorder, lineWidth: 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .focused($isCustomVerbsFocused)
                    }

                    Toggle("Run interactively", isOn: $interactive)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Target")
                            .font(.subheadline.weight(.semibold))
                        Text(model.settingsSummary)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Detected Components")
                            .font(.headline)
                        ForEach(model.detectedWinetricksComponents()) { component in
                            HStack(alignment: .top, spacing: 12) {
                                Circle()
                                    .fill(componentColor(component.state))
                                    .frame(width: 10, height: 10)
                                    .padding(.top, 4)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(component.title)
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Text(componentLabel(component.state))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(componentColor(component.state))
                                    }
                                    Text(component.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(12)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .padding(24)
            }

            Divider()

            HStack {
                Button("Cancel") {
                    model.closeWinetricks()
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Run Winetricks") {
                    model.runWinetricks(verbsText: verbsText, interactive: interactive)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .background(.regularMaterial)
        }
        .frame(width: 620, height: 470)
        .task {
            isCustomVerbsFocused = true
        }
    }

    private var editorBackground: Color {
        colorScheme == .dark ? Color(hex: "#2A302C") : Color(hex: "#F7FBF5")
    }

    private var editorBorder: Color {
        colorScheme == .dark ? Color(hex: "#4A544D") : Color(hex: "#C9D5CA")
    }

    private func componentColor(_ state: WinetricksComponentStatus.State) -> Color {
        switch state {
        case .installed:
            return Color(hex: "#6DBB7A")
        case .missing:
            return Color.secondary
        case .unavailable:
            return Color(hex: "#D96C6C")
        }
    }

    private func componentLabel(_ state: WinetricksComponentStatus.State) -> String {
        switch state {
        case .installed:
            return "Detected"
        case .missing:
            return "Not Found"
        case .unavailable:
            return "Unavailable"
        }
    }
}
