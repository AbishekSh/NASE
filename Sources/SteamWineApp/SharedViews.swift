import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemePalette {
    let scheme: ColorScheme

    var appBackground: Color { scheme == .dark ? Color(hex: "#00111D") : Color(hex: "#F0F6F9") }
    var sidebarBackground: Color { scheme == .dark ? Color(hex: "#000611") : Color(hex: "#E5EFF5") }
    var toolbarBackground: Color { scheme == .dark ? Color(hex: "#000611") : Color(hex: "#E5EFF5") }
    var panelBackground: Color { scheme == .dark ? Color(hex: "#001E29") : Color(hex: "#FFFFFF") }
    var panelRaised: Color { scheme == .dark ? Color(hex: "#002B3A") : Color(hex: "#F0F6F9") }
    var panelBorder: Color { scheme == .dark ? Color(hex: "#003843") : Color(hex: "#CBD5E1") }
    var panelHoverBorder: Color { scheme == .dark ? Color(hex: "#00BAFE") : Color(hex: "#94A3B8") }
    var controlBackground: Color { scheme == .dark ? Color(hex: "#002937") : Color(hex: "#F8FAFC") }
    var controlBorder: Color { scheme == .dark ? Color(hex: "#003843") : Color(hex: "#E2E8F0") }
    var textPrimary: Color { scheme == .dark ? Color(hex: "#FFD6A7") : Color(hex: "#0F172A") }
    var textSecondary: Color { scheme == .dark ? Color(hex: "#90C4D4") : Color(hex: "#475569") }
    var textMuted: Color { scheme == .dark ? Color(hex: "#5A8B9C") : Color(hex: "#94A3B8") }
    var accentPrimary: Color { scheme == .dark ? Color(hex: "#00BAFE") : Color(hex: "#0284C7") }
    var accentGreen: Color { scheme == .dark ? Color(hex: "#01DF72") : Color(hex: "#059669") }
    var accentRed: Color { scheme == .dark ? Color(hex: "#F04E4F") : Color(hex: "#E11D48") }
    var accentAmber: Color { scheme == .dark ? Color(hex: "#FFBF00") : Color(hex: "#D97706") }
}
extension RunnerKind {
    var brandGradient: LinearGradient {
        switch self {
        case .home:
            LinearGradient(colors: [Color(hex: "#6366F1"), Color(hex: "#8B5CF6")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mac:
            LinearGradient(colors: [Color(hex: "#0284C7"), Color(hex: "#38BDF8")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .steam:
            LinearGradient(colors: [Color(hex: "#171A21"), Color(hex: "#2A475E")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .wine:
            LinearGradient(colors: [Color(hex: "#721C24"), Color(hex: "#9E2A2B")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .epic:
            LinearGradient(colors: [Color(hex: "#2A2A2A"), Color(hex: "#121212")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gog:
            LinearGradient(colors: [Color(hex: "#5C1B8E"), Color(hex: "#8E24AA")], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var brandForeground: Color {
        switch self {
        case .home: Color(hex: "#EDE9FE")
        case .mac: Color(hex: "#E0F2FE")
        case .steam: Color(hex: "#66C0F4")
        case .wine: Color(hex: "#FFD2D2")
        case .epic: Color(hex: "#FFFFFF")
        case .gog: Color(hex: "#F3E8FF")
        }
    }

    var brandBadgeBg: Color {
        switch self {
        case .home: Color(hex: "#4338CA").opacity(0.85)
        case .mac: Color(hex: "#0369A1").opacity(0.85)
        case .steam: Color(hex: "#171A21").opacity(0.85)
        case .wine: Color(hex: "#5C1318").opacity(0.85)
        case .epic: Color(hex: "#202020").opacity(0.85)
        case .gog: Color(hex: "#4A148C").opacity(0.85)
        }
    }
}

struct EmptyLibraryState: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let message: String
    let showsActions: Bool
    let isBusy: Bool
    let isLoading: Bool
    let onOpenSettings: () -> Void
    let onRefresh: () -> Void

    private var theme: ThemePalette { ThemePalette(scheme: colorScheme) }

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(theme.accentPrimary.opacity(0.12))
                    .frame(width: 84, height: 84)
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(theme.accentPrimary)
                }
            }
            .padding(.top, 12)

            VStack(spacing: 6) {
                Text(isLoading ? "Refreshing \(title) library" : "No \(title) items found")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            if showsActions {
                HStack(spacing: 12) {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("Open Settings", systemImage: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(theme.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.controlBorder, lineWidth: 1)
                    )

                    Button {
                        onRefresh()
                    } label: {
                        Label("Run Refresh Again", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(theme.accentPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: theme.accentPrimary.opacity(0.3), radius: 6, y: 3)
                }
                .disabled(isBusy)
                .opacity(isBusy ? 0.6 : 1)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 380)
        .padding(32)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(theme.panelBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }
}

func naseResourceURL(named name: String, withExtension fileExtension: String) -> URL? {
    let bundleName = "SteamWineApp_SteamWineApp.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(bundleName, isDirectory: true),
        Bundle.main.bundleURL.appendingPathComponent(bundleName, isDirectory: true),
    ].compactMap { $0 }

    for candidate in candidates {
        if let bundle = Bundle(url: candidate),
           let resource = bundle.url(forResource: name, withExtension: fileExtension) {
            return resource
        }
    }
    return Bundle.main.url(forResource: name, withExtension: fileExtension)
}

func moduleNSImage(named name: String) -> NSImage? {
    if let bundleURL = naseResourceURL(named: name, withExtension: "png"),
       let image = NSImage(contentsOf: bundleURL) {
        return image
    }

    let sourceURL = URL(fileURLWithPath: #filePath)
    let repoRoot = sourceURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let assetURL = repoRoot.appendingPathComponent("assets/\(name).png")
    return NSImage(contentsOf: assetURL)
}

struct Pill: View {
    let text: String
    let tint: Color
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint)
            .clipShape(Capsule())
    }
}

extension HealthStatus {
    var color: Color {
        switch self {
        case .unknown:
            return Color.secondary.opacity(0.28)
        case .healthy:
            return Color(hex: "#10B981")
        case .warning:
            return Color(hex: "#F59E0B")
        case .error:
            return Color(hex: "#F43F5E")
        }
    }

    var showsIndicator: Bool {
        self == .error
    }

    var showsIssueBadge: Bool {
        self == .error
    }
}

extension GameCollection {
    var color: Color {
        switch self {
        case .none:
            return Color.secondary
        case .favorites:
            return Color(hex: "#F59E0B")
        case .finished:
            return Color(hex: "#10B981")
        case .testing:
            return Color(hex: "#38BDF8")
        case .broken:
            return Color(hex: "#F43F5E")
        }
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
