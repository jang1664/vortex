#!/usr/bin/env python3
"""Keep only the latest measurement for each kernel in a raw DB CSV."""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


KEY_COLUMN_ALIASES = (
    ("xclbin_sha", "xclbin_sha256"),
    ("kernel", "app"),
    ("args",),
)
MAX_EXAMPLES_PER_APP = 3
MAX_ARGS_DISPLAY_LENGTH = 160


@dataclass(frozen=True)
class RawDbAnalysis:
    raw_db: Path
    fieldnames: list[str]
    rows: list[dict[str, str]]
    latest_rows: list[dict[str, str]]
    removed_rows: list[dict[str, str]]
    key_columns: list[str]


def find_raw_dbs(path: Path) -> list[Path]:
    """Resolve one raw DB, one sub-root, or an output root of sub-roots."""

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

    # Output roots contain FPGA-bin sub-roots such as C1/C3/C4_v3. Restrict
    # discovery to direct children so nested runs and refine probe DBs are not
    # modified as side effects.
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


def _resolve_key_columns(columns: Iterable[str]) -> list[str]:
    available = set(columns)
    resolved: list[str] = []
    missing: list[str] = []

    for aliases in KEY_COLUMN_ALIASES:
        column = next((name for name in aliases if name in available), None)
        if column is None:
            missing.append("/".join(aliases))
        else:
            resolved.append(column)

    if missing:
        raise ValueError(
            "raw DB is missing required key column(s): " + ", ".join(missing)
        )
    return resolved


def _timestamp_sort_key(value: str) -> tuple[int, datetime]:
    text = value.strip()
    if not text:
        return 0, datetime.min.replace(tzinfo=timezone.utc)
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return 0, datetime.min.replace(tzinfo=timezone.utc)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return 1, parsed.astimezone(timezone.utc)


def keep_latest_rows(
    rows: list[dict[str, str]], fieldnames: list[str]
) -> tuple[list[dict[str, str]], list[str]]:
    """Return one latest row per measurement key and the resolved key columns.

    ``timestamp_utc`` determines recency when present. Rows with equal or
    missing timestamps use their order in the input CSV as the tie-breaker.
    If the timestamp column is absent, the last row in the CSV is considered
    the latest.
    """

    key_columns = _resolve_key_columns(fieldnames)
    latest_by_key: dict[tuple[str, ...], tuple[int, tuple[int, datetime]]] = {}
    has_timestamp = "timestamp_utc" in fieldnames

    for index, row in enumerate(rows):
        key = tuple(row.get(column, "") for column in key_columns)
        timestamp = (
            _timestamp_sort_key(row.get("timestamp_utc", ""))
            if has_timestamp
            else (0, datetime.min.replace(tzinfo=timezone.utc))
        )
        previous = latest_by_key.get(key)
        if previous is None or (timestamp, index) >= (previous[1], previous[0]):
            latest_by_key[key] = index, timestamp

    retained_indexes = {index for index, _ in latest_by_key.values()}
    return [row for index, row in enumerate(rows) if index in retained_indexes], key_columns


def analyze_raw_db(raw_db: Path) -> RawDbAnalysis:
    raw_db = raw_db.expanduser().resolve()
    if not raw_db.is_file():
        raise FileNotFoundError(f"raw DB does not exist or is not a file: {raw_db}")

    with raw_db.open(newline="") as source:
        reader = csv.DictReader(source)
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)
    if not fieldnames:
        raise ValueError(f"raw DB has no header: {raw_db}")

    latest_rows, key_columns = keep_latest_rows(rows, fieldnames)
    latest_row_ids = {id(row) for row in latest_rows}
    removed_rows = [row for row in rows if id(row) not in latest_row_ids]
    return RawDbAnalysis(
        raw_db=raw_db,
        fieldnames=fieldnames,
        rows=rows,
        latest_rows=latest_rows,
        removed_rows=removed_rows,
        key_columns=key_columns,
    )


