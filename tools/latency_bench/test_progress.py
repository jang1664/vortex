from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.progress import append_progress_execution


class ProgressTest(unittest.TestCase):
    def test_appends_progress_row_with_measurements(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_csv = tmp_path / "raw.csv"
            raw_csv.write_text("# comment\nfpint_gemm,3,1.0,2.0,4.0,2.0,3.0\n")
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=2,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="fpint_gemm_ffn_hw",
                args="-m 1 -n 128 -k 128",
                warmup=1,
                iterations=3,
                returncode=0,
                elapsed_wall_s="12.345",
                raw_csv=raw_csv,
                log_file=tmp_path / "bench.log",
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual(1, len(rows))
            self.assertEqual("1", rows[0]["idx"])
            self.assertEqual("2", rows[0]["total"])
            self.assertEqual("pass", rows[0]["status"])
            self.assertEqual("12.345", rows[0]["elapsed_wall_s"])
            self.assertEqual("2.0", rows[0]["p50_us"])
            self.assertEqual("", rows[0]["parse_error"])

    def test_failed_execution_records_parse_error_without_parse_status(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            progress_csv = tmp_path / "progress.csv"

            append_progress_execution(
                output=progress_csv,
                idx=1,
                total=1,
                run_id="run_1",
                suite="suite_a",
                exec_key="exec_a",
                app="app_a",
                args="--bad",
                warmup=0,
                iterations=1,
                returncode=1,
                elapsed_wall_s="0.010",
                raw_csv=tmp_path / "missing.csv",
                log_file=tmp_path / "bench.log",
            )

            with progress_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual("fail", rows[0]["status"])
            self.assertEqual("missing_raw_csv", rows[0]["parse_error"])


if __name__ == "__main__":
    unittest.main()
