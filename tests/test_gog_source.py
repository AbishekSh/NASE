from __future__ import annotations

import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from mysteamwine.sources.gog import GOGSource, _authorization_code


class GOGSourceTests(unittest.TestCase):
    def test_extracts_code_from_gog_callback_url(self) -> None:
        self.assertEqual(
            _authorization_code("https://embed.gog.com/on_login_success?origin=client&code=fresh-code"),
            "fresh-code",
        )
        with self.assertRaises(ValueError):
            _authorization_code("https://embed.gog.com/on_login_success?origin=client")

    def test_status_does_not_treat_an_empty_token_file_as_authenticated(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "gogdl"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)
            with patch("mysteamwine.sources.gog.app_support_root", return_value=root / "support"):
                source = GOGSource(str(client))
                source.root.mkdir(parents=True)
                source.auth_path.write_text("", encoding="utf-8")
                self.assertFalse(source.status().authenticated)

    def test_authentication_keeps_code_out_of_command_arguments_when_cli_uses_stdin(self) -> None:
        commands: list[list[str]] = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "gogdl"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                commands.append(command)
                source.auth_path.parent.mkdir(parents=True, exist_ok=True)
                source.auth_path.write_text('{"token":"stored"}', encoding="utf-8")
                payload = {"access_token": "secret", "user_id": "42"}
                return subprocess.CompletedProcess(command, 0, json.dumps(payload), "")

            with patch("mysteamwine.sources.gog.app_support_root", return_value=root / "support"):
                source = GOGSource(str(client), runner=runner)
                status = source.authenticate(authorization_code="fresh-code")
                self.assertTrue(status.authenticated)
                self.assertEqual(source.auth_path.stat().st_mode & 0o777, 0o600)
        self.assertIn("--auth-config-path", commands[0])

    def test_lists_paginated_owned_games_with_art_and_install_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "gogdl"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                return subprocess.CompletedProcess(command, 0, '{"access_token":"token","user_id":"42"}', "")

            def fetch(url, headers):
                if "galaxy-library" in url:
                    return {"items": [{"platform_id": "gog", "external_id": "123", "certificate": "cert"}]}
                return {
                    "type": "game",
                    "game_id": "canonical-123",
                    "title": {"*": "Good Old Game"},
                    "game": {
                        "visible_in_library": True,
                        "background": {"url_format": "https://images.gog.com/banner.{ext}"},
                        "vertical_cover": {"url_format": "https://images.gog.com/cover.{ext}"},
                    },
                }

            with patch("mysteamwine.sources.gog.app_support_root", return_value=root / "support"):
                source = GOGSource(str(client), runner=runner, fetch_json=fetch)
                source.root.mkdir(parents=True)
                source.auth_path.write_text("{}", encoding="utf-8")
                source.installed_path.write_text('{"123":{"install_path":"/Games/Good","version":"1.0"}}', encoding="utf-8")
                games = source.list_games()
        self.assertEqual(len(games), 1)
        self.assertEqual(games[0].library_id, "gog:123")
        self.assertTrue(games[0].installed)
        self.assertEqual(games[0].art_url, "https://images.gog.com/banner.jpg")
        self.assertEqual(games[0].portrait_art_url, "https://images.gog.com/cover.jpg")

    def test_filters_hidden_spam_entitlements_and_duplicate_canonical_releases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "gogdl"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                return subprocess.CompletedProcess(command, 0, '{"access_token":"token","user_id":"42"}', "")

            def fetch(url, headers):
                if "galaxy-library" in url:
                    return {"items": [
                        {"platform_id": "gog", "external_id": "100"},
                        {"platform_id": "gog", "external_id": "101"},
                        {"platform_id": "gog", "external_id": "102"},
                    ]}
                game_id = url.rsplit("/", 1)[-1]
                if game_id == "102":
                    return {"type": "spam", "game_id": "junk", "title": {"*": "Game - Amazon Prime"},
                            "game": {"visible_in_library": False}}
                return {"type": "game", "game_id": "canonical-game", "title": {"*": "Game"},
                        "game": {"visible_in_library": True}}

            with patch("mysteamwine.sources.gog.app_support_root", return_value=root / "support"):
                source = GOGSource(str(client), runner=runner, fetch_json=fetch)
                source.root.mkdir(parents=True)
                source.auth_path.write_text("{}", encoding="utf-8")
                games = source.list_games()
        self.assertEqual([(game.store_id, game.title) for game in games], [("100", "Game")])

    def test_install_and_launch_use_windows_profile(self) -> None:
        commands: list[list[str]] = []
        launches: list[list[str]] = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            client = root / "gogdl"
            client.write_text("", encoding="utf-8")
            client.chmod(0o755)

            def runner(command, environment, timeout):
                commands.append(command)
                if "info" in command:
                    return subprocess.CompletedProcess(command, 0, '{"folder_name":"Game","versionName":"1.0"}', "")
                return subprocess.CompletedProcess(command, 0, "", "")

            def launcher(command, environment, log_path):
                launches.append(command)

            with patch("mysteamwine.sources.gog.app_support_root", return_value=root / "support"):
                source = GOGSource(str(client), runner=runner, launcher=launcher)
                source.install("123", base_path=root / "games")
                (root / "games" / "Game").mkdir(parents=True, exist_ok=True)
                source.launch("123", wine_path=root / "wine", wine_prefix=root / "prefix", environment={"DXVK_LOG_LEVEL": "info"})
        download = next(command for command in commands if "download" in command)
        launch = launches[0]
        self.assertIn("windows", download)
        self.assertIn("--wine-prefix", launch)


if __name__ == "__main__":
    unittest.main()
