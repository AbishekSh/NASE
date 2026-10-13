from __future__ import annotations

from pathlib import Path
import struct
import tempfile
import unittest

from nase import steam_ownership


def _kv_string(key: str, value: str, table: list[str] | None = None) -> bytes:
    return b"\x01" + _key(key, table) + value.encode("utf-8") + b"\x00"


def _kv_int(key: str, value: int, table: list[str] | None = None) -> bytes:
    return b"\x02" + _key(key, table) + struct.pack("<i", value)


def _kv_nested(key: str, body: bytes, table: list[str] | None = None) -> bytes:
    return b"\x00" + _key(key, table) + body + b"\x08"


def _key(key: str, table: list[str] | None) -> bytes:
    if table is None:
        return key.encode("utf-8") + b"\x00"
    if key not in table:
        table.append(key)
    return struct.pack("<I", table.index(key))


def _packageinfo(packages: dict[int, list[int]]) -> bytes:
    payload = struct.pack("<II", steam_ownership.PACKAGEINFO_MAGIC, 1)
    for package_id, appids in packages.items():
        appid_body = b"".join(_kv_int(str(index), appid) for index, appid in enumerate(appids))
        # The record's outermost node needs its own terminator, exactly as
        # Steam writes it.
        record = _kv_nested(str(package_id), _kv_nested("appids", appid_body)) + b"\x08"
        payload += struct.pack("<I", package_id)
        payload += b"\x11" * 20  # sha1
        payload += struct.pack("<I", 7)  # change number
        payload += struct.pack("<Q", 0)  # PICS token
        payload += record
    payload += struct.pack("<I", 0xFFFFFFFF)
    return payload


def _launch_entry(index: int, entry: dict[str, str], table: list[str] | None) -> bytes:
    fields = b"".join(
        _kv_string(key, value, table) for key, value in entry.items() if key not in {"oslist", "betakey"}
    )
    config = b"".join(
        _kv_string(key, entry[key], table) for key in ("oslist", "betakey") if key in entry
    )
    if config:
        fields += _kv_nested("config", config, table)
    return _kv_nested(str(index), fields, table)


def _appinfo(
    apps: dict[int, tuple[str, str]],
    *,
    magic: int,
    launch: dict[int, list[dict[str, str]]] | None = None,
) -> bytes:
    uses_table = magic in steam_ownership.APPINFO_STRING_TABLE_MAGICS
    table: list[str] | None = [] if uses_table else None

    records = b""
    for appid, (name, app_type) in apps.items():
        common = _kv_string("name", name, table) + _kv_string("type", app_type, table)
        sections = _kv_nested("common", common, table)
        if launch and appid in launch:
            entries = b"".join(_launch_entry(index, entry, table) for index, entry in enumerate(launch[appid]))
            sections += _kv_nested("config", _kv_nested("launch", entries, table), table)
        body = _kv_nested("appinfo", sections, table) + b"\x08"
        header = b"\x00" * steam_ownership._APP_HEADER_BYTES
        records += struct.pack("<II", appid, len(header) + len(body)) + header + body
    records += struct.pack("<I", 0)

    if not uses_table:
        return struct.pack("<II", magic, 1) + records

    prefix = struct.pack("<II", magic, 1) + struct.pack("<q", 0)
    table_offset = len(prefix) + len(records)
    encoded = struct.pack("<I", len(table or []))
    for value in table or []:
        encoded += value.encode("utf-8") + b"\x00"
    return struct.pack("<II", magic, 1) + struct.pack("<q", table_offset) + records + encoded


class SteamOwnershipTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-ownership-test-"))
        (self.root / "appcache").mkdir(parents=True)

    def _write(self, packages: bytes | None = None, apps: bytes | None = None) -> None:
        if packages is not None:
            (self.root / "appcache" / "packageinfo.vdf").write_bytes(packages)
        if apps is not None:
            (self.root / "appcache" / "appinfo.vdf").write_bytes(apps)

    def test_owned_games_intersects_packages_and_app_metadata(self) -> None:
        self._write(
            packages=_packageinfo({1001: [10, 20], 1002: [30]}),
            apps=_appinfo(
                {
                    10: ("Playable One", "Game"),
                    20: ("Some Toolkit", "Tool"),
                    30: ("Playable Two", "game"),
                    40: ("Not Owned", "Game"),
                },
                magic=0x07564429,
            ),
        )
        games, warnings = steam_ownership.owned_games(self.root)
        self.assertEqual(warnings, [])
        self.assertEqual([(game.appid, game.name) for game in games], [("10", "Playable One"), ("30", "Playable Two")])

    def test_appinfo_without_string_table_is_supported(self) -> None:
        self._write(
            packages=_packageinfo({1001: [10]}),
            apps=_appinfo({10: ("Legacy Format Game", "Game")}, magic=0x07564427),
        )
        games, warnings = steam_ownership.owned_games(self.root)
        self.assertEqual(warnings, [])
        self.assertEqual([game.name for game in games], ["Legacy Format Game"])

    def test_appinfo_v28_string_table_is_supported(self) -> None:
        self._write(
            packages=_packageinfo({1001: [10]}),
            apps=_appinfo({10: ("Table Format Game", "Game")}, magic=0x07564428),
        )
        games, _ = steam_ownership.owned_games(self.root)
        self.assertEqual([game.name for game in games], ["Table Format Game"])

    def test_windows_launch_executables_follow_steam_launch_order(self) -> None:
        self._write(
            apps=_appinfo(
                {250900: ("The Binding of Isaac: Rebirth", "Game"), 10: ("Other", "Game")},
                magic=0x07564429,
                launch={
                    250900: [
                        {"executable": "isaac-ng.exe", "oslist": "windows"},
                        {"executable": "run-x64.sh", "oslist": "linux"},
                        {"executable": "beta\\isaac-beta.exe", "oslist": "windows", "betakey": "beta"},
                        {"executable": "server.exe", "type": "server"},
                        {"executable": "bin\\tool.exe"},
                    ]
                },
            ),
        )
        self.assertEqual(
            steam_ownership.windows_launch_executables(self.root, "250900"),
            ["isaac-ng.exe", "bin\\tool.exe"],
        )
        self.assertEqual(steam_ownership.windows_launch_executables(self.root, "10"), [])
        self.assertEqual(steam_ownership.windows_launch_executables(self.root, "999"), [])

    def test_unknown_format_degrades_with_a_warning(self) -> None:
        self._write(
            packages=struct.pack("<II", 0xDEADBEEF, 1),
            apps=_appinfo({10: ("Ignored", "Game")}, magic=0x07564429),
        )
        games, warnings = steam_ownership.owned_games(self.root)
        self.assertEqual(games, [])
        self.assertTrue(any("Unsupported" in warning for warning in warnings))

    def test_truncated_package_cache_keeps_what_parsed(self) -> None:
        complete = _packageinfo({1001: [10], 1002: [30]})
        self._write(
            packages=complete[: len(complete) - 12],
            apps=_appinfo({10: ("Playable One", "Game"), 30: ("Playable Two", "Game")}, magic=0x07564429),
        )
        games, warnings = steam_ownership.owned_games(self.root)
        self.assertTrue(warnings)
        # The intact leading record still yields its game; only the cut-off tail
        # is lost, so a damaged cache degrades instead of emptying the library.
        self.assertEqual([game.name for game in games], ["Playable One"])

    def test_missing_files_return_warnings_instead_of_raising(self) -> None:
        games, warnings = steam_ownership.owned_games(self.root)
        self.assertEqual(games, [])
        self.assertTrue(any("unreadable" in warning for warning in warnings))


if __name__ == "__main__":
    unittest.main()
