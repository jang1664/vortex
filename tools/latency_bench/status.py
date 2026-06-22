from __future__ import annotations

from typing import Any


TIMEOUT_RETURNCODES = {124, 137}
DEFAULT_POWER_MIN_SAMPLES = 5
POWER_SAMPLES_LOW_REASON = "power_samples_low"


def _parse_sample_count(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def power_samples_below_threshold(power: dict[str, Any] | None, power_min_samples: int) -> bool:
    if power_min_samples < 0:
        raise ValueError("power_min_samples must be >= 0")
    if power_min_samples == 0:
        return False
    samples = _parse_sample_count((power or {}).get("power_samples"))
    return samples is None or samples < power_min_samples


def power_sample_failure_reason(
    power: dict[str, Any] | None,
    *,
    measure_power: bool,
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES,
) -> str:
    if measure_power and power_samples_below_threshold(power, power_min_samples):
        return POWER_SAMPLES_LOW_REASON
    return ""


def classify_status(
    returncode: int,
    *,
    has_status: bool = True,
    bench: dict[str, Any] | None = None,
    power: dict[str, Any] | None = None,
    measure_power: bool = False,
    power_min_samples: int = DEFAULT_POWER_MIN_SAMPLES,
    failure_phase: str = "",
    failure_reason: str = "",
) -> str:
    if not has_status:
        return "not_run"
    if failure_phase == "build" or failure_reason == "build":
        return "build_fail"
    if returncode in TIMEOUT_RETURNCODES or failure_reason == "timeout":
        return "timeout"
    if failure_reason == POWER_SAMPLES_LOW_REASON:
        return "fail"

    bench = bench or {}
    if "parse_error" in bench:
        return "parse_error" if returncode == 0 else "fail"
    if returncode == 0 and power_sample_failure_reason(
        power,
        measure_power=measure_power,
        power_min_samples=power_min_samples,
    ):
        return "fail"
    if returncode == 0 and bench:
        return "pass"
    return "fail"
