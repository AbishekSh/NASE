from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from .pe import executable_architecture


@dataclass(frozen=True)
class ScanSignal:
    key: str
    detail: str
    path: Path


@dataclass(frozen=True)
class GameScan:
    root: Path
    signals: list[ScanSignal]


_FILE_RULES = {
    "directx-installer": ["dxsetup.exe"],
    "vc-redist": ["vcredist_x64.exe", "vcredist_x86.exe", "vc_redist.x64.exe", "vc_redist.x86.exe"],
    "dotnet-installer": ["dotnetfx", "ndp48", "ndp472"],
    "unity": ["unityplayer.dll"],
    "unreal": ["ue4prereqsetup_x64.exe", "ue4prereqsetup_x86.exe"],
    "xna": ["fna.dll", "xnafx40_redist.msi"],
    "d3dx9": ["d3dx9_43.dll"],
    "d3dcompiler_43": ["d3dcompiler_43.dll"],
    "xinput": ["xinput1_3.dll", "xinput9_1_0.dll"],
    "xact": ["xaudio2_7.dll", "x3daudio1_7.dll"],
}


def scan_game_dir(root: Path, max_files: int = 4000) -> GameScan:
    root = root.expanduser().resolve()
    if not root.exists():
        raise FileNotFoundError(f"Game directory does not exist: {root}")

    signals: list[ScanSignal] = []
    scanned = 0
    for path in root.rglob("*"):
        if scanned >= max_files:
            break
        if not path.is_file():
            continue
        scanned += 1
        name = path.name.lower()
        if path.suffix.lower() == ".exe":
            architecture = executable_architecture(path)
            if architecture in {"x86", "x86_64"}:
                signals.append(
                    ScanSignal(
                        key=f"executable-{architecture}",
                        detail=f"{path.name} is a {architecture} Windows executable",
                        path=path,
                    )
                )
        for key, markers in _FILE_RULES.items():
            if any(marker in name for marker in markers):
                signals.append(ScanSignal(key=key, detail=path.name, path=path))
    return GameScan(root=root, signals=signals)
