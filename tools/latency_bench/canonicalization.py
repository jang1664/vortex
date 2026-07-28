from __future__ import annotations

import shlex
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .yaml_io import safe_load


DEFAULT_CANONICALIZATION_PATH = (
    Path(__file__).resolve().parent / "kernel_latency_canonicalization.yaml"
)


@dataclass(frozen=True)
class CanonicalizedArgs:
    measurement_args: str
    latency_shape: dict[str, Any]


def _align_up(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def load_canonicalization_policies(
    path: Path = DEFAULT_CANONICALIZATION_PATH,
) -> dict[str, Any]:
    with path.open() as fp:
        raw = safe_load(fp) or {}
    if raw.get("version") != 1:
        raise ValueError(f"unsupported canonicalization policy version: {path}")
    fpga_bins = raw.get("fpga_bins")
    if not isinstance(fpga_bins, dict):
        raise ValueError(f"canonicalization policy must define fpga_bins: {path}")
    unsupported = set(fpga_bins).difference({"C1", "C2", "C3", "C4"})
    if unsupported:
        raise ValueError(
            f"canonicalization policy only supports C1-C4, got {sorted(unsupported)}"
        )
    return fpga_bins


def canonicalize_args(
    *,
    app: str,
    args: str,
    fpga_bin_label: str,
    policies: dict[str, Any],
) -> CanonicalizedArgs:
    bin_policy = policies.get(fpga_bin_label)
    if not isinstance(bin_policy, dict):
        return CanonicalizedArgs(args, {})
    apps = bin_policy.get("apps")
    app_policy = apps.get(app) if isinstance(apps, dict) else None
    if not isinstance(app_policy, dict):
        return CanonicalizedArgs(args, {})
    mode = str(app_policy.get("mode", "exact"))
    if mode == "exact":
        return CanonicalizedArgs(
            args,
            {
                "fpga_bin_label": fpga_bin_label,
                "app": app,
                "mode": "exact",
            },
        )
    if mode != "aligned":
        raise ValueError(
            f"unsupported canonicalization mode for {fpga_bin_label}/{app}: {mode}"
        )
    alignments = app_policy.get("align")
    if not isinstance(alignments, dict):
        raise ValueError(
            f"canonicalization policy for {fpga_bin_label}/{app} must define align"
        )

    parts = shlex.split(args)
    canonical: dict[str, int] = {}
    for option, raw_alignment in alignments.items():
        alignment = int(raw_alignment)
        if alignment < 1:
            raise ValueError(
                f"invalid alignment for {fpga_bin_label}/{app}/{option}: {alignment}"
            )
        try:
            index = parts.index(str(option))
        except ValueError as exc:
            raise ValueError(
                f"canonicalization option {option!r} is missing from {app} args: {args!r}"
            ) from exc
        if index + 1 >= len(parts):
            raise ValueError(f"missing value after {option!r} in {app} args: {args!r}")
        try:
            logical = int(parts[index + 1])
        except ValueError as exc:
            raise ValueError(
                f"canonicalization option {option!r} must be an integer: {args!r}"
            ) from exc
        value = _align_up(logical, alignment)
        parts[index + 1] = str(value)
        canonical[str(option)] = value

    return CanonicalizedArgs(
        measurement_args=shlex.join(parts),
        latency_shape={
            "fpga_bin_label": fpga_bin_label,
            "app": app,
            "mode": "aligned",
            "canonical_arguments": canonical,
        },
    )