def _default_backup_path(raw_db: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return raw_db.with_name(f"{raw_db.name}.bak.{timestamp}")


def _write_csv_atomically(
    rows: Iterable[dict[str, str]], fieldnames: list[str], destination: Path
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
        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, destination)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def process_analysis(analysis: RawDbAnalysis) -> tuple[Path, int, int, list[str]]:
    backup = _default_backup_path(analysis.raw_db)
    shutil.copy2(analysis.raw_db, backup)

    try:
        _write_csv_atomically(
            analysis.latest_rows, analysis.fieldnames, analysis.raw_db
        )
    except Exception:
        # The original path is unchanged unless the atomic replace succeeded;
        # the backup remains available in either case.
        raise

    return (
        backup,
        len(analysis.rows),
        len(analysis.latest_rows),
        analysis.key_columns,
    )


def process_raw_db(raw_db: Path) -> tuple[Path, int, int, list[str]]:
    return process_analysis(analyze_raw_db(raw_db))


def _display_args(value: str) -> str:
    text = " ".join(value.split()) or "<no args>"
    if len(text) <= MAX_ARGS_DISPLAY_LENGTH:
        return text
    return text[: MAX_ARGS_DISPLAY_LENGTH - 3] + "..."


def print_dry_run_summary(analysis: RawDbAnalysis) -> None:
    before = len(analysis.rows)
    after = len(analysis.latest_rows)
    print(
        f"dry-run: would keep {after}/{before} rows using key "
        f"{tuple(analysis.key_columns)}; would remove {before - after} "
        "duplicate row(s)"
    )
    if not analysis.removed_rows:
        print("delete candidates: none")
        return

    app_column = "kernel" if "kernel" in analysis.fieldnames else "app"
    grouped: dict[str, list[dict[str, str]]] = {}
    for row in analysis.removed_rows:
        app = row.get(app_column, "").strip() or "<missing app>"
        grouped.setdefault(app, []).append(row)

    print("delete candidates by app:")
    for app, rows in sorted(grouped.items()):
        print(f"  {app}: {len(rows)} row(s)")
        for row in rows[:MAX_EXAMPLES_PER_APP]:
            details = [f"args={_display_args(row.get('args', ''))!r}"]
            if "timestamp_utc" in analysis.fieldnames:
                details.append(f"timestamp={row.get('timestamp_utc', '') or '<missing>'}")
            if "run_id" in analysis.fieldnames:
                details.append(f"run_id={row.get('run_id', '') or '<missing>'}")
            print("    " + " | ".join(details))
        omitted = len(rows) - MAX_EXAMPLES_PER_APP
        if omitted > 0:
            print(f"    ... {omitted} more row(s)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Rewrite raw_db.csv with only the latest row for each "
            "(xclbin SHA, kernel, args) key. A timestamped backup is created "
            "in the same directory before rewriting. PATH may be a raw_db.csv, "
            "a sub-root containing one, or an output root whose direct "
            "subdirectories contain raw_db.csv files."
        )
    )
    parser.add_argument(
        "path", type=Path, help="Output root, sub-root, or raw_db.csv"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report rows that would be removed without modifying the CSV",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    # Validate every selected DB before rewriting any of them.
    analyses = [analyze_raw_db(raw_db) for raw_db in find_raw_dbs(args.path)]
    if args.dry_run:
        for analysis in analyses:
            print(f"{analysis.raw_db}:")
            print_dry_run_summary(analysis)
        print(
            f"summary: would remove "
            f"{sum(len(analysis.removed_rows) for analysis in analyses)} "
            f"duplicate row(s) across {len(analyses)} raw DB(s)"
        )
        return 0

    total_removed = 0
    for analysis in analyses:
        backup, before, after, key_columns = process_analysis(analysis)
        total_removed += before - after
        print(
            f"{analysis.raw_db}: kept {after}/{before} rows using key "
            f"{tuple(key_columns)}; removed {before - after} duplicate row(s)"
        )
        print(f"  backup: {backup}")
    print(
        f"summary: removed {total_removed} duplicate row(s) across "
        f"{len(analyses)} raw DB(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
