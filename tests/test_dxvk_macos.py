from __future__ import annotations

import tempfile
import unittest
import json
from pathlib import Path
from unittest.mock import patch

from nase.bottle import Bottle
from nase.dxvk import install_dxvk
from nase.steam import graphics_launch_environment
from nase.dxvk_macos import (
    PINNED_MOLTENVK_PAYLOADS,
    _gpu_from_dxvk_log,
    discover_moltenvk_source,
    verify_dxvk_macos_profile,
    dxvk_macos_launch_environment,
)


def write_pe(path: Path, machine: int) -> None:
    payload = bytearray(256)
    payload[0:2] = b"MZ"
    payload[0x3C:0x40] = (128).to_bytes(4, "little")
    payload[128:132] = b"PE\0\0"
    payload[132:134] = machine.to_bytes(2, "little")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


class DXVKMacOSProfileTests(unittest.TestCase):
    def test_launch_reinstall_cannot_apply_upstream_overrides_to_macos_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bottle = Bottle("DXVK", root, root / "prefix", root / "logs", root / "downloads", root / "cache")
            (root / "compatibility-profile.json").write_text(json.dumps({"profile": {"id": "dxvk-macos-pinned-v1"}}))
            source = root / "source"
            for arch, machine in (("x64", 0x8664), ("x32", 0x014c)):
                for name in ("d3d11", "d3d10core"):
                    write_pe(source / arch / f"{name}.dll", machine)
            bottle.prefix.mkdir()
            registry = bottle.prefix / "user.reg"
            registry.write_text('[Software\\\\Wine\\\\DllOverrides]\n"dxgi"="native"\n"*d3d9"="native,builtin"\n"custom"="native"\n')
            for _ in range(2):
                code, _ = install_dxvk(bottle=bottle, dxvk_source=source)
                self.assertEqual(code, 0)
                contents = registry.read_text()
                self.assertIn('"d3d11"="native"', contents)
                self.assertIn('"d3d10core"="native"', contents)
                self.assertNotIn('"dxgi"=', contents)
                self.assertNotIn('"*d3d9"=', contents)
                self.assertIn('"custom"="native"', contents)

    def test_game_launch_neutralizes_stale_registry_overrides(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bottle = Bottle("DXVK", root, root / "prefix", root / "logs", root / "downloads", root / "cache")
            native = root / "runtime/dxvk-macos/native/libMoltenVK.dylib"
            native.parent.mkdir(parents=True)
            native.write_bytes(b"test")
            with patch("nase.dxvk_macos._sha256", return_value=next(iter(PINNED_MOLTENVK_PAYLOADS))):
                env = graphics_launch_environment(bottle, "dxvk")
                probe_env = dxvk_macos_launch_environment(bottle)
            overrides = dict(item.split("=") for item in env["WINEDLLOVERRIDES"].split(";"))
            self.assertEqual(overrides["d3d11"], "n")
            self.assertEqual(overrides["dxgi"], "b")
            self.assertEqual(overrides["d3d9"], "b")
            self.assertEqual(env["WINEDLLOVERRIDES"], probe_env["WINEDLLOVERRIDES"])

    def test_managed_sikarugir_wine_supplies_moltenvk_automatically(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-managed-moltenvk-test-"))
        wine = root / "bin" / "wine"
        moltenvk = root / "lib" / "libMoltenVK.dylib"
        wine.parent.mkdir(parents=True)
        wine.write_bytes(b"wine")
        moltenvk.parent.mkdir(parents=True)
        moltenvk.write_bytes(b"managed-moltenvk")
        supported_sha = next(iter(PINNED_MOLTENVK_PAYLOADS))

        with patch("nase.dxvk_macos._sha256", return_value=supported_sha):
            discovered = discover_moltenvk_source(wine)

        self.assertEqual(discovered, moltenvk.resolve())

    def test_dxvk_log_gpu_parser_accepts_macos_device_format(self) -> None:
        text = "info:    Device name:     : Apple M2\n"
        self.assertEqual(_gpu_from_dxvk_log(text).lstrip(": "), "Apple M2")

    def test_verifier_rejects_renderer_override_conflicts(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-dxvk-macos-test-"))
        bottle = Bottle("Test", root, root / "prefix", root / "logs", root / "downloads", root / "cache")
        for directory, machine in (("system32", 0x8664), ("syswow64", 0x014C)):
            for name in ("d3d11.dll", "d3d10core.dll"):
                write_pe(bottle.drive_c / "windows" / directory / name, machine)
        bottle.prefix.mkdir(parents=True, exist_ok=True)
        (bottle.prefix / "user.reg").write_text(
            '[Software\\\\Wine\\\\DllOverrides]\n'
            '"d3d10core"="native"\n"d3d11"="native"\n"winemetal"="native"\n',
            encoding="utf-8",
        )
        checks = verify_dxvk_macos_profile(bottle)
        override = next(check for check in checks if check["name"] == "renderer-overrides")
        self.assertEqual(override["status"], "error")


if __name__ == "__main__":
    unittest.main()
