from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import tempfile
from typing import Any, Iterator


@contextmanager
def exclusive_lock(lock_path: Path) -> Iterator[None]:
    """Serialize read-modify-write cycles across backend processes.

    The app runs every command in its own Python process, so a registry that is
    loaded, changed, and saved without this lock silently loses whichever
    concurrent write lands first. flock locks belong to the open file, so a
    process must not nest two acquisitions of the same lock path.
    """
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield


def atomic_write_json(path: Path, payload: Any) -> None:
    """Replace a JSON file without exposing partial content to readers.

    Each writer gets its own temporary file so two processes can never
    truncate or rename each other's half-written data.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        os.replace(temporary, path)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
