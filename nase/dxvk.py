from __future__ import annotations

import shutil
import tarfile
from pathlib import Path

from .bottle import Bottle, ensure_bottle_dirs
from .runtime import find_wine_module_root, run_logged


UPSTREAM_DXVK_DLL_OVERRIDES = ("d3d9", "d3d10core", "d3d11", "dxgi")
MACOS_DXVK_DLL_OVERRIDES = ("d3d10core", "d3d11")
BUILTIN_GRAPHICS_DLLS = ("d3d9", "d3d10core", "d3d11", "dxgi", "winemetal")
FOREIGN_RENDERER_OVERRIDES = ("d3d9", "d3d10core", "d3d11", "d3d12", "dxgi", "winemetal", "atidxx64", "nvapi64", "nvngx")


def _extract_archive(archive: Path, target_dir: Path) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as handle:
        members = handle.getmembers()
        top_levels = {member.name.split("/", 1)[0] for member in members if member.name}
        handle.extractall(target_dir)
    if len(top_levels) == 1:
        return target_dir / next(iter(top_levels))
    return target_dir


def resolve_dxvk_root(source: Path, cache_dir: Path) -> Path:
    candidate = source.expanduser().resolve()
    if candidate.is_dir():
        return candidate
    if candidate.is_file() and candidate.suffixes[-2:] == [".tar", ".gz"]:
        return _extract_archive(candidate, cache_dir / candidate.stem.replace(".tar", ""))
    raise FileNotFoundError(f"DXVK source must be a directory or .tar.gz archive: {candidate}")


def find_setup_script(dxvk_root: Path) -> Path:
    for candidate in (dxvk_root / "setup_dxvk.sh", dxvk_root / "setup-dxvk.sh"):
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"Could not find setup_dxvk.sh under: {dxvk_root}")


def _upsert_user_reg_section(user_reg: Path, section: str, entries: dict[str, str]) -> None:
    if user_reg.exists():
        lines = user_reg.read_text(encoding="utf-8", errors="replace").splitlines()
    else:
        user_reg.parent.mkdir(parents=True, exist_ok=True)
        lines = []
    header = f"[{section}]"
    start = None
    end = None

    for index, line in enumerate(lines):
        if line == header or line.startswith(header + " "):
            start = index
            end = len(lines)
            for cursor in range(index + 1, len(lines)):
                if lines[cursor].startswith("["):
                    end = cursor
                    break
            break

    section_header = lines[start] if start is not None else header
    section_lines = [section_header]
    for key, value in entries.items():
        section_lines.append(f'"{key}"="{value}"')

    if start is None:
        if lines and lines[-1] != "":
            lines.append("")
        lines.extend(section_lines)
    else:
        existing: dict[str, str] = {}
        preserved: list[str] = []
        for line in lines[start + 1 : end]:
            if line.startswith('"') and '"="' in line and line.endswith('"'):
                key = line.split('"', 2)[1]
                existing[key] = line
            else:
                preserved.append(line)

        merged = preserved + [f'"{key}"="{value}"' for key, value in entries.items()]
        lines[start:end] = [header, *merged]

    user_reg.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _remove_user_reg_entries(user_reg: Path, section: str, keys: tuple[str, ...]) -> None:
    if not user_reg.exists():
        return

    lines = user_reg.read_text(encoding="utf-8", errors="replace").splitlines()
    header = f"[{section}]"
    start = None
    end = None

    for index, line in enumerate(lines):
        if line == header or line.startswith(header + " "):
            start = index
            end = len(lines)
            for cursor in range(index + 1, len(lines)):
                if lines[cursor].startswith("["):
                    end = cursor
                    break
            break

    if start is None or end is None:
        return

    section_header = lines[start]
    filtered: list[str] = [section_header]
    for line in lines[start + 1 : end]:
        if line.startswith('"') and '"="' in line and line.endswith('"'):
            key = line.split('"', 2)[1]
            if key in keys:
                continue
        filtered.append(line)

    while len(filtered) > 1 and filtered[-1] == "":
        filtered.pop()

    if len(filtered) == 1:
        replacement: list[str] = []
    else:
        replacement = filtered

    lines[start:end] = replacement
    user_reg.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _select_overrides(dxvk_flavor: str, without_dxgi: bool) -> tuple[str, ...]:
    if dxvk_flavor == "macos":
        return MACOS_DXVK_DLL_OVERRIDES
    return tuple(name for name in UPSTREAM_DXVK_DLL_OVERRIDES if not (without_dxgi and name == "dxgi"))


