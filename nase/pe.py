from __future__ import annotations

from pathlib import Path


PE_MACHINE_I386 = 0x014C
PE_MACHINE_AMD64 = 0x8664


def pe_machine(path: Path) -> int | None:
    """Return the COFF machine for a PE executable, or None for a non-PE file."""
    candidate = path.expanduser().resolve()
    try:
        with candidate.open("rb") as handle:
            if handle.read(2) != b"MZ":
                return None
            handle.seek(0x3C)
            offset_bytes = handle.read(4)
            if len(offset_bytes) != 4:
                return None
            handle.seek(int.from_bytes(offset_bytes, "little"))
            if handle.read(4) != b"PE\0\0":
                return None
            machine_bytes = handle.read(2)
            return int.from_bytes(machine_bytes, "little") if len(machine_bytes) == 2 else None
    except OSError:
        return None


def executable_architecture(path: Path) -> str:
    machine = pe_machine(path)
    if machine == PE_MACHINE_I386:
        return "x86"
    if machine == PE_MACHINE_AMD64:
        return "x86_64"
    return "unknown"
