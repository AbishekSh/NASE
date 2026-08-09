from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path

from .bottle import Bottle, ensure_bottle_dirs
from .dxmt import (
    DXMT_AVOID_VERSION_MARKERS,
    DXMT_DLL_OVERRIDES,
    DXMT_RECOMMENDED_VERSION_MARKERS,
    enable_dxmt_overrides,
    install_dxmt,
)
from .runtime import detect_wine_runtime, find_wine_module_root, resolve_executable, run_logged
from .steam import list_installed_apps, steam_prefix_root


@dataclass(frozen=True)
class CheckResult:
    status: str
    name: str
    detail: str


def _result(status: str, name: str, detail: str) -> CheckResult:
    return CheckResult(status=status, name=name, detail=detail)


def _check_file(path: Path) -> bool:
    return path.exists() and path.is_file()


def _detect_dxmt_file_version(path: Path) -> str | None:
    if not _check_file(path):
        return None
    try:
        data = path.read_bytes()
    except OSError:
        return None
    for marker in DXMT_RECOMMENDED_VERSION_MARKERS + DXMT_AVOID_VERSION_MARKERS:
        if marker.encode("ascii") in data:
            return marker
    return None


def _check_dxmt_version(label: str, path: Path) -> CheckResult:
    version = _detect_dxmt_file_version(path)
    if version in DXMT_RECOMMENDED_VERSION_MARKERS:
        return _result("ok", label, f"DXMT {version}: {path}")
    if version in DXMT_AVOID_VERSION_MARKERS:
        return _result("fail", label, f"DXMT {version} is not validated for this setup; use 0.70 or 0.71: {path}")
    return _result("warn", label, f"Could not detect DXMT version; use 0.70 or 0.71: {path}")


def _check_dxmt_runtime(module_root: Path) -> list[CheckResult]:
    checks: list[CheckResult] = []
    runtime_files = (
        ("DXMT runtime unix", module_root / "x86_64-unix" / "winemetal.so"),
        ("DXMT runtime x64 d3d10core", module_root / "x86_64-windows" / "d3d10core.dll"),
        ("DXMT runtime x64 d3d11", module_root / "x86_64-windows" / "d3d11.dll"),
        ("DXMT runtime x64 dxgi", module_root / "x86_64-windows" / "dxgi.dll"),
        ("DXMT runtime x64 winemetal", module_root / "x86_64-windows" / "winemetal.dll"),
        ("DXMT runtime x86 d3d10core", module_root / "i386-windows" / "d3d10core.dll"),
        ("DXMT runtime x86 d3d11", module_root / "i386-windows" / "d3d11.dll"),
        ("DXMT runtime x86 dxgi", module_root / "i386-windows" / "dxgi.dll"),
        ("DXMT runtime x86 winemetal", module_root / "i386-windows" / "winemetal.dll"),
    )
    for name, path in runtime_files:
        checks.append(_result("ok" if _check_file(path) else "fail", name, str(path)))
    checks.append(_check_dxmt_version("DXMT runtime version", module_root / "x86_64-windows" / "d3d11.dll"))
    return checks


def _check_dxmt_prefix(bottle: Bottle) -> list[CheckResult]:
    checks: list[CheckResult] = []
    prefix_files = (
        ("DXMT prefix x64 d3d10core", bottle.drive_c / "windows" / "system32" / "d3d10core.dll"),
        ("DXMT prefix x64 d3d11", bottle.drive_c / "windows" / "system32" / "d3d11.dll"),
        ("DXMT prefix x64 dxgi", bottle.drive_c / "windows" / "system32" / "dxgi.dll"),
        ("DXMT prefix x64 winemetal", bottle.drive_c / "windows" / "system32" / "winemetal.dll"),
        ("DXMT prefix x86 d3d10core", bottle.drive_c / "windows" / "syswow64" / "d3d10core.dll"),
        ("DXMT prefix x86 d3d11", bottle.drive_c / "windows" / "syswow64" / "d3d11.dll"),
        ("DXMT prefix x86 dxgi", bottle.drive_c / "windows" / "syswow64" / "dxgi.dll"),
        ("DXMT prefix x86 winemetal", bottle.drive_c / "windows" / "syswow64" / "winemetal.dll"),
    )
    for name, path in prefix_files:
        checks.append(_result("ok" if _check_file(path) else "fail", name, str(path)))
    checks.append(_check_dxmt_version("DXMT prefix version", bottle.drive_c / "windows" / "system32" / "d3d11.dll"))
    return checks


