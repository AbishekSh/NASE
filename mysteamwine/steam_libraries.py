from __future__ import annotations

import hashlib
import json
import os
import fcntl
from pathlib import Path
import shutil
import time
from typing import Any
import uuid

from .bottle import Bottle, app_support_root, bottle_paths, list_bottle_roots
from .sessions import steam_is_running
from .steam import SteamApp, parse_vdf_file, steam_prefix_root, steamapps_dirs, wine_path_to_host


SCHEMA_VERSION = 1


def registry_path() -> Path:
    return app_support_root() / "steam-libraries.json"


def managed_shared_library() -> Path:
    """Return the profile-independent Steam library owned by NASE."""
    return app_support_root() / "SteamLibrary"


def _library_id(path: Path) -> str:
    return "library_" + hashlib.sha256(str(path).encode("utf-8")).hexdigest()[:16]


def _normalized(path: Path) -> Path:
    expanded = path.expanduser()
    try:
        return expanded.resolve(strict=False)
    except OSError:
        return expanded.absolute()


def _managed_bottles(current: Bottle) -> list[Bottle]:
    bottles = [bottle_paths(root.name) for root in list_bottle_roots()]
    if all(_normalized(item.root) != _normalized(current.root) for item in bottles):
        bottles.append(current)
    return sorted(bottles, key=lambda bottle: (bottle.name.lower(), str(bottle.prefix)))


def _manifest_location(manifest: Path, steamapps: Path, library_id: str, bottle_name: str) -> dict[str, Any] | None:
    try:
        parsed = parse_vdf_file(manifest)
    except (OSError, ValueError):
        return None
    app_state = parsed.get("AppState", parsed)
    if not isinstance(app_state, dict):
        return None
    appid = str(app_state.get("appid") or manifest.stem.replace("appmanifest_", ""))
    name = str(app_state.get("name") or appid)
    install_dir_name = str(app_state.get("installdir") or name)
    install_dir = _normalized(steamapps / "common" / install_dir_name)
    installed = install_dir.is_dir()
    return {
        "appid": appid,
        "name": name,
        "library_id": library_id,
        "install_dir": str(install_dir),
        "manifest_path": str(_normalized(manifest)),
        "state": "installed" if installed else "missing-files",
        "state_flags": str(app_state.get("StateFlags") or app_state.get("stateflags") or ""),
        "seen_from_bottle": bottle_name,
    }


def discover_steam_libraries(current: Bottle, registered: dict[str, Any] | None = None) -> dict[str, Any]:
    libraries: dict[str, dict[str, Any]] = {}
    locations_by_app: dict[str, list[dict[str, Any]]] = {}
    warnings: list[str] = []

    # Every compatibility profile attaches this external library. Keeping it
    # outside bottle roots lets profiles be deleted without deleting games.
    shared_root = _normalized(managed_shared_library())
    shared_steamapps = shared_root / "steamapps"
    shared_steamapps.mkdir(parents=True, exist_ok=True)
    shared_library_id = _library_id(shared_root)
    libraries[shared_library_id] = {
        "library_id": shared_library_id,
        "path": str(shared_root),
        "steamapps_path": str(shared_steamapps),
        "exists": True,
        "writable": os.access(shared_steamapps, os.W_OK),
        "referenced_by": [],
        "managed": True,
    }

    # Registered libraries outlive any one profile. Seed discovery with them so
    # removing or switching the active bottle cannot make installed games vanish.
    for stored in (registered or {}).get("libraries", []):
        steamapps_value = str(stored.get("steamapps_path") or "")
        path_value = str(stored.get("path") or "")
        if not steamapps_value and not path_value:
            continue
        steamapps = _normalized(Path(steamapps_value) if steamapps_value else Path(path_value) / "steamapps")
        library_root = steamapps.parent
        library_id = str(stored.get("library_id") or _library_id(library_root))
        entry = libraries.setdefault(
            library_id,
            {
                "library_id": library_id,
                "path": str(library_root),
                "steamapps_path": str(steamapps),
                "exists": steamapps.is_dir(),
                "writable": steamapps.is_dir() and os.access(steamapps, os.W_OK),
                "referenced_by": list(stored.get("referenced_by") or []),
            },
        )
        if not steamapps.is_dir():
            continue
        for manifest in sorted(steamapps.glob("appmanifest_*.acf")):
            location = _manifest_location(manifest, steamapps, library_id, "registry")
            if location is not None:
                locations_by_app.setdefault(location["appid"], []).append(location)

    for bottle in _managed_bottles(current):
        try:
            directories = steamapps_dirs(bottle)
        except (OSError, ValueError) as exc:
            warnings.append(f"Could not read Steam libraries for {bottle.name}: {exc}")
            continue
        for steamapps in directories:
            normalized_steamapps = _normalized(steamapps)
            library_root = normalized_steamapps.parent
            library_id = _library_id(library_root)
            entry = libraries.setdefault(
                library_id,
                {
                    "library_id": library_id,
                    "path": str(library_root),
                    "steamapps_path": str(normalized_steamapps),
                    "exists": normalized_steamapps.is_dir(),
                    "writable": normalized_steamapps.is_dir() and os.access(normalized_steamapps, os.W_OK),
                    "referenced_by": [],
                },
            )
            reference = {
                "bottle": bottle.name,
                "prefix": str(_normalized(bottle.prefix)),
                "source": "libraryfolders.vdf" if normalized_steamapps != _normalized(bottle.drive_c / "Program Files (x86)" / "Steam" / "steamapps") else "primary",
            }
            if reference not in entry["referenced_by"]:
                entry["referenced_by"].append(reference)
            if not normalized_steamapps.is_dir():
                continue
            for manifest in sorted(normalized_steamapps.glob("appmanifest_*.acf")):
                location = _manifest_location(manifest, normalized_steamapps, library_id, bottle.name)
                if location is None:
                    warnings.append(f"Could not parse Steam manifest: {manifest}")
                    continue
                locations_by_app.setdefault(location["appid"], []).append(location)

    apps: list[dict[str, Any]] = []
    for appid, locations in locations_by_app.items():
        unique_locations = list({(item["manifest_path"], item["install_dir"]): item for item in locations}.values())
        unique_locations.sort(
            key=lambda item: (
                item["state"] != "installed",
                not libraries[item["library_id"]]["writable"],
                item["install_dir"].lower(),
            )
        )
        preferred = unique_locations[0]
        apps.append(
            {
                "appid": appid,
                "name": preferred["name"],
                "state": preferred["state"],
                "preferred_location": preferred,
                "locations": unique_locations,
            }
        )

    apps.sort(key=lambda app: (app["name"].lower(), app["appid"]))
    for library in libraries.values():
        library["referenced_by"].sort(key=lambda item: (item["bottle"].lower(), item["prefix"]))
    return {
        "schema_version": SCHEMA_VERSION,
        "updated_at": time.time(),
        "libraries": sorted(libraries.values(), key=lambda item: item["path"].lower()),
        "apps": apps,
        "warnings": warnings,
    }


