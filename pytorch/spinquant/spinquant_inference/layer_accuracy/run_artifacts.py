"""Serialization for backend run captures and physical-plan metadata."""

from __future__ import annotations

import json
from pathlib import Path

import torch

from .graph import RunResult
from .tensor_io import tensor_sha256


RUN_SCHEMA_VERSION = 1


def save_run(result: RunResult, path: str | Path, *, capture_mode: str) -> None:
    if capture_mode not in ("semantic", "physical", "both"):
        raise ValueError(f"invalid capture mode {capture_mode!r}")
    destination = Path(path)
    destination.mkdir(parents=True, exist_ok=False)
    torch.save(result.captures, destination / "captures.pt")
    torch.save(result.auxiliary_captures, destination / "auxiliary_captures.pt")
    capture_hashes = {
        name: tensor_sha256(tensor) for name, tensor in sorted(result.captures.items())
    }
    auxiliary_hashes = {
        name: tensor_sha256(tensor)
        for name, tensor in sorted(result.auxiliary_captures.items())
    }
    metadata = {
        "schema_version": RUN_SCHEMA_VERSION,
        "backend": result.backend,
        "case_hash": result.case_hash,
        "graph_version": result.graph_version,
        "stop_after": result.stop_after,
        "stage_order": result.stage_order,
        "capture_mode": capture_mode,
        "capture_hashes": capture_hashes,
        "auxiliary_capture_hashes": auxiliary_hashes,
        "placement": result.placement,
    }
    (destination / "run.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (destination / "physical_plan.json").write_text(
        json.dumps(result.placement, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def load_run(path: str | Path) -> tuple[dict, dict[str, torch.Tensor], dict[str, torch.Tensor]]:
    source = Path(path)
    metadata = json.loads((source / "run.json").read_text(encoding="utf-8"))
    if metadata.get("schema_version") != RUN_SCHEMA_VERSION:
        raise ValueError(f"unsupported run schema version {metadata.get('schema_version')!r}")
    captures = torch.load(source / "captures.pt", map_location="cpu", weights_only=True)
    auxiliary = torch.load(
        source / "auxiliary_captures.pt", map_location="cpu", weights_only=True
    )
    _validate_hashes("capture", captures, metadata.get("capture_hashes", {}))
    _validate_hashes("auxiliary capture", auxiliary, metadata.get("auxiliary_capture_hashes", {}))
    return metadata, captures, auxiliary


def _validate_hashes(kind: str, tensors: dict[str, torch.Tensor], expected: dict[str, str]) -> None:
    if set(tensors) != set(expected):
        raise ValueError(f"{kind} set does not match run metadata")
    for name, tensor in tensors.items():
        actual = tensor_sha256(tensor)
        if actual != expected[name]:
            raise ValueError(f"{kind} checksum mismatch for {name}: {actual} != {expected[name]}")
