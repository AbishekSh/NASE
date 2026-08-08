from __future__ import annotations

from dataclasses import dataclass
from concurrent.futures import ThreadPoolExecutor
import fcntl
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from typing import Any, Iterator

from . import DEFAULT_STEAM_WINDOWS_PATH, STEAM_SETUP_URL
from .bottle import Bottle, app_support_root, ensure_bottle_dirs
from .library_activity import acquire_shared_steam_client, release_shared_steam_client
from .runtime import download, run_logged, run_logged_detached, supports_wow64
from .pe import executable_architecture
from .d3dmetal import d3dmetal_launch_environment
from .sessions import ACTIVE_STATUSES, reconcile_sessions, steam_is_running, stop_session


@dataclass(frozen=True)
class SteamApp:
    appid: str
    name: str
    install_dir: Path
    manifest_path: Path
    library_path: Path


def steam_windows_path() -> str:
    return DEFAULT_STEAM_WINDOWS_PATH


def steam_prefix_root(bottle: Bottle) -> Path:
    return bottle.drive_c / "Program Files (x86)" / "Steam"


def steam_setup_exe(bottle: Bottle) -> Path:
    return bottle.downloads / "SteamSetup.exe"


def _wineserver_path(wine_path: Path) -> Path:
    candidate = wine_path.with_name("wineserver")
    if candidate.exists():
        return candidate
    raise FileNotFoundError(f"wineserver not found next to Wine binary: {candidate}")


def _wine_server_dir(prefix: Path) -> Path:
    prefix_stat = prefix.stat()
    return Path("/tmp") / f".wine-{os.getuid()}" / f"server-{prefix_stat.st_dev:x}-{prefix_stat.st_ino:x}"


def _terminate_pids(pids: list[int], *, timeout: float = 3) -> list[int]:
    stopped: list[int] = []
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
            stopped.append(pid)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + timeout
    remaining = list(stopped)
    while remaining and time.monotonic() < deadline:
        next_remaining: list[int] = []
        for pid in remaining:
            try:
                os.kill(pid, 0)
                next_remaining.append(pid)
            except ProcessLookupError:
                pass
        remaining = next_remaining
        if remaining:
            time.sleep(0.1)
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    return stopped


def _terminate_prefix_server_processes(prefix: Path) -> list[int]:
    """Stop Wine clients attached to this prefix, including detached store launchers."""
    if os.name != "posix" or not Path("/usr/sbin/lsof").exists():
        return []
    server_dir = _wine_server_dir(prefix)
    if not server_dir.is_dir():
        return []
    result = subprocess.run(
        ["/usr/sbin/lsof", "-t", "+D", str(server_dir)],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    owned_wine_pids: list[int] = []
    for line in result.stdout.splitlines():
        if not line.strip().isdigit():
            continue
        pid = int(line)
        if pid == os.getpid():
            continue
        process = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "uid=,command="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        ).stdout.strip()
        parts = process.split(maxsplit=1)
        if len(parts) != 2 or not parts[0].isdigit() or int(parts[0]) != os.getuid():
            continue
        command = parts[1].lower()
        if "wine" in command or ".exe" in command:
            owned_wine_pids.append(pid)
    return _terminate_pids(sorted(set(owned_wine_pids)))


def _terminate_stale_macos_wineserver(prefix: Path) -> tuple[bool, str]:
    """Terminate only the wineserver that has this prefix's server directory open."""
    if os.name != "posix" or not Path("/usr/sbin/lsof").exists():
        return False, ""

    server_dir = _wine_server_dir(prefix)
    if not server_dir.is_dir():
        return False, ""

    result = subprocess.run(
        ["/usr/sbin/lsof", "-t", "+D", str(server_dir)],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    candidate_pids = {int(line) for line in result.stdout.splitlines() if line.strip().isdigit()}
    wineserver_pids: list[int] = []
    for pid in sorted(candidate_pids):
        command = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "comm="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        ).stdout.strip()
        if Path(command).name == "wineserver":
            wineserver_pids.append(pid)

    if not wineserver_pids:
        return False, ""

    _terminate_pids(wineserver_pids)
    return True, f"Recovered stale Wine server for this prefix (PID {', '.join(map(str, wineserver_pids))})."


