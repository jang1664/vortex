from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.append_raw import append_raw_execution


class AppendRawExecutionTest(unittest.TestCase):
    def test_appends_rows_with_header_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_a = tmp_path / "a.csv"
            raw_b = tmp_path / "b.csv"
            out = tmp_path / "aggregate.csv"

            raw_a.write_text("# comment\nlabel_a,10,1.0,2.0,3.0,2.1,2.9\n")
            raw_b.write_text("label_b,20,4.0,5.0,6.0,5.1,5.9\n")

            append_raw_execution(
                output=out,
                suite="suite_a",
                run_id="run_1",
                exec_key="exec_a",
                app="app_a",
                returncode=0,
                raw_csv=raw_a,
                log_file=tmp_path / "a.log",
            )
            append_raw_execution(
                output=out,
                suite="suite_a",
                run_id="run_1",
                exec_key="exec_b",
                app="app_b",
                returncode=0,
                raw_csv=raw_b,
                log_file=tmp_path / "b.log",
            )

            with out.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual(2, len(rows))
            self.assertEqual("exec_a", rows[0]["exec_key"])
            self.assertEqual("label_a", rows[0]["bench_label"])
            self.assertEqual("2.1", rows[0]["p50_us"])
            self.assertEqual("exec_b", rows[1]["exec_key"])
            self.assertEqual("label_b", rows[1]["bench_label"])
            self.assertEqual("", rows[1]["parse_error"])

    def test_records_missing_raw_csv_as_parse_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            out = tmp_path / "aggregate.csv"

            append_raw_execution(
                output=out,
                suite="suite_a",
                run_id="run_1",
                exec_key="exec_a",
                app="app_a",
                returncode=1,
                raw_csv=tmp_path / "missing.csv",
                log_file=tmp_path / "a.log",
            )

            with out.open(newline="") as fp:
                rows = list(csv.DictReader(fp))

            self.assertEqual(1, len(rows))
            self.assertEqual("exec_a", rows[0]["exec_key"])
            self.assertEqual("1", rows[0]["returncode"])
            self.assertEqual("missing_raw_csv", rows[0]["parse_error"])


if __name__ == "__main__":
    unittest.main()
