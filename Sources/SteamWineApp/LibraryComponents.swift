import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SidebarRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let runner: RunnerKind
    let isSelected: Bool
    var gameCount: Int? = nil

    private var theme: ThemePalette { ThemePalette(scheme: colorScheme) }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? runner.brandBadgeBg : theme.controlBackground)
                    .frame(width: 30, height: 30)

                Image(systemName: runner.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? runner.brandForeground : theme.textSecondary)
            }
            .fixedSize()

            Text(runner.rawValue)
                .font(.system(size: 14, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            if let gameCount {
                Text("\(gameCount)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isSelected ? theme.textPrimary : theme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(isSelected ? theme.controlBackground : theme.panelRaised)
                    .clipShape(Capsule())
                    .fixedSize()
            } else if !runner.isAvailable {
                Text("Soon")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(theme.controlBackground)
                    .clipShape(Capsule())
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.panelBackground)
                        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.panelBorder, lineWidth: 1)
                }
            }
        )
        .contentShape(Rectangle())
    }
}

enum LibraryDisplayMode: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: Self { self }
}

struct GameCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let game: LibraryGame
    let isBusy: Bool
    let isDragging: Bool
    let collection: GameCollection
    let launchStatus: GameLaunchStatus?
    let canStop: Bool
    let steamCacheURL: URL?
    let displayMode: LibraryDisplayMode
    let allowsReordering: Bool
    let onDragStarted: () -> Void
    let onLaunch: () -> Void
    let onStop: () -> Void
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onOpenStore: () -> Void
    let onRevealFiles: () -> Void
    let onOpenDetails: () -> Void
    let onGameSettings: () -> Void
    let onRevealLogs: () -> Void
    let onDebugLaunch: () -> Void
    let onChangeIcon: () -> Void
    let onRemoveFromLibrary: () -> Void
    let onUpdateSourceGame: () -> Void
    let onVerifySourceGame: () -> Void
    let onRepairSourceGame: () -> Void
    let onUninstallSourceGame: () -> Void

    @State private var isHovered: Bool = false
    private var theme: ThemePalette { ThemePalette(scheme: colorScheme) }

    @ViewBuilder
    var body: some View {
        if displayMode == .list {
            listCard
        } else {
            gridCard
        }
    }

    private var gridCard: some View {
        // Size the card from a definite Color.clear sizer so every cell reserves
        // the same 2:3 height whether its art has decoded yet or is still showing
        // a skeleton/fallback (a content-driven aspect ratio collapses otherwise).
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                CoverArtwork(
                    cacheKey: "\(game.pinID):portrait",
                    sources: portraitSources,
                    maxPixelSize: 600,
                    contentMode: .fill
                ) {
                    fallbackCover
                }
            }
            .clipped()
        .overlay {
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(isHovered ? 0.9 : 0.66)],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(.easeOut(duration: 0.18), value: isHovered)
        }
        .overlay(alignment: .topLeading) {
            runnerBadge.padding(9)
        }
        .overlay(alignment: .topTrailing) {
            if collection != .none {
                Pill(text: collection.rawValue, tint: collection.color.opacity(0.9), foreground: .white)
                    .padding(9)
            }
        }
        .overlay(alignment: .bottomLeading) {
            gridBottomOverlay.padding(10)
        }
        .background(theme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHovered ? theme.panelHoverBorder : theme.panelBorder, lineWidth: isHovered ? 1.5 : 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.28 : 0.12), radius: isHovered ? 16 : 7, y: isHovered ? 8 : 3)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .opacity(isDragging ? 0.35 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(game.title), \(game.runner.rawValue), \(game.status)")
    }

    private var gridBottomOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(game.title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)
                .shadow(color: .black.opacity(0.6), radius: 4, y: 1)

            if isHovered {
                HStack(spacing: 8) {
                    primaryActionButton(diameter: 38)
                    Spacer(minLength: 4)
                    if allowsReordering { reorderHandle(size: 26) }
                    cardActionMenu
                }
                .transition(.opacity)
            } else if let launchStatus, launchStatus.phase.isActive {
                Pill(
                    text: launchStatus.phase.rawValue,
                    tint: launchTint(for: launchStatus.phase),
                    foreground: launchForeground(for: launchStatus.phase)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    private var runnerBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: game.runner.symbolName)
                .font(.system(size: 11, weight: .bold))
            Text(game.runner.rawValue)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(game.runner.brandForeground)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(game.runner.brandBadgeBg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }

    private func primaryActionButton(diameter: CGFloat) -> some View {
        Button {
            canStop ? onStop() : onLaunch()
        } label: {
            ZStack {
                Circle()
                    .fill(primaryActionColor)
                    .frame(width: diameter, height: diameter)
                    .shadow(color: primaryActionColor.opacity(isHovered ? 0.5 : 0.25), radius: isHovered ? 8 : 4, y: 3)
                Image(systemName: primaryActionSymbol)
                    .font(.system(size: diameter * 0.38, weight: .bold))
                    .foregroundStyle(canStop ? Color.white : Color.black)
            }
            .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(launchStatus?.phase == .launching || launchStatus?.phase == .stopping)
        .help(primaryActionHelp)
        .accessibilityLabel(primaryActionHelp)
    }

    private func reorderHandle(size: CGFloat) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: size, height: size)
            .contentShape(Rectangle())
            .onDrag {
                onDragStarted()
                return NSItemProvider(object: game.pinID as NSString)
            } preview: {
                DragBadge(title: game.title)
            }
            .help("Drag to reorder")
            .accessibilityLabel("Reorder \(game.title)")
    }

    // Ordered art candidates: local Steam portrait cache, then the store's
    // portrait URL, then the landscape banner as a last resort.
    private var portraitSources: [ArtworkLoader.Source] {
        var sources = steamLocalSources([
            "\(steamAppID)_library_600x900.jpg",
            "\(steamAppID)_library_600x900.png",
            "\(steamAppID)/library_600x900.jpg",
            "\(steamAppID)/library_600x900.png",
        ])
        if let portrait = game.portraitURL { sources.append(source(for: portrait)) }
        if let banner = game.bannerURL { sources.append(source(for: banner)) }
        return sources
    }

    private var landscapeSources: [ArtworkLoader.Source] {
        var sources = steamLocalSources([
            "\(steamAppID)_library_hero.jpg",
            "\(steamAppID)_library_hero.png",
            "\(steamAppID)/library_hero.jpg",
            "\(steamAppID)_header.jpg",
            "\(steamAppID)/header.jpg",
        ])
        if let banner = game.bannerURL { sources.append(source(for: banner)) }
        if let portrait = game.portraitURL { sources.append(source(for: portrait)) }
        return sources
    }

    private var steamAppID: String { game.backendID ?? "" }

    private func steamLocalSources(_ names: [String]) -> [ArtworkLoader.Source] {
        guard game.runner == .steam, game.backendID != nil, let root = steamCacheURL else { return [] }
        return names.map { .local(root.appendingPathComponent($0)) }
    }

    private func source(for url: URL) -> ArtworkLoader.Source {
        url.isFileURL ? .local(url) : .remote(url)
    }

    private var fallbackCover: some View {
        ZStack {
            LinearGradient(
                colors: [ArtworkLoader.fallbackColor(for: game.pinID), ArtworkLoader.fallbackColor(for: game.pinID).opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: game.runner.symbolName)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private var listCard: some View {
        HStack(spacing: 0) {
            CoverArtwork(
                cacheKey: "\(game.pinID):landscape",
                sources: landscapeSources,
                maxPixelSize: 320,
                contentMode: .fill
            ) {
                fallbackCover
            }
            .frame(width: 160, height: 84)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(6)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(game.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: game.runner.symbolName)
                            .font(.system(size: 10, weight: .bold))
                        Text(game.runner.rawValue)
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(game.runner.brandForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(game.runner.brandBadgeBg)
                    .clipShape(Capsule())
                }

                HStack(spacing: 6) {
                    Text(game.status)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)

                    if collection != .none {
                        Pill(text: collection.rawValue, tint: collection.color.opacity(0.18), foreground: collection.color)
                    }

                    if let launchStatus {
                        Pill(text: launchStatus.phase.rawValue, tint: launchTint(for: launchStatus.phase), foreground: launchForeground(for: launchStatus.phase))
                    }
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 12)

            if let statsText = game.statsText, !statsText.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 10))
                    Text(statsText)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .padding(.trailing, 10)
            }

            if allowsReordering {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .onDrag {
                        onDragStarted()
                        return NSItemProvider(object: game.pinID as NSString)
                    } preview: {
                        DragBadge(title: game.title)
                    }
                    .help("Drag to reorder")
            }

            cardActionMenu
                .padding(.horizontal, 4)

            primaryActionButton(diameter: 36)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .background(theme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHovered ? theme.panelHoverBorder : theme.panelBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 8 : 3, y: 2)
        .opacity(isDragging ? 0.35 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var primaryActionColor: Color {
        if canStop { return theme.accentRed }
        if [.epic, .gog].contains(game.runner), game.installURL == nil { return theme.accentPrimary }
        return theme.accentGreen
    }

    private var primaryActionSymbol: String {
        if canStop { return "stop.fill" }
        if [.epic, .gog].contains(game.runner), game.installURL == nil { return "arrow.down" }
        return "play.fill"
    }

    private var primaryActionHelp: String {
        if canStop { return "Stop \(game.title)" }
        if [.epic, .gog].contains(game.runner), game.installURL == nil { return "Install \(game.title)" }
        return "Play \(game.title)"
    }

    private func launchTint(for phase: GameLaunchPhase) -> Color {
        switch phase {
        case .launching:
            return theme.accentAmber.opacity(0.18)
        case .stopping:
            return theme.accentRed.opacity(0.18)
        case .running:
            return theme.accentGreen.opacity(0.18)
        case .exited:
            return theme.textMuted.opacity(0.14)
        case .failed:
            return theme.accentRed.opacity(0.18)
        }
    }

    private func launchForeground(for phase: GameLaunchPhase) -> Color {
        switch phase {
        case .launching:
            return theme.accentAmber
        case .stopping:
            return theme.accentRed
        case .running:
            return theme.accentGreen
        case .exited:
            return theme.textMuted
        case .failed:
            return theme.accentRed
        }
    }

    private var cardActionMenu: some View {
        Menu {
            Button("Game Details") {
                onOpenDetails()
            }
            Divider()
            Button(isPinned ? "Unpin from Home" : "Pin to Home") {
                onTogglePin()
            }
            if game.runner == .steam, game.storeURL != nil {
                Button("Open Steam Store Page") {
                    onOpenStore()
                }
            }
            if game.installURL != nil {
                Button("Reveal Local Files") {
                    onRevealFiles()
                }
            }
            if game.runner == .steam || game.runner == .wine {
                Button("Reveal Logs") {
                    onRevealLogs()
                }
                Button("Debug Launch") {
                    onDebugLaunch()
                }
            }
            if [.epic, .gog].contains(game.runner), game.installURL != nil {
                Divider()
                Button("Update") { onUpdateSourceGame() }
                Button("Verify Files") { onVerifySourceGame() }
                Button("Repair and Update") { onRepairSourceGame() }
                Button("Uninstall", role: .destructive) { onUninstallSourceGame() }
            }
            Button("Game Settings") {
                onGameSettings()
            }
            if ![.epic, .gog].contains(game.runner) {
                Divider()
                Button(game.runner == .steam ? "Hide from Library" : "Remove from Library", role: .destructive) {
                    onRemoveFromLibrary()
                }
            }
        } label: {
            CardActionMenuLabel(isHovered: isHovered)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .zIndex(4)
    }
}

struct CardActionMenuLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let isHovered: Bool

    private var theme: ThemePalette { ThemePalette(scheme: colorScheme) }

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(theme.textSecondary)
            .frame(width: 28, height: 28)
            .background(theme.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isHovered ? theme.controlBorder : Color.clear, lineWidth: 1)
            )
            .accessibilityLabel("Game actions")
    }
}

