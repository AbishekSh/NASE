from __future__ import annotations

import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from nase import steam_identity
from nase.bottle import bottle_paths
from nase.steam import parse_vdf_file, steam_prefix_root


LOGINUSERS = '''"users"
{
    "76561198000000000"
    {
        "AccountName" "tester"
        "RememberPassword" "1"
    }
}
'''

CONFIG = '''"InstallConfigStore"
{
    "Software"
    {
        "Valve"
        {
            "Steam"
            {
                "Accounts" { "tester" { "SteamID" "76561198000000000" } }
                "ShaderCacheManager" { "KeepMe" "yes" }
            }
        }
    }
}
'''

LOCALCONFIG = '''"UserLocalConfigStore"
{
    "SharedAuth" { "AuthData" "secret-value" }
    "Software" { "KeepMe" "yes" }
}
'''


class SteamIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.home_patch = patch("pathlib.Path.home", return_value=self.home)
        self.home_patch.start()
        self.source = bottle_paths("Source")
        self.target = bottle_paths("Target")
        self._install_signed_in_steam(self.source)
        self._install_steam(self.target)

    def tearDown(self) -> None:
        self.home_patch.stop()
        self.temporary.cleanup()

    def _install_steam(self, bottle) -> None:
        root = steam_prefix_root(bottle)
        (root / "config").mkdir(parents=True, exist_ok=True)
        (root / "config" / "config.vdf").write_text(CONFIG.replace('"tester"', '"target"'), encoding="utf-8")
        bottle.prefix.mkdir(parents=True, exist_ok=True)
        (bottle.prefix / "user.reg").write_text(
            'WINE REGISTRY Version 2\n\n[Software\\\\Valve\\\\Steam]\n"AutoLoginUser"="old"\n"KeepMe"="yes"\n',
            encoding="utf-8",
        )

    def _install_signed_in_steam(self, bottle) -> None:
        self._install_steam(bottle)
        root = steam_prefix_root(bottle)
        (root / "config" / "config.vdf").write_text(CONFIG, encoding="utf-8")
        (root / "config" / "loginusers.vdf").write_text(LOGINUSERS, encoding="utf-8")
        local = root / "userdata" / "123" / "config" / "localconfig.vdf"
        local.parent.mkdir(parents=True)
        local.write_text(LOCALCONFIG, encoding="utf-8")
        (bottle.prefix / "user.reg").write_text(
            'WINE REGISTRY Version 2\n\n[Software\\\\Valve\\\\Steam]\n"AutoLoginUser"="tester"\n',
            encoding="utf-8",
        )

    def test_capture_uses_restrictive_permissions_and_redacted_status(self) -> None:
        with patch.object(steam_identity, "steam_is_running", return_value=False):
            status = steam_identity.capture_steam_identity(self.source)
        self.assertTrue(status["available"])
        self.assertEqual(status["account_count"], 1)
        self.assertNotIn("tester", json.dumps(status))
        self.assertEqual(os.stat(steam_identity.identity_root()).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(steam_identity._snapshot_path()).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(steam_identity._manifest_path()).st_mode & 0o777, 0o600)

    def test_capture_refuses_when_any_managed_steam_is_running(self) -> None:
        with patch.object(steam_identity, "steam_is_running", side_effect=lambda prefix: prefix == str(self.target.prefix)):
            with self.assertRaisesRegex(RuntimeError, "Still running: Target"):
                steam_identity.capture_steam_identity(self.source)
        self.assertFalse(steam_identity._snapshot_path().exists())

    def test_provision_merges_only_auth_subtrees(self) -> None:
        with patch.object(steam_identity, "steam_is_running", return_value=False):
            steam_identity.capture_steam_identity(self.source)
            result = steam_identity.provision_steam_identity(self.target)
        self.assertEqual(result["target_bottle"], "Target")
        config = parse_vdf_file(steam_prefix_root(self.target) / "config" / "config.vdf")
        steam = config["InstallConfigStore"]["Software"]["Valve"]["Steam"]
        self.assertEqual(steam["ShaderCacheManager"]["KeepMe"], "yes")
        self.assertIn("tester", steam["Accounts"])
        local = parse_vdf_file(steam_prefix_root(self.target) / "userdata" / "123" / "config" / "localconfig.vdf")
        self.assertEqual(local["UserLocalConfigStore"]["SharedAuth"]["AuthData"], "secret-value")
        registry = (self.target.prefix / "user.reg").read_text(encoding="utf-8")
        self.assertIn('"AutoLoginUser"="tester"', registry)
        self.assertIn('"KeepMe"="yes"', registry)

    def test_sign_out_preserves_unrelated_profile_configuration(self) -> None:
        with patch.object(steam_identity, "steam_is_running", return_value=False):
            steam_identity.capture_steam_identity(self.source)
            steam_identity.provision_steam_identity(self.target)
            result = steam_identity.sign_out_steam_profile(self.target)
        self.assertTrue(result["signed_out"])
        self.assertFalse((steam_prefix_root(self.target) / "config" / "loginusers.vdf").exists())
        config = parse_vdf_file(steam_prefix_root(self.target) / "config" / "config.vdf")
        steam = config["InstallConfigStore"]["Software"]["Valve"]["Steam"]
        self.assertNotIn("Accounts", steam)
        self.assertEqual(steam["ShaderCacheManager"]["KeepMe"], "yes")
        registry = (self.target.prefix / "user.reg").read_text(encoding="utf-8")
        self.assertNotIn("AutoLoginUser", registry)
        self.assertIn('"KeepMe"="yes"', registry)

    def test_forget_does_not_sign_out_profiles(self) -> None:
        loginusers = steam_prefix_root(self.source) / "config" / "loginusers.vdf"
        with patch.object(steam_identity, "steam_is_running", return_value=False):
            steam_identity.capture_steam_identity(self.source)
            result = steam_identity.forget_steam_identity()
        self.assertTrue(result["profiles_unchanged"])
        self.assertTrue(loginusers.exists())
        self.assertFalse(steam_identity._snapshot_path().exists())

    def test_provision_rejects_a_modified_snapshot(self) -> None:
        with patch.object(steam_identity, "steam_is_running", return_value=False):
            steam_identity.capture_steam_identity(self.source)
            steam_identity._snapshot_path().write_text('{}\n', encoding="utf-8")
            with self.assertRaisesRegex(RuntimeError, "integrity check"):
                steam_identity.provision_steam_identity(self.target)


if __name__ == "__main__":
    unittest.main()
