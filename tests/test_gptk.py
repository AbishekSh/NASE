from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from nase.bottle import Bottle
from nase.d3dmetal import d3dmetal_launch_environment, enable_d3dmetal_overrides, verify_d3dmetal_profile
import nase.gptk as gptk
from nase.gptk import inspect_gptk_installation


class GPTKTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-gptk-test-"))
        self.installation = self.root / "Game Porting Toolkit 2"
        self.wine = self.installation / "bin" / "wine"
        self.wine.parent.mkdir(parents=True)
        self.wine.write_text("#!/bin/sh\necho 'wine-10.0 (Sikarugir)'\n", encoding="utf-8")
        self.wine.chmod(0o755)
        self.payload = self.installation / "lib" / "wine" / "x86_64-windows"
        self.payload.mkdir(parents=True)
        for name in ("dxgi.dll", "d3d11.dll", "d3d12.dll"):
            (self.payload / name).write_text(name, encoding="utf-8")
        unix = self.installation / "lib" / "wine" / "x86_64-unix"
        unix.mkdir(parents=True)
        (unix / "d3d11.so").write_text("unix", encoding="utf-8")
        external = self.installation / "external"
        framework = external / "D3DMetal.framework" / "Versions" / "A"
        framework.mkdir(parents=True)
        (framework / "D3DMetal").write_text("framework", encoding="utf-8")
        (external / "libd3dshared.dylib").write_text("shared", encoding="utf-8")

    def test_inspection_pairs_wine_and_payload_from_one_installation(self) -> None:
        result = inspect_gptk_installation(self.wine, self.installation)

        self.assertEqual(result["wine_version"], "wine-10.0 (Sikarugir)")
        self.assertEqual(Path(result["payload_path"]), self.payload.resolve())

    def test_discovers_apple_evaluation_payload_with_configured_wine(self) -> None:
        mounted_payload = self.root / "Evaluation environment for Windows games 2.1" / "redist" / "lib"
        shutil.copytree(self.installation / "lib" / "wine", mounted_payload / "wine")
        shutil.copytree(self.installation / "external", mounted_payload / "external")

        with patch.object(gptk, "_candidate_roots", return_value=[mounted_payload]):
            found = gptk.discover_gptk_installations(configured_wine=self.wine)

        self.assertEqual(len(found), 1)
        self.assertEqual(found[0]["d3dmetal_source"], str(mounted_payload.resolve()))

    def test_inspection_rejects_incomplete_payload(self) -> None:
        unrelated = self.root / "Downloads" / "d3dmetal" / "x86_64-windows"
        unrelated.mkdir(parents=True)
        (unrelated / "dxgi.dll").write_text("", encoding="utf-8")
        (unrelated / "d3d11.dll").write_text("", encoding="utf-8")

        with self.assertRaisesRegex(FileNotFoundError, "Unix Wine modules"):
            inspect_gptk_installation(self.wine, unrelated.parent)

    def test_inspection_rejects_unsupported_wine_engine(self) -> None:
        self.wine.write_text("#!/bin/sh\necho wine-11.0\n", encoding="utf-8")

        with self.assertRaisesRegex(RuntimeError, "requires a tested Wine engine"):
            inspect_gptk_installation(self.wine, self.installation)

    def test_launch_environment_points_to_preserved_bundle(self) -> None:
        environment = d3dmetal_launch_environment(self.installation)

        self.assertEqual(environment["WINEDLLPATH_PREPEND"], str((self.installation / "lib" / "wine").resolve()))
        self.assertEqual(environment["WINEESYNC"], "1")
        self.assertEqual(environment["WINEMSYNC"], "1")
        self.assertEqual(environment["CX_D3DMETALPATH"], str(self.installation.resolve()))
        self.assertEqual(environment["CX_APPLEGPTK_LIBD3DSHARED_PATH"], str((self.installation / "external" / "libd3dshared.dylib").resolve()))

    def test_wrapper_launch_environment_includes_native_frameworks(self) -> None:
        framework_root = self.root / "Wrapper.app" / "Contents" / "Frameworks"
        renderer = framework_root / "renderer" / "d3dmetal"
        shutil.copytree(self.installation / "lib" / "wine", renderer / "wine")
        shutil.copytree(self.installation / "external", renderer / "external")

        environment = d3dmetal_launch_environment(renderer)

        self.assertIn(str(framework_root.resolve()), environment["DYLD_FALLBACK_LIBRARY_PATH"].split(":"))

    def test_profile_verification_reports_dlls_overrides_and_steam(self) -> None:
        bottle_root = self.root / "bottle"
        bottle = Bottle("D3DMetal", bottle_root, bottle_root / "prefix", bottle_root / "logs", bottle_root / "downloads", bottle_root / "cache")
        system32 = bottle.drive_c / "windows" / "system32"
        system32.mkdir(parents=True)
        for name in ("dxgi.dll", "d3d11.dll", "d3d12.dll"):
            (system32 / name).write_text("", encoding="utf-8")
        steam = bottle.drive_c / "Program Files (x86)" / "Steam" / "Steam.exe"
        steam.parent.mkdir(parents=True)
        steam.write_text("", encoding="utf-8")
        (bottle.prefix / "user.reg").write_text(
            '[Software\\\\Wine\\\\DllOverrides]\n"winemetal"="native,builtin"\n"d3d9"="native"\n',
            encoding="utf-8",
        )
        enable_d3dmetal_overrides(bottle)

        checks = verify_d3dmetal_profile(bottle, self.installation)

        self.assertTrue(all(check["status"] == "ok" for check in checks))
        registry = (bottle.prefix / "user.reg").read_text(encoding="utf-8")
        self.assertNotIn('"winemetal"=', registry)
        self.assertNotIn('"d3d9"=', registry)

    def test_managed_import_requires_license_and_copies_paired_runtime(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "explicit acceptance"):
            gptk.import_managed_gptk(wine_path=self.wine, d3dmetal_source=self.installation)

        managed_root = self.root / "Application Support"
        with patch.object(gptk, "app_support_root", return_value=managed_root):
            installed = gptk.import_managed_gptk(
                wine_path=self.wine,
                d3dmetal_source=self.installation,
                confirm_license=True,
            )

        self.assertTrue(installed["managed"])
        self.assertTrue(Path(installed["wine_path"]).is_file())
        self.assertTrue(Path(installed["payload_path"]).is_dir())
        self.assertEqual(Path(installed["d3dmetal_source"]).name, "d3dmetal")
        self.assertTrue(str(Path(installed["installation_root"]).resolve()).startswith(str(managed_root.resolve())))

    def test_managed_wrapper_import_preserves_framework_dependencies(self) -> None:
        contents = self.root / "Wrapper.app" / "Contents"
        wrapper_wine = contents / "SharedSupport" / "wine" / "bin" / "wine"
        wrapper_wine.parent.mkdir(parents=True)
        wrapper_wine.write_text("#!/bin/sh\necho 'wine-10.0 (Sikarugir)'\n", encoding="utf-8")
        wrapper_wine.chmod(0o755)
        renderer = contents / "Frameworks" / "renderer" / "d3dmetal"
        shutil.copytree(self.installation / "lib" / "wine", renderer / "wine")
        shutil.copytree(self.installation / "external", renderer / "external")
        (contents / "Frameworks" / "libinotify.0.dylib").write_text("native", encoding="utf-8")

        with patch.object(gptk, "app_support_root", return_value=self.root / "managed"):
            installed = gptk.import_managed_gptk(
                wine_path=wrapper_wine,
                d3dmetal_source=renderer,
                confirm_license=True,
            )

        managed_wine = Path(installed["wine_path"])
        managed_contents = next(path for path in managed_wine.parents if path.name == "Contents")
        managed_frameworks = managed_contents / "Frameworks"
        self.assertTrue((managed_frameworks / "libinotify.0.dylib").is_file())
        fallback = d3dmetal_launch_environment(Path(installed["d3dmetal_source"]))["DYLD_FALLBACK_LIBRARY_PATH"]
        self.assertIn(str(managed_frameworks), fallback.split(":"))

    def test_prepare_sikarugir_native_dependencies_copies_and_verifies_dependency(self) -> None:
        contents = self.root / "Wrapper.app" / "Contents"
        renderer = contents / "Frameworks" / "renderer" / "d3dmetal"
        renderer.mkdir(parents=True)
        dependency = contents / "Frameworks" / "libinotify.0.dylib"
        dependency.write_bytes(b"paired native dependency")
        freetype = contents / "Frameworks" / "libfreetype.6.dylib"
        freetype.write_bytes(b"paired freetype dependency")
        (contents / "Frameworks" / "libfreetype.dylib").symlink_to(freetype.name)
        wine = self.root / "engine" / "bin" / "wine"
        wineserver = wine.with_name("wineserver")
        wine.parent.mkdir(parents=True)
        wine.write_text("wine", encoding="utf-8")
        wineserver.write_text("wineserver", encoding="utf-8")

        with patch.object(gptk.subprocess, "run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = "@rpath/libinotify.0.dylib"
            run.return_value.stderr = ""
            installed = gptk.prepare_sikarugir_native_dependencies(wine, renderer)

        destination = self.root / "engine" / "lib" / "libinotify.0.dylib"
        self.assertEqual(destination.read_bytes(), dependency.read_bytes())
        self.assertEqual(Path(installed["installed_path"]), destination.resolve())
        self.assertEqual(installed["sha256"], gptk._sha256(dependency))
        self.assertEqual(installed["verified_library_count"], 2)
        self.assertEqual((destination.parent / "libfreetype.6.dylib").read_bytes(), freetype.read_bytes())
        self.assertEqual((destination.parent / "libfreetype.dylib").readlink(), Path(freetype.name))


if __name__ == "__main__":
    unittest.main()
