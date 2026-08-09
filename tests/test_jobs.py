from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from nase.jobs import cancel_job, create_job, list_jobs, load_job, update_job


class DurableJobTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(tempfile.mkdtemp(prefix="nase-jobs-test-"))
        self.support_patch = patch("nase.jobs.app_support_root", return_value=self.root)
        self.support_patch.start()

    def tearDown(self) -> None:
        self.support_patch.stop()

    def test_job_progress_and_result_are_persisted(self) -> None:
        create_job(job_id="job_123", action="setup", message="Starting")
        update_job(
            "job_123",
            status="started",
            message="Installed Steam",
            step={"name": "install-steam", "status": "ok"},
            progress=0.5,
            completed_steps=2,
            total_steps=4,
        )
        update_job(
            "job_123",
            status="failed",
            message="Verification failed",
            errors=["probe failed"],
            rollback={"attempted": True, "removed_new_bottle": True},
        )

        job = load_job("job_123")
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["steps"][0]["name"], "install-steam")
        self.assertEqual(job["completed_steps"], 2)
        self.assertTrue(job["rollback"]["removed_new_bottle"])
        self.assertIsNotNone(job["completed_at"])

    def test_abandoned_active_job_becomes_interrupted(self) -> None:
        create_job(job_id="job_dead", action="setup", message="Starting")
        with patch("nase.jobs._pid_is_our_backend", return_value=False):
            jobs = list_jobs()
        self.assertEqual(jobs[0]["status"], "interrupted")
        self.assertIn("Repair", jobs[0]["message"])

    def test_cancel_only_signals_verified_backend_process(self) -> None:
        create_job(job_id="job_live", action="setup", message="Starting")
        with (
            patch("nase.jobs._pid_is_our_backend", return_value=True),
            patch("nase.jobs.os.kill") as kill,
        ):
            job = cancel_job("job_live")
        self.assertEqual(job["status"], "cancelling")
        kill.assert_called_once()


if __name__ == "__main__":
    unittest.main()
