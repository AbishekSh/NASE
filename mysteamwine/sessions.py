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


ACTIVE_STATUSES = {"launching", "running", "stopping"}
LAUNCH_GRACE_SECONDS = 45
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
    path = _registry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps({"sessions": sessions}, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def _processes() -> dict[int, str]:
    result = subprocess.run(
        ["/bin/ps", "ax", "-o", "pid=,uid=,stat=,command="],
        capture_output=True,
        text=True,
        timeout=5,
        check=False,
    )
    processes: dict[int, str] = {}
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=3)
        if len(parts) != 4 or not parts[0].isdigit() or not parts[1].isdigit():
            continue
        if int(parts[1]) == os.getuid() and not parts[2].startswith("Z"):
            processes[int(parts[0])] = parts[3]
    return processes


def _prefix_pids(prefix: str) -> set[int]:
    prefix_path = Path(prefix)
    if not prefix_path.is_dir() or not Path("/usr/sbin/lsof").exists():
        return set()
    result = subprocess.run(
        ["/usr/sbin/lsof", "-t", "+D", str(prefix_path)],
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    return {int(line) for line in result.stdout.splitlines() if line.strip().isdigit()}


def steam_is_running(prefix: str) -> bool:
    processes = _processes()
    for pid in _prefix_pids(prefix):
        command = processes.get(pid, "").replace("\\", "/").lower()
        if re.search(r"(?:^|/)steam(?:\.exe)?(?:\s|$)", command):
            return True
    return False


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
        if pid not in allowed:
            continue
        normalized = command.replace("\\", "/").lower()
        executable_pattern = rf"(?:^|/){re.escape(executable_name)}(?:\s|$)" if executable_name else None
        install_pattern = rf"^c:/.*?/{re.escape(install_name)}/" if install_name else None
        if executable_pattern and re.search(executable_pattern, normalized):
            matches.add(pid)
        elif install_pattern and re.search(install_pattern, normalized) and ".exe" in normalized:
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


def reconcile_sessions() -> list[dict[str, Any]]:
    sessions = _load()
    processes = _processes()
    now = time.time()
    changed = False
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
            changed = True
        else:
            last_seen_at = session.get("last_seen_at")
            launch_grace_expired = now - float(session.get("started_at") or now) >= LAUNCH_GRACE_SECONDS
            exit_grace_expired = isinstance(last_seen_at, (int, float)) and now - last_seen_at >= PROCESS_EXIT_GRACE_SECONDS
            if not launch_grace_expired and not exit_grace_expired:
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
            changed = True

    active_prefixes = {
        str(item.get("prefix") or "")
        for item in sessions
        if item.get("status") in ACTIVE_STATUSES
    }
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


def stop_session(session_id: str) -> tuple[dict[str, Any] | None, list[int]]:
    sessions = reconcile_sessions()
    session = next((item for item in sessions if item.get("session_id") == session_id), None)
    if session is None:
        return None, []
    if session.get("status") not in ACTIVE_STATUSES:
        return session, []

    processes = _processes()
    pids = _matching_pids(session, processes, _prefix_pids(str(session.get("prefix") or "")))
    update_session(session_id, status="stopping", message="Stopping game processes.")
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass

    deadline = time.monotonic() + 5
    remaining = list(pids)
    while remaining and time.monotonic() < deadline:
        time.sleep(0.1)
        live = _processes()
        remaining = [pid for pid in remaining if pid in live]
    for pid in remaining:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    stopped = update_session(
        session_id,
        status="exited",
        pids=[],
        message="Stopped by user." if pids else "No matching game processes were running.",
        steam_cleanup_after=time.time() + STEAM_CLEANUP_GRACE_SECONDS if session.get("steam_started_by_nase") else None,
    )
    return stopped, pids
