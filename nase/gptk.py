from __future__ import annotations

import os
import hashlib
from pathlib import Path
import shutil
import subprocess
from typing import Any

from .d3dmetal import inspect_d3dmetal_bundle
from .bottle import app_support_root


SUPPORTED_D3DMETAL_WINE_VERSIONS = ("wine-10.0 (Sikarugir)",)
SIKARUGIR_NATIVE_DEPENDENCY = "libinotify.0.dylib"


def _candidate_roots() -> list[Path]:
    roots = [
        Path("/Applications/Game Porting Toolkit.app/Contents/Resources"),
        Path("/opt/local/libexec/game-porting-toolkit"),
        Path("/usr/local/opt/game-porting-toolkit"),
        Path("/opt/homebrew/opt/game-porting-toolkit"),
    ]
    volumes = Path("/Volumes")
    try:
        roots.extend(path for path in volumes.glob("Game Porting Toolkit*") if path.is_dir())
        roots.extend(
            path / "redist" / "lib"
            for path in volumes.glob("Evaluation environment for Windows games*")
            if (path / "redist" / "lib").is_dir()
        )
    except OSError:
        pass
    return roots


def _wine_candidates(root: Path) -> list[Path]:
    return [
        root / "bin" / "wine64",
        root / "bin" / "wine",
        root / "wine" / "bin" / "wine64",
        root / "wine" / "bin" / "wine",
        root / "game-porting-toolkit" / "bin" / "wine64",
        root / "game-porting-toolkit" / "bin" / "wine",
    ]


def _installation_root(wine_path: Path, payload_root: Path) -> Path | None:
    wine = wine_path.expanduser().resolve(strict=False)
    payload = payload_root.expanduser().resolve(strict=False)
    try:
        common = Path(os.path.commonpath([wine, payload]))
    except ValueError:
        return None
    normalized_common = str(common).lower().replace("_", "-")
    if "game-porting-toolkit" not in normalized_common and "game porting toolkit" not in normalized_common:
        return None
    return common


def _shared_wrapper_contents(wine_path: Path, renderer_root: Path) -> Path | None:
    wine_contents = next((path for path in wine_path.parents if path.name == "Contents"), None)
    renderer_contents = next((path for path in renderer_root.parents if path.name == "Contents"), None)
    if wine_contents is not None and wine_contents == renderer_contents:
        return wine_contents
    return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def prepare_sikarugir_native_dependencies(wine_path: Path, d3dmetal_source: Path) -> dict[str, Any]:
    """Make the pinned Sikarugir engine self-contained before any Wine process starts."""
    wine = wine_path.expanduser().resolve(strict=False)
    wine_root = wine.parent.parent
    wineserver = wine_root / "bin" / "wineserver"
    if not wineserver.is_file():
        raise RuntimeError(f"Sikarugir Wine is missing wineserver: {wineserver}")

    result = subprocess.run(["otool", "-L", str(wineserver)], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"Could not inspect Sikarugir Wine native dependencies: {(result.stderr or '').strip()}")
    if SIKARUGIR_NATIVE_DEPENDENCY not in result.stdout:
        raise RuntimeError(
            f"The selected Sikarugir wineserver does not declare {SIKARUGIR_NATIVE_DEPENDENCY}; "
            "the engine does not match the supported Wine 10 revision 6 build."
        )

    source = d3dmetal_source.expanduser().resolve(strict=False)
    frameworks = next((parent for parent in (source, *source.parents) if parent.name == "Frameworks"), None)
    dependency_source = frameworks / SIKARUGIR_NATIVE_DEPENDENCY if frameworks else None
    if dependency_source is None or not dependency_source.is_file():
        installed_dependency = wine_root / "lib" / SIKARUGIR_NATIVE_DEPENDENCY
        if installed_dependency.is_file():
            return {
                "dependency": SIKARUGIR_NATIVE_DEPENDENCY,
                "source": str(installed_dependency),
                "installed_path": str(installed_dependency),
                "sha256": _sha256(installed_dependency),
                "verified_library_count": 1,
            }
        raise RuntimeError(
            f"The selected Wine engine and D3DMetal bundle are missing {SIKARUGIR_NATIVE_DEPENDENCY}. "
            "Repair the pinned Sikarugir Wine 10 runtime, then retry."
        )

    dependency_dir = wine_root / "lib"
    dependency_dir.mkdir(parents=True, exist_ok=True)
    verified: dict[str, str] = {}
    for native_source in sorted(frameworks.glob("*.dylib")):
        native_destination = dependency_dir / native_source.name
        if native_source.is_symlink():
            link_target = os.readlink(native_source)
            if native_destination.is_symlink() and os.readlink(native_destination) == link_target:
                continue
            native_destination.unlink(missing_ok=True)
            native_destination.symlink_to(link_target)
            continue
        source_checksum = _sha256(native_source)
        if not native_destination.is_file() or native_destination.is_symlink() or _sha256(native_destination) != source_checksum:
            native_destination.unlink(missing_ok=True)
            shutil.copy2(native_source, native_destination)
        installed_checksum = _sha256(native_destination)
        if installed_checksum != source_checksum:
            raise RuntimeError(f"Checksum verification failed while installing {native_source.name}.")
        verified[native_source.name] = installed_checksum

    dependency_destination = dependency_dir / SIKARUGIR_NATIVE_DEPENDENCY
    installed_checksum = verified.get(SIKARUGIR_NATIVE_DEPENDENCY)
    if installed_checksum is None or not dependency_destination.is_file():
        raise RuntimeError(f"Failed to install required native dependency {SIKARUGIR_NATIVE_DEPENDENCY}.")

    return {
        "dependency": SIKARUGIR_NATIVE_DEPENDENCY,
        "source": str(dependency_source),
        "installed_path": str(dependency_destination),
        "sha256": installed_checksum,
        "verified_library_count": len(verified),
    }


