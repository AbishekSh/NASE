from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mysteamwine.bottle import Bottle
import mysteamwine.steam as steam
from mysteamwine.steam import run_steam, steam_client_is_ready, validate_executable_compatibility


class SteamLaunchTests(unittest.TestCase):
    def make_bottle(self, root: Path) -> Bottle:
        return Bottle(
            "Test",
            root,
            root / "prefix",
            root / "logs",
            root / "downloads",
            root / "cache",
        )

    def make_x86_executable(self, root: Path) -> Path:
        executable = root / "game.exe"
        payload = bytearray(256)
        payload[0:2] = b"MZ"
        payload[0x3C:0x40] = (128).to_bytes(4, "little")
        payload[128:132] = b"PE\0\0"
        payload[132:134] = (0x014C).to_bytes(2, "little")
        executable.write_bytes(payload)
        return executable

    def test_native_macos_steam_blocks_windows_steam_launch(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-steam-test-"))
        bottle = Bottle(
            "Test",
            root,
            root / "prefix",
            root / "logs",
            root / "downloads",
            root / "cache",
        )

        with patch("mysteamwine.steam.native_macos_steam_is_running", return_value=True):
            code, message = run_steam(
                bottle=bottle,
                wine64_path=Path("/missing/wine"),
                wait=False,
            )

        self.assertEqual(code, 1)
        self.assertIn("Steam > Quit Steam", message)
        self.assertIn("Closing only the Steam window is not enough", message)

    def test_x86_executable_requires_wow64_runtime(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-steam-test-"))
        executable = self.make_x86_executable(root)
        with (
            patch("mysteamwine.steam.supports_wow64", return_value=False),
            self.assertRaisesRegex(RuntimeError, "does not include WoW64"),
        ):
            validate_executable_compatibility(
                executable=executable,
                wine_path=root / "wine",
                graphics_backend="none",
            )

    def test_x86_executable_rejects_d3dmetal(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-steam-test-"))
        executable = self.make_x86_executable(root)
        with (
            patch("mysteamwine.steam.supports_wow64", return_value=True),
            self.assertRaisesRegex(RuntimeError, "D3DMetal supports 64-bit"),
        ):
            validate_executable_compatibility(
                executable=executable,
                wine_path=root / "wine",
                graphics_backend="d3dmetal",
            )

    def test_x86_executable_accepts_dxmt_with_wow64(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-steam-test-"))
        executable = self.make_x86_executable(root)
        with patch("mysteamwine.steam.supports_wow64", return_value=True):
            architecture = validate_executable_compatibility(
                executable=executable,
                wine_path=root / "wine",
                graphics_backend="dxmt",
            )
        self.assertEqual(architecture, "x86")

    def test_steam_readiness_uses_latest_connection_state(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-steam-test-"))
        bottle = self.make_bottle(root)
        log = bottle.prefix / "drive_c" / "Program Files (x86)" / "Steam" / "logs" / "connection_log.txt"
        log.parent.mkdir(parents=True)
        log.write_text("[Logged On, 4, 7] ready\n", encoding="utf-8")
        self.assertTrue(steam_client_is_ready(bottle))

        log.write_text("[Logged On, 4, 7] ready\n[Logged Off, 0, 0] stopped\n", encoding="utf-8")
        self.assertFalse(steam_client_is_ready(bottle))

        offset = log.stat().st_size
        self.assertFalse(steam_client_is_ready(bottle, after_offset=offset))
        with log.open("a", encoding="utf-8") as handle:
            handle.write("[Logged On, 4, 7] fresh session\n")
        self.assertTrue(steam_client_is_ready(bottle, after_offset=offset))

    def test_global_stop_covers_managed_and_tracked_external_prefixes(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-stop-test-"))
        managed_prefix = root / "bottles" / "Default-DXMT" / "prefix"
        external_prefix = root / "external-game-prefix"
        managed_prefix.mkdir(parents=True)
        external_prefix.mkdir()
        current = self.make_bottle(root / "bottles" / "Default-DXMT")
        session = {
            "session_id": "launch_test",
            "status": "running",
            "prefix": str(external_prefix),
        }

        with (
            patch.object(steam, "app_support_root", return_value=root),
            patch.object(steam, "reconcile_sessions", return_value=[session]),
            patch.object(steam, "stop_session", return_value=(session, [101])) as stop,
            patch.object(steam, "_terminate_prefix_server_processes", return_value=[303]) as terminate_server,
            patch.object(steam, "_terminate_orphaned_prefix_processes", return_value=[202]) as terminate,
            patch.object(steam, "_process_command", return_value="wineserver"),
        ):
            code, message, targets = steam.kill_nase_wine_processes(current_bottle=current)

        self.assertEqual(code, 0)
        self.assertEqual(set(targets), {str(managed_prefix), str(external_prefix)})
        self.assertIn("Stopped 2 Wine/game processes", message)
        self.assertIn("Stopped 2 Wine servers", message)
        stop.assert_called_once_with("launch_test")
        self.assertEqual(terminate_server.call_count, 2)
        terminate.assert_not_called()


if __name__ == "__main__":
    unittest.main()
