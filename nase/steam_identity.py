from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
from typing import Any, Iterator

from .bottle import Bottle, app_support_root, bottle_paths, bottles_root, list_bottle_roots
from .sessions import steam_is_running
from .steam import parse_vdf_file, steam_prefix_root


STORE_VERSION = 1


def identity_root() -> Path:
    return app_support_root() / "steam-identity"


def _manifest_path() -> Path:
    return identity_root() / "manifest.json"


def _snapshot_path() -> Path:
    return identity_root() / "identity.json"


def _managed_bottles() -> list[Bottle]:
    return [bottle_paths(path.name) for path in list_bottle_roots()]


def _require_managed_bottle(bottle: Bottle) -> None:
    expected_parent = bottles_root().resolve()
    if bottle.root.resolve().parent != expected_parent or bottle.name in {"", ".", ".."}:
        raise RuntimeError("Shared Steam login only supports a named NASE-managed bottle.")


def _active_bottle_names() -> list[str]:
    return [bottle.name for bottle in _managed_bottles() if steam_is_running(str(bottle.prefix))]


def _require_all_steam_stopped() -> None:
    active = _active_bottle_names()
    if active:
        names = ", ".join(active)
        raise RuntimeError(
            f"Close Windows Steam in every NASE profile before changing shared login. Still running: {names}."
        )


@contextmanager
def _identity_lock() -> Iterator[None]:
    root = identity_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(root, 0o700)
    lock_path = root / ".lock"
    with lock_path.open("a", encoding="utf-8") as handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def _steam_files(bottle: Bottle) -> tuple[Path, Path]:
    root = steam_prefix_root(bottle)
    return root / "config" / "loginusers.vdf", root / "config" / "config.vdf"


def _get_path(tree: dict[str, Any], keys: tuple[str, ...]) -> Any:
    current: Any = tree
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def _set_path(tree: dict[str, Any], keys: tuple[str, ...], value: Any) -> None:
    current = tree
    for key in keys[:-1]:
        child = current.get(key)
        if not isinstance(child, dict):
            child = {}
            current[key] = child
        current = child
    current[keys[-1]] = value


def _delete_path(tree: dict[str, Any], keys: tuple[str, ...]) -> None:
    current: Any = tree
    for key in keys[:-1]:
        if not isinstance(current, dict):
            return
        current = current.get(key)
    if isinstance(current, dict):
        current.pop(keys[-1], None)


