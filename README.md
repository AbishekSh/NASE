# NASE

### Your Windows game library, made at home on macOS.

NASE is a native macOS game launcher for Steam, Epic Games, GOG, Windows
installers, and Mac apps. It brings every game into one searchable library and
handles Wine bottles, graphics backends, dependencies, launch settings, and
troubleshooting behind a focused SwiftUI interface.

NASE is built to feel like a launcher—not a collection of Wine scripts.

> [!IMPORTANT]
> NASE is in active development. It is ready for contributors and technical
> testers, but it is not yet a polished public release. Game compatibility
> varies by title and graphics backend.

## One Library, Every Source

- Browse Steam, Epic, GOG, native Mac apps, and personal Windows games together.
- Install, update, verify, repair, and uninstall supported store games in-app.
- Import an `.exe`, installer, app folder, or existing Wine prefix.
- Search, filter, pin, and organize games without managing folders by hand.
- Keep shared game files separate from isolated compatibility profiles.

Epic support uses Legendary and GOG support uses GOG Download Client. Both run
as native provider adapters, so their Windows store launchers are not required.

## Compatibility Without the Guesswork

Every game can have its own profile, bottle, launch arguments, environment,
working directory, and graphics backend. NASE supports:

- **DXMT** — the recommended default for modern Direct3D games.
- **D3DMetal** — an advanced profile using an imported, licensed Apple Game
  Porting Toolkit payload.
- **DXVK-macOS** — an experimental Vulkan-based profile that requires a
  compatible imported MoltenVK payload.
- **Plain Wine** — useful for launchers, utilities, and games that do not need
  a graphics translation override.

Profiles remain isolated, versioned, and repairable. NASE validates the selected
Wine engine and renderer together instead of treating graphics runtimes as
interchangeable DLL packs.

## Setup That Belongs to the App

The release build bundles a signed private Python 3.13 runtime. NASE downloads
checksum-pinned Wine Stable 11, Winetricks, GStreamer, and DXMT into its own
Application Support directory. Homebrew and a system Python installation are
not consumer requirements.

Downloads are verified before they enter the runtime cache. Interrupted or
invalid files are discarded safely, and the app does not start source refreshes
or background backend work until its bundled runtime passes preflight.

Rosetta 2 is the one Apple-managed prerequisite on Apple Silicon and requires
the user to accept Apple's license. Optional D3DMetal and MoltenVK components
must be imported from a compatible licensed installation; NASE does not
silently download or redistribute them.

The Recommended Gaming Environment guides a new installation through:

1. Runtime verification
2. Required managed downloads
3. Compatibility profile creation
4. Steam installation
5. Library attachment
6. Steam sign-in

Completed work is preserved if a step fails, with focused repair actions and
logs available inside the app.

## Built for Real Game Libraries

- **Isolated profiles:** Prefixes, renderers, shader caches, and logs stay
  separated while games can remain in shared host libraries.
- **Safe Steam ownership:** Only one profile can run Windows Steam against a
  shared library at a time, preventing competing clients from updating the same
  files.
- **Optional shared sign-in:** Protected Steam authentication metadata can be
  applied between stopped profiles without copying whole prefixes.
- **Session controls:** NASE tracks launched games, reconciles real process
  state, and can stop one game without shutting down an unrelated Steam session.
- **Actionable diagnostics:** Health checks, bounded log views, compatibility
  advice, Winetricks, and repair actions are available in-app.
- **Legacy support:** WoW64 handles supported 32-bit applications, while an
  optional private dgVoodoo2 overlay can help older DirectDraw and Direct3D
  titles without modifying shared game files.

## Storage and Privacy

NASE stores managed data under:

```text
~/Library/Application Support/NASE
```

This includes bottles, managed runtimes, logs, downloads, job records, provider
state, and the canonical Steam library registry. Imported external prefixes
remain in their original locations.

Upgrading from an older build automatically moves
`~/Library/Application Support/MySteamWine` to this location and updates
NASE-owned stored paths. The migration does not copy or modify external
prefixes.

Store credentials and remembered Steam metadata stay in NASE-owned storage with
restrictive permissions. Short-lived Epic authorization data is passed through
standard input rather than process arguments or job logs. NASE never modifies
Steam's host `libraryfolders.vdf` while discovering libraries.

## Uninstalling NASE

Open **Settings → General → Uninstall NASE**. NASE stops its managed Wine
processes, removes its preferences and caches, moves `NASE.app` to the Trash,
and quits.

The confirmation offers two data choices:

- Delete `~/Library/Application Support/NASE` for a complete uninstall,
  including managed bottles, runtimes, logs, protected Steam login data, and
  Epic/GOG games downloaded into NASE's managed library.
- Keep that folder if you intend to reinstall NASE without rebuilding its
  managed environment.

Imported executables, native Mac apps, external Wine prefixes, and Steam
libraries outside NASE's managed folder are never removed.

## Run NASE from Source

NASE is currently distributed as a source project for development and testing.
Open the Swift package:

```bash
open Package.swift
```

or:

```bash
xed .
```

Run the `SteamWineApp` target in Xcode. To verify a command-line build:

```bash
swift build
```

Release packaging, Developer ID signing, notarization, updates, and the
clean-machine release gate are documented in
[docs/RELEASING.md](docs/RELEASING.md).

## How NASE Is Built

The SwiftUI application is the product. Python remains a private implementation
engine for Wine setup, store adapters, diagnostics, scanning, and launch
workflows.

```text
Sources/SteamWineApp/   Native SwiftUI app, state, views, and backend bridge
mysteamwine/            Python implementation engine
mysteamwine.py          Secondary developer and debugging CLI
docs/                   Architecture, design, and release documentation
```

The app and backend communicate through structured JSON and streaming JSONL job
events. Long-running work is recorded under Application Support so NASE can
recover progress after an app restart, report failures clearly, and safely
cancel only verified backend processes.

For a complete module map, data flows, storage model, and design rationale, see:

- [Codebase Structure](docs/CODEBASE_STRUCTURE.md)
- [Frontend Design](docs/FRONTEND_DESIGN.md)
- [Release Guide](docs/RELEASING.md)

## Developer and Debugging CLI

The command-line interface is secondary. It keeps backend workflows testable
outside the app and is useful for diagnostics and automation.

```bash
# Inspect system and bottle readiness
python3 mysteamwine.py --json doctor

# Stream a managed setup job
python3 mysteamwine.py --bottle Default-DXMT --jsonl \
  setup-compatibility-profile --profile dxmt-wine-stable-11-v1

# List normalized games
python3 mysteamwine.py --json list-games

# Inspect durable work from this or an earlier app session
python3 mysteamwine.py --json list-jobs

# Inspect active game sessions
python3 mysteamwine.py --json list-sessions
```

Existing CLI commands remain supported while the native app continues moving
toward a structured, observable, concurrency-friendly backend contract.

## Project Direction

The near-term goal is a dependable public release with:

- A friendly first-launch experience on a clean Mac
- Internally managed, signed, and checksum-pinned dependencies
- Clear compatibility profiles instead of exposed Wine complexity
- Stronger per-title recommendations and repair workflows
- Stable multi-store installs, updates, and launches
- A polished library-first interface

NASE is designed around a simple principle: the game library stays front and
center, and operational complexity appears only when it is useful.
