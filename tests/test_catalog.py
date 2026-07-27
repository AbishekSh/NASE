from __future__ import annotations

import hashlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import mysteamwine.catalog as catalog
from mysteamwine.catalog import CATALOG


class DownloadResponse(io.BytesIO):
    def __init__(self, payload: bytes) -> None:
        super().__init__(payload)
        self.headers = {"Content-Length": str(len(payload))}


class RuntimeCatalogTests(unittest.TestCase):
    def test_gog_clients_are_checksum_pinned_for_both_mac_architectures(self) -> None:
        entries = [item for item in CATALOG if item.id.startswith("gogdl-1.2.2-macos-")]
        self.assertEqual({entry.id.rsplit("-", 1)[-1] for entry in entries}, {"arm64", "x86_64"})
        self.assertTrue(all(entry.sha256 and len(entry.sha256) == 64 for entry in entries))
        self.assertTrue(all(entry.install_layout == "source-client-binary" for entry in entries))

    def test_legendary_epic_client_is_checksum_pinned(self) -> None:
        entry = next(item for item in CATALOG if item.id == "legendary-python-0.20.34-macos")
        self.assertEqual(entry.kind, "source-client")
        self.assertEqual(entry.archive_type, "wheel")
        self.assertEqual(entry.sha256, "14f56c337f705346a4bfe27a14e56d60eecbe6508cc0a580ef18d1e44813136c")

    def test_sikarugir_wine_10_is_checksum_pinned(self) -> None:
        runtime = next(entry for entry in CATALOG if entry.id == "wine-sikarugir-10.0-r6")

        self.assertEqual(runtime.version, "10.0 revision 6")
        self.assertEqual(runtime.archive_type, "tar.xz")
        self.assertEqual(runtime.sha256, "9da7ee0cbf386522f3a9906943726d9c3c125dbbd9ab120e3cde80e88d6091b2")
        self.assertTrue(runtime.download_url.endswith("WS12WineSikarugir10.0_6.tar.xz"))

    def test_default_wine_and_winetricks_are_managed_and_checksum_pinned(self) -> None:
        wine = next(entry for entry in CATALOG if entry.id == "wine-stable-11.0_1-gcenx")
        winetricks = next(entry for entry in CATALOG if entry.id == "winetricks-20260125")
        gstreamer = next(entry for entry in CATALOG if entry.id == "gstreamer-1.28.2-macos-universal")

        self.assertEqual(wine.kind, "wine")
        self.assertEqual(wine.sha256, "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388")
        self.assertEqual(winetricks.kind, "tool")
        self.assertEqual(winetricks.install_layout, "tool-script")
        self.assertEqual(winetricks.sha256, "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b")
        self.assertEqual(gstreamer.install_layout, "gstreamer-framework")
        self.assertEqual(gstreamer.sha256, "964ff693002aaa69b2908f79967609b424ddc61210849e1afe5e8d8810f68b91")

    def test_corrupt_cached_download_is_replaced_atomically(self) -> None:
        payload = b"verified runtime payload"
        entry = catalog.RuntimeCatalogEntry(
            id="test-runtime",
            name="Test Runtime",
            version="1",
            kind="test",
            source="test",
            download_url="https://example.invalid/runtime.bin",
            sha256=hashlib.sha256(payload).hexdigest(),
            archive_type="binary",
            install_layout="test",
            license="test",
            notes="test",
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "runtime.bin"
            destination.write_bytes(b"partial")
            with (
                patch.object(catalog, "downloads_root", return_value=root),
                patch.object(catalog.urllib.request, "urlopen", return_value=io.BytesIO(payload)),
            ):
                result = catalog._download(entry)

            self.assertEqual(result.read_bytes(), payload)
            self.assertFalse((root / "runtime.bin.partial").exists())

    def test_download_reports_byte_and_percentage_progress(self) -> None:
        payload = b"x" * (3 * 1024 * 1024)
        entry = catalog.RuntimeCatalogEntry(
            id="progress-runtime",
            name="Progress Runtime",
            version="1",
            kind="test",
            source="test",
            download_url="https://example.invalid/progress.bin",
            sha256=hashlib.sha256(payload).hexdigest(),
            archive_type="binary",
            install_layout="test",
            license="test",
            notes="test",
        )
        updates: list[tuple[str, str, str]] = []
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with (
                patch.object(catalog, "downloads_root", return_value=root),
                patch.object(catalog.urllib.request, "urlopen", return_value=DownloadResponse(payload)),
            ):
                result = catalog._download(entry, lambda name, status, message: updates.append((name, status, message)))

            self.assertEqual(result.read_bytes(), payload)
            progress_messages = [message for name, status, message in updates if name == "download" and status == "started"]
            self.assertTrue(any("MiB" in message and "%" in message for message in progress_messages))
            self.assertTrue(any("(100%)" in message for message in progress_messages))


if __name__ == "__main__":
    unittest.main()
