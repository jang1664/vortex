from __future__ import annotations

import csv
import json
from dataclasses import asdict
from pathlib import Path
from typing import Any, Iterable

from .models import CaseResult, RegressionCase


RESULT_COLUMNS = (
    "order",
    "case_id",
    "test",
    "args",
    "backend",
    "fpga_alias",
    "status",
    "returncode",
    "started_at",
    "ended_at",
    "duration_sec",
    "log",
    "message",
)


def _atomic_text(path: Path, text: str) -> None:
    temporary = path.with_name(f".{path.name}.tmp")
    temporary.write_text(text)
    temporary.replace(path)


def write_json(path: Path, value: Any) -> None:
    _atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n")


def write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    write_json(path, manifest)


def write_results(run_dir: Path, manifest: dict[str, Any], results: list[CaseResult]) -> None:
    rows = [asdict(result) for result in results]
    write_json(
        run_dir / "results.json",
        {
            "schema_version": 1,
            "run_id": manifest["run_id"],
            "backend": manifest["backend"],
            "fpga_alias": manifest["fpga_alias"],
            "results": rows,
        },
    )

    csv_path = run_dir / "results.csv"
    temporary = csv_path.with_name(f".{csv_path.name}.tmp")
    with temporary.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=RESULT_COLUMNS)
        writer.writeheader()
        writer.writerows(rows)
    temporary.replace(csv_path)


def _display(value: object, limit: int) -> str:
    text = "" if value is None else str(value)
    text = text.replace("\n", "\\n")
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)] + "…"


def render_table(
    headers: list[str],
    rows: Iterable[Iterable[object]],
    *,
    limits: dict[int, int] | None = None,
) -> str:
    limits = limits or {}
    rendered = [
        [_display(value, limits.get(index, 80)) for index, value in enumerate(row)]
        for row in rows
    ]
    widths = [len(header) for header in headers]
    for row in rendered:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def line(char: str = "-") -> str:
        return "+" + "+".join(char * (width + 2) for width in widths) + "+"

    def row_text(row: list[str]) -> str:
        return "| " + " | ".join(value.ljust(widths[index]) for index, value in enumerate(row)) + " |"

    output = [line(), row_text(headers), line("=")]
    output.extend(row_text(row) for row in rendered)
    output.append(line())
    return "\n".join(output)


def render_case_table(cases: list[RegressionCase]) -> str:
    return render_table(
        ["#", "test", "args", "case_id"],
        ((case.order, case.test, case.args, case.case_id) for case in cases),
        limits={1: 52, 2: 64, 3: 72},
    )


def render_result_table(results: list[CaseResult]) -> str:
    return render_table(
        ["#", "test", "args", "backend", "fpga", "status", "exit", "duration", "log"],
        (
            (
                result.order,
                result.test,
                result.args,
                result.backend,
                result.fpga_alias,
                result.status,
                result.returncode,
                f"{result.duration_sec:.2f}s",
                result.log,
            )
            for result in results
        ),
        limits={1: 42, 2: 52, 8: 48},
    )


def summarize_results(results: list[CaseResult]) -> str:
    statuses = ("PASS", "FAIL", "TIMEOUT", "ERROR", "INTERRUPTED")
    counts = {status: 0 for status in statuses}
    for result in results:
        counts[result.status] = counts.get(result.status, 0) + 1
    details = " ".join(f"{status}={counts[status]}" for status in statuses)
    return f"TOTAL={len(results)} {details}"
