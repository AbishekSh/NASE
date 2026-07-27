from __future__ import annotations

import tempfile
import unittest
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from mysteamwine.bottle import Bottle
import mysteamwine.cli as cli
import mysteamwine.profiles as profiles


class CompatibilityProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-profile-test-"))
        self.bottle = Bottle("Test-DXMT", root, root / "prefix", root / "logs", root / "downloads", root / "cache")
        self.source = root / "dxmt"
        self.source.mkdir()

    def test_dxvk_macos_profile_is_available_for_verified_setup(self) -> None:
        profile = profiles.profile_for("dxvk-macos-pinned-v1", "dxvk")
        self.assertTrue(profile.ready)

    def test_profile_manifest_rejects_runtime_drift(self) -> None:
        with (
            patch.object(profiles, "_wine_version", return_value="wine-11.0"),
            patch.object(profiles, "_source_fingerprint", return_value="source-a"),
            patch.object(profiles, "_runtime_id_for_source", return_value="dxmt-0.71"),
        ):
            profiles.bind_profile(
                bottle=self.bottle,
                profile_id="dxmt-wine-stable-11-v1",
                graphics_backend="dxmt",
                wine_path=Path("/runtime/wine"),
                graphics_source=self.source,
                require_ready=False,
            )

        with (
            patch.object(profiles, "_wine_version", return_value="wine-11.0"),
            patch.object(profiles, "_source_fingerprint", return_value="source-b"),
            patch.object(profiles, "_runtime_id_for_source", return_value="dxmt-0.71"),
            self.assertRaisesRegex(RuntimeError, "different compatibility stack"),
        ):
            profiles.bind_profile(
                bottle=self.bottle,
                profile_id="dxmt-wine-stable-11-v1",
                graphics_backend="dxmt",
                wine_path=Path("/runtime/wine"),
                graphics_source=self.source,
                require_ready=False,
            )

    def test_dxmt_profile_requires_wine_11(self) -> None:
        with (
            patch.object(profiles, "_wine_version", return_value="wine-10.0"),
            patch.object(profiles, "_runtime_id_for_source", return_value="dxmt-0.71"),
            self.assertRaisesRegex(RuntimeError, "Wine Stable 11"),
        ):
            profiles.bind_profile(
                bottle=self.bottle,
                profile_id="dxmt-wine-stable-11-v1",
                graphics_backend="dxmt",
                wine_path=Path("/runtime/wine"),
                graphics_source=self.source,
                require_ready=False,
            )

    def test_launch_requires_completed_profile_setup(self) -> None:
        with (
            patch.object(profiles, "_wine_version", return_value="wine-11.0"),
            patch.object(profiles, "_source_fingerprint", return_value="source-a"),
            patch.object(profiles, "_runtime_id_for_source", return_value="dxmt-0.71"),
        ):
            profiles.bind_profile(
                bottle=self.bottle,
                profile_id="dxmt-wine-stable-11-v1",
                graphics_backend="dxmt",
                wine_path=Path("/runtime/wine"),
                graphics_source=self.source,
                require_ready=False,
            )
            with self.assertRaisesRegex(RuntimeError, "needs profile setup"):
                profiles.bind_profile(
                    bottle=self.bottle,
                    profile_id="dxmt-wine-stable-11-v1",
                    graphics_backend="dxmt",
                    wine_path=Path("/runtime/wine"),
                    graphics_source=self.source,
                )
            profiles.mark_profile_ready(self.bottle)
            ready = profiles.bind_profile(
                bottle=self.bottle,
                profile_id="dxmt-wine-stable-11-v1",
                graphics_backend="dxmt",
                wine_path=Path("/runtime/wine"),
                graphics_source=self.source,
            )
            self.assertEqual(ready["setup_status"], "ready")

    def test_d3dmetal_profile_explains_deleted_runtime(self) -> None:
        missing_source = self.bottle.root / "deleted-wrapper" / "d3dmetal"
        with (
            patch.object(profiles, "_wine_version", return_value="wine-10.0 (Sikarugir)"),
            self.assertRaisesRegex(RuntimeError, "moved or deleted"),
        ):
            profiles.bind_profile(
                bottle=self.bottle,
                profile_id="d3dmetal-gptk-v1",
                graphics_backend="d3dmetal",
                wine_path=Path("/runtime/wine"),
                graphics_source=missing_source,
                require_ready=False,
            )

    def test_mark_ready_clears_failed_transaction_metadata(self) -> None:
        manifest_path = self.bottle.root / "compatibility-profile.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "profile": {"id": "dxmt-wine-stable-11-v1"},
                    "setup_status": "needs-repair",
                    "active_job_id": "old",
                    "last_failed_job": "old",
                    "last_failure": "failed",
                    "failed_at": 1,
                    "setup_started_at": 1,
                }
            ),
            encoding="utf-8",
        )

        ready = profiles.mark_profile_ready(self.bottle)

        self.assertEqual(ready["setup_status"], "ready")
        self.assertNotIn("last_failure", ready)
        self.assertNotIn("active_job_id", ready)

    def test_profile_setup_marks_the_bound_manifest_active(self) -> None:
        active_manifest: dict[str, object] = {
            "schema_version": 1,
            "profile": {"id": "dxmt-wine-stable-11-v1"},
        }
        args = SimpleNamespace(
            profile="dxmt-wine-stable-11-v1",
            repair=False,
            prefix=None,
            bottle=self.bottle.name,
            dxmt_source=str(self.source),
            d3dmetal_source=None,
            dxvk_source=None,
            moltenvk_source=None,
            json=False,
            jsonl=False,
        )

        with (
            patch.object(cli, "_require_wine64", return_value=Path("/runtime/wine")),
            patch.object(cli, "_resolve_bottle", return_value=self.bottle),
            patch.object(cli, "_is_external_prefix", return_value=False),
            patch.object(cli, "bind_profile", return_value=active_manifest),
            patch.object(cli, "ensure_bottle_dirs", side_effect=RuntimeError("stop after manifest")),
            patch.object(cli, "kill_wine_processes"),
            self.assertRaisesRegex(SystemExit, "stop after manifest"),
        ):
            cli.cmd_setup_compatibility_profile(args)

        self.assertEqual(active_manifest["setup_status"], "setting-up")
        self.assertIn("setup_started_at", active_manifest)

    def test_profile_delete_refuses_bottle_with_local_steam_games(self) -> None:
        steamapps = (
            self.bottle.prefix
            / "drive_c"
            / "Program Files (x86)"
            / "Steam"
            / "steamapps"
        )
        steamapps.mkdir(parents=True)
        (steamapps / "appmanifest_250900.acf").write_text("", encoding="utf-8")
        args = SimpleNamespace(
            profile="dxmt-wine-stable-11-v1",
            confirm=True,
            prefix=None,
            bottle=self.bottle.name,
            json=False,
            jsonl=False,
        )

        with (
            patch.object(cli, "_resolve_bottle", return_value=self.bottle),
            self.assertRaisesRegex(SystemExit, "Move them to the NASE Shared Library"),
        ):
            cli.cmd_reset_compatibility_profile(args)

    def test_import_migration_ignores_profiles_without_graphics_source(self) -> None:
        bottles_root = self.bottle.root / "bottles"
        plain_manifest = bottles_root / "Plain" / "compatibility-profile.json"
        plain_manifest.parent.mkdir(parents=True)
        plain_manifest.write_text(json.dumps({"graphics_source": None, "profile": {"id": "plain-wine-v1"}}))
        new_source = self.bottle.root / "managed-d3dmetal"
        windows = new_source / "wine" / "x86_64-windows"
        windows.mkdir(parents=True)

        with (
            patch.object(
                profiles,
                "inspect_d3dmetal_bundle",
                return_value=SimpleNamespace(root=new_source, windows_dir=windows),
            ),
            patch.object(profiles, "_source_fingerprint", return_value="managed"),
        ):
            migrated = profiles.migrate_imported_d3dmetal_profiles(
                old_source=self.bottle.root / "mounted",
                new_source=new_source,
                bottles_root=bottles_root,
            )

        self.assertEqual(migrated, 0)


if __name__ == "__main__":
    unittest.main()
