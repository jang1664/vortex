from __future__ import annotations

import csv
import math
from pathlib import Path
from typing import Any


def _parse_int_field(value: str) -> int:
    return int(float(value))


def _parse_float_field(value: str) -> float:
    return float(value)


def _parse_cycle_field(value: str) -> int | float:
    parsed = float(value)
    if math.isnan(parsed):
        return parsed
    if parsed.is_integer():
        return int(parsed)
    return parsed


def _select_power_summary_row(rows: list[dict[str, str]]) -> dict[str, str]:
    for row in rows:
        if row.get("mode") == "separate" and row.get("phase") == "run":
            return row
    for row in rows:
        if row.get("phase") == "run":
            return row
    return rows[0]


def read_power_summary(path: Path | str | None) -> dict[str, Any]:
    if path is None or str(path) == "":
        return {}

    summary_path = Path(path)
    if not summary_path.exists():
        return {"power_parse_error": "missing_power_summary"}

    try:
        with summary_path.open(newline="") as fp:
            rows = list(csv.DictReader(fp))
    except OSError as exc:
        return {"power_parse_error": str(exc)}

    if not rows:
        return {"power_parse_error": "empty_power_summary"}

    row = _select_power_summary_row(rows)
    fields = (
        ("power_samples", "samples", _parse_int_field),
        ("power_elapsed_s", "elapsed_s", _parse_float_field),
        ("power_min_w", "run_min_w", _parse_float_field),
        ("power_avg_w", "run_avg_w", _parse_float_field),
        ("power_max_w", "run_max_w", _parse_float_field),
    )
    out: dict[str, Any] = {}
    errors: list[str] = []
    for output_key, input_key, parser in fields:
        value = row.get(input_key, "")
        if value == "":
            errors.append(f"missing_power_field:{input_key}")
            continue
        try:
            out[output_key] = parser(value)
        except ValueError as exc:
            errors.append(f"{input_key}:{exc}")

    optional_fields = (
        ("power_latency", ("power_latency", "latency_avg_us"), _parse_float_field),
        ("power_fpga_cycle", ("power_fpga_cycle",), _parse_cycle_field),
        ("power_kernel_iterations", ("power_kernel_iterations",), _parse_int_field),
        ("power_kernel_iterations_auto", ("power_kernel_iterations_auto",), _parse_int_field),
        ("power_target_sec", ("power_target_sec",), _parse_float_field),
    )
    for output_key, input_keys, parser in optional_fields:
        value = ""
        for input_key in input_keys:
            value = row.get(input_key, "")
            if value != "":
                break
        if value == "":
            continue
        try:
            out[output_key] = parser(value)
        except ValueError as exc:
            errors.append(f"{output_key}:{exc}")

    if errors:
        out["power_parse_error"] = ";".join(errors)
    else:
        out["power_parse_error"] = ""
    return out