def _enable_dxvk_overrides(bottle: Bottle, *, dxvk_flavor: str, without_dxgi: bool) -> None:
    if dxvk_flavor == "macos":
        _remove_user_reg_entries(
            bottle.prefix / "user.reg",
            r"Software\\Wine\\DllOverrides",
            FOREIGN_RENDERER_OVERRIDES,
        )
    overrides = {name: "native" for name in _select_overrides(dxvk_flavor, without_dxgi)}
    _upsert_user_reg_section(
        bottle.prefix / "user.reg",
        r"Software\\Wine\\DllOverrides",
        overrides,
    )


def _copy_dxvk_payload(*, dxvk_root: Path, bottle: Bottle, dxvk_flavor: str, without_dxgi: bool) -> tuple[int, str]:
    if (dxvk_root / "x64").is_dir() and (dxvk_root / "x32").is_dir():
        x64_dir = dxvk_root / "x64"
        x32_dir = dxvk_root / "x32"
    elif (dxvk_root / "x86_64-windows").is_dir() and (dxvk_root / "i386-windows").is_dir():
        x64_dir = dxvk_root / "x86_64-windows"
        x32_dir = dxvk_root / "i386-windows"
    else:
        x64_dir = dxvk_root / "x64"
        x32_dir = dxvk_root / "x32"
    if not x64_dir.is_dir() or not x32_dir.is_dir():
        raise FileNotFoundError(
            "DXVK directory must contain either setup_dxvk.sh, x32/ and x64/, "
            f"or i386-windows/ and x86_64-windows/: {dxvk_root}"
        )

    system32 = bottle.drive_c / "windows" / "system32"
    syswow64 = bottle.drive_c / "windows" / "syswow64"
    system32.mkdir(parents=True, exist_ok=True)
    syswow64.mkdir(parents=True, exist_ok=True)

    copied: list[str] = []
    for source_dir, target_dir in ((x64_dir, system32), (x32_dir, syswow64)):
        for dll in sorted(source_dir.glob("*.dll")):
            destination = target_dir / dll.name
            shutil.copy2(dll, destination)
            copied.append(str(destination))

    _enable_dxvk_overrides(bottle, dxvk_flavor=dxvk_flavor, without_dxgi=without_dxgi)
    return 0, "\n".join(copied)


def install_dxvk(
    *,
    bottle: Bottle,
    dxvk_source: Path,
    dxvk_flavor: str = "upstream",
    use_symlinks: bool = False,
    without_dxgi: bool = False,
) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    dxvk_root = resolve_dxvk_root(dxvk_source, bottle.cache / "dxvk")
    try:
        setup_script = find_setup_script(dxvk_root)
    except FileNotFoundError:
        if use_symlinks:
            raise
        return _copy_dxvk_payload(
            dxvk_root=dxvk_root,
            bottle=bottle,
            dxvk_flavor=dxvk_flavor,
            without_dxgi=without_dxgi,
        )

    command = ["/bin/bash", str(setup_script), "install"]
    if use_symlinks:
        command.append("--symlink")
    if without_dxgi:
        command.append("--without-dxgi")

    code, tail = run_logged(
        cmd=command,
        env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
        log_file=bottle.logs / "dxvk_install.log",
        cwd=dxvk_root,
    )
    if code == 0:
        _enable_dxvk_overrides(bottle, dxvk_flavor=dxvk_flavor, without_dxgi=without_dxgi)
    return code, tail


def restore_builtin_graphics_dlls(*, bottle: Bottle, wine64_path: Path) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    module_root = find_wine_module_root(wine64_path)
    if not module_root:
        raise FileNotFoundError(f"Could not locate Wine module root for: {wine64_path}")

    system32 = bottle.drive_c / "windows" / "system32"
    syswow64 = bottle.drive_c / "windows" / "syswow64"
    system32.mkdir(parents=True, exist_ok=True)
    syswow64.mkdir(parents=True, exist_ok=True)

    restored: list[str] = []
    for runtime_dir, target_dir in (
        (module_root / "x86_64-windows", system32),
        (module_root / "i386-windows", syswow64),
    ):
        if not runtime_dir.is_dir():
            continue
        for dll_name in BUILTIN_GRAPHICS_DLLS:
            source = runtime_dir / f"{dll_name}.dll"
            if source.exists():
                destination = target_dir / f"{dll_name}.dll"
                shutil.copy2(source, destination)
                restored.append(str(destination))

    _remove_user_reg_entries(
        bottle.prefix / "user.reg",
        r"Software\\Wine\\DllOverrides",
        BUILTIN_GRAPHICS_DLLS,
    )

    if not restored:
        return 0, "Removed graphics DLL overrides for builtin graphics stack."
    return 0, "\n".join(restored + ["Removed graphics DLL overrides for builtin graphics stack."])
