#!/usr/bin/env python3
"""Delete interpolation-refine promoted rows from latency raw databases."""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


PROMOTED_RUN_ID = "interpolation_refine"
MAX_ARGS_EXAMPLES = 3
MAX_ARGS_DISPLAY_LENGTH = 160


@dataclass(frozen=True)
class AppSummary:
    app: str
    row_count: int
    unique_args_count: int
    args_examples: tuple[str, ...]


@dataclass(frozen=True)
class DeletePlan:
    raw_db: Path
    fieldnames: list[str]
    kept_rows: list[dict[str, str]]
    total_rows: int
    promoted_rows: int
    promoted_by_app: tuple[AppSummary, ...]


@dataclass(frozen=True)
class DeleteResult:
    raw_db: Path
    total_rows: int
    promoted_rows: int
    promoted_by_app: tuple[AppSummary, ...]
    backup: Path | None


def find_raw_dbs(path: Path) -> list[Path]:
    """Resolve a raw DB, one sub-root, or a root containing sub-roots."""

    target = path.expanduser().resolve()
    if target.is_file():
        if target.name != "raw_db.csv":
            raise ValueError(f"expected a file named raw_db.csv: {target}")
        return [target]
    if not target.is_dir():
        raise FileNotFoundError(f"path does not exist or is not a directory: {target}")

    local_raw_db = target / "raw_db.csv"
    if local_raw_db.is_file():
        return [local_raw_db]

    # Only inspect direct children. In particular, do not modify probe DBs under
    # refinement run directories nested below an FPGA-bin sub-root.
    raw_dbs = sorted(
        candidate
        for candidate in target.glob("*/raw_db.csv")
        if candidate.is_file()
    )
    if not raw_dbs:
        raise FileNotFoundError(
            f"no raw_db.csv found in direct subdirectories of: {target}"
        )
    return raw_dbs


def _display_args(value: str) -> str:
    text = " ".join(value.split()) or "<no args>"
    if len(text) <= MAX_ARGS_DISPLAY_LENGTH:
        return text
    return text[: MAX_ARGS_DISPLAY_LENGTH - 3] + "..."


def summarize_promoted_rows(rows: Iterable[dict[str, str]]) -> tuple[AppSummary, ...]:
    grouped: dict[str, list[str]] = {}
    for row in rows:
        app = row.get("app", "").strip() or "<missing app>"
        normalized_args = " ".join(row.get("args", "").split()) or "<no args>"
        grouped.setdefault(app, []).append(normalized_args)

    summaries = []
    for app, args_values in sorted(grouped.items()):
        unique_args = list(dict.fromkeys(args_values))
        summaries.append(
            AppSummary(
                app=app,
                row_count=len(args_values),
                unique_args_count=len(unique_args),
                args_examples=tuple(
                    _display_args(value) for value in unique_args[:MAX_ARGS_EXAMPLES]
                ),
            )
        )
    return tuple(summaries)


def build_delete_plan(raw_db: Path) -> DeletePlan:
    with raw_db.open(newline="") as source:
        reader = csv.DictReader(source)
        fieldnames = list(reader.fieldnames or [])
        if not fieldnames:
            raise ValueError(f"raw DB has no header: {raw_db}")
        if "run_id" not in fieldnames:
            raise ValueError(f"raw DB is missing required column 'run_id': {raw_db}")
        rows = list(reader)

    promoted = [
        row for row in rows if row.get("run_id", "").strip() == PROMOTED_RUN_ID
    ]
    kept_rows = [
        row for row in rows if row.get("run_id", "").strip() != PROMOTED_RUN_ID
    ]
    return DeletePlan(
        raw_db=raw_db,
        fieldnames=fieldnames,
        kept_rows=kept_rows,
        total_rows=len(rows),
        promoted_rows=len(promoted),
        promoted_by_app=summarize_promoted_rows(promoted),
    )


def _backup_path(raw_db: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return raw_db.with_name(f"{raw_db.name}.bak.delete_promoted.{timestamp}")


def _write_csv_atomically(
    destination: Path,
    fieldnames: list[str],
    rows: Iterable[dict[str, str]],
) -> None:
    original_mode = destination.stat().st_mode
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            newline="",
            prefix=f".{destination.name}.",
            suffix=".tmp",
            dir=destination.parent,
            delete=False,
        ) as temporary:
            temporary_path = Path(temporary.name)
            writer = csv.DictWriter(temporary, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, destination)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def apply_delete_plan(plan: DeletePlan, *, dry_run: bool) -> DeleteResult:
    backup: Path | None = None
    if plan.promoted_rows and not dry_run:
        backup = _backup_path(plan.raw_db)
        shutil.copy2(plan.raw_db, backup)
        _write_csv_atomically(plan.raw_db, plan.fieldnames, plan.kept_rows)
    return DeleteResult(
        raw_db=plan.raw_db,
        total_rows=plan.total_rows,
        promoted_rows=plan.promoted_rows,
        promoted_by_app=plan.promoted_by_app,
        backup=backup,
    )


def delete_promoted_rows(path: Path, *, dry_run: bool = False) -> list[DeleteResult]:
    # Build every plan first so a malformed DB cannot cause a partially applied
    # multi-sub-root operation.
    plans = [build_delete_plan(raw_db) for raw_db in find_raw_dbs(path)]
    return [apply_delete_plan(plan, dry_run=dry_run) for plan in plans]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Delete rows whose run_id is 'interpolation_refine'. PATH may be "
            "a raw_db.csv, an FPGA-bin sub-root containing raw_db.csv, or an "
            "output root whose direct subdirectories contain raw_db.csv. "
            "Changed files receive timestamped backups."
        )
    )
    parser.add_argument("path", type=Path, help="Output root, sub-root, or raw_db.csv")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report rows that would be deleted without modifying any files",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        results = delete_promoted_rows(args.path, dry_run=args.dry_run)
    except (FileNotFoundError, OSError, ValueError, csv.Error) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    prefix = "would delete" if args.dry_run else "deleted"
    for result in results:
        print(
            f"{result.raw_db}: {prefix} {result.promoted_rows} promoted row(s); "
            f"kept {result.total_rows - result.promoted_rows}/{result.total_rows}"
        )
        if args.dry_run and result.promoted_by_app:
            print("  delete candidates by app:")
            for app_summary in result.promoted_by_app:
                print(f"    {app_summary.app}: {app_summary.row_count} row(s)")
                for args_example in app_summary.args_examples:
                    print(f"      args: {args_example}")
                omitted = (
                    app_summary.unique_args_count - len(app_summary.args_examples)
                )
                if omitted:
                    print(f"      ... {omitted} more unique args")
        if result.backup is not None:
            print(f"  backup: {result.backup}")
    print(
        f"summary: {prefix} {sum(result.promoted_rows for result in results)} "
        f"promoted row(s) across {len(results)} raw DB(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