def save_registry(registry: dict[str, Any]) -> Path:
    path = registry_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(registry, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)
    return path


def refresh_registry(current: Bottle) -> dict[str, Any]:
    registry = discover_steam_libraries(current, load_registry())
    save_registry(registry)
    return registry


def installed_games(registry: dict[str, Any]) -> list[dict[str, str]]:
    games: list[dict[str, str]] = []
    for app in registry.get("apps", []):
        preferred = app.get("preferred_location", {})
        if preferred.get("state") != "installed":
            continue
        games.append(
            {
                "appid": str(app.get("appid") or ""),
                "name": str(app.get("name") or app.get("appid") or "Unknown"),
                "install_dir": str(preferred.get("install_dir") or ""),
                "library_id": str(preferred.get("library_id") or ""),
            }
        )
    return games


def resolve_registered_app(current: Bottle, appid: str, *, registry: dict[str, Any] | None = None) -> tuple[SteamApp, str]:
    """Resolve one canonical app independently from the selected profile prefix."""
    catalog = registry or refresh_registry(current)
    app = next((item for item in catalog.get("apps", []) if str(item.get("appid")) == str(appid)), None)
    if app is None:
        raise FileNotFoundError(f"Steam app not found for AppID {appid} in registered libraries")
    location = app.get("preferred_location") or {}
    install_dir = Path(str(location.get("install_dir") or ""))
    manifest_path = Path(str(location.get("manifest_path") or ""))
    if location.get("state") != "installed" or not install_dir.is_dir():
        raise FileNotFoundError(f"Steam app {appid} is registered but its game files are missing")
    return (
        SteamApp(
            appid=str(app.get("appid") or appid),
            name=str(app.get("name") or appid),
            install_dir=install_dir,
            manifest_path=manifest_path,
            library_path=Path(str(next(
                (library.get("path") for library in catalog.get("libraries", []) if library.get("library_id") == location.get("library_id")),
                install_dir.parent.parent,
            ))),
        ),
        str(location.get("library_id") or ""),
    )


def load_registry() -> dict[str, Any]:
    path = registry_path()
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"schema_version": SCHEMA_VERSION, "libraries": [], "apps": [], "warnings": []}
    return payload if isinstance(payload, dict) else {"schema_version": SCHEMA_VERSION, "libraries": [], "apps": [], "warnings": []}


def _vdf_quote(value: Any) -> str:
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _serialize_vdf_object(data: dict[str, Any], depth: int = 0) -> list[str]:
    lines: list[str] = []
    indent = "\t" * depth
    for key, value in data.items():
        if isinstance(value, dict):
            lines.extend([f"{indent}{_vdf_quote(key)}", f"{indent}{{"])
            lines.extend(_serialize_vdf_object(value, depth + 1))
            lines.append(f"{indent}}}")
        else:
            lines.append(f"{indent}{_vdf_quote(key)}\t\t{_vdf_quote(value)}")
    return lines