def _check_dxmt_overrides(bottle: Bottle) -> CheckResult:
    user_reg = bottle.prefix / "user.reg"
    if not user_reg.exists():
        return _result("fail", "DXMT overrides", f"Missing registry file: {user_reg}")

    content = user_reg.read_text(encoding="utf-8", errors="replace")
    missing = [
        name
        for name in DXMT_DLL_OVERRIDES
        if f'"{name}"="native"' not in content and f'"{name}"="native,builtin"' not in content
    ]
    if missing:
        return _result("fail", "DXMT overrides", f"Missing overrides: {', '.join(missing)}")
    return _result("ok", "DXMT overrides", "All DXMT DLL overrides present")


def _read_prefix_windows_version(bottle: Bottle) -> tuple[str | None, str | None, int | None]:
    system_reg = bottle.prefix / "system.reg"
    if not system_reg.exists():
        return None, None, None

    current_version = None
    product_name = None
    major_version = None
    in_nt_current = False
    in_wow_current = False

    for raw_line in system_reg.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw_line.strip()
        if line.startswith("["):
            in_nt_current = line.startswith(r"[Software\\Microsoft\\Windows NT\\CurrentVersion]")
            in_wow_current = line.startswith(r"[Software\\Wow6432Node\\Microsoft\\Windows NT\\CurrentVersion]")
            continue
        if not (in_nt_current or in_wow_current):
            continue
        if line.startswith('"CurrentVersion"=') and current_version is None:
            current_version = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith('"ProductName"=') and product_name is None:
            product_name = line.split("=", 1)[1].strip().strip('"')
        elif line.startswith('"CurrentMajorVersionNumber"=') and major_version is None:
            value = line.split("=", 1)[1].strip()
            if value.startswith("dword:"):
                try:
                    major_version = int(value.removeprefix("dword:"), 16)
                except ValueError:
                    major_version = None
        if current_version and product_name and major_version is not None:
            break

    return current_version, product_name, major_version


def _check_prefix_windows_version(bottle: Bottle) -> CheckResult:
    current_version, product_name, major_version = _read_prefix_windows_version(bottle)
    if not current_version and not product_name and major_version is None:
        return _result("warn", "Prefix Windows version", "Could not read Windows version from system.reg")

    parts = [part for part in (product_name, current_version) if part]
    if major_version is not None:
        parts.append(f"major {major_version}")
    detail = " / ".join(parts)
    if major_version is not None and major_version >= 10:
        return _result("ok", "Prefix Windows version", detail)
    if product_name and "windows 10" in product_name.lower():
        return _result("ok", "Prefix Windows version", detail)
    return _result("fail", "Prefix Windows version", f"{detail} (Steam expects Windows 10+)")


def set_prefix_windows_version(
    bottle: Bottle,
    wine_path: Path,
    version: str = "win10",
    extra_env: dict[str, str] | None = None,
) -> tuple[int, str]:
    environment = {"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"}
    if extra_env:
        environment.update(extra_env)
    return run_logged(
        cmd=[str(wine_path), "winecfg", "-v", version],
        env=environment,
        log_file=bottle.logs / "01_winecfg_winver.log",
        timeout=60,
    )


def _check_steam(bottle: Bottle) -> list[CheckResult]:
    checks: list[CheckResult] = []
    steam_root = steam_prefix_root(bottle)
    steam_exe = steam_root / "Steam.exe"
    steamapps = steam_root / "steamapps"

    checks.append(_result("ok" if steam_root.is_dir() else "fail", "Steam root", str(steam_root)))
    checks.append(_result("ok" if steam_exe.exists() else "fail", "Steam.exe", str(steam_exe)))
    checks.append(_result("ok" if steamapps.is_dir() else "fail", "steamapps", str(steamapps)))

    manifests = sorted(steamapps.glob("appmanifest_*.acf")) if steamapps.is_dir() else []
    if manifests:
        checks.append(_result("ok", "Steam manifests", f"{len(manifests)} manifest(s) found"))
    else:
        checks.append(_result("warn", "Steam manifests", "No appmanifest_*.acf files found"))

    try:
        apps = list_installed_apps(bottle)
    except Exception as exc:
        checks.append(_result("fail", "Installed games", f"Failed to read manifests: {exc}"))
    else:
        if apps:
            checks.append(_result("ok", "Installed games", f"{len(apps)} game(s) discovered"))
        else:
            checks.append(_result("warn", "Installed games", "No installed games discovered"))

    return checks


