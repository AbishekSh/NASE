from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from nase import runtime


class SubprocessEchoTests(unittest.TestCase):
    def setUp(self) -> None:
        self.log = Path(tempfile.mkdtemp(prefix="nase-runtime-test-")) / "run.log"

    def tearDown(self) -> None:
        runtime.set_subprocess_echo(True)

    def _run(self, *, timeout: int | None) -> tuple[str, str]:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code, tail = runtime.run_logged(cmd=["/bin/echo", "wine says hello"], env=None, log_file=self.log, timeout=timeout)
        self.assertEqual(code, 0)
        self.assertIn("wine says hello", tail)
        self.assertIn("wine says hello", self.log.read_text(encoding="utf-8"))
        return stdout.getvalue(), tail

    def test_structured_modes_keep_subprocess_output_in_the_log_only(self) -> None:
        runtime.set_subprocess_echo(False)
        for timeout in (None, 30):
            with self.subTest(timeout=timeout):
                printed, _ = self._run(timeout=timeout)
                self.assertEqual(printed, "")

    def test_plain_mode_still_shows_subprocess_output(self) -> None:
        runtime.set_subprocess_echo(True)
        printed, _ = self._run(timeout=None)
        self.assertIn("wine says hello", printed)


if __name__ == "__main__":
    unittest.main()
