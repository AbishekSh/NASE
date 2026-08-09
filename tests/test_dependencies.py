from __future__ import annotations

import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import nase.dependencies as dependencies


class DependencyStatusTests(unittest.TestCase):
    def test_recommended_dxmt_stack_is_ready_without_optional_gptk(self) -> None:
        runtimes = [
            SimpleNamespace(id="dxmt-0.71", path="/managed/dxmt-0.71"),
            SimpleNamespace(id="gstreamer-1.28.2-macos-universal", path="/managed/GStreamer.framework"),
        ]
        with (
            patch.object(dependencies.platform, "mac_ver", return_value=("14.7", ("", "", ""), "")),
            patch.object(dependencies.platform, "python_version", return_value="3.12.0"),
            patch.object(dependencies.sys, "version_info", (3, 12)),
            patch.object(dependencies, "_rosetta_installed", return_value=True),
            patch.object(dependencies, "_command_version", return_value=(0, "wine-11.0")),
            patch.object(dependencies, "list_installed_runtimes", return_value=runtimes),
            patch.object(dependencies.shutil, "which", return_value="/opt/homebrew/bin/winetricks"),
            patch.object(Path, "is_file", return_value=True),
            patch.object(dependencies.subprocess, "run", return_value=SimpleNamespace(stdout="arm64", returncode=0)),
        ):
            result = dependencies.dependency_status(wine_path=Path("/opt/homebrew/bin/wine"))

        self.assertTrue(result["ready"])
        self.assertEqual(result["worst_status"], "warn")
        self.assertEqual(result["missing_required"], [])

    def test_missing_core_dependencies_are_actionable(self) -> None:
        with (
            patch.object(dependencies.platform, "mac_ver", return_value=("14.0", ("", "", ""), "")),
            patch.object(dependencies.platform, "python_version", return_value="3.12.0"),
            patch.object(dependencies.sys, "version_info", (3, 12)),
            patch.object(dependencies, "_rosetta_installed", return_value=False),
            patch.object(dependencies, "_command_version", return_value=(0, "wine-10.0")),
            patch.object(dependencies, "list_installed_runtimes", return_value=[]),
            patch.object(dependencies.shutil, "which", return_value=None),
            patch.object(dependencies.subprocess, "run", return_value=SimpleNamespace(stdout="arm64", returncode=0)),
        ):
            result = dependencies.dependency_status(wine_path=Path("/missing/wine"))

        self.assertFalse(result["ready"])
        self.assertEqual(
            result["missing_required"],
            ["Rosetta 2", "GStreamer 1.28.2", "Winetricks", "Wine Stable 11", "DXMT 0.71"],
        )
        failed = [check for check in result["checks"] if check["status"] == "fail"]
        self.assertTrue(all(check["fix"] for check in failed))

    def test_rosetta_requires_explicit_license_confirmation(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "explicit acceptance"):
            dependencies.dependency_install_command("rosetta")
        self.assertEqual(
            dependencies.dependency_install_command("rosetta", confirm_rosetta_license=True),
            ["/usr/sbin/softwareupdate", "--install-rosetta", "--agree-to-license"],
        )

    def test_host_dependency_installer_rejects_managed_dependencies(self) -> None:
        for dependency in ("gstreamer", "wine-stable", "winetricks"):
            with self.assertRaisesRegex(RuntimeError, "managed NASE runtime"):
                dependencies.dependency_install_command(dependency)
        with self.assertRaisesRegex(RuntimeError, "bundled inside NASE"):
            dependencies.dependency_install_command("python")

    def test_python_support_policy_matches_bundled_and_legendary_runtime(self) -> None:
        for version in ((3, 10), (3, 13), (3, 14)):
            with (
                patch.object(dependencies.platform, "mac_ver", return_value=("14.0", ("", "", ""), "")),
                patch.object(dependencies.platform, "python_version", return_value=f"{version[0]}.{version[1]}.0"),
                patch.object(dependencies.sys, "version_info", version),
                patch.object(dependencies, "_rosetta_installed", return_value=True),
                patch.object(dependencies, "_command_version", return_value=(0, "wine-11.0")),
                patch.object(
                    dependencies,
                    "list_installed_runtimes",
                    return_value=[
                        SimpleNamespace(id="dxmt-0.71", path="/dxmt"),
                        SimpleNamespace(id="gstreamer-1.28.2-macos-universal", path="/gstreamer"),
                    ],
                ),
                patch.object(dependencies, "installed_runtime_executable", return_value=Path("/managed/winetricks")),
                patch.object(Path, "is_file", return_value=True),
                patch.object(dependencies.subprocess, "run", return_value=SimpleNamespace(stdout="arm64", returncode=0)),
            ):
                python_check = dependencies.dependency_status(wine_path=Path("/wine"))["checks"][1]
            self.assertEqual(python_check["status"], "ok")


if __name__ == "__main__":
    unittest.main()
