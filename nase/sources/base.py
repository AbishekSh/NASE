from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Protocol


@dataclass(frozen=True)
class SourceStatus:
    source: str
    available: bool
    authenticated: bool
    client: str | None
    version: str | None
    message: str

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class SourceGame:
    source: str
    store_id: str
    library_id: str
    title: str
    installed: bool
    install_path: str | None = None
    version: str | None = None
    update_available: bool = False
    art_url: str | None = None
    portrait_art_url: str | None = None

    def as_dict(self) -> dict:
        return asdict(self)


@dataclass(frozen=True)
class InstalledGame:
    """Local install facts for one game, resolvable without network access.

    Launch tracking needs a title and an install directory the moment a game
    starts. Refreshing the whole account library for that would be slow and
    would fail while offline, so adapters answer this from local state only.
    """

    title: str
    install_path: str | None = None
    executable: str | None = None

    def as_dict(self) -> dict:
        return asdict(self)


class GameSource(Protocol):
    id: str

    def status(self) -> SourceStatus: ...

    def list_games(self, *, force_refresh: bool = False) -> list[SourceGame]: ...

    def installed_game(self, game_id: str) -> InstalledGame | None: ...

    def authenticate(self, *, authorization_code: str) -> SourceStatus: ...

    def sign_out(self) -> SourceStatus: ...
