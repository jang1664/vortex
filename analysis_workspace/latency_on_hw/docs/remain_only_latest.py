#!/usr/bin/env python3
"""Keep only the latest measurement for each kernel in a raw DB CSV."""

from __future__ import annotations

import argparse
import csv
import os
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


KEY_COLUMN_ALIASES = (
    ("xclbin_sha", "xclbin_sha256"),
    ("kernel", "app"),
    ("args",),
)


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

    retained_indexes = sorted(index for index, _ in latest_by_key.values())
    return [rows[index] for index in retained_indexes], key_columns


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


def process_raw_db(raw_db: Path) -> tuple[Path, int, int, list[str]]:
    raw_db = raw_db.expanduser().resolve()
    if not raw_db.is_file():
        raise FileNotFoundError(f"raw DB does not exist or is not a file: {raw_db}")

    with raw_db.open(newline="") as source:
        reader = csv.DictReader(source)
        fieldnames = list(reader.fieldnames or [])
        rows = list(reader)
    if not fieldnames:
        raise ValueError(f"raw DB has no header: {raw_db}")

    latest, key_columns = keep_latest_rows(rows, fieldnames)
    backup = _default_backup_path(raw_db)
    shutil.copy2(raw_db, backup)

    try:
        _write_csv_atomically(latest, fieldnames, raw_db)
    except Exception:
        # The original path is unchanged unless the atomic replace succeeded;
        # the backup remains available in either case.
        raise

    return backup, len(rows), len(latest), key_columns


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Rewrite raw_db.csv with only the latest row for each "
            "(xclbin SHA, kernel, args) key. A timestamped backup is created "
            "in the same directory before rewriting."
        )
    )
    parser.add_argument("raw_db", type=Path, help="Path to raw_db.csv")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    backup, before, after, key_columns = process_raw_db(args.raw_db)
    print(
        f"kept {after}/{before} rows using key {tuple(key_columns)}; "
        f"removed {before - after} duplicate row(s)"
    )
    print(f"backup: {backup}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
