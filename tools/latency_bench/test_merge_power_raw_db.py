from __future__ import annotations

import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[2] / "analysis_workspace" / "latency_on_hw" / "merge_power_raw_db.py"
SPEC = importlib.util.spec_from_file_location("merge_power_raw_db", SCRIPT)
assert SPEC is not None
merge_power_raw_db = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = merge_power_raw_db
SPEC.loader.exec_module(merge_power_raw_db)


LEGACY_COLUMNS = [
    "run_id",
    "timestamp_utc",
    "fpga_bin_label",
    "git_commit",
    "git_branch",
    "git_dirty",
    "suite",
    "case_id",
    "exec_key",
    "app",
    "kind",
    "op",
    "backend",
    "variant",
    "stage",
    "name",
    "args",
    "shape_json",
    "calls_per_forward",
    "fpga_bin_dir",
    "xclbin_sha256",
    "warmup",
    "iterations",
    "source",
    "status",
    "returncode",
    "failure_phase",
    "failure_reason",
    "raw_csv",
    "log_file",
    "elapsed_wall_s",
    "samples",
    "min_us",
    "avg_us",
    "max_us",
    "p50_us",
    "p95_us",
]


def _base_row(**overrides: str) -> dict[str, str]:
    row = {column: "" for column in merge_power_raw_db.RAW_DB_COLUMNS}
    row.update({
        "run_id": "run_main",
        "fpga_bin_label": "naive_simd",
        "exec_key": "main_key",
        "app": "sgemm_tcu",
        "args": "-m 512 -n 128 -k 512",
        "status": "pass",
        "returncode": "0",
        "raw_csv": "/main/raw.csv",
        "log_file": "/main/log.txt",
        "elapsed_wall_s": "1.0",
        "samples": "3",
        "avg_us": "2.0",
    })
    row.update(overrides)
    return row


def _write_csv(path: Path, columns: list[str], rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=columns)
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in columns})


def _read_csv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open(newline="") as fp:
        reader = csv.DictReader(fp)
        return list(reader.fieldnames or []), list(reader)


class MergePowerRawDbTest(unittest.TestCase):
    def test_merges_power_columns_and_normalizes_low_samples(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main_csv = tmp_path / "outputs_main" / "naive_simd" / "raw_db.csv"
            power_csv = tmp_path / "outputs_main_power" / "naive_simd" / "raw_db.csv"
            _write_csv(
                main_csv,
                LEGACY_COLUMNS,
                [
                    _base_row(exec_key="main_valid", app="sgemm_tcu", args="-m 512 -n 128 -k 512"),
                    _base_row(exec_key="main_low", app="tile_weight_w4a16", args="-k 512 -n 128 -t 0"),
                    _base_row(exec_key="main_missing", app="eladd", args="-n 4194304", status="timeout", returncode="124", failure_reason="timeout"),
                ],
            )
            _write_csv(
                power_csv,
                merge_power_raw_db.RAW_DB_COLUMNS,
                [
                    _base_row(
                        exec_key="main_valid",
                        app="sgemm_tcu",
                        args="-m 512 -n 128 -k 512",
                        power_csv="/power/valid.csv",
                        power_summary="/power/valid.summary.csv",
                        measure_latency="0",
                        measure_power="1",
                        power_samples="77",
                        power_elapsed_s="10.0",
                        power_min_w="11.0",
                        power_avg_w="12.0",
                        power_max_w="13.0",
                    ),
                    _base_row(
                        exec_key="main_low",
                        app="tile_weight_w4a16",
                        args="-k 512 -n 128 -t 0",
                        status="fail",
                        failure_reason="power_samples_low",
                        power_csv="/power/low.csv",
                        power_summary="/power/low.summary.csv",
                        measure_latency="0",
                        measure_power="1",
                        power_samples="1",
                        power_elapsed_s="0.1",
                        power_min_w="11.0",
                        power_avg_w="12.0",
                        power_max_w="13.0",
                    ),
                ],
            )

            summaries = merge_power_raw_db.merge_roots(
                main_root=tmp_path / "outputs_main",
                power_root=tmp_path / "outputs_main_power",
                in_place=True,
                backup_suffix=".bak.test",
            )

            self.assertEqual(1, len(summaries))
            self.assertEqual(3, summaries[0].main_rows)
            self.assertEqual(2, summaries[0].matched_rows)
            self.assertEqual(1, summaries[0].missing_rows)
            self.assertEqual(1, summaries[0].low_sample_rows)
            self.assertTrue(main_csv.with_name("raw_db.csv.bak.test").exists())

            header, rows = _read_csv(main_csv)
            by_case = {row["exec_key"]: row for row in rows}
            self.assertEqual(merge_power_raw_db.RAW_DB_COLUMNS, header)
            self.assertEqual("77", by_case["main_valid"]["power_samples"])
            self.assertEqual("12.0", by_case["main_valid"]["power_avg_w"])
            self.assertEqual("1", by_case["main_valid"]["measure_latency"])
            self.assertEqual("1", by_case["main_valid"]["measure_power"])

            self.assertEqual("pass", by_case["main_low"]["status"])
            self.assertEqual("0", by_case["main_low"]["returncode"])
            self.assertEqual("", by_case["main_low"]["failure_reason"])
            self.assertEqual("0", by_case["main_low"]["power_samples"])
            self.assertEqual("", by_case["main_low"]["power_avg_w"])
            self.assertEqual("/power/low.csv", by_case["main_low"]["power_csv"])

            self.assertEqual("timeout", by_case["main_missing"]["status"])
            self.assertEqual("timeout", by_case["main_missing"]["failure_reason"])
            self.assertEqual("0", by_case["main_missing"]["measure_power"])
            self.assertEqual("", by_case["main_missing"]["power_samples"])

    def test_duplicate_power_match_keys_fail_before_writing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            main_csv = tmp_path / "outputs_main" / "naive_simd" / "raw_db.csv"
            power_csv = tmp_path / "outputs_main_power" / "naive_simd" / "raw_db.csv"
            _write_csv(main_csv, LEGACY_COLUMNS, [_base_row()])
            duplicate = _base_row(power_samples="5")
            _write_csv(power_csv, merge_power_raw_db.RAW_DB_COLUMNS, [duplicate, duplicate])

            with self.assertRaises(ValueError):
                merge_power_raw_db.merge_roots(
                    main_root=tmp_path / "outputs_main",
                    power_root=tmp_path / "outputs_main_power",
                    in_place=True,
                    backup_suffix=".bak.test",
                )
            self.assertFalse(main_csv.with_name("raw_db.csv.bak.test").exists())


if __name__ == "__main__":
    unittest.main()
