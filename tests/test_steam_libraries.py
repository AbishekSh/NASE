from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from nase.bottle import Bottle
import nase.steam_libraries as steam_libraries


def write_manifest(steamapps: Path, appid: str, name: str, install_dir: str) -> Path:
    steamapps.mkdir(parents=True, exist_ok=True)
    manifest = steamapps / f"appmanifest_{appid}.acf"
    manifest.write_text(
        f'''"AppState"
{{
    "appid" "{appid}"
    "name" "{name}"
    "installdir" "{install_dir}"
    "StateFlags" "4"
}}
''',
        encoding="utf-8",
    )
    return manifest


class SteamLibraryRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-library-test-"))
        bottle_root = self.root / "bottles" / "Default"
        self.bottle = Bottle(
            "Default",
            bottle_root,
            bottle_root / "prefix",
            bottle_root / "logs",
            bottle_root / "downloads",
            bottle_root / "cache",
        )
        self.primary = self.bottle.prefix / "drive_c" / "Program Files (x86)" / "Steam" / "steamapps"
        self.external = self.root / "SharedSteam" / "steamapps"
        self.managed_shared = self.root / "NASESteamLibrary"
        self.shared_library_patch = patch.object(
            steam_libraries,
            "managed_shared_library",
            return_value=self.managed_shared,
        )
        self.shared_library_patch.start()
        self.addCleanup(self.shared_library_patch.stop)

    def test_discovers_deduplicates_and_prefers_installed_location(self) -> None:
        write_manifest(self.primary, "100", "Example Game", "Example Game")
        write_manifest(self.external, "100", "Example Game", "Example Game")
        (self.external / "common" / "Example Game").mkdir(parents=True)
        self.primary.mkdir(parents=True, exist_ok=True)
        (self.primary / "libraryfolders.vdf").write_text(
            f'''"libraryfolders"
{{
    "1"
    {{
        "path" "{self.external.parent}"
    }}
}}
''',
            encoding="utf-8",
        )

        with patch.object(steam_libraries, "list_bottle_roots", return_value=[]):
            registry = steam_libraries.discover_steam_libraries(self.bottle)

        self.assertEqual(len(registry["libraries"]), 3)
        self.assertEqual(len(registry["apps"]), 1)
        app = registry["apps"][0]
        self.assertEqual(len(app["locations"]), 2)
        self.assertEqual(app["preferred_location"]["state"], "installed")
        self.assertEqual(app["preferred_location"]["install_dir"], str((self.external / "common" / "Example Game").resolve()))

    def test_stale_manifest_remains_in_registry_but_not_installed_games(self) -> None:
        write_manifest(self.primary, "200", "Missing Game", "Missing Game")
        with patch.object(steam_libraries, "list_bottle_roots", return_value=[]):
            registry = steam_libraries.discover_steam_libraries(self.bottle)

        self.assertEqual(registry["apps"][0]["state"], "missing-files")
        self.assertEqual(steam_libraries.installed_games(registry), [])

    def test_resolves_registered_game_outside_active_prefix(self) -> None:
        manifest = write_manifest(self.external, "250", "Profile Independent", "Profile Independent")
        install_dir = self.external / "common" / "Profile Independent"
        install_dir.mkdir(parents=True)
        registry = {
            "libraries": [{
                "library_id": "library_external",
                "path": str(self.external.parent),
                "steamapps_path": str(self.external),
            }],
            "apps": [{
                "appid": "250",
                "name": "Profile Independent",
                "preferred_location": {
                    "library_id": "library_external",
                    "manifest_path": str(manifest),
                    "install_dir": str(install_dir),
                    "state": "installed",
                },
            }],
        }

        app, library_id = steam_libraries.resolve_registered_app(self.bottle, "250", registry=registry)

        self.assertEqual(app.install_dir, install_dir)
        self.assertEqual(app.manifest_path, manifest)
        self.assertEqual(library_id, "library_external")

    def test_registered_library_is_scanned_without_active_prefix_reference(self) -> None:
        write_manifest(self.external, "275", "Registry Game", "Registry Game")
        (self.external / "common" / "Registry Game").mkdir(parents=True)
        registered = {
            "libraries": [{
                "library_id": "library_external",
                "path": str(self.external.parent),
                "steamapps_path": str(self.external),
                "referenced_by": [],
            }],
        }

        with patch.object(steam_libraries, "list_bottle_roots", return_value=[]):
            registry = steam_libraries.discover_steam_libraries(self.bottle, registered)

        self.assertEqual([app["appid"] for app in registry["apps"]], ["275"])

    def test_registry_write_is_atomic_and_reloadable(self) -> None:
        write_manifest(self.primary, "300", "Saved Game", "Saved Game")
        (self.primary / "common" / "Saved Game").mkdir(parents=True)
        destination = self.root / "steam-libraries.json"
        with (
            patch.object(steam_libraries, "list_bottle_roots", return_value=[]),
            patch.object(steam_libraries, "registry_path", return_value=destination),
        ):
            registry = steam_libraries.refresh_registry(self.bottle)

        self.assertTrue(destination.is_file())
        self.assertFalse(destination.with_suffix(".tmp").exists())
        self.assertEqual(steam_libraries.installed_games(registry)[0]["appid"], "300")

    def test_managed_shared_library_is_created_and_registered(self) -> None:
        with patch.object(steam_libraries, "list_bottle_roots", return_value=[]):
            registry = steam_libraries.discover_steam_libraries(self.bottle)

        managed = next(library for library in registry["libraries"] if library.get("managed"))
        self.assertEqual(managed["path"], str(self.managed_shared.resolve()))
        self.assertTrue((self.managed_shared / "steamapps").is_dir())

    def test_attach_shares_files_without_copying_them_into_profile(self) -> None:
        write_manifest(self.external, "400", "Shared Game", "Shared Game")
        shared_game = self.external / "common" / "Shared Game"
        shared_game.mkdir(parents=True)
        shared_exe = shared_game / "Shared.exe"
        shared_exe.write_text("game-data", encoding="utf-8")
        registry = {
            "libraries": [{
                "library_id": "library_shared",
                "path": str(self.external.parent),
                "steamapps_path": str(self.external),
                "exists": True,
                "writable": True,
                "referenced_by": [{"bottle": "Default", "prefix": str(self.bottle.prefix), "source": "primary"}],
            }],
            "apps": [{
                "appid": "400",
                "name": "Shared Game",
                "locations": [{
                    "library_id": "library_shared",
                    "state": "installed",
                    "install_dir": str(shared_game),
                }],
            }],
        }
        steam_root = self.bottle.prefix / "drive_c" / "Program Files (x86)" / "Steam"
        steam_root.mkdir(parents=True)
        (steam_root / "Steam.exe").write_text("", encoding="utf-8")
        config = steam_root / "steamapps" / "libraryfolders.vdf"
        config.parent.mkdir()
        config.write_text('"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path" "C:\\\\Program Files (x86)\\\\Steam"\n\t}\n}\n', encoding="utf-8")

        with patch.object(steam_libraries, "steam_is_running", return_value=False):
            result = steam_libraries.attach_registered_libraries(self.bottle, registry)
            repeated = steam_libraries.attach_registered_libraries(self.bottle, registry)

        self.assertEqual(len(result["attached"]), 1)
        self.assertEqual(len(repeated["already_attached"]), 1)
        self.assertIsNotNone(result["backup_path"])
        self.assertTrue(Path(result["backup_path"]).is_file())
        self.assertIn("Z:\\\\", config.read_text(encoding="utf-8"))
        self.assertEqual(shared_exe.read_text(encoding="utf-8"), "game-data")
        self.assertFalse((config.parent / "common" / "Shared Game").exists())

    def test_attach_refuses_while_target_steam_is_running(self) -> None:
        steam_root = self.bottle.prefix / "drive_c" / "Program Files (x86)" / "Steam"
        steam_root.mkdir(parents=True)
        (steam_root / "Steam.exe").write_text("", encoding="utf-8")
        registry = {"libraries": [], "apps": []}

        with (
            patch.object(steam_libraries, "steam_is_running", return_value=True),
            self.assertRaisesRegex(RuntimeError, "Close Steam"),
        ):
            steam_libraries.attach_registered_libraries(self.bottle, registry)


if __name__ == "__main__":
    unittest.main()
