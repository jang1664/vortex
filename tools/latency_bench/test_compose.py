from __future__ import annotations

import csv
import re
import tempfile
import unittest
import warnings
from pathlib import Path

import pandas as pd

from tools.latency_bench.compose import (
    ComposeOptions,
    LatencyScaleRule,
    apply_latency_scale_rules,
    compose_latency,
    compose_to_csv,
)
from tools.latency_bench.fpga_clock import resolve_fpga_period_s
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite


class ComposeTest(unittest.TestCase):
    def test_fpga_period_uses_achieved_kernel_frequency(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp)
            (bin_dir / "vortex_afu.xclbin.info").write_text(
                "System Clocks\n"
                "   Name:           ulp_ucs_aclk_kernel_00\n"
                "   Requested Freq: 100 MHz\n"
                "   Achieved Freq:  99.5 MHz\n"
            )

            period_s = resolve_fpga_period_s({"fpga_bin_dir": str(bin_dir)})

            self.assertIsNotNone(period_s)
            self.assertAlmostEqual(1.0 / (99.5 * 1_000_000.0), period_s)

    def _suite(self) -> BenchSuite:
        return BenchSuite(
            name="mini_suite",
            defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="improve_tcol1"),
            cases=[
                BenchCase(
                    case_id="gemm_a",
                    app="fpint_gemm_ffn_hw",
                    args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    model="llama2-7b",
                    kind="fpint_gemm",
                    stage="prefill",
                    name="gemm_a",
                    batch=2,
                    prefill_seq_len=128,
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
                "power_avg_w": "10",
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
                "power_avg_w": "20",
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
        self._write_rows(path, rows)

    def _write_rows(self, path: Path, rows: list[dict[str, str]]) -> None:
        for index, row in enumerate(rows):
            if not row.get("exec_key") and row.get("app") and row.get("args"):
                row["exec_key"] = BenchCase(
                    case_id=f"raw_{index}",
                    app=row["app"],
                    args=row["args"],
                    warmup=int(row.get("warmup", 1)),
                    iterations=int(row.get("iterations", 1)),
                ).exec_key
        with path.open("w", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    def test_compose_matches_by_app_args_and_resolved_fpga_bin(self) -> None:
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
            self.assertEqual([1, 1], list(composed["match_count"]))
            self.assertEqual(14.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(28.0, float(composed.loc[0, "weighted_latency_us"]))
            self.assertEqual(60.0, float(composed.loc[1, "weighted_latency_us"]))
            self.assertEqual("run_new", composed.loc[0, "source_run_ids"])
            self.assertEqual("improve_tcol1", composed.loc[0, "expected_fpga_bin_label"])
            self.assertEqual("improve_tcol1", composed.loc[0, "source_fpga_bin_labels"])
            self.assertEqual("llama2-7b", composed.loc[0, "model"])
            self.assertEqual(2, int(composed.loc[0, "batch"]))
            self.assertEqual(128, int(composed.loc[0, "prefill_seq_len"]))
            self.assertEqual(0, int(composed.loc[0, "gen_kv_len"]))

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
            self.assertEqual(140.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(280.0, float(composed.loc[0, "weighted_latency_us"]))
            self.assertEqual(600.0, float(composed.loc[1, "weighted_latency_us"]))

    def test_compose_records_cycle_derived_latency_in_microseconds(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed = compose_latency(
                self._suite(),
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "composed.csv",
                    metric="fpga_cycle_latency",
                ),
            )

            self.assertEqual("fpga_cycle_latency", composed.loc[0, "metric"])
            self.assertEqual(140.0, float(composed.loc[0, "fpga_cycle"]))
            self.assertAlmostEqual(1.4, float(composed.loc[0, "fpga_cycle_latency"]))
            self.assertAlmostEqual(1.4, float(composed.loc[0, "latency_us"]))
            self.assertAlmostEqual(2.8, float(composed.loc[0, "weighted_latency_us"]))
            self.assertAlmostEqual(10e-9, float(composed.loc[0, "fpga_period_s"]))

    def test_fully_expanded_decode_uses_one_logical_row_per_token(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="decode_suite",
                defaults=BenchDefaults(
                    warmup=1, iterations=1, fpga_bin="improve_tcol1",
                ),
                cases=[
                    BenchCase(
                        case_id="decode_gemm",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        stage="generation",
                        calls_per_forward=2,
                        out_tokens=3,
                        warmup=1,
                        iterations=1,
                    ),
                ],
            )

            composed = compose_latency(
                suite,
                ComposeOptions(raw_dbs=(raw_db,), out=Path(tmp) / "out.csv"),
            )

            self.assertEqual(2.0, float(composed.loc[0, "calls_per_forward"]))
            self.assertEqual(2.0, float(composed.loc[0, "effective_calls"]))
            self.assertEqual(28.0, float(composed.loc[0, "weighted_latency_us"]))

    def test_fully_expanded_decode_interpolates_each_logical_row(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="sampled_decode",
                defaults=BenchDefaults(
                    warmup=1, iterations=1, fpga_bin="improve_tcol1",
                ),
                cases=[
                    BenchCase(
                        case_id="decode_first",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        stage="generation",
                        name="decode_kernel",
                        calls_per_forward=2,
                        output_token_index=1,
                        out_tokens=3,
                        shape={
                            "decode_sampling_class": "continuous",
                            "logical_cache_length": 101,
                        },
                        warmup=1,
                        iterations=1,
                    ),
                    BenchCase(
                        case_id="decode_middle",
                        app="fpint_gemm_ffn_hw",
                        args="-m 3 -n 128 -k 128 -q 32 -t 0 -d 0",
                        stage="generation",
                        name="decode_kernel",
                        calls_per_forward=2,
                        output_token_index=2,
                        out_tokens=3,
                        measurement_kind="interpolated",
                        shape={
                            "decode_sampling_class": "continuous",
                            "logical_cache_length": 102,
                        },
                        warmup=1,
                        iterations=1,
                    ),
                    BenchCase(
                        case_id="decode_last",
                        app="fpint_gemm_ffn_hw",
                        args="-m 2 -n 128 -k 128 -q 32 -t 0 -d 0",
                        stage="generation",
                        name="decode_kernel",
                        calls_per_forward=2,
                        output_token_index=3,
                        out_tokens=3,
                        shape={
                            "decode_sampling_class": "continuous",
                            "logical_cache_length": 103,
                        },
                        warmup=1,
                        iterations=1,
                    ),
                ],
            )
            composed = compose_latency(
                suite,
                ComposeOptions(raw_dbs=(raw_db,), out=Path(tmp) / "out.csv"),
            )
            self.assertEqual(3, len(composed))
            middle = composed.loc[composed["case_id"] == "decode_middle"].iloc[0]
            self.assertEqual(17.0, float(middle["latency_us"]))
            self.assertEqual(2.0, float(middle["effective_calls"]))
            self.assertEqual(34.0, float(middle["weighted_latency_us"]))
            self.assertEqual("interpolated", middle["latency_resolution_kind"])
            self.assertEqual("estimated", middle["compose_status"])
            self.assertEqual(15.0, float(middle["power_avg_w"]))
            self.assertEqual("interpolated", middle["power_resolution_kind"])

    def test_decode_reuse_resolves_varying_logical_args_from_representative(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="sampled_invariant_decode",
                defaults=BenchDefaults(
                    warmup=1, iterations=1, fpga_bin="improve_tcol1",
                ),
                cases=[
                    BenchCase(
                        case_id="rope_first",
                        app="fpint_gemm_ffn_hw",
                        args="-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                        stage="generation",
                        name="rope_q",
                        calls_per_forward=2,
                        output_token_index=1,
                        out_tokens=2,
                        shape={
                            "decode_sampling_class": "invariant",
                            "logical_cache_length": 101,
                            "maxseq": 101,
                            "offset": 100,
                        },
                        warmup=1,
                        iterations=1,
                    ),
                    BenchCase(
                        case_id="rope_second",
                        app="fpint_gemm_ffn_hw",
                        args="-m 9 -n 128 -k 128 -q 32 -t 0 -d 0",
                        stage="generation",
                        name="rope_q",
                        calls_per_forward=2,
                        output_token_index=2,
                        out_tokens=2,
                        measurement_kind="invariant_reused",
                        shape={
                            "decode_sampling_class": "invariant",
                            "logical_cache_length": 102,
                            "maxseq": 102,
                            "offset": 101,
                            "reuse_representative_step": 1,
                        },
                        warmup=1,
                        iterations=1,
                    ),
                ],
            )

            composed = compose_latency(
                suite,
                ComposeOptions(raw_dbs=(raw_db,), out=Path(tmp) / "out.csv"),
            )

            reused = composed.loc[composed["case_id"] == "rope_second"].iloc[0]
            self.assertEqual("pass", reused["compose_status"])
            self.assertEqual(14.0, float(reused["latency_us"]))
            self.assertEqual(28.0, float(reused["weighted_latency_us"]))
            self.assertEqual("invariant_reused", reused["latency_resolution_kind"])
            self.assertEqual(
                "rope_first", reused["latency_reuse_representative_case_id"]
            )
            self.assertEqual(10.0, float(reused["power_avg_w"]))
            self.assertEqual("invariant_reused", reused["power_resolution_kind"])
            self.assertEqual(
                "rope_first", reused["power_reuse_representative_case_id"]
            )

    def test_decode_reuse_identifies_missing_representative(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            suite = BenchSuite(
                name="missing_invariant_representative",
                defaults=BenchDefaults(
                    warmup=1, iterations=1, fpga_bin="improve_tcol1",
                ),
                cases=[
                    BenchCase(
                        case_id="missing_anchor",
                        app="unmeasured_kernel",
                        args="-n 1",
                        stage="generation",
                        name="invariant_kernel",
                        output_token_index=1,
                        out_tokens=2,
                        shape={"decode_sampling_class": "invariant"},
                        warmup=1,
                        iterations=1,
                    ),
                    BenchCase(
                        case_id="missing_reuse",
                        app="unmeasured_kernel",
                        args="-n 2",
                        stage="generation",
                        name="invariant_kernel",
                        output_token_index=2,
                        out_tokens=2,
                        measurement_kind="invariant_reused",
                        shape={
                            "decode_sampling_class": "invariant",
                            "reuse_representative_step": 1,
                        },
                        warmup=1,
                        iterations=1,
                    ),
                ],
            )

            composed = compose_latency(
                suite,
                ComposeOptions(
                    raw_dbs=(raw_db,),
                    out=Path(tmp) / "out.csv",
                    missing="nan",
                ),
            )

            reused = composed.loc[composed["case_id"] == "missing_reuse"].iloc[0]
            self.assertEqual("missing", reused["compose_status"])
            self.assertEqual(
                "missing_anchor", reused["latency_reuse_representative_case_id"]
            )
            self.assertEqual(
                "missing_anchor", reused["power_reuse_representative_case_id"]
            )

    def test_compose_filters_non_pass_and_dedupes_latest_with_warnings(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            rows = [
                {
                    "run_id": "run_old",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                    "fpga_bin_label": "improve_tcol1",
                    "xclbin_sha256": "abc",
                    "app": "fpint_gemm_ffn_hw",
                    "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    "exec_key": self._suite().cases[0].exec_key,
                    "status": "pass",
                    "avg_us": "11",
                    "p50_us": "10",
                    "p95_us": "12",
                    "min_us": "9",
                    "max_us": "13",
                    "fpga_cycle": "100",
                },
                {
                    "run_id": "run_timeout",
                    "timestamp_utc": "2026-01-03T00:00:00+00:00",
                    "fpga_bin_label": "improve_tcol1",
                    "xclbin_sha256": "abc",
                    "app": "fpint_gemm_ffn_hw",
                    "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    "status": "timeout",
                    "avg_us": "",
                    "p50_us": "",
                    "p95_us": "",
                    "min_us": "",
                    "max_us": "",
                    "fpga_cycle": "",
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
            ]
            self._write_rows(raw_db, rows)

            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always", RuntimeWarning)
                composed = compose_latency(
                    self._suite(),
                    ComposeOptions(
                        raw_dbs=(raw_db,),
                        out=Path(tmp) / "composed.csv",
                        select="median",
                    ),
                )

            messages = [str(item.message) for item in caught if issubclass(item.category, RuntimeWarning)]
            self.assertTrue(any("filtered out 1 raw DB row(s) with status != 'pass'" in message for message in messages))
            self.assertTrue(any("duplicate raw DB row(s)" in message and "using the most recent row" in message for message in messages))
            self.assertEqual(14.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(1, int(composed.loc[0, "match_count"]))
            self.assertEqual("run_new", composed.loc[0, "source_run_ids"])
            self.assertEqual("run_new", composed.loc[0, "selected_run_id"])

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

            self.assertEqual(7.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual(14.0, float(composed.loc[0, "weighted_latency_us"]))
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
                    "xclbin_sha256": "abc",
                    "app": "fpint_gemm_ffn_hw",
                    "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    "exec_key": self._suite().cases[0].exec_key,
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

    def test_match_fpga_bin_can_be_disabled(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            rows = [
                {
                    "run_id": "run_a",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                    "xclbin_sha256": "abc",
                    "app": "fpint_gemm_ffn_hw",
                    "args": "-m 1 -n 128 -k 128 -q 32 -t 0 -d 0",
                    "exec_key": self._suite().cases[0].exec_key,
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

    def test_compose_requires_nonempty_xclbin_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            self._write_raw_db(raw_db)
            frame = pd.read_csv(raw_db)
            frame.loc[0, "xclbin_sha256"] = ""
            frame.to_csv(raw_db, index=False)

            with self.assertRaisesRegex(ValueError, "missing xclbin_sha256"):
                compose_latency(
                    self._suite(),
                    ComposeOptions(raw_dbs=(raw_db,), out=Path(tmp) / "out.csv"),
                )

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
            self.assertEqual("88.0", rows[0]["total_latency_us"])


if __name__ == "__main__":
    unittest.main()
