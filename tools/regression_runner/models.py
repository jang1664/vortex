from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class CaseSpec:
    pattern: str
    args: str


@dataclass(frozen=True)
class RegressionCase:
    order: int
    case_id: str
    test: str
    args: str


@dataclass(frozen=True)
class CaseResult:
    order: int
    case_id: str
    test: str
    args: str
    backend: str
    fpga_alias: str
    status: str
    returncode: int | None
    started_at: str
    ended_at: str
    duration_sec: float
    log: str
    message: str = ""
