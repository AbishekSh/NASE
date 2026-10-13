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

    def test_store_install_on_another_drive_is_tracked(self) -> None:
        """Epic/GOG games live outside the prefix, so Wine maps them off C:."""
        session = {
            "executable": None,
            "install_dir": "/Users/test/game-libraries/gog/Cool Game",
            "prefix": str(self.bottle.prefix),
            "pids": [],
        }
        processes = {10: r"Z:\Users\test\game-libraries\gog\Cool Game\cool.exe"}
        self.assertEqual(sessions._matching_pids(session, processes, {10}), [10])

    def test_lsof_timeout_does_not_escape_reconcile(self) -> None:
        timeout = subprocess.TimeoutExpired(cmd="lsof", timeout=10)
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "_processes", return_value={}),
            patch.object(sessions.subprocess, "run", side_effect=timeout),
        ):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="slow-lsof",
                game="Slow Lsof Test",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="dxmt",
                strategy="direct",
            )
            reconciled = sessions.reconcile_sessions()
            updated = next(item for item in reconciled if item["session_id"] == session["session_id"])
            # A timed-out lsof degrades to name matching, it does not crash the
            # poller that the UI depends on.
            self.assertIn(updated["status"], {"launching", "exited"})

    def test_unreadable_process_table_leaves_running_session_alone(self) -> None:
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "_prefix_pids", return_value=set()),
        ):
            session = sessions.create_session(
                bottle=self.bottle,
                appid="ps-failure",
                game="Process Table Test",
                executable=Path("/games/test.exe"),
                install_dir=Path("/games"),
                graphics_backend="dxmt",
                strategy="direct",
            )
            sessions.update_session(
                session["session_id"],
                status="running",
                last_seen_at=time.time() - 600,
                started_at=time.time() - 600,
            )
            with patch.object(sessions, "_processes", return_value=None):
                reconciled = sessions.reconcile_sessions()
            updated = next(item for item in reconciled if item["session_id"] == session["session_id"])
            # A failed `ps` means "unknown", never "the game exited".
            self.assertEqual(updated["status"], "running")

    def test_process_table_timeout_reports_unknown(self) -> None:
        with patch.object(
            sessions.subprocess,
            "run",
            side_effect=subprocess.TimeoutExpired(cmd="ps", timeout=5),
        ):
            self.assertIsNone(sessions._processes())


    def _create(self, appid: str, **extra) -> dict:
        return sessions.create_session(
            bottle=self.bottle,
            appid=appid,
            game=f"Game {appid}",
            executable=Path(f"/games/{appid}/game.exe"),
            install_dir=Path(f"/games/{appid}"),
            graphics_backend="dxmt",
            strategy="direct",
            **extra,
        )

    def test_launch_registered_during_reconcile_is_kept(self) -> None:
        launched: list[dict] = []

        def launch_while_inspecting(_prefix: str) -> set[int]:
            launched.append(self._create("second"))
            return {4242}

        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "reconcile_shared_steam_client"),
            patch.object(sessions, "_processes", return_value={4242: r"C:\games\first\game.exe"}),
            patch.object(sessions, "_prefix_pids", side_effect=launch_while_inspecting),
        ):
            first = self._create("first")
            reconciled = sessions.reconcile_sessions()

        by_id = {item["session_id"]: item for item in reconciled}
        self.assertEqual(by_id[first["session_id"]]["status"], "running")
        self.assertEqual(by_id[launched[0]["session_id"]]["status"], "launching")
        with patch.object(sessions, "_registry_path", return_value=self.registry):
            stored = {item["session_id"] for item in sessions._load()}
        self.assertIn(launched[0]["session_id"], stored)

    def test_update_made_during_reconcile_is_not_overwritten(self) -> None:
        def stop_while_inspecting(_prefix: str) -> set[int]:
            sessions.update_session(first["session_id"], status="stopping", message="Stopping game processes.")
            return {4242}

        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "reconcile_shared_steam_client"),
            patch.object(sessions, "_processes", return_value={4242: r"C:\games\first\game.exe"}),
            patch.object(sessions, "_prefix_pids", side_effect=stop_while_inspecting),
        ):
            first = self._create("first")
            sessions.reconcile_sessions()
            stored = next(item for item in sessions._load() if item["session_id"] == first["session_id"])

        self.assertEqual(stored["status"], "stopping")

    def test_owned_steam_stays_open_for_a_launch_registered_during_reconcile(self) -> None:
        def launch_while_listing_processes() -> dict[int, str]:
            self._create("second")
            return {}

        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "reconcile_shared_steam_client"),
            patch.object(sessions, "_processes", side_effect=launch_while_listing_processes),
            patch.object(sessions, "_prefix_pids", return_value=set()),
            patch.object(sessions, "_steam_has_active_work", return_value=False),
            patch.object(sessions, "steam_is_running", return_value=True),
            patch.object(sessions, "_request_steam_shutdown", return_value=True) as shutdown,
        ):
            finished = self._create("first", wine_path=Path("/usr/local/bin/wine64"), steam_started_by_nase=True)
            sessions.update_session(finished["session_id"], status="exited", steam_cleanup_after=time.time() - 1)
            sessions.reconcile_sessions()

        shutdown.assert_not_called()


    def _steam_handoff_session(self, age_seconds: float) -> dict:
        session = self._create("250900")
        sessions.update_session(
            session["session_id"],
            strategy="steam-fallback",
            started_at=time.time() - age_seconds,
        )
        return session

    def test_steam_handoff_keeps_launching_while_steam_updates_the_game(self) -> None:
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "reconcile_shared_steam_client"),
            patch.object(sessions, "_processes", return_value={7: r"C:\Program Files (x86)\Steam\Steam.exe -silent"}),
            patch.object(sessions, "_prefix_pids", return_value={7}),
            patch.object(sessions, "_steam_has_active_work", return_value=True),
        ):
            session = self._steam_handoff_session(age_seconds=90)
            reconciled = next(item for item in sessions.reconcile_sessions() if item["session_id"] == session["session_id"])

        self.assertEqual(reconciled["status"], "launching")
        self.assertIn("updating", reconciled["message"])

    def test_steam_handoff_is_tracked_once_the_game_finally_starts(self) -> None:
        steam_only = {7: r"C:\Program Files (x86)\Steam\Steam.exe -silent"}
        with_game = {**steam_only, 8: r"C:\games\250900\game.exe"}
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(sessions, "reconcile_shared_steam_client"),
            patch.object(sessions, "_processes", side_effect=[steam_only, with_game]),
            patch.object(sessions, "_prefix_pids", return_value={7, 8}),
            patch.object(sessions, "_steam_has_active_work", return_value=False),
        ):
            session = self._steam_handoff_session(age_seconds=90)
            sessions.reconcile_sessions()
            reconciled = next(item for item in sessions.reconcile_sessions() if item["session_id"] == session["session_id"])

        self.assertEqual(reconciled["status"], "running")
        self.assertEqual(reconciled["pids"], [8])

    def test_steam_handoff_gives_up_when_steam_is_closed_or_after_the_cap(self) -> None:
        for processes, age in (({}, 90), ({7: r"C:\Program Files (x86)\Steam\Steam.exe"}, sessions.STEAM_HANDOFF_GRACE_SECONDS + 1)):
            with self.subTest(steam_running=bool(processes), age=age):
                self.registry.unlink(missing_ok=True)
                with (
                    patch.object(sessions, "_registry_path", return_value=self.registry),
                    patch.object(sessions, "reconcile_shared_steam_client"),
                    patch.object(sessions, "_processes", return_value=processes),
                    patch.object(sessions, "_prefix_pids", return_value=set(processes)),
                    patch.object(sessions, "_steam_has_active_work", return_value=False),
                ):
                    session = self._steam_handoff_session(age_seconds=age)
                    reconciled = next(item for item in sessions.reconcile_sessions() if item["session_id"] == session["session_id"])
                self.assertEqual(reconciled["status"], "exited")

    def test_steam_handoff_outlasts_the_launch_window_while_steam_downloads(self) -> None:
        cases = (
            (sessions.STEAM_HANDOFF_GRACE_SECONDS + 60, True, "launching"),
            (sessions.STEAM_HANDOFF_GRACE_SECONDS + 60, False, "exited"),
            (sessions.STEAM_UPDATE_GRACE_SECONDS + 1, True, "exited"),
        )
        for age, downloading, expected in cases:
            with self.subTest(age=age, downloading=downloading):
                self.registry.unlink(missing_ok=True)
                with (
                    patch.object(sessions, "_registry_path", return_value=self.registry),
                    patch.object(sessions, "reconcile_shared_steam_client"),
                    patch.object(sessions, "_processes", return_value={7: r"C:\Program Files (x86)\Steam\Steam.exe"}),
                    patch.object(sessions, "_prefix_pids", return_value={7}),
                    patch.object(sessions, "_steam_has_active_work", return_value=downloading),
                ):
                    session = self._steam_handoff_session(age_seconds=age)
                    reconciled = next(item for item in sessions.reconcile_sessions() if item["session_id"] == session["session_id"])
                self.assertEqual(reconciled["status"], expected)


if __name__ == "__main__":
    unittest.main()
