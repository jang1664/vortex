"""Freeze candidate selections independently of logical kernel routing."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from .fpga_bins import resolve_fpga_bin_artifacts
from .fpga_clock import XCLBIN_INFO_FILENAMES, kernel_clock_period_s
from .yaml_io import safe_load

PROVENANCE_COLUMNS = ("fpga_bin_alias", "selection_digest", "fpga_period_s", "fpga_clock_source")


def _digest(candidates: dict) -> str:
    return hashlib.sha256(json.dumps(candidates, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_snapshot(snapshot: dict) -> None:
    if not snapshot:
        return
    if not isinstance(snapshot, dict):
        raise ValueError("invalid candidate snapshot")
    candidates = snapshot.get("candidates")
    if snapshot.get("schema_version") != 1 or not isinstance(candidates, dict) or set(candidates) != {"C1", "C2", "C3", "C4"}:
        raise ValueError("invalid candidate snapshot schema")
    required = {"alias", "bin_dir", "xclbin", "xclbin_sha256", "config", "config_sha256", "manifest", "manifest_sha256", "fpga_period_s", "fpga_clock_source"}
    if any(not isinstance(spec, dict) or not required.issubset(spec) for spec in candidates.values()):
        raise ValueError("incomplete candidate snapshot")
    if snapshot.get("selection_digest") != _digest(candidates):
        raise ValueError("candidate snapshot digest mismatch")


def resolve_candidate_map(path: Path) -> dict[str, Any]:
    # Import lazily: report also consumes suites, which validate snapshots.
    from .report import sha256_file
    with path.open() as source:
        payload = safe_load(source)
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ValueError(f"invalid candidate map schema: {path}")
    mapping = payload.get("candidates")
    if not isinstance(mapping, dict) or set(mapping) != {"C1", "C2", "C3", "C4"}:
        raise ValueError(f"candidate map must define C1, C2, C3, C4: {path}")
    candidates = {}
    for label, alias in sorted(mapping.items()):
        if not isinstance(alias, str) or not alias.strip():
            raise ValueError(f"invalid alias for {label}")
        artifacts = resolve_fpga_bin_artifacts(alias, require_alias=True)
        period, clock_source = None, "unavailable"
        for filename in XCLBIN_INFO_FILENAMES:
            info = artifacts.bin_dir / filename
            # A new snapshot must observe replaced files, even in one process.
            kernel_clock_period_s.cache_clear()
            period = kernel_clock_period_s(info)
            if period is not None:
                clock_source = str(info)
                break
        if period is None:
            raise ValueError(f"kernel clock information is unavailable for {alias}")
        candidates[label] = {
            "alias": alias, "bin_dir": str(artifacts.bin_dir),
            "xclbin": str(artifacts.xclbin), "xclbin_sha256": sha256_file(artifacts.xclbin),
            "config": str(artifacts.config), "config_sha256": sha256_file(artifacts.config),
            "manifest": str(artifacts.manifest), "manifest_sha256": sha256_file(artifacts.manifest),
            "fpga_period_s": period, "fpga_clock_source": clock_source,
        }
    return {"schema_version": 1, "candidate_map": str(path.resolve()),
            "selection_digest": _digest(candidates), "candidates": candidates}


def validate_run_selection(snapshot: dict, candidate_map: Path | None = None) -> None:
    validate_snapshot(snapshot)
    path = candidate_map or Path(snapshot["candidate_map"])
    current = resolve_candidate_map(path)
    if current["selection_digest"] != snapshot["selection_digest"]:
        raise ValueError("FPGA selection changed since generation; generate a new experiment")


def measurement_provenance(snapshot: dict, label: str) -> dict:
    if not snapshot:
        return {}
    spec = snapshot["candidates"][label]
    return {"fpga_bin_alias": spec["alias"], "selection_digest": snapshot["selection_digest"],
            "fpga_period_s": spec["fpga_period_s"], "fpga_clock_source": spec["fpga_clock_source"]}


def filter_snapshot_rows(raw, snapshot: dict):
    """Filter before latest-row selection or estimation; no live alias lookup."""
    if not snapshot:
        return raw
    validate_snapshot(snapshot)
    expected = {label: spec["xclbin_sha256"] for label, spec in snapshot["candidates"].items()}
    if "fpga_bin_label" not in raw or "xclbin_sha256" not in raw:
        raise ValueError("mapped composition requires FPGA label and xclbin SHA-256")
    return raw.loc[raw["fpga_bin_label"].map(expected).eq(raw["xclbin_sha256"])].copy()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Validate a captured FPGA selection before running a queued job.")
    parser.add_argument("--run-manifest", required=True, type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.run_manifest.read_text())
    validate_run_selection(manifest["experiment"])
