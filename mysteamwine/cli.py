from __future__ import annotations

import argparse
import hashlib
import json
import os
import signal
import shutil
import subprocess
import sys
import textwrap
import time
import uuid
import zipfile
from pathlib import Path

from . import APP_NAME, DEFAULT_BOTTLE_NAME
from .advisor import recommend_dependencies
from .bottle import app_support_root, bottle_paths, ensure_bottle_dirs, external_prefix_paths, wipe_all_bottles
from .catalog import (
    installed_runtime_executable,
    install_runtime,
    list_installed_runtimes,
    list_runtime_catalog,
    managed_gstreamer_environment,
)
from .d3dmetal import d3dmetal_launch_environment, install_d3dmetal, verify_d3dmetal_profile
from .dependencies import dependency_install_command, dependency_status
from .doctor import apply_doctor_fixes, run_doctor, set_prefix_windows_version
from .dxmt import install_dxmt
from .dxvk import install_dxvk
from .dxvk_macos import (
    discover_moltenvk_source,
    install_dxvk_macos_native_runtime,
    probe_dxvk_macos_graphics,
    verify_dxvk_macos_profile,
)
from .gptk import discover_gptk_installations, import_managed_gptk, prepare_sikarugir_native_dependencies
from .library_activity import acquire_steam_activity, assert_direct_launch_safe, release_steam_activity
from .legacy_directx import prepare_legacy_directx_overlay, reset_legacy_directx_overlay
from .jobs import cancel_job, create_job, list_jobs, update_job
from .profiles import PROFILES, bind_profile, list_profiles, mark_profile_ready, migrate_imported_d3dmetal_profiles
from .runtime import detect_wine_runtime, is_apple_silicon, resolve_executable, resolve_with_fallback, run_logged
from .scanner import scan_game_dir
from .sessions import create_session, mark_steam_opened_by_user, reconcile_sessions, steam_is_running, stop_session, update_session
from .steam import (
    graphics_launch_environment,
    guess_game_executable,
    install_steam,
    kill_nase_wine_processes,
    kill_wine_processes,
    launch_app,
    probe_steam_stability,
    run_game_executable,
    steam_client_is_ready,
    steam_prefix_root,
    validate_executable_compatibility,
    run_steam,
    steam_windows_path,
)
from .steam_libraries import attach_registered_libraries, installed_games, refresh_registry, resolve_registered_app
from .steam_identity import (
    capture_steam_identity,
    forget_steam_identity,
    provision_steam_identity,
    sign_out_steam_profile,
    steam_identity_status,
)
from .sources import EpicSource, GOGSource
from .winetricks import run_winetricks


def _resolve_winetricks(path_or_name: str = "winetricks") -> Path:
    if path_or_name == "winetricks":
        managed = installed_runtime_executable("winetricks-20260125")
        if managed is not None:
            return managed
    return resolve_executable(path_or_name, "winetricks")


_TRANSIENT_JOB_ACTIONS = {
    "cancel-job",
    "dependency-status",
    "list-compatibility-profiles",
    "list-games",
    "list-installed-runtimes",
    "list-jobs",
    "list-runtime-catalog",
    "list-sessions",
    "steam-identity-status",
    "source-status",
    "list-source-games",
}
_TRANSIENT_JOB_IDS: set[str] = set()
_JOB_TARGET: dict[str, str] = {}


def _json_enabled(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "json", False))


def _stream_enabled(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "jsonl", False))


def _emit_json(
    *,
    action: str,
    ok: bool,
    message: str,
    data: dict | None = None,
    warnings: list[str] | None = None,
    errors: list[str] | None = None,
    status: str | None = None,
    job_id: str | None = None,
) -> None:
    print(
        json.dumps(
            {
                "ok": ok,
                "action": action,
                "status": status or ("completed" if ok else "failed"),
                "job_id": job_id or uuid.uuid4().hex,
                "message": message,
                "data": data or {},
                "warnings": warnings or [],
                "errors": errors or [],
            }
        )
    )


def _emit_stream_event(
    *,
    event: str,
    action: str,
    job_id: str,
    status: str,
    message: str,
    data: dict | None = None,
    warnings: list[str] | None = None,
    errors: list[str] | None = None,
    ok: bool | None = None,
) -> None:
    if job_id not in _TRANSIENT_JOB_IDS:
        step = (data or {}).get("step") if event == "step" else None
        update_job(
            job_id,
            status=status,
            message=message,
            step=step,
            progress=(data or {}).get("progress"),
            completed_steps=(data or {}).get("completed_steps"),
            total_steps=(data or {}).get("total_steps"),
            warnings=warnings,
            errors=errors,
            rollback=(data or {}).get("rollback"),
        )
    print(
        json.dumps(
            {
                "event": event,
                "job_id": job_id,
                "action": action,
                "status": status,
                "message": message,
                "ok": ok,
                "data": data or {},
                "warnings": warnings or [],
                "errors": errors or [],
            }
        ),
        flush=True,
    )


def _stream_start(*, action: str, message: str) -> str:
    job_id = uuid.uuid4().hex
    if action in _TRANSIENT_JOB_ACTIONS:
        _TRANSIENT_JOB_IDS.add(job_id)
    else:
        create_job(job_id=job_id, action=action, message=message, target=_JOB_TARGET)
    _emit_stream_event(
        event="job",
        action=action,
        job_id=job_id,
        status="started",
        message=message,
    )
    return job_id


def _stream_step(*, action: str, job_id: str, name: str, status: str, message: str) -> None:
    _emit_stream_event(
        event="step",
        action=action,
        job_id=job_id,
        status=status,
        message=message,
        data={"step": {"name": name, "status": status}},
    )


def _stream_progress(
    *,
    action: str,
    job_id: str,
    name: str,
    status: str,
    message: str,
    completed_steps: int,
    total_steps: int,
) -> None:
    progress = completed_steps / total_steps if total_steps else None
    _emit_stream_event(
        event="step",
        action=action,
        job_id=job_id,
        status=status,
        message=message,
        data={
            "step": {"name": name, "status": status},
            "completed_steps": completed_steps,
            "total_steps": total_steps,
            "progress": progress,
        },
    )


def _stream_result(
    *,
    action: str,
    job_id: str,
    ok: bool,
    status: str,
    message: str,
    data: dict | None = None,
    warnings: list[str] | None = None,
    errors: list[str] | None = None,
) -> None:
    _emit_stream_event(
        event="result",
        action=action,
        job_id=job_id,
        status=status,
        message=message,
        ok=ok,
        data=data,
        warnings=warnings,
        errors=errors,
    )


def _json_error(args: argparse.Namespace, *, action: str, message: str, code: int = 1, data: dict | None = None) -> None:
    if _stream_enabled(args):
        job_id = _stream_start(action=action, message=message)
        _stream_result(
            action=action,
            job_id=job_id,
            ok=False,
            status="failed",
            message=message,
            data=data,
            errors=[message],
        )
        raise SystemExit(code)
    if _json_enabled(args):
        _emit_json(action=action, ok=False, message=message, data=data, errors=[message], status="failed")
        raise SystemExit(code)
    raise SystemExit(message if code == 1 else code)


def _require_wine64(args: argparse.Namespace) -> Path:
    wine_arg = args.wine64 or args.wine
    if not wine_arg:
        raise SystemExit("--wine64 is required for this command")
    return resolve_with_fallback(wine_arg, "wine64", ("wine",))


def _resolve_bottle(args: argparse.Namespace):
    if getattr(args, "prefix", None):
        return external_prefix_paths(Path(args.prefix))
    return bottle_paths(args.bottle)


def _is_external_prefix(args: argparse.Namespace) -> bool:
    return bool(getattr(args, "prefix", None))


def _target_label(args: argparse.Namespace, bottle) -> str:
    if _is_external_prefix(args):
        return f"external prefix '{bottle.prefix}'"
    return f"managed bottle '{bottle.name}'"


def _resolved_graphics_backend(args: argparse.Namespace, *, for_steam: bool) -> str:
    if args.graphics_backend == "auto":
        return "none" if for_steam else "dxmt"
    return args.graphics_backend


def _acquire_library_or_error(args: argparse.Namespace, *, action: str, **activity) -> dict:
    try:
        return acquire_steam_activity(**activity)
    except RuntimeError as exc:
        message = (
            f"{exc} Close Steam from NASE's current bottle, or use Kill Wine for that bottle if Steam will not exit, "
            "then try again. NASE keeps shared game files locked to one Windows Steam instance during updates."
        )
        _json_error(args, action=action, message=message)


def _bind_launch_profile(args: argparse.Namespace, *, action: str, bottle, wine_path: Path, graphics_backend: str) -> str:
    defaults = {
        "dxmt": "dxmt-wine-stable-11-v1",
        "d3dmetal": "d3dmetal-gptk-v1",
        "dxvk": "dxvk-macos-pinned-v1",
        "none": "plain-wine-v1",
    }
    profile_id = getattr(args, "compatibility_profile", None) or defaults[graphics_backend]
    source_value = {
        "dxmt": getattr(args, "dxmt_source", None),
        "d3dmetal": getattr(args, "d3dmetal_source", None),
        "dxvk": getattr(args, "dxvk_source", None),
        "none": None,
    }[graphics_backend]
    try:
        if graphics_backend == "d3dmetal":
            free_bytes = shutil.disk_usage(bottle.root.parent).free
            if free_bytes < 2 * 1024**3:
                free_mib = free_bytes // (1024 * 1024)
                raise RuntimeError(
                    f"D3DMetal setup needs at least 2 GiB of free disk space for Wine, Steam updates, and temporary files; "
                    f"only {free_mib} MiB is available. Free some space, then retry Set Up."
                )
        active_manifest = bind_profile(
            bottle=bottle,
            profile_id=profile_id,
            graphics_backend=graphics_backend,
            wine_path=wine_path,
            graphics_source=Path(source_value) if source_value else None,
            moltenvk_source=discover_moltenvk_source() if graphics_backend == "dxvk" else None,
        )
    except (RuntimeError, OSError) as exc:
        _json_error(args, action=action, message=f"Compatibility profile is not ready: {exc}")
    return profile_id


