from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from nase.pe import PE_MACHINE_AMD64, PE_MACHINE_I386, executable_architecture, pe_machine


class PEArchitectureTests(unittest.TestCase):
    def make_pe(self, machine: int) -> Path:
        path = Path(tempfile.mkdtemp(prefix="nase-pe-test-")) / "test.exe"
        payload = bytearray(256)
        payload[0:2] = b"MZ"
        payload[0x3C:0x40] = (128).to_bytes(4, "little")
        payload[128:132] = b"PE\0\0"
        payload[132:134] = machine.to_bytes(2, "little")
        path.write_bytes(payload)
        return path

    def test_detects_x86_pe(self) -> None:
        path = self.make_pe(PE_MACHINE_I386)
        self.assertEqual(pe_machine(path), PE_MACHINE_I386)
        self.assertEqual(executable_architecture(path), "x86")

    def test_detects_x64_pe(self) -> None:
        path = self.make_pe(PE_MACHINE_AMD64)
        self.assertEqual(executable_architecture(path), "x86_64")

    def test_non_pe_is_unknown(self) -> None:
        path = Path(tempfile.mkdtemp(prefix="nase-pe-test-")) / "text.exe"
        path.write_text("not an executable", encoding="utf-8")
        self.assertEqual(executable_architecture(path), "unknown")


if __name__ == "__main__":
    unittest.main()
