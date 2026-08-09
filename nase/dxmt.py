from __future__ import annotations

import shutil
import tarfile
from pathlib import Path

from .bottle import Bottle, ensure_bottle_dirs
from .runtime import find_wine_module_root, run_logged


DXMT_DLL_OVERRIDES = {
    "dxgi": "native,builtin",
    "d3d11": "native,builtin",
    "d3d10core": "native,builtin",
    "winemetal": "native,builtin",
}
DXMT_RECOMMENDED_VERSION_MARKERS = ("0.70", "0.71")
DXMT_AVOID_VERSION_MARKERS = ("0.72", "0.73")
OLD_GRAPHICS_OVERRIDES = (
    "d3d8",
    "d3d9",
    "d3d10",
    "d3d10core",
    "d3d11",
    "d3d12",
    "dxgi",
    "dxvk_config",
    "nvapi",
    "nvapi64",
    "nvngx",
    "winemetal",
    "*d3d8",
    "*d3d9",
    "*d3d10",
    "*d3d10core",
    "*d3d11",
    "*d3d12",
    "*dxgi",
    "*dxvk_config",
    "*nvapi",
    "*nvapi64",
    "*nvngx",
    "*winemetal",
)


def _extract_archive(archive: Path, target_dir: Path) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as handle:
        members = handle.getmembers()
        top_levels = {member.name.split("/", 1)[0] for member in members if member.name}
        handle.extractall(target_dir)
    if len(top_levels) == 1:
        return target_dir / next(iter(top_levels))
    return target_dir


def resolve_dxmt_root(source: Path, cache_dir: Path) -> Path:
    candidate = source.expanduser().resolve()
    if candidate.is_dir():
        return candidate
    if candidate.is_file() and candidate.suffixes[-2:] == [".tar", ".gz"]:
        return _extract_archive(candidate, cache_dir / candidate.stem.replace(".tar", ""))
    raise FileNotFoundError(f"DXMT source must be a directory or .tar.gz archive: {candidate}")


def _detect_dxmt_version_from_payload(dxmt_root: Path) -> str | None:
    candidates = (
        dxmt_root / "x86_64-windows" / "d3d11.dll",
        dxmt_root / "x64" / "d3d11.dll",
    )
    for candidate in candidates:
        if not candidate.exists():
            continue
        try:
            data = candidate.read_bytes()
        except OSError:
            continue
        for marker in DXMT_RECOMMENDED_VERSION_MARKERS + DXMT_AVOID_VERSION_MARKERS:
            if marker.encode("ascii") in data:
                return marker
    return None


def detect_dxmt_version_hint(source: Path, dxmt_root: Path | None = None) -> str | None:
    names = [source.name.lower()]
    if dxmt_root is not None:
        names.append(dxmt_root.name.lower())
    for name in names:
        for marker in DXMT_RECOMMENDED_VERSION_MARKERS + DXMT_AVOID_VERSION_MARKERS:
            if marker in name:
                return marker
    if dxmt_root is not None:
        return _detect_dxmt_version_from_payload(dxmt_root)
    return None


def dxmt_version_warning(source: Path, dxmt_root: Path | None = None) -> str | None:
    version = detect_dxmt_version_hint(source, dxmt_root)
    if version in DXMT_AVOID_VERSION_MARKERS:
        return f"DXMT {version} is known to regress video/cutscene playback; use DXMT 0.70 or 0.71."
    if version is None:
        return "Could not infer DXMT version from the source path; DXMT 0.70 or 0.71 is recommended."
    if version not in DXMT_RECOMMENDED_VERSION_MARKERS:
        return f"DXMT {version} is not the validated version for this setup; DXMT 0.70 or 0.71 is recommended."
    return None


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
        existing: list[str] = []
        for line in lines[start + 1 : end]:
            if not (line.startswith('"') and '"="' in line and line.endswith('"')):
                existing.append(line)
        lines[start:end] = [header, *existing, *section_lines[1:]]

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

    lines[start:end] = [] if len(filtered) == 1 else filtered
    user_reg.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _locate_payload_dirs(dxmt_root: Path) -> tuple[Path, Path]:
    candidates = (
        (dxmt_root / "x64", dxmt_root / "x32"),
        (dxmt_root / "x86_64-windows", dxmt_root / "i386-windows"),
    )
    for x64_dir, x32_dir in candidates:
        if x64_dir.is_dir() and x32_dir.is_dir():
            return x64_dir, x32_dir
    raise FileNotFoundError(
        "DXMT directory must contain x32/ and x64/, or i386-windows/ and x86_64-windows/: "
        f"{dxmt_root}"
    )


def _locate_unix_payload_dir(dxmt_root: Path) -> Path | None:
    for candidate in (dxmt_root / "x86_64-unix", dxmt_root / "lib" / "wine" / "x86_64-unix"):
        if candidate.is_dir():
            return candidate
    return None


