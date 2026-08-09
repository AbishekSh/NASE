from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
from typing import Any, Callable, Iterator
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen

from ..bottle import app_support_root
from .base import SourceGame, SourceStatus


CommandRunner = Callable[[list[str], dict[str, str], int], subprocess.CompletedProcess[str]]
LaunchRunner = Callable[[list[str], dict[str, str], Path], None]
JSONFetcher = Callable[[str, dict[str, str]], Any]


def _default_runner(command: list[str], environment: dict[str, str], timeout: int) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, env=environment, capture_output=True, text=True, check=False, timeout=timeout)


def _default_launcher(command: list[str], environment: dict[str, str], log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("a", encoding="utf-8") as output:
        process = subprocess.Popen(
            command,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
        try:
            return_code = process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            return
    if return_code != 0:
        try:
            lines = log_path.read_text(encoding="utf-8", errors="replace").strip().splitlines()
        except OSError:
            lines = []
        raise RuntimeError(f"GOG game launch failed: {lines[-1] if lines else 'gogdl exited immediately.'}")


def _default_fetch_json(url: str, headers: dict[str, str]) -> Any:
    request = Request(url, headers={"User-Agent": "NASE/1.0", **headers})
    with urlopen(request, timeout=45) as response:
        return json.load(response)


class GOGSource:
    id = "gog"

    def __init__(
        self,
        client: str = "gogdl",
        *,
        runner: CommandRunner = _default_runner,
        launcher: LaunchRunner = _default_launcher,
        fetch_json: JSONFetcher = _default_fetch_json,
    ) -> None:
        self.requested_client = client
        self.runner = runner
        self.launcher = launcher
        self.fetch_json = fetch_json

    @property
    def root(self) -> Path:
        return app_support_root() / "sources" / "gog"

    @property
    def config_root(self) -> Path:
        return self.root / "config"

    @property
    def auth_path(self) -> Path:
        return self.root / "auth.json"

    @property
    def installed_path(self) -> Path:
        return self.root / "installed.json"

    def _client_path(self) -> str | None:
        candidate = Path(self.requested_client).expanduser()
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
        resolved = shutil.which(self.requested_client)
        if resolved:
            return resolved
        architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
        managed = app_support_root() / "runtimes" / "source-client" / f"gogdl-1.2.2-macos-{architecture}" / "bin" / "gogdl"
        return str(managed) if managed.is_file() and os.access(managed, os.X_OK) else None

    def _environment(self) -> dict[str, str]:
        self.config_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.root.chmod(0o700)
        self.config_root.chmod(0o700)
        environment = os.environ.copy()
        environment["GOGDL_CONFIG_PATH"] = str(self.config_root)
        return environment

    @contextmanager
    def _lock(self) -> Iterator[None]:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = self.root / ".lock"
        with lock.open("a", encoding="utf-8") as handle:
            lock.chmod(0o600)
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def _run(self, arguments: list[str], *, timeout: int = 120) -> subprocess.CompletedProcess[str]:
        client = self._client_path()
        if not client:
            raise RuntimeError("GOG support requires the managed GOG Download Client. Install it from GOG Setup first.")
        command = [client, "--auth-config-path", str(self.auth_path), *arguments]
        with self._lock():
            result = self.runner(command, self._environment(), timeout)
        if result.returncode != 0:
            lines = (result.stderr or result.stdout).strip().splitlines()
            raise RuntimeError(f"GOG service action failed: {lines[-1] if lines else 'gogdl failed without an error message.'}")
        return result

    def _credentials(self) -> dict[str, Any] | None:
        if not self.auth_path.is_file() or self.auth_path.stat().st_size == 0:
            return None
        result = self._run(["auth"], timeout=45)
        try:
            credentials = json.loads(result.stdout)
        except json.JSONDecodeError:
            return None
        return credentials if isinstance(credentials, dict) and credentials.get("access_token") and credentials.get("user_id") else None

    def status(self) -> SourceStatus:
        client = self._client_path()
        if not client:
            return SourceStatus(self.id, False, False, None, None, "Install the GOG Download Client to enable this source.")
        try:
            credentials = self._credentials()
        except RuntimeError:
            credentials = None
        return SourceStatus(
            self.id, True, credentials is not None, client, "1.2.2" if "gogdl-1.2.2" in client else None,
            "GOG account is connected." if credentials else "Sign in to GOG to load your library.",
        )

    def authenticate(self, *, authorization_code: str) -> SourceStatus:
        code = _authorization_code(authorization_code)
        result = self._run(["auth", "--code", code], timeout=120)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise RuntimeError("GOG returned an unreadable sign-in response. Try signing in again.") from exc
        if not isinstance(payload, dict) or payload.get("error") or not payload.get("access_token"):
            raise RuntimeError("GOG did not accept that sign-in code. Open GOG Login again and paste the new callback URL.")
        self.auth_path.chmod(0o600)
        return self.status()

    def sign_out(self) -> SourceStatus:
        self.auth_path.unlink(missing_ok=True)
        return self.status()

    def list_games(self, *, force_refresh: bool = False) -> list[SourceGame]:
        credentials = self._credentials()
        if not credentials:
            raise RuntimeError("Sign in to GOG before refreshing your library.")
        headers = {"Authorization": f"Bearer {credentials['access_token']}"}
        entries: list[dict[str, Any]] = []
        page_token: str | None = None
        while True:
            suffix = f"?page_token={page_token}" if page_token else ""
            payload = self.fetch_json(f"https://galaxy-library.gog.com/users/{credentials['user_id']}/releases{suffix}", headers)
            entries.extend(item for item in payload.get("items", []) if isinstance(item, dict) and item.get("platform_id") == "gog")
            page_token = payload.get("next_page_token")
            if not page_token:
                break
        installed = self._installed()
        games_by_canonical_id: dict[str, SourceGame] = {}
        for entry in entries:
            game_id = str(entry.get("external_id") or "")
            if not game_id:
                continue
            metadata = self.fetch_json(f"https://gamesdb.gog.com/platforms/gog/external_releases/{game_id}", {
                **headers, "X-GOG-Library-Cert": str(entry.get("certificate") or ""),
            })
            game = metadata.get("game", {}) if isinstance(metadata, dict) else {}
            if metadata.get("type") not in {"game", "mod"} or game.get("visible_in_library") is False:
                continue
            title = _localized(metadata.get("title")) or _localized(game.get("title")) or game_id
            local = installed.get(game_id)
            normalized = SourceGame("gog", game_id, f"gog:{game_id}", title, local is not None,
                                    local.get("install_path") if local else None,
                                    local.get("version") if local else None, False, _art_url(game),
                                    portrait_art_url=_portrait_art_url(game))
            canonical_id = str(metadata.get("game_id") or game.get("id") or game_id)
            existing = games_by_canonical_id.get(canonical_id)
            if existing is None or (normalized.installed and not existing.installed) or (normalized.art_url and not existing.art_url):
                games_by_canonical_id[canonical_id] = normalized
        return sorted(games_by_canonical_id.values(), key=lambda game: (game.title.casefold(), game.store_id))

    def _installed(self) -> dict[str, dict[str, str]]:
        try:
            payload = json.loads(self.installed_path.read_text(encoding="utf-8"))
            return payload if isinstance(payload, dict) else {}
        except (OSError, json.JSONDecodeError):
            return {}

    def _write_installed(self, installed: dict[str, dict[str, str]]) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.installed_path.write_text(json.dumps(installed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        self.installed_path.chmod(0o600)

    def install(self, game_id: str, *, base_path: Path) -> None:
        game_id = _game_id(game_id)
        base_path = base_path.expanduser().resolve()
        base_path.mkdir(parents=True, exist_ok=True)
        info = json.loads(self._run(["info", game_id, "--platform", "windows"], timeout=180).stdout)
        destination = base_path / str(info.get("folder_name") or game_id)
        # gogdl's `download` command appends its own installDirectory. Update and
        # repair commands do not, so retain the resolved final directory here.
        self._run(["download", game_id, "--path", str(base_path), "--platform", "windows", "--skip-dlcs"], timeout=24 * 60 * 60)
        installed = self._installed()
        installed[game_id] = {"install_path": str(destination), "version": str(info.get("versionName") or info.get("buildId") or "")}
        self._write_installed(installed)

    def _installed_game(self, game_id: str) -> tuple[str, dict[str, str]]:
        game_id = _game_id(game_id)
        local = self._installed().get(game_id)
        if not local or not Path(local.get("install_path", "")).is_dir():
            raise RuntimeError("This GOG game is not installed in NASE yet.")
        return game_id, local

    def update(self, game_id: str) -> None:
        game_id, local = self._installed_game(game_id)
        self._run(["update", game_id, "--path", local["install_path"], "--platform", "windows", "--skip-dlcs"], timeout=24 * 60 * 60)

    def verify(self, game_id: str) -> None:
        game_id, local = self._installed_game(game_id)
        self._run(["repair", game_id, "--path", local["install_path"], "--platform", "windows", "--skip-dlcs"], timeout=8 * 60 * 60)

    def repair(self, game_id: str) -> None:
        self.verify(game_id)

    def uninstall(self, game_id: str, *, keep_files: bool = False) -> None:
        game_id, local = self._installed_game(game_id)
        if not keep_files:
            shutil.rmtree(Path(local["install_path"]))
        (self.config_root / "heroic_gogdl" / "manifests" / game_id).unlink(missing_ok=True)
        installed = self._installed()
        installed.pop(game_id, None)
        self._write_installed(installed)

    def launch(self, game_id: str, *, wine_path: Path, wine_prefix: Path, environment: dict[str, str]) -> None:
        game_id, local = self._installed_game(game_id)
        client = self._client_path()
        assert client
        command = [client, "--auth-config-path", str(self.auth_path), "launch", local["install_path"], game_id,
                   "--platform", "windows", "--wine", str(wine_path.expanduser().resolve()),
                   "--wine-prefix", str(wine_prefix.expanduser().resolve())]
        launch_environment = self._environment()
        launch_environment.update(environment)
        with self._lock():
            self.launcher(command, launch_environment, self.root / "logs" / f"launch-{game_id}.log")


def _authorization_code(value: str) -> str:
    candidate = value.strip()
    if candidate.startswith("http"):
        candidate = (parse_qs(urlparse(candidate).query).get("code") or [""])[0]
    candidate = candidate.strip().strip('"')
    if not candidate or any(character.isspace() for character in candidate):
        raise ValueError("Paste the complete GOG callback URL or its code value.")
    return candidate


def _game_id(value: str) -> str:
    game_id = value.strip()
    if not game_id.isdigit():
        raise ValueError("GOG game id is invalid.")
    return game_id


def _localized(value: Any) -> str | None:
    if isinstance(value, str):
        return value.strip() or None
    if isinstance(value, dict):
        return str(value.get("*") or value.get("en-US") or "").strip() or None
    return None


def _art_from_keys(game: dict[str, Any], keys: tuple[str, ...]) -> str | None:
    for key in keys:
        image = game.get(key)
        template = image.get("url_format") if isinstance(image, dict) else None
        if isinstance(template, str) and template.startswith("https://"):
            return template.replace("{formatter}", "").replace("{ext}", "jpg")
    return None


def _art_url(game: dict[str, Any]) -> str | None:
    return _art_from_keys(game, ("background", "vertical_cover", "logo", "square_icon", "icon"))


def _portrait_art_url(game: dict[str, Any]) -> str | None:
    return _art_from_keys(game, ("vertical_cover", "logo", "square_icon", "icon"))