def _check_profile_transaction(bottle: Bottle) -> CheckResult | None:
    manifest_path = bottle.root / "compatibility-profile.json"
    if not manifest_path.exists():
        return None
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return _result("fail", "Compatibility profile transaction", f"Manifest is damaged: {exc}")
    status = str(manifest.get("setup_status") or "unknown")
    if status == "ready":
        return _result("ok", "Compatibility profile transaction", "Profile setup completed and verified")
    if status in {"setting-up", "needs-repair", "bound"}:
        detail = manifest.get("last_failure") or "Setup did not reach final verification"
        return _result("fail", "Compatibility profile transaction", f"{status}: {detail}. Use Repair in Runtime Center.")
    return _result("warn", "Compatibility profile transaction", f"Unknown setup state: {status}")


def run_doctor(*, bottle: Bottle, wine_value: str | None, winetricks_value: str) -> list[CheckResult]:
    checks: list[CheckResult] = []

    checks.append(_result("ok" if bottle.root.exists() else "warn", "Bottle root", str(bottle.root)))
    checks.append(_result("ok" if bottle.prefix.exists() else "fail", "Wine prefix", str(bottle.prefix)))
    profile_transaction = _check_profile_transaction(bottle)
    if profile_transaction is not None:
        checks.append(profile_transaction)

    wine_path = None
    if wine_value:
        try:
            wine_path = resolve_executable(wine_value, "wine")
        except Exception as exc:
            checks.append(_result("fail", "Wine runtime", str(exc)))
        else:
            runtime = detect_wine_runtime(wine_path)
            detail = runtime.get("version_output") or str(wine_path)
            status = "ok" if runtime.get("is_stable_11") else "warn"
            checks.append(_result(status, "Wine runtime", str(detail)))

            module_root = find_wine_module_root(wine_path)
            if module_root is None:
                checks.append(_result("fail", "Wine module root", f"Could not locate lib/wine for {wine_path}"))
            else:
                checks.append(_result("ok", "Wine module root", str(module_root)))
                checks.extend(_check_dxmt_runtime(module_root))
    else:
        checks.append(_result("warn", "Wine runtime", "No --wine/--wine64 provided; skipping runtime checks"))

    try:
        winetricks_path = resolve_executable(winetricks_value, "winetricks")
    except Exception as exc:
        checks.append(_result("fail", "winetricks", str(exc)))
    else:
        checks.append(_result("ok", "winetricks", str(winetricks_path)))

    checks.extend(_check_dxmt_prefix(bottle))
    checks.append(_check_dxmt_overrides(bottle))
    checks.append(_check_prefix_windows_version(bottle))
    checks.extend(_check_steam(bottle))

    return checks


def apply_doctor_fixes(
    *,
    bottle: Bottle,
    wine_value: str | None,
    dxmt_source: str | None,
    allow_unrecommended_dxmt: bool = False,
) -> list[str]:
    actions: list[str] = []

    ensure_bottle_dirs(bottle)
    actions.append(f"Ensured support directories under {bottle.root}")

    enable_dxmt_overrides(bottle)
    actions.append(f"Wrote DXMT DLL overrides into {bottle.prefix / 'user.reg'}")

    if wine_value:
        wine_path = resolve_executable(wine_value, "wine")
        code, tail = set_prefix_windows_version(bottle, wine_path, "win10")
        if code != 0:
            raise ValueError(f"Failed to set prefix Windows version to win10. Tail:\n{tail}")
        actions.append("Set the prefix Windows version to Windows 10")

    if dxmt_source:
        if not wine_value:
            raise ValueError("--fix with --dxmt-source also requires --wine/--wine64")
        wine_path = resolve_executable(wine_value, "wine")
        install_dxmt(
            bottle=bottle,
            dxmt_source=Path(dxmt_source),
            wine64_path=wine_path,
            allow_unrecommended=allow_unrecommended_dxmt,
        )
        actions.append("Reinstalled DXMT files into the Wine runtime and prefix")

    return actions
