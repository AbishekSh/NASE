from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from mysteamwine.bottle import Bottle
from mysteamwine.dxvk_macos import (
    PINNED_MOLTENVK_PAYLOADS,
    _gpu_from_dxvk_log,
    discover_moltenvk_source,
    verify_dxvk_macos_profile,
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
    def test_managed_sikarugir_wine_supplies_moltenvk_automatically(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="nase-managed-moltenvk-test-"))
        wine = root / "bin" / "wine"
        moltenvk = root / "lib" / "libMoltenVK.dylib"
        wine.parent.mkdir(parents=True)
        wine.write_bytes(b"wine")
        moltenvk.parent.mkdir(parents=True)
        moltenvk.write_bytes(b"managed-moltenvk")
        supported_sha = next(iter(PINNED_MOLTENVK_PAYLOADS))

        with patch("mysteamwine.dxvk_macos._sha256", return_value=supported_sha):
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
