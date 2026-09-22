import signal
import unittest
from unittest.mock import patch

from nase import sessions


class StopRecoveryTests(unittest.TestCase):
    def stop(self, *, force=False, exits=False):
        session = {"session_id": "game", "status": "running", "prefix": "/test", "pids": [101]}
        processes = {101: "game.exe", 202: "steam.exe", 303: "other-game.exe"}
        with (
            patch.object(sessions, "reconcile_sessions", return_value=[session]),
            patch.object(sessions, "_processes", side_effect=[processes, {}] if exits else [processes]),
            patch.object(sessions, "_prefix_pids", return_value={101, 202, 303}),
            patch.object(sessions, "_matching_pids", return_value=[101]),
            patch.object(sessions, "update_session", side_effect=lambda _, **fields: {**session, **fields}),
            patch.object(sessions.os, "kill") as kill,
            patch.object(sessions.time, "monotonic", side_effect=[0, 1] if exits else [0, 6]),
            patch.object(sessions.time, "sleep"),
        ):
            result, stopped = sessions.stop_session("game", force=force)
        return result, stopped, kill

    def test_normal_stop_does_not_automatically_force_quit(self):
        result, stopped, kill = self.stop()
        kill.assert_called_once_with(101, signal.SIGTERM)
        self.assertEqual(result["status"], "stopping")
        self.assertEqual(stopped, [])

    def test_force_quit_targets_only_matched_game(self):
        result, stopped, kill = self.stop(force=True, exits=True)
        kill.assert_called_once_with(101, signal.SIGKILL)
        self.assertEqual(result["status"], "exited")
        self.assertEqual(stopped, [101])

    def test_force_quit_does_not_claim_success_while_process_remains(self):
        result, stopped, _ = self.stop(force=True)
        self.assertEqual(result["status"], "stopping")
        self.assertEqual(stopped, [])
