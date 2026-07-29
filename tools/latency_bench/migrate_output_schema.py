#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import json
import shutil
from pathlib import Path

from .canonicalization import canonicalize_args, load_canonicalization_policies
from .raw_db import RAW_DB_COLUMNS
from .suite import make_exec_key


CASE_COLUMNS = [
    "suite", "case_id", "exec_key", "app", "model", "kind", "op", "backend",
    "variant", "stage", "name", "batch", "prefill_seq_len", "gen_kv_len",
    "args", "measurement_args",
    "latency_shape_json", "padded_args", "shape_json", "calls_per_forward",
    "output_token_index", "out_tokens", "measurement_kind", "warmup",
    "iterations", "source",
]


def _read_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as fp:
        return list(csv.DictReader(fp))


def _write_rows(path: Path, columns: list[str], rows: list[dict[str, object]]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp.schema-migration")
    with tmp.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})
    tmp.replace(path)


def _canonicalize_row(
    row: dict[str, str],
    *,
    fpga_bin_label: str,
    policies: dict,
) -> tuple[str, dict]:
    canonical = canonicalize_args(
        app=row.get("app", ""),
        args=row.get("args", ""),
        fpga_bin_label=fpga_bin_label,
        policies=policies,
    )
    return canonical.measurement_args, canonical.latency_shape


def migrate_cases(
    path: Path,
    *,
    fpga_bin_label: str,
    xclbin_sha256: str,
    policies: dict,
) -> tuple[int, int]:
    old_rows = _read_rows(path)
    rows: list[dict[str, object]] = []
    changed_args = 0
    for old in old_rows:
        measurement_args, latency_shape = _canonicalize_row(
            old, fpga_bin_label=fpga_bin_label, policies=policies
        )
        if measurement_args != old.get("args", ""):
            changed_args += 1
        row: dict[str, object] = dict(old)
        output_token_index = old.get("output_token_index", "")
        if not output_token_index:
            try:
                shape = json.loads(old.get("shape_json", "") or "{}")
                output_token_index = int(shape.get(
                    "output_token_index",
                    (
                        int(shape["logical_cache_length"])
                        - int(shape["input_kv_length"])
                    )
                    if (
                        old.get("stage") == "generation"
                        and "logical_cache_length" in shape
                        and "input_kv_length" in shape
                    )
                    else 0,
                ))
            except (TypeError, ValueError, json.JSONDecodeError):
                output_token_index = 0
        row.update({
            "measurement_args": measurement_args,
            "latency_shape_json": json.dumps(latency_shape, sort_keys=True),
            "padded_args": (
                old.get("padded_args", "")
                or (measurement_args if measurement_args != old.get("args", "") else "")
            ),
            "output_token_index": output_token_index,
            "out_tokens": old.get("out_tokens", "1") or "1",
            "measurement_kind": old.get("measurement_kind", "measured") or "measured",
            "exec_key": make_exec_key(
                xclbin_sha256,
                old.get("app", ""),
                measurement_args,
            ),
        })
        rows.append(row)
    _write_rows(path, CASE_COLUMNS, rows)
    return len(rows), changed_args


def migrate_raw_db(path: Path, *, fpga_bin_label: str, policies: dict) -> tuple[int, int]:
    old_rows = _read_rows(path)
    unique: dict[tuple[str, ...], dict[str, object]] = {}
    changed_args = 0
    for old in old_rows:
        measurement_args, _ = _canonicalize_row(
            old, fpga_bin_label=fpga_bin_label, policies=policies
        )
        if measurement_args != old.get("args", ""):
            changed_args += 1
        exec_key = make_exec_key(
            old.get("xclbin_sha256", ""),
            old.get("app", ""),
            measurement_args,
        )
        row: dict[str, object] = {
            column: old.get(column, "") for column in RAW_DB_COLUMNS
        }
        row.update({
            "exec_key": exec_key,
            "args": measurement_args,
            "padded_args": (
                old.get("padded_args", "")
                or (measurement_args if measurement_args != old.get("args", "") else "")
            ),
        })
        key = (
            old.get("run_id", ""),
            old.get("fpga_bin_label", fpga_bin_label),
            old.get("xclbin_sha256", ""),
            old.get("app", ""),
            measurement_args,
        )
        previous = unique.get(key)
        if previous is None or (
            previous.get("status") != "pass" and row.get("status") == "pass"
        ):
            unique[key] = row
    rows = list(unique.values())
    _write_rows(path, RAW_DB_COLUMNS, rows)
    return len(old_rows), len(rows)


def _backup_file(path: Path, *, common_root: Path, backup_root: Path) -> None:
    destination = backup_root / path.relative_to(common_root)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination)


def migrate_roots(roots: list[Path], backup_root: Path) -> None:
    roots = [root.resolve() for root in roots]
    backup_root = backup_root.resolve()
    policies = load_canonicalization_policies()
    common_root = Path.cwd().resolve()
    files = [
        path
        for root in roots
        for path in (
            list(root.glob("*/raw_db.csv"))
            + list(root.glob("*/runs/*/cases.csv"))
        )
    ]
    for path in files:
        _backup_file(path, common_root=common_root, backup_root=backup_root)

    raw_before = raw_after = case_rows = canonical_cases = 0
    for root in roots:
        for path in sorted(root.glob("*/raw_db.csv")):
            before, after = migrate_raw_db(
                path, fpga_bin_label=path.parent.name, policies=policies
            )
            raw_before += before
            raw_after += after
        for path in sorted(root.glob("*/runs/*/cases.csv")):
            raw_db = path.parents[2] / "raw_db.csv"
            raw_rows = _read_rows(raw_db)
            xclbin_shas = {
                str(row.get("xclbin_sha256", "")).strip()
                for row in raw_rows
                if str(row.get("xclbin_sha256", "")).strip()
            }
            if len(xclbin_shas) != 1:
                raise ValueError(
                    f"expected exactly one xclbin_sha256 in {raw_db}, "
                    f"found {sorted(xclbin_shas)}"
                )
            rows, changed = migrate_cases(
                path,
                fpga_bin_label=path.parents[2].name,
                xclbin_sha256=next(iter(xclbin_shas)),
                policies=policies,
            )
            case_rows += rows
            canonical_cases += changed

    print(f"backed up {len(files)} CSV files to {backup_root}")
    print(f"raw rows: {raw_before} -> {raw_after}")
    print(f"case rows: {case_rows} ({canonical_cases} canonicalized)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup-root", type=Path, required=True)
    parser.add_argument("roots", nargs="+", type=Path)
    args = parser.parse_args()
    migrate_roots(args.roots, args.backup_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