def inspect_gptk_installation(wine_path: Path, d3dmetal_source: Path) -> dict[str, Any]:
    wine = wine_path.expanduser().resolve(strict=False)
    source = d3dmetal_source.expanduser().resolve(strict=False)
    if not wine.is_file() or not os.access(wine, os.X_OK):
        raise RuntimeError(f"GPTK Wine is not executable: {wine}")
    bundle = inspect_d3dmetal_bundle(source)
    try:
        result = subprocess.run([str(wine), "--version"], capture_output=True, text=True, timeout=10, check=False)
    except OSError as exc:
        raise RuntimeError(f"Could not run GPTK Wine at {wine}: {exc}") from exc
    version = (result.stdout or result.stderr).strip()
    if result.returncode != 0 or not version:
        raise RuntimeError(f"Could not identify GPTK Wine at {wine}.")
    if version not in SUPPORTED_D3DMETAL_WINE_VERSIONS:
        supported = ", ".join(SUPPORTED_D3DMETAL_WINE_VERSIONS)
        raise RuntimeError(f"D3DMetal requires a tested Wine engine ({supported}); found {version}.")
    root = _installation_root(wine, bundle.root) or bundle.root
    return {
        "installation_root": str(root),
        "wine_path": str(wine),
        "wine_version": version,
        "d3dmetal_source": str(bundle.root),
        "payload_path": str(bundle.windows_dir),
        "framework_path": str(bundle.framework_binary),
        "shared_library_path": str(bundle.shared_library),
    }


def discover_gptk_installations(
    *, configured_wine: Path | None = None, configured_source: Path | None = None
) -> list[dict[str, Any]]:
    pairs: list[tuple[Path, Path]] = []
    if configured_wine and configured_source:
        pairs.append((configured_wine, configured_source))
    for root in _candidate_roots():
        if not root.exists():
            continue
        if configured_wine:
            pairs.append((configured_wine, root))
        for wine in _wine_candidates(root):
            if wine.is_file():
                pairs.append((wine, root))
    home = Path.home()
    wrapper_roots = list((home / "Applications" / "Sikarugir").glob("*.app/Contents"))
    wrapper_roots += list((home / "Library/Application Support/Sikarugir/Wrapper").glob("*.app/Contents"))
    for contents in wrapper_roots:
        wine = contents / "SharedSupport" / "wine" / "bin" / "wine"
        renderer = contents / "Frameworks" / "renderer" / "d3dmetal"
        if wine.is_file() and renderer.is_dir():
            pairs.append((wine, renderer))
    found: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for wine, source in pairs:
        try:
            item = inspect_gptk_installation(wine, source)
        except (OSError, RuntimeError, FileNotFoundError):
            continue
        key = (item["wine_path"], item["d3dmetal_source"])
        if key not in seen:
            seen.add(key)
            found.append(item)
    return found


def import_managed_gptk(
    *, wine_path: Path, d3dmetal_source: Path, confirm_license: bool = False
) -> dict[str, Any]:
    if not confirm_license:
        raise RuntimeError("Importing Game Porting Toolkit requires explicit acceptance of Apple's license.")
    inspected = inspect_gptk_installation(wine_path, d3dmetal_source)
    source_wine = Path(inspected["wine_path"])
    source_wine_root = source_wine.parent.parent
    source_bundle = inspect_d3dmetal_bundle(Path(inspected["d3dmetal_source"]))
    wrapper_contents = _shared_wrapper_contents(source_wine, source_bundle.root)
    identity = hashlib.sha256(
        f"{source_wine_root}|{inspected['wine_version']}|{source_bundle.root}".encode("utf-8")
    ).hexdigest()[:12]
    destination = app_support_root() / "runtimes" / "gptk" / f"game-porting-toolkit-{identity}"
    if not destination.exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".tmp")
        if temporary.exists():
            shutil.rmtree(temporary)
        temporary.mkdir(parents=True)
        if wrapper_contents is not None:
            managed_contents = temporary / "Contents"
            (managed_contents / "SharedSupport").mkdir(parents=True)
            shutil.copytree(source_wine_root, managed_contents / "SharedSupport" / "wine", symlinks=True)
            shutil.copytree(wrapper_contents / "Frameworks", managed_contents / "Frameworks", symlinks=True)
        else:
            shutil.copytree(source_wine_root, temporary / "wine", symlinks=True)
            shutil.copytree(source_bundle.root, temporary / "d3dmetal", symlinks=True)
        temporary.replace(destination)
    if wrapper_contents is not None:
        managed_contents = destination / "Contents"
        managed_wine = managed_contents / "SharedSupport" / "wine" / "bin" / source_wine.name
        managed_bundle = managed_contents / source_bundle.root.relative_to(wrapper_contents)
    else:
        managed_wine = destination / "wine" / "bin" / source_wine.name
        managed_bundle = destination / "d3dmetal"
    managed = inspect_gptk_installation(managed_wine, managed_bundle)
    managed["managed"] = True
    managed["source_root"] = str(Path(inspected["installation_root"]))
    return managed
