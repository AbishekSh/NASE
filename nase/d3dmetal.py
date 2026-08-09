from __future__ import annotations

import shutil
import tarfile
from dataclasses import dataclass
from pathlib import Path

from .bottle import Bottle, ensure_bottle_dirs
from .runtime import find_wine_module_root, run_logged


D3DMETAL_DLL_OVERRIDES = {
    "dxgi": "native,builtin",
    "d3d11": "native,builtin",
    "d3d12": "native,builtin",
    "atidxx64": "native,builtin",
    "nvapi64": "native,builtin",
    "nvngx": "native,builtin",
}
OLD_GRAPHICS_OVERRIDES = (
    "d3d9",
    "d3d10core",
    "d3d11",
    "d3d12",
    "dxgi",
    "winemetal",
    "d3dmetal",
    "atidxx64",
    "nvapi64",
    "nvngx",
    "*d3d9",
    "*d3d10core",
    "*d3d11",
    "*d3d12",
    "*dxgi",
    "*winemetal",
    "*d3dmetal",
    "*atidxx64",
    "*nvapi64",
    "*nvngx",
)
D3DMETAL_DLL_NAMES = (
    "atidxx64.dll",
    "dxgi.dll",
    "d3d11.dll",
    "d3d12.dll",
    "nvapi64.dll",
    "nvngx.dll",
)


@dataclass(frozen=True)
class D3DMetalBundle:
    root: Path
    wine_root: Path
    windows_dir: Path
    unix_dir: Path
    external_dir: Path
    framework_binary: Path
    shared_library: Path


def inspect_d3dmetal_bundle(source: Path) -> D3DMetalBundle:
    root = source.expanduser().resolve(strict=False)
    if not root.is_dir():
        raise FileNotFoundError(f"D3DMetal bundle directory was not found: {root}")
    windows_dir = _locate_payload_dir(root)
    wine_root = windows_dir.parent
    unix_dir = wine_root / "x86_64-unix"
    external_dir = _locate_external_payload_dir(root)
    if not unix_dir.is_dir():
        raise FileNotFoundError(f"D3DMetal Unix Wine modules were not found under: {root}")
    if external_dir is None:
        raise FileNotFoundError(f"D3DMetal external runtime directory was not found under: {root}")
    framework = external_dir / "D3DMetal.framework"
    framework_binary = framework / "Versions" / "A" / "D3DMetal"
    if not framework_binary.is_file():
        framework_binary = framework / "D3DMetal"
    shared_library = external_dir / "libd3dshared.dylib"
    if not framework_binary.is_file():
        raise FileNotFoundError(f"D3DMetal.framework binary was not found under: {external_dir}")
    if not shared_library.is_file():
        raise FileNotFoundError(f"libd3dshared.dylib was not found under: {external_dir}")
    return D3DMetalBundle(
        root=root,
        wine_root=wine_root,
        windows_dir=windows_dir,
        unix_dir=unix_dir,
        external_dir=external_dir,
        framework_binary=framework_binary,
        shared_library=shared_library,
    )


def d3dmetal_launch_environment(source: Path) -> dict[str, str]:
    bundle = inspect_d3dmetal_bundle(source)
    native_library_dirs = [bundle.external_dir]
    for candidate in (bundle.root, *bundle.root.parents):
        if candidate.name == "Frameworks":
            native_library_dirs.append(candidate)
            break
    return {
        "WINEESYNC": "1",
        "WINEMSYNC": "1",
        "WINEDLLPATH_PREPEND": str(bundle.wine_root),
        "CX_D3DMETALPATH": str(bundle.root),
        "CX_APPLEGPT_LIBD3DSHARED_PATH": str(bundle.shared_library),
        "CX_APPLEGPTK_LIBD3DSHARED_PATH": str(bundle.shared_library),
        "DYLD_FALLBACK_LIBRARY_PATH": ":".join(str(path) for path in native_library_dirs),
    }


def _extract_archive(archive: Path, target_dir: Path) -> Path:
    target_dir.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as handle:
        members = handle.getmembers()
        top_levels = {member.name.split("/", 1)[0] for member in members if member.name}
        handle.extractall(target_dir)
    if len(top_levels) == 1:
        return target_dir / next(iter(top_levels))
    return target_dir


def resolve_d3dmetal_root(source: Path, cache_dir: Path) -> Path:
    candidate = source.expanduser().resolve()
    if candidate.is_dir():
        return candidate
    if candidate.is_file() and candidate.suffixes[-2:] == [".tar", ".gz"]:
        return _extract_archive(candidate, cache_dir / candidate.stem.replace(".tar", ""))
    raise FileNotFoundError(f"D3DMetal source must be a directory or .tar.gz archive: {candidate}")


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


def _locate_payload_dir(root: Path) -> Path:
    direct_candidates = (
        root / "wine" / "x86_64-windows",
        root / "x86_64-windows",
        root / "x64",
        root / "redist" / "lib" / "wine" / "x86_64-windows",
        root / "redist" / "lib64" / "wine" / "x86_64-windows",
        root / "lib64" / "wine" / "x86_64-windows",
        root / "lib" / "wine" / "x86_64-windows",
    )
    for candidate in direct_candidates:
        if (candidate / "d3d11.dll").is_file() and (candidate / "dxgi.dll").is_file():
            return candidate

    matches = sorted(root.rglob("d3d11.dll"))
    if matches:
        for match in matches:
            if (match.parent / "dxgi.dll").is_file():
                return match.parent
    raise FileNotFoundError(f"Could not find D3DMetal d3d11.dll/dxgi.dll payload under: {root}")


