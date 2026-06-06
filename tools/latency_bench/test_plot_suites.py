from __future__ import annotations

import csv
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
            self.assertFalse((out_dir / "composed_cases_scaled.csv").exists())
            self.assertFalse((out_dir / "plot_data_scaled.csv").exists())
            self.assertFalse((out_dir / "plot_stack_data_scaled.csv").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.png").exists())
            self.assertTrue((out_dir / "bar_total_p50_us.pdf").exists())
            self.assertFalse(subplots.call_args.kwargs["sharey"])

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

            unscaled_plot = pd.read_csv(out_dir / "plot_data.csv")
            scaled_plot = pd.read_csv(out_dir / "plot_data_scaled.csv")
            self.assertEqual(80.0, float(unscaled_plot.loc[0, "total_latency_us"]))
            self.assertEqual(70.0, float(scaled_plot.loc[0, "total_latency_us"]))
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
            self.assertFalse((out_dir / "plot_data_scaled_estimated.csv").exists())

            base_plot = pd.read_csv(out_dir / "plot_data.csv")
            estimated_plot = pd.read_csv(out_dir / "plot_data_estimated.csv")
            estimated_cases = pd.read_csv(out_dir / "composed_cases_estimated.csv")
            self.assertEqual(20.0, float(base_plot["total_latency_us"].sum()))
            self.assertEqual(60.0, float(estimated_plot["total_latency_us"].sum()))
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
        self.assertEqual(32, _derive_seq_len(row, {"batch": 1, "seq": 1, "cache_len": 32}))
        self.assertEqual(128, _derive_seq_len(row, {"batch": 1, "seqq": 1, "seqk": 128}))

    def test_stack_legend_scope_hue_uses_hue_specific_color_families(self) -> None:
        global_options = SuiteBarPlotOptions(raw_dbs=(Path("raw_db.csv"),), out_dir=Path("figures"))
        hue_options = SuiteBarPlotOptions(
            raw_dbs=(Path("raw_db.csv"),),
            out_dir=Path("figures"),
            stack_legend_scope="hue",
        )

        self.assertEqual(_stack_color(0, 0, 3, global_options), _stack_color(0, 1, 3, global_options))
        self.assertNotEqual(_stack_color(0, 0, 3, hue_options), _stack_color(0, 1, 3, hue_options))
        self.assertNotEqual(_stack_color(0, 0, 3, hue_options), _stack_color(1, 0, 3, hue_options))

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
