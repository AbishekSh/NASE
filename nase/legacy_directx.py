from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import zipfile

from .bottle import Bottle
from .pe import PE_MACHINE_I386, pe_machine


WRAPPER_DLLS = ("DDraw.dll", "D3DImm.dll")


def _find_case_insensitive(root: Path, relative_suffix: str) -> Path | None:
    suffix = relative_suffix.lower().replace("\\", "/")
    return next(
        (path for path in root.rglob("*") if path.is_file() and path.relative_to(root).as_posix().lower().endswith(suffix)),
        None,
    )


def inspect_dgvoodoo_source(source: Path) -> dict[str, str]:
    candidate = source.expanduser().resolve()
    temporary: tempfile.TemporaryDirectory[str] | None = None
    try:
        if candidate.is_file() and candidate.suffix.lower() == ".zip":
            temporary = tempfile.TemporaryDirectory(prefix="nase-dgvoodoo-inspect-")
            with zipfile.ZipFile(candidate) as archive:
                archive.extractall(temporary.name)
            root = Path(temporary.name)
        elif candidate.is_dir():
            root = candidate
        else:
            raise FileNotFoundError(f"Legacy DirectX source must be a dgVoodoo2 ZIP or directory: {candidate}")

        found: dict[str, str] = {}
        for name in WRAPPER_DLLS:
            path = _find_case_insensitive(root, f"MS/x86/{name}")
            if path is None:
                raise FileNotFoundError(f"dgVoodoo2 32-bit {name} was not found under MS/x86 in {candidate}.")
            if pe_machine(path) != PE_MACHINE_I386:
                raise RuntimeError(f"dgVoodoo2 {name} is not a 32-bit x86 DLL: {path}")
            found[name] = str(path)
        config = _find_case_insensitive(root, "dgVoodoo.conf")
        if config:
            found["dgVoodoo.conf"] = str(config)
        return found
    finally:
        if temporary is not None:
            temporary.cleanup()


def _extract_source(source: Path, destination: Path) -> dict[str, Path]:
    candidate = source.expanduser().resolve()
    if candidate.is_file() and candidate.suffix.lower() == ".zip":
        with zipfile.ZipFile(candidate) as archive:
            archive.extractall(destination)
        root = destination
    else:
        root = candidate
    inspected = inspect_dgvoodoo_source(root)
    return {name: Path(path) for name, path in inspected.items()}


def prepare_legacy_directx_overlay(
    *, bottle: Bottle, game_id: str, game_dir: Path, executable: Path, source: Path
) -> dict[str, str]:
    game_root = game_dir.expanduser().resolve()
    exe = executable.expanduser().resolve()
    if pe_machine(exe) != PE_MACHINE_I386:
        raise RuntimeError("Legacy DirectX acceleration currently supports 32-bit x86 games only.")
    if game_root not in (exe.parent, *exe.parents):
        raise RuntimeError(f"Executable is outside its game directory: {exe}")

    safe_id = "".join(character if character.isalnum() or character in "-_" else "_" for character in game_id)
    overlay = bottle.root / "overlays" / safe_id / "game"
    overlay.mkdir(parents=True, exist_ok=True)
    wrapper_names = {name.lower() for name in (*WRAPPER_DLLS, "dgVoodoo.conf")}
    for item in game_root.iterdir():
        if item.name.lower() in wrapper_names:
            continue
        destination = overlay / item.name
        if destination.exists() or destination.is_symlink():
            continue
        destination.symlink_to(item, target_is_directory=item.is_dir())

    with tempfile.TemporaryDirectory(prefix="nase-dgvoodoo-install-") as temporary:
        files = _extract_source(source, Path(temporary))
        checksums: dict[str, str] = {}
        for name, path in files.items():
            destination = overlay / name
            shutil.copy2(path, destination)
            checksums[name] = hashlib.sha256(destination.read_bytes()).hexdigest()

    relative_executable = exe.relative_to(game_root)
    overlay_executable = overlay / relative_executable
    manifest = {
        "schema_version": 1,
        "kind": "legacy-directx-dgvoodoo2",
        "game_id": game_id,
        "game_root": str(game_root),
        "original_executable": str(exe),
        "overlay_executable": str(overlay_executable),
        "source": str(source.expanduser().resolve()),
        "checksums": checksums,
    }
    manifest_path = overlay.parent / "overlay.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return {**manifest, "overlay_root": str(overlay), "manifest_path": str(manifest_path)}


def reset_legacy_directx_overlay(*, bottle: Bottle, game_id: str) -> bool:
    safe_id = "".join(character if character.isalnum() or character in "-_" else "_" for character in game_id)
    root = bottle.root / "overlays" / safe_id
    if not root.exists():
        return False
    shutil.rmtree(root)
    return True
