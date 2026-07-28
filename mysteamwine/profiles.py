from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import subprocess
import time

from .bottle import Bottle
from .catalog import list_installed_runtimes
from .d3dmetal import inspect_d3dmetal_bundle
from .gptk import inspect_gptk_installation
from .dxvk_macos import inspect_dxvk_macos_stack


@dataclass(frozen=True)
class CompatibilityProfile:
    id: str
    name: str
    graphics_backend: str
    bottle_suffix: str
    wine_requirement: str
    graphics_requirement: str
    ready: bool
    unavailable_reason: str | None = None


PROFILES: dict[str, CompatibilityProfile] = {
    "dxmt-wine-stable-11-v1": CompatibilityProfile(
        id="dxmt-wine-stable-11-v1",
        name="DXMT Recommended",
        graphics_backend="dxmt",
        bottle_suffix="DXMT",
        wine_requirement="Wine Stable 11.x",
        graphics_requirement="DXMT 0.71",
        ready=True,
    ),
    "d3dmetal-gptk-v1": CompatibilityProfile(
        id="d3dmetal-gptk-v1",
        name="D3DMetal (GPTK)",
        graphics_backend="d3dmetal",
        bottle_suffix="D3DMetal",
        wine_requirement="wine-10.0 (Sikarugir), revision 6",
        graphics_requirement="Complete D3DMetal bundle with Wine modules and native framework",
        ready=True,
    ),
    "dxvk-macos-pinned-v1": CompatibilityProfile(
        id="dxvk-macos-pinned-v1",
        name="DXVK-macOS Pinned",
        graphics_backend="dxvk",
        bottle_suffix="DXVK-macOS",
        wine_requirement="Pinned supported Wine build with matching winevulkan",
        graphics_requirement="Pinned DXVK-macOS and MoltenVK bundle",
        ready=True,
    ),
    "plain-wine-v1": CompatibilityProfile(
        id="plain-wine-v1",
        name="Plain Wine",
        graphics_backend="none",
        bottle_suffix="Plain",
        wine_requirement="Selected Wine runtime",
        graphics_requirement="Wine built-in graphics",
        ready=True,
    ),
}


def list_profiles() -> list[dict]:
    return [asdict(profile) for profile in PROFILES.values()]


def profile_for(profile_id: str, graphics_backend: str) -> CompatibilityProfile:
    try:
        profile = PROFILES[profile_id]
    except KeyError as exc:
        raise RuntimeError(f"Unknown compatibility profile: {profile_id}") from exc
    if profile.graphics_backend != graphics_backend:
        raise RuntimeError(
            f"Compatibility profile {profile.id} requires {profile.graphics_backend}, not {graphics_backend}."
        )
    if not profile.ready:
        raise RuntimeError(profile.unavailable_reason or f"Compatibility profile {profile.name} is not ready.")
    return profile


def _wine_version(wine_path: Path) -> str:
    try:
        result = subprocess.run(
            [str(wine_path), "--version"], capture_output=True, text=True, timeout=10, check=False
        )
    except OSError as exc:
        raise RuntimeError(f"Wine runtime is not executable: {wine_path}") from exc
    version = (result.stdout or result.stderr).strip()
    if result.returncode != 0 or not version:
        raise RuntimeError(f"Could not identify Wine runtime at {wine_path}.")
    return version