def _vdf_quote(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def _vdf_text(tree: dict[str, Any], indent: int = 0) -> str:
    lines: list[str] = []
    prefix = "\t" * indent
    for key, value in tree.items():
        lines.append(f'{prefix}"{_vdf_quote(key)}"')
        if isinstance(value, dict):
            lines.append(f"{prefix}{{")
            lines.append(_vdf_text(value, indent + 1).rstrip("\n"))
            lines.append(f"{prefix}}}")
        else:
            lines[-1] += f'\t\t"{_vdf_quote(value)}"'
    return "\n".join(lines) + "\n"


def _atomic_text(path: Path, text: str, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        if mode is not None:
            os.chmod(temporary, mode)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def _account_ids(loginusers: dict[str, Any]) -> list[str]:
    users = loginusers.get("users", loginusers.get("Users", {}))
    return sorted(str(key) for key in users) if isinstance(users, dict) else []


def _local_shared_auth(bottle: Bottle) -> dict[str, Any]:
    result: dict[str, Any] = {}
    userdata = steam_prefix_root(bottle) / "userdata"
    if not userdata.is_dir():
        return result
    for localconfig in userdata.glob("*/config/localconfig.vdf"):
        try:
            tree = parse_vdf_file(localconfig)
        except OSError:
            continue
        shared = _get_path(tree, ("UserLocalConfigStore", "SharedAuth"))
        if isinstance(shared, dict):
            result[localconfig.parents[1].name] = shared
    return result


def _read_auto_login_user(user_reg: Path) -> str | None:
    if not user_reg.is_file():
        return None
    text = user_reg.read_text(encoding="utf-8", errors="replace")
    match = re.search(
        r'(?ms)^\[Software\\\\Valve\\\\Steam\].*?(?=^\[|\Z)', text
    )
    if not match:
        return None
    value = re.search(r'^"AutoLoginUser"="((?:\\.|[^"\\])*)"$', match.group(0), re.MULTILINE)
    return value.group(1) if value else None


def _set_auto_login_user(user_reg: Path, value: str | None) -> None:
    text = user_reg.read_text(encoding="utf-8", errors="replace") if user_reg.is_file() else "WINE REGISTRY Version 2\n"
    section_pattern = re.compile(r'(?ms)^\[Software\\\\Valve\\\\Steam\].*?(?=^\[|\Z)')
    section_match = section_pattern.search(text)
    escaped = value.replace("\\", "\\\\").replace('"', '\\"') if value is not None else None
    if section_match:
        section = section_match.group(0)
        line_pattern = re.compile(r'^"AutoLoginUser"=.*(?:\n|$)', re.MULTILINE)
        replacement = f'"AutoLoginUser"="{escaped}"\n' if escaped is not None else ""
        if line_pattern.search(section):
            section = line_pattern.sub(replacement, section)
        elif replacement:
            section = section.rstrip() + "\n" + replacement + "\n"
        text = text[: section_match.start()] + section + text[section_match.end() :]
    elif escaped is not None:
        text = text.rstrip() + f'\n\n[Software\\\\Valve\\\\Steam]\n"AutoLoginUser"="{escaped}"\n'
    _atomic_text(user_reg, text)


def steam_identity_status() -> dict[str, Any]:
    manifest: dict[str, Any] = {}
    try:
        manifest = json.loads(_manifest_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    return {
        "available": _snapshot_path().is_file() and bool(manifest),
        "source_bottle": manifest.get("source_bottle"),
        "captured_at": manifest.get("captured_at"),
        "account_count": manifest.get("account_count", 0),
        "provisioned_profiles": manifest.get("provisioned_profiles", []),
        "active_steam_profiles": _active_bottle_names(),
    }


def capture_steam_identity(source: Bottle) -> dict[str, Any]:
    with _identity_lock():
        _require_managed_bottle(source)
        _require_all_steam_stopped()
        loginusers_path, config_path = _steam_files(source)
        if not loginusers_path.is_file():
            raise RuntimeError(f"Sign in to Steam successfully in {source.name}, choose Remember Me, then fully close Steam.")
        loginusers_text = loginusers_path.read_text(encoding="utf-8", errors="strict")
        loginusers = parse_vdf_file(loginusers_path)
        accounts = _account_ids(loginusers)
        if not accounts:
            raise RuntimeError(f"No remembered Steam account was found in {source.name}.")
        config = parse_vdf_file(config_path) if config_path.is_file() else {}
        account_config = _get_path(config, ("InstallConfigStore", "Software", "Valve", "Steam", "Accounts"))
        snapshot = {
            "version": STORE_VERSION,
            "loginusers_vdf": loginusers_text,
            "account_config": account_config if isinstance(account_config, dict) else {},
            "shared_auth": _local_shared_auth(source),
            "auto_login_user": _read_auto_login_user(source.prefix / "user.reg"),
        }
        encoded = json.dumps(snapshot, sort_keys=True, separators=(",", ":")) + "\n"
        _atomic_text(_snapshot_path(), encoded, 0o600)
        manifest = {
            "version": STORE_VERSION,
            "source_bottle": source.name,
            "captured_at": int(time.time()),
            "account_count": len(accounts),
            "snapshot_sha256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
            "provisioned_profiles": [],
        }
        _atomic_text(_manifest_path(), json.dumps(manifest, indent=2, sort_keys=True) + "\n", 0o600)
        return steam_identity_status()


def _load_snapshot() -> tuple[dict[str, Any], dict[str, Any]]:
    try:
        encoded = _snapshot_path().read_text(encoding="utf-8")
        snapshot = json.loads(encoded)
        manifest = json.loads(_manifest_path().read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError("No protected Steam login is saved. Sign in once, close Steam, then capture it.") from exc
    expected = manifest.get("snapshot_sha256")
    actual = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    if not expected or expected != actual:
        raise RuntimeError("The protected Steam login failed its integrity check. Forget it and capture the login again.")
    if snapshot.get("version") != STORE_VERSION:
        raise RuntimeError("The saved Steam login format is unsupported. Forget it and capture the login again.")
    return snapshot, manifest


def provision_steam_identity(target: Bottle) -> dict[str, Any]:
    with _identity_lock():
        _require_managed_bottle(target)
        _require_all_steam_stopped()
        snapshot, manifest = _load_snapshot()
        loginusers_path, config_path = _steam_files(target)
        if not steam_prefix_root(target).is_dir():
            raise RuntimeError(f"Install Steam in {target.name} before applying the shared login.")
        backups: dict[Path, bytes | None] = {}
        touched = [loginusers_path, config_path, target.prefix / "user.reg"]
        for account in snapshot.get("shared_auth", {}):
            touched.append(steam_prefix_root(target) / "userdata" / account / "config" / "localconfig.vdf")
        for path in touched:
            backups[path] = path.read_bytes() if path.is_file() else None
        try:
            _atomic_text(loginusers_path, snapshot["loginusers_vdf"])
            config = parse_vdf_file(config_path) if config_path.is_file() else {}
            _set_path(config, ("InstallConfigStore", "Software", "Valve", "Steam", "Accounts"), snapshot.get("account_config", {}))
            _atomic_text(config_path, _vdf_text(config))
            for account, shared_auth in snapshot.get("shared_auth", {}).items():
                localconfig = steam_prefix_root(target) / "userdata" / account / "config" / "localconfig.vdf"
                tree = parse_vdf_file(localconfig) if localconfig.is_file() else {}
                _set_path(tree, ("UserLocalConfigStore", "SharedAuth"), shared_auth)
                _atomic_text(localconfig, _vdf_text(tree))
            _set_auto_login_user(target.prefix / "user.reg", snapshot.get("auto_login_user"))
        except Exception:
            for path, content in backups.items():
                if content is None:
                    path.unlink(missing_ok=True)
                else:
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(content)
            raise
        profiles = sorted(set(manifest.get("provisioned_profiles", [])) | {target.name})
        manifest["provisioned_profiles"] = profiles
        _atomic_text(_manifest_path(), json.dumps(manifest, indent=2, sort_keys=True) + "\n", 0o600)
        return {"target_bottle": target.name, "fallback": "Steam may request login or Steam Guard if it invalidates the saved session."}


def sign_out_steam_profile(target: Bottle) -> dict[str, Any]:
    with _identity_lock():
        _require_managed_bottle(target)
        _require_all_steam_stopped()
        loginusers_path, config_path = _steam_files(target)
        loginusers_path.unlink(missing_ok=True)
        if config_path.is_file():
            config = parse_vdf_file(config_path)
            _delete_path(config, ("InstallConfigStore", "Software", "Valve", "Steam", "Accounts"))
            _atomic_text(config_path, _vdf_text(config))
        userdata = steam_prefix_root(target) / "userdata"
        if userdata.is_dir():
            for localconfig in userdata.glob("*/config/localconfig.vdf"):
                tree = parse_vdf_file(localconfig)
                _delete_path(tree, ("UserLocalConfigStore", "SharedAuth"))
                _atomic_text(localconfig, _vdf_text(tree))
        _set_auto_login_user(target.prefix / "user.reg", None)
        if _manifest_path().is_file():
            try:
                manifest = json.loads(_manifest_path().read_text(encoding="utf-8"))
                manifest["provisioned_profiles"] = [name for name in manifest.get("provisioned_profiles", []) if name != target.name]
                _atomic_text(_manifest_path(), json.dumps(manifest, indent=2, sort_keys=True) + "\n", 0o600)
            except ValueError:
                pass
        return {"target_bottle": target.name, "signed_out": True}


def forget_steam_identity() -> dict[str, Any]:
    with _identity_lock():
        _require_all_steam_stopped()
        root = identity_root()
        removed = _snapshot_path().exists() or _manifest_path().exists()
        _snapshot_path().unlink(missing_ok=True)
        _manifest_path().unlink(missing_ok=True)
        for path in root.iterdir() if root.is_dir() else []:
            if path.name != ".lock" and path.is_file():
                path.unlink()
        return {"forgotten": removed, "profiles_unchanged": True}
