from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path
import shutil

from . import APP_NAME, LEGACY_APP_NAME


@dataclass(frozen=True)
class Bottle:
    name: str
    root: Path
    prefix: Path
    logs: Path
    downloads: Path
    cache: Path

    @property
    def drive_c(self) -> Path:
        return self.prefix / "drive_c"


def _replace_managed_path(path: Path, old_root: Path, new_root: Path) -> None:
    temporary = path.with_name(f".{path.name}.nase-migration")
    try:
        if not path.is_file() or path.stat().st_size > 2 * 1024 * 1024:
            return
        original = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return
    updated = original.replace(str(old_root), str(new_root))
    if updated == original:
        return
    try:
        mode = path.stat().st_mode
        temporary.write_text(updated, encoding="utf-8")
        temporary.chmod(mode)
        temporary.replace(path)
    except OSError:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def _rewrite_migrated_metadata(old_root: Path, new_root: Path) -> None:
    marker = new_root / ".nase-data-root-v1"
    if marker.exists():
        return
    candidates: set[Path] = set(new_root.glob("*.json"))
    for relative in ("jobs", "sources"):
        directory = new_root / relative
        if directory.is_dir():
            candidates.update(directory.rglob("*.json"))
    for name in ("compatibility-profile.json", "overlay.json", "stack.json"):
        bottles = new_root / "bottles"
        if bottles.is_dir():
            candidates.update(bottles.rglob(name))
    installed = new_root / "runtimes" / "installed.json"
    if installed.is_file():
        candidates.add(installed)
    source_clients = new_root / "runtimes" / "source-client"
    if source_clients.is_dir():
        candidates.update(
            path
            for path in source_clients.rglob("*")
            if path.is_file() and not path.is_symlink()
        )
        for link in (path for path in source_clients.rglob("*") if path.is_symlink()):
            try:
                target = link.readlink()
                updated = str(target).replace(str(old_root), str(new_root))
                if updated != str(target):
                    link.unlink()
                    link.symlink_to(updated)
            except OSError:
                continue
    for path in candidates:
        _replace_managed_path(path, old_root, new_root)
    try:
        marker.write_text(
            f"Migrated from {old_root}\n",
            encoding="utf-8",
        )
    except OSError:
        pass


def app_support_root() -> Path:
    support = Path.home() / "Library" / "Application Support"
    root = support / APP_NAME
    legacy = support / LEGACY_APP_NAME
    if not root.exists() and legacy.exists():
        try:
            support.mkdir(parents=True, exist_ok=True)
            legacy.rename(root)
        except OSError:
            return legacy
    if root.exists():
        _rewrite_migrated_metadata(legacy, root)
    return root


def bottle_paths(name: str) -> Bottle:
    root = app_support_root() / "bottles" / name
    return Bottle(
        name=name,
        root=root,
        prefix=root / "prefix",
        logs=root / "logs",
        downloads=root / "downloads",
        cache=root / "cache",
    )


def external_prefix_paths(prefix: Path) -> Bottle:
    resolved = prefix.expanduser().resolve()
    digest = hashlib.sha1(str(resolved).encode("utf-8")).hexdigest()[:12]
    root = app_support_root() / "external-prefixes" / digest
    return Bottle(
        name=resolved.name or digest,
        root=root,
        prefix=resolved,
        logs=root / "logs",
        downloads=root / "downloads",
        cache=root / "cache",
    )


def ensure_bottle_dirs(bottle: Bottle) -> None:
    for path in (bottle.root, bottle.prefix, bottle.logs, bottle.downloads, bottle.cache):
        path.mkdir(parents=True, exist_ok=True)


def bottles_root() -> Path:
    return app_support_root() / "bottles"


def list_bottle_roots() -> list[Path]:
    root = bottles_root()
    if not root.exists():
        return []
    return sorted(path for path in root.iterdir() if path.is_dir())


def wipe_all_bottles() -> list[Path]:
    removed: list[Path] = []
    for bottle_root in list_bottle_roots():
        shutil.rmtree(bottle_root)
        removed.append(bottle_root)
    return removed