def _terminate_orphaned_prefix_processes(prefix: Path) -> list[int]:
    """Clean up Wine child processes still holding files in one target prefix."""
    if os.name != "posix" or not Path("/usr/sbin/lsof").exists():
        return []
    result = subprocess.run(
        ["/usr/sbin/lsof", "-t", "+D", str(prefix)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    stopped: list[int] = []
    for line in result.stdout.splitlines():
        if not line.strip().isdigit():
            continue
        pid = int(line)
        if pid == os.getpid():
            continue
        process = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "uid=,command="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        ).stdout.strip()
        parts = process.split(maxsplit=1)
        if len(parts) != 2 or not parts[0].isdigit() or int(parts[0]) != os.getuid():
            continue
        command = parts[1]
        if "wine" not in command.lower() and ".exe" not in command.lower():
            continue
        try:
            os.kill(pid, signal.SIGTERM)
            stopped.append(pid)
        except ProcessLookupError:
            pass
    return stopped


def _terminate_managed_prefix(prefix: Path) -> tuple[set[int], bool]:
    """Stop one prefix with a fast server scan and a deep-scan fallback."""
    try:
        stopped = set(_terminate_prefix_server_processes(prefix))
    except (OSError, subprocess.TimeoutExpired):
        stopped = set()
    if stopped:
        return stopped, any("wineserver" in _process_command(pid).lower() for pid in stopped)

    try:
        stopped.update(_terminate_orphaned_prefix_processes(prefix))
    except (OSError, subprocess.TimeoutExpired):
        pass
    if stopped:
        return stopped, False

    try:
        recovered, _ = _terminate_stale_macos_wineserver(prefix)
    except (OSError, subprocess.TimeoutExpired):
        recovered = False
    return stopped, recovered


def _process_command(pid: int) -> str:
    try:
        return subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        ).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def native_macos_steam_is_running() -> bool:
    try:
        result = subprocess.run(
            ["/bin/ps", "ax", "-o", "command="],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except OSError:
        return False
    return any(
        "/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx" in command
        for command in result.stdout.splitlines()
    )


def _graphics_launch_env(
    bottle: Bottle,
    wine_debug: str,
    graphics_backend: str,
    graphics_source: Path | None = None,
) -> dict[str, str]:
    env = {"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": wine_debug}
    if graphics_backend == "dxvk":
        from .dxvk_macos import dxvk_macos_launch_environment

        env["WINEDLLOVERRIDES"] = "d3d11=n;d3d10core=n"
        env.update(dxvk_macos_launch_environment(bottle))
    elif graphics_backend == "dxmt":
        env["WINEDLLOVERRIDES"] = "dxgi=n,b;d3d11=n,b;d3d10core=n,b;winemetal=n,b"
    elif graphics_backend == "d3dmetal":
        env["WINEDLLOVERRIDES"] = "dxgi=n,b;d3d11=n,b;d3d12=n,b;atidxx64=n,b;nvapi64=n,b;nvngx=n,b"
        if graphics_source is None:
            raise RuntimeError("D3DMetal launches require a validated renderer bundle.")
        d3dmetal_env = d3dmetal_launch_environment(graphics_source)
        existing_fallback = os.environ.get("DYLD_FALLBACK_LIBRARY_PATH", "")
        if existing_fallback:
            d3dmetal_env["DYLD_FALLBACK_LIBRARY_PATH"] += ":" + existing_fallback
        env.update(d3dmetal_env)
    return env


def graphics_launch_environment(
    bottle: Bottle,
    graphics_backend: str,
    graphics_source: Path | None = None,
) -> dict[str, str]:
    """Return the complete profile environment for non-Steam store launchers."""
    return _graphics_launch_env(bottle, "-all", graphics_backend, graphics_source)


def steam_core_root() -> Path:
    """Return the single Steam client shared by every compatibility profile."""
    return app_support_root() / "steam-core" / "Steam"


def ensure_shared_steam(bottle: Bottle) -> bool:
    """Point this bottle's Steam directory at the shared client if one already exists.

    Returns True once this bottle has a working Steam install (whether newly
    symlinked or already present), so callers can skip installing Steam here.
    """
    target = steam_prefix_root(bottle)
    core = steam_core_root()
    if target.is_symlink():
        return (core / "Steam.exe").is_file() and target.resolve() == core.resolve()
    if target.is_dir():
        return (target / "Steam.exe").is_file()
    if not (core / "Steam.exe").is_file():
        return False
    target.parent.mkdir(parents=True, exist_ok=True)
    target.symlink_to(core)
    return True


def promote_to_shared_steam(bottle: Bottle) -> None:
    """Make this bottle's freshly installed Steam the shared client for every profile."""
    target = steam_prefix_root(bottle)
    if target.is_symlink() or not (target / "Steam.exe").is_file():
        return
    core = steam_core_root()
    core.parent.mkdir(parents=True, exist_ok=True)
    lock_path = core.parent / ".promotion.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if (core / "Steam.exe").is_file():
            # Another profile promoted its client first; adopt it instead.
            shutil.rmtree(target)
            target.symlink_to(core)
            return
        shutil.move(str(target), str(core))
        target.symlink_to(core)


def install_steam(*, bottle: Bottle, wine64_path: Path) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    if ensure_shared_steam(bottle):
        return 0, "Steam is already installed via the shared client."
    installer = steam_setup_exe(bottle)
    download(STEAM_SETUP_URL, installer)
    code, tail = run_logged(
        cmd=[str(wine64_path), str(installer)],
        env={"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"},
        log_file=bottle.logs / "02_install_steam.log",
    )
    if code == 0:
        promote_to_shared_steam(bottle)
    return code, tail


def run_steam(
    *,
    bottle: Bottle,
    wine64_path: Path,
    steam_path: str | None = None,
    extra_args: list[str] | None = None,
    wait: bool = True,
    extra_env: dict[str, str] | None = None,
    graphics_backend: str = "none",
    restart_existing: bool = True,
    graphics_source: Path | None = None,
) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    ensure_shared_steam(bottle)
    if native_macos_steam_is_running():
        return 1, (
            "macOS Steam is currently running and owns Steam's local communication port. "
            "Choose Steam > Quit Steam in the macOS Steam menu, wait for it to close, then try again. "
            "Closing only the Steam window is not enough."
        )
    try:
        acquire_shared_steam_client(prefix=str(bottle.prefix), bottle=bottle.name)
    except RuntimeError as exc:
        return 1, str(exc)
    wineserver = _wineserver_path(wine64_path)
    env = _graphics_launch_env(bottle, "-all", graphics_backend, graphics_source)
    if extra_env:
        env.update(extra_env)
    open_main = False
    passthrough_args: list[str] = []
    for arg in extra_args or []:
        if arg == "steam://open/main":
            open_main = True
        else:
            passthrough_args.append(arg)

    shutdown_tail = ""
    if restart_existing:
        shutdown_parts: list[str] = []
        shutdown_code, step_tail = run_logged(
            cmd=[str(wine64_path), steam_path or steam_windows_path(), "-shutdown"],
            env=env,
            log_file=bottle.logs / "03_run_steam.log",
            timeout=8,
        )
        if step_tail:
            shutdown_parts.append(step_tail)

        if shutdown_code in (0, 124):
            wait_code, wait_tail = run_logged(
                cmd=[str(wineserver), "-w"],
                env=env,
                log_file=bottle.logs / "03_run_steam.log",
                timeout=8,
            )
            if wait_tail:
                shutdown_parts.append(wait_tail)

            if wait_code == 124:
                kill_code, kill_tail = run_logged(
                    cmd=[str(wineserver), "-k"],
                    env=env,
                    log_file=bottle.logs / "03_run_steam.log",
                    timeout=5,
                )
                if kill_tail:
                    shutdown_parts.append(kill_tail)
                if kill_code == 0:
                    final_wait_code, final_wait_tail = run_logged(
                        cmd=[str(wineserver), "-w"],
                        env=env,
                        log_file=bottle.logs / "03_run_steam.log",
                        timeout=5,
                    )
                    if final_wait_tail:
                        shutdown_parts.append(final_wait_tail)
                    if final_wait_code not in (0, 124):
                        return final_wait_code, "\n".join(shutdown_parts)
                elif kill_code not in (0, 124):
                    return kill_code, "\n".join(shutdown_parts)
            elif wait_code not in (0, 124):
                return wait_code, "\n".join(shutdown_parts)

        shutdown_tail = "\n".join(part for part in shutdown_parts if part)

    args = [str(wine64_path), steam_path or steam_windows_path()]
    if passthrough_args:
        args.extend(passthrough_args)
    if wait:
        code, tail = run_logged(
            cmd=args,
            env=env,
            log_file=bottle.logs / "03_run_steam.log",
        )
    else:
        code, tail = run_logged_detached(
            cmd=args,
            env=env,
            log_file=bottle.logs / "03_run_steam.log",
        )
    if code == 0 and open_main:
        opener = run_logged if wait else run_logged_detached
        open_code, open_tail = opener(
            cmd=[str(wine64_path), "start", "steam://open/main"],
            env=env,
            log_file=bottle.logs / "03_run_steam.log",
        )
        tail = "\n".join(part for part in (shutdown_tail, tail, open_tail) if part)
        code = open_code
    else:
        tail = "\n".join(part for part in (shutdown_tail, tail) if part)
    if code != 0:
        release_shared_steam_client(prefix=str(bottle.prefix))
        return code, tail
    if not wait:
        return code, tail

    wait_code, wait_tail = run_logged(
        cmd=[str(wineserver), "-w"],
        env=env,
        log_file=bottle.logs / "03_run_steam.log",
    )
    release_shared_steam_client(prefix=str(bottle.prefix))
    combined_tail = "\n".join(part for part in (tail, wait_tail) if part)
    return wait_code, combined_tail


def steam_client_is_ready(bottle: Bottle, *, after_offset: int | None = None) -> bool:
    """Return whether the current Steam session reached its logged-on state."""
    connection_log = steam_prefix_root(bottle) / "logs" / "connection_log.txt"
    if not connection_log.is_file():
        return False
    try:
        with connection_log.open("rb") as handle:
            size = handle.seek(0, os.SEEK_END)
            if after_offset is not None:
                handle.seek(after_offset if after_offset <= size else 0)
            else:
                handle.seek(max(0, size - 256 * 1024))
            text = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return False
    logged_on = text.rfind("[Logged On,")
    disconnected = max(
        text.rfind("[Logged Off,"),
        text.rfind("[Logging Off,"),
        text.rfind("Log session ended"),
    )
    return logged_on >= 0 and logged_on > disconnected


def probe_steam_stability(
    *,
    bottle: Bottle,
    wine64_path: Path,
    graphics_source: Path,
    duration_seconds: int = 45,
    graphics_backend: str = "d3dmetal",
) -> tuple[int, str]:
    dumps = steam_prefix_root(bottle) / "dumps"
    bootstrap_log = steam_prefix_root(bottle) / "logs" / "bootstrap_log.txt"
    bootstrap_offset = bootstrap_log.stat().st_size if bootstrap_log.is_file() else 0
    existing_asserts = set(dumps.glob("assert_steam.exe_*.dmp")) if dumps.is_dir() else set()
    code, tail = run_steam(
        bottle=bottle,
        wine64_path=wine64_path,
        extra_args=["-silent"],
        wait=False,
        graphics_backend=graphics_backend,
        restart_existing=True,
        graphics_source=graphics_source,
    )
    if code != 0:
        return code, tail

    # Steam may exit and relaunch several times while replacing its bootstrapper
    # and switching from the legacy 32-bit updater to the current 64-bit client.
    # Require one continuous stable window, but tolerate those updater gaps.
    deadline = time.monotonic() + duration_seconds + 180
    observed = False
    consecutive_running_seconds = 0
    while time.monotonic() < deadline:
        if steam_is_running(str(bottle.prefix)):
            observed = True
            consecutive_running_seconds += 1
            if consecutive_running_seconds >= duration_seconds:
                break
        else:
            consecutive_running_seconds = 0
        time.sleep(1)

    new_asserts = set(dumps.glob("assert_steam.exe_*.dmp")) - existing_asserts if dumps.is_dir() else set()
    if new_asserts:
        names = ", ".join(sorted(path.name for path in new_asserts))
        return 1, f"Steam generated a crash/assert dump during verification: {names}"
    if bootstrap_log.is_file():
        with bootstrap_log.open("r", encoding="utf-8", errors="replace") as handle:
            handle.seek(bootstrap_offset)
            new_bootstrap_log = handle.read()
        fatal_markers = (
            "Error: Saving package",
            "Error: Steam needs to be online to update",
            "Fatal Error",
        )
        matched = next((marker for marker in fatal_markers if marker in new_bootstrap_log), None)
        if matched:
            free_bytes = shutil.disk_usage(bootstrap_log).free
            free_mib = free_bytes // (1024 * 1024)
            disk_hint = (
                f" Only {free_mib} MiB is free; make at least 2 GiB available and retry setup."
                if free_bytes < 2 * 1024**3
                else ""
            )
            return 1, f"Steam updater failed during verification ({matched}).{disk_hint}"
    if not observed or consecutive_running_seconds < duration_seconds or not steam_is_running(str(bottle.prefix)):
        return 1, "Steam did not remain continuously running after its updater restarts."

    environment = _graphics_launch_env(bottle, "-all", graphics_backend, graphics_source)
    shutdown_code, shutdown_tail = run_logged(
        cmd=[str(wine64_path), steam_windows_path(), "-shutdown"],
        env=environment,
        log_file=bottle.logs / f"04_{graphics_backend}_steam_probe.log",
        timeout=15,
    )
    combined = "\n".join(
        part for part in (tail, shutdown_tail, "Steam remained stable for the full probe window.") if part
    )
    return (0 if shutdown_code in (0, 124) else shutdown_code), combined


def kill_wine_processes(
    *,
    bottle: Bottle,
    wine64_path: Path,
) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    wineserver = _wineserver_path(wine64_path)
    env = {"WINEPREFIX": str(bottle.prefix), "WINEDEBUG": "-all"}

    kill_code, kill_tail = run_logged(
        cmd=[str(wineserver), "-k"],
        env=env,
        log_file=bottle.logs / "05_kill_wine.log",
        timeout=8,
    )
    # Wine Stable returns 1 without output both when no server exists and when
    # a stale macOS Mach endpoint prevents it from reaching an existing server.
    if kill_code == 1 and not kill_tail.strip():
        recovered, recovery_message = _terminate_stale_macos_wineserver(bottle.prefix)
        if recovered:
            return 0, recovery_message
        return 0, "No Wine processes were running."
    if kill_code not in (0, 124):
        return kill_code, kill_tail

    wait_code, wait_tail = run_logged(
        cmd=[str(wineserver), "-w"],
        env=env,
        log_file=bottle.logs / "05_kill_wine.log",
        timeout=8,
    )
    orphaned_pids = _terminate_orphaned_prefix_processes(bottle.prefix)
    orphaned_tail = ""
    if orphaned_pids:
        orphaned_tail = f"Stopped orphaned Wine processes for this prefix: {', '.join(map(str, orphaned_pids))}."
    combined_tail = "\n".join(part for part in (kill_tail, wait_tail, orphaned_tail) if part)
    return wait_code, combined_tail


def kill_nase_wine_processes(*, current_bottle: Bottle) -> tuple[int, str, list[str]]:
    """Stop Wine activity owned by NASE across managed and tracked prefixes."""
    prefixes: set[Path] = set()
    managed_root = app_support_root() / "bottles"
    if managed_root.is_dir():
        prefixes.update(
            child / "prefix"
            for child in managed_root.iterdir()
            if child.is_dir() and (child / "prefix").is_dir()
        )
    if current_bottle.prefix.is_dir():
        prefixes.add(current_bottle.prefix)

    sessions = reconcile_sessions()
    active_sessions = [
        session for session in sessions
        if session.get("status") in ACTIVE_STATUSES
    ]
    for session in sessions:
        raw_prefix = str(session.get("prefix") or "").strip()
        if raw_prefix:
            prefix = Path(raw_prefix).expanduser()
            if prefix.is_dir():
                prefixes.add(prefix)

    stopped_session_pids: set[int] = set()
    for session in active_sessions:
        session_id = str(session.get("session_id") or "")
        if not session_id:
            continue
        _, stopped_pids = stop_session(session_id)
        stopped_session_pids.update(stopped_pids)

    sorted_prefixes = sorted(prefixes, key=lambda path: str(path).casefold())
    targets = [str(prefix) for prefix in sorted_prefixes]
    stopped_prefix_pids: set[int] = set()
    recovered_servers = 0
    if sorted_prefixes:
        # Prefix probes can each wait on lsof. Run them concurrently so the
        # emergency stop duration is bounded by the slowest target rather than
        # growing linearly with every compatibility profile.
        with ThreadPoolExecutor(max_workers=min(len(sorted_prefixes), 16)) as executor:
            for stopped, recovered in executor.map(_terminate_managed_prefix, sorted_prefixes):
                stopped_prefix_pids.update(stopped)
                if recovered:
                    recovered_servers += 1

    details = [
        f"Checked {len(targets)} NASE prefix{'es' if len(targets) != 1 else ''}.",
    ]
    stopped_pids = stopped_session_pids | stopped_prefix_pids
    if stopped_pids:
        details.append(f"Stopped {len(stopped_pids)} Wine/game process{'es' if len(stopped_pids) != 1 else ''}.")
    if recovered_servers:
        details.append(f"Stopped {recovered_servers} Wine server{'s' if recovered_servers != 1 else ''}.")
    if not stopped_pids and not recovered_servers:
        details.append("No Wine processes were running.")
    return 0, " ".join(details), targets


def launch_app(
    *,
    bottle: Bottle,
    wine64_path: Path,
    appid: str,
    graphics_backend: str = "dxmt",
    wait: bool = True,
    restart_existing: bool = True,
    graphics_source: Path | None = None,
) -> tuple[int, str]:
    return run_steam(
        bottle=bottle,
        wine64_path=wine64_path,
        steam_path=steam_windows_path(),
        extra_args=["-applaunch", appid],
        wait=wait,
        graphics_backend=graphics_backend,
        restart_existing=restart_existing and graphics_backend != "none",
        graphics_source=graphics_source,
    )


def guess_game_executable(install_dir: Path) -> Path:
    candidates = sorted(install_dir.glob("*.exe"))
    if not candidates:
        raise FileNotFoundError(f"No .exe files found in {install_dir}")

    def rank(path: Path) -> tuple[int, str]:
        name = path.name.lower()
        penalty = 0
        if "crashhandler" in name:
            penalty += 100
        if "unins" in name or "setup" in name or "launcher" in name:
            penalty += 50
        if path.stem.lower() == install_dir.name.lower():
            penalty -= 20
        return penalty, name

    return min(candidates, key=rank)


def run_game_executable(
    *,
    bottle: Bottle,
    wine64_path: Path,
    executable: Path,
    extra_args: list[str] | None = None,
    extra_env: dict[str, str] | None = None,
    cwd: Path | None = None,
    wine_debug: str = "+timestamp,+seh,+loaddll",
    wait: bool = True,
    graphics_backend: str = "dxmt",
    probe_seconds: int = 0,
    graphics_source: Path | None = None,
) -> tuple[int, str]:
    ensure_bottle_dirs(bottle)
    # Keep the caller's lexical path intact. Per-game overlays intentionally use
    # a symlink to the shared executable so wrapper DLLs can live beside that
    # overlay path without modifying the Steam installation. Resolving the
    # symlink here silently bypasses the overlay and Windows searches for DLLs
    # in the original game directory instead.
    exe_path = executable.expanduser().absolute()
    if not exe_path.exists():
        raise FileNotFoundError(f"Game executable not found: {exe_path}")

    architecture = validate_executable_compatibility(
        executable=exe_path,
        wine_path=wine64_path,
        graphics_backend=graphics_backend,
    )

    command = [str(wine64_path), str(exe_path)]
    if extra_args:
        command.extend(extra_args)

    env = _graphics_launch_env(bottle, wine_debug, graphics_backend, graphics_source)
    if architecture == "x86":
        env["NASE_EXECUTABLE_ARCH"] = "x86"
    if extra_env:
        existing_overrides = env.get("WINEDLLOVERRIDES")
        custom_overrides = extra_env.get("WINEDLLOVERRIDES")
        env.update(extra_env)
        if existing_overrides and custom_overrides:
            env["WINEDLLOVERRIDES"] = f"{existing_overrides};{custom_overrides}"

    runner = run_logged if wait else run_logged_detached
    code, tail = runner(
        cmd=command,
        env=env,
        log_file=bottle.logs / "04_debug_game.log",
        cwd=cwd or exe_path.parent,
        probe_seconds=probe_seconds if not wait else 0,
    )
    if code != 0 or not wait:
        return code, tail

    wineserver = _wineserver_path(wine64_path)
    wait_code, wait_tail = run_logged(
        cmd=[str(wineserver), "-w"],
        env=env,
        log_file=bottle.logs / "04_debug_game.log",
    )
    combined_tail = "\n".join(part for part in (tail, wait_tail) if part)
    return wait_code, combined_tail


def validate_executable_compatibility(*, executable: Path, wine_path: Path, graphics_backend: str) -> str:
    architecture = executable_architecture(executable)
    if architecture == "x86":
        if not supports_wow64(wine_path):
            raise RuntimeError(
                "This is a 32-bit Windows application, but the selected Wine runtime does not include WoW64 support. "
                "Choose Wine Stable 11 or repair the selected managed Wine runtime."
            )
        if graphics_backend == "d3dmetal":
            raise RuntimeError(
                "This is a 32-bit Windows application. D3DMetal supports 64-bit Direct3D applications only; "
                "choose DXMT or Plain Wine for this title."
            )
    return architecture


def _tokenize_vdf(text: str) -> Iterator[str]:
    i = 0
    length = len(text)
    while i < length:
        char = text[i]
        if char.isspace():
            i += 1
            continue
        if char == "/" and i + 1 < length and text[i + 1] == "/":
            newline = text.find("\n", i)
            if newline == -1:
                break
            i = newline + 1
            continue
        if char in "{}":
            yield char
            i += 1
            continue
        if char == '"':
            i += 1
            value_chars: list[str] = []
            while i < length:
                current = text[i]
                if current == "\\" and i + 1 < length:
                    value_chars.append(text[i + 1])
                    i += 2
                    continue
                if current == '"':
                    i += 1
                    break
                value_chars.append(current)
                i += 1
            yield "".join(value_chars)
            continue
        start = i
        while i < length and not text[i].isspace() and text[i] not in "{}":
            i += 1
        yield text[start:i]


def parse_vdf_text(text: str) -> dict[str, Any]:
    tokens = list(_tokenize_vdf(text))
    position = 0

    def parse_object() -> dict[str, Any]:
        nonlocal position
        data: dict[str, Any] = {}
        while position < len(tokens):
            token = tokens[position]
            if token == "}":
                position += 1
                break
            key = token
            position += 1
            if position >= len(tokens):
                break
            value_token = tokens[position]
            if value_token == "{":
                position += 1
                data[key] = parse_object()
            else:
                data[key] = value_token
                position += 1
        return data

    return parse_object()


def parse_vdf_file(path: Path) -> dict[str, Any]:
    return parse_vdf_text(path.read_text(encoding="utf-8", errors="replace"))


def wine_path_to_host(bottle: Bottle, raw_path: str) -> Path:
    normalized = raw_path.replace("\\\\", "\\")
    if len(normalized) >= 2 and normalized[1] == ":":
        drive = normalized[0].lower()
        suffix = normalized[2:].lstrip("\\/")
        parts = [part for part in suffix.replace("\\", "/").split("/") if part]
        if drive == "c":
            return bottle.drive_c.joinpath(*parts)
        if drive == "z":
            return Path("/").joinpath(*parts)
        return bottle.prefix / "dosdevices" / f"{drive}:" / Path(*parts)
    return Path(normalized.replace("\\", "/")).expanduser()


def steamapps_dirs(bottle: Bottle) -> list[Path]:
    primary = steam_prefix_root(bottle) / "steamapps"
    library_file = primary / "libraryfolders.vdf"
    libraries = [primary]
    if not library_file.exists():
        return libraries

    parsed = parse_vdf_file(library_file)
    root = parsed.get("libraryfolders", parsed)
    if not isinstance(root, dict):
        return libraries

    for value in root.values():
        if isinstance(value, dict):
            raw_path = value.get("path")
            if raw_path:
                path = wine_path_to_host(bottle, str(raw_path))
                libraries.append(path / "steamapps")
    unique: list[Path] = []
    seen: set[Path] = set()
    for path in libraries:
        normalized = path.resolve() if path.exists() else path
        if normalized in seen:
            continue
        seen.add(normalized)
        unique.append(path)
    return unique


def list_installed_apps(bottle: Bottle) -> list[SteamApp]:
    apps: list[SteamApp] = []
    for steamapps in steamapps_dirs(bottle):
        if not steamapps.exists():
            continue
        for manifest in sorted(steamapps.glob("appmanifest_*.acf")):
            parsed = parse_vdf_file(manifest)
            app_state = parsed.get("AppState", parsed)
            appid = str(app_state.get("appid", manifest.stem.replace("appmanifest_", "")))
            name = str(app_state.get("name", appid))
            install_dir_name = str(app_state.get("installdir", name))
            apps.append(
                SteamApp(
                    appid=appid,
                    name=name,
                    install_dir=steamapps / "common" / install_dir_name,
                    manifest_path=manifest,
                    library_path=steamapps.parent,
                )
            )
    return apps


def find_app(bottle: Bottle, appid: str) -> SteamApp:
    for app in list_installed_apps(bottle):
        if app.appid == appid:
            return app
    raise FileNotFoundError(f"Steam app not found for AppID {appid}")