def cmd_info(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    print(f"TARGET:           {_target_label(args, bottle)}")
    print(f"APP SUPPORT ROOT: {app_support_root()}")
    print(f"BOTTLE ROOT:      {bottle.root}")
    print(f"PREFIX:           {bottle.prefix}")
    print(f"LOGS:             {bottle.logs}")
    print(f"DOWNLOADS:        {bottle.downloads}")
    print(f"CACHE:            {bottle.cache}")
    print(f"Apple Silicon:    {is_apple_silicon()}")


def cmd_list_compatibility_profiles(args: argparse.Namespace) -> None:
    profiles = list_profiles()
    if _stream_enabled(args):
        job_id = _stream_start(action="list-compatibility-profiles", message="Loading compatibility profiles...")
        _stream_result(
            action="list-compatibility-profiles",
            job_id=job_id,
            ok=True,
            status="completed",
            message=f"Found {len(profiles)} compatibility profiles.",
            data={"profiles": profiles},
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="list-compatibility-profiles",
            ok=True,
            message="Compatibility profiles listed.",
            data={"profiles": profiles},
        )
        return
    for profile in profiles:
        state = "ready" if profile["ready"] else "unavailable"
        print(f"{profile['id']}\t{state}\t{profile['name']}")


def cmd_discover_d3dmetal(args: argparse.Namespace) -> None:
    action = "discover-d3dmetal"
    installations = discover_gptk_installations(
        configured_wine=Path(args.gptk_wine) if args.gptk_wine else None,
        configured_source=Path(args.d3dmetal_source) if args.d3dmetal_source else None,
    )
    selected = installations[0] if installations else None
    message = "Found a matched Game Porting Toolkit installation." if selected else "No complete Game Porting Toolkit installation was found."
    data = {
        "installations": installations,
        "gptk_wine_path": selected["wine_path"] if selected else None,
        "d3dmetal_source": selected["d3dmetal_source"] if selected else None,
    }
    if _json_enabled(args) or _stream_enabled(args):
        _emit_json(action=action, ok=bool(selected), message=message, data=data, warnings=[] if selected else ["Install Apple's Game Porting Toolkit, then choose its folder in Advanced Settings."])
        if not selected:
            raise SystemExit(1)
        return
    print(message)
    if selected:
        print(f"Wine: {selected['wine_path']}")
        print(f"D3DMetal: {selected['d3dmetal_source']}")


def cmd_import_gptk(args: argparse.Namespace) -> None:
    action = "import-gptk"
    try:
        installed = import_managed_gptk(
            wine_path=Path(args.gptk_wine),
            d3dmetal_source=Path(args.d3dmetal_source),
            confirm_license=args.confirm_license,
        )
    except Exception as exc:
        _json_error(args, action=action, message=str(exc), code=1)
        return
    migrated_profiles = migrate_imported_d3dmetal_profiles(
        old_source=Path(args.d3dmetal_source),
        new_source=Path(installed["d3dmetal_source"]),
        bottles_root=app_support_root() / "bottles",
    )
    data = {
        "gptk_wine_path": installed["wine_path"],
        "d3dmetal_source": installed["d3dmetal_source"],
        "installation": installed,
        "migrated_profiles": migrated_profiles,
    }
    message = f"Installed a managed Game Porting Toolkit runtime at {installed['installation_root']}."
    if _json_enabled(args) or _stream_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def cmd_dependency_status(args: argparse.Namespace) -> None:
    action = "dependency-status"
    wine = Path(args.wine or args.wine64 or "/opt/homebrew/bin/wine")
    result = dependency_status(
        wine_path=wine,
        winetricks_path=args.winetricks,
        gptk_wine_path=Path(args.gptk_wine) if args.gptk_wine else None,
        d3dmetal_source=Path(args.d3dmetal_source) if args.d3dmetal_source else None,
    )
    missing = result["missing_required"]
    message = "Dependencies are ready." if not missing else f"Missing required dependencies: {', '.join(missing)}."
    if _stream_enabled(args):
        job_id = _stream_start(action=action, message="Checking host dependencies...")
        _stream_result(action=action, job_id=job_id, ok=not missing, status="completed" if not missing else "failed", message=message, data=result)
        return
    if _json_enabled(args):
        _emit_json(action=action, ok=not missing, message=message, data=result, status="completed" if not missing else "failed")
        return
    for check in result["checks"]:
        print(f"[{check['status'].upper():4}] {check['name']}: {check['detail']}")


def cmd_install_host_dependency(args: argparse.Namespace) -> None:
    action = "install-host-dependency"
    managed_runtime_ids = {
        "gstreamer": "gstreamer-1.28.2-macos-universal",
        "wine-stable": "wine-stable-11.0_1-gcenx",
        "winetricks": "winetricks-20260125",
    }
    if args.dependency in managed_runtime_ids:
        runtime_id = managed_runtime_ids[args.dependency]
        job_id = _stream_start(action=action, message=f"Installing managed {args.dependency}...") if _stream_enabled(args) else None

        def callback(name: str, status: str, message: str) -> None:
            if _stream_enabled(args):
                _stream_step(
                    action=action,
                    job_id=job_id or uuid.uuid4().hex,
                    name=name,
                    status=status,
                    message=message,
                )

        try:
            installed, notes = install_runtime(
                runtime_id=runtime_id,
                install_into_bottle=False,
                callback=callback,
            )
        except Exception as exc:
            message = f"Could not install managed {args.dependency}: {exc}"
            if _stream_enabled(args):
                _stream_result(
                    action=action,
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=message,
                    errors=[message],
                )
                raise SystemExit(1)
            _json_error(args, action=action, message=message, code=1)
            return
        runtime = {
            "id": installed.id,
            "name": installed.name,
            "version": installed.version,
            "kind": installed.kind,
            "path": installed.path,
            "executable": installed.executable,
            "installed_at": installed.installed_at,
            "installed": True,
        }
        message = f"Installed managed {installed.name} {installed.version}."
        data = {"dependency": args.dependency, "runtime": runtime, "notes": notes}
        if _stream_enabled(args):
            _stream_result(
                action=action,
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="completed",
                message=message,
                data=data,
            )
        elif _json_enabled(args):
            _emit_json(action=action, ok=True, message=message, data=data)
        else:
            print(message)
        return
    if args.dependency == "python":
        message = f"Python {sys.version_info.major}.{sys.version_info.minor} is already provided by the active NASE backend."
        if _json_enabled(args) or _stream_enabled(args):
            _emit_json(action=action, ok=True, message=message, data={"dependency": "python", "executable": sys.executable})
        else:
            print(message)
        return
    try:
        command = dependency_install_command(
            args.dependency,
            confirm_rosetta_license=args.confirm_rosetta_license,
        )
    except RuntimeError as exc:
        _json_error(args, action=action, message=str(exc))
    job_id = _stream_start(action=action, message=f"Installing {args.dependency}...") if _stream_enabled(args) else None
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=1800, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        message = f"Could not install {args.dependency}: {exc}"
        if _stream_enabled(args):
            _stream_result(action=action, job_id=job_id or uuid.uuid4().hex, ok=False, status="failed", message=message, errors=[message])
            raise SystemExit(1)
        _json_error(args, action=action, message=message, code=1)
    output = "\n".join(part for part in (result.stdout.strip(), result.stderr.strip()) if part)
    tail = "\n".join(output.splitlines()[-80:])
    if result.returncode != 0:
        message = f"{args.dependency} installation failed (exit {result.returncode})."
        if _stream_enabled(args):
            _stream_result(action=action, job_id=job_id or uuid.uuid4().hex, ok=False, status="failed", message=message, data={"dependency": args.dependency, "tail": tail}, errors=[message])
            raise SystemExit(result.returncode)
        _json_error(args, action=action, message=f"{message}\n{tail}", code=result.returncode)
    message = f"Installed {args.dependency}."
    data = {"dependency": args.dependency, "command": command, "tail": tail}
    if _stream_enabled(args):
        _stream_result(action=action, job_id=job_id or uuid.uuid4().hex, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def cmd_setup_compatibility_profile(args: argparse.Namespace) -> None:
    action = "repair-compatibility-profile" if getattr(args, "repair", False) else "setup-compatibility-profile"
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    if _is_external_prefix(args):
        _json_error(args, action=action, message="Compatibility profiles require a dedicated managed bottle.")
    profile_id = args.profile
    backend_by_profile = {
        "dxmt-wine-stable-11-v1": "dxmt",
        "d3dmetal-gptk-v1": "d3dmetal",
        "dxvk-macos-pinned-v1": "dxvk",
        "plain-wine-v1": "none",
    }
    if profile_id not in backend_by_profile:
        _json_error(args, action=action, message=f"Unknown compatibility profile: {profile_id}")
    if getattr(args, "repair", False) and not bottle.root.exists():
        _json_error(args, action=action, message=f"There is no {bottle.name} profile bottle to repair. Choose Set Up instead.")
    graphics_backend = backend_by_profile[profile_id]
    setup_total_steps = {"dxmt": 5, "d3dmetal": 8, "dxvk": 10, "none": 5}[graphics_backend]
    source_value = {
        "dxmt": args.dxmt_source,
        "d3dmetal": args.d3dmetal_source,
        "dxvk": args.dxvk_source,
        "none": None,
    }[graphics_backend]
    graphics_source = Path(source_value) if source_value else None
    moltenvk_source = Path(args.moltenvk_source) if args.moltenvk_source else None
    if graphics_backend == "dxvk" and moltenvk_source is None:
        moltenvk_source = discover_moltenvk_source()
    root_existed = bottle.root.exists()
    manifest_path = bottle.root / "compatibility-profile.json"
    original_manifest = manifest_path.read_bytes() if manifest_path.is_file() else None
    job_id = _stream_start(action=action, message=f"Preparing {profile_id} in {bottle.name}...") if _stream_enabled(args) else None
    steps: list[dict[str, str]] = []
    cancelled = False

    def cancel_setup(_signum, _frame) -> None:
        nonlocal cancelled
        cancelled = True
        raise RuntimeError("Setup cancelled by the user.")

    previous_sigterm = signal.signal(signal.SIGTERM, cancel_setup)

    def run_step(name: str, message: str, operation) -> None:
        if _stream_enabled(args):
            _stream_step(action=action, job_id=job_id or uuid.uuid4().hex, name=name, status="started", message=message)
        code, tail = operation()
        if code != 0:
            raise RuntimeError(f"{message} failed (exit {code}). Tail:\n{tail}")
        steps.append({"name": name, "status": "ok"})
        if _stream_enabled(args):
            _stream_progress(
                action=action,
                job_id=job_id or uuid.uuid4().hex,
                name=name,
                status="ok",
                message=message.replace("...", "") + " complete.",
                completed_steps=len(steps),
                total_steps=setup_total_steps,
            )

    try:
        graphics_environment = (
            d3dmetal_launch_environment(graphics_source)
            if graphics_backend == "d3dmetal" and graphics_source is not None
            else {}
        )
        if graphics_backend == "dxvk":
            free_bytes = shutil.disk_usage(bottle.root.parent).free
            minimum_bytes = 4 * 1024**3
            if free_bytes < minimum_bytes:
                raise RuntimeError(
                    f"DXVK-macOS setup needs at least 4 GiB free for its fresh bottle and Steam update; "
                    f"only {free_bytes // (1024**2)} MiB is available."
                )
            steps.append({"name": "disk-space", "status": "ok"})
        active_manifest = bind_profile(
            bottle=bottle,
            profile_id=profile_id,
            graphics_backend=graphics_backend,
            wine_path=wine64,
            graphics_source=graphics_source,
            moltenvk_source=moltenvk_source,
            require_ready=False,
        )
        active_manifest["setup_status"] = "setting-up"
        active_manifest["active_job_id"] = job_id
        active_manifest["setup_started_at"] = time.time()
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        temporary_manifest = manifest_path.with_suffix(".tmp")
        temporary_manifest.write_text(
            json.dumps(active_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        temporary_manifest.replace(manifest_path)
        if graphics_backend == "dxvk":
            manifest_path = bottle.root / "compatibility-profile.json"
            bound_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            install_dxvk_macos_native_runtime(bottle, bound_manifest["dxvk_macos_stack"])
            steps.append({"name": "install-native-runtime", "status": "ok"})
        if graphics_backend == "d3dmetal" and graphics_source is not None:
            native_dependency = prepare_sikarugir_native_dependencies(wine64, graphics_source)
            steps.append({"name": "verify-native-dependencies", "status": "ok"})
            if _stream_enabled(args):
                _stream_progress(
                    action=action,
                    job_id=job_id or uuid.uuid4().hex,
                    name="verify-native-dependencies",
                    status="ok",
                    message=(
                        f"Verified {native_dependency['verified_library_count']} native libraries, including "
                        f"{native_dependency['dependency']} ({native_dependency['sha256'][:12]}...)."
                    ),
                    completed_steps=len(steps),
                    total_steps=setup_total_steps,
                )
        ensure_bottle_dirs(bottle)
        steam_exe = bottle.drive_c / "Program Files (x86)" / "Steam" / "Steam.exe"
        initialized_prefix = (bottle.prefix / "system.reg").is_file() and steam_exe.is_file()
        if initialized_prefix:
            # A Wine update pass can launch Steam through its registry startup entry
            # and then wait forever for the client to exit. Profile setup retries only
            # need to resume graphics/library verification once Steam is installed.
            steps.extend(
                [
                    {"name": "wineboot", "status": "ok"},
                    {"name": "set-win10", "status": "ok"},
                ]
            )
        else:
            run_step(
                "wineboot",
                "Initializing the dedicated bottle...",
                lambda: run_logged(
                    cmd=[str(wine64), "wineboot", "-u"],
                    env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all", **graphics_environment},
                    log_file=bottle.logs / "01_profile_wineboot.log",
                    timeout=120,
                ),
            )
            run_step(
                "set-win10",
                "Setting Windows 10 compatibility...",
                lambda: set_prefix_windows_version(bottle, wine64, "win10", extra_env=graphics_environment),
            )
        if steam_exe.exists():
            steps.append({"name": "install-steam", "status": "ok"})
        else:
            winetricks = _resolve_winetricks(args.winetricks)
            run_step(
                "install-steam",
                "Installing Steam...",
                lambda: run_winetricks(
                    bottle=bottle,
                    winetricks_path=winetricks,
                    verbs=["steam"],
                    log_name="02_profile_steam.log",
                    unattended=not args.interactive,
                    extra_env=graphics_environment,
                    wine_path=wine64,
                ),
            )
        if graphics_backend == "dxmt":
            run_step(
                "install-graphics",
                "Installing DXMT 0.71...",
                lambda: install_dxmt(bottle=bottle, dxmt_source=graphics_source, wine64_path=wine64),
            )
        elif graphics_backend == "d3dmetal":
            run_step(
                "install-graphics",
                "Installing the matching D3DMetal payload...",
                lambda: install_d3dmetal(bottle=bottle, d3dmetal_source=graphics_source, wine64_path=wine64),
            )
            verification = verify_d3dmetal_profile(bottle, graphics_source)
            failed = [check for check in verification if check["status"] != "ok"]
            if failed:
                raise RuntimeError("D3DMetal verification failed: " + "; ".join(check["detail"] for check in failed))
            steps.append({"name": "verify-graphics", "status": "ok"})
        elif graphics_backend == "dxvk":
            run_step(
                "install-graphics",
                "Installing pinned DXVK-macOS DLLs...",
                lambda: install_dxvk(
                    bottle=bottle,
                    dxvk_source=graphics_source,
                    dxvk_flavor="macos",
                    without_dxgi=True,
                ),
            )
            verification = verify_dxvk_macos_profile(bottle)
            failed = [check for check in verification if check["status"] != "ok"]
            if failed:
                raise RuntimeError("DXVK-macOS verification failed: " + "; ".join(check["detail"] for check in failed))
            steps.append({"name": "verify-graphics", "status": "ok"})
            run_step(
                "probe-vulkan-d3d11",
                "Creating Vulkan and D3D11 devices and confirming the selected GPU...",
                lambda: probe_dxvk_macos_graphics(bottle=bottle, wine_path=wine64),
            )
        else:
            steps.append({"name": "install-graphics", "status": "ok"})
        if _stream_enabled(args):
            _stream_step(action=action, job_id=job_id or uuid.uuid4().hex, name="attach-libraries", status="started", message="Attaching existing Steam libraries...")
        attachment = attach_registered_libraries(bottle, refresh_registry(bottle))
        steps.append({"name": "attach-libraries", "status": "ok"})
        if graphics_backend == "d3dmetal":
            run_step(
                "verify-steam-stability",
                "Verifying Steam stability with the pinned D3DMetal engine...",
                lambda: probe_steam_stability(
                    bottle=bottle,
                    wine64_path=wine64,
                    graphics_source=graphics_source,
                ),
            )
        elif graphics_backend == "dxvk":
            run_step(
                "verify-steam-stability",
                "Updating Steam and verifying continuous DXVK-macOS stability...",
                lambda: probe_steam_stability(
                    bottle=bottle,
                    wine64_path=wine64,
                    graphics_source=graphics_source,
                    graphics_backend="dxvk",
                ),
            )
        manifest = mark_profile_ready(bottle)
    except BaseException as exc:
        message = str(exc)
        try:
            kill_wine_processes(bottle=bottle, wine64_path=wine64)
        except Exception:
            pass
        rollback = {
            "attempted": True,
            "removed_new_bottle": False,
            "restored_manifest": False,
            "repair_required": root_existed,
        }
        if not root_existed:
            if bottle.root.exists():
                shutil.rmtree(bottle.root)
            rollback["removed_new_bottle"] = True
            rollback["repair_required"] = False
        else:
            bottle.root.mkdir(parents=True, exist_ok=True)
            if original_manifest is not None:
                try:
                    failed_manifest = json.loads(original_manifest)
                except (ValueError, json.JSONDecodeError):
                    failed_manifest = {}
                rollback["restored_manifest"] = True
            else:
                failed_manifest = {"schema_version": 1, "profile": {"id": profile_id}}
            failed_manifest["setup_status"] = "needs-repair"
            failed_manifest["last_failed_job"] = job_id
            failed_manifest["last_failure"] = message
            failed_manifest["failed_at"] = time.time()
            temporary = manifest_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(failed_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            temporary.replace(manifest_path)
        status = "cancelled" if cancelled else "failed"
        if _stream_enabled(args):
            _stream_result(
                action=action,
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status=status,
                message=message,
                data={"profile_id": profile_id, "bottle": bottle.name, "steps": steps, "rollback": rollback},
                errors=[message],
            )
            raise SystemExit(1)
        _json_error(args, action=action, message=message, code=1, data={"rollback": rollback})
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)

    message = f"{manifest['profile']['name']} is ready in {bottle.name}."
    data = {"profile": manifest["profile"], "bottle": bottle.name, "manifest": manifest, "steps": steps, "library_attachment": attachment}
    if _stream_enabled(args):
        _stream_result(action=action, job_id=job_id or uuid.uuid4().hex, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def cmd_reset_compatibility_profile(args: argparse.Namespace) -> None:
    action = "reset-compatibility-profile"
    bottle = _resolve_bottle(args)
    if _is_external_prefix(args):
        _json_error(args, action=action, message="Only managed profile bottles can be reset.")
    profile = PROFILES.get(args.profile)
    if profile is None:
        _json_error(args, action=action, message=f"Unknown compatibility profile: {args.profile}")
    expected_suffix = f"-{profile.bottle_suffix}"
    if not bottle.name.endswith(expected_suffix):
        _json_error(
            args,
            action=action,
            message=f"Refusing to reset {bottle.name}; the {profile.name} bottle must end in {expected_suffix}.",
        )
    if not args.confirm:
        _json_error(args, action=action, message="Reset requires explicit confirmation.")
    if not bottle.root.exists():
        message = f"{profile.name} is already reset."
    else:
        primary_steamapps = steam_prefix_root(bottle) / "steamapps"
        local_manifests = sorted(primary_steamapps.glob("appmanifest_*.acf"))
        if local_manifests:
            appids = ", ".join(path.stem.removeprefix("appmanifest_") for path in local_manifests)
            _json_error(
                args,
                action=action,
                message=(
                    f"Refusing to delete {bottle.name}: it still contains locally stored Steam games "
                    f"({appids}). Move them to the NASE Shared Library in Steam's Storage settings, "
                    "then try again."
                ),
            )
        wine64 = _require_wine64(args)
        kill_wine_processes(bottle=bottle, wine64_path=wine64)
        shutil.rmtree(bottle.root)
        message = f"Removed the dedicated {profile.name} bottle. Shared Steam game files were not removed."
    data = {"profile": args.profile, "bottle": bottle.name, "removed": not bottle.root.exists()}
    if _stream_enabled(args):
        job_id = _stream_start(action=action, message=message)
        _stream_result(action=action, job_id=job_id, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def cmd_attach_steam_library(args: argparse.Namespace) -> None:
    action = "attach-steam-library"
    bottle = _resolve_bottle(args)
    if _is_external_prefix(args):
        _json_error(args, action=action, message="Shared libraries can only be attached to a managed profile bottle.")
    library_ids = set(args.library_id or [])
    if not args.all and not library_ids:
        _json_error(args, action=action, message="Choose --all or provide at least one --library-id.")
    job_id = _stream_start(action=action, message=f"Attaching shared Steam libraries to {bottle.name}...") if _stream_enabled(args) else None
    try:
        registry = refresh_registry(bottle)
        result = attach_registered_libraries(bottle, registry, library_ids=None if args.all else library_ids)
        refreshed = refresh_registry(bottle)
    except RuntimeError as exc:
        message = str(exc)
        if _stream_enabled(args):
            _stream_result(action=action, job_id=job_id or uuid.uuid4().hex, ok=False, status="failed", message=message, errors=[message])
            raise SystemExit(1)
        _json_error(args, action=action, message=message, code=1)
    count = len(result["attached"])
    message = f"Attached {count} shared Steam library location(s) to {bottle.name}." if count else f"All selected Steam libraries are already attached to {bottle.name}."
    data = {**result, "registry_path": str(app_support_root() / "steam-libraries.json"), "library_count": len(refreshed["libraries"])}
    if _stream_enabled(args):
        _stream_result(action=action, job_id=job_id or uuid.uuid4().hex, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def cmd_init(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    ensure_bottle_dirs(bottle)
    print(f"Initializing {_target_label(args, bottle)} at: {bottle.prefix}")
    code, tail = run_logged(
        cmd=[str(wine64), "wineboot", "-u"],
        env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
        log_file=bottle.logs / "01_wineboot.log",
    )
    if code != 0:
        raise SystemExit(f"wineboot failed (exit {code}). Tail:\n{tail}")
    print("Done.")


def cmd_install_steam(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    print(f"Installing Steam into {_target_label(args, bottle)}...")
    code, tail = install_steam(bottle=bottle, wine64_path=wine64)
    if code != 0:
        raise SystemExit(f"Steam installer failed (exit {code}). Tail:\n{tail}")
    print("Steam install finished (or installer exited).")


def cmd_run_steam(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    registry = refresh_registry(bottle)
    acquired_library_ids: list[str] = []
    try:
        for library in registry.get("libraries", []):
            library_id = str(library.get("library_id") or "")
            references = library.get("referenced_by") or []
            attached_here = any(str(reference.get("prefix") or "") == str(bottle.prefix) for reference in references)
            if not library.get("exists") or not library_id or not attached_here:
                continue
            _acquire_library_or_error(
                args,
                action="run-steam",
                library_id=library_id,
                prefix=str(bottle.prefix),
                bottle=bottle.name,
                profile_id=f"steam-{bottle.name}",
                appid="*",
            )
            acquired_library_ids.append(library_id)
    except Exception:
        # Keep successful reservations: they may belong to a concurrent launch
        # in this same prefix. Unused reservations expire after the short launch window.
        raise
    mark_steam_opened_by_user(str(bottle.prefix))
    job_id = _stream_start(action="run-steam", message=f"Launching Steam in {_target_label(args, bottle)}...") if _stream_enabled(args) else None
    if not _json_enabled(args):
        print(f"Launching Steam in {_target_label(args, bottle)}...")
    code, tail = run_steam(
        bottle=bottle,
        wine64_path=wine64,
        steam_path=args.steam_path,
        extra_args=["steam://open/main"],
        wait=not args.no_wait,
        graphics_backend=_resolved_graphics_backend(args, for_steam=True),
        restart_existing=not steam_is_running(str(bottle.prefix)),
    )
    if code != 0:
        if not steam_is_running(str(bottle.prefix)):
            for library_id in acquired_library_ids:
                release_steam_activity(library_id=library_id, prefix=str(bottle.prefix))
        if _stream_enabled(args):
            _stream_result(
                action="run-steam",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"Steam launch failed (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "tail": tail},
                errors=[f"Steam launch failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="run-steam", message=f"Steam launch failed (exit {code}). Tail:\n{tail}", code=code)
    if args.no_wait:
        if _stream_enabled(args):
            _stream_result(
                action="run-steam",
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="started",
                message="Steam launched.",
                data={"target": _target_label(args, bottle), "tail": tail},
            )
            return
        if _json_enabled(args):
            _emit_json(
                action="run-steam",
                ok=True,
                message="Steam launched.",
                data={"target": _target_label(args, bottle), "tail": tail},
                status="started",
            )
        else:
            print("Steam launched.")
    else:
        for library_id in acquired_library_ids:
            release_steam_activity(library_id=library_id, prefix=str(bottle.prefix))
        if _stream_enabled(args):
            _stream_result(
                action="run-steam",
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="completed",
                message="Steam exited.",
                data={"target": _target_label(args, bottle), "tail": tail},
            )
            return
        if _json_enabled(args):
            _emit_json(
                action="run-steam",
                ok=True,
                message="Steam exited.",
                data={"target": _target_label(args, bottle), "tail": tail},
            )
        else:
            print("Steam exited.")


def cmd_winecfg(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    job_id = _stream_start(action="winecfg", message=f"Opening winecfg for {_target_label(args, bottle)}...") if _stream_enabled(args) else None
    if not _json_enabled(args):
        print(f"Opening winecfg for {_target_label(args, bottle)}...")

    code, tail = run_logged(
        cmd=[str(wine64), "winecfg"],
        env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
        log_file=bottle.logs / "05_winecfg.log",
    )
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="winecfg",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"winecfg failed (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "tail": tail},
                errors=[f"winecfg failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="winecfg", message=f"winecfg failed (exit {code}). Tail:\n{tail}", code=code)

    if _stream_enabled(args):
        _stream_result(
            action="winecfg",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message="winecfg exited.",
            data={"target": _target_label(args, bottle), "tail": tail},
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="winecfg",
            ok=True,
            message="winecfg exited.",
            data={"target": _target_label(args, bottle), "tail": tail},
            status="completed",
        )
        return
    print("winecfg exited.")


def cmd_run_winetricks(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    wine64 = _require_wine64(args)
    winetricks = _resolve_winetricks(args.winetricks)
    verbs = [verb.strip() for verb in args.verbs.split(",") if verb.strip()]
    if not verbs:
        _json_error(args, action="winetricks", message="At least one winetricks verb is required")
    job_id = _stream_start(action="winetricks", message=f"Running winetricks for {', '.join(verbs)}...") if _stream_enabled(args) else None
    code, tail = run_winetricks(
        bottle=bottle,
        winetricks_path=winetricks,
        verbs=verbs,
        unattended=not args.interactive,
        wine_path=wine64,
    )
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="winetricks",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"winetricks failed (exit {code}). Tail:\n{tail}",
                data={"verbs": verbs, "target": _target_label(args, bottle), "tail": tail},
                errors=[f"winetricks failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="winetricks", message=f"winetricks failed (exit {code}). Tail:\n{tail}", code=code)
    if _stream_enabled(args):
        _stream_result(
            action="winetricks",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message="Winetricks finished.",
            data={"verbs": verbs, "target": _target_label(args, bottle), "tail": tail},
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="winetricks",
            ok=True,
            message="Winetricks finished.",
            data={"verbs": verbs, "target": _target_label(args, bottle), "tail": tail},
            status="completed",
        )


def cmd_kill_wine(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    all_managed = bool(getattr(args, "all_managed", False))
    target = "all NASE bottles" if all_managed else _target_label(args, bottle)
    job_id = _stream_start(action="kill-wine", message=f"Killing Wine processes for {target}...") if _stream_enabled(args) else None
    if not _json_enabled(args):
        print(f"Killing Wine processes for {target}...")

    if all_managed:
        code, tail, targets = kill_nase_wine_processes(current_bottle=bottle)
    else:
        wine64 = _require_wine64(args)
        code, tail = kill_wine_processes(bottle=bottle, wine64_path=wine64)
        targets = [str(bottle.prefix)]
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="kill-wine",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"Failed to stop Wine processes (exit {code}). Tail:\n{tail}",
                data={"target": target, "targets": targets, "tail": tail},
                errors=[f"Failed to stop Wine processes (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="kill-wine", message=f"Failed to stop Wine processes (exit {code}). Tail:\n{tail}", code=code)

    if _stream_enabled(args):
        _stream_result(
            action="kill-wine",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message="Stopped Wine processes.",
            data={"target": target, "targets": targets, "tail": tail},
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="kill-wine",
            ok=True,
            message="Stopped Wine processes.",
            data={"target": target, "targets": targets, "tail": tail},
            status="completed",
        )
        return
    print("Stopped Wine processes.")


def cmd_list_sessions(args: argparse.Namespace) -> None:
    sessions = reconcile_sessions()
    active_only = not getattr(args, "all", False)
    if active_only:
        sessions = [session for session in sessions if session.get("status") in {"launching", "running", "stopping"}]
    if _stream_enabled(args):
        job_id = _stream_start(action="list-sessions", message="Reconciling launch sessions...")
        _stream_result(
            action="list-sessions",
            job_id=job_id,
            ok=True,
            status="completed",
            message=f"Found {len(sessions)} launch session(s).",
            data={"sessions": sessions},
        )
        return
    if _json_enabled(args):
        _emit_json(action="list-sessions", ok=True, message="Launch sessions reconciled.", data={"sessions": sessions})
        return
    for session in sessions:
        print(f"{session.get('session_id')}\t{session.get('status')}\t{session.get('game')}\t{session.get('bottle')}")


def cmd_list_jobs(args: argparse.Namespace) -> None:
    action = "list-jobs"
    jobs = list_jobs(limit=args.limit)
    message = f"Loaded {len(jobs)} backend job record(s)."
    data = {"jobs": jobs}
    if _stream_enabled(args):
        job_id = _stream_start(action=action, message="Loading backend job history...")
        _stream_result(action=action, job_id=job_id, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(json.dumps(jobs, indent=2))


def cmd_cancel_job(args: argparse.Namespace) -> None:
    action = "cancel-job"
    try:
        job = cancel_job(args.job_id)
    except (FileNotFoundError, OSError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    message = f"Cancellation state for {args.job_id}: {job['status']}."
    data = {"job": job}
    if _stream_enabled(args):
        query_id = _stream_start(action=action, message=f"Cancelling {args.job_id}...")
        _stream_result(action=action, job_id=query_id, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def _identity_result(args: argparse.Namespace, *, action: str, message: str, data: dict) -> None:
    if _stream_enabled(args):
        job_id = _stream_start(action=action, message=message)
        _stream_result(action=action, job_id=job_id, ok=True, status="completed", message=message, data=data)
    elif _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
    else:
        print(message)


def cmd_steam_identity_status(args: argparse.Namespace) -> None:
    _identity_result(
        args,
        action="steam-identity-status",
        message="Shared Steam login status loaded.",
        data=steam_identity_status(),
    )


def cmd_capture_steam_identity(args: argparse.Namespace) -> None:
    action = "capture-steam-identity"
    if not args.confirm:
        _json_error(args, action=action, message="Capture requires --confirm after Steam is fully closed.")
    try:
        data = capture_steam_identity(bottle_paths(args.source_bottle))
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message=f"Protected Steam login captured from {args.source_bottle}.", data=data)


def cmd_provision_steam_identity(args: argparse.Namespace) -> None:
    action = "provision-steam-identity"
    try:
        data = provision_steam_identity(bottle_paths(args.target_bottle))
    except (OSError, RuntimeError, ValueError, KeyError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message=f"Shared Steam login applied to {args.target_bottle}.", data=data)


def cmd_forget_steam_identity(args: argparse.Namespace) -> None:
    action = "forget-steam-identity"
    if not args.confirm:
        _json_error(args, action=action, message="Forgetting the protected login requires --confirm.")
    try:
        data = forget_steam_identity()
    except (OSError, RuntimeError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message="NASE forgot the protected Steam login. Existing profile logins were unchanged.", data=data)


def cmd_sign_out_steam_profile(args: argparse.Namespace) -> None:
    action = "sign-out-steam-profile"
    if not args.confirm:
        _json_error(args, action=action, message="Signing out this profile requires --confirm.")
    try:
        data = sign_out_steam_profile(bottle_paths(args.target_bottle))
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message=f"Signed out Steam in {args.target_bottle} only.", data=data)


def _epic_source(args: argparse.Namespace) -> EpicSource:
    return EpicSource(args.epic_client)


def _gog_source(args: argparse.Namespace) -> GOGSource:
    return GOGSource(args.gog_client)


def _game_source(args: argparse.Namespace):
    return _epic_source(args) if args.source == "epic" else _gog_source(args)


def cmd_source_status(args: argparse.Namespace) -> None:
    source = _game_source(args)
    data = {"source_status": source.status().as_dict()}
    _identity_result(args, action="source-status", message=f"{args.source.upper()} source status loaded.", data=data)


def cmd_list_source_games(args: argparse.Namespace) -> None:
    action = "list-source-games"
    source = _game_source(args)
    try:
        games = [game.as_dict() for game in source.list_games(force_refresh=args.force_refresh)]
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(
        args,
        action=action,
        message=f"Found {len(games)} {args.source.upper()} library item(s).",
        data={"source_id": args.source, "source_games": games},
    )


def cmd_epic_auth(args: argparse.Namespace) -> None:
    action = "epic-auth"
    authorization_code = sys.stdin.readline().strip() if args.authorization_code_stdin else args.authorization_code
    try:
        status = _epic_source(args).authenticate(authorization_code=authorization_code or "")
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message="Epic Games account connected.", data={"source_status": status.as_dict()})


def cmd_epic_logout(args: argparse.Namespace) -> None:
    action = "epic-logout"
    if not args.confirm:
        _json_error(args, action=action, message="Epic sign-out requires --confirm.")
    try:
        status = _epic_source(args).sign_out()
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message="Epic Games account signed out.", data={"source_status": status.as_dict()})


def cmd_gog_auth(args: argparse.Namespace) -> None:
    action = "gog-auth"
    authorization_code = sys.stdin.readline().strip() if args.authorization_code_stdin else args.authorization_code
    try:
        status = _gog_source(args).authenticate(authorization_code=authorization_code or "")
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message="GOG account connected.", data={"source_status": status.as_dict()})


def cmd_gog_logout(args: argparse.Namespace) -> None:
    action = "gog-logout"
    if not args.confirm:
        _json_error(args, action=action, message="GOG sign-out requires --confirm.")
    try:
        status = _gog_source(args).sign_out()
    except (OSError, RuntimeError, ValueError) as exc:
        _json_error(args, action=action, message=str(exc))
    _identity_result(args, action=action, message="GOG account signed out.", data={"source_status": status.as_dict()})


def cmd_source_game_action(args: argparse.Namespace) -> None:
    action = f"{args.source}-{args.operation}"
    source = _game_source(args)
    source_name = "Epic" if args.source == "epic" else "GOG"
    if args.operation == "uninstall" and not args.confirm:
        _json_error(args, action=action, message=f"{source_name} uninstall requires --confirm.")
    job_id = _stream_start(action=action, message=f"{source_name} {args.operation} started for {args.game_id}...") if _stream_enabled(args) else None
    try:
        if args.operation == "install":
            destination = Path(args.install_root).expanduser() if args.install_root else app_support_root() / "game-libraries" / args.source
            source.install(args.game_id, base_path=destination)
        elif args.operation == "update":
            source.update(args.game_id)
        elif args.operation == "verify":
            source.verify(args.game_id)
        elif args.operation == "repair":
            source.repair(args.game_id)
        else:
            source.uninstall(args.game_id, keep_files=args.keep_files)
    except (OSError, RuntimeError, ValueError) as exc:
        if job_id:
            _stream_result(action=action, job_id=job_id, ok=False, status="failed", message=str(exc), errors=[str(exc)])
            raise SystemExit(1)
        _json_error(args, action=action, message=str(exc))
    if job_id:
        _stream_result(
            action=action,
            job_id=job_id,
            ok=True,
            status="completed",
            message=f"{source_name} {args.operation} completed for {args.game_id}.",
            data={"source_id": args.source, "game_id": args.game_id, "operation": args.operation},
        )
        return
    _identity_result(
        args,
        action=action,
        message=f"{source_name} {args.operation} completed for {args.game_id}.",
        data={"source_id": args.source, "game_id": args.game_id, "operation": args.operation},
    )


def cmd_launch_source_game(args: argparse.Namespace) -> None:
    action = "launch-source-game"
    bottle = _resolve_bottle(args)
    wine_path = _require_wine64(args)
    graphics_backend = _resolved_graphics_backend(args, for_steam=False)
    _bind_launch_profile(args, action=action, bottle=bottle, wine_path=wine_path, graphics_backend=graphics_backend)
    graphics_source_value = {
        "dxmt": args.dxmt_source,
        "dxvk": args.dxvk_source,
        "d3dmetal": args.d3dmetal_source,
        "none": None,
    }[graphics_backend]
    source_name = "Epic" if args.source == "epic" else "GOG"
    job_id = _stream_start(action=action, message=f"Preparing {source_name} launch for {args.game_id}...") if _stream_enabled(args) else None
    try:
        environment = graphics_launch_environment(
            bottle,
            graphics_backend,
            Path(graphics_source_value) if graphics_source_value else None,
        )
        _game_source(args).launch(
            args.game_id,
            wine_path=wine_path,
            wine_prefix=bottle.prefix,
            environment=environment,
        )
    except (OSError, RuntimeError, ValueError) as exc:
        if job_id:
            _stream_result(action=action, job_id=job_id, ok=False, status="failed", message=str(exc), errors=[str(exc)])
            raise SystemExit(1)
        _json_error(args, action=action, message=str(exc))
    if job_id:
        _stream_result(
            action=action,
            job_id=job_id,
            ok=True,
            status="completed",
            message=f"{source_name} launch request sent for {args.game_id}.",
            data={"source_id": args.source, "game_id": args.game_id, "graphics_backend": graphics_backend},
        )
        return
    _identity_result(
        args,
        action=action,
        message=f"{source_name} launch request sent for {args.game_id}.",
        data={"source_id": args.source, "game_id": args.game_id, "graphics_backend": graphics_backend},
    )


def cmd_stop_game(args: argparse.Namespace) -> None:
    job_id = _stream_start(action="stop-game", message="Stopping game...") if _stream_enabled(args) else None
    session, pids = stop_session(args.session_id)
    if session is None:
        _json_error(args, action="stop-game", message=f"Unknown launch session: {args.session_id}")
    message = session.get("message") or "Game stopped."
    data = {"session": session, "stopped_pids": pids}
    if _stream_enabled(args):
        _stream_result(
            action="stop-game",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message=message,
            data=data,
        )
        return
    if _json_enabled(args):
        _emit_json(action="stop-game", ok=True, message=message, data=data)
        return
    print(message)


def cmd_install_dxvk(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    code, tail = install_dxvk(
        bottle=bottle,
        dxvk_source=Path(args.dxvk_source),
        dxvk_flavor=args.dxvk_flavor,
        use_symlinks=args.symlink,
        without_dxgi=args.without_dxgi,
    )
    if code != 0:
        raise SystemExit(f"DXVK install failed (exit {code}). Tail:\n{tail}")


def cmd_install_dxmt(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    wine64 = _require_wine64(args)
    code, tail = install_dxmt(
        bottle=bottle,
        dxmt_source=Path(args.dxmt_source),
        wine64_path=wine64,
        allow_unrecommended=getattr(args, "allow_unrecommended_dxmt", False),
    )
    if code != 0:
        raise SystemExit(f"DXMT install failed (exit {code}). Tail:\n{tail}")


def cmd_install_d3dmetal(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    wine64 = _require_wine64(args)
    code, tail = install_d3dmetal(
        bottle=bottle,
        d3dmetal_source=Path(args.d3dmetal_source),
        wine64_path=wine64,
    )
    if code != 0:
        raise SystemExit(f"D3DMetal install failed (exit {code}). Tail:\n{tail}")


def cmd_list_runtime_catalog(args: argparse.Namespace) -> None:
    catalog = list_runtime_catalog()
    if _json_enabled(args) or _stream_enabled(args):
        _emit_json(
            action="list-runtime-catalog",
            ok=True,
            message="Runtime catalog listed.",
            data={"runtimes": catalog},
        )
        return

    for item in catalog:
        installed = "installed" if item.get("installed") else "available"
        print(f"{item['id']}\t{item['kind']}\t{item['name']}\t{item['version']}\t{installed}")


def cmd_list_installed_runtimes(args: argparse.Namespace) -> None:
    runtimes = [runtime.__dict__ for runtime in list_installed_runtimes()]
    if _json_enabled(args) or _stream_enabled(args):
        _emit_json(
            action="list-installed-runtimes",
            ok=True,
            message="Installed runtimes listed.",
            data={"runtimes": runtimes},
        )
        return

    if not runtimes:
        print("No managed runtimes installed.")
        return
    for runtime in runtimes:
        print(f"{runtime['id']}\t{runtime['kind']}\t{runtime['name']}\t{runtime['version']}\t{runtime['path']}")


def cmd_install_runtime(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    wine_path = None
    if args.wine or args.wine64:
        wine_path = _require_wine64(args)
    action = "install-runtime"
    job_id = _stream_start(action=action, message=f"Installing runtime {args.runtime}...") if _stream_enabled(args) else None

    def callback(name: str, status: str, message: str) -> None:
        if _stream_enabled(args):
            _stream_step(
                action=action,
                job_id=job_id or uuid.uuid4().hex,
                name=name,
                status=status,
                message=message,
            )

    try:
        installed, notes = install_runtime(
            runtime_id=args.runtime,
            bottle=bottle,
            wine_path=wine_path,
            install_into_bottle=not args.no_bottle_install,
            callback=callback,
        )
    except Exception as exc:
        message = str(exc)
        if _stream_enabled(args):
            _stream_result(
                action=action,
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=message,
                errors=[message],
            )
            raise SystemExit(1)
        _json_error(args, action=action, message=message, code=1)

    data = {"runtime": installed.__dict__, "notes": notes}
    message = f"Installed {installed.name} {installed.version}."
    if _stream_enabled(args):
        _stream_result(
            action=action,
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message=message,
            data=data,
        )
        return
    if _json_enabled(args):
        _emit_json(action=action, ok=True, message=message, data=data)
        return
    print(message)
    for note in notes:
        print(note)


def cmd_setup_metal(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    ensure_bottle_dirs(bottle)
    job_id = _stream_start(action="setup-metal", message=f"Starting Metal setup for {_target_label(args, bottle)}...") if _stream_enabled(args) else None
    total_steps = 4 if args.no_launch else 5
    runtime = detect_wine_runtime(wine64)
    steps: list[dict[str, str]] = []

    app_name = runtime.get("app_name") or "unknown Wine app"
    version_output = runtime.get("version_output") or "unknown version"
    if not _json_enabled(args):
        print(f"Detected Wine runtime: {app_name} ({version_output})")
        if not runtime.get("is_stable_11"):
            print("Note: the Metal setup is tuned for Wine Stable 11.0.")
            print("      This runtime may still work, but if setup-metal or Steam behaves oddly,")
            print("      switch to /Applications/Wine Stable.app before debugging the prefix.")

    if _is_external_prefix(args):
        if not _json_enabled(args):
            print(f"Using external prefix: {bottle.prefix}")
            print(f"Support files will still live under: {bottle.root}")
    else:
        if not _json_enabled(args):
            print(f"Using managed bottle '{bottle.name}'")
            print(f"Managed prefix path: {bottle.prefix}")

    if not _json_enabled(args):
        print("Initializing prefix...")
    if _stream_enabled(args):
        _stream_step(action="setup-metal", job_id=job_id or uuid.uuid4().hex, name="wineboot", status="started", message="Initializing prefix...")
    code, tail = run_logged(
        cmd=[str(wine64), "wineboot", "-u"],
        env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
        log_file=bottle.logs / "01_wineboot.log",
    )
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"wineboot failed (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                errors=[f"wineboot failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="setup-metal", message=f"wineboot failed (exit {code}). Tail:\n{tail}", code=code)
    steps.append({"name": "wineboot", "status": "ok"})
    if _stream_enabled(args):
        _stream_progress(
            action="setup-metal",
            job_id=job_id or uuid.uuid4().hex,
            name="wineboot",
            status="ok",
            message="Initialized prefix.",
            completed_steps=1,
            total_steps=total_steps,
        )

    if not _json_enabled(args):
        print("Setting the prefix Windows version to Windows 10...")
    if _stream_enabled(args):
        _stream_step(action="setup-metal", job_id=job_id or uuid.uuid4().hex, name="set-win10", status="started", message="Setting Windows version to Windows 10...")
    code, tail = set_prefix_windows_version(bottle, wine64, "win10")
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"winecfg -v win10 failed (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                errors=[f"winecfg -v win10 failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="setup-metal", message=f"winecfg -v win10 failed (exit {code}). Tail:\n{tail}", code=code)
    steps.append({"name": "set-win10", "status": "ok"})
    if _stream_enabled(args):
        _stream_progress(
            action="setup-metal",
            job_id=job_id or uuid.uuid4().hex,
            name="set-win10",
            status="ok",
            message="Set Windows version to Windows 10.",
            completed_steps=2,
            total_steps=total_steps,
        )

    winetricks = _resolve_winetricks(args.winetricks)
    if not _json_enabled(args):
        print("Installing Steam via winetricks...")
    if _stream_enabled(args):
        _stream_step(action="setup-metal", job_id=job_id or uuid.uuid4().hex, name="winetricks-steam", status="started", message="Installing Steam via winetricks...")
    code, tail = run_winetricks(
        bottle=bottle,
        winetricks_path=winetricks,
        verbs=["steam"],
        log_name="02_winetricks_steam.log",
        unattended=not args.interactive,
        wine_path=wine64,
    )
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"winetricks steam failed (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                errors=[f"winetricks steam failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="setup-metal", message=f"winetricks steam failed (exit {code}). Tail:\n{tail}", code=code)
    steps.append({"name": "winetricks-steam", "status": "ok"})
    if _stream_enabled(args):
        _stream_progress(
            action="setup-metal",
            job_id=job_id or uuid.uuid4().hex,
            name="winetricks-steam",
            status="ok",
            message="Installed Steam via winetricks.",
            completed_steps=3,
            total_steps=total_steps,
        )

    if not _json_enabled(args):
        print("Installing DXMT into the Wine runtime and prefix...")
    if _stream_enabled(args):
        _stream_step(action="setup-metal", job_id=job_id or uuid.uuid4().hex, name="install-dxmt", status="started", message="Installing DXMT...")
    code, tail = install_dxmt(
        bottle=bottle,
        dxmt_source=Path(args.dxmt_source),
        wine64_path=wine64,
        allow_unrecommended=getattr(args, "allow_unrecommended_dxmt", False),
    )
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"DXMT install failed (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                errors=[f"DXMT install failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="setup-metal", message=f"DXMT install failed (exit {code}). Tail:\n{tail}", code=code)
    steps.append({"name": "install-dxmt", "status": "ok"})
    if _stream_enabled(args):
        _stream_progress(
            action="setup-metal",
            job_id=job_id or uuid.uuid4().hex,
            name="install-dxmt",
            status="ok",
            message="Installed DXMT.",
            completed_steps=4,
            total_steps=total_steps,
        )

    if args.no_launch:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="completed",
                message="Metal setup complete.",
                data={"target": _target_label(args, bottle), "steps": steps, "completed_steps": total_steps, "total_steps": total_steps, "progress": 1.0},
            )
            return
        if _json_enabled(args):
            _emit_json(
                action="setup-metal",
                ok=True,
                message="Metal setup complete.",
                data={"target": _target_label(args, bottle), "steps": steps},
                status="completed",
            )
        else:
            print("Metal setup complete.")
            if _is_external_prefix(args):
                print("Next step:")
                print(f"python3 mysteamwine.py --prefix {bottle.prefix} --wine {wine64} run-steam")
            else:
                print("Next step:")
                print(f"python3 mysteamwine.py --bottle {bottle.name} --wine {wine64} run-steam")
        return

    if not _json_enabled(args):
        print("Opening Steam...")
    if _stream_enabled(args):
        _stream_step(action="setup-metal", job_id=job_id or uuid.uuid4().hex, name="run-steam", status="started", message="Opening Steam...")
    code, tail = run_steam(
        bottle=bottle,
        wine64_path=wine64,
        wait=not args.no_wait,
        graphics_backend=_resolved_graphics_backend(args, for_steam=True),
    )
    if code != 0:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"Steam launch failed after setup (exit {code}). Tail:\n{tail}",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                errors=[f"Steam launch failed after setup (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="setup-metal", message=f"Steam launch failed after setup (exit {code}). Tail:\n{tail}", code=code)
    steps.append({"name": "run-steam", "status": "ok"})
    if _stream_enabled(args):
        _stream_progress(
            action="setup-metal",
            job_id=job_id or uuid.uuid4().hex,
            name="run-steam",
            status="ok",
            message="Steam opened.",
            completed_steps=5,
            total_steps=total_steps,
        )
    if args.no_wait:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="started",
                message="Metal setup complete. Steam launched.",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail, "completed_steps": total_steps, "total_steps": total_steps, "progress": 1.0},
            )
            return
        if _json_enabled(args):
            _emit_json(
                action="setup-metal",
                ok=True,
                message="Metal setup complete. Steam launched.",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                status="started",
            )
        else:
            print("Metal setup complete. Steam launched.")
    else:
        if _stream_enabled(args):
            _stream_result(
                action="setup-metal",
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="completed",
                message="Metal setup complete. Steam exited.",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail, "completed_steps": total_steps, "total_steps": total_steps, "progress": 1.0},
            )
            return
        if _json_enabled(args):
            _emit_json(
                action="setup-metal",
                ok=True,
                message="Metal setup complete. Steam exited.",
                data={"target": _target_label(args, bottle), "steps": steps, "tail": tail},
                status="completed",
            )
        else:
            print("Metal setup complete. Steam exited.")


def cmd_wipe_bottles(args: argparse.Namespace) -> None:
    if not args.yes:
        raise SystemExit("Refusing to wipe all bottles without --yes")
    removed = wipe_all_bottles()
    if not removed:
        print("No bottles found.")
        return
    print(f"Removed {len(removed)} bottle(s):")
    for bottle_root in removed:
        print(bottle_root)


def cmd_list_games(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    job_id = _stream_start(action="list-games", message="Scanning registered Steam libraries...") if _stream_enabled(args) else None
    registry = refresh_registry(bottle)
    games = installed_games(registry)
    data = {
        "target": _target_label(args, bottle),
        "registry_path": str(app_support_root() / "steam-libraries.json"),
        "library_count": len(registry["libraries"]),
        "libraries": registry["libraries"],
        "games": games,
    }
    message = f"Found {len(games)} installed Steam game(s) across {len(registry['libraries'])} library location(s)." if games else "No installed Steam games were found in registered libraries."
    if _stream_enabled(args):
        _stream_result(
            action="list-games",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message=message,
            data=data,
            warnings=registry["warnings"],
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="list-games",
            ok=True,
            message=message,
            data=data,
            warnings=registry["warnings"],
            status="completed",
        )
        return
    if not games:
        print(message)
        return
    for game in games:
        print(f"{game['appid']}\t{game['name']}\t{game['install_dir']}")


def cmd_doctor(args: argparse.Namespace) -> None:
    bottle = _resolve_bottle(args)
    wine_value = args.wine64 or args.wine
    actions: list[str] = []
    job_id = _stream_start(action="doctor", message=f"Running doctor for {_target_label(args, bottle)}...") if _stream_enabled(args) else None
    if args.fix:
        if _stream_enabled(args):
            _stream_step(action="doctor", job_id=job_id or uuid.uuid4().hex, name="doctor-fix", status="started", message="Applying safe fixes...")
        try:
            actions = apply_doctor_fixes(
                bottle=bottle,
                wine_value=wine_value,
                dxmt_source=args.dxmt_source,
                allow_unrecommended_dxmt=getattr(args, "allow_unrecommended_dxmt", False),
            )
        except Exception as exc:
            if _stream_enabled(args):
                _stream_result(
                    action="doctor",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"doctor --fix failed: {exc}",
                    errors=[f"doctor --fix failed: {exc}"],
                )
                raise SystemExit(1)
            _json_error(args, action="doctor", message=f"doctor --fix failed: {exc}")
        if not _json_enabled(args):
            print(f"Doctor fix target: {_target_label(args, bottle)}")
            for action in actions:
                print(f"[FIX ] {action}")
        if _stream_enabled(args):
            _stream_step(action="doctor", job_id=job_id or uuid.uuid4().hex, name="doctor-fix", status="ok", message="Applied safe fixes.")

    results = run_doctor(bottle=bottle, wine_value=wine_value, winetricks_value=args.winetricks)

    worst_status = "ok"
    rank = {"ok": 0, "warn": 1, "fail": 2}
    checks_payload = []
    for result in results:
        checks_payload.append({"status": result.status, "name": result.name, "detail": result.detail})
        if rank[result.status] > rank[worst_status]:
            worst_status = result.status

    if _stream_enabled(args):
        _stream_result(
            action="doctor",
            job_id=job_id or uuid.uuid4().hex,
            ok=worst_status != "fail",
            status="failed" if worst_status == "fail" else "completed",
            message=f"Doctor finished with status {worst_status}.",
            data={
                "target": _target_label(args, bottle),
                "worst_status": worst_status,
                "checks": checks_payload,
                "actions": actions,
            },
            errors=[] if worst_status != "fail" else ["One or more checks failed."],
        )
        if worst_status == "fail":
            raise SystemExit(1)
        return

    if _json_enabled(args):
        _emit_json(
            action="doctor",
            ok=worst_status != "fail",
            message=f"Doctor finished with status {worst_status}.",
            data={
                "target": _target_label(args, bottle),
                "worst_status": worst_status,
                "checks": checks_payload,
                "actions": actions,
            },
            errors=[] if worst_status != "fail" else ["One or more checks failed."],
            status="failed" if worst_status == "fail" else "completed",
        )
        if worst_status == "fail":
            raise SystemExit(1)
        return

    print(f"Doctor target: {_target_label(args, bottle)}")
    for result in results:
        print(f"[{result.status.upper():4}] {result.name}: {result.detail}")

    if worst_status == "fail":
        raise SystemExit(1)


def cmd_launch_game(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    app, library_id = resolve_registered_app(bottle, args.appid)
    graphics_backend = _resolved_graphics_backend(args, for_steam=False)
    profile_id = _bind_launch_profile(
        args, action="launch-game", bottle=bottle, wine_path=wine64, graphics_backend=graphics_backend
    )
    job_id = _stream_start(action="launch-game", message=f"Launching {app.name} ({app.appid})...") if _stream_enabled(args) else None
    if not _json_enabled(args):
        print(f"Launching {app.name} ({app.appid}) via Steam.")
    if graphics_backend == "dxmt" and args.dxmt_source:
        code, tail = install_dxmt(
            bottle=bottle,
            dxmt_source=Path(args.dxmt_source),
            wine64_path=wine64,
            allow_unrecommended=getattr(args, "allow_unrecommended_dxmt", False),
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"DXMT restore failed (exit {code}). Tail:\n{tail}",
                    data={"appid": app.appid, "name": app.name, "tail": tail},
                    errors=[f"DXMT restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="launch-game", message=f"DXMT restore failed (exit {code}). Tail:\n{tail}", code=code)
    elif graphics_backend == "dxvk" and args.dxvk_source:
        code, tail = install_dxvk(
            bottle=bottle,
            dxvk_source=Path(args.dxvk_source),
            dxvk_flavor=args.dxvk_flavor,
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"DXVK restore failed (exit {code}). Tail:\n{tail}",
                    data={"appid": app.appid, "name": app.name, "tail": tail},
                    errors=[f"DXVK restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="launch-game", message=f"DXVK restore failed (exit {code}). Tail:\n{tail}", code=code)
    elif graphics_backend == "d3dmetal" and args.d3dmetal_source:
        code, tail = install_d3dmetal(
            bottle=bottle,
            d3dmetal_source=Path(args.d3dmetal_source),
            wine64_path=wine64,
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"D3DMetal restore failed (exit {code}). Tail:\n{tail}",
                    data={"appid": app.appid, "name": app.name, "tail": tail},
                    errors=[f"D3DMetal restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="launch-game", message=f"D3DMetal restore failed (exit {code}). Tail:\n{tail}", code=code)
    try:
        executable_hint = guess_game_executable(app.install_dir)
    except (FileNotFoundError, RuntimeError):
        executable_hint = None
    if executable_hint is not None:
        try:
            validate_executable_compatibility(
                executable=executable_hint, wine_path=wine64, graphics_backend=graphics_backend
            )
        except RuntimeError as exc:
            _json_error(args, action="launch-game", message=str(exc))
    steam_was_running = steam_is_running(str(bottle.prefix))
    _acquire_library_or_error(
        args,
        action="launch-game",
        library_id=library_id,
        prefix=str(bottle.prefix),
        bottle=bottle.name,
        profile_id=profile_id,
        appid=app.appid,
    )
    launch_session = create_session(
        bottle=bottle,
        appid=app.appid,
        game=app.name,
        executable=executable_hint,
        install_dir=app.install_dir,
        graphics_backend=graphics_backend,
        strategy="steam",
        profile_id=profile_id,
        wine_path=wine64,
        steam_started_by_nase=not steam_was_running,
        steam_was_running=steam_was_running,
        library_id=library_id,
    )
    code, tail = launch_app(
        bottle=bottle,
        wine64_path=wine64,
        appid=args.appid,
        graphics_backend=graphics_backend,
        wait=not args.no_wait,
        restart_existing=not steam_was_running,
        graphics_source=Path(args.d3dmetal_source) if graphics_backend == "d3dmetal" and args.d3dmetal_source else None,
    )
    if code != 0:
        if not steam_is_running(str(bottle.prefix)):
            release_steam_activity(library_id=library_id, prefix=str(bottle.prefix))
        update_session(
            launch_session["session_id"],
            status="failed",
            message="Steam launch failed.",
            steam_cleanup_after=time.time() + 10 if launch_session.get("steam_started_by_nase") else None,
        )
        if _stream_enabled(args):
            _stream_result(
                action="launch-game",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"App launch failed (exit {code}). Tail:\n{tail}",
                data={"appid": app.appid, "name": app.name, "tail": tail},
                errors=[f"App launch failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="launch-game", message=f"App launch failed (exit {code}). Tail:\n{tail}", code=code)
    launch_session = next(
        (item for item in reconcile_sessions() if item.get("session_id") == launch_session["session_id"]),
        launch_session,
    )
    if args.no_wait:
        if _stream_enabled(args):
            _stream_result(
                action="launch-game",
                job_id=job_id or uuid.uuid4().hex,
                ok=True,
                status="completed",
                message="Launch request sent.",
                data={"appid": app.appid, "name": app.name, "tail": tail, "session": launch_session},
            )
            return
        if _json_enabled(args):
            _emit_json(
                action="launch-game",
                ok=True,
                message="Launch request sent.",
                data={"appid": app.appid, "name": app.name, "tail": tail, "session": launch_session},
                status="completed",
            )
        else:
            print("Launch request sent.")


def cmd_smart_launch_game(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    graphics_backend = _resolved_graphics_backend(args, for_steam=False)
    profile_id = _bind_launch_profile(
        args, action="smart-launch-game", bottle=bottle, wine_path=wine64, graphics_backend=graphics_backend
    )
    try:
        app, library_id = resolve_registered_app(bottle, args.appid)
    except FileNotFoundError:
        if graphics_backend != "d3dmetal":
            raise
        app = None
        library_id = ""
    app_name = app.name if app else f"Steam App {args.appid}"
    job_id = _stream_start(action="smart-launch-game", message=f"Launching {app_name} ({args.appid})...") if _stream_enabled(args) else None

    if graphics_backend == "d3dmetal":
        steam_exe = bottle.drive_c / "Program Files (x86)" / "Steam" / "Steam.exe"
        if not steam_exe.exists():
            if _stream_enabled(args):
                _stream_step(
                    action="smart-launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    name="setup-d3dmetal-steam",
                    status="started",
                    message="Preparing hidden D3DMetal Steam environment...",
                )
            setup_steps = (
                ("wineboot", lambda: run_logged(
                    cmd=[str(wine64), "wineboot", "-u"],
                    env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
                    log_file=bottle.logs / "01_wineboot_d3dmetal.log",
                    timeout=60,
                )),
                ("set-win10", lambda: set_prefix_windows_version(bottle, wine64, "win10")),
                ("winetricks-steam", lambda: run_winetricks(
                    bottle=bottle,
                    winetricks_path=_resolve_winetricks(getattr(args, "winetricks", "winetricks")),
                    verbs=["steam"],
                    log_name="02_winetricks_steam_d3dmetal.log",
                    unattended=True,
                    wine_path=wine64,
                )),
            )
            for step_name, step in setup_steps:
                code, tail = step()
                if code != 0:
                    message = f"D3DMetal environment setup failed at {step_name} (exit {code}). Tail:\n{tail}"
                    if _stream_enabled(args):
                        _stream_result(
                            action="smart-launch-game",
                            job_id=job_id or uuid.uuid4().hex,
                            ok=False,
                            status="failed",
                            message=message,
                            data={"appid": args.appid, "name": app_name, "tail": tail},
                            errors=[message],
                        )
                        raise SystemExit(code)
                    _json_error(args, action="smart-launch-game", message=message, code=code)
            if _stream_enabled(args):
                _stream_step(
                    action="smart-launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    name="setup-d3dmetal-steam",
                    status="ok",
                    message="Prepared hidden D3DMetal Steam environment.",
                )

    if graphics_backend == "dxmt" and args.dxmt_source:
        code, tail = install_dxmt(
            bottle=bottle,
            dxmt_source=Path(args.dxmt_source),
            wine64_path=wine64,
            allow_unrecommended=getattr(args, "allow_unrecommended_dxmt", False),
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="smart-launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"DXMT restore failed (exit {code}). Tail:\n{tail}",
                    data={"appid": args.appid, "name": app_name, "tail": tail},
                    errors=[f"DXMT restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="smart-launch-game", message=f"DXMT restore failed (exit {code}). Tail:\n{tail}", code=code)
    elif graphics_backend == "dxvk" and args.dxvk_source:
        code, tail = install_dxvk(
            bottle=bottle,
            dxvk_source=Path(args.dxvk_source),
            dxvk_flavor=args.dxvk_flavor,
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="smart-launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"DXVK restore failed (exit {code}). Tail:\n{tail}",
                    data={"appid": args.appid, "name": app_name, "tail": tail},
                    errors=[f"DXVK restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="smart-launch-game", message=f"DXVK restore failed (exit {code}). Tail:\n{tail}", code=code)
    elif graphics_backend == "d3dmetal" and args.d3dmetal_source:
        code, tail = install_d3dmetal(
            bottle=bottle,
            d3dmetal_source=Path(args.d3dmetal_source),
            wine64_path=wine64,
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="smart-launch-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"D3DMetal restore failed (exit {code}). Tail:\n{tail}",
                    data={"appid": args.appid, "name": app_name, "tail": tail},
                    errors=[f"D3DMetal restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="smart-launch-game", message=f"D3DMetal restore failed (exit {code}). Tail:\n{tail}", code=code)

    direct_error: str | None = None
    skip_direct_reason: str | None = None
    executable_hint: Path | None = None
    if app is not None:
        try:
            executable_hint = guess_game_executable(app.install_dir)
        except (FileNotFoundError, RuntimeError):
            executable_hint = None
        if executable_hint is not None:
            try:
                validate_executable_compatibility(
                    executable=executable_hint, wine_path=wine64, graphics_backend=graphics_backend
                )
            except RuntimeError as exc:
                _json_error(args, action="smart-launch-game", message=str(exc))
    launch_session = create_session(
        bottle=bottle,
        appid=args.appid,
        game=app_name,
        executable=executable_hint,
        install_dir=app.install_dir if app is not None else None,
        graphics_backend=graphics_backend,
        strategy="pending",
        profile_id=profile_id,
        wine_path=wine64,
        library_id=library_id,
    )
    try:
        if app is None:
            skip_direct_reason = "No manifest found in the hidden D3DMetal environment yet; using Steam protocol launch."
        else:
            scan = scan_game_dir(app.install_dir, max_files=1200)
            if any(signal.key == "unity" for signal in scan.signals):
                skip_direct_reason = "Skipped direct launch for Unity title; using Steam launch for better renderer compatibility."
    except Exception:
        scan = None

    if skip_direct_reason is None:
        try:
            assert_direct_launch_safe(library_path=app.library_path, appid=args.appid)
            executable = executable_hint or guess_game_executable(app.install_dir)
            code, tail = run_game_executable(
                bottle=bottle,
                wine64_path=wine64,
                executable=executable,
                extra_args=None,
                extra_env=None,
                cwd=executable.parent,
                wine_debug="-all",
                wait=False,
                graphics_backend=graphics_backend,
                probe_seconds=args.probe_seconds,
                graphics_source=Path(args.d3dmetal_source) if graphics_backend == "d3dmetal" and args.d3dmetal_source else None,
            )
            if code == 0:
                update_session(launch_session["session_id"], strategy="direct", message="Direct launch request sent.")
                launch_session = next(
                    (item for item in reconcile_sessions() if item.get("session_id") == launch_session["session_id"]),
                    launch_session,
                )
                message = "Direct launch started."
                data = {
                    "appid": args.appid,
                    "name": app_name,
                    "executable": str(executable),
                    "strategy": "direct",
                    "tail": tail,
                    "session": launch_session,
                }
                if _stream_enabled(args):
                    _stream_result(
                        action="smart-launch-game",
                        job_id=job_id or uuid.uuid4().hex,
                        ok=True,
                        status="completed",
                        message=message,
                        data=data,
                    )
                    return
                if _json_enabled(args):
                    _emit_json(
                        action="smart-launch-game",
                        ok=True,
                        message=message,
                        data=data,
                        status="completed",
                    )
                    return
                print(message)
                return
            direct_error = f"Direct launch failed (exit {code}). Tail:\n{tail}"
        except Exception as exc:
            direct_error = str(exc)
    else:
        direct_error = skip_direct_reason

    steam_was_running = steam_is_running(str(bottle.prefix))
    _acquire_library_or_error(
        args,
        action="smart-launch-game",
        library_id=library_id,
        prefix=str(bottle.prefix),
        bottle=bottle.name,
        profile_id=profile_id,
        appid=args.appid,
    )
    update_session(
        launch_session["session_id"],
        steam_was_running=steam_was_running,
        steam_started_by_nase=not steam_was_running,
        steam_cleanup_status="not-owned" if steam_was_running else "pending",
    )
    code, tail = launch_app(
        bottle=bottle,
        wine64_path=wine64,
        appid=args.appid,
        graphics_backend=graphics_backend,
        wait=not args.no_wait,
        restart_existing=not steam_was_running,
        graphics_source=Path(args.d3dmetal_source) if graphics_backend == "d3dmetal" and args.d3dmetal_source else None,
    )
    if code != 0:
        if not steam_is_running(str(bottle.prefix)):
            release_steam_activity(library_id=library_id, prefix=str(bottle.prefix))
        update_session(
            launch_session["session_id"],
            status="failed",
            strategy="steam-fallback",
            message="Steam launch failed.",
            steam_cleanup_after=time.time() + 10 if not steam_was_running else None,
        )
        failure = f"Fallback Steam launch failed (exit {code}). Tail:\n{tail}"
        combined = f"{direct_error or 'Direct launch failed.'}\n\n{failure}"
        if _stream_enabled(args):
            _stream_result(
                action="smart-launch-game",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=combined,
                data={"appid": args.appid, "name": app_name, "tail": tail, "strategy": "steam-fallback", "session": launch_session},
                errors=[failure],
            )
            raise SystemExit(code)
        _json_error(args, action="smart-launch-game", message=combined, code=code)

    update_session(launch_session["session_id"], strategy="steam-fallback", message="Steam launch request sent.")
    launch_session = next(
        (item for item in reconcile_sessions() if item.get("session_id") == launch_session["session_id"]),
        launch_session,
    )
    message = "Opened with Steam after direct launch failed."
    data = {
        "appid": args.appid,
        "name": app_name,
        "strategy": "steam-fallback",
        "tail": tail,
        "warnings": [direct_error] if direct_error else [],
        "session": launch_session,
    }
    if _stream_enabled(args):
        _stream_result(
            action="smart-launch-game",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="completed",
            message=message,
            data=data,
            warnings=[direct_error] if direct_error else [],
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="smart-launch-game",
            ok=True,
            message=message,
            data=data,
            warnings=[direct_error] if direct_error else [],
            status="completed",
        )
        return
    print(message)


def cmd_gui(args: argparse.Namespace) -> None:
    from .gui import launch_gui

    launch_gui(args)


def _resolve_debug_executable(args: argparse.Namespace) -> Path:
    if args.exe:
        return Path(args.exe)
    if args.appid:
        bottle = _resolve_bottle(args)
        app, _ = resolve_registered_app(bottle, args.appid)
        return guess_game_executable(app.install_dir)
    raise SystemExit("Provide either --appid or --exe")


def cmd_debug_game(args: argparse.Namespace) -> None:
    wine64 = _require_wine64(args)
    bottle = _resolve_bottle(args)
    executable = _resolve_debug_executable(args)
    graphics_backend = _resolved_graphics_backend(args, for_steam=False)
    profile_id = _bind_launch_profile(
        args, action="debug-game", bottle=bottle, wine_path=wine64, graphics_backend=graphics_backend
    )
    job_id = _stream_start(action="debug-game", message=f"Launching {executable.name} with Wine debug logging...") if _stream_enabled(args) else None
    extra_args = list(args.game_args or [])
    if extra_args and extra_args[0] == "--":
        extra_args = extra_args[1:]
    extra_env: dict[str, str] = {}
    for entry in args.env or []:
        if "=" not in entry:
            raise SystemExit(f"Invalid --env value: {entry!r}. Expected KEY=VALUE.")
        key, value = entry.split("=", 1)
        extra_env[key] = value

    if not _json_enabled(args):
        print(f"Launching {executable.name} directly with Wine debug logging...")
    if graphics_backend == "dxmt" and args.dxmt_source:
        code, tail = install_dxmt(
            bottle=bottle,
            dxmt_source=Path(args.dxmt_source),
            wine64_path=wine64,
            allow_unrecommended=getattr(args, "allow_unrecommended_dxmt", False),
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="debug-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"DXMT restore failed (exit {code}). Tail:\n{tail}",
                    data={"executable": str(executable), "tail": tail},
                    errors=[f"DXMT restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="debug-game", message=f"DXMT restore failed (exit {code}). Tail:\n{tail}", code=code)
    elif graphics_backend == "dxvk" and args.dxvk_source:
        code, tail = install_dxvk(
            bottle=bottle,
            dxvk_source=Path(args.dxvk_source),
            dxvk_flavor=args.dxvk_flavor,
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="debug-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"DXVK restore failed (exit {code}). Tail:\n{tail}",
                    data={"executable": str(executable), "tail": tail},
                    errors=[f"DXVK restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="debug-game", message=f"DXVK restore failed (exit {code}). Tail:\n{tail}", code=code)
    elif graphics_backend == "d3dmetal" and args.d3dmetal_source:
        code, tail = install_d3dmetal(
            bottle=bottle,
            d3dmetal_source=Path(args.d3dmetal_source),
            wine64_path=wine64,
        )
        if code != 0:
            if _stream_enabled(args):
                _stream_result(
                    action="debug-game",
                    job_id=job_id or uuid.uuid4().hex,
                    ok=False,
                    status="failed",
                    message=f"D3DMetal restore failed (exit {code}). Tail:\n{tail}",
                    data={"executable": str(executable), "tail": tail},
                    errors=[f"D3DMetal restore failed (exit {code})."],
                )
                raise SystemExit(code)
            _json_error(args, action="debug-game", message=f"D3DMetal restore failed (exit {code}). Tail:\n{tail}", code=code)
    debug_app = None
    debug_library_id = ""
    if args.appid:
        debug_app, debug_library_id = resolve_registered_app(bottle, args.appid)
    try:
        validate_executable_compatibility(
            executable=executable, wine_path=wine64, graphics_backend=graphics_backend
        )
    except RuntimeError as exc:
        _json_error(args, action="debug-game", message=str(exc))
    launch_cwd = Path(args.cwd) if args.cwd else executable.parent
    overlay: dict[str, str] | None = None
    if args.legacy_directx_source:
        try:
            overlay = prepare_legacy_directx_overlay(
                bottle=bottle,
                game_id=args.appid or hashlib.sha256(str(executable.resolve()).encode()).hexdigest()[:16],
                game_dir=debug_app.install_dir if debug_app else executable.parent,
                executable=executable,
                source=Path(args.legacy_directx_source),
            )
        except (OSError, RuntimeError, zipfile.BadZipFile) as exc:
            _json_error(args, action="debug-game", message=f"Legacy DirectX overlay could not be prepared: {exc}")
        executable = Path(overlay["overlay_executable"])
        launch_cwd = Path(overlay["overlay_root"])
        extra_env["WINEDLLOVERRIDES"] = "ddraw=n;d3dimm=n"
    steam_was_running = steam_is_running(str(bottle.prefix))
    steam_started_by_nase = False
    steam_connection_offset: int | None = None
    if args.ensure_steam:
        if not args.appid:
            _json_error(args, action="debug-game", message="Starting Steam automatically requires a Steam AppID.")
        _acquire_library_or_error(
            args,
            action="debug-game",
            library_id=debug_library_id,
            prefix=str(bottle.prefix),
            bottle=bottle.name,
            profile_id=profile_id,
            appid=args.appid,
        )
        if not steam_was_running:
            connection_log = (
                bottle.prefix
                / "drive_c"
                / "Program Files (x86)"
                / "Steam"
                / "logs"
                / "connection_log.txt"
            )
            steam_connection_offset = connection_log.stat().st_size if connection_log.is_file() else 0
            code, tail = run_steam(
                bottle=bottle,
                wine64_path=wine64,
                extra_args=["-silent"],
                wait=False,
                graphics_backend=graphics_backend,
                restart_existing=False,
                graphics_source=(
                    Path(args.d3dmetal_source)
                    if graphics_backend == "d3dmetal" and args.d3dmetal_source
                    else None
                ),
            )
            if code != 0:
                release_steam_activity(library_id=debug_library_id, prefix=str(bottle.prefix))
                _json_error(
                    args,
                    action="debug-game",
                    message=f"The matching Windows Steam could not be started (exit {code}). Tail:\n{tail}",
                    code=code,
                )
            steam_started_by_nase = True
        # Steam.exe appears well before login and the local Steam API are ready.
        # Waiting for the connection log's current state avoids racing games
        # that call SteamAPI_Init immediately during process startup.
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if steam_is_running(str(bottle.prefix)) and steam_client_is_ready(
                bottle, after_offset=steam_connection_offset
            ):
                break
            time.sleep(0.5)
        else:
            if steam_started_by_nase:
                release_steam_activity(library_id=debug_library_id, prefix=str(bottle.prefix))
            _json_error(
                args,
                action="debug-game",
                message=(
                    "Windows Steam opened but did not finish signing in within one minute. "
                    "Open Steam for this compatibility profile, finish any login or update prompt, then try again."
                ),
            )
    launch_session = create_session(
        bottle=bottle,
        appid=args.appid,
        game=debug_app.name if debug_app else executable.stem,
        executable=executable,
        install_dir=debug_app.install_dir if debug_app else executable.parent,
        graphics_backend=graphics_backend,
        strategy="direct",
        profile_id=profile_id,
        wine_path=wine64,
        library_id=debug_library_id or None,
        steam_started_by_nase=steam_started_by_nase,
        steam_was_running=steam_was_running,
    )
    code, tail = run_game_executable(
        bottle=bottle,
        wine64_path=wine64,
        executable=executable,
        extra_args=extra_args,
        extra_env=extra_env or None,
        cwd=launch_cwd,
        wine_debug=args.wine_debug,
        wait=not args.no_wait,
        graphics_backend=graphics_backend,
        graphics_source=Path(args.d3dmetal_source) if graphics_backend == "d3dmetal" and args.d3dmetal_source else None,
    )
    if code != 0:
        update_session(launch_session["session_id"], status="failed", message="Direct game launch failed.")
        if _stream_enabled(args):
            _stream_result(
                action="debug-game",
                job_id=job_id or uuid.uuid4().hex,
                ok=False,
                status="failed",
                message=f"Direct game launch failed (exit {code}). Tail:\n{tail}",
                data={"executable": str(executable), "tail": tail},
                errors=[f"Direct game launch failed (exit {code})."],
            )
            raise SystemExit(code)
        _json_error(args, action="debug-game", message=f"Direct game launch failed (exit {code}). Tail:\n{tail}", code=code)
    if not args.no_wait:
        update_session(launch_session["session_id"], status="exited", message="Game process exited.")
    launch_session = next(
        (item for item in reconcile_sessions() if item.get("session_id") == launch_session["session_id"]),
        launch_session,
    )
    if _stream_enabled(args):
        _stream_result(
            action="debug-game",
            job_id=job_id or uuid.uuid4().hex,
            ok=True,
            status="started" if args.no_wait else "completed",
            message="Game process exited." if not args.no_wait else "Debug launch started.",
            data={"executable": str(executable), "tail": tail, "session": launch_session},
        )
        return
    if _json_enabled(args):
        _emit_json(
            action="debug-game",
            ok=True,
            message="Game process exited." if not args.no_wait else "Debug launch started.",
            data={"executable": str(executable), "tail": tail, "session": launch_session},
            status="started" if args.no_wait else "completed",
        )
    else:
        print("Game process exited.")


def _resolve_scan_target(args: argparse.Namespace) -> Path:
    if args.path:
        return Path(args.path)
    if args.appid:
        bottle = _resolve_bottle(args)
        return resolve_registered_app(bottle, args.appid)[0].install_dir
    raise SystemExit("Provide either --path or --appid")


def cmd_scan_game(args: argparse.Namespace) -> None:
    scan = scan_game_dir(_resolve_scan_target(args))
    if _json_enabled(args):
        _emit_json(
            action="scan-game",
            ok=True,
            message=f"Scanned {scan.root}",
            data={
                "root": str(scan.root),
                "signals": [
                    {"key": signal.key, "detail": signal.detail, "path": str(signal.path)}
                    for signal in scan.signals
                ],
            },
            status="completed",
        )
        return
    if not scan.signals:
        print(f"No known dependency markers found in {scan.root}")
        return
    for signal in scan.signals:
        print(f"{signal.key}\t{signal.detail}\t{signal.path}")


def cmd_advise_game(args: argparse.Namespace) -> None:
    scan = scan_game_dir(_resolve_scan_target(args))
    recommendations = recommend_dependencies(scan)
    if _json_enabled(args):
        _emit_json(
            action="advise-game",
            ok=True,
            message=f"Generated {len(recommendations)} recommendation(s)." if recommendations else f"No rules matched for {scan.root}",
            data={
                "root": str(scan.root),
                "recommendations": [
                    {"verb": rec.verb, "reason": rec.reason}
                    for rec in recommendations
                ],
            },
            status="completed",
        )
        return
    if not recommendations:
        print(f"No rules matched for {scan.root}")
        return
    for rec in recommendations:
        print(f"{rec.verb}\t{rec.reason}")


def cmd_reset_game_overlay(args: argparse.Namespace) -> None:
    if not args.confirm:
        _json_error(args, action="reset-game-overlay", message="Reset requires --confirm.")
    bottle = _resolve_bottle(args)
    removed = reset_legacy_directx_overlay(bottle=bottle, game_id=args.game_id)
    message = "Removed the per-game legacy DirectX overlay." if removed else "No per-game overlay was installed."
    data = {"game_id": args.game_id, "removed": removed}
    if _json_enabled(args) or _stream_enabled(args):
        _emit_json(action="reset-game-overlay", ok=True, message=message, data=data)
    else:
        print(message)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mysteamwine",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=textwrap.dedent(
            f"""\
            {APP_NAME}: Python-first Wine bottle manager for Steam on macOS.

            Typical flow:
              1) init
              2) install-steam
              3) run-steam
              4) list-games
              5) launch-game --appid <id>
            """
        ),
    )
    parser.add_argument("--bottle", default=DEFAULT_BOTTLE_NAME, help=f"Bottle name (default: {DEFAULT_BOTTLE_NAME})")
    parser.add_argument(
        "--prefix",
        help="Use an existing Wine prefix directly instead of a managed bottle, for example: ~/.wine-bluearchive",
    )
    parser.add_argument(
        "--wine64",
        help="Path to the Wine launcher (example: /opt/homebrew/bin/wine or /opt/homebrew/bin/wine64)",
    )
    parser.add_argument("--wine", dest="wine", help="Alias for --wine64 for compatibility with older usage")
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON for app integrations")
    parser.add_argument("--jsonl", action="store_true", help="Emit streaming machine-readable JSON lines for app integrations")
    parser.add_argument(
        "--graphics-backend",
        choices=("auto", "dxvk", "dxmt", "d3dmetal", "none"),
        default="auto",
        help="Graphics backend override to apply at launch time (default: auto: plain Steam, DXMT for games)",
    )
    parser.add_argument(
        "--compatibility-profile",
        help="Pinned compatibility profile id. Defaults to the profile for --graphics-backend.",
    )
    parser.add_argument("--epic-client", default="legendary", help="Path or command name for the Legendary Epic client")
    parser.add_argument("--gog-client", default="gogdl", help="Path or command name for the GOG Download Client")

    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("info", help="Show paths used for this bottle").set_defaults(func=cmd_info)
    list_jobs_cmd = sub.add_parser("list-jobs", help="List durable backend job records")
    list_jobs_cmd.add_argument("--limit", type=int, default=50, help="Maximum jobs to return")
    list_jobs_cmd.set_defaults(func=cmd_list_jobs)
    cancel_job_cmd = sub.add_parser("cancel-job", help="Request cancellation of a running backend job")
    cancel_job_cmd.add_argument("--job-id", required=True, help="Durable backend job id")
    cancel_job_cmd.set_defaults(func=cmd_cancel_job)
    sub.add_parser("steam-identity-status", help="Show protected shared Steam login status without exposing tokens").set_defaults(
        func=cmd_steam_identity_status
    )
    capture_identity = sub.add_parser("capture-steam-identity", help="Save the minimal remembered Steam login from one stopped profile")
    capture_identity.add_argument("--source-bottle", required=True, help="Signed-in managed bottle to capture from")
    capture_identity.add_argument("--confirm", action="store_true", help="Confirm protected authentication capture")
    capture_identity.set_defaults(func=cmd_capture_steam_identity)
    provision_identity = sub.add_parser("provision-steam-identity", help="Apply the protected Steam login to one stopped profile")
    provision_identity.add_argument("--target-bottle", required=True, help="Managed bottle that already contains Steam")
    provision_identity.set_defaults(func=cmd_provision_steam_identity)
    forget_identity = sub.add_parser("forget-steam-identity", help="Delete NASE's protected login without changing profile logins")
    forget_identity.add_argument("--confirm", action="store_true", help="Confirm deletion of the protected login")
    forget_identity.set_defaults(func=cmd_forget_steam_identity)
    sign_out_profile = sub.add_parser("sign-out-steam-profile", help="Remove remembered Steam authentication from one profile")
    sign_out_profile.add_argument("--target-bottle", required=True, help="Managed bottle to sign out")
    sign_out_profile.add_argument("--confirm", action="store_true", help="Confirm per-profile sign-out")
    sign_out_profile.set_defaults(func=cmd_sign_out_steam_profile)
    source_status = sub.add_parser("source-status", help="Show availability and authentication state for a game source")
    source_status.add_argument("--source", choices=("epic", "gog"), required=True)
    source_status.set_defaults(func=cmd_source_status)
    list_source_games = sub.add_parser("list-source-games", help="List normalized games owned through a store source")
    list_source_games.add_argument("--source", choices=("epic", "gog"), required=True)
    list_source_games.add_argument("--force-refresh", action="store_true", help="Refresh source metadata from the service")
    list_source_games.set_defaults(func=cmd_list_source_games)
    epic_auth = sub.add_parser("epic-auth", help="Connect Epic using an authorization code")
    epic_auth_input = epic_auth.add_mutually_exclusive_group(required=True)
    epic_auth_input.add_argument("--authorization-code", help="Short-lived code copied from Epic's authorization response")
    epic_auth_input.add_argument("--authorization-code-stdin", action="store_true", help="Read the short-lived code from standard input")
    epic_auth.set_defaults(func=cmd_epic_auth)
    epic_logout = sub.add_parser("epic-logout", help="Remove the Epic authentication stored by Legendary")
    epic_logout.add_argument("--confirm", action="store_true", help="Confirm Epic sign-out")
    epic_logout.set_defaults(func=cmd_epic_logout)
    gog_auth = sub.add_parser("gog-auth", help="Connect GOG using the callback URL or authorization code")
    gog_auth_input = gog_auth.add_mutually_exclusive_group(required=True)
    gog_auth_input.add_argument("--authorization-code", help="Short-lived code returned by GOG")
    gog_auth_input.add_argument("--authorization-code-stdin", action="store_true", help="Read the callback URL or code from standard input")
    gog_auth.set_defaults(func=cmd_gog_auth)
    gog_logout = sub.add_parser("gog-logout", help="Remove the GOG authentication stored by NASE")
    gog_logout.add_argument("--confirm", action="store_true", help="Confirm GOG sign-out")
    gog_logout.set_defaults(func=cmd_gog_logout)
    source_game_action = sub.add_parser("source-game-action", help="Install, update, verify, repair, or uninstall a store game")
    source_game_action.add_argument("--source", choices=("epic", "gog"), required=True)
    source_game_action.add_argument("--game-id", required=True, help="Provider-specific game id")
    source_game_action.add_argument("--operation", choices=("install", "update", "verify", "repair", "uninstall"), required=True)
    source_game_action.add_argument("--install-root", help="Shared host directory used for source game files")
    source_game_action.add_argument("--keep-files", action="store_true", help="Remove Legendary metadata without deleting game files")
    source_game_action.add_argument("--confirm", action="store_true", help="Confirm uninstall")
    source_game_action.set_defaults(func=cmd_source_game_action)
    launch_source_game = sub.add_parser("launch-source-game", help="Launch an installed store game through a compatibility profile")
    launch_source_game.add_argument("--source", choices=("epic", "gog"), required=True)
    launch_source_game.add_argument("--game-id", required=True, help="Provider-specific game id")
    launch_source_game.add_argument("--dxmt-source", help="DXMT source for the selected profile")
    launch_source_game.add_argument("--dxvk-source", help="DXVK-macOS source for the selected profile")
    launch_source_game.add_argument("--d3dmetal-source", help="D3DMetal source for the selected profile")
    launch_source_game.set_defaults(func=cmd_launch_source_game)
    sub.add_parser("list-compatibility-profiles", help="List pinned graphics/runtime profiles").set_defaults(func=cmd_list_compatibility_profiles)
    discover_d3dmetal = sub.add_parser("discover-d3dmetal", help="Find a matched local GPTK Wine and D3DMetal installation")
    discover_d3dmetal.add_argument("--gptk-wine", help="Previously selected GPTK Wine executable")
    discover_d3dmetal.add_argument("--d3dmetal-source", help="Previously selected GPTK/D3DMetal root")
    discover_d3dmetal.set_defaults(func=cmd_discover_d3dmetal)
    import_gptk = sub.add_parser("import-gptk", help="Copy a licensed GPTK installation into NASE managed storage")
    import_gptk.add_argument("--gptk-wine", required=True, help="GPTK Wine executable")
    import_gptk.add_argument("--d3dmetal-source", required=True, help="Root of the same GPTK installation")
    import_gptk.add_argument("--confirm-license", action="store_true", help="Confirm acceptance of Apple's GPTK license")
    import_gptk.set_defaults(func=cmd_import_gptk)
    dependency_cmd = sub.add_parser("dependency-status", help="Check host dependencies required by NASE profiles")
    dependency_cmd.add_argument("--winetricks", default="winetricks", help="Path or command name for Winetricks")
    dependency_cmd.add_argument("--gptk-wine", help="Optional GPTK Wine executable")
    dependency_cmd.add_argument("--d3dmetal-source", help="Optional D3DMetal source directory")
    dependency_cmd.set_defaults(func=cmd_dependency_status)
    install_dependency_cmd = sub.add_parser("install-host-dependency", help="Install one confirmed host dependency")
    install_dependency_cmd.add_argument(
        "--dependency",
        choices=("python", "rosetta", "gstreamer", "wine-stable", "winetricks"),
        required=True,
    )
    install_dependency_cmd.add_argument("--confirm-rosetta-license", action="store_true", help="Confirm acceptance of Apple's Rosetta software license")
    install_dependency_cmd.set_defaults(func=cmd_install_host_dependency)
    profile_setup = sub.add_parser("setup-compatibility-profile", help="Prepare a dedicated bottle for a pinned graphics profile")
    profile_setup.add_argument("--profile", required=True, help="Profile id from list-compatibility-profiles")
    profile_setup.add_argument("--dxmt-source", help="Verified DXMT source directory")
    profile_setup.add_argument("--dxvk-source", help="Pinned DXVK-macOS bundle directory")
    profile_setup.add_argument("--moltenvk-source", help="Compatible Sikarugir wrapper or moltenvkcx directory")
    profile_setup.add_argument("--d3dmetal-source", help="D3DMetal directory from the selected GPTK installation")
    profile_setup.add_argument("--winetricks", default="winetricks", help="Path to winetricks")
    profile_setup.add_argument("--interactive", action="store_true", help="Allow interactive Steam installation")
    profile_setup.set_defaults(func=cmd_setup_compatibility_profile, repair=False)
    profile_repair = sub.add_parser("repair-compatibility-profile", help="Resume and verify an incomplete profile bottle")
    profile_repair.add_argument("--profile", required=True, help="Profile id from list-compatibility-profiles")
    profile_repair.add_argument("--dxmt-source", help="Verified DXMT source directory")
    profile_repair.add_argument("--dxvk-source", help="Pinned DXVK-macOS bundle directory")
    profile_repair.add_argument("--moltenvk-source", help="Compatible Sikarugir wrapper or moltenvkcx directory")
    profile_repair.add_argument("--d3dmetal-source", help="D3DMetal directory from the selected GPTK installation")
    profile_repair.add_argument("--winetricks", default="winetricks", help="Path to winetricks")
    profile_repair.add_argument("--interactive", action="store_true", help="Allow interactive Steam installation")
    profile_repair.set_defaults(func=cmd_setup_compatibility_profile, repair=True)
    profile_reset = sub.add_parser("reset-compatibility-profile", help="Remove one dedicated profile bottle without deleting shared games")
    profile_reset.add_argument("--profile", required=True, help="Profile id from list-compatibility-profiles")
    profile_reset.add_argument("--confirm", action="store_true", help="Confirm removal of the dedicated bottle")
    profile_reset.set_defaults(func=cmd_reset_compatibility_profile)
    attach_library = sub.add_parser("attach-steam-library", help="Attach canonical shared Steam libraries to one managed profile bottle")
    attach_library.add_argument("--all", action="store_true", help="Attach every discovered Steam library")
    attach_library.add_argument("--library-id", action="append", help="Attach one stable library id; may be repeated")
    attach_library.set_defaults(func=cmd_attach_steam_library)
    sub.add_parser("init", help="Create or initialize the Wine prefix").set_defaults(func=cmd_init)
    sub.add_parser("install-steam", help="Download and run SteamSetup.exe").set_defaults(func=cmd_install_steam)

    run_cmd = sub.add_parser("run-steam", help="Launch Steam.exe inside the bottle")
    run_cmd.add_argument("--steam-path", default=steam_windows_path(), help="Windows path to Steam.exe")
    run_cmd.add_argument("--no-wait", action="store_true", help="Return immediately after launching Steam")
    run_cmd.set_defaults(func=cmd_run_steam)

    sub.add_parser("winecfg", help="Open winecfg for the current bottle or prefix").set_defaults(func=cmd_winecfg)

    tricks_cmd = sub.add_parser("winetricks", help="Run winetricks verbs against the bottle")
    tricks_cmd.add_argument("--winetricks", default="winetricks", help="Path to the winetricks executable")
    tricks_cmd.add_argument("--verbs", required=True, help="Comma-separated verbs, for example: vcrun2019,d3dx9")
    tricks_cmd.add_argument("--interactive", action="store_true", help="Run winetricks without -q")
    tricks_cmd.set_defaults(func=cmd_run_winetricks)

    kill_wine_cmd = sub.add_parser("kill-wine", help="Stop Wine processes for one target or every NASE prefix")
    kill_wine_cmd.add_argument(
        "--all-managed",
        action="store_true",
        help="Stop Wine processes across all NASE-managed and tracked prefixes",
    )
    kill_wine_cmd.set_defaults(func=cmd_kill_wine)

    sessions_cmd = sub.add_parser("list-sessions", help="Reconcile and list tracked game launch sessions")
    sessions_cmd.add_argument("--all", action="store_true", help="Include exited and failed sessions")
    sessions_cmd.set_defaults(func=cmd_list_sessions)

    stop_game_cmd = sub.add_parser("stop-game", help="Stop one tracked game session without stopping shared Steam")
    stop_game_cmd.add_argument("--session-id", required=True, help="Launch session id returned by a game launch")
    stop_game_cmd.set_defaults(func=cmd_stop_game)

    dxvk_cmd = sub.add_parser("install-dxvk", help="Install DXVK into the bottle from a local folder or tar.gz")
    dxvk_cmd.add_argument("--dxvk-source", required=True, help="Path to a DXVK directory or tar.gz archive")
    dxvk_cmd.add_argument(
        "--dxvk-flavor",
        choices=("upstream", "macos"),
        default="upstream",
        help="DXVK layout to install (default: upstream)",
    )
    dxvk_cmd.add_argument("--symlink", action="store_true", help="Use symlinks instead of copying DLLs")
    dxvk_cmd.add_argument("--without-dxgi", action="store_true", help="Skip dxgi.dll override")
    dxvk_cmd.set_defaults(func=cmd_install_dxvk)

    dxmt_cmd = sub.add_parser("install-dxmt", help="Install DXMT into the bottle from a local folder or tar.gz")
    dxmt_cmd.add_argument("--dxmt-source", required=True, help="Path to a DXMT directory or tar.gz archive")
    dxmt_cmd.add_argument(
        "--allow-unrecommended-dxmt",
        action="store_true",
        help="Allow DXMT versions outside the validated 0.70/0.71 path, including known-problem versions",
    )
    dxmt_cmd.set_defaults(func=cmd_install_dxmt)

    d3dmetal_cmd = sub.add_parser("install-d3dmetal", help="Install D3DMetal into the bottle from a local folder or tar.gz")
    d3dmetal_cmd.add_argument("--d3dmetal-source", required=True, help="Path to a D3DMetal directory or tar.gz archive")
    d3dmetal_cmd.set_defaults(func=cmd_install_d3dmetal)

    sub.add_parser("list-runtime-catalog", help="List installable Wine and graphics runtimes").set_defaults(
        func=cmd_list_runtime_catalog
    )

    sub.add_parser("list-installed-runtimes", help="List managed runtimes installed by the launcher").set_defaults(
        func=cmd_list_installed_runtimes
    )

    runtime_cmd = sub.add_parser("install-runtime", help="Download, verify, extract, and optionally install a managed runtime")
    runtime_cmd.add_argument("--runtime", required=True, help="Runtime id from list-runtime-catalog")
    runtime_cmd.add_argument(
        "--no-bottle-install",
        action="store_true",
        help="Only download/register the runtime; do not install graphics DLLs into the selected bottle",
    )
    runtime_cmd.set_defaults(func=cmd_install_runtime)

    setup_cmd = sub.add_parser(
        "setup-metal",
        help="Create or reuse a prefix, install Steam via winetricks, install DXMT, and open Steam",
    )
    setup_cmd.add_argument("--dxmt-source", required=True, help="Path to a DXMT directory or tar.gz archive")
    setup_cmd.add_argument(
        "--allow-unrecommended-dxmt",
        action="store_true",
        help="Allow DXMT versions outside the validated 0.70/0.71 path, including known-problem versions",
    )
    setup_cmd.add_argument("--winetricks", default="winetricks", help="Path to the winetricks executable")
    setup_cmd.add_argument("--interactive", action="store_true", help="Run winetricks steam without -q")
    setup_cmd.add_argument("--no-launch", action="store_true", help="Finish setup without opening Steam")
    setup_cmd.add_argument("--no-wait", action="store_true", help="Return immediately after launching Steam")
    setup_cmd.set_defaults(func=cmd_setup_metal)

    wipe_cmd = sub.add_parser("wipe-bottles", help="Delete every bottle under app support")
    wipe_cmd.add_argument("--yes", action="store_true", help="Confirm deletion of all bottles")
    wipe_cmd.set_defaults(func=cmd_wipe_bottles)

    doctor_cmd = sub.add_parser("doctor", help="Check Wine, DXMT, Steam, and manifest health for the target prefix")
    doctor_cmd.add_argument("--winetricks", default="winetricks", help="Path to the winetricks executable")
    doctor_cmd.add_argument("--fix", action="store_true", help="Apply safe fixes, then rerun the checks")
    doctor_cmd.add_argument(
        "--dxmt-source",
        help="Optional DXMT directory or tar.gz archive to reinstall DXMT during --fix",
    )
    doctor_cmd.add_argument(
        "--allow-unrecommended-dxmt",
        action="store_true",
        help="Allow DXMT versions outside the validated 0.70/0.71 path during --fix",
    )
    doctor_cmd.set_defaults(func=cmd_doctor)

    gui_cmd = sub.add_parser("gui", help="Open the simple desktop frontend")
    gui_cmd.add_argument("--no-browser", action="store_true", help="Start the local UI server without opening a browser")
    gui_cmd.set_defaults(func=cmd_gui)

    sub.add_parser("list-games", help="List installed Steam games discovered from manifests").set_defaults(func=cmd_list_games)

    launch_cmd = sub.add_parser("launch-game", help="Launch a Steam game by AppID")
    launch_cmd.add_argument("--appid", required=True, help="Steam AppID")
    launch_cmd.add_argument("--dxmt-source", help="Optional DXMT directory or tar.gz archive to restore DXMT before launch")
    launch_cmd.add_argument("--dxvk-source", help="Optional DXVK directory or tar.gz archive to restore DXVK before launch")
    launch_cmd.add_argument("--dxvk-flavor", choices=("upstream", "macos"), default="upstream")
    launch_cmd.add_argument(
        "--allow-unrecommended-dxmt",
        action="store_true",
        help="Allow DXMT versions outside the validated 0.70/0.71 path before launch",
    )
    launch_cmd.add_argument("--d3dmetal-source", help="Optional D3DMetal directory or tar.gz archive to restore D3DMetal before launch")
    launch_cmd.add_argument("--no-wait", action="store_true", help="Return immediately after sending the launch request")
    launch_cmd.set_defaults(func=cmd_launch_game)

    smart_launch_cmd = sub.add_parser("smart-launch-game", help="Try a direct launch first, then fall back to Steam")
    smart_launch_cmd.add_argument("--appid", required=True, help="Steam AppID")
    smart_launch_cmd.add_argument("--dxmt-source", help="Optional DXMT directory or tar.gz archive to restore DXMT before launch")
    smart_launch_cmd.add_argument(
        "--allow-unrecommended-dxmt",
        action="store_true",
        help="Allow DXMT versions outside the validated 0.70/0.71 path before launch",
    )
    smart_launch_cmd.add_argument("--dxvk-source", help="Optional DXVK directory or tar.gz archive to restore DXVK before launch")
    smart_launch_cmd.add_argument("--dxvk-flavor", choices=("upstream", "macos"), default="upstream")
    smart_launch_cmd.add_argument("--d3dmetal-source", help="Optional D3DMetal directory or tar.gz archive to restore D3DMetal before launch")
    smart_launch_cmd.add_argument("--winetricks", default="winetricks", help="Path to winetricks for first-time hidden D3DMetal setup")
    smart_launch_cmd.add_argument("--probe-seconds", type=int, default=8, help="Seconds to watch the direct launch before considering it healthy")
    smart_launch_cmd.add_argument("--no-wait", action="store_true", help="Return immediately after a healthy launch path is found")
    smart_launch_cmd.set_defaults(func=cmd_smart_launch_game)

    reset_overlay_cmd = sub.add_parser("reset-game-overlay", help="Remove one private per-game compatibility overlay")
    reset_overlay_cmd.add_argument("--game-id", required=True, help="Steam AppID or stable game identifier")
    reset_overlay_cmd.add_argument("--confirm", action="store_true", help="Confirm removal of the overlay")
    reset_overlay_cmd.set_defaults(func=cmd_reset_game_overlay)

    debug_cmd = sub.add_parser("debug-game", help="Launch a game executable directly with Wine debug logging")
    debug_cmd.add_argument("--appid", help="Steam AppID to resolve to an installed game executable")
    debug_cmd.add_argument("--exe", help="Explicit path to a Windows game executable inside the bottle")
    debug_cmd.add_argument("--cwd", help="Optional working directory override")
    debug_cmd.add_argument("--env", action="append", default=[], help="Extra environment override in KEY=VALUE form")
    debug_cmd.add_argument(
        "--legacy-directx-source",
        help="User-provided dgVoodoo2 ZIP or directory used to build a private per-game DirectDraw overlay",
    )
    debug_cmd.add_argument(
        "--ensure-steam",
        action="store_true",
        help="Start Windows Steam in the selected profile before a Steam-backed direct launch",
    )
    debug_cmd.add_argument("--dxmt-source", help="Optional DXMT directory or tar.gz archive to restore DXMT before launch")
    debug_cmd.add_argument(
        "--allow-unrecommended-dxmt",
        action="store_true",
        help="Allow DXMT versions outside the validated 0.70/0.71 path before launch",
    )
    debug_cmd.add_argument("--dxvk-source", help="Optional DXVK directory or tar.gz archive to restore DXVK before launch")
    debug_cmd.add_argument("--dxvk-flavor", choices=("upstream", "macos"), default="upstream")
    debug_cmd.add_argument("--d3dmetal-source", help="Optional D3DMetal directory or tar.gz archive to restore D3DMetal before launch")
    debug_cmd.add_argument("--wine-debug", default="+timestamp,+seh,+loaddll", help="WINEDEBUG value for the direct launch")
    debug_cmd.add_argument("--no-wait", action="store_true", help="Return immediately after launching the executable")
    debug_cmd.add_argument("game_args", nargs=argparse.REMAINDER, help="Arguments passed through to the game after --")
    debug_cmd.set_defaults(func=cmd_debug_game)

    for name, handler, help_text in (
        ("scan-game", cmd_scan_game, "Scan a game folder for dependency markers"),
        ("advise-game", cmd_advise_game, "Recommend winetricks verbs for a game folder"),
    ):
        scan_cmd = sub.add_parser(name, help=help_text)
        scan_cmd.add_argument("--appid", help="Scan a known Steam game by AppID")
        scan_cmd.add_argument("--path", help="Scan an explicit game directory")
        scan_cmd.set_defaults(func=handler)

    return parser


def main() -> None:
    global _JOB_TARGET
    parser = build_parser()
    args = parser.parse_args()
    os.environ.update(managed_gstreamer_environment())

    _JOB_TARGET = {
        "kind": "external-prefix" if getattr(args, "prefix", None) else "managed-bottle",
        "bottle": getattr(args, "bottle", None) or DEFAULT_BOTTLE_NAME,
    }
    if getattr(args, "prefix", None):
        _JOB_TARGET["prefix"] = str(Path(args.prefix).expanduser())
    if getattr(args, "profile", None):
        _JOB_TARGET["profile_id"] = str(args.profile)
    if getattr(args, "appid", None):
        _JOB_TARGET["appid"] = str(args.appid)

    if is_apple_silicon() and not getattr(args, "json", False) and not getattr(args, "jsonl", False):
        print("[Note] You’re on Apple Silicon. Many Wine/Steam setups run under Rosetta 2.")

    args.func(args)
