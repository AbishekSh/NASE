# Contributing to NASE

Thanks for your interest in NASE — a native macOS game launcher for Steam,
Epic, GOG, Windows games, and Mac apps. This guide gets you from a fresh clone
to a running build and a passing test suite quickly.

## Prerequisites

- **macOS 14 (Sonoma) or newer.**
- **Xcode** (or the Swift toolchain / command-line tools) for the SwiftUI app.
- **Python 3.13** for the backend during development. (Release builds bundle
  their own signed Python runtime — see [docs/RELEASING.md](docs/RELEASING.md) —
  so end users never install Python.)
- **Rosetta 2** on Apple Silicon, since the managed Wine runtime is x86_64.

## Architecture in one minute

NASE is a hybrid app. **The SwiftUI application is the product; Python is a
private implementation engine** for Wine setup, store adapters, diagnostics,
and launch workflows.

```
SwiftUI views  →  AppViewModel  →  BackendBridge.swift
                                        │  (JSON for short calls,
                                        ▼   streaming JSONL for long jobs)
                                     nase.py  →  nase/ Python modules
                                        │
                                        ▼
                            Wine, store providers, files, processes
```

- `Sources/NASE/` — the SwiftUI app: views, `AppViewModel` (state/orchestration),
  and `BackendBridge.swift` (the **only** layer that knows the Python CLI's
  argument shapes).
- `nase/` — the Python engine (`cli.py`, `runtime.py`, `bottle.py`, `profiles.py`,
  `steam*.py`, `sessions.py`, `jobs.py`, `doctor.py`, `sources/`, graphics
  backends, …).
- `nase.py` — the thin CLI entry point (also handy for debugging: `python3 nase.py --json doctor`).
- `tests/` — Python `unittest` tests plus the Swift `NASETests` target.
- `docs/`, `scripts/`, `assets/`, `release/` — documentation, build/packaging, and app resources.

The two sides talk through **structured JSON and streaming JSONL job events**.
Long-running work is recorded under `~/Library/Application Support/NASE` so the
app can recover progress after a restart.

For the full module map and design rationale, see
[docs/CODEBASE_STRUCTURE.md](docs/CODEBASE_STRUCTURE.md) and
[docs/FRONTEND_DESIGN.md](docs/FRONTEND_DESIGN.md).

## Build and run

Open the package in Xcode and run the **NASE** target:

```bash
open Package.swift   # or: xed .
```

Or from the command line:

```bash
swift build
.build/debug/NASE
```

To test a first-run experience without touching your real setup, launch with an
isolated home directory — the app writes all managed data under `$HOME`:

```bash
HOME=$(mktemp -d) .build/debug/NASE
```

## Run the checks before you push

```bash
swift build
swift test
python3 -m compileall nase nase.py
python3 -m unittest discover -s tests
```

All four should pass. Please add or update tests when you change backend
behavior or the Swift/Python contract.

## Conventions

- **Keep the Swift/Python boundary clean.** Don't construct Python command
  arguments in SwiftUI views — go through `BackendBridge.swift`. Prefer adding
  structured response fields over parsing new human-readable output.
- **Keep Wine and process behavior in Python** unless moving it to Swift has a
  concrete benefit.
- **Preserve both managed bottles and external prefixes**, and keep the terminal
  CLI workflows functional.
- **Match the surrounding code** — naming, comment density, and idiom.
- **Branch per change**, keep documentation in sync when architecture or
  workflows change, and avoid unrelated cleanup in the same change.

## A note on legacy names

The identifier `MySteamWine` still appears in a few places (`LEGACY_APP_NAME`,
`legacyDirectoryName`, and migration tests). **Leave these as-is** — they are
deliberate anchors that migrate data from the app's previous name into
`~/Library/Application Support/NASE`. Renaming them would strand existing users'
data.

## Reporting issues

Game compatibility varies by title and graphics backend. When filing a bug,
include your macOS version, the game and store, the selected compatibility
profile, and any relevant log excerpts (Settings → Advanced → logs, or
`Doctor`). The [Beta Testing Guide](docs/BETA_TESTING.md) has more detail.
