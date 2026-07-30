from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.canonicalization import load_canonicalization_policies
from tools.latency_bench.migrate_output_schema import (
    CASE_COLUMNS,
    migrate_cases,
    migrate_raw_db,
)
from tools.latency_bench.raw_db import RAW_DB_COLUMNS
from tools.latency_bench.suite import make_exec_key


def _write_csv(path: Path, columns: list[str], rows: list[dict[str, object]]) -> None:
    with path.open("w", newline="") as fp:
        writer = csv.DictWriter(fp, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def _read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as fp:
        return list(csv.DictReader(fp))


class MigrateOutputSchemaTest(unittest.TestCase):
    def test_raw_db_merges_physical_sgemm_shape_and_keeps_passing_row(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "raw_db.csv"
            common = {
                "fpga_bin_label": "C1",
                "xclbin_sha256": "sha",
                "app": "sgemm_tcu",
            }
            _write_csv(path, RAW_DB_COLUMNS, [
                {
                    **common,
                    "run_id": "failed",
                    "args": "-m 8 -n 24 -k 16",
                    "status": "fail",
                    "timestamp_utc": "2026-01-02T00:00:00+00:00",
                },
                {
                    **common,
                    "run_id": "passing",
                    "args": "-m 8 -n 32 -k 32",
                    "status": "pass",
                    "samples": "3",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                },
            ])

            before, after = migrate_raw_db(
                path,
                fpga_bin_label="C1",
                policies=load_canonicalization_policies(),
            )

            self.assertEqual((2, 1), (before, after))
            [row] = _read_csv(path)
            expected_args = "-m 16 -n 32 -k 32"
            self.assertEqual("passing", row["run_id"])
            self.assertEqual(expected_args, row["args"])
            self.assertEqual(expected_args, row["padded_args"])
            self.assertEqual(
                make_exec_key("sha", "sgemm_tcu", expected_args),
                row["exec_key"],
            )

    def test_cases_use_the_same_sgemm_measurement_and_padded_args(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "cases.csv"
            _write_csv(path, CASE_COLUMNS, [{
                "suite": "suite",
                "case_id": "qk",
                "app": "sgemm_tcu",
                "args": "-m 1 -n 17 -k 17",
                "padded_args": "-m 1 -n 24 -k 17",
                "measurement_kind": "measured",
            }])

            rows, changed = migrate_cases(
                path,
                fpga_bin_label="C1",
                xclbin_sha256="sha",
                policies=load_canonicalization_policies(),
            )

            self.assertEqual((1, 1), (rows, changed))
            [row] = _read_csv(path)
            expected_args = "-m 16 -n 32 -k 32"
            self.assertEqual(expected_args, row["measurement_args"])
            self.assertEqual(expected_args, row["padded_args"])
            self.assertEqual(
                make_exec_key("sha", "sgemm_tcu", expected_args),
                row["exec_key"],
            )


if __name__ == "__main__":
    unittest.main()