def locate_d3dmetal_payload(source: Path) -> Path:
    """Return the matching 64-bit D3DMetal payload without modifying a bottle."""
    root = source.expanduser().resolve(strict=False)
    if not root.is_dir():
        raise FileNotFoundError(f"D3DMetal source directory was not found: {root}")
    return _locate_payload_dir(root)


def _locate_optional_32bit_dir(root: Path) -> Path | None:
    for candidate in (root / "i386-windows", root / "x32", root / "lib" / "wine" / "i386-windows"):
        if candidate.is_dir() and any(candidate.glob("*.dll")):
            return candidate
    return None


def _locate_unix_payload_dir(root: Path) -> Path | None:
    for candidate in (
        root / "wine" / "x86_64-unix",
        root / "x86_64-unix",
        root / "redist" / "lib" / "wine" / "x86_64-unix",
        root / "lib64" / "wine" / "x86_64-unix",
        root / "lib" / "wine" / "x86_64-unix",
    ):
        if candidate.is_dir() and any(candidate.glob("*.so")):
            return candidate
    return None


def _locate_external_payload_dir(root: Path) -> Path | None:
    for candidate in (
        root / "external",
        root / "redist" / "lib" / "external",
        root / "lib64" / "external",
        root / "lib" / "external",
    ):
        if candidate.is_dir():
            return candidate
    return None


def _wineserver_path(wine_path: Path) -> Path:
    candidate = wine_path.with_name("wineserver")
    if candidate.exists():
        return candidate
    raise FileNotFoundError(f"wineserver not found next to Wine binary: {candidate}")


def clear_graphics_overrides(bottle: Bottle) -> None:
    _remove_user_reg_entries(
        bottle.prefix / "user.reg",
        r"Software\\Wine\\DllOverrides",
        OLD_GRAPHICS_OVERRIDES,
    )


def enable_d3dmetal_overrides(bottle: Bottle) -> None:
    clear_graphics_overrides(bottle)
    _upsert_user_reg_section(
        bottle.prefix / "user.reg",
        r"Software\\Wine\\DllOverrides",
        D3DMETAL_DLL_OVERRIDES,
    )


def install_d3dmetal(*, bottle: Bottle, d3dmetal_source: Path, wine64_path: Path | None = None) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    d3dmetal_root = resolve_d3dmetal_root(d3dmetal_source, bottle.cache / "d3dmetal")
    bundle = inspect_d3dmetal_bundle(d3dmetal_root)

    enable_d3dmetal_overrides(bottle)
    tail_parts = [f"Using preserved D3DMetal bundle at {bundle.root}"]
    if wine64_path is not None:
        wineserver = _wineserver_path(wine64_path)
        environment = {"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"}
        environment.update(d3dmetal_launch_environment(d3dmetal_root))
        code, tail = run_logged(
            cmd=[str(wineserver), "-k"],
            env=environment,
            log_file=bottle.logs / "d3dmetal_install.log",
            timeout=20,
        )
        if tail:
            tail_parts.append(tail)
        if code not in (0, 1, 124):
            return code, "\n".join(part for part in tail_parts if part)
    return 0, "\n".join(part for part in tail_parts if part)


def verify_d3dmetal_profile(bottle: Bottle, source: Path) -> list[dict[str, str]]:
    try:
        bundle = inspect_d3dmetal_bundle(source)
    except (OSError, FileNotFoundError) as exc:
        return [{"name": "D3DMetal bundle", "status": "fail", "detail": str(exc)}]
    required_dlls = ("dxgi.dll", "d3d11.dll", "d3d12.dll")
    missing = [name for name in required_dlls if not (bundle.windows_dir / name).is_file()]
    checks = [{
        "name": "D3DMetal DLLs",
        "status": "ok" if not missing else "fail",
        "detail": "Required D3DMetal DLLs are present in the preserved bundle." if not missing else f"Missing: {', '.join(missing)}",
    }]
    checks.append({"name": "D3DMetal.framework", "status": "ok", "detail": str(bundle.framework_binary)})
    checks.append({"name": "libd3dshared", "status": "ok", "detail": str(bundle.shared_library)})
    user_reg = bottle.prefix / "user.reg"
    registry = user_reg.read_text(encoding="utf-8", errors="replace") if user_reg.exists() else ""
    missing_overrides = [name for name in ("dxgi", "d3d11", "d3d12") if f'"{name}"="native,builtin"' not in registry]
    checks.append({
        "name": "D3DMetal overrides",
        "status": "ok" if not missing_overrides else "fail",
        "detail": "D3DMetal DLL overrides are enabled." if not missing_overrides else f"Missing overrides: {', '.join(missing_overrides)}",
    })
    conflicting = [name for name in ("winemetal", "d3d10core", "d3d9") if f'"{name}"=' in registry or f'"*{name}"=' in registry]
    checks.append({
        "name": "Renderer exclusivity",
        "status": "ok" if not conflicting else "fail",
        "detail": "DXMT and DXVK overrides are disabled." if not conflicting else f"Conflicting renderer overrides: {', '.join(conflicting)}",
    })
    steam = bottle.drive_c / "Program Files (x86)" / "Steam" / "Steam.exe"
    checks.append({
        "name": "Steam",
        "status": "ok" if steam.is_file() else "fail",
        "detail": "Steam is installed in the dedicated profile." if steam.is_file() else "Steam.exe is missing from the dedicated profile.",
    })
    return checks
