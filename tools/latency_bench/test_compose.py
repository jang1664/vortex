from __future__ import annotations

import csv
import re
import tempfile
import unittest
from pathlib import Path

import pandas as pd

from tools.latency_bench.compose import (
    ComposeOptions,
    LatencyScaleRule,
    apply_latency_scale_rules,
    compose_latency,
    compose_to_csv,
)
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite


class ComposeTest(unittest.TestCase):
    def _suite(self) -> BenchSuite:
        return BenchSuite(
            name="mini_suite",
            defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="improve_tcol1"),
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
                "fpga_cycle": "100",
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
                "fpga_cycle": "140",
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
                "fpga_cycle": "200",
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
                "fpga_cycle": "1000",
            },
        ]
        with path.open("w", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    def test_compose_uses_median_matches_by_app_args_and_resolved_fpga_bin(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "composed.csv",
                ),
            )

            self.assertEqual(["gemm_a", "gemm_b"], list(composed["case_id"]))
            self.assertEqual([2, 1], list(composed["match_count"]))
            self.assertEqual(12.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(24.0, float(composed.loc[0, "weighted_latency_us"]))
            self.assertEqual(60.0, float(composed.loc[1, "weighted_latency_us"]))
            self.assertEqual("run_old;run_new", composed.loc[0, "source_run_ids"])
            self.assertEqual("improve_tcol1", composed.loc[0, "expected_fpga_bin_label"])
            self.assertEqual("improve_tcol1", composed.loc[0, "source_fpga_bin_labels"])

    def test_compose_accepts_fpga_cycle_metric(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "composed.csv",
                    metric="fpga_cycle",
                ),
            )

            self.assertEqual("fpga_cycle", composed.loc[0, "metric"])
            self.assertEqual(120.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(240.0, float(composed.loc[0, "weighted_latency_us"]))
            self.assertEqual(600.0, float(composed.loc[1, "weighted_latency_us"]))

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

    def test_apply_latency_scale_rules_matches_exact_list_and_regex(self) -> None:
        raw = pd.DataFrame(
            [
                {
                    "app": "sgemm_tcu",
                    "name": "attn_qkT",
                    "variant": "v1",
                    "p50_us": "10",
                    "avg_us": "11",
                    "p95_us": "12",
                    "min_us": "9",
                    "max_us": "13",
                },
                {
                    "app": "fpint_gemm_ffn_hw",
                    "name": "gate_proj",
                    "variant": "v2",
                    "p50_us": "20",
                    "avg_us": "21",
                    "p95_us": "22",
                    "min_us": "19",
                    "max_us": "23",
                },
            ]
        )

        scaled = apply_latency_scale_rules(
            raw,
            (
                LatencyScaleRule("sgemm", {"app": "sgemm_tcu"}, 0.5),
                LatencyScaleRule("attn", {"name": re.compile(r"attn_")}, 0.5),
                {"name": "variant_v2", "condition": {"variant": ["v2", "v3"]}, "scale": 2.0},
            ),
        )

        self.assertEqual(2.5, float(scaled.loc[0, "p50_us"]))
        self.assertEqual(2.75, float(scaled.loc[0, "avg_us"]))
        self.assertEqual(40.0, float(scaled.loc[1, "p50_us"]))
        self.assertEqual("sgemm;attn", scaled.loc[0, "_latency_scale_rules"])
        self.assertEqual("0.25", scaled.loc[0, "_latency_scale_factor"])
        self.assertEqual("variant_v2", scaled.loc[1, "_latency_scale_rules"])

    def test_latency_scale_rules_validate_inputs(self) -> None:
        raw = pd.DataFrame([{"app": "sgemm_tcu", "p50_us": "10"}])

        with self.assertRaisesRegex(ValueError, "missing column"):
            apply_latency_scale_rules(raw, (LatencyScaleRule("missing", {"name": "x"}, 0.5),))
        with self.assertRaisesRegex(ValueError, "positive finite"):
            apply_latency_scale_rules(raw, (LatencyScaleRule("bad", {"app": "sgemm_tcu"}, 0.0),))
        with self.assertRaisesRegex(ValueError, "matcher mapping"):
            apply_latency_scale_rules(raw, (LatencyScaleRule("bad_matcher", {"app": {"glob": "sgemm*"}}, 0.5),))

    def test_compose_applies_latency_scale_before_selection(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "composed.csv",
                    latency_scale_rules=(
                        LatencyScaleRule(
                            "half_m1",
                            {"args": {"regex": r"-m\s+1(?:\s|$)"}},
                            0.5,
                        ),
                    ),
                ),
            )

            self.assertEqual(6.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(12.0, float(composed.loc[0, "weighted_latency_us"]))
            self.assertEqual(60.0, float(composed.loc[1, "weighted_latency_us"]))
            self.assertEqual("half_m1", composed.loc[0, "source_latency_scale_rules"])
            self.assertEqual("0.5", composed.loc[0, "source_latency_scales"])
            self.assertEqual("", composed.loc[1, "source_latency_scale_rules"])
            self.assertEqual("1", composed.loc[1, "source_latency_scales"])

    def test_missing_error_is_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="missing_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="improve_tcol1"),
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

    def test_missing_nan_keeps_expected_fpga_bin_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="missing_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="improve_tcol1"),
                cases=[
                    BenchCase(
                        case_id="missing",
                        app="fpint_gemm_ffn_hw",
                        args="-m 99 -n 128 -k 128 -q 32 -t 0 -d 0",
                    ),
                ],
            )

            composed = compose_latency(
                suite,
                ComposeOptions(raw_dbs=(raw_db,), out=Path(tmp) / "out.csv", missing="nan"),
            )

            self.assertEqual("missing", composed.loc[0, "compose_status"])
            self.assertEqual("improve_tcol1", composed.loc[0, "expected_fpga_bin_label"])
            self.assertEqual("", composed.loc[0, "source_fpga_bin_labels"])

    def test_match_fpga_bin_requires_raw_db_column(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            rows = [
                {
                    "run_id": "run_a",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                    "app": "fpint_gemm_ffn_hw",
                    "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    "status": "pass",
                    "p50_us": "10",
                    "avg_us": "10",
                    "p95_us": "10",
                    "min_us": "10",
                    "max_us": "10",
                }
            ]
            with raw_db.open("w", newline="") as fp:
                writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
                writer.writeheader()
                writer.writerows(rows)

            with self.assertRaisesRegex(ValueError, "fpga_bin_label"):
                compose_latency(self._suite(), ComposeOptions(raw_dbs=(raw_db,), out=tmp_path / "out.csv"))

    def test_match_fpga_bin_can_be_disabled_for_legacy_raw_db(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            rows = [
                {
                    "run_id": "run_a",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                    "app": "fpint_gemm_ffn_hw",
                    "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    "status": "pass",
                    "p50_us": "10",
                    "avg_us": "10",
                    "p95_us": "10",
                    "min_us": "10",
                    "max_us": "10",
                }
            ]
            with raw_db.open("w", newline="") as fp:
                writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
                writer.writeheader()
                writer.writerows(rows)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(raw_dbs=(raw_db,), out=tmp_path / "out.csv", match_fpga_bin=False, missing="skip"),
            )

            self.assertEqual(10.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual("", composed.loc[0, "expected_fpga_bin_label"])

    def test_directory_out_writes_composed_and_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed_csv, summary_csv = compose_to_csv(
                self._suite(),
                ComposeOptions(raw_dbs=(raw_db,), out=tmp_path / "out"),
            )

            self.assertTrue(composed_csv.exists())
            self.assertTrue(summary_csv and summary_csv.exists())
            with summary_csv.open(newline="") as fp:
                rows = list(csv.DictReader(fp))
            self.assertEqual("84.0", rows[0]["total_latency_us"])


if __name__ == "__main__":
    unittest.main()
