from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from nase.jobs import RETAINED_FINISHED_JOBS, cancel_job, create_job, list_jobs, load_job, reconcile_job, update_job


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


    def test_reconcile_from_stale_snapshot_keeps_reported_result(self) -> None:
        stale = create_job(job_id="job_done", action="debug-game", message="Launching")
        update_job("job_done", status="completed", message="Debug launch started.")
        with patch("nase.jobs._pid_is_our_backend", return_value=False):
            job = reconcile_job(stale)
        self.assertEqual(job["status"], "completed")
        self.assertEqual(load_job("job_done")["status"], "completed")

    def test_cancel_does_not_signal_a_job_that_already_finished(self) -> None:
        create_job(job_id="job_racing", action="setup", message="Starting")

        def finish_before_cancel(job_id: str, **changes):
            update_job(job_id, status="completed", message="Setup complete.")
            return update_job(job_id, **changes)

        with (
            patch("nase.jobs._pid_is_our_backend", return_value=True),
            patch("nase.jobs.update_job", side_effect=finish_before_cancel),
            patch("nase.jobs.os.kill") as kill,
        ):
            job = cancel_job("job_racing")
        self.assertEqual(job["status"], "completed")
        kill.assert_not_called()

    def test_listing_prunes_oldest_finished_jobs_and_keeps_active_ones(self) -> None:
        for index in range(RETAINED_FINISHED_JOBS + 5):
            create_job(job_id=f"job_old_{index}", action="stop-game", message="Stopping")
            update_job(f"job_old_{index}", status="completed", message="Stopped.")
        create_job(job_id="job_active", action="setup", message="Starting")
        with patch("nase.jobs._pid_is_our_backend", return_value=True):
            list_jobs(limit=200)
        remaining = {path.stem for path in (self.root / "jobs").glob("*.json")}
        self.assertEqual(len(remaining), RETAINED_FINISHED_JOBS + 1)
        self.assertIn("job_active", remaining)
        self.assertNotIn("job_old_0", remaining)
        self.assertIn(f"job_old_{RETAINED_FINISHED_JOBS + 4}", remaining)


if __name__ == "__main__":
    unittest.main()