struct GameDropDelegate: DropDelegate {
    let targetGame: LibraryGame
    @Binding var draggedGame: LibraryGame?
    let model: AppViewModel

    func dropEntered(info: DropInfo) {
        guard let draggedGame, draggedGame.pinID != targetGame.pinID else { return }
        withAnimation(.snappy(duration: 0.14)) {
            model.moveGame(draggedGame, before: targetGame)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation(.snappy(duration: 0.1)) {
            draggedGame = nil
        }
        return true
    }
}

struct BannerArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    let url: URL?
    let title: String
    let height: CGFloat
    let installURL: URL?
    let runner: RunnerKind
    let appid: String?
    let steamCacheURL: URL?
    var showsTitleOverlay: Bool = true
    var isHovered: Bool = false

    private var theme: ThemePalette { ThemePalette(scheme: colorScheme) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let customImage {
                    artworkLayer(Image(nsImage: customImage))
                } else if let localSteamBannerImage {
                    artworkLayer(Image(nsImage: localSteamBannerImage))
                } else if let url {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            placeholder
                        case .success(let image):
                            artworkLayer(image)
                        case .failure:
                            placeholder
                        @unknown default:
                            placeholder
                        }
                    }
                } else {
                    localFallbackArtwork
                }

                Rectangle()
                    .fill(.black.opacity(0.12))

                LinearGradient(
                    colors: [
                        .black.opacity(0.65),
                        .black.opacity(0.2),
                        .clear,
                    ],
                    startPoint: .bottomLeading,
                    endPoint: .topTrailing
                )

                if showsTitleOverlay, let steamLogoImage {
                    Image(nsImage: steamLogoImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: min(320, height * 2.7), maxHeight: height * 0.58, alignment: .leading)
                        .shadow(color: .black.opacity(0.55), radius: 7, y: 3)
                        .padding(.leading, steamIconImage == nil ? 16 : 80)
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                } else if showsTitleOverlay {
                    Text(title)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .shadow(color: .black.opacity(0.55), radius: 7, y: 3)
                        .padding(.leading, steamIconImage == nil ? 16 : 80)
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                if let steamIcon = steamIconImage {
                    Image(nsImage: steamIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .padding(6)
                        .background(.black.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(.white.opacity(0.2), lineWidth: 1)
                        )
                        .padding(10)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(height: height)
        .background(theme.panelRaised)
    }

    private var placeholder: some View {
        Rectangle()
            .fill(theme.panelRaised)
    }

    private func artworkLayer(_ image: Image) -> some View {
        ZStack {
            image
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: height)
                .scaleEffect(isHovered ? 1.05 : 1.0)
                .animation(.easeOut(duration: 0.25), value: isHovered)
        }
        .frame(maxWidth: .infinity, maxHeight: height)
        .clipped()
    }

    private var localFallbackArtwork: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(dominantLocalColor.opacity(0.92))

            if let installURL, let icon = localIconImage(for: installURL) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: height * 0.42, height: height * 0.42)
                    .padding(14)
                    .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
            } else {
                Image(systemName: runner.symbolName)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(18)
            }
        }
    }

    private var dominantLocalColor: Color {
        guard let installURL, let icon = localIconImage(for: installURL) else {
            return theme.panelRaised
        }
        return averageColor(for: icon) ?? theme.panelRaised
    }

    private func localIconImage(for url: URL) -> NSImage? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    private var localSteamBannerImage: NSImage? {
        guard runner == .steam, let appid else { return nil }
        return localSteamBanner(appid: appid)
    }

    private var steamIconImage: NSImage? {
        guard runner == .steam, let appid else { return nil }
        return localSteamIcon(appid: appid)
    }

    private var steamLogoImage: NSImage? {
        guard runner == .steam, let appid else { return nil }
        return localSteamLogo(appid: appid)
    }

    private var customImage: NSImage? {
        guard let url, url.isFileURL else { return nil }
        return NSImage(contentsOf: url)
    }

    private func localSteamBanner(appid: String) -> NSImage? {
        guard let cacheRoot = steamCacheURL else { return nil }
        let candidates = [
            cacheRoot.appendingPathComponent("\(appid)_library_hero.jpg"),
            cacheRoot.appendingPathComponent("\(appid)_library_hero.png"),
            cacheRoot.appendingPathComponent("\(appid)/library_hero.jpg"),
            cacheRoot.appendingPathComponent("\(appid)/library_hero.png"),
            cacheRoot.appendingPathComponent("\(appid)_header.jpg"),
            cacheRoot.appendingPathComponent("\(appid)_header.png"),
            cacheRoot.appendingPathComponent("\(appid)/header.jpg"),
            cacheRoot.appendingPathComponent("\(appid)/header.png"),
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }
        return nil
    }

    private func localSteamIcon(appid: String) -> NSImage? {
        guard let cacheRoot = steamCacheURL else { return nil }
        let candidates = [
            cacheRoot.appendingPathComponent("\(appid)_icon.jpg"),
            cacheRoot.appendingPathComponent("\(appid)_icon.png"),
            cacheRoot.appendingPathComponent("\(appid)/icon.jpg"),
            cacheRoot.appendingPathComponent("\(appid)/icon.png"),
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }
        return nil
    }

    private func localSteamLogo(appid: String) -> NSImage? {
        guard let cacheRoot = steamCacheURL else { return nil }
        let directCandidates = [
            cacheRoot.appendingPathComponent("\(appid)_logo.png"),
            cacheRoot.appendingPathComponent("\(appid)/logo.png"),
        ]

        for candidate in directCandidates where FileManager.default.fileExists(atPath: candidate.path) {
            if let image = NSImage(contentsOf: candidate) {
                return image
            }
        }

        let appFolder = cacheRoot.appendingPathComponent(appid, isDirectory: true)
        guard let nestedCandidates = try? FileManager.default.contentsOfDirectory(
            at: appFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for folder in nestedCandidates where folder.hasDirectoryPath {
            let candidate = folder.appendingPathComponent("logo.png")
            if FileManager.default.fileExists(atPath: candidate.path), let image = NSImage(contentsOf: candidate) {
                return image
            }
        }

        return nil
    }

    private func averageColor(for image: NSImage) -> Color? {
        guard
            let tiffData = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var count: CGFloat = 0

        let sampleStep = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 24)
        for x in stride(from: 0, to: bitmap.pixelsWide, by: sampleStep) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: sampleStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                count += 1
            }
        }

        guard count > 0 else { return nil }
        return Color(
            .sRGB,
            red: red / count,
            green: green / count,
            blue: blue / count,
            opacity: 1
        )
    }

    private var themePanel: Color { colorScheme == .dark ? Color(hex: "#2A302C") : Color(hex: "#F7FBF5") }
    private var themePanelRaised: Color { colorScheme == .dark ? Color(hex: "#353D38") : Color(hex: "#DEE8DE") }
}
