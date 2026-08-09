from __future__ import annotations

import tempfile
import unittest
import json
from pathlib import Path
from unittest.mock import patch

import nase.library_activity as activity
import nase.sessions as sessions


class SteamLibraryActivityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-library-activity-test-"))
        self.path = self.root / "activity.json"

    def acquire(self, prefix: str, bottle: str, appid: str = "100") -> dict:
        return activity.acquire_steam_activity(
            library_id="library_shared",
            prefix=prefix,
            bottle=bottle,
            profile_id=f"profile-{bottle}",
            appid=appid,
        )

    def test_same_profile_can_launch_separate_games(self) -> None:
        with patch.object(activity, "activity_path", return_value=self.path):
            self.acquire("/prefix/a", "DXMT", "100")
            owner = self.acquire("/prefix/a", "DXMT", "200")

        self.assertEqual(owner["active_appids"], ["100", "200"])

    def test_other_profile_is_blocked_while_owner_steam_runs(self) -> None:
        with (
            patch.object(activity, "activity_path", return_value=self.path),
            patch.object(sessions, "steam_is_running", side_effect=lambda prefix: prefix == "/prefix/a"),
        ):
            self.acquire("/prefix/a", "DXMT")
            with self.assertRaisesRegex(RuntimeError, "currently owned by DXMT"):
                self.acquire("/prefix/b", "D3DMetal")

    def test_stale_owner_is_replaced_when_steam_is_closed(self) -> None:
        with patch.object(activity, "activity_path", return_value=self.path):
            self.acquire("/prefix/a", "DXMT")
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            payload["owners"]["library_shared"]["updated_at"] = 0
            self.path.write_text(json.dumps(payload), encoding="utf-8")
        with (
            patch.object(activity, "activity_path", return_value=self.path),
            patch.object(sessions, "steam_is_running", return_value=False),
        ):
            owner = self.acquire("/prefix/b", "D3DMetal")

        self.assertEqual(owner["prefix"], "/prefix/b")

    def test_direct_launch_is_blocked_while_library_has_update_work(self) -> None:
        downloading = self.root / "SteamLibrary" / "steamapps" / "downloading" / "100"
        downloading.mkdir(parents=True)
        (downloading / "chunk.bin").write_text("update", encoding="utf-8")

        with self.assertRaisesRegex(RuntimeError, "updating shared library files"):
            activity.assert_direct_launch_safe(library_path=self.root / "SteamLibrary", appid="200")


if __name__ == "__main__":
    unittest.main()
