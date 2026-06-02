from __future__ import annotations

from typing import Any


TIMEOUT_RETURNCODES = {124, 137}


def classify_status(
    returncode: int,
    *,
    has_status: bool = True,
    bench: dict[str, Any] | None = None,
    failure_phase: str = "",
) -> str:
    if not has_status:
        return "not_run"
    if failure_phase == "build":
        return "build_fail"
    if returncode in TIMEOUT_RETURNCODES:
        return "timeout"

    bench = bench or {}
    if "parse_error" in bench:
        return "parse_error" if returncode == 0 else "fail"
    if returncode == 0 and bench:
        return "pass"
    return "fail"