def _wineserver_path(wine_path: Path) -> Path:
    candidate = wine_path.with_name("wineserver")
    if candidate.exists():
        return candidate
    raise FileNotFoundError(f"wineserver not found next to Wine binary: {candidate}")


def enable_dxmt_overrides(bottle: Bottle) -> None:
    _remove_user_reg_entries(
        bottle.prefix / "user.reg",
        r"Software\\Wine\\DllOverrides",
        OLD_GRAPHICS_OVERRIDES,
    )
    _upsert_user_reg_section(
        bottle.prefix / "user.reg",
        r"Software\\Wine\\DllOverrides",
        DXMT_DLL_OVERRIDES,
    )


def install_dxmt(
    *,
    bottle: Bottle,
    dxmt_source: Path,
    wine64_path: Path | None = None,
    allow_unrecommended: bool = False,
) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    dxmt_root = resolve_dxmt_root(dxmt_source, bottle.cache / "dxmt")
    warning = dxmt_version_warning(dxmt_source, dxmt_root)
    version = detect_dxmt_version_hint(dxmt_source, dxmt_root)
    if version in DXMT_AVOID_VERSION_MARKERS and not allow_unrecommended:
        return 1, warning or f"DXMT {version} is not validated for this setup."
    x64_dir, x32_dir = _locate_payload_dirs(dxmt_root)
    unix_dir = _locate_unix_payload_dir(dxmt_root)

    system32 = bottle.drive_c / "windows" / "system32"
    syswow64 = bottle.drive_c / "windows" / "syswow64"
    system32.mkdir(parents=True, exist_ok=True)
    syswow64.mkdir(parents=True, exist_ok=True)

    copied: list[str] = []
    for source_dir, target_dir in ((x64_dir, system32), (x32_dir, syswow64)):
        for dll_name in ("dxgi.dll", "d3d10core.dll", "d3d11.dll", "winemetal.dll", "nvapi64.dll", "nvngx.dll"):
            source = source_dir / dll_name
            if source.exists():
                destination = target_dir / dll_name
                shutil.copy2(source, destination)
                copied.append(str(destination))

    module_root = None
    if wine64_path is None:
        wine_bin_path = shutil.which("wine")
        if wine_bin_path:
            module_root = find_wine_module_root(Path(wine_bin_path))
    else:
        module_root = find_wine_module_root(wine64_path)
    if module_root:
        builtin_d3d9_targets = (
            (module_root / "x86_64-windows" / "d3d9.dll", system32 / "d3d9.dll"),
            (module_root / "i386-windows" / "d3d9.dll", syswow64 / "d3d9.dll"),
        )
        for source, destination in builtin_d3d9_targets:
            if source.exists():
                shutil.copy2(source, destination)
                copied.append(str(destination))

        runtime_targets = (
            (x64_dir / "d3d10core.dll", module_root / "x86_64-windows" / "d3d10core.dll"),
            (x64_dir / "d3d11.dll", module_root / "x86_64-windows" / "d3d11.dll"),
            (x64_dir / "dxgi.dll", module_root / "x86_64-windows" / "dxgi.dll"),
            (x64_dir / "winemetal.dll", module_root / "x86_64-windows" / "winemetal.dll"),
        )
        if unix_dir:
            runtime_targets += ((unix_dir / "winemetal.so", module_root / "x86_64-unix" / "winemetal.so"),)
        for source, destination in runtime_targets:
            if source.exists() and destination.parent.is_dir():
                shutil.copy2(source, destination)
                copied.append(str(destination))

        i386_runtime = module_root / "i386-windows"
        if i386_runtime.is_dir():
            for source in sorted(x32_dir.glob("*")):
                if not source.is_file():
                    continue
                destination = i386_runtime / source.name
                shutil.copy2(source, destination)
                copied.append(str(destination))

    if not copied:
        raise FileNotFoundError(f"No DXMT DLLs found under: {dxmt_root}")

    enable_dxmt_overrides(bottle)
    tail_parts = ["\n".join(copied)]
    if warning:
        tail_parts.append(f"Warning: {warning}")
    if wine64_path is not None:
        wineserver = _wineserver_path(wine64_path)
        code, tail = run_logged(
            cmd=[str(wineserver), "-k"],
            env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
            log_file=bottle.logs / "dxmt_install.log",
            timeout=20,
        )
        if tail:
            tail_parts.append(tail)
        if code not in (0, 1, 124):
            return code, "\n".join(part for part in tail_parts if part)
        wait_code, wait_tail = run_logged(
            cmd=[str(wineserver), "-w"],
            env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
            log_file=bottle.logs / "dxmt_install.log",
            timeout=20,
        )
        if wait_tail:
            tail_parts.append(wait_tail)
        if wait_code not in (0, 1, 124):
            return wait_code, "\n".join(part for part in tail_parts if part)
    return 0, "\n".join(part for part in tail_parts if part)
