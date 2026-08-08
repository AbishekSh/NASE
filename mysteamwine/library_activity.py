from __future__ import annotations

import fcntl
import json
from pathlib import Path
import time
from typing import Any

from .bottle import app_support_root


SCHEMA_VERSION = 1
LAUNCH_RESERVATION_SECONDS = 60


def activity_path() -> Path:
    return app_support_root() / "steam-library-activity.json"


def _read(path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"schema_version": SCHEMA_VERSION, "owners": {}}
    if not isinstance(payload, dict) or not isinstance(payload.get("owners"), dict):
        return {"schema_version": SCHEMA_VERSION, "owners": {}}
    return payload


def _write(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def acquire_steam_activity(*, library_id: str, prefix: str, bottle: str, profile_id: str, appid: str) -> dict[str, Any]:
    """Exclusively assign one library's Windows Steam activity to one prefix."""
    if not library_id:
        raise RuntimeError("The game's Steam library could not be identified.")
    path = activity_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        payload = _read(path)
        owners = payload["owners"]
        current = owners.get(library_id)
        if current and current.get("prefix") != prefix:
            # Import lazily to avoid making process/session ownership a module cycle.
            from .sessions import steam_is_running

            recently_reserved = time.time() - float(current.get("updated_at") or 0) < LAUNCH_RESERVATION_SECONDS
            if recently_reserved or steam_is_running(str(current.get("prefix") or "")):
                owner = current.get("bottle") or current.get("profile_id") or "another profile"
                raise RuntimeError(
                    f"Shared Steam library is currently owned by {owner}. Close that Steam instance before launching through this profile."
                )
        now = time.time()
        owner = {
            "library_id": library_id,
            "prefix": prefix,
            "bottle": bottle,
            "profile_id": profile_id,
            "active_appids": sorted(set((current or {}).get("active_appids", [])) | {str(appid)}),
            "acquired_at": (current or {}).get("acquired_at", now) if (current or {}).get("prefix") == prefix else now,
            "updated_at": now,
        }
        owners[library_id] = owner
        _write(path, payload)
        return owner


def release_steam_activity(*, library_id: str, prefix: str) -> None:
    if not library_id:
        return
    path = activity_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        payload = _read(path)
        current = payload["owners"].get(library_id)
        if current and current.get("prefix") == prefix:
            del payload["owners"][library_id]
            _write(path, payload)


CLIENT_RESERVATION_GRACE_SECONDS = 60


def acquire_shared_steam_client(*, prefix: str, bottle: str) -> None:
    """Exclusively assign the one shared Steam client to a single prefix.

    Steam launches are detached, so this reservation must outlive the CLI
    process that acquires it. reconcile_shared_steam_client() is what renews
    it while Steam is observed running and expires it once Steam is gone.
    """
    path = activity_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        payload = _read(path)
        current = payload.get("client_owner")
        now = time.time()
        if current and current.get("prefix") != prefix:
            from .sessions import steam_is_running

            recently_active = now - float(current.get("updated_at") or 0) < CLIENT_RESERVATION_GRACE_SECONDS
            if recently_active or steam_is_running(str(current.get("prefix") or "")):
                owner = current.get("bottle") or "another profile"
                raise RuntimeError(
                    f"The shared Steam client is currently in use by {owner}. "
                    "Close Steam there before launching through this profile."
                )
        payload["client_owner"] = {
            "prefix": prefix,
            "bottle": bottle,
            "acquired_at": (current or {}).get("acquired_at", now) if (current or {}).get("prefix") == prefix else now,
            "updated_at": now,
        }
        _write(path, payload)


def release_shared_steam_client(*, prefix: str) -> None:
    path = activity_path()
    if not path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        payload = _read(path)
        current = payload.get("client_owner")
        if current and current.get("prefix") == prefix:
            del payload["client_owner"]
            _write(path, payload)


def reconcile_shared_steam_client() -> None:
    """Renew the shared client reservation while its owner's Steam is running, else expire it."""
    path = activity_path()
    if not path.exists():
        return
    lock_path = path.with_suffix(".lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        payload = _read(path)
        current = payload.get("client_owner")
        if not current:
            return
        from .sessions import steam_is_running

        now = time.time()
        prefix = str(current.get("prefix") or "")
        if steam_is_running(prefix):
            current["updated_at"] = now
            _write(path, payload)
        elif now - float(current.get("updated_at") or 0) >= CLIENT_RESERVATION_GRACE_SECONDS:
            del payload["client_owner"]
            _write(path, payload)


def shared_steam_client_owner() -> dict[str, Any] | None:
    return _read(activity_path()).get("client_owner")


def assert_direct_launch_safe(*, library_path: Path, appid: str) -> None:
    """Refuse a direct launch while Steam is mutating this shared library."""
    steamapps = library_path / "steamapps"
    for directory_name in ("downloading", "temp"):
        work = steamapps / directory_name
        try:
            if work.is_dir() and any(work.iterdir()):
                raise RuntimeError(
                    f"Steam is updating shared library files. Wait for Steam's download activity to finish before launching AppID {appid} from another profile."
                )
        except OSError as exc:
            raise RuntimeError(f"Could not verify that shared Steam library {library_path} is idle: {exc}") from exc
