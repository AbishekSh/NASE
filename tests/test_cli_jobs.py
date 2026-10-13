from __future__ import annotations

import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from nase.bottle import Bottle
import nase.cli as cli
import nase.sessions as sessions
from nase.jobs import load_job


def run_main(argv: list[str], **patches) -> tuple[list[dict], object]:
    """Run the CLI in --jsonl mode and return its events and exit code."""
    stdout = io.StringIO()
    with contextlib.ExitStack() as stack:
        stack.enter_context(patch.object(cli, "managed_gstreamer_environment", return_value={}))
        for name, value in patches.items():
            stack.enter_context(patch.object(cli, name, value))
        stack.enter_context(patch.object(cli.sys, "argv", ["nase.py", "--jsonl", *argv]))
        stack.enter_context(contextlib.redirect_stdout(stdout))
        try:
            cli.main()
            code = 0
        except SystemExit as exc:
            code = exc.code
    return [json.loads(line) for line in stdout.getvalue().splitlines()], code


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
            out = cli.Output(self.args, "setup-metal")
            out.start("Starting")
            out.step("wineboot", "Done", status="ok")
            job_id = out.job_id

        job = load_job(job_id)
        self.assertEqual(job["status"], "started")
        self.assertEqual(job["steps"][0]["status"], "ok")

    def test_error_after_start_fails_the_open_job_instead_of_starting_another(self) -> None:
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaises(SystemExit):
            out = cli.Output(self.args, "debug-game")
            out.start("Launching")
            job_id = out.job_id
            cli._json_error(self.args, action="debug-game", message="Executable is not compatible.")

        self.assertEqual(self._job_ids_on_disk(), [job_id])
        self.assertEqual(load_job(job_id)["status"], "failed")
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([event["event"] for event in events], ["job", "result"])
        self.assertEqual(events[-1]["job_id"], job_id)
        self.assertEqual(cli._OPEN_STREAM_JOB, {})

    def test_uncaught_exception_fails_the_open_job(self) -> None:
        def crashing_handler(args) -> None:
            cli.Output(args, "kill-wine").start("Stopping")
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


class OutputModeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-cli-output-test-"))
        self.support_patch = patch("nase.jobs.app_support_root", return_value=self.root)
        self.support_patch.start()
        cli._OPEN_STREAM_JOB.clear()

    def tearDown(self) -> None:
        self.support_patch.stop()
        cli._OPEN_STREAM_JOB.clear()

    def _report(self, mode: str, report) -> tuple[str, str, object]:
        args = cli.argparse.Namespace(json=mode == "json", jsonl=mode == "jsonl")
        stdout, stderr = io.StringIO(), io.StringIO()
        exit_code = None
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                report(cli.Output(args, "install-runtime"))
            except SystemExit as exc:
                exit_code = exc.code
        return stdout.getvalue(), stderr.getvalue(), exit_code

    def test_one_report_renders_in_every_mode(self) -> None:
        def report(out: cli.Output) -> None:
            out.start("Installing...")
            out.step("download", "Downloaded.", status="ok", completed_steps=1, total_steps=4)
            out.done("Installed.", data={"runtime": "rt"}, text="Installed rt.")

        streamed, _, _ = self._report("jsonl", report)
        events = [json.loads(line) for line in streamed.splitlines()]
        self.assertEqual([event["event"] for event in events], ["job", "step", "result"])
        self.assertEqual(len({event["job_id"] for event in events}), 1)
        self.assertEqual(events[1]["data"]["progress"], 0.25)
        self.assertEqual((events[2]["status"], events[2]["data"]), ("completed", {"runtime": "rt"}))

        single, _, _ = self._report("json", report)
        payload = json.loads(single)
        self.assertEqual((payload["ok"], payload["status"], payload["message"]), (True, "completed", "Installed."))

        plain, _, _ = self._report("plain", report)
        self.assertEqual(plain, "Installing...\nInstalled rt.\n")

    def test_failures_exit_with_the_process_code_in_every_mode(self) -> None:
        def report(out: cli.Output) -> None:
            out.fail_process("Winetricks failed", 4, "last log line", data={"verbs": ["vcrun2019"]})

        streamed, _, code = self._report("jsonl", report)
        result = json.loads(streamed.splitlines()[-1])
        self.assertEqual(code, 4)
        self.assertEqual(result["errors"], ["Winetricks failed (exit 4)."])
        self.assertIn("last log line", result["message"])
        self.assertEqual(result["data"], {"verbs": ["vcrun2019"]})

        plain, errors, code = self._report("plain", report)
        self.assertEqual((plain, code), ("", 4))
        self.assertIn("Winetricks failed (exit 4)", errors)

    def test_graphics_installers_report_structured_results(self) -> None:
        events, code = run_main(
            ["--wine", "/bin/echo", "install-dxmt", "--dxmt-source", "/x"],
            install_dxmt=lambda **_: (2, "missing d3d11.dll"),
            _resolve_bottle=lambda _args: SimpleNamespace(name="Test", prefix=self.root / "prefix"),
        )
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]["event"], "result")
        self.assertEqual(events[-1]["errors"], ["DXMT install failed (exit 2)."])

    def test_missing_wine_is_reported_as_a_failed_result(self) -> None:
        events, code = run_main(["run-steam", "--no-wait"])
        self.assertEqual(code, 1)
        self.assertEqual(events[-1]["action"], "run-steam")
        self.assertEqual(events[-1]["status"], "failed")
        self.assertIn("--wine64 is required", events[-1]["message"])


class SteamHandoffTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-cli-handoff-test-"))
        self.bottle = Bottle("Test", self.root, self.root / "prefix", self.root / "logs", self.root / "downloads", self.root / "cache")
        self.app = SimpleNamespace(appid="250900", name="Isaac", install_dir=self.root / "isaac", library_path=self.root / "lib")
        cli._OPEN_STREAM_JOB.clear()

    def tearDown(self) -> None:
        cli._OPEN_STREAM_JOB.clear()

    def test_busy_shared_library_fails_the_launch_session(self) -> None:
        def library_owned_elsewhere(**_activity):
            raise RuntimeError("Shared Steam library is currently owned by Default-D3DMetal.")

        for command in ("launch-game", "smart-launch-game"):
            with self.subTest(command=command), contextlib.ExitStack() as stack:
                registry = self.root / f"{command}-sessions.json"
                stack.enter_context(patch("nase.jobs.app_support_root", return_value=self.root))
                stack.enter_context(patch.object(sessions, "_registry_path", return_value=registry))
                stack.enter_context(patch.object(sessions, "_processes", return_value={}))
                stack.enter_context(patch.object(sessions, "_prefix_pids", return_value=set()))
                stack.enter_context(patch.object(sessions, "reconcile_shared_steam_client"))
                events, code = run_main(
                    ["--wine", "/bin/echo", command, "--appid", "250900", "--no-wait"],
                    _resolve_bottle=lambda _args: self.bottle,
                    resolve_registered_app=lambda *_a, **_k: (self.app, "library_1"),
                    _bind_launch_profile=lambda *_a, **_k: "dxmt-wine-stable-11-v1",
                    guess_game_executable=lambda *_a, **_k: (_ for _ in ()).throw(FileNotFoundError()),
                    scan_game_dir=lambda *_a, **_k: SimpleNamespace(signals=[]),
                    run_game_executable=lambda **_: (9, "direct launch exited"),
                    steam_is_running=lambda *_: False,
                    acquire_steam_activity=library_owned_elsewhere,
                )
                stored = json.loads(registry.read_text(encoding="utf-8"))["sessions"]
                self.assertEqual(code, 1)
                self.assertIn("owned by Default-D3DMetal", events[-1]["message"])
                self.assertEqual([session["status"] for session in stored], ["failed"])


if __name__ == "__main__":
    unittest.main()
