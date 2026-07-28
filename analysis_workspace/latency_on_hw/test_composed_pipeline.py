from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
import sys

import pandas as pd

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import energy_per_token
import plot
import prepare
import run_compose


def _decode_frame(*, out_tokens: int = 4) -> pd.DataFrame:
    rows = []
    for index, latency in enumerate((10.0, 20.0, 30.0, 40.0), start=1):
        if index > out_tokens:
            break
        rows.append(
            {
                "model": "llama2_7b",
                "suite": "decode_suite",
                "suite_file": "decode.yaml",
                "case_id": f"decode_case_{out_tokens}_{index}",
                "exec_key": "same-invariant-exec-key",
                "app": "kernel",
                "stage": "generation",
                "variant": "all_sgemm_tcu_spinquant",
                "kind": "vector",
                "name": "kernel",
                "backend": "kernel",
                "op": "kernel",
                "batch": 2,
                "prefill_seq_len": 0,
                "gen_kv_len": 1024,
                "args": "--test",
                "shape_json": (
                    '{"input_kv_length": 1024, "logical_cache_length": '
                    f"{1024 + index}, \"out_tokens\": {out_tokens}, "
                    f'"output_token_index": {index}}}'
                ),
                "calls_per_forward": 2.0,
                "metric": "fpga_cycle",
                "output_token_index": index,
                "out_tokens": out_tokens,
                "measurement_kind": "invariant_reused" if index > 1 else "measured",
                "latency_us": latency,
                "weighted_latency_us": latency * 2.0,
                "compose_status": "pass",
                "latency_resolution_kind": "measured",
                "power_resolution_kind": "measured",
                "power_avg_w": 1.0,
                "power_vcc_avg_w": 1.0,
                "power_dynamic_avg_w": 1.0,
                "fpga_period_s": 1.0,
                "source_raw_dbs": "raw.csv",
                "expected_fpga_bin_label": "C1",
                "source_fpga_bin_labels": "C1",
            }
        )
    return pd.DataFrame(rows)


class ComposedPipelineTest(unittest.TestCase):
    def test_decode_latency_is_grouped_by_input_kv_and_averaged_per_token(self) -> None:
        frame = _decode_frame()
        prepare._configure_out_tokens(4)
        _, options = prepare._make_suite_options(
            Path("unused"),
            model="llama2_7b",
            suite_tag="unused",
            stacked=True,
            include_c4_alone=True,
            row_filters=(),
            shape_selection=None,
            case_latency_scale_rules=(),
        )
        versions = prepare._prepare_versions_from_composed(frame, options)

        self.assertEqual(1, len(versions.final.plot_data))
        row = versions.final.plot_data.iloc[0]
        self.assertEqual(1024, row["seq_len"])
        self.assertAlmostEqual(50.0, row["total_latency_us"])
        self.assertEqual(4, row["case_count"])

    def test_decode_energy_uses_batch_times_out_tokens(self) -> None:
        frame = _decode_frame()
        rows = energy_per_token.energy_rows_from_records(
            frame.to_dict("records"),
            (),
            power_metric="power_dynamic_avg_W",
            fpga_period_s=1.0,
            allow_generic_power_estimate=False,
        )
        summary = energy_per_token.summarize_energy_rows(rows)

        self.assertEqual(1, len(summary))
        self.assertEqual(1024, summary[0]["seq_len"])
        self.assertEqual(8, summary[0]["tokens"])
        self.assertAlmostEqual(25.0, summary[0]["joules_per_token"])

    def test_vectorized_energy_matches_legacy_for_all_power_metrics(self) -> None:
        frame = _decode_frame()
        vectorized = prepare._vectorized_energy_rows(frame)
        for power_metric in prepare.ENERGY_POWER_METRICS:
            legacy = energy_per_token.energy_rows_from_records(
                frame.to_dict("records"),
                (),
                power_metric=power_metric,
                fpga_period_s=1.0,
                allow_generic_power_estimate=False,
            )
            legacy_energy = [row["kernel_energy_j"] for row in legacy]
            vectorized_energy = vectorized.loc[
                vectorized["power_metric"].eq(power_metric),
                "kernel_energy_j",
            ].tolist()
            self.assertEqual(legacy_energy, vectorized_energy)

    def test_prepare_keeps_multiple_batch_and_sequence_workloads(self) -> None:
        frames = []
        for batch, seq_len in ((1, 512), (1, 1024), (2, 512), (2, 1024)):
            frame = _decode_frame().copy()
            frame["batch"] = batch
            frame["gen_kv_len"] = seq_len
            frame["case_id"] = frame["case_id"].map(
                lambda case_id: f"{case_id}_b{batch}_s{seq_len}"
            )
            frames.append(frame)
        composed = pd.concat(frames, ignore_index=True)
        prepare._configure_out_tokens(4)
        _, options = prepare._make_suite_options(
            Path("unused"),
            model="llama2_7b",
            suite_tag="unused",
            stacked=True,
            include_c4_alone=True,
            row_filters=(),
            shape_selection=None,
            case_latency_scale_rules=(),
        )
        versions = prepare._prepare_versions_from_composed(composed, options)

        workloads = versions.final.plot_data[["batch", "seq_len"]]
        self.assertEqual(
            {(1, 512), (1, 1024), (2, 512), (2, 1024)},
            set(map(tuple, workloads.to_numpy())),
        )
        self.assertTrue(versions.final.plot_data["total_latency_us"].eq(50.0).all())

    def test_prepare_rejects_missing_output_step(self) -> None:
        frame = _decode_frame().iloc[:-1].copy()
        with self.assertRaisesRegex(ValueError, "do not cover every output token"):
            prepare._validate_prepare_composed(frame, 4)

    def test_compose_rejects_missing_power(self) -> None:
        frame = _decode_frame()
        frame.loc[0, "power_dynamic_avg_w"] = float("nan")
        with self.assertRaisesRegex(ValueError, "incomplete"):
            run_compose._validate_complete_composed(frame, label="test")

    def test_plot_requires_matching_scalar_out_tokens(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "excel_figure_data.csv"
            pd.DataFrame(
                [{"out_tokens": 4, "stage": "Generation", "batch": 1, "seq": "1k"}]
            ).to_csv(path, index=False)
            plot.REQUESTED_OUT_TOKENS = 2
            try:
                with self.assertRaisesRegex(ValueError, "does not match"):
                    plot._read_excel_figure_data(path)
            finally:
                plot.REQUESTED_OUT_TOKENS = None

    def test_plot_formats_control_every_figure_family(self) -> None:
        args = plot.parse_args(
            ["--out-tokens", "4", "--formats", "png", "--workers", "2"]
        )
        knobs = plot._plot_knobs_from_args(args)
        for item in vars(knobs).values():
            self.assertTrue(item.save_png)
            self.assertFalse(item.save_pdf)
            self.assertFalse(item.save_svg)

    def test_parallel_plot_job_replaces_coordinator_options(self) -> None:
        arguments = plot._replace_parallel_plot_args(
            [
                "--plot",
                "all",
                "--out-tokens",
                "128",
                "--workers=4",
                "--formats",
                "png",
            ],
            plot_name="llama_energy",
            power_metric="power_dynamic_avg_W",
        )
        self.assertIn("llama_energy", arguments)
        self.assertIn("power_dynamic_avg_W", arguments)
        self.assertNotIn("all", arguments)
        self.assertIn("png", arguments)


if __name__ == "__main__":
    unittest.main()
