from __future__ import annotations

import os
import platform
import re
import signal
import shutil
import subprocess
import sys
import time
import urllib.request
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple


SANITIZED_METAL_ENV_KEYS = (
    "MTL_DEBUG_LAYER",
    "MTL_SHADER_VALIDATION",
    "MTL_SHADER_VALIDATION_REPORT_TO_STDERR",
    "MTL_HUD_ENABLED",
    "METAL_DEVICE_WRAPPER_TYPE",
    "METAL_CAPTURE_ENABLED",
    "METAL_DEBUG_ERROR_MODE",
    "DYLD_INSERT_LIBRARIES",
)


def ensure_dirs(*paths: Path) -> None:
    for path in paths:
        path.mkdir(parents=True, exist_ok=True)


def is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine() in ("arm64", "aarch64")


def check_executable(path: Path, label: str) -> None:
    if not path.exists():
        raise FileNotFoundError(f"{label} not found: {path}")
    if not os.access(path, os.X_OK):
        raise PermissionError(f"{label} is not executable: {path}")


def resolve_executable(path_or_name: str, label: str) -> Path:
    candidate = Path(path_or_name).expanduser()
    if candidate.is_absolute() or "/" in path_or_name:
        resolved = candidate.resolve()
    else:
        found = shutil.which(path_or_name)
        if not found:
            raise FileNotFoundError(f"{label} not found in PATH: {path_or_name}")
        resolved = Path(found).resolve()
    check_executable(resolved, label)
    return resolved


def resolve_with_fallback(path_or_name: str, label: str, fallback_names: tuple[str, ...]) -> Path:
    try:
        return resolve_executable(path_or_name, label)
    except FileNotFoundError:
        original = Path(path_or_name).expanduser()
        candidates: list[str] = []

        if original.name:
            for fallback in fallback_names:
                if original.is_absolute() or "/" in path_or_name:
                    candidates.append(str(original.with_name(fallback)))
                else:
                    candidates.append(fallback)

        for candidate in candidates:
            try:
                return resolve_executable(candidate, label)
            except FileNotFoundError:
                continue

        raise


def download(url: str, dest: Path) -> None:
    ensure_dirs(dest.parent)
    if dest.exists() and dest.stat().st_size > 0:
        return
    print(f"Downloading {url} -> {dest}")
    with urllib.request.urlopen(url) as response, dest.open("wb") as handle:
        shutil.copyfileobj(response, handle)


