from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import nase.cli as cli
from nase.jobs import load_job


class StreamedJobLifecycleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-cli-jobs-test-"))
        self.support_patch = patch("nase.jobs.app_support_root", return_value=self.root)
        self.support_patch.start()
        cli._OPEN_STREAM_JOB.clear()
        self.args = cli.argparse.Namespace(json=False, jsonl=True)

    def tearDown(self) -> None:
        self.support_patch.stop()
        cli._OPEN_STREAM_JOB.clear()

    def _job_ids_on_disk(self) -> list[str]:
        return sorted(path.stem for path in (self.root / "jobs").glob("*.json"))

    def test_step_status_does_not_replace_job_status(self) -> None:
        with contextlib.redirect_stdout(io.StringIO()):
            job_id = cli._stream_start(action="setup-metal", message="Starting")
            cli._stream_step(action="setup-metal", job_id=job_id, name="wineboot", status="ok", message="Done")

        job = load_job(job_id)
        self.assertEqual(job["status"], "started")
        self.assertEqual(job["steps"][0]["status"], "ok")

    def test_error_after_start_fails_the_open_job_instead_of_starting_another(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
            job_id = cli._stream_start(action="debug-game", message="Launching")
            cli._json_error(self.args, action="debug-game", message="Executable is not compatible.")

        self.assertEqual(self._job_ids_on_disk(), [job_id])
        self.assertEqual(load_job(job_id)["status"], "failed")
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([event["event"] for event in events], ["job", "result"])
        self.assertEqual(events[-1]["job_id"], job_id)
        self.assertEqual(cli._OPEN_STREAM_JOB, {})

    def test_uncaught_exception_fails_the_open_job(self) -> None:
        def crashing_handler(_args) -> None:
            cli._stream_start(action="kill-wine", message="Stopping")
            raise RuntimeError("ps was unavailable")

        output = io.StringIO()
        with (
            patch.object(cli, "cmd_kill_wine", crashing_handler),
            patch.object(cli, "managed_gstreamer_environment", return_value={}),
            patch.object(cli.sys, "argv", ["nase.py", "--jsonl", "kill-wine"]),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as raised,
        ):
            cli.main()

        self.assertEqual(raised.exception.code, 1)
        result = json.loads(output.getvalue().splitlines()[-1])
        self.assertEqual(result["event"], "result")
        self.assertEqual(result["status"], "failed")
        self.assertIn("ps was unavailable", result["message"])
        self.assertEqual(load_job(result["job_id"])["status"], "failed")


if __name__ == "__main__":
    unittest.main()