def _source_fingerprint(source: Path | None) -> str | None:
    if source is None:
        return None
    resolved = source.expanduser().resolve()
    if not resolved.exists():
        raise RuntimeError(f"Graphics runtime source does not exist: {resolved}")
    digest = hashlib.sha256()
    digest.update(str(resolved).encode())
    if resolved.is_file():
        digest.update(str(resolved.stat().st_size).encode())
        digest.update(str(resolved.stat().st_mtime_ns).encode())
    else:
        for path in sorted(resolved.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(resolved)
            stat = path.stat()
            digest.update(str(relative).encode())
            digest.update(str(stat.st_size).encode())
            digest.update(str(stat.st_mtime_ns).encode())
    return digest.hexdigest()


def _runtime_id_for_source(source: Path) -> str | None:
    resolved = source.expanduser().resolve()
    for runtime in list_installed_runtimes():
        try:
            runtime_path = Path(runtime.path).expanduser().resolve()
        except OSError:
            continue
        if resolved == runtime_path:
            return runtime.id
    return None


def bind_profile(
    *,
    bottle: Bottle,
    profile_id: str,
    graphics_backend: str,
    wine_path: Path,
    graphics_source: Path | None,
    moltenvk_source: Path | None = None,
    require_ready: bool = True,
) -> dict:
    profile = profile_for(profile_id, graphics_backend)
    wine_version = _wine_version(wine_path)
    d3dmetal_inspection: dict | None = None
    if profile.id == "dxmt-wine-stable-11-v1" and not wine_version.lower().startswith("wine-11.0"):
        raise RuntimeError(
            f"{profile.name} requires Wine Stable 11.x, but {wine_version or wine_path.name} was selected."
        )
    if profile.id == "dxmt-wine-stable-11-v1":
        if graphics_source is None or _runtime_id_for_source(graphics_source) != "dxmt-0.71":
            raise RuntimeError(
                "DXMT Recommended requires the verified DXMT 0.71 package from Runtime Center."
            )
    if profile.id == "d3dmetal-gptk-v1" and graphics_source is None:
        raise RuntimeError(
            "D3DMetal requires a complete managed runtime. Open Runtime Center, choose Find Runtime, "
            "then import and repair the D3DMetal profile."
        )
    if profile.id == "d3dmetal-gptk-v1":
        if not graphics_source.expanduser().is_dir():
            raise RuntimeError(
                f"The saved D3DMetal runtime was moved or deleted: {graphics_source}. "
                "Open Runtime Center, choose Find Runtime, then import and repair the D3DMetal profile. "
                "NASE will not substitute a different D3DMetal build because it may not match the pinned Wine engine."
            )
        try:
            d3dmetal_inspection = inspect_gptk_installation(wine_path, graphics_source)
        except OSError as exc:
            raise RuntimeError(
                f"The saved D3DMetal runtime is incomplete or unavailable: {exc}. "
                "Open Runtime Center, choose Find Runtime, then import and repair the D3DMetal profile."
            ) from exc
    dxvk_inspection: dict | None = None
    if profile.id == "dxvk-macos-pinned-v1":
        if graphics_source is None or moltenvk_source is None:
            raise RuntimeError("DXVK-macOS requires its pinned DXVK package and a compatible MoltenVK source.")
        if _runtime_id_for_source(graphics_source) != "dxvk-macos-1.10.3-20230507-repack":
            raise RuntimeError("DXVK-macOS requires the verified pinned package from Runtime Center.")
        dxvk_inspection = inspect_dxvk_macos_stack(wine_path, graphics_source, moltenvk_source)

    fingerprint_source = Path(d3dmetal_inspection["payload_path"]) if d3dmetal_inspection else graphics_source

    fingerprint = {
        "schema_version": 1,
        "profile": asdict(profile),
        "wine_path": str(wine_path.expanduser().resolve()),
        "wine_version": wine_version,
        "graphics_source": str(graphics_source.expanduser().resolve()) if graphics_source else None,
        "graphics_source_fingerprint": _source_fingerprint(fingerprint_source),
        "graphics_runtime_id": _runtime_id_for_source(graphics_source) if graphics_source else None,
        "gptk_installation_root": d3dmetal_inspection["installation_root"] if d3dmetal_inspection else None,
        "dxvk_macos_stack": dxvk_inspection,
        "moltenvk_source_fingerprint": _source_fingerprint(moltenvk_source) if moltenvk_source else None,
    }
    manifest_path = bottle.root / "compatibility-profile.json"
    if manifest_path.exists():
        try:
            existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"Compatibility manifest is damaged: {manifest_path}") from exc
        comparable_keys = ["profile", "wine_path", "wine_version"]
        # Managed runtimes are checksum-pinned catalog artifacts. Reinstalling the
        # same artifact can change directory mtimes without changing the stack.
        # Prefer its stable catalog identity and retain fingerprints for imports.
        if not (
            existing.get("graphics_runtime_id")
            and existing.get("graphics_runtime_id") == fingerprint.get("graphics_runtime_id")
        ):
            comparable_keys.append("graphics_source_fingerprint")
        existing_moltenvk_sha = (existing.get("dxvk_macos_stack") or {}).get("moltenvk_sha256")
        current_moltenvk_sha = (fingerprint.get("dxvk_macos_stack") or {}).get("moltenvk_sha256")
        if not (existing_moltenvk_sha and existing_moltenvk_sha == current_moltenvk_sha):
            comparable_keys.append("moltenvk_source_fingerprint")
        if any(existing.get(key) != fingerprint.get(key) for key in comparable_keys):
            raise RuntimeError(
                f"Bottle '{bottle.name}' is already bound to a different compatibility stack. "
                "Choose its original profile or create a new profile bottle."
            )
        if profile.id == "d3dmetal-gptk-v1" and existing.get("graphics_source") != fingerprint.get("graphics_source"):
            existing["graphics_source"] = fingerprint["graphics_source"]
            existing["gptk_installation_root"] = fingerprint["gptk_installation_root"]
            temporary = manifest_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(existing, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            temporary.replace(manifest_path)
        if require_ready and existing.get("setup_status") != "ready":
            raise RuntimeError(f"Profile bottle '{bottle.name}' needs profile setup before launching a game.")
        return existing

    bottle.root.mkdir(parents=True, exist_ok=True)
    fingerprint["created_at"] = time.time()
    fingerprint["setup_status"] = "bound"
    temporary = manifest_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(fingerprint, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(manifest_path)
    if require_ready:
        raise RuntimeError(f"Profile bottle '{bottle.name}' was created and now needs profile setup.")
    return fingerprint


def mark_profile_ready(bottle: Bottle) -> dict:
    manifest_path = bottle.root / "compatibility-profile.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Compatibility manifest is missing or damaged: {manifest_path}") from exc
    manifest["setup_status"] = "ready"
    manifest["ready_at"] = time.time()
    for key in (
        "active_job_id",
        "failed_at",
        "last_failed_job",
        "last_failure",
        "setup_started_at",
    ):
        manifest.pop(key, None)
    temporary = manifest_path.with_suffix(".tmp")
    temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(manifest_path)
    return manifest


def migrate_imported_d3dmetal_profiles(*, old_source: Path, new_source: Path, bottles_root: Path) -> int:
    """Rebind profiles only after an explicit import copied their exact configured source."""
    old_resolved = old_source.expanduser().resolve()
    new_bundle = inspect_d3dmetal_bundle(new_source)
    new_resolved = new_bundle.root.resolve()
    new_fingerprint = _source_fingerprint(new_bundle.windows_dir)
    migrated = 0
    for manifest_path in bottles_root.glob("*/compatibility-profile.json"):
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        configured_value = manifest.get("graphics_source")
        if not isinstance(configured_value, str) or not configured_value:
            continue
        configured = Path(configured_value).expanduser().resolve()
        if manifest.get("profile", {}).get("id") != "d3dmetal-gptk-v1" or configured != old_resolved:
            continue
        manifest["graphics_source"] = str(new_resolved)
        manifest["graphics_source_fingerprint"] = new_fingerprint
        manifest["gptk_installation_root"] = str(new_resolved.parent)
        temporary = manifest_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(manifest_path)
        migrated += 1
    return migrated
