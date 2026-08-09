import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var draggedGame: LibraryGame?
    @AppStorage("libraryDisplayMode") private var libraryDisplayMode: LibraryDisplayMode = .grid
    @FocusState private var focusedGameID: String?
    @State private var gridColumnCount: Int = 1

    private var theme: ThemePalette { ThemePalette(scheme: colorScheme) }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            library
        }
        .navigationSplitViewStyle(.prominentDetail)
        .sheet(isPresented: $model.isShowingSettings) {
            SettingsSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingGameSettings) {
            if let game = model.editingGame {
                GameSettingsSheet(model: model, game: game)
            }
        }
        .sheet(isPresented: $model.isShowingGameDetails) {
            if let game = model.editingGame {
                GameDetailsSheet(model: model, game: game)
            }
        }
        .sheet(isPresented: $model.isShowingLogViewer) {
            LogViewerSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingWinetricks) {
            WinetricksSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingSetupWizard) {
            SetupWizardSheet(model: model)
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $model.isShowingEpicSetup) {
            EpicSetupSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingGOGSetup) {
            GOGSetupSheet(model: model)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let image = moduleNSImage(named: "NASE Logo") {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .shadow(color: theme.accentPrimary.opacity(0.3), radius: 6, y: 2)
                } else {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(theme.accentPrimary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("NASE")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text("Game Launcher")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .background(theme.panelBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(model.sidebarSections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.title.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.textMuted)
                                .padding(.horizontal, 16)
                                .lineLimit(1)

                            ForEach(section.runners) { runner in
                                Button {
                                    model.selectRunner(runner)
                                } label: {
                                    SidebarRow(
                                        runner: runner,
                                        isSelected: model.selectedRunner == runner,
                                        gameCount: countForRunner(runner)
                                    )
                                }
                               .buttonStyle(.plain)
                               .padding(.horizontal, 10)
                               .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }

            Divider()
                .background(theme.panelBorder)

            sidebarCommandCenter
        }
        .background(theme.sidebarBackground)
        .navigationTitle("Sources")
    }

    private var library: some View {
        GeometryReader { geometry in
                ScrollView {
                    if model.filteredGames.isEmpty {
                        EmptyLibraryState(
                            title: model.selectedRunner?.rawValue ?? "Library",
                            message: model.libraryEmptyMessage,
                            showsActions: model.shouldShowSteamEmptyStateActions,
                            isBusy: model.isBusy,
                            isLoading: model.isRefreshingSteamGames,
                            onOpenSettings: {
                                model.openSettings()
                            },
                            onRefresh: {
                                model.refreshGames()
                            }
                        )
                        .padding(24)
                    } else if libraryDisplayMode == .grid {
                        let columns = gridColumns(for: geometry.size.width)
                        LazyVGrid(
                            columns: columns,
                            alignment: .leading,
                            spacing: libraryGridSpacing
                        ) {
                            ForEach(model.filteredGames, id: \.pinID) { game in
                                gameCard(for: game)
                            }
                        }
                        .padding(.horizontal, libraryGridPadding)
                        .padding(.vertical, libraryGridSpacing)
                        .onAppear { gridColumnCount = columns.count }
                        .onChange(of: geometry.size.width) { _, width in
                            gridColumnCount = gridColumns(for: width).count
                        }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(model.filteredGames, id: \.pinID) { game in
                                gameCard(for: game)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                    }
                }
                .background(theme.appBackground)
            }
            .background(theme.appBackground)
        .navigationTitle(model.selectedRunner?.rawValue ?? "Library")
        .navigationSubtitle(librarySubtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search library…")
        .toolbar { libraryToolbar }
        .task {
            model.initialLoad()
        }
    }

    @ToolbarContentBuilder
    private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                ForEach(LibrarySortOption.allCases) { option in
                    Button(option.rawValue) { model.sortOption = option }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .help("Sort library")

            Menu {
                Button("All Collections") { model.collectionFilter = nil }
                ForEach(GameCollection.allCases.filter { $0 != .none }) { collection in
                    Button(collection.rawValue) { model.collectionFilter = collection }
                }
            } label: {
                Label(model.collectionFilter?.rawValue ?? "Collections", systemImage: "line.3.horizontal.decrease.circle")
            }
            .help("Filter by collection")

            if model.selectedRunner == .home {
                Menu {
                    ForEach(LibrarySourceFilter.allCases) { option in
                        Button(option.rawValue) { model.sourceFilter = option }
                    }
                } label: {
                    Label(model.sourceFilter.rawValue, systemImage: "square.grid.2x2")
                }
                .help("Filter by source")
            }

            Picker("Library layout", selection: $libraryDisplayMode) {
                Image(systemName: "square.grid.2x2").tag(LibraryDisplayMode.grid)
                Image(systemName: "list.bullet").tag(LibraryDisplayMode.list)
            }
            .pickerStyle(.segmented)
            .help(libraryDisplayMode == .grid ? "Switch to list view" : "Switch to grid view")

            if model.selectedRunner == .steam {
                Button {
                    model.perform(OperationCard(kind: .openSteam, title: "Open Steam", detail: "Open Windows Steam.", symbolName: "play.circle"))
                } label: {
                    Label("Open Steam", systemImage: "play.circle")
                }
            }
            if model.shouldShowAddButton {
                if model.shouldShowWineAddMenu {
                    Menu {
                        Button("Add Windows Game") { model.performPrimaryAddAction() }
                        Button("Open Installer") { model.openWineInstaller() }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                } else {
                    Button { model.performPrimaryAddAction() } label: {
                        Label(model.selectedRunnerActionTitle, systemImage: "plus")
                    }
                }
            }
            if model.selectedRunner == .epic {
                Button { model.openEpicSetup() } label: {
                    Label("Epic Setup", systemImage: "person.badge.key")
                }
            }
            if model.selectedRunner == .gog {
                Button { model.openGOGSetup() } label: {
                    Label("GOG Setup", systemImage: "person.badge.key")
                }
            }
            if let runner = model.selectedRunner, [.steam, .epic, .gog].contains(runner) {
                Button { refreshSelectedSource() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh the selected library")
            }
            Button { model.openSettings() } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
        }
    }

    private let libraryGridSpacing: CGFloat = 18
    private let libraryGridPadding: CGFloat = 20

    private func gridColumns(for availableWidth: CGFloat) -> [GridItem] {
        let preferredCardWidth: CGFloat = 185
        let usableWidth = max(160, availableWidth - (libraryGridPadding * 2))
        let columnCount = max(
            1,
            Int((usableWidth + libraryGridSpacing) / (preferredCardWidth + libraryGridSpacing))
        )

        return Array(
            repeating: GridItem(
                .flexible(minimum: 150, maximum: 240),
                spacing: libraryGridSpacing,
                alignment: .top
            ),
            count: columnCount
        )
    }

    private func countForRunner(_ runner: RunnerKind) -> Int? {
        model.gameCount(for: runner)
    }

    private var librarySubtitle: String {
        let count = model.filteredGames.count
        let noun = count == 1 ? "game" : "games"
        let description = model.selectedRunner?.subtitle ?? "Your game library"
        return "\(count) \(noun)  •  \(description)"
    }


    private var sidebarCommandCenter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let job = model.currentOperationJob {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.action).font(.system(size: 12, weight: .bold)).foregroundStyle(theme.textPrimary).lineLimit(1)
                        Text(job.message).font(.system(size: 11)).foregroundStyle(theme.textSecondary).lineLimit(1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(theme.accentGreen)
                        .frame(width: 8, height: 8)
                    Text("Backend Ready")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
            }

            Button {
                model.stopAllWineProcesses()
            } label: {
                Label("Stop All Wine Processes", systemImage: "stop.circle")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .background(theme.controlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(theme.controlBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(model.hasActiveBackendWork && model.currentOperationJob?.action == "Kill Wine")
            .help("Emergency stop for Wine and game processes across every NASE bottle")
        }
        .padding(12)
        .background(theme.sidebarBackground)
        .animation(.easeInOut(duration: 0.18), value: model.currentOperationJob?.id)
    }

    private func refreshSelectedSource() {
        switch model.selectedRunner {
        case .steam: model.refreshGames()
        case .epic: model.refreshEpicLibrary()
        case .gog: model.refreshGOGLibrary()
        default: break
        }
    }

    @ViewBuilder
    private func gameCard(for game: LibraryGame) -> some View {
        Group {
            if model.selectedRunner == .home {
                configuredGameCard(for: game)
                    .onDrop(
                        of: [UTType.text],
                        delegate: GameDropDelegate(targetGame: game, draggedGame: $draggedGame, model: model)
                    )
            } else {
                configuredGameCard(for: game)
            }
        }
        .focusable()
        .focused($focusedGameID, equals: game.pinID)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.accentPrimary, lineWidth: focusedGameID == game.pinID ? 2.5 : 0)
        )
        .onKeyPress(.return) {
            model.canStop(game) ? model.stop(game) : model.launch(game)
            return .handled
        }
        .onMoveCommand { direction in
            moveFocus(direction, from: game)
        }
    }

    /// Arrow-key navigation across the library. Left/right step one card;
    /// up/down jump by a full row using the current column count.
    private func moveFocus(_ direction: MoveCommandDirection, from game: LibraryGame) {
        let games = model.filteredGames
        guard let index = games.firstIndex(where: { $0.pinID == game.pinID }) else { return }
        let stride = libraryDisplayMode == .grid ? gridColumnCount : 1
        let target: Int
        switch direction {
        case .left: target = index - 1
        case .right: target = index + 1
        case .up: target = index - stride
        case .down: target = index + stride
        @unknown default: return
        }
        guard games.indices.contains(target) else { return }
        focusedGameID = games[target].pinID
    }

    private func configuredGameCard(for game: LibraryGame) -> some View {
        GameCard(
            game: game,
            isBusy: model.isBusy,
            isDragging: draggedGame?.pinID == game.pinID,
            collection: model.settings(for: game).collection,
            launchStatus: model.launchStatus(for: game),
            canStop: model.canStop(game),
            steamCacheURL: model.steamLibraryCacheURL,
            displayMode: libraryDisplayMode,
            allowsReordering: model.selectedRunner == .home,
            onDragStarted: { draggedGame = game },
            onLaunch: { model.launch(game) },
            onStop: { model.stop(game) },
            isPinned: model.isPinned(game),
            onTogglePin: { model.togglePin(for: game) },
            onOpenStore: { model.openSteamStorePage(for: game) },
            onRevealFiles: { model.revealLocalFiles(for: game) },
            onOpenDetails: { model.openGameDetails(for: game) },
            onGameSettings: { model.openGameSettings(for: game) },
            onRevealLogs: { model.openLogViewer(for: game) },
            onDebugLaunch: { model.debugLaunch(game) },
            onChangeIcon: { model.changeAppIcon() },
            onRemoveFromLibrary: { model.removeGameFromLibrary(game) },
            onUpdateSourceGame: { game.runner == .gog ? model.updateGOGGame(game) : model.updateEpicGame(game) },
            onVerifySourceGame: { game.runner == .gog ? model.verifyGOGGame(game) : model.verifyEpicGame(game) },
            onRepairSourceGame: { game.runner == .gog ? model.repairGOGGame(game) : model.repairEpicGame(game) },
            onUninstallSourceGame: { game.runner == .gog ? model.uninstallGOGGame(game) : model.uninstallEpicGame(game) }
        )
    }

}
