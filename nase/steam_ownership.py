"""Read owned Steam games from the Steam client's local caches.

Steam has no NASE account adapter the way Epic and GOG do, so the library could
only ever show games with an ``appmanifest_*.acf`` on disk. The Windows Steam
client, however, already caches everything needed to answer "what do I own?"
offline:

- ``appcache/packageinfo.vdf`` — one record per licensed package, each listing
  the app ids that package grants.
- ``appcache/appinfo.vdf`` — per-app metadata including ``common.name`` and
  ``common.type``.

Both are undocumented binary key-value formats, so every reader here degrades to
an empty result plus a warning rather than raising. An unrecognised future
format simply returns the installed-only library NASE showed before.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import struct
from typing import Any, Iterator


PACKAGEINFO_MAGIC = 0x06565528
APPINFO_MAGICS = (0x07564427, 0x07564428, 0x07564429)
# v28 and newer move keys into a shared string table appended to the file.
APPINFO_STRING_TABLE_MAGICS = (0x07564428, 0x07564429)

# Binary KV value markers.
_TYPE_NESTED = 0x00
_TYPE_STRING = 0x01
_TYPE_INT32 = 0x02
_TYPE_FLOAT32 = 0x03
_TYPE_POINTER = 0x04
_TYPE_WIDESTRING = 0x05
_TYPE_COLOR = 0x06
_TYPE_UINT64 = 0x07
_TYPE_END = 0x08
_TYPE_INT64 = 0x0A

# packageinfo record header after the package id: sha1 + change number + token.
_PACKAGE_HEADER_BYTES = 20 + 4 + 8
# appinfo record header after appid/size: info state, last updated, PICS token,
# text sha1, change number, and the binary vdf sha1.
_APP_HEADER_BYTES = 4 + 4 + 8 + 20 + 4 + 20


class BinaryVDFError(ValueError):
    """Raised internally when a cache file does not match the known layout."""


@dataclass(frozen=True)
class OwnedGame:
    appid: str
    name: str

    def as_dict(self) -> dict[str, str]:
        return {"appid": self.appid, "name": self.name}


def _read_cstring(data: bytes, offset: int) -> tuple[str, int]:
    end = data.find(b"\x00", offset)
    if end < 0:
        raise BinaryVDFError("unterminated string")
    return data[offset:end].decode("utf-8", "replace"), end + 1


def read_binary_kv(
    data: bytes,
    offset: int,
    string_table: list[str] | None = None,
) -> tuple[dict[str, Any], int]:
    """Read one binary key-value node, returning it with the next offset.

    Keys are inline NUL-terminated strings unless ``string_table`` is given, in
    which case each key is a ``uint32`` index into that table.
    """
    node: dict[str, Any] = {}
    while True:
        if offset >= len(data):
            raise BinaryVDFError("truncated node")
        value_type = data[offset]
        offset += 1
        if value_type == _TYPE_END:
            return node, offset
        if string_table is None:
            key, offset = _read_cstring(data, offset)
        else:
            (index,) = struct.unpack_from("<I", data, offset)
            offset += 4
            if index >= len(string_table):
                raise BinaryVDFError("string table index out of range")
            key = string_table[index]

        if value_type == _TYPE_NESTED:
            node[key], offset = read_binary_kv(data, offset, string_table)
        elif value_type == _TYPE_STRING:
            node[key], offset = _read_cstring(data, offset)
        elif value_type == _TYPE_WIDESTRING:
            end = data.find(b"\x00\x00", offset)
            if end < 0:
                raise BinaryVDFError("unterminated wide string")
            node[key] = data[offset:end].decode("utf-16-le", "replace")
            offset = end + 2
        elif value_type in (_TYPE_INT32, _TYPE_POINTER, _TYPE_COLOR):
            (node[key],) = struct.unpack_from("<i", data, offset)
            offset += 4
        elif value_type == _TYPE_FLOAT32:
            (node[key],) = struct.unpack_from("<f", data, offset)
            offset += 4
        elif value_type in (_TYPE_UINT64, _TYPE_INT64):
            (node[key],) = struct.unpack_from("<q", data, offset)
            offset += 8
        else:
            raise BinaryVDFError(f"unknown value type {value_type}")
    return node, offset


def _appcache_path(steam_root: Path, name: str) -> Path:
    return Path(steam_root) / "appcache" / name


def owned_appids(steam_root: Path) -> tuple[set[int], list[str]]:
    """Return app ids granted by the licensed packages Steam has cached."""
    path = _appcache_path(steam_root, "packageinfo.vdf")
    try:
        data = path.read_bytes()
    except OSError:
        return set(), [f"Steam package cache is unreadable: {path}"]
    if len(data) < 8:
        return set(), [f"Steam package cache is too small to parse: {path}"]
    (magic,) = struct.unpack_from("<I", data, 0)
    if magic != PACKAGEINFO_MAGIC:
        return set(), [f"Unsupported Steam package cache format ({magic:#010x})."]

    appids: set[int] = set()
    offset = 8
    try:
        while offset + 4 <= len(data):
            (package_id,) = struct.unpack_from("<I", data, offset)
            if package_id == 0xFFFFFFFF:
                break
            offset += 4 + _PACKAGE_HEADER_BYTES
            node, offset = read_binary_kv(data, offset)
            root = node.get(str(package_id))
            if not isinstance(root, dict):
                root = next((value for value in node.values() if isinstance(value, dict)), node)
            granted = root.get("appids") if isinstance(root, dict) else None
            if isinstance(granted, dict):
                appids.update(value for value in granted.values() if isinstance(value, int))
    except (BinaryVDFError, struct.error) as exc:
        # Keep whatever parsed cleanly; a partial list still beats none.
        return appids, [f"Steam package cache ended unexpectedly ({exc})."]
    return appids, []


def _iter_app_records(
    steam_root: Path,
    warnings: list[str],
    appids: set[int] | None = None,
) -> Iterator[tuple[int, dict[str, Any]]]:
    """Yield ``(appid, appinfo)`` from the client's app metadata cache.

    Only records in ``appids`` are decoded when it is given. Problems are
    appended to ``warnings`` and end the iteration instead of raising.
    """
    path = _appcache_path(steam_root, "appinfo.vdf")
    try:
        data = path.read_bytes()
    except OSError:
        warnings.append(f"Steam app cache is unreadable: {path}")
        return
    if len(data) < 16:
        warnings.append(f"Steam app cache is too small to parse: {path}")
        return
    (magic,) = struct.unpack_from("<I", data, 0)
    if magic not in APPINFO_MAGICS:
        warnings.append(f"Unsupported Steam app cache format ({magic:#010x}).")
        return

    string_table: list[str] | None = None
    end_of_records = len(data)
    if magic in APPINFO_STRING_TABLE_MAGICS:
        try:
            (table_offset,) = struct.unpack_from("<q", data, 8)
            if not 0 < table_offset < len(data):
                raise BinaryVDFError("string table offset out of range")
            (count,) = struct.unpack_from("<I", data, table_offset)
            cursor = table_offset + 4
            string_table = []
            for _ in range(count):
                value, cursor = _read_cstring(data, cursor)
                string_table.append(value)
            end_of_records = table_offset
        except (BinaryVDFError, struct.error) as exc:
            warnings.append(f"Steam app cache string table is unreadable ({exc}).")
            return
        offset = 16
    else:
        offset = 8

    try:
        while offset + 8 <= end_of_records:
            appid, size = struct.unpack_from("<II", data, offset)
            if appid == 0:
                break
            if appids is None or appid in appids:
                body = offset + 8 + _APP_HEADER_BYTES
                node, _ = read_binary_kv(data, body, string_table)
                root = node.get("appinfo") if isinstance(node.get("appinfo"), dict) else node
                yield appid, root
            offset += 8 + size
    except (BinaryVDFError, struct.error) as exc:
        warnings.append(f"Steam app cache ended unexpectedly ({exc}).")


def app_info(steam_root: Path) -> tuple[dict[int, tuple[str, str]], list[str]]:
    """Return ``{appid: (name, type)}`` from the client's app metadata cache."""
    apps: dict[int, tuple[str, str]] = {}
    warnings: list[str] = []
    for appid, root in _iter_app_records(steam_root, warnings):
        common = root.get("common") if isinstance(root.get("common"), dict) else {}
        name = common.get("name")
        app_type = common.get("type")
        if isinstance(name, str) and name:
            apps[appid] = (name, str(app_type or ""))
    return apps, warnings


