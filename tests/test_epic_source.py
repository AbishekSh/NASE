from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from mysteamwine.sources.epic import EpicSource, _authenticated_from_status, normalize_epic_games


class EpicSourceTests(unittest.TestCase):
    def test_legendary_logged_out_placeholder_is_not_authenticated(self) -> None:
        self.assertFalse(_authenticated_from_status({"account": "<not logged in>", "games_available": 0}))
        self.assertFalse(_authenticated_from_status({"account": "not logged in"}))
        self.assertTrue(_authenticated_from_status({"account": "real-user"}))

    def test_normalizes_owned_and_installed_games(self) -> None:
        owned = [
            {"app_name": "Anemone", "app_title": "World of Goo"},
            {"app_name": "Cattail", "app_title": "A Game"},
        ]
        installed = [
            {"app_name": "Anemone", "install_path": "/Games/WorldOfGoo", "version": "1.2"}
        ]
        games = normalize_epic_games(owned, installed)
        self.assertEqual([game.library_id for game in games], ["epic:Cattail", "epic:Anemone"])
        world = games[1]
        self.assertTrue(world.installed)
        self.assertEqual(world.install_path, "/Games/WorldOfGoo")
        self.assertEqual(world.version, "1.2")

    def test_normalizes_official_epic_wide_artwork(self) -> None:
        wide = "https://cdn1.epicgames.com/item/game-wide.jpg"
        tall = "https://cdn1.epicgames.com/item/game-tall.jpg"
        owned = [{
            "app_name": "Mushroom",
            "app_title": "Among Friends",
            "metadata": {
                "keyImages": [
                    {"type": "DieselGameBoxTall", "width": 1200, "height": 1600, "url": tall},
                    {"type": "DieselGameBox", "width": 2560, "height": 1440, "url": wide},
                ]
            },
        }]
        game = normalize_epic_games(owned, [])[0]
        self.assertEqual(game.art_url, wide)
        self.assertEqual(game.portrait_art_url, tall)

    def test_artwork_falls_back_to_a_safe_available_image(self) -> None:
        fallback = "https://cdn2.unrealengine.com/item/fallback.jpg"
        owned = [{
            "app_name": "Fallback",
            "metadata": {
                "title": "Fallback Game",
                "keyImages": [
                    {"type": "Logo", "url": "file:///tmp/private.png"},
                    {"type": "UnknownArtwork", "width": 800, "height": 450, "url": fallback},
                ],
            },
        }]
        games = normalize_epic_games(owned, [])
        self.assertEqual(games[0].art_url, fallback)

    def test_missing_client_has_friendly_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary, \
             patch("mysteamwine.sources.epic.shutil.which", return_value=None), \
             patch("mysteamwine.sources.epic.app_support_root", return_value=Path(temporary)):
            status = EpicSource("missing-legendary").status()
        self.assertFalse(status.available)
        self.assertFalse(status.authenticated)
        self.assertNotIn(str(Path.home()), status.message)

    def test_library_commands_use_windows_platform_and_private_config(self) -> None:
        calls: list[tuple[list[str], dict[str, str], int]] = []

        def runner(command, environment, timeout):
            calls.append((command, environment, timeout))
            payload = (
                [{"app_name": "Anemone", "app_title": "World of Goo"}]
                if command[1] == "list"
                else [{"app_name": "Anemone", "install_path": "/Games/WorldOfGoo"}]
            )
            return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            client = home / "legendary"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)
            with patch("pathlib.Path.home", return_value=home):
                source = EpicSource(str(client), runner=runner)
                games = source.list_games(force_refresh=True)
                self.assertEqual(len(games), 1)
                self.assertIn("Windows", calls[0][0])
                self.assertIn("--force-refresh", calls[0][0])
                config = Path(calls[0][1]["XDG_CONFIG_HOME"])
                self.assertEqual(config, source.config_root)
                self.assertEqual(os.stat(source.root).st_mode & 0o777, 0o700)
                self.assertEqual(os.stat(source.config_root).st_mode & 0o777, 0o700)

    def test_auth_code_is_not_logged_or_placed_in_errors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            client = Path(temporary) / "legendary"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                if "auth" in command:
                    return subprocess.CompletedProcess(command, 1, "", "authentication rejected")
                return subprocess.CompletedProcess(command, 0, "{}", "")

            source = EpicSource(str(client), runner=runner)
            with self.assertRaisesRegex(RuntimeError, "authentication rejected") as raised:
                source.authenticate(authorization_code="super-secret-code")
            self.assertNotIn("super-secret-code", str(raised.exception))

    def test_zero_exit_without_credentials_is_not_reported_as_connected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "legendary"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch("mysteamwine.sources.epic.app_support_root", return_value=root / "support"):
                source = EpicSource(str(client), runner=runner)
                with self.assertRaisesRegex(RuntimeError, "did not accept"):
                    source.authenticate(authorization_code="unused-code")

    def test_auth_accepts_complete_epic_json_response(self) -> None:
        commands: list[list[str]] = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "legendary"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)
            source = EpicSource(str(client), runner=lambda command, environment, timeout: subprocess.CompletedProcess(command, 0, "", ""))

            def runner(command, environment, timeout):
                commands.append(command)
                if command[1] == "auth":
                    credentials = source.config_root / "legendary" / "user.json"
                    credentials.parent.mkdir(parents=True, exist_ok=True)
                    credentials.write_text('{"refresh_token":"test"}', encoding="utf-8")
                if command[1] == "status":
                    return subprocess.CompletedProcess(command, 0, '{"account_id":"123"}', "")
                return subprocess.CompletedProcess(command, 0, "", "")

            with patch("mysteamwine.sources.epic.app_support_root", return_value=root / "support"):
                source = EpicSource(str(client), runner=runner)
                status = source.authenticate(authorization_code='{"authorizationCode": "short-code"}')
        self.assertTrue(status.authenticated)
        self.assertIn("short-code", commands[0])

    def test_game_operations_are_non_shell_commands(self) -> None:
        commands: list[list[str]] = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "legendary"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                commands.append(command)
                return subprocess.CompletedProcess(command, 0, "", "")

            source = EpicSource(str(client), runner=runner)
            source.install("Anemone", base_path=root / "games")
            source.update("Anemone")
            source.verify("Anemone")
            source.repair("Anemone")
            source.uninstall("Anemone")
        self.assertIn("--platform", commands[0])
        self.assertIn("Windows", commands[0])
        self.assertIn("--update-only", commands[1])
        self.assertEqual(commands[2][1:3], ["verify", "Anemone"])
        self.assertIn("--repair-and-update", commands[3])
        self.assertEqual(commands[4][1:4], ["-y", "uninstall", "Anemone"])

    def test_launch_receives_profile_environment(self) -> None:
        captured: dict[str, object] = {}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "legendary"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def launcher(command, environment, log_path):
                captured["command"] = command
                captured["environment"] = environment
                captured["log_path"] = log_path

            EpicSource(str(client), launcher=launcher).launch(
                "Anemone",
                wine_path=root / "wine",
                wine_prefix=root / "prefix",
                environment={"WINEDLLOVERRIDES": "d3d11=n,b"},
            )
        self.assertIn("--wine-prefix", captured["command"])
        self.assertEqual(captured["environment"]["WINEDLLOVERRIDES"], "d3d11=n,b")
        self.assertEqual(captured["log_path"].name, "launch-Anemone.log")


if __name__ == "__main__":
    unittest.main()