def detect_wine_runtime(wine_path: Path) -> dict[str, str | bool | None]:
    resolved = wine_path.resolve()
    app_name = None
    for ancestor in resolved.parents:
        if ancestor.name.endswith(".app"):
            app_name = ancestor.name
            break

    version_output = None
    version = None
    try:
        proc = subprocess.run(
            [str(resolved), "--version"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=15,
            check=False,
        )
        version_output = (proc.stdout or "").strip()
        match = re.search(r"wine-([0-9]+(?:\.[0-9]+)*)", version_output)
        if match:
            version = match.group(1)
    except Exception:
        version_output = None

    is_stable_app = app_name == "Wine Stable.app"
    is_stable_11 = is_stable_app and (version == "11.0" or version is None)

    return {
        "path": str(resolved),
        "app_name": app_name,
        "version_output": version_output,
        "version": version,
        "is_stable_app": is_stable_app,
        "is_stable_11": is_stable_11,
    }


def find_wine_module_root(wine_path: Path) -> Path | None:
    resolved = wine_path.resolve()
    for ancestor in resolved.parents:
        candidate = ancestor / "lib" / "wine"
        if candidate.is_dir():
            return candidate
    return None


def supports_wow64(wine_path: Path) -> bool:
    module_root = find_wine_module_root(wine_path)
    return bool(
        module_root
        and (module_root / "i386-windows" / "ntdll.dll").is_file()
        and (module_root / "x86_64-windows" / "ntdll.dll").is_file()
    )


def run_logged(
    *,
    cmd: Iterable[str],
    env: Optional[Dict[str, str]],
    log_file: Path,
    cwd: Optional[Path] = None,
    timeout: Optional[int] = None,
) -> Tuple[int, str]:
    ensure_dirs(log_file.parent)

    command = [str(part) for part in cmd]
    merged_env = os.environ.copy()
    for key in SANITIZED_METAL_ENV_KEYS:
        merged_env.pop(key, None)
    if env:
        merged_env.update(env)

    tail_lines: list[str] = []
    tail_max = 200
    exit_code = 1

    with log_file.open("a", encoding="utf-8") as handle:
        handle.write("\n" + "=" * 80 + "\n")
        handle.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] RUN: {' '.join(command)}\n")
        if env:
            for key in ("WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES"):
                if env.get(key):
                    handle.write(f"ENV {key}={env[key]}\n")
        handle.flush()

        proc = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=merged_env,
            cwd=str(cwd) if cwd else None,
            text=True,
            bufsize=1,
            universal_newlines=True,
            start_new_session=timeout is not None,
        )

        try:
            assert proc.stdout is not None
            if timeout is not None:
                output, _ = proc.communicate(timeout=timeout)
                for line in (output or "").splitlines():
                    sys.stdout.write(line + "\n")
                    handle.write(line + "\n")
                    tail_lines.append(line)
                    if len(tail_lines) > tail_max:
                        tail_lines.pop(0)
                handle.flush()
                exit_code = proc.returncode if proc.returncode is not None else 0
            else:
                for line in proc.stdout:
                    sys.stdout.write(line)
                    handle.write(line)
                    handle.flush()

                    tail_lines.append(line.rstrip("\n"))
                    if len(tail_lines) > tail_max:
                        tail_lines.pop(0)

                exit_code = proc.wait()
        except subprocess.TimeoutExpired:
            if timeout is not None:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    try:
                        proc.kill()
                    except ProcessLookupError:
                        pass
            else:
                proc.kill()
            try:
                output, _ = proc.communicate(timeout=1)
            except subprocess.TimeoutExpired:
                output = ""
            for line in (output or "").splitlines():
                sys.stdout.write(line + "\n")
                handle.write(line + "\n")
                tail_lines.append(line)
                if len(tail_lines) > tail_max:
                    tail_lines.pop(0)
            exit_code = 124
            message = f"\n[Timeout] Process exceeded {timeout}s and was killed.\n"
            sys.stdout.write(message)
            handle.write(message)
        finally:
            handle.write(f"\n[{time.strftime('%Y-%m-%d %H:%M:%S')}] EXIT: {exit_code}\n")
            handle.flush()

    return exit_code, "\n".join(tail_lines[-50:])


def run_logged_detached(
    *,
    cmd: Iterable[str],
    env: Optional[Dict[str, str]],
    log_file: Path,
    cwd: Optional[Path] = None,
    probe_seconds: int = 0,
) -> Tuple[int, str]:
    ensure_dirs(log_file.parent)

    command = [str(part) for part in cmd]
    merged_env = os.environ.copy()
    for key in SANITIZED_METAL_ENV_KEYS:
        merged_env.pop(key, None)
    if env:
        merged_env.update(env)

    with log_file.open("a", encoding="utf-8") as handle:
        handle.write("\n" + "=" * 80 + "\n")
        handle.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] SPAWN: {' '.join(command)}\n")
        if env:
            for key in ("WINEPREFIX", "WINEDEBUG", "WINEDLLOVERRIDES"):
                if env.get(key):
                    handle.write(f"ENV {key}={env[key]}\n")
        handle.flush()

        proc = subprocess.Popen(
            command,
            stdout=handle,
            stderr=subprocess.STDOUT,
            env=merged_env,
            cwd=str(cwd) if cwd else None,
            text=True,
            start_new_session=True,
        )

        handle.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] PID: {proc.pid}\n")
        handle.flush()

        if probe_seconds > 0:
            deadline = time.time() + probe_seconds
            while time.time() < deadline:
                exit_code = proc.poll()
                if exit_code is not None:
                    handle.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] EARLY EXIT: {exit_code}\n")
                    handle.flush()
                    return exit_code, f"Process exited within {probe_seconds}s (exit {exit_code})"
                time.sleep(0.5)

    return 0, f"Spawned PID {proc.pid}"
