from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mysteamwine import bottle


class AppSupportMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.home = Path(tempfile.mkdtemp(prefix="nase-data-root-test-"))
        self.support = self.home / "Library" / "Application Support"
        self.legacy = self.support / "MySteamWine"
        self.destination = self.support / "NASE"

    def test_migrates_legacy_root_and_rewrites_owned_metadata(self) -> None:
        jobs = self.legacy / "jobs"
        client_bin = self.legacy / "runtimes" / "source-client" / "legendary" / "bin"
        jobs.mkdir(parents=True)
        client_bin.mkdir(parents=True)
        (jobs / "job.json").write_text(
            f'{{"prefix": "{self.legacy / "bottles" / "Default" / "prefix"}"}}',
            encoding="utf-8",
        )
        launcher = client_bin / "legendary"
        launcher.write_text(f"#!{self.legacy}/python\n", encoding="utf-8")
        launcher.chmod(0o755)
        library_config = (
            self.legacy
            / "bottles"
            / "Default-DXMT"
            / "prefix"
            / "drive_c"
            / "Program Files (x86)"
            / "Steam"
            / "steamapps"
            / "libraryfolders.vdf"
        )
        library_config.parent.mkdir(parents=True)
        legacy_wine_path = "Z:" + str(self.legacy).replace("/", "\\\\")
        library_config.write_text(
            f'"libraryfolders"\n{{\n\t"1"\n\t{{\n\t\t"path" "{legacy_wine_path}\\\\bottles\\\\Default\\\\prefix"\n\t}}\n}}\n',
            encoding="utf-8",
        )
        registry = self.legacy / "bottles" / "Default-DXMT" / "prefix" / "user.reg"
        registry.write_text(
            f'@="{legacy_wine_path}\\\\bottles\\\\Default\\\\game.exe"\n',
            encoding="utf-8",
        )
        save_path = (
            self.legacy
            / "bottles"
            / "Default"
            / "prefix"
            / "drive_c"
            / "Game"
            / "savedatapath.txt"
        )
        save_path.parent.mkdir(parents=True)
        save_path.write_text(f"Modding Data Path: {self.legacy}/mods/\n", encoding="utf-8")
        overlay_link = self.legacy / "bottles" / "Default-DXMT" / "overlays" / "game.exe"
        overlay_link.parent.mkdir(parents=True)
        overlay_link.symlink_to(self.legacy / "bottles" / "Default" / "game.exe")
        external = self.home / "ExternalPrefix" / "user.reg"
        external.parent.mkdir()
        external.write_text(str(self.legacy), encoding="utf-8")

        with patch.object(Path, "home", return_value=self.home):
            resolved = bottle.app_support_root()

        self.assertEqual(resolved, self.destination)
        self.assertFalse(self.legacy.exists())
        self.assertIn(
            str(self.destination),
            (self.destination / "jobs" / "job.json").read_text(),
        )
        migrated_launcher = self.destination / launcher.relative_to(self.legacy)
        self.assertIn(str(self.destination), migrated_launcher.read_text())
        migrated_config = self.destination / library_config.relative_to(self.legacy)
        destination_wine_path = "Z:" + str(self.destination).replace("/", "\\\\")
        self.assertIn(destination_wine_path, migrated_config.read_text())
        self.assertNotIn("MySteamWine", migrated_config.read_text())
        migrated_registry = self.destination / registry.relative_to(self.legacy)
        self.assertNotIn("MySteamWine", migrated_registry.read_text())
        migrated_save_path = self.destination / save_path.relative_to(self.legacy)
        self.assertNotIn("MySteamWine", migrated_save_path.read_text())
        migrated_overlay_link = self.destination / overlay_link.relative_to(self.legacy)
        self.assertIn(str(self.destination), str(migrated_overlay_link.readlink()))
        self.assertTrue(migrated_launcher.stat().st_mode & 0o100)
        self.assertEqual(external.read_text(), str(self.legacy))
        self.assertTrue((self.destination / ".nase-data-root-v3").is_file())

    def test_v3_migration_runs_when_v2_marker_already_exists(self) -> None:
        config = self.destination / "bottles" / "Default-DXMT" / "libraryfolders.vdf"
        config.parent.mkdir(parents=True)
        (self.destination / ".nase-data-root-v2").write_text("older migration\n", encoding="utf-8")
        legacy_wine_path = "Z:" + str(self.legacy).replace("/", "\\\\")
        config.write_text(f'"path" "{legacy_wine_path}\\\\bottles\\\\Default"\n', encoding="utf-8")

        with patch.object(Path, "home", return_value=self.home):
            resolved = bottle.app_support_root()

        self.assertEqual(resolved, self.destination)
        self.assertNotIn("MySteamWine", config.read_text())
        self.assertTrue((self.destination / ".nase-data-root-v3").is_file())

    def test_falls_back_to_legacy_root_when_move_fails(self) -> None:
        self.legacy.mkdir(parents=True)
        with (
            patch.object(Path, "home", return_value=self.home),
            patch.object(Path, "rename", side_effect=PermissionError("denied")),
        ):
            resolved = bottle.app_support_root()

        self.assertEqual(resolved, self.legacy)
        self.assertTrue(self.legacy.is_dir())
        self.assertFalse(self.destination.exists())


if __name__ == "__main__":
    unittest.main()
