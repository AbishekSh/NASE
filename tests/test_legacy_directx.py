from __future__ import annotations

import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path
import zipfile

from nase.bottle import Bottle
from nase.legacy_directx import prepare_legacy_directx_overlay, reset_legacy_directx_overlay
from nase.steam import run_game_executable


def write_x86_pe(path: Path) -> None:
    payload = bytearray(256)
    payload[0:2] = b"MZ"
    payload[0x3C:0x40] = (128).to_bytes(4, "little")
    payload[128:132] = b"PE\0\0"
    payload[132:134] = (0x014C).to_bytes(2, "little")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(payload)


class LegacyDirectXOverlayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-overlay-test-"))
        self.bottle = Bottle("Test", self.root / "bottle", self.root / "prefix", self.root / "logs", self.root / "downloads", self.root / "cache")
        self.game = self.root / "shared" / "Game"
        self.executable = self.game / "game.exe"
        write_x86_pe(self.executable)
        (self.game / "Data").mkdir()
        (self.game / "Data" / "asset.bin").write_bytes(b"asset")
        source = self.root / "dgVoodoo2.zip"
        with zipfile.ZipFile(source, "w") as archive:
            for name in ("DDraw.dll", "D3DImm.dll"):
                dll = self.root / name
                write_x86_pe(dll)
                archive.write(dll, f"dgVoodoo2/MS/x86/{name}")
            archive.writestr("dgVoodoo2/dgVoodoo.conf", "[General]\n")
        self.source = source

    def test_overlay_keeps_shared_game_untouched(self) -> None:
        result = prepare_legacy_directx_overlay(
            bottle=self.bottle,
            game_id="1782380",
            game_dir=self.game,
            executable=self.executable,
            source=self.source,
        )

        overlay = Path(result["overlay_root"])
        self.assertTrue((overlay / "game.exe").is_symlink())
        self.assertTrue((overlay / "Data").is_symlink())
        self.assertTrue((overlay / "DDraw.dll").is_file())
        self.assertTrue((overlay / "D3DImm.dll").is_file())
        self.assertFalse((self.game / "DDraw.dll").exists())
        self.assertTrue(Path(result["manifest_path"]).is_file())

    def test_overlay_reset_does_not_remove_game(self) -> None:
        prepare_legacy_directx_overlay(
            bottle=self.bottle,
            game_id="1782380",
            game_dir=self.game,
            executable=self.executable,
            source=self.source,
        )
        self.assertTrue(reset_legacy_directx_overlay(bottle=self.bottle, game_id="1782380"))
        self.assertTrue(self.executable.is_file())
        self.assertTrue((self.game / "Data" / "asset.bin").is_file())

    def test_launch_preserves_overlay_executable_path(self) -> None:
        result = prepare_legacy_directx_overlay(
            bottle=self.bottle,
            game_id="1782380",
            game_dir=self.game,
            executable=self.executable,
            source=self.source,
        )
        overlay_executable = Path(result["overlay_executable"])
        wine = self.root / "wine"
        wine.write_text("", encoding="utf-8")

        with (
            patch("nase.steam.validate_executable_compatibility", return_value="x86"),
            patch("nase.steam._graphics_launch_env", return_value={}),
            patch("nase.steam.run_logged_detached", return_value=(0, "")) as run,
        ):
            run_game_executable(
                bottle=self.bottle,
                wine64_path=wine,
                executable=overlay_executable,
                cwd=Path(result["overlay_root"]),
                wait=False,
            )

        self.assertEqual(run.call_args.kwargs["cmd"][1], str(overlay_executable))


if __name__ == "__main__":
    unittest.main()
