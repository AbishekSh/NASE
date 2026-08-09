from __future__ import annotations

import json
import os
from pathlib import Path
import signal
import subprocess
import time
from typing import Any

from .bottle import app_support_root


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


def jobs_root() -> Path:
    root = app_support_root() / "jobs"
    root.mkdir(parents=True, exist_ok=True)
    return root


def _job_path(job_id: str) -> Path:
    safe = "".join(character for character in job_id if character.isalnum() or character in "-_")
    if not safe or safe != job_id:
        raise ValueError("Invalid job id.")
    return jobs_root() / f"{safe}.json"


def _atomic_write(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def create_job(*, job_id: str, action: str, message: str, target: dict | None = None) -> dict:
    now = time.time()
    job = {
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
    _atomic_write(_job_path(job_id), job)
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
) -> dict:
    try:
        job = load_job(job_id)
    except FileNotFoundError:
        job = create_job(job_id=job_id, action="unknown", message=message or "Job started.")
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
    _atomic_write(_job_path(job_id), job)
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
    )


def list_jobs(*, limit: int = 50) -> list[dict]:
    jobs: list[dict] = []
    for path in jobs_root().glob("*.json"):
        try:
            job = json.loads(path.read_text(encoding="utf-8"))
            if job.get("action") in TRANSIENT_ACTIONS:
                continue
            jobs.append(reconcile_job(job))
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    jobs.sort(key=lambda item: float(item.get("updated_at") or 0), reverse=True)
    return jobs[: max(1, min(limit, 200))]


def cancel_job(job_id: str) -> dict:
    job = reconcile_job(load_job(job_id))
    if job.get("status") not in ACTIVE_STATUSES:
        return job
    pid = int(job.get("pid") or 0)
    if not _pid_is_our_backend(pid):
        return update_job(job_id, status="interrupted", message="Backend process is no longer running.")
    update_job(job_id, status="cancelling", message="Cancellation requested; rolling back safe changes...")
    os.kill(pid, signal.SIGTERM)
    return load_job(job_id)
