from __future__ import annotations

import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time
import uuid
from typing import Any

from .bottle import Bottle, app_support_root
from .library_activity import reconcile_shared_steam_client
from .state_files import atomic_write_json, exclusive_lock


ACTIVE_STATUSES = {"launching", "running", "stopping"}
LAUNCH_GRACE_SECONDS = 45
# Steam may update the game, sync Cloud saves, or show a prompt before it
# starts the game, so a launch handed to Steam waits longer while Steam runs.
STEAM_HANDOFF_GRACE_SECONDS = 600
STEAM_HANDOFF_STRATEGIES = {"steam", "steam-fallback"}
_STEAM_PROCESS_PATTERN = re.compile(r"(?:^|/)steam(?:\.exe)?(?:\s|$)")
PROCESS_EXIT_GRACE_SECONDS = 3
STEAM_CLEANUP_GRACE_SECONDS = 60
STEAM_CLOUD_QUIET_SECONDS = 30


def _registry_path() -> Path:
    return app_support_root() / "sessions.json"


def _load() -> list[dict[str, Any]]:
    path = _registry_path()
    if not path.exists():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    sessions = payload.get("sessions", []) if isinstance(payload, dict) else []
    return [item for item in sessions if isinstance(item, dict)]


def _save(sessions: list[dict[str, Any]]) -> None:
    atomic_write_json(_registry_path(), {"sessions": sessions})


def _registry_lock():
    # Every load-modify-save of the registry must hold this lock: launches,
    # stops, and the app's session poll all run in separate processes.
    return exclusive_lock(_registry_path().with_suffix(".lock"))


def _processes() -> dict[int, str] | None:
    """Return live user processes, or None when the process table is unreadable.

    Callers must treat None as "unknown", never as "nothing is running": a
    timed-out or failed `ps` must not be allowed to fabricate a game exit.
    """
    try:
        result = subprocess.run(
            ["/bin/ps", "ax", "-o", "pid=,uid=,stat=,command="],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return None
    processes: dict[int, str] = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=3)
        if len(parts) != 4 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        if int(parts[1]) == os.getuid() and not parts[2].startswith("Z"):
            processes[int(parts[0])] = parts[3]
    return processes


def _prefix_pids(prefix: str) -> set[int]:
    """Return PIDs holding a file inside the prefix.

    `lsof -t +D` walks the whole prefix and can exceed its timeout on a large
    Steam library. That is not fatal: an empty set degrades to the same
    behaviour as a host without lsof, where exact install-directory and
    executable path matches still identify the game.
    """
    prefix_path = Path(prefix)
    if not prefix_path.is_dir() or not Path("/usr/sbin/lsof").exists():
        return set()
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-t", "+D", str(prefix_path)],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (subprocess.SubprocessError, OSError):
        return set()
    return {int(line) for line in result.stdout.splitlines() if line.strip().isdigit()}


def _steam_in_prefix(processes: dict[int, str], prefix_pids: set[int]) -> bool:
    return any(
        _STEAM_PROCESS_PATTERN.search(processes.get(pid, "").replace("\\", "/").lower())
        for pid in prefix_pids
    )


def steam_is_running(prefix: str) -> bool:
    processes = _processes()
    if processes is None:
        return False
    return _steam_in_prefix(processes, _prefix_pids(prefix))


def _steam_has_active_work(prefix: str) -> bool:
    steam_root = Path(prefix) / "drive_c" / "Program Files (x86)" / "Steam"
    steamapps = steam_root / "steamapps"
    recent_cutoff = time.time() - 300
    for directory_name in ("downloading", "temp"):
        directory = steamapps / directory_name
        try:
            if not directory.is_dir():
                continue
            for index, path in enumerate(directory.rglob("*")):
                if index >= 500:
                    return True
                if path.is_file() and path.stat().st_mtime >= recent_cutoff:
                    return True
        except OSError:
            return True
    cloud_log = steam_root / "logs" / "cloud_log.txt"
    try:
        if cloud_log.is_file() and cloud_log.stat().st_mtime >= time.time() - STEAM_CLOUD_QUIET_SECONDS:
            return True
    except OSError:
        return True
    return False


