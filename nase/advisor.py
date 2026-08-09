from __future__ import annotations

from dataclasses import dataclass

from .scanner import GameScan


@dataclass(frozen=True)
class Recommendation:
    verb: str
    reason: str


_RULES = {
    "vc-redist": Recommendation("vcrun2019", "VC++ redistributable installer detected"),
    "directx-installer": Recommendation("d3dx9", "DirectX redistributable files detected"),
    "d3dx9": Recommendation("d3dx9", "Legacy Direct3D 9 DLL detected"),
    "d3dcompiler_43": Recommendation("d3dcompiler_43", "Legacy D3D compiler DLL detected"),
    "xinput": Recommendation("xinput", "XInput DLL detected"),
    "xact": Recommendation("xact", "XAudio/XACT DLL detected"),
    "dotnet-installer": Recommendation("dotnet48", ".NET installer detected"),
    "unity": Recommendation("corefonts", "Unity titles often benefit from core fonts"),
    "unreal": Recommendation("vcrun2019", "Unreal prerequisite bundle detected"),
    "xna": Recommendation("xna40", "XNA/FNA runtime files detected"),
}


def recommend_dependencies(scan: GameScan) -> list[Recommendation]:
    recommendations: list[Recommendation] = []
    seen: set[str] = set()
    for signal in scan.signals:
        recommendation = _RULES.get(signal.key)
        if not recommendation or recommendation.verb in seen:
            continue
        seen.add(recommendation.verb)
        recommendations.append(recommendation)

    if any(rec.verb == "d3dx9" for rec in recommendations) and "dxvk" not in seen:
        recommendations.append(Recommendation("dxvk", "DXVK is a good follow-up for DirectX 9/10/11 games"))

    return recommendations
