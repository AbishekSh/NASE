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
        self.assertTrue(migrated_launcher.stat().st_mode & 0o100)
        self.assertEqual(external.read_text(), str(self.legacy))
        self.assertTrue((self.destination / ".nase-data-root-v1").is_file())

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
