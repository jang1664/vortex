from __future__ import annotations

import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import pandas as pd

from tools.latency_bench.cli import main
from tools.latency_bench import plot as plot_module
from tools.latency_bench.compose import LatencyScaleRule
from tools.latency_bench.estimate import LatencyEstimateOptions
from tools.latency_bench.plot import (
    SuiteBarPlotOptions,
    _apply_relative_values,
    _bar_width_and_offsets,
    _derive_seq_len,
    _nonzero_bar_segments,
    _ordered_values,
    _relative_baselines,
    _relative_group_axes,
    _subplot_title,
    _stack_color,
    plot_suite_bar_grid,
    prepare_suite_bar_data,
    visualize_suites,
)
from tools.latency_bench.suite import BenchCase, BenchDefaults, BenchSuite, load_suite


class SuiteBarPlotTest(unittest.TestCase):
    def _suite(self) -> BenchSuite:
        return BenchSuite(
            name="plot_suite",
            defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="plot_bin"),
            cases=[
                BenchCase(
                    case_id="llama2_batch1_prefill_seq_len8_v1_attn",
                    app="sgemm_tcu",
                    args="-m 8 -n 8 -k 128",
                    kind="gemm",
                    stage="prefill",
                    name="attn_qkT",
                    variant="v1",
                    calls_per_forward=2,
                    warmup=1,
                    iterations=1,
                    shape={"batch": 1, "seq": 8},
                ),
                BenchCase(
                    case_id="llama2_batch1_prefill_seq_len8_v1_ffn",
                    app="fpint_gemm_ffn_hw",
                    args="-m 8 -n 4096 -k 4096",
                    kind="gemm",
                    stage="prefill",
                    name="gate_proj",
                    variant="v1",
                    calls_per_forward=3,
                    warmup=1,
                    iterations=1,
                    shape={"batch": 1, "seq": 8},
                ),
            ],
        )

    def _suite_with_vector_case(self) -> BenchSuite:
        suite = self._suite()
        return BenchSuite(
            name=suite.name,
            defaults=suite.defaults,
            cases=[
                *suite.cases,
                BenchCase(
                    case_id="llama2_batch1_prefill_seq_len8_v1_softmax",
                    app="softmax",
                    args="-batch 1 -heads 32 -seqq 8 -seqk 8 -mask 1",
                    kind="softmax",
                    stage="prefill",
                    name="attn_softmax",
                    variant="v1",
                    calls_per_forward=1,
                    warmup=1,
                    iterations=1,
                    shape={"batch": 1, "seq": 8},
                ),
            ],
        )

    def _write_raw_db(self, path: Path) -> None:
        rows = [
            {
                "run_id": "run_a",
                "timestamp_utc": "2026-01-01T00:00:00+00:00",
                "fpga_bin_label": "plot_bin",
                "app": "sgemm_tcu",
                "args": "-m 8 -n 8 -k 128",
                "status": "pass",
                "p50_us": "10",
                "avg_us": "11",
                "p95_us": "12",
                "min_us": "9",
                "max_us": "13",
            },
            {
                "run_id": "run_a",
                "timestamp_utc": "2026-01-01T00:00:00+00:00",
                "fpga_bin_label": "plot_bin",
                "app": "fpint_gemm_ffn_hw",
                "args": "-m 8 -n 4096 -k 4096",
                "status": "pass",
                "p50_us": "20",
                "avg_us": "21",
                "p95_us": "22",
                "min_us": "19",
                "max_us": "23",
            },
        ]
        with path.open("w", newline="") as fp:
            writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)

    def _suite_with_missing_estimate_case(self) -> BenchSuite:
        return BenchSuite(
            name="plot_estimate_suite",
            defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="plot_bin"),
            cases=[
                BenchCase(
                    case_id="llama2_batch1_prefill_seq_len8_v1_attn",
                    app="sgemm_tcu",
                    args="-m 8 -n 8 -k 128",
                    kind="gemm",
                    stage="prefill",
                    name="attn_qkT",
                    variant="v1",
                    calls_per_forward=2,
                    warmup=1,
                    iterations=1,
                    shape={"batch": 1, "seq": 8},
                ),
                BenchCase(
                    case_id="llama2_batch1_prefill_seq_len16_v1_attn",
                    app="sgemm_tcu",
                    args="-m 16 -n 8 -k 128",
                    kind="gemm",
                    stage="prefill",
                    name="attn_qkT",
                    variant="v1",
                    calls_per_forward=2,
                    warmup=1,
                    iterations=1,
                    shape={"batch": 1, "seq": 16},
                ),
            ],
        )

    def test_prepare_extracts_axes_and_sums_weighted_latency(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed, plot_data, stack_data = prepare_suite_bar_data(
                [self._suite()],
                SuiteBarPlotOptions(raw_dbs=(raw_db,), out_dir=tmp_path / "figures"),
            )

            self.assertEqual([1, 1], list(composed["batch"]))
            self.assertEqual([8, 8], list(composed["seq_len"]))
            self.assertEqual(1, len(plot_data))
            self.assertEqual("prefill", plot_data.loc[0, "stage"])
            self.assertEqual("v1", plot_data.loc[0, "variant"])
            self.assertEqual(80.0, float(plot_data.loc[0, "total_latency_us"]))
            self.assertEqual(0, int(plot_data.loc[0, "missing_case_count"]))
            self.assertEqual("plot_bin", plot_data.loc[0, "expected_fpga_bin_labels"])
            self.assertEqual("plot_bin", plot_data.loc[0, "source_fpga_bin_labels"])
            self.assertEqual(["attn_qkT", "gate_proj"], sorted(stack_data["stack_key"].tolist()))
            by_stack = {
                row["stack_key"]: float(row["total_latency_us"])
                for _, row in stack_data.iterrows()
            }
            self.assertEqual(20.0, by_stack["attn_qkT"])
            self.assertEqual(60.0, by_stack["gate_proj"])
            self.assertEqual({"plot_bin"}, set(stack_data["expected_fpga_bin_labels"]))
            self.assertEqual({"plot_bin"}, set(stack_data["source_fpga_bin_labels"]))

    def test_duplicate_suite_inputs_are_counted_once(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            _, plot_data, stack_data = prepare_suite_bar_data(
                [self._suite(), self._suite()],
                SuiteBarPlotOptions(raw_dbs=(raw_db,), out_dir=tmp_path / "figures"),
            )

            self.assertEqual(1, len(plot_data))
            self.assertEqual(80.0, float(plot_data.loc[0, "total_latency_us"]))
            self.assertEqual(2, int(plot_data.loc[0, "case_count"]))
            self.assertEqual(2, len(stack_data))

    def test_prepare_suite_bar_data_can_filter_rows_by_kind(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed, plot_data, stack_data = prepare_suite_bar_data(
                [self._suite_with_vector_case()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=tmp_path / "figures",
                    row_filters=(lambda df: df["kind"].eq("gemm"),),
                ),
            )

            self.assertEqual({"gemm"}, set(composed["kind"]))
            self.assertEqual(2, len(composed))
            self.assertEqual(80.0, float(plot_data.loc[0, "total_latency_us"]))
            self.assertEqual(["attn_qkT", "gate_proj"], sorted(stack_data["stack_key"].tolist()))

    def test_prepare_suite_bar_data_can_filter_rows_by_derived_axis(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed, plot_data, _ = prepare_suite_bar_data(
                [self._suite_with_missing_estimate_case()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=tmp_path / "figures",
                    row_filters=(lambda df: df["seq_len"].eq(8),),
                ),
            )

            self.assertEqual([8], sorted(composed["seq_len"].unique().tolist()))
            self.assertEqual(1, len(composed))
            self.assertEqual(20.0, float(plot_data.loc[0, "total_latency_us"]))

    def test_prepare_suite_bar_data_rejects_empty_row_filter(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            with self.assertRaisesRegex(ValueError, "matched no composed rows"):
                prepare_suite_bar_data(
                    [self._suite()],
                    SuiteBarPlotOptions(
                        raw_dbs=(raw_db,),
                        out_dir=tmp_path / "figures",
                        row_filters=(lambda df: df["kind"].eq("missing"),),
                    ),
                )

    def test_prepare_suite_bar_data_rejects_bad_row_filter_mask_length(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            with self.assertRaisesRegex(ValueError, "returned 1 rows for 2 composed rows"):
                prepare_suite_bar_data(
                    [self._suite()],
                    SuiteBarPlotOptions(
                        raw_dbs=(raw_db,),
                        out_dir=tmp_path / "figures",
                        row_filters=(lambda df: [True],),
                    ),
                )

    def test_prepare_uses_scaled_latency_when_rules_are_set(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            composed, plot_data, stack_data = prepare_suite_bar_data(
                [self._suite()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=tmp_path / "figures",
                    latency_scale_rules=(LatencyScaleRule("half_tcu", {"app": "sgemm_tcu"}, 0.5),),
                ),
            )

            self.assertEqual(5.0, float(composed.loc[0, "latency_us"]))
            self.assertEqual("half_tcu", composed.loc[0, "source_latency_scale_rules"])
            self.assertEqual("0.5", composed.loc[0, "source_latency_scales"])
            self.assertEqual(70.0, float(plot_data.loc[0, "total_latency_us"]))
            self.assertIn("source_latency_scale_rules", plot_data.columns)
            by_stack = {
                row["stack_key"]: float(row["total_latency_us"])
                for _, row in stack_data.iterrows()
            }
            self.assertEqual(10.0, by_stack["attn_qkT"])
            self.assertEqual(60.0, by_stack["gate_proj"])

    def test_case_latency_scale_rules_use_composed_case_variant_after_raw_match(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            rows = [
                {
                    "run_id": "run_shared",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                    "fpga_bin_label": "plot_bin",
                    "app": "shared_gemm",
                    "kind": "gemm",
                    "variant": "C1",
                    "args": "-m 8 -n 8 -k 128",
                    "status": "pass",
                    "p50_us": "10",
                    "avg_us": "10",
                    "p95_us": "10",
                    "min_us": "10",
                    "max_us": "10",
                },
                {
                    "run_id": "run_softmax",
                    "timestamp_utc": "2026-01-01T00:00:00+00:00",
                    "fpga_bin_label": "plot_bin",
                    "app": "softmax",
                    "kind": "softmax",
                    "variant": "C1",
                    "args": "-size 8",
                    "status": "pass",
                    "p50_us": "7",
                    "avg_us": "7",
                    "p95_us": "7",
                    "min_us": "7",
                    "max_us": "7",
                },
            ]
            with raw_db.open("w", newline="") as fp:
                writer = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
                writer.writeheader()
                writer.writerows(rows)

            suite = BenchSuite(
                name="shared_variant_suite",
                defaults=BenchDefaults(warmup=1, iterations=1, fpga_bin="plot_bin"),
                cases=[
                    BenchCase(
                        case_id="c1_gemm",
                        app="shared_gemm",
                        args="-m 8 -n 8 -k 128",
                        kind="gemm",
                        stage="prefill",
                        name="shared_gemm",
                        variant="C1",
                        calls_per_forward=1,
                        warmup=1,
                        iterations=1,
                        shape={"batch": 1, "seq": 8},
                    ),
                    BenchCase(
                        case_id="c2_gemm",
                        app="shared_gemm",
                        args="-m 8 -n 8 -k 128",
                        kind="gemm",
                        stage="prefill",
                        name="shared_gemm",
                        variant="C2",
                        calls_per_forward=2,
                        warmup=1,
                        iterations=1,
                        shape={"batch": 1, "seq": 8},
                    ),
                    BenchCase(
                        case_id="c2_softmax",
                        app="softmax",
                        args="-size 8",
                        kind="softmax",
                        stage="prefill",
                        name="attn_softmax",
                        variant="C2",
                        calls_per_forward=3,
                        warmup=1,
                        iterations=1,
                        shape={"batch": 1, "seq": 8},
                    ),
                ],
            )
            scale_rules = (
                LatencyScaleRule("C2_gemm_area_norm", {"kind": "gemm", "variant": "C2"}, 2.29),
            )

            composed, plot_data, stack_data = prepare_suite_bar_data(
                [suite],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=tmp_path / "figures",
                    case_latency_scale_rules=scale_rules,
                ),
            )

            by_case = {row["case_id"]: row for _, row in composed.iterrows()}
            self.assertEqual(10.0, float(by_case["c1_gemm"]["latency_us"]))
            self.assertEqual("", by_case["c1_gemm"]["case_latency_scale_rules"])
            self.assertAlmostEqual(22.9, float(by_case["c2_gemm"]["latency_us"]), places=6)
            self.assertAlmostEqual(45.8, float(by_case["c2_gemm"]["weighted_latency_us"]), places=6)
            self.assertEqual("C2_gemm_area_norm", by_case["c2_gemm"]["case_latency_scale_rules"])
            self.assertEqual("2.29", by_case["c2_gemm"]["case_latency_scales"])
            self.assertEqual(7.0, float(by_case["c2_softmax"]["latency_us"]))
            self.assertEqual("", by_case["c2_softmax"]["case_latency_scale_rules"])

            totals_by_variant = {
                row["variant"]: float(row["total_latency_us"])
                for _, row in plot_data.iterrows()
            }
            self.assertEqual(10.0, totals_by_variant["C1"])
            self.assertAlmostEqual(66.8, totals_by_variant["C2"], places=6)
            self.assertIn("case_latency_scale_rules", plot_data.columns)
            self.assertIn("case_latency_scale_rules", stack_data.columns)

            out_dir = tmp_path / "figures"
            visualize_suites(
                [suite],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    case_latency_scale_rules=scale_rules,
                ),
            )
            scaled_plot = pd.read_csv(out_dir / "plot_data_scaled.csv")
            scaled_stack = pd.read_csv(out_dir / "plot_stack_data_scaled.csv")
            self.assertIn("case_latency_scale_rules", scaled_plot.columns)
            self.assertIn("case_latency_scale_rules", scaled_stack.columns)

    def test_visualize_suites_writes_csvs_and_figures(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            with patch("tools.latency_bench.plot.plt.subplots", wraps=plot_module.plt.subplots) as subplots:
                visualize_suites(
                    [self._suite()],
                    SuiteBarPlotOptions(raw_dbs=(raw_db,), out_dir=out_dir),
                )

            self.assertTrue((out_dir / "composed_cases.csv").exists())
            self.assertTrue((out_dir / "plot_data.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data.csv").exists())
            self.assertTrue((out_dir / "plot_data_wide.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data_wide.csv").exists())
            self.assertFalse((out_dir / "composed_cases_scaled.csv").exists())
            self.assertFalse((out_dir / "plot_data_scaled.csv").exists())
            self.assertFalse((out_dir / "plot_stack_data_scaled.csv").exists())
            self.assertFalse((out_dir / "plot_data_wide_scaled.csv").exists())
            self.assertFalse((out_dir / "plot_stack_data_wide_scaled.csv").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.png").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.pdf").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.svg").exists())
            self.assertFalse(subplots.call_args.kwargs["sharey"])

            plot_wide = pd.read_csv(out_dir / "plot_data_wide.csv")
            stack_wide = pd.read_csv(out_dir / "plot_stack_data_wide.csv")
            self.assertEqual(80.0, float(plot_wide.loc[0, "v1"]))
            self.assertEqual(20.0, float(stack_wide.loc[0, "attn_qkT"]))
            self.assertEqual(60.0, float(stack_wide.loc[0, "gate_proj"]))

    def test_title_right_legend_position_generates_plot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            visualize_suites(
                [self._suite()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    stacked=False,
                    legend_position="title_right",
                    legend_ncol=2,
                    figure_title="E2E latency",
                ),
            )

            self.assertTrue((out_dir / "bar_total_p50_us.png").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.pdf").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.svg").exists())

    def test_title_right_legend_uses_visible_frame(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "figures"
            plot_data = pd.DataFrame(
                [
                    {
                        "stage": "prefill",
                        "batch": 1,
                        "seq_len": 32,
                        "variant": variant,
                        "total_latency_us": 1.0,
                        "case_count": 1,
                        "pass_case_count": 1,
                        "missing_case_count": 0,
                    }
                    for variant in ("C1", "C2")
                ]
            )

            plot_module.plt.close("all")
            with patch("tools.latency_bench.plot.plt.close"):
                plot_suite_bar_grid(
                    plot_data,
                    pd.DataFrame(),
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=out_dir,
                        stacked=False,
                        legend_position="title_right",
                        legend_ncol=2,
                        value_labels=False,
                    ),
                )
                legends = plot_module.plt.gcf().legends
                self.assertEqual(1, len(legends))
                self.assertTrue(legends[0].get_frame().get_visible())
            plot_module.plt.close("all")

    def test_visualize_suites_writes_unscaled_and_scaled_csvs_when_rules_are_set(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            visualize_suites(
                [self._suite()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    latency_scale_rules=(LatencyScaleRule("half_tcu", {"app": "sgemm_tcu"}, 0.5),),
                ),
            )

            self.assertTrue((out_dir / "composed_cases.csv").exists())
            self.assertTrue((out_dir / "plot_data.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data.csv").exists())
            self.assertTrue((out_dir / "composed_cases_scaled.csv").exists())
            self.assertTrue((out_dir / "plot_data_scaled.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data_scaled.csv").exists())
            self.assertTrue((out_dir / "plot_data_wide.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data_wide.csv").exists())
            self.assertTrue((out_dir / "plot_data_wide_scaled.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data_wide_scaled.csv").exists())

            unscaled_plot = pd.read_csv(out_dir / "plot_data.csv")
            scaled_plot = pd.read_csv(out_dir / "plot_data_scaled.csv")
            scaled_plot_wide = pd.read_csv(out_dir / "plot_data_wide_scaled.csv")
            self.assertEqual(80.0, float(unscaled_plot.loc[0, "total_latency_us"]))
            self.assertEqual(70.0, float(scaled_plot.loc[0, "total_latency_us"]))
            self.assertEqual(70.0, float(scaled_plot_wide.loc[0, "v1"]))
            self.assertIn("source_latency_scale_rules", scaled_plot.columns)

    def test_visualize_suites_writes_estimated_csvs_when_estimator_is_set(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            visualize_suites(
                [self._suite_with_missing_estimate_case()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    latency_estimate=LatencyEstimateOptions(min_train_rows=3, warn_extrapolation=False),
                ),
            )

            self.assertTrue((out_dir / "composed_cases.csv").exists())
            self.assertTrue((out_dir / "plot_data.csv").exists())
            self.assertTrue((out_dir / "composed_cases_estimated.csv").exists())
            self.assertTrue((out_dir / "plot_data_estimated.csv").exists())
            self.assertTrue((out_dir / "plot_data_wide_estimated.csv").exists())
            self.assertTrue((out_dir / "plot_stack_data_wide_estimated.csv").exists())
            self.assertFalse((out_dir / "plot_data_scaled_estimated.csv").exists())

            base_plot = pd.read_csv(out_dir / "plot_data.csv")
            estimated_plot = pd.read_csv(out_dir / "plot_data_estimated.csv")
            estimated_wide = pd.read_csv(out_dir / "plot_data_wide_estimated.csv")
            estimated_cases = pd.read_csv(out_dir / "composed_cases_estimated.csv")
            self.assertEqual(20.0, float(base_plot["total_latency_us"].sum()))
            self.assertEqual(60.0, float(estimated_plot["total_latency_us"].sum()))
            self.assertEqual(60.0, float(estimated_wide["v1"].sum()))
            self.assertEqual(1, int(estimated_plot["estimated_case_count"].sum()))
            self.assertEqual(0, int(estimated_plot["missing_case_count"].sum()))
            self.assertIn("estimate_model", estimated_plot.columns)
            self.assertEqual("estimated", estimated_cases.loc[1, "compose_status"])

    def test_visualize_suites_estimates_missing_case_from_sample_csv_fixture(self) -> None:
        fixture_dir = Path(__file__).resolve().parent / "testdata"
        suite = load_suite(
            fixture_dir / "estimate_suite.yaml",
            repo_root=Path(__file__).resolve().parents[2],
        )

        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "figures"
            visualize_suites(
                [suite],
                SuiteBarPlotOptions(
                    raw_dbs=(fixture_dir / "estimate_raw_db.csv",),
                    out_dir=out_dir,
                    latency_estimate=LatencyEstimateOptions(min_train_rows=3, warn_extrapolation=False),
                ),
            )

            base_plot = pd.read_csv(out_dir / "plot_data.csv")
            estimated_plot = pd.read_csv(out_dir / "plot_data_estimated.csv")
            estimated_cases = pd.read_csv(out_dir / "composed_cases_estimated.csv")
            target = estimated_cases[estimated_cases["case_id"] == "estimate_prefill_b1_s64_attn"].iloc[0]

            self.assertEqual(1, int(base_plot["missing_case_count"].sum()))
            self.assertEqual(0, int(estimated_plot["missing_case_count"].sum()))
            self.assertEqual(1, int(estimated_plot["estimated_case_count"].sum()))
            self.assertEqual("estimated", target["compose_status"])
            self.assertEqual("auto_shape:linear_1d", target["estimate_model"])
            self.assertAlmostEqual(80.0, float(target["latency_us"]), places=6)
            self.assertEqual("extrapolation", target["estimate_mode"])
            self.assertEqual(3, int(target["estimate_train_rows"]))
            self.assertGreater(float(target["latency_us"]), 0.0)
            self.assertGreater(
                float(estimated_plot["total_latency_us"].sum()),
                float(base_plot["total_latency_us"].sum()),
            )

    def test_visualize_suites_writes_scaled_estimated_csvs_when_both_are_set(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            visualize_suites(
                [self._suite_with_missing_estimate_case()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    latency_scale_rules=(LatencyScaleRule("half_tcu", {"app": "sgemm_tcu"}, 0.5),),
                    latency_estimate=LatencyEstimateOptions(min_train_rows=3, warn_extrapolation=False),
                ),
            )

            self.assertTrue((out_dir / "plot_data.csv").exists())
            self.assertTrue((out_dir / "plot_data_scaled.csv").exists())
            self.assertTrue((out_dir / "plot_data_estimated.csv").exists())
            self.assertTrue((out_dir / "plot_data_scaled_estimated.csv").exists())

            scaled_estimated = pd.read_csv(out_dir / "plot_data_scaled_estimated.csv")
            self.assertEqual(30.0, float(scaled_estimated["total_latency_us"].sum()))
            self.assertEqual(1, int(scaled_estimated["estimated_case_count"].sum()))

    def test_visualize_suites_can_share_y_axis(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            self._write_raw_db(raw_db)

            with patch("tools.latency_bench.plot.plt.subplots", wraps=plot_module.plt.subplots) as subplots:
                visualize_suites(
                    [self._suite()],
                    SuiteBarPlotOptions(raw_dbs=(raw_db,), out_dir=tmp_path / "figures", share_y=True),
                )

            self.assertTrue(subplots.call_args.kwargs["sharey"])

    def test_bar_grid_can_share_y_axis_by_row(self) -> None:
        plot_data = pd.DataFrame(
            [
                {
                    "stage": stage,
                    "batch": batch,
                    "seq_len": 512,
                    "variant": "C1",
                    "total_latency_us": value,
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
                for stage, batch, value in (
                    ("prefill", 1, 1.0),
                    ("prefill", 2, 3.0),
                    ("generation", 1, 10.0),
                    ("generation", 2, 30.0),
                )
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plot_module.plt.close("all")
            with patch("tools.latency_bench.plot.plt.close"):
                plot_suite_bar_grid(
                    plot_data,
                    pd.DataFrame(),
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=Path(tmp) / "figures",
                        stacked=False,
                        value_labels=False,
                        legend_position="none",
                        share_y_scope="row",
                    ),
                )
                axes = plot_module.plt.gcf().axes
                self.assertEqual(4, len(axes))
                self.assertEqual(axes[0].get_ylim(), axes[1].get_ylim())
                self.assertEqual(axes[2].get_ylim(), axes[3].get_ylim())
                self.assertNotEqual(axes[0].get_ylim(), axes[2].get_ylim())
                self.assertGreater(axes[2].get_ylim()[1], axes[0].get_ylim()[1])
                self.assertTrue(any(label.get_visible() for label in axes[0].get_yticklabels()))
                self.assertFalse(any(label.get_visible() for label in axes[1].get_yticklabels()))
            plot_module.plt.close("all")

    def test_relative_bar_plot_labels_y_axis_only_on_first_column(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            plot_data = pd.DataFrame(
                [
                    {
                        "stage": "prefill",
                        "batch": batch,
                        "seq_len": 32,
                        "variant": "C1",
                        "total_latency_us": float(batch),
                        "case_count": 1,
                        "pass_case_count": 1,
                        "missing_case_count": 0,
                    }
                    for batch in (1, 2)
                ]
            )

            plot_module.plt.close("all")
            with patch("tools.latency_bench.plot.plt.close"):
                plot_suite_bar_grid(
                    plot_data,
                    pd.DataFrame(),
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=Path(tmp) / "figures",
                        stacked=False,
                        relative=True,
                        relative_scope="x_tick",
                        legend_position="none",
                        value_labels=False,
                    ),
                )
                axes = plot_module.plt.gcf().axes
                self.assertEqual(["relative latency", ""], [ax.get_ylabel() for ax in axes])
            plot_module.plt.close("all")

    def test_bar_grid_can_use_one_shared_x_axis_label(self) -> None:
        plot_data = pd.DataFrame(
            [
                {
                    "stage": stage,
                    "batch": batch,
                    "seq_len": 1024,
                    "variant": "C1",
                    "total_latency_us": 1.0,
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
                for stage in ("prefill", "generation")
                for batch in (1, 2)
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plot_module.plt.close("all")
            with patch("tools.latency_bench.plot.plt.close"):
                plot_suite_bar_grid(
                    plot_data,
                    pd.DataFrame(),
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=Path(tmp) / "figures",
                        stacked=False,
                        value_labels=False,
                        legend_position="none",
                        shared_x_label=True,
                        shared_x_label_y=0.08,
                        x_label="sequence length",
                    ),
                )
                fig = plot_module.plt.gcf()
                self.assertEqual(["", "", "", ""], [ax.get_xlabel() for ax in fig.axes])
                shared_labels = [text for text in fig.texts if text.get_text() == "sequence length"]
                self.assertEqual(1, len(shared_labels))
                self.assertAlmostEqual(0.08, shared_labels[0].get_position()[1])
            plot_module.plt.close("all")

    def test_bar_grid_can_group_column_axis_on_x_axis(self) -> None:
        plot_data = pd.DataFrame(
            [
                {
                    "stage": stage,
                    "batch": batch,
                    "seq_len": seq_len,
                    "variant": "C1",
                    "total_latency_us": float(batch + seq_len / 1024),
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
                for stage in ("prefill", "generation")
                for batch in (1, 2)
                for seq_len in (512, 1024)
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plot_module.plt.close("all")
            with patch("tools.latency_bench.plot.plt.close"):
                plot_suite_bar_grid(
                    plot_data,
                    pd.DataFrame(),
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=Path(tmp) / "figures",
                        stacked=False,
                        value_labels=False,
                        legend_position="none",
                        x_group_axis="batch",
                    ),
                )
                axes = plot_module.plt.gcf().axes
                self.assertEqual(2, len(axes))
                self.assertEqual(["512", "1024", "512", "1024"], [tick.get_text() for tick in axes[0].get_xticklabels()])
                self.assertEqual(["batch=1", "batch=2"], [text.get_text() for text in axes[0].texts])
                self.assertEqual(1, len(axes[0].lines))
                self.assertAlmostEqual(-0.21, axes[0].get_xlim()[0])
                self.assertAlmostEqual(4.41, axes[0].get_xlim()[1])
            plot_module.plt.close("all")

    def test_bar_grid_saves_with_default_figure_padding(self) -> None:
        plot_data = pd.DataFrame(
            [
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 1024,
                    "variant": "C1",
                    "total_latency_us": 1.0,
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            with (
                patch("matplotlib.figure.Figure.savefig") as savefig,
                patch("tools.latency_bench.plot.plt.close"),
            ):
                plot_suite_bar_grid(
                    plot_data,
                    pd.DataFrame(),
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=Path(tmp) / "figures",
                        stacked=False,
                        value_labels=False,
                        legend_position="none",
                    ),
                )

            self.assertGreater(len(savefig.call_args_list), 0)
            for call in savefig.call_args_list:
                self.assertNotIn("pad_inches", call.kwargs)

    def test_relative_scope_x_tick_uses_one_baseline_per_x_tick(self) -> None:
        rows = pd.DataFrame(
            [
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "a", "plot_value": 10.0},
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "b", "plot_value": 20.0},
                {"stage": "prefill", "batch": 1, "seq_len": 32, "variant": "a", "plot_value": 100.0},
                {"stage": "prefill", "batch": 1, "seq_len": 32, "variant": "b", "plot_value": 150.0},
            ]
        )
        group_axes = _relative_group_axes("x_tick", "seq_len", "stage", "batch")
        out = _apply_relative_values(rows, "plot_value", _relative_baselines(rows, "plot_value", group_axes), group_axes)

        by_key = {
            (int(row["seq_len"]), row["variant"]): float(row["plot_value"])
            for _, row in out.iterrows()
        }
        self.assertEqual(1.0, by_key[(8, "a")])
        self.assertEqual(2.0, by_key[(8, "b")])
        self.assertEqual(1.0, by_key[(32, "a")])
        self.assertEqual(1.5, by_key[(32, "b")])

    def test_relative_scope_subplot_uses_one_baseline_per_subplot(self) -> None:
        rows = pd.DataFrame(
            [
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "a", "plot_value": 10.0},
                {"stage": "prefill", "batch": 1, "seq_len": 32, "variant": "b", "plot_value": 20.0},
                {"stage": "prefill", "batch": 2, "seq_len": 8, "variant": "a", "plot_value": 50.0},
                {"stage": "prefill", "batch": 2, "seq_len": 32, "variant": "b", "plot_value": 100.0},
            ]
        )
        group_axes = _relative_group_axes("subplot", "seq_len", "stage", "batch")
        out = _apply_relative_values(rows, "plot_value", _relative_baselines(rows, "plot_value", group_axes), group_axes)

        by_key = {
            (int(row["batch"]), int(row["seq_len"])): float(row["plot_value"])
            for _, row in out.iterrows()
        }
        self.assertEqual(1.0, by_key[(1, 8)])
        self.assertEqual(2.0, by_key[(1, 32)])
        self.assertEqual(1.0, by_key[(2, 8)])
        self.assertEqual(2.0, by_key[(2, 32)])

    def test_relative_stacked_segments_use_total_bar_baseline(self) -> None:
        totals = pd.DataFrame(
            [
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "a", "plot_value": 30.0},
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "b", "plot_value": 60.0},
            ]
        )
        segments = pd.DataFrame(
            [
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "a", "stack_key": "q", "plot_value": 10.0},
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "a", "stack_key": "k", "plot_value": 20.0},
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "b", "stack_key": "q", "plot_value": 30.0},
                {"stage": "prefill", "batch": 1, "seq_len": 8, "variant": "b", "stack_key": "k", "plot_value": 30.0},
            ]
        )
        group_axes = _relative_group_axes("x_tick", "seq_len", "stage", "batch")
        baselines = _relative_baselines(totals, "plot_value", group_axes)
        scaled_totals = _apply_relative_values(totals, "plot_value", baselines, group_axes)
        scaled_segments = _apply_relative_values(segments, "plot_value", baselines, group_axes)

        total_by_variant = scaled_totals.groupby("variant")["plot_value"].sum().to_dict()
        segment_by_variant = scaled_segments.groupby("variant")["plot_value"].sum().to_dict()
        self.assertEqual(total_by_variant, segment_by_variant)

    def test_subplot_title_uses_axis_and_value_label_maps(self) -> None:
        title = _subplot_title(
            "stage",
            "prefill",
            "batch",
            2,
            SuiteBarPlotOptions(
                raw_dbs=(Path("raw_db.csv"),),
                out_dir=Path("figures"),
                axis_label_map={"stage": "Stage", "batch": "Batch"},
                label_maps={"stage": {"prefill": "Prefill"}},
            ),
        )

        self.assertEqual("Stage=Prefill, Batch=2", title)

    def test_cli_visualize_accepts_suite_raw_db_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            suite = tmp_path / "suite.yaml"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)
            suite.write_text(
                """
name: plot_cli_suite
defaults:
  warmup: 1
  iterations: 1
  fpga_bin: plot_bin
cases:
  - id: llama2_batch1_prefill_seq_len8_v1_attn
    app: sgemm_tcu
    kind: gemm
    stage: prefill
    name: attn_qkT
    variant: v1
    args: "-m 8 -n 8 -k 128"
    calls_per_forward: 2
    shape: {batch: 1, seq: 8}
  - id: llama2_batch1_prefill_seq_len8_v1_ffn
    app: fpint_gemm_ffn_hw
    kind: gemm
    stage: prefill
    name: gate_proj
    variant: v1
    args: "-m 8 -n 4096 -k 4096"
    calls_per_forward: 3
    shape: {batch: 1, seq: 8}
""".lstrip()
            )

            rc = main([
                "visualize",
                "--suite", str(suite),
                "--raw-db", str(raw_db),
                "--out", str(out_dir),
                "--x", "seq_len",
                "--hue", "variant",
                "--row", "stage",
                "--col", "batch",
                "--no-stacked",
                "--no-value-labels",
                "--relative",
                "--relative-scope", "x_tick",
                "--share-y",
                "--legend-position", "bottom",
                "--legend-ncol", "2",
                "--figure-title", "Plot Test",
                "--x-label", "Seq",
                "--y-label", "Relative",
                "--legend-title", "Variant",
                "--value-order", "variant=v1",
                "--stack-legend-scope", "hue",
                "--value-label-rotation", "45",
                "--value-label-fontsize", "6",
                "--grouped-bar-gap", "0.06",
                "--x-tick-label-mode", "bar",
                "--x-tick-label-rotation", "30",
                "--x-tick-label-ha", "right",
            ])

            self.assertEqual(0, rc)
            plot_data = pd.read_csv(out_dir / "plot_data.csv")
            self.assertEqual(80.0, float(plot_data.loc[0, "total_latency_us"]))

    def test_stage_order_prefers_prefill_before_generation(self) -> None:
        ordered = _ordered_values(pd.Series(["generation", "prefill"]))

        self.assertEqual(["prefill", "generation"], ordered)

    def test_generation_seq_len_prefers_kv_length_over_decode_seq(self) -> None:
        row = pd.Series({
            "stage": "generation",
            "case_id": "llama2_batch1_gen_kv_len64_generation_rope_q",
        })

        self.assertEqual(64, _derive_seq_len(row, {"batch": 1, "seq": 1}))
        self.assertEqual(64, _derive_seq_len(row, {"batch": 1, "seq": 1, "cache_len": 32}))
        self.assertEqual(64, _derive_seq_len(row, {"batch": 1, "seqq": 1, "seqk": 128}))

    def test_stack_legend_scope_hue_uses_hue_specific_color_families(self) -> None:
        global_options = SuiteBarPlotOptions(raw_dbs=(Path("raw_db.csv"),), out_dir=Path("figures"))
        hue_options = SuiteBarPlotOptions(
            raw_dbs=(Path("raw_db.csv"),),
            out_dir=Path("figures"),
            stack_legend_scope="hue",
        )
        custom_global_options = SuiteBarPlotOptions(
            raw_dbs=(Path("raw_db.csv"),),
            out_dir=Path("figures"),
            palette=("#111111", "#222222"),
        )
        custom_hue_options = SuiteBarPlotOptions(
            raw_dbs=(Path("raw_db.csv"),),
            out_dir=Path("figures"),
            stack_legend_scope="hue",
            hue_stack_cmaps=("viridis", "plasma"),
            stack_cmap_min=0.10,
            stack_cmap_max=0.90,
        )

        self.assertEqual(_stack_color(0, 0, 3, global_options), _stack_color(0, 1, 3, global_options))
        self.assertNotEqual(_stack_color(0, 0, 3, hue_options), _stack_color(0, 1, 3, hue_options))
        self.assertNotEqual(_stack_color(0, 0, 3, hue_options), _stack_color(1, 0, 3, hue_options))
        self.assertEqual("#111111", _stack_color(0, 0, 3, custom_global_options))
        self.assertNotEqual(
            _stack_color(0, 0, 3, custom_hue_options),
            _stack_color(0, 1, 3, custom_hue_options),
        )

    def test_zero_height_stack_segments_are_never_drawn(self) -> None:
        self.assertEqual(
            [(0.0, 3.0, 0.0), (2.0, 4.0, 7.0)],
            _nonzero_bar_segments(
                positions=[0.0, 1.0, 2.0],
                heights=[3.0, 0.0, 4.0],
                bottoms=[0.0, 3.0, 7.0],
            ),
        )
        self.assertEqual([], _nonzero_bar_segments([0.0, 1.0], [0.0, 0.0], [0.0, 0.0]))

    def test_bar_width_and_offsets_include_grouped_bar_gap(self) -> None:
        width, offsets = _bar_width_and_offsets(4, 0.04)

        self.assertAlmostEqual(0.17, width)
        self.assertEqual(4, len(offsets))
        self.assertAlmostEqual(0.21, offsets[1] - offsets[0])
        self.assertAlmostEqual(-offsets[-1], offsets[0])

        with self.assertRaisesRegex(ValueError, "too large"):
            _bar_width_and_offsets(4, 0.4)

    def test_paper_plot_defaults_use_compact_grouped_axis_spacing(self) -> None:
        script = (
            Path(__file__).resolve().parents[2]
            / "analysis_workspace"
            / "latency_on_hw"
            / "plot_notebook.py"
        )
        spec = importlib.util.spec_from_file_location("latency_on_hw_plot_notebook", script)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)

        width, _ = _bar_width_and_offsets(4, module.GROUPED_BAR_GAP)
        old_width, _ = _bar_width_and_offsets(4, 0.04)
        self.assertEqual("batch", module.X_GROUP_AXIS)
        self.assertLessEqual(module.X_GROUP_GAP, 0.4)
        self.assertGreater(width, old_width)
        self.assertGreaterEqual(module.TWO_COLUMN_FIGSIZE[1], 4.8)
        self.assertLessEqual(module.VALUE_LABEL_FONTSIZE, 4.0)
        self.assertGreaterEqual(module.SHARED_X_LABEL_Y, 0.055)

    def test_stack_legend_scope_hue_generates_stacked_plot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            visualize_suites(
                [self._suite()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    stack_legend_scope="hue",
                    legend_position="right",
                    value_labels=False,
                ),
            )

            self.assertTrue((out_dir / "bar_total_p50_us.png").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.pdf").exists())

    def test_stack_legend_scope_hue_colors_by_active_stack_subset(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "figures"
            plot_data = pd.DataFrame([
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 32,
                    "variant": "C1",
                    "total_latency_us": 6.0,
                    "case_count": 3,
                    "pass_case_count": 3,
                    "missing_case_count": 0,
                },
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 32,
                    "variant": "C4",
                    "total_latency_us": 17.0,
                    "case_count": 2,
                    "pass_case_count": 2,
                    "missing_case_count": 0,
                },
            ])
            stack_data = pd.DataFrame([
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 32,
                    "variant": "C1",
                    "stack_key": f"kernel_{idx:02d}",
                    "total_latency_us": float(idx + 1),
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
                for idx in range(3)
            ] + [
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 32,
                    "variant": "C4",
                    "stack_key": f"kernel_{idx:02d}",
                    "total_latency_us": float(idx + 1),
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
                for idx in (7, 8)
            ])

            with patch("tools.latency_bench.plot._stack_color", wraps=plot_module._stack_color) as stack_color:
                plot_suite_bar_grid(
                    plot_data,
                    stack_data,
                    SuiteBarPlotOptions(
                        raw_dbs=(Path("raw_db.csv"),),
                        out_dir=out_dir,
                        stack_legend_scope="hue",
                        legend_position="right",
                        value_labels=False,
                    ),
                )

            color_calls = [(call.args[0], call.args[1], call.args[2]) for call in stack_color.call_args_list]
            self.assertEqual([(0, 1, 2), (1, 1, 2)], [call for call in color_calls if call[1] == 1])
            self.assertNotIn((3, 1, 5), color_calls)
            self.assertNotIn((4, 1, 5), color_calls)

    def test_visualize_suites_accepts_custom_bar_style(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            out_dir = tmp_path / "figures"
            self._write_raw_db(raw_db)

            visualize_suites(
                [self._suite()],
                SuiteBarPlotOptions(
                    raw_dbs=(raw_db,),
                    out_dir=out_dir,
                    palette=("#123456", "#abcdef"),
                    hue_stack_cmaps=("tab20", "Set3"),
                    stack_cmap_min=0.05,
                    stack_cmap_max=0.95,
                    bar_edgecolor="none",
                    bar_linewidth=0.0,
                    bar_alpha=0.9,
                    grouped_bar_gap=0.06,
                    value_label_rotation=45.0,
                    value_label_fontsize=6.0,
                    x_tick_label_mode="bar",
                    x_tick_label_rotation=30.0,
                    x_tick_label_ha="right",
                    stack_legend_scope="hue",
                ),
            )

            self.assertTrue((out_dir / "bar_total_p50_us.png").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.pdf").exists())

    def test_stack_legend_scope_hue_handles_many_stack_labels(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "figures"
            variants = ["C1", "C2", "C3", "C4"]
            plot_data = pd.DataFrame([
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 32,
                    "variant": variant,
                    "total_latency_us": 100.0,
                    "case_count": 12,
                    "pass_case_count": 12,
                    "missing_case_count": 0,
                }
                for variant in variants
            ])
            stack_data = pd.DataFrame([
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 32,
                    "variant": variant,
                    "stack_key": f"kernel_{idx:02d}",
                    "total_latency_us": float(idx + 1),
                    "case_count": 1,
                    "pass_case_count": 1,
                    "missing_case_count": 0,
                }
                for variant in variants
                for idx in range(12)
            ])

            plot_suite_bar_grid(
                plot_data,
                stack_data,
                SuiteBarPlotOptions(
                    raw_dbs=(Path("raw_db.csv"),),
                    out_dir=out_dir,
                    stack_legend_scope="hue",
                    legend_position="right",
                    value_labels=False,
                ),
            )

            self.assertTrue((out_dir / "bar_total_p50_us.png").exists())

    def test_ordered_values_uses_explicit_axis_order(self) -> None:
        ordered = _ordered_values(
            pd.Series(["C3", "C1", "C4", "C2"]),
            axis="variant",
            options=SuiteBarPlotOptions(
                raw_dbs=(Path("raw_db.csv"),),
                out_dir=Path("figures"),
                value_orders={"variant": ("C1", "C2")},
            ),
        )

        self.assertEqual(["C1", "C2", "C3", "C4"], ordered)

    def test_ordered_values_matches_explicit_order_by_string_value(self) -> None:
        ordered = _ordered_values(
            pd.Series([32, 8, 64]),
            axis="seq_len",
            options=SuiteBarPlotOptions(
                raw_dbs=(Path("raw_db.csv"),),
                out_dir=Path("figures"),
                value_orders={"seq_len": ("64", "8")},
            ),
        )

        self.assertEqual([64, 8, 32], ordered)


if __name__ == "__main__":
    unittest.main()