def _request_steam_shutdown(session: dict[str, Any]) -> bool:
    wine_path = str(session.get("wine_path") or "")
    prefix = str(session.get("prefix") or "")
    if not wine_path or not prefix:
        return False
    steam_path = r"C:\Program Files (x86)\Steam\Steam.exe"
    try:
        subprocess.Popen(
            [wine_path, steam_path, "-shutdown"],
            env={**os.environ, "WINEPREFIX": prefix, "WINEDEBUG": "-all"},
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError:
        return False
    return True


def _matching_pids(
    session: dict[str, Any],
    processes: dict[int, str],
    prefix_pids: set[int] | None = None,
) -> list[int]:
    executable = str(session.get("executable") or "").replace("\\", "/")
    executable_name = Path(executable).name.lower()
    install_dir = str(session.get("install_dir") or "").replace("\\", "/")
    install_name = Path(install_dir).name.lower()
    known = {int(pid) for pid in session.get("pids", []) if str(pid).isdigit()}
    allowed = prefix_pids if prefix_pids is not None else _prefix_pids(str(session.get("prefix") or ""))
    matches: set[int] = {pid for pid in known if pid in processes and pid in allowed}

    for pid, command in processes.items():
        normalized = command.replace("\\", "/").lower()
        executable_pattern = rf"(?:^|/){re.escape(executable_name)}(?:\s|$)" if executable_name else None
        executable_path_pattern = (
            rf"(?:^|/){re.escape(install_name)}/{re.escape(executable_name)}(?:\s|$)"
            if install_name and executable_name
            else None
        )
        # Steam games live on C:, but Epic/GOG installs sit in a shared host
        # library that Wine maps to another drive letter, so match any drive.
        install_pattern = rf"^[a-z]:/.*?/{re.escape(install_name)}/" if install_name else None
        exact_path_match = bool(executable_path_pattern and re.search(executable_path_pattern, normalized))
        prefix_bound_name_match = bool(
            pid in allowed and executable_pattern and re.search(executable_pattern, normalized)
        )
        # Wine clients do not reliably retain an open file inside WINEPREFIX,
        # especially after Steam hands control to the game. Match the recorded
        # install-directory/executable tail without lsof, but require prefix
        # ownership for a basename-only match so an unrelated process with a
        # common name (for example game.exe) cannot keep this session alive.
        if exact_path_match or prefix_bound_name_match:
            matches.add(pid)
        elif pid in allowed and install_pattern and re.search(install_pattern, normalized) and ".exe" in normalized:
            matches.add(pid)
    return sorted(matches)


def create_session(
    *,
    bottle: Bottle,
    appid: str | None,
    game: str,
    executable: Path | None,
    install_dir: Path | None,
    graphics_backend: str,
    strategy: str,
    profile_id: str | None = None,
    wine_path: Path | None = None,
    steam_started_by_nase: bool = False,
    steam_was_running: bool = False,
    library_id: str | None = None,
) -> dict[str, Any]:
    now = time.time()
    session = {
        "session_id": f"launch_{uuid.uuid4().hex}",
        "appid": appid,
        "game": game,
        "status": "launching",
        "strategy": strategy,
        "graphics_backend": graphics_backend,
        "profile_id": profile_id or f"{graphics_backend}-unversioned",
        "bottle": bottle.name,
        "prefix": str(bottle.prefix),
        "executable": str(executable) if executable else None,
        "install_dir": str(install_dir) if install_dir else None,
        "library_id": library_id,
        "pids": [],
        "started_at": now,
        "updated_at": now,
        "last_seen_at": None,
        "message": "Launch request started.",
        "wine_path": str(wine_path) if wine_path else None,
        "steam_started_by_nase": steam_started_by_nase,
        "steam_was_running": steam_was_running,
        "steam_cleanup_after": None,
        "steam_cleanup_status": "not-owned" if not steam_started_by_nase else "pending",
    }
    with _registry_lock():
        sessions = _load()
        for item in sessions:
            if item.get("status") in ACTIVE_STATUSES and appid and item.get("appid") == appid and item.get("prefix") == str(bottle.prefix):
                item["status"] = "exited"
                item["updated_at"] = now
                item["message"] = "Superseded by a newer launch request."
        sessions.append(session)
        _save(sessions[-200:])
    return session


def update_session(session_id: str, **changes: Any) -> dict[str, Any] | None:
    with _registry_lock():
        sessions = _load()
        updated = None
        for session in sessions:
            if session.get("session_id") == session_id:
                session.update(changes)
                session["updated_at"] = time.time()
                updated = session
                break
        _save(sessions)
    return updated


def mark_steam_opened_by_user(prefix: str) -> None:
    """Relinquish automatic cleanup when the user explicitly opens Steam."""
    with _registry_lock():
        sessions = _load()
        changed = False
        for session in sessions:
            if session.get("prefix") != prefix or not session.get("steam_started_by_nase"):
                continue
            if session.get("status") not in ACTIVE_STATUSES and session.get("steam_cleanup_status") != "pending":
                continue
            session["steam_started_by_nase"] = False
            session["steam_cleanup_after"] = None
            session["steam_cleanup_status"] = "user-owned"
            session["updated_at"] = time.time()
            changed = True
        if changed:
            _save(sessions)


def _merge_reconciled(
    reconciled: list[dict[str, Any]],
    loaded_versions: dict[str, Any],
    changed_ids: set[str],
) -> list[dict[str, Any]]:
    """Save reconciled sessions without discarding concurrent writes.

    Process inspection runs without the registry lock because lsof can take
    seconds. Only sessions this pass changed are written back, and only when no
    other process updated them meanwhile; sessions created during the pass are
    kept. A skipped session is settled by the next reconcile.
    """
    by_id = {str(item.get("session_id")): item for item in reconciled if str(item.get("session_id")) in changed_ids}
    with _registry_lock():
        current = _load()
        merged = []
        for item in current:
            session_id = str(item.get("session_id"))
            if session_id in by_id and item.get("updated_at") == loaded_versions.get(session_id):
                merged.append(by_id[session_id])
            else:
                merged.append(item)
        _save(merged)
    return merged


def _clean_up_finished_steam_sessions(now: float) -> list[dict[str, Any]]:
    """Close Steam instances NASE started once their game has finished.

    This holds the registry lock so a game launching into the same prefix
    cannot be registered between the active-prefix check and the shutdown.
    """
    with _registry_lock():
        sessions = _load()
        active_prefixes = {
            str(item.get("prefix") or "")
            for item in sessions
            if item.get("status") in ACTIVE_STATUSES
        }
        changed = False
        for session in sessions:
            cleanup_after = session.get("steam_cleanup_after")
            if (
                not session.get("steam_started_by_nase")
                or session.get("steam_cleanup_status") != "pending"
                or not isinstance(cleanup_after, (int, float))
                or now < cleanup_after
            ):
                continue
            prefix = str(session.get("prefix") or "")
            if prefix in active_prefixes:
                continue
            if _steam_has_active_work(prefix):
                session["steam_cleanup_after"] = now + 30
                session["message"] = "Game exited; waiting for Steam downloads or Cloud sync to finish."
            elif not steam_is_running(prefix):
                session["steam_cleanup_status"] = "already-closed"
            elif _request_steam_shutdown(session):
                session["steam_cleanup_status"] = "shutdown-requested"
                session["message"] = "Game exited; closing the Steam session started by NASE."
            else:
                session["steam_cleanup_status"] = "shutdown-failed"
                session["message"] = "Game exited; Steam could not be closed automatically."
            session["updated_at"] = now
            changed = True
        if changed:
            _save(sessions)
    return sessions


def _steam_cleanup_is_due(sessions: list[dict[str, Any]], now: float) -> bool:
    return any(
        session.get("steam_started_by_nase")
        and session.get("steam_cleanup_status") == "pending"
        and isinstance(session.get("steam_cleanup_after"), (int, float))
        and now >= session["steam_cleanup_after"]
        for session in sessions
    )


def reconcile_sessions() -> list[dict[str, Any]]:
    reconcile_shared_steam_client()
    sessions = _load()
    processes = _processes()
    if processes is None:
        # The process table could not be read. Report the sessions unchanged
        # rather than guessing; the next reconcile will settle them.
        return sessions
    loaded_versions = {str(item.get("session_id")): item.get("updated_at") for item in sessions}
    now = time.time()
    changed_ids: set[str] = set()
    prefix_cache: dict[str, set[int]] = {}
    for session in sessions:
        if session.get("status") not in ACTIVE_STATUSES:
            continue
        prefix = str(session.get("prefix") or "")
        if prefix not in prefix_cache:
            prefix_cache[prefix] = _prefix_pids(prefix)
        pids = _matching_pids(session, processes, prefix_cache[prefix])
        if pids:
            session["pids"] = pids
            session["status"] = "running"
            session["last_seen_at"] = now
            session["updated_at"] = now
            session["message"] = "Game process is running."
            changed_ids.add(str(session.get("session_id")))
        else:
            last_seen_at = session.get("last_seen_at")
            launch_age = now - float(session.get("started_at") or now)
            launch_grace_expired = launch_age >= LAUNCH_GRACE_SECONDS
            exit_grace_expired = isinstance(last_seen_at, (int, float)) and now - last_seen_at >= PROCESS_EXIT_GRACE_SECONDS
            if not launch_grace_expired and not exit_grace_expired:
                continue
            if (
                last_seen_at is None
                and session.get("strategy") in STEAM_HANDOFF_STRATEGIES
                and launch_age < STEAM_HANDOFF_GRACE_SECONDS
                and _steam_in_prefix(processes, prefix_cache[prefix])
            ):
                message = (
                    "Steam is updating the game before it starts."
                    if _steam_has_active_work(prefix)
                    else "Waiting for Steam to start the game."
                )
                if session.get("message") != message:
                    session["message"] = message
                    session["updated_at"] = now
                    changed_ids.add(str(session.get("session_id")))
                continue
            session["pids"] = []
            session["status"] = "exited"
            session["updated_at"] = now
            if last_seen_at is None:
                session["message"] = "Game process was not detected; Steam was left open for sign-in or setup."
                session["steam_cleanup_after"] = None
                if session.get("steam_started_by_nase"):
                    session["steam_cleanup_status"] = "launch-not-observed"
            else:
                session["message"] = "Game exited; allowing Steam Cloud to finish syncing."
            if last_seen_at is not None and session.get("steam_started_by_nase"):
                session["steam_cleanup_after"] = now + STEAM_CLEANUP_GRACE_SECONDS
            changed_ids.add(str(session.get("session_id")))

    if changed_ids:
        sessions = _merge_reconciled(sessions, loaded_versions, changed_ids)
    if _steam_cleanup_is_due(sessions, now):
        sessions = _clean_up_finished_steam_sessions(now)
    return sessions


def stop_session(session_id: str, *, force: bool = False) -> tuple[dict[str, Any] | None, list[int]]:
    sessions = reconcile_sessions()
    session = next((item for item in sessions if item.get("session_id") == session_id), None)
    if session is None:
        return None, []
    if session.get("status") not in ACTIVE_STATUSES:
        return session, []

    processes = _processes()
    if processes is None:
        return session, []
    pids = _matching_pids(session, processes, _prefix_pids(str(session.get("prefix") or "")))
    update_session(session_id, status="stopping", message="Stopping game processes.")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
        except ProcessLookupError:
            pass

    deadline = time.monotonic() + 5
    remaining = list(pids)
    while remaining and time.monotonic() < deadline:
        time.sleep(0.1)
        live = _processes()
        if live is None:
            break
        remaining = [pid for pid in remaining if pid in live]
    if remaining:
        pending = update_session(
            session_id,
            status="stopping",
            pids=remaining,
            message="The game is still running." if force else "The game didn't respond to Stop. You can force quit it.",
        )
        return pending, [pid for pid in pids if pid not in remaining]

    stopped = update_session(
        session_id,
        status="exited",
        pids=[],
        message="Stopped by user." if pids else "No matching game processes were running.",
        steam_cleanup_after=time.time() + STEAM_CLEANUP_GRACE_SECONDS if session.get("steam_started_by_nase") else None,
    )
    return stopped, pids
