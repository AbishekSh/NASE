from __future__ import annotations

import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from nase.bottle import Bottle
import nase.sessions as sessions


class LaunchSessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-session-test-"))
        self.registry = self.root / "sessions.json"
        self.bottle = Bottle(
            "Test",
            self.root,
            self.root / "prefix",
            self.root / "logs",
            self.root / "downloads",
            self.root / "cache",
        )
        self.bottle.prefix.mkdir()

    def test_matching_uses_path_boundaries(self) -> None:
        session = {
            "executable": "/games/Example Game.exe",
            "install_dir": "/games",
            "prefix": str(self.bottle.prefix),
            "pids": [],
        }
        processes = {
            10: r"C:\games\Example Game.exe --windowed",
            11: "shell --note=/games/Example Game.exe.backup",
        }
        self.assertEqual(sessions._matching_pids(session, processes, {10, 11}), [10])

    def test_exact_executable_match_does_not_require_open_prefix_handle(self) -> None:
        session = {
            "executable": "/library/The Binding of Isaac Rebirth/isaac-ng.exe",
            "install_dir": "/library/The Binding of Isaac Rebirth",
            "prefix": str(self.bottle.prefix),
            "pids": [],
        }
        processes = {
            10: r"C:\Program Files (x86)\Steam\steamapps\common\The Binding of Isaac Rebirth\isaac-ng.exe",
            11: r"C:\games\isaac-ng.exe.backup",
        }
        self.assertEqual(sessions._matching_pids(session, processes, set()), [10])

    def test_same_executable_name_from_another_install_does_not_keep_session_running(self) -> None:
        session = {
            "executable": "/library/Expected Game/game.exe",
            "install_dir": "/library/Expected Game",
            "prefix": str(self.bottle.prefix),
            "pids": [],
        }
        processes = {
            10: r"C:\Games\Different Game\game.exe",
            11: r"C:\Games\Expected Game\game.exe",
        }
        self.assertEqual(sessions._matching_pids(session, processes, set()), [11])

    def test_reconcile_and_stop_one_process(self) -> None:
        proc = subprocess.Popen(["/bin/sleep", "30"], cwd=self.bottle.prefix)
        try:
            with (
                patch.object(sessions, "_registry_path", return_value=self.registry),
                patch.object(sessions, "_prefix_pids", return_value={proc.pid}),
            ):
                session = sessions.create_session(
                    bottle=self.bottle,
                    appid="test",
                    game="Sleep Test",
                    executable=Path("/bin/sleep"),
                    install_dir=None,
                    graphics_backend="none",
                    strategy="direct",
                )
                active = next(
                    item for item in sessions.reconcile_sessions()
                    if item["session_id"] == session["session_id"]
                )
                self.assertEqual(active["status"], "running")
                self.assertEqual(active["pids"], [proc.pid])

                stopped, stopped_pids = sessions.stop_session(session["session_id"])
                proc.wait(timeout=3)
                self.assertIsNotNone(stopped)
                self.assertEqual(stopped["status"], "exited")
                self.assertEqual(stopped_pids, [proc.pid])
        finally:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(timeout=3)

    def test_owned_steam_closes_after_last_game_and_grace_period(self) -> None:
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "_processes", return_value={}),
            patch.object(sessions, "_prefix_pids", return_value=set()),
            patch.object(sessions, "_steam_has_active_work", return_value=False),
            patch.object(sessions, "steam_is_running", return_value=True),
            patch.object(sessions, "_request_steam_shutdown", return_value=True) as shutdown,
        ):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="owned",
                game="Owned Steam Test",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="dxmt",
                strategy="steam",
                wine_path=Path("/usr/local/bin/wine64"),
                steam_started_by_nase=True,
            )
            sessions.update_session(
                session["session_id"],
                status="exited",
                steam_cleanup_after=time.time() - 1,
            )
            reconciled = sessions.reconcile_sessions()
            owned = next(item for item in reconciled if item["session_id"] == session["session_id"])
            self.assertEqual(owned["steam_cleanup_status"], "shutdown-requested")
            shutdown.assert_called_once()

    def test_observed_game_exits_without_waiting_for_launch_grace(self) -> None:
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "_processes", return_value={}),
            patch.object(sessions, "_prefix_pids", return_value=set()),
        ):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="quick-exit",
                game="Quick Exit Test",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="dxmt",
                strategy="steam",
                steam_started_by_nase=True,
            )
            last_seen = time.time() - sessions.PROCESS_EXIT_GRACE_SECONDS - 1
            sessions.update_session(session["session_id"], status="running", last_seen_at=last_seen)

            reconciled = sessions.reconcile_sessions()

            updated = next(item for item in reconciled if item["session_id"] == session["session_id"])
            self.assertEqual(updated["status"], "exited")
            self.assertIn("Cloud", updated["message"])
            self.assertGreaterEqual(
                updated["steam_cleanup_after"],
                time.time() + sessions.STEAM_CLEANUP_GRACE_SECONDS - 1,
            )

    def test_recent_cloud_log_defers_owned_steam_shutdown(self) -> None:
        cloud_log = self.bottle.prefix / "drive_c" / "Program Files (x86)" / "Steam" / "logs" / "cloud_log.txt"
        cloud_log.parent.mkdir(parents=True)
        cloud_log.write_text("Cloud sync started\n", encoding="utf-8")
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "_processes", return_value={}),
            patch.object(sessions, "_prefix_pids", return_value=set()),
            patch.object(sessions, "steam_is_running", return_value=True),
            patch.object(sessions, "_request_steam_shutdown", return_value=True) as shutdown,
        ):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="cloud-sync",
                game="Cloud Sync Test",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="dxmt",
                strategy="steam",
                wine_path=Path("/usr/local/bin/wine64"),
                steam_started_by_nase=True,
            )
            sessions.update_session(
                session["session_id"],
                status="exited",
                steam_cleanup_after=time.time() - 1,
            )

            reconciled = sessions.reconcile_sessions()

            updated = next(item for item in reconciled if item["session_id"] == session["session_id"])
            self.assertEqual(updated["steam_cleanup_status"], "pending")
            self.assertIn("Cloud sync", updated["message"])
            self.assertGreater(updated["steam_cleanup_after"], time.time())
            shutdown.assert_not_called()

    def test_unobserved_game_leaves_owned_steam_open(self) -> None:
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "_processes", return_value={}),
            patch.object(sessions, "_prefix_pids", return_value=set()),
            patch.object(sessions, "steam_is_running", return_value=True),
            patch.object(sessions, "_request_steam_shutdown", return_value=True) as shutdown,
        ):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="not-started",
                game="Needs Sign In",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="d3dmetal",
                strategy="steam",
                wine_path=Path("/usr/local/bin/wine64"),
                steam_started_by_nase=True,
            )
            sessions.update_session(session["session_id"], started_at=time.time() - sessions.LAUNCH_GRACE_SECONDS - 1)

            reconciled = sessions.reconcile_sessions()

            updated = next(item for item in reconciled if item["session_id"] == session["session_id"])
            self.assertEqual(updated["status"], "exited")
            self.assertEqual(updated["steam_cleanup_status"], "launch-not-observed")
            self.assertIsNone(updated["steam_cleanup_after"])
            self.assertIn("left open", updated["message"])
            shutdown.assert_not_called()

    def test_explicit_open_relinquishes_owned_steam(self) -> None:
        with patch.object(sessions, "_registry_path", return_value=self.registry):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="manual",
                game="Manual Steam Test",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="dxmt",
                strategy="steam",
                wine_path=Path("/usr/local/bin/wine64"),
                steam_started_by_nase=True,
            )
            sessions.mark_steam_opened_by_user(str(self.bottle.prefix))
            updated = next(item for item in sessions._load() if item["session_id"] == session["session_id"])
            self.assertFalse(updated["steam_started_by_nase"])
            self.assertEqual(updated["steam_cleanup_status"], "user-owned")


if __name__ == "__main__":
    unittest.main()
