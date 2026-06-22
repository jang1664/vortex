#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.latency_bench.raw_db import RAW_DB_COLUMNS  # noqa: E402


WORKSPACE = Path(__file__).resolve().parent
DEFAULT_MAIN_ROOT = WORKSPACE / "outputs_main"
DEFAULT_POWER_ROOT = WORKSPACE / "outputs_main_power"

POWER_COPY_COLUMNS = [
    "power_csv",
    "power_summary",
    "power_samples",
    "power_elapsed_s",
    "power_min_w",
    "power_avg_w",
    "power_max_w",
    "power_parse_error",
]
LOW_SAMPLE_POWER_COLUMNS = [
    "power_elapsed_s",
    "power_min_w",
    "power_avg_w",
    "power_max_w",
    "power_parse_error",
]


@dataclass(frozen=True)
class MergeSummary:
    fpga_bin: str
    main_rows: int
    power_rows: int
    matched_rows: int
    missing_rows: int
    low_sample_rows: int
    output: Path
    backup: Path | None = None


def _read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(newline="") as fp:
        reader = csv.DictReader(fp)
        return list(reader.fieldnames or []), list(reader)


def _write_csv(path: Path, rows: Iterable[dict[str, str]]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp.merge_power")
    with tmp.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=RAW_DB_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in RAW_DB_COLUMNS})
    tmp.replace(path)


def _match_key(row: dict[str, str]) -> tuple[str, str]:
    return row.get("app", ""), row.get("args", "")


def _power_index(rows: list[dict[str, str]], *, power_csv: Path) -> dict[tuple[str, str], dict[str, str]]:
    out: dict[tuple[str, str], dict[str, str]] = {}
    duplicates: list[tuple[str, str]] = []
    for row in rows:
        key = _match_key(row)
        if key in out:
            duplicates.append(key)
        else:
            out[key] = row
    if duplicates:
        sample = ", ".join(f"app={app!r} args={args!r}" for app, args in duplicates[:5])
        raise ValueError(f"{power_csv} has duplicate power match keys: {sample}")
    return out


def _merged_row(main_row: dict[str, str], power_row: dict[str, str] | None) -> tuple[dict[str, str], bool, bool]:
    out = {column: "" for column in RAW_DB_COLUMNS}
    for column in RAW_DB_COLUMNS:
        if column in main_row:
            out[column] = main_row.get(column, "")

    out["measure_latency"] = out.get("measure_latency") or "1"

    if power_row is None:
        out["measure_power"] = "0"
        return out, False, False

    out["measure_power"] = "1"
    for column in POWER_COPY_COLUMNS:
        out[column] = power_row.get(column, "")

    if power_row.get("failure_reason", "") == "power_samples_low":
        out["status"] = "pass"
        out["returncode"] = "0"
        out["failure_phase"] = ""
        out["failure_reason"] = ""
        out["power_samples"] = "0"
        for column in LOW_SAMPLE_POWER_COLUMNS:
            out[column] = ""
        return out, True, True

    return out, True, False


def _backup_path(raw_db: Path, backup_suffix: str) -> Path:
    return raw_db.with_name(raw_db.name + backup_suffix)


def merge_raw_db(
    *,
    main_csv: Path,
    power_csv: Path | None,
    in_place: bool,
    backup_suffix: str,
) -> MergeSummary:
    main_header, main_rows = _read_csv(main_csv)
    if not main_header:
        raise ValueError(f"{main_csv} has no header")

    power_rows: list[dict[str, str]] = []
    power_by_key: dict[tuple[str, str], dict[str, str]] = {}
    if power_csv is not None and power_csv.exists():
        _, power_rows = _read_csv(power_csv)
        power_by_key = _power_index(power_rows, power_csv=power_csv)

    merged_rows: list[dict[str, str]] = []
    matched_rows = 0
    low_sample_rows = 0
    for main_row in main_rows:
        power_row = power_by_key.get(_match_key(main_row))
        merged, matched, low_sample = _merged_row(main_row, power_row)
        merged_rows.append(merged)
        matched_rows += int(matched)
        low_sample_rows += int(low_sample)

    backup: Path | None = None
    if in_place:
        backup = _backup_path(main_csv, backup_suffix)
        if backup.exists():
            raise FileExistsError(f"backup already exists: {backup}")
        shutil.copy2(main_csv, backup)
        _write_csv(main_csv, merged_rows)

    return MergeSummary(
        fpga_bin=main_csv.parent.name,
        main_rows=len(main_rows),
        power_rows=len(power_rows),
        matched_rows=matched_rows,
        missing_rows=len(main_rows) - matched_rows,
        low_sample_rows=low_sample_rows,
        output=main_csv,
        backup=backup,
    )


def merge_roots(
    *,
    main_root: Path,
    power_root: Path,
    in_place: bool,
    backup_suffix: str,
) -> list[MergeSummary]:
    if not main_root.is_dir():
        raise FileNotFoundError(f"main root not found: {main_root}")
    if not power_root.is_dir():
        raise FileNotFoundError(f"power root not found: {power_root}")

    summaries: list[MergeSummary] = []
    for main_csv in sorted(main_root.glob("*/raw_db.csv")):
        fpga_bin = main_csv.parent.name
        power_csv = power_root / fpga_bin / "raw_db.csv"
        summaries.append(
            merge_raw_db(
                main_csv=main_csv,
                power_csv=power_csv if power_csv.exists() else None,
                in_place=in_place,
                backup_suffix=backup_suffix,
            )
        )
    return summaries


def _default_backup_suffix() -> str:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    return f".bak.{stamp}"


def _print_summary(summaries: list[MergeSummary], *, in_place: bool) -> None:
    mode = "wrote" if in_place else "dry-run"
    print(f"[merge-power-raw-db] mode={mode} files={len(summaries)}")
    for summary in summaries:
        backup = f" backup={summary.backup}" if summary.backup else ""
        print(
            "[merge-power-raw-db] "
            f"fpga_bin={summary.fpga_bin} "
            f"main_rows={summary.main_rows} "
            f"power_rows={summary.power_rows} "
            f"matched={summary.matched_rows} "
            f"missing={summary.missing_rows} "
            f"low_sample_normalized={summary.low_sample_rows} "
            f"output={summary.output}"
            f"{backup}"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Merge power columns from outputs_main_power raw_db.csv files into outputs_main raw_db.csv files."
    )
    parser.add_argument("--main-root", type=Path, default=DEFAULT_MAIN_ROOT, help="Root containing main per-FPGA raw_db.csv files.")
    parser.add_argument("--power-root", type=Path, default=DEFAULT_POWER_ROOT, help="Root containing power per-FPGA raw_db.csv files.")
    parser.add_argument("--in-place", action="store_true", help="Rewrite main raw_db.csv files after creating backups.")
    parser.add_argument(
        "--backup-suffix",
        default=None,
        help="Suffix appended to each raw_db.csv backup; default is a UTC timestamp.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    backup_suffix = args.backup_suffix or _default_backup_suffix()
    summaries = merge_roots(
        main_root=args.main_root,
        power_root=args.power_root,
        in_place=args.in_place,
        backup_suffix=backup_suffix,
    )
    _print_summary(summaries, in_place=args.in_place)
    if not args.in_place:
        print("[merge-power-raw-db] dry-run only; pass --in-place to rewrite outputs_main raw_db.csv files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