# Launch options that start something other than the game itself.
_NON_GAME_LAUNCH_TYPES = {"server", "editor", "vr"}


@dataclass(frozen=True)
class SteamLaunchOption:
    """One Windows launch entry, as Steam stores it.

    Paths are relative to the install directory and may use backslashes;
    ``arguments`` is the raw command-line string Steam passes to the game.
    """

    executable: str
    arguments: str = ""
    working_dir: str = ""


def windows_launch_options(steam_root: Path, appid: str) -> list[SteamLaunchOption]:
    """Return the game's Windows launch options, in Steam's own order.

    Beta-only and server/editor/VR options are skipped. An empty list means
    the cache had no usable launch configuration.
    """
    if not str(appid).isdigit():
        return []
    for _appid, root in _iter_app_records(steam_root, [], {int(appid)}):
        config = root.get("config") if isinstance(root.get("config"), dict) else {}
        launch = config.get("launch") if isinstance(config.get("launch"), dict) else {}
        options: list[SteamLaunchOption] = []
        for key in sorted(launch, key=lambda item: int(item) if str(item).isdigit() else len(launch)):
            entry = launch[key]
            if not isinstance(entry, dict):
                continue
            entry_config = entry.get("config") if isinstance(entry.get("config"), dict) else {}
            oslist = str(entry_config.get("oslist") or "")
            if oslist and "windows" not in oslist.split(","):
                continue
            if entry_config.get("betakey") or str(entry.get("type") or "").lower() in _NON_GAME_LAUNCH_TYPES:
                continue
            executable = entry.get("executable")
            if isinstance(executable, str) and executable:
                options.append(
                    SteamLaunchOption(
                        executable=executable,
                        arguments=str(entry.get("arguments") or ""),
                        working_dir=str(entry.get("workingdir") or ""),
                    )
                )
        return options
    return []


def owned_games(steam_root: Path) -> tuple[list[OwnedGame], list[str]]:
    """Return every owned app the client knows to be a game, with warnings.

    Packages also grant tools, demos, DLC, soundtracks, and config apps, so the
    ``common.type`` recorded by Steam is what separates a library card from an
    invisible support entry. Steam is inconsistent about capitalisation there.
    """
    appids, warnings = owned_appids(steam_root)
    if not appids:
        return [], warnings
    apps, app_warnings = app_info(steam_root)
    warnings = warnings + app_warnings
    games: list[OwnedGame] = []
    for appid in appids:
        entry = apps.get(appid)
        if entry is None:
            continue
        name, app_type = entry
        if app_type.strip().lower() != "game":
            continue
        games.append(OwnedGame(appid=str(appid), name=name))
    games.sort(key=lambda game: (game.name.casefold(), game.appid))
    return games, warnings
