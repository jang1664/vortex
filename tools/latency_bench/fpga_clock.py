from __future__ import annotations

import math
import re
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping

from .fpga_bins import resolve_fpga_bin_config


DEFAULT_FPGA_PERIOD_S = 10e-9
XCLBIN_INFO_FILENAMES = ("vortex_xclbin.info", "vortex_afu.xclbin.info")


def _to_float(value: object) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def _text(value: object) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    return "" if text.lower() == "nan" else text


def _number_after_colon(line: str) -> float | None:
    text = line.split(":", 1)[1] if ":" in line else line
    match = re.search(r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?", text)
    return _to_float(match.group(0)) if match else None


def _frequency_mhz(line: str) -> float | None:
    number = _number_after_colon(line)
    if number is None or number <= 0.0:
        return None
    lowered = line.lower()
    if "ghz" in lowered:
        return number * 1_000.0
    if "khz" in lowered:
        return number / 1_000.0
    if re.search(r"\bhz\b", lowered) and "mhz" not in lowered:
        return number / 1_000_000.0
    return number


@lru_cache(maxsize=None)
def kernel_clock_period_s(info_path: Path) -> float | None:
    in_kernel_clock = False
    try:
        with info_path.open(errors="ignore") as handle:
            for line in handle:
                if "Name:" in line:
                    in_kernel_clock = "ulp_ucs_aclk_kernel_00" in line
                if not in_kernel_clock or "Achieved Freq:" not in line:
                    continue
                frequency_mhz = _frequency_mhz(line)
                if frequency_mhz is not None:
                    return 1.0 / (frequency_mhz * 1_000_000.0)
    except OSError:
        return None
    return None


def _info_paths(row: Mapping[str, Any]) -> tuple[Path, ...]:
    bin_dirs: list[Path] = []
    explicit_dir = _text(row.get("fpga_bin_dir"))
    if explicit_dir:
        bin_dirs.append(Path(explicit_dir).expanduser())
    for key in ("expected_fpga_bin_label", "fpga_bin_label"):
        label = _text(row.get(key))
        if not label:
            continue
        bin_dir = _resolved_bin_dir(label)
        if bin_dir is not None:
            bin_dirs.append(bin_dir)

    paths: list[Path] = []
    seen: set[str] = set()
    for bin_dir in bin_dirs:
        for filename in XCLBIN_INFO_FILENAMES:
            path = bin_dir / filename
            key = str(path)
            if key not in seen:
                seen.add(key)
                paths.append(path)
    return tuple(paths)


@lru_cache(maxsize=None)
def _resolved_bin_dir(label: str) -> Path | None:
    try:
        return resolve_fpga_bin_config(label).path
    except Exception:
        return None


def resolve_fpga_period_s(
    row: Mapping[str, Any],
    *,
    default: float = DEFAULT_FPGA_PERIOD_S,
) -> float | None:
    explicit = _to_float(row.get("fpga_period_s"))
    if explicit is not None and explicit > 0.0:
        return explicit
    for key in ("fpga_freq_mhz", "power_fpga_freq_mhz", "clock_mhz"):
        frequency_mhz = _to_float(row.get(key))
        if frequency_mhz is not None and frequency_mhz > 0.0:
            return 1.0 / (frequency_mhz * 1_000_000.0)
    for info_path in _info_paths(row):
        period_s = kernel_clock_period_s(info_path)
        if period_s is not None:
            return period_s
    return default if default > 0.0 else None