def serialize_vdf(data: dict[str, Any]) -> str:
    return "\n".join(_serialize_vdf_object(data)) + "\n"


def _host_path_to_wine(path: Path) -> str:
    return "Z:" + str(_normalized(path)).replace("/", "\\")


def _library_appids(registry: dict[str, Any], library_id: str) -> dict[str, str]:
    appids: dict[str, str] = {}
    for app in registry.get("apps", []):
        for location in app.get("locations", []):
            if location.get("library_id") == library_id and location.get("state") == "installed":
                appids[str(app.get("appid"))] = "0"
    return appids


def _attach_registered_libraries_unlocked(
    bottle: Bottle,
    registry: dict[str, Any],
    *,
    library_ids: set[str] | None = None,
) -> dict[str, Any]:
    steam_exe = steam_prefix_root(bottle) / "Steam.exe"
    if not steam_exe.is_file():
        raise RuntimeError(f"Steam is not installed in profile bottle '{bottle.name}'.")
    if steam_is_running(str(bottle.prefix)):
        raise RuntimeError(f"Close Steam in '{bottle.name}' before attaching shared libraries.")

    primary = steam_prefix_root(bottle) / "steamapps"
    primary.mkdir(parents=True, exist_ok=True)
    config = primary / "libraryfolders.vdf"
    if config.exists():
        try:
            parsed = parse_vdf_file(config)
        except OSError as exc:
            raise RuntimeError(f"Could not read {config}: {exc}") from exc
    else:
        parsed = {
            "libraryfolders": {
                "0": {
                    "path": r"C:\Program Files (x86)\Steam",
                    "label": "",
                    "contentid": "0",
                    "totalsize": "0",
                    "apps": {},
                }
            }
        }
    folders = parsed.get("libraryfolders", parsed)
    if not isinstance(folders, dict):
        raise RuntimeError(f"Steam library configuration is not valid: {config}")

    existing_paths: set[Path] = set()
    numeric_keys: list[int] = []
    for key, value in folders.items():
        if str(key).isdigit():
            numeric_keys.append(int(key))
        if isinstance(value, dict) and value.get("path"):
            existing_paths.add(_normalized(wine_path_to_host(bottle, str(value["path"]))))

    target_primary = _normalized(steam_prefix_root(bottle))
    candidates = []
    for library in registry.get("libraries", []):
        library_id = str(library.get("library_id") or "")
        path = _normalized(Path(str(library.get("path") or "")))
        if library_ids is not None and library_id not in library_ids:
            continue
        if not library.get("exists") or path == target_primary:
            continue
        candidates.append((library_id, path))

    attached: list[dict[str, str]] = []
    already_attached: list[dict[str, str]] = []
    next_key = max(numeric_keys, default=-1) + 1
    for library_id, path in sorted(candidates, key=lambda item: str(item[1]).lower()):
        item = {"library_id": library_id, "path": str(path)}
        if path in existing_paths:
            already_attached.append(item)
            continue
        content_id = str(int(hashlib.sha256(str(path).encode()).hexdigest()[:15], 16))
        folders[str(next_key)] = {
            "path": _host_path_to_wine(path),
            "label": "NASE Shared Library",
            "contentid": content_id,
            "totalsize": "0",
            "apps": _library_appids(registry, library_id),
        }
        next_key += 1
        existing_paths.add(path)
        attached.append(item)

    backup: Path | None = None
    if attached:
        if config.exists():
            backup = config.with_name(f"libraryfolders.vdf.nase-backup-{int(time.time())}")
            shutil.copy2(config, backup)
        temporary = config.with_name(f".{config.name}.{uuid.uuid4().hex}.tmp")
        temporary.write_text(serialize_vdf(parsed), encoding="utf-8")
        temporary.replace(config)
        verified = parse_vdf_file(config)
        verified_folders = verified.get("libraryfolders", verified)
        verified_paths = {
            _normalized(wine_path_to_host(bottle, str(value.get("path"))))
            for value in verified_folders.values()
            if isinstance(value, dict) and value.get("path")
        }
        missing = [item["path"] for item in attached if _normalized(Path(item["path"])) not in verified_paths]
        if missing:
            if backup:
                shutil.copy2(backup, config)
            raise RuntimeError(f"Steam library attachment verification failed for: {', '.join(missing)}")

    return {
        "bottle": bottle.name,
        "config_path": str(config),
        "backup_path": str(backup) if backup else None,
        "attached": attached,
        "already_attached": already_attached,
    }


def attach_registered_libraries(
    bottle: Bottle,
    registry: dict[str, Any],
    *,
    library_ids: set[str] | None = None,
) -> dict[str, Any]:
    bottle.root.mkdir(parents=True, exist_ok=True)
    lock_path = bottle.root / ".library-attachment.lock"
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            return _attach_registered_libraries_unlocked(bottle, registry, library_ids=library_ids)
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
