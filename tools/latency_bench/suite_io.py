"""Storage for suite payloads and their small, relocatable indexes.

PKL inputs must be trusted local artifacts. Pickle is not an interchange format
for untrusted downloads, even though the envelope is validated after loading.
"""
from __future__ import annotations

import os
import pickle
import tempfile
from pathlib import Path
from typing import Any

from .yaml_io import safe_dump, safe_load

SUITE_SUFFIXES = (".yaml", ".yml", ".pkl")


def read_suite_payload(path: Path) -> dict[str, Any]:
    if path.suffix == ".pkl":
        with path.open("rb") as source:
            envelope = pickle.load(source)
        if not isinstance(envelope, dict) or envelope.get("format") != "vortex-latency-suite" or envelope.get("schema_version") != 1:
            raise ValueError(f"unsupported PKL suite schema: {path}")
        payload = envelope.get("suite")
    elif path.suffix in (".yaml", ".yml"):
        with path.open() as source:
            payload = safe_load(source)
    else:
        raise ValueError(f"unsupported suite format: {path}")
    if not isinstance(payload, dict):
        raise ValueError(f"suite must contain a mapping: {path}")
    return payload


def write_suite_payload(path: Path, payload: dict[str, Any]) -> None:
    if path.suffix not in SUITE_SUFFIXES:
        raise ValueError(f"unsupported suite format: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="wb" if path.suffix == ".pkl" else "w",
                                         dir=path.parent, prefix=f".{path.name}.", delete=False) as dest:
            temporary = Path(dest.name)
            if path.suffix == ".pkl":
                pickle.dump({"format": "vortex-latency-suite", "schema_version": 1, "suite": payload}, dest, protocol=pickle.HIGHEST_PROTOCOL)
            else:
                safe_dump(payload, dest, sort_keys=False)
            dest.flush()
            os.fsync(dest.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None and temporary.exists():
            temporary.unlink()


def indexed_suites(index_path: Path) -> list[tuple[str, Path]]:
    with index_path.open() as source:
        index = safe_load(source) or {}
    entries = index.get("generated")
    if not isinstance(entries, list) or not entries:
        raise ValueError(f"empty or invalid suite index: {index_path}")
    result = []
    for entry in entries:
        if not isinstance(entry, dict) or not entry.get("suite"):
            raise ValueError(f"invalid suite index entry: {index_path}")
        original = Path(entry["suite"]).expanduser()
        local = index_path.parent / original.name
        path = local if local.is_file() else original
        if not path.is_file() or path.suffix not in SUITE_SUFFIXES:
            raise ValueError(f"indexed suite is unavailable or unsupported: {path}")
        result.append((str(entry.get("fpga_bin", "")), path.resolve()))
    if len({path for _, path in result}) != len(result):
        raise ValueError(f"duplicate suite entries: {index_path}")
    return result
