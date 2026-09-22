from __future__ import annotations

import argparse
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from nase import cli, sessions
from nase.bottle import Bottle
from nase.sources.base import InstalledGame


class FakeSource:
    """Minimal stand-in for EpicSource/GOGSource."""

    def __init__(self, *, install_path: Path | None, raises: Exception | None = None) -> None:
        self.install_path = install_path
        self.raises = raises
        self.launched: list[str] = []

    def installed_game(self, game_id: str) -> InstalledGame | None:
        if self.raises:
            raise self.raises
        if self.install_path is None:
            return None
        return InstalledGame(title="Cool Game", install_path=str(self.install_path))

    def launch(self, game_id: str, **_: object) -> None:
        self.launched.append(game_id)


class StoreLaunchSessionTests(unittest.TestCase):
    """Epic and GOG launches must be tracked like Steam and Wine launches.

    Without a session record nothing could ever contradict the UI's optimistic
    "Running", so a store game stayed lit until the app was restarted.
    """

    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-store-launch-"))
        self.registry = self.root / "sessions.json"
        self.bottle = Bottle(
            "Test",
            self.root,
            self.root / "prefix",
            self.root / "logs",
            self.root / "downloads",
            self.root / "cache",
        )
        self.bottle.prefix.mkdir(parents=True)
        self.install_dir = self.root / "game-libraries" / "gog" / "Cool Game"
        self.install_dir.mkdir(parents=True)

    def _launch(self, source: FakeSource) -> dict:
        args = argparse.Namespace(
            source="gog",
            game_id="12345",
            json=True,
            jsonl=False,
            dxmt_source=None,
            dxvk_source=None,
            d3dmetal_source=None,
            compatibility_profile=None,
        )
        captured: dict = {}
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(cli, "_resolve_bottle", return_value=self.bottle),
            patch.object(cli, "_require_wine64", return_value=Path("/usr/bin/true")),
            patch.object(cli, "_resolved_graphics_backend", return_value="none"),
            patch.object(cli, "_bind_launch_profile", return_value="plain-wine-v1"),
            patch.object(cli, "graphics_launch_environment", return_value={}),
            patch.object(cli, "_game_source", return_value=source),
            patch.object(sessions, "_processes", return_value={}),
            patch.object(sessions, "_prefix_pids", return_value=set()),
            patch.object(cli, "_identity_result", lambda _args, **kwargs: captured.update(kwargs)),
        ):
            cli.cmd_launch_source_game(args)
        return captured

    def test_launch_records_a_tracked_session(self) -> None:
        source = FakeSource(install_path=self.install_dir)
        captured = self._launch(source)

        self.assertEqual(source.launched, ["12345"])
        stored = json.loads(self.registry.read_text(encoding="utf-8"))["sessions"]
        self.assertEqual(len(stored), 1)
        session = stored[0]
        # The qualified id keeps an Epic and a GOG game from colliding.
        self.assertEqual(session["appid"], "gog:12345")
        self.assertEqual(session["strategy"], "store")
        self.assertEqual(session["game"], "Cool Game")
        self.assertEqual(session["install_dir"], str(self.install_dir))
        # The result carries the session so the UI can bind it immediately.
        self.assertEqual(captured["data"]["session"]["session_id"], session["session_id"])

    def test_unresolvable_install_still_records_a_session(self) -> None:
        source = FakeSource(install_path=None, raises=RuntimeError("provider offline"))
        self._launch(source)

        stored = json.loads(self.registry.read_text(encoding="utf-8"))["sessions"]
        self.assertEqual(len(stored), 1)
        self.assertEqual(stored[0]["appid"], "gog:12345")
        self.assertIsNone(stored[0]["install_dir"])
        self.assertEqual(source.launched, ["12345"])

    def test_failed_launch_marks_the_session_failed(self) -> None:
        source = FakeSource(install_path=self.install_dir)
        source.launch = lambda *_args, **_kwargs: (_ for _ in ()).throw(RuntimeError("gogdl missing"))
        args = argparse.Namespace(
            source="gog",
            game_id="12345",
            json=True,
            jsonl=False,
            dxmt_source=None,
            dxvk_source=None,
            d3dmetal_source=None,
            compatibility_profile=None,
        )
        with (
            patch.object(sessions, "_registry_path", return_value=self.registry),
            patch.object(cli, "_resolve_bottle", return_value=self.bottle),
            patch.object(cli, "_require_wine64", return_value=Path("/usr/bin/true")),
            patch.object(cli, "_resolved_graphics_backend", return_value="none"),
            patch.object(cli, "_bind_launch_profile", return_value="plain-wine-v1"),
            patch.object(cli, "graphics_launch_environment", return_value={}),
            patch.object(cli, "_game_source", return_value=source),
            patch.object(cli, "_json_error", side_effect=SystemExit(1)),
        ):
            with self.assertRaises(SystemExit):
                cli.cmd_launch_source_game(args)

        stored = json.loads(self.registry.read_text(encoding="utf-8"))["sessions"]
        self.assertEqual(stored[0]["status"], "failed")


if __name__ == "__main__":
    unittest.main()
