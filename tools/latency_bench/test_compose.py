from __future__ import annotations

import csv
import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.compose import ComposeOptions, compose_latency, compose_to_csv
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite


class ComposeTest(unittest.TestCase):
    def _suite(self) -> BenchSuite:
        return BenchSuite(
            name="mini_suite",
            defaults=BenchDefaults(warmup=1, iterations=1),
            cases=[
                BenchCase(
                    case_id="gemm_a",
                    app="fpint_gemm_ffn_hw",
                    args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    kind="fpint_gemm",
                    stage="prefill",
                    name="gemm_a",
                    calls_per_forward=2,
                    warmup=1,
                    iterations=1,
                ),
                BenchCase(
                    case_id="gemm_b",
                    app="fpint_gemm_ffn_hw",
                    args="-m 2 -n 128 -k 128 -q 32 -t 0 -d 0",
                    kind="fpint_gemm",
                    stage="prefill",
                    name="gemm_b",
                    calls_per_forward=3,
                    warmup=1,
                    iterations=1,
                ),
            ],
        )

    def _write_raw_db(self, path: Path) -> None:
        rows = [
            {
                "run_id": "run_old",
                "timestamp_utc": "2026-01-01T00:00:00+00:00",
                "fpga_bin_label": "improve_tcol1",
                "xclbin_sha256": "abc",
                "app": "fpint_gemm_ffn_hw",
                "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                "status": "pass",
                "avg_us": "11",
                "p50_us": "10",
                "p95_us": "12",
                "min_us": "9",
                "max_us": "13",
            },
            {
                "run_id": "run_new",
                "timestamp_utc": "2026-01-02T00:00:00+00:00",
                "fpga_bin_label": "improve_tcol1",
                "xclbin_sha256": "abc",
                "app": "fpint_gemm_ffn_hw",
                "args": "-m 1   -n 128 -k 128 -q 32 -t 0 -d 0",
                "status": "pass",
                "avg_us": "15",
                "p50_us": "14",
                "p95_us": "16",
                "min_us": "13",
                "max_us": "17",
            },
            {
                "run_id": "run_b",
                "timestamp_utc": "2026-01-01T00:00:00+00:00",
                "fpga_bin_label": "improve_tcol1",
                "xclbin_sha256": "abc",
                "app": "fpint_gemm_ffn_hw",
                "args": "-m 2 -n 128 -k 128 -q 32 -t 0 -d 0",
                "status": "pass",
                "avg_us": "20",
                "p50_us": "20",
                "p95_us": "22",
                "min_us": "19",
                "max_us": "23",
            },
            {
                "run_id": "wrong_bin",
                "timestamp_utc": "2026-01-01T00:00:00+00:00",
                "fpga_bin_label": "other",
                "xclbin_sha256": "def",
                "app": "fpint_gemm_ffn_hw",
                "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                "status": "pass",
                "avg_us": "100",
                "p50_us": "100",
                "p95_us": "100",
                "min_us": "100",
                "max_us": "100",
            },
        ]
        with path.open("w", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    def test_compose_uses_median_matches_by_app_and_normalized_args(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "composed.csv",
                    fpga_bin_label="improve_tcol1",
                ),
            )

            self.assertEqual(["gemm_a", "gemm_b"], list(composed["case_id"]))
            self.assertEqual([2, 1], list(composed["match_count"]))
            self.assertEqual(12.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(24.0, float(composed.loc[0, "weighted_latency_us"]))
            self.assertEqual(60.0, float(composed.loc[1, "weighted_latency_us"]))
            self.assertEqual("run_old;run_new", composed.loc[0, "source_run_ids"])

    def test_compose_latest_selects_newest_row(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "composed.csv",
                    select="latest",
                    fpga_bin_label="improve_tcol1",
                ),
            )

            self.assertEqual(14.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual("run_new", composed.loc[0, "selected_run_id"])

    def test_missing_error_is_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="missing_suite",
                defaults=BenchDefaults(warmup=1, iterations=1),
                cases=[
                    BenchCase(
                        case_id="missing",
                        app="fpint_gemm_ffn_hw",
                        args="-m 99 -n 128 -k 128 -q 32 -t 0 -d 0",
                    ),
                ],
            )

            with self.assertRaisesRegex(ValueError, "missing measurements"):
                compose_latency(suite, ComposeOptions(raw_dbs=(raw_db,), out=Path(tmp) / "out.csv"))

    def test_directory_out_writes_composed_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed_csv, summary_csv = compose_to_csv(
                self._suite(),
                ComposeOptions(raw_dbs=(raw_db,), out=tmp_path / "out", fpga_bin_label="improve_tcol1"),
            )

            self.assertTrue(composed_csv.exists())
            self.assertTrue(summary_csv and summary_csv.exists())
            with summary_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual("84.0", rows[0]["total_latency_us"])


if __name__ == "__main__":
    unittest.main()
