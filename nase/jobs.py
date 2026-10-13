from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import time

from .bottle import app_support_root
from .state_files import atomic_write_json, exclusive_lock


ACTIVE_STATUSES = {"queued", "started", "cancelling"}
TERMINAL_STATUSES = {"completed", "failed", "cancelled", "interrupted"}
TRANSIENT_ACTIONS = {
    "cancel-job",
    "dependency-status",
    "list-compatibility-profiles",
    "list-games",
    "list-installed-runtimes",
    "list-jobs",
    "list-runtime-catalog",
    "list-sessions",
}
# Finished jobs beyond this many are deleted; active jobs are always kept.
RETAINED_FINISHED_JOBS = 200


def jobs_root() -> Path:
    root = app_support_root() / "jobs"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _job_path(job_id: str) -> Path:
    safe = "".join(character for character in job_id if character.isalnum() or character in "-_")
    if not safe or safe != job_id:
        raise ValueError("Invalid job id.")
    return jobs_root() / f"{safe}.json"


def _jobs_lock_path() -> Path:
    return jobs_root() / "jobs.lock"


def _new_job(*, job_id: str, action: str, message: str, target: dict | None = None) -> dict:
    now = time.time()
    return {
        "schema_version": 1,
        "job_id": job_id,
        "action": action,
        "status": "started",
        "message": message,
        "pid": os.getpid(),
        "created_at": now,
        "updated_at": now,
        "completed_at": None,
        "target": target or {},
        "progress": None,
        "completed_steps": None,
        "total_steps": None,
        "steps": [],
        "warnings": [],
        "errors": [],
        "rollback": None,
    }


def create_job(*, job_id: str, action: str, message: str, target: dict | None = None) -> dict:
    job = _new_job(job_id=job_id, action=action, message=message, target=target)
    atomic_write_json(_job_path(job_id), job)
    return job


def load_job(job_id: str) -> dict:
    path = _job_path(job_id)
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise FileNotFoundError(f"Job not found: {job_id}") from exc


def update_job(
    job_id: str,
    *,
    status: str | None = None,
    message: str | None = None,
    step: dict | None = None,
    progress: float | None = None,
    completed_steps: int | None = None,
    total_steps: int | None = None,
    warnings: list[str] | None = None,
    errors: list[str] | None = None,
    rollback: dict | None = None,
    expected_statuses: set[str] | None = None,
) -> dict:
    """Apply changes to a job record under the jobs lock.

    With ``expected_statuses``, the update is skipped unless the stored job is
    still in one of those statuses, so a status decided from an older snapshot
    cannot overwrite a result another process has already written.
    """
    with exclusive_lock(_jobs_lock_path()):
        try:
            job = load_job(job_id)
        except FileNotFoundError:
            job = _new_job(job_id=job_id, action="unknown", message=message or "Job started.")
        if expected_statuses is not None and job.get("status") not in expected_statuses:
            return job
        now = time.time()
        if status is not None:
            job["status"] = status
            if status in TERMINAL_STATUSES:
                job["completed_at"] = now
        if message is not None:
            job["message"] = message
        if step is not None:
            steps = [item for item in job.get("steps", []) if item.get("name") != step.get("name")]
            steps.append({**step, "updated_at": now})
            job["steps"] = steps
        if progress is not None:
            job["progress"] = progress
        if completed_steps is not None:
            job["completed_steps"] = completed_steps
        if total_steps is not None:
            job["total_steps"] = total_steps
        if warnings:
            job["warnings"] = warnings
        if errors:
            job["errors"] = errors
        if rollback is not None:
            job["rollback"] = rollback
        job["updated_at"] = now
        atomic_write_json(_job_path(job_id), job)
    return job


def _pid_is_our_backend(pid: int) -> bool:
    if pid <= 1:
        return False
    try:
        result = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "command="],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except OSError:
        return False
    return result.returncode == 0 and "nase.py" in result.stdout


def reconcile_job(job: dict) -> dict:
    if job.get("status") not in ACTIVE_STATUSES:
        return job
    pid = int(job.get("pid") or 0)
    if _pid_is_our_backend(pid):
        return job
    terminal = "cancelled" if job.get("status") == "cancelling" else "interrupted"
    return update_job(
        str(job["job_id"]),
        status=terminal,
        message=(
            "Job was cancelled. Run Repair if it changed a compatibility profile."
            if terminal == "cancelled"
            else "The backend exited before reporting a result. Run Repair to safely resume."
        ),
        expected_statuses=ACTIVE_STATUSES,
    )


def _prune_finished_jobs(records: list[tuple[Path, dict]]) -> None:
    finished = [
        (path, job)
        for path, job in records
        if job.get("status") in TERMINAL_STATUSES
    ]
    finished.sort(key=lambda item: float(item[1].get("updated_at") or 0), reverse=True)
    for path, _job in finished[RETAINED_FINISHED_JOBS:]:
        try:
            path.unlink(missing_ok=True)
        except OSError:
            continue


def list_jobs(*, limit: int = 50) -> list[dict]:
    records: list[tuple[Path, dict]] = []
    for path in jobs_root().glob("*.json"):
        try:
            records.append((path, reconcile_job(json.loads(path.read_text(encoding="utf-8")))))
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    _prune_finished_jobs(records)
    jobs = [job for _path, job in records if job.get("action") not in TRANSIENT_ACTIONS]
    jobs.sort(key=lambda item: float(item.get("updated_at") or 0), reverse=True)
    return jobs[: max(1, min(limit, 200))]


def cancel_job(job_id: str) -> dict:
    job = reconcile_job(load_job(job_id))
    if job.get("status") not in ACTIVE_STATUSES:
        return job
    pid = int(job.get("pid") or 0)
    if not _pid_is_our_backend(pid):
        return update_job(
            job_id,
            status="interrupted",
            message="Backend process is no longer running.",
            expected_statuses=ACTIVE_STATUSES,
        )
    job = update_job(
        job_id,
        status="cancelling",
        message="Cancellation requested; rolling back safe changes...",
        expected_statuses=ACTIVE_STATUSES,
    )
    if job.get("status") != "cancelling":
        return job
    os.kill(pid, signal.SIGTERM)
    return load_job(job_id)
