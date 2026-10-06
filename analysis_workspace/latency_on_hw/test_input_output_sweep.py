import unittest
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch

import numpy as np
import pandas as pd

import input_output_sweep as sweep
import plot
import prepare


class InputOutputSweepTests(unittest.TestCase):
    def components(self):
        records = []
        variants = prepare.plot_label_maps(include_c4_alone=False)["variant"]
        for variant, candidate in variants.items():
            if candidate not in sweep.CANDIDATES:
                continue
            for length in (1024, 2048):
                for step in range(5):
                    cycles = 10000 if step == 0 else step * 1000
                    records.append(dict(
                        model="llama2_7b", variant=variant, stage="prefill" if step == 0 else "generation",
                        name="q_proj", app="gemm", kind="gemm", backend="sgemm_tcu", op="q_proj",
                        batch=1, prefill_seq_len=length if step == 0 else np.nan,
                        gen_kv_len=length if step else np.nan, output_token_index=step,
                        out_tokens=4, calls_per_forward=1, fpga_cycle=cycles, fpga_period_s=1e-6,
                        weighted_latency_us=cycles, compose_status="pass", power_pcie_avg_w=2,
                        power_idle_pcie_avg_w=0,
                    ))
        return pd.DataFrame(records)

    def build(self, rows=None, **kwargs):
        return sweep.build_input_output_breakdown(
            self.components() if rows is None else rows,
            models=("llama2_7b",), source_out_tokens=4,
            power_metric="power_avg_W", **kwargs,
        )

    def test_first_output_uses_only_prefill(self):
        result = self.build(output_tokens=(1,))
        self.assertEqual(len(result), 8)
        self.assertTrue(result["batch"].eq(1).all())
        self.assertTrue(result["decode_steps"].eq(0).all())
        np.testing.assert_allclose(result["prefill_latency_s"], .01)
        np.testing.assert_allclose(result["decode_latency_s"], 0)
        np.testing.assert_allclose(result["decode_energy_j"], 0)
        np.testing.assert_allclose(result["energy_per_output_token_j"], .02)

    def test_decode_prefix_and_output_energy_denominator(self):
        result = self.build(output_tokens="1,4")
        four = result.loc[result["output_tokens"].eq(4)]
        # Includes steps 1+2+3, not step 4 or a scaled full-run average.
        np.testing.assert_allclose(four["decode_latency_s"], .006)
        np.testing.assert_allclose(four["e2e_latency_s"], .016)
        np.testing.assert_allclose(four["prefill_energy_per_output_token_j"], .005)
        np.testing.assert_allclose(four["decode_energy_per_output_token_j"], .003)
        np.testing.assert_allclose(four["energy_per_output_token_j"], .008)
        np.testing.assert_allclose(
            result["prefill_energy_per_output_token_j"] + result["decode_energy_per_output_token_j"],
            result["energy_per_output_token_j"],
        )

    def test_other_batches_are_excluded(self):
        rows = self.components()
        batch4 = rows.assign(batch=4, weighted_latency_us=1e12)
        result = self.build(pd.concat([rows, batch4]), output_tokens=(4,))
        np.testing.assert_allclose(result["e2e_latency_s"], .016)

    def test_missing_step_is_detected_per_component(self):
        rows = self.components()
        # A second component still covers step 2; checking the union would pass.
        other = rows.assign(name="k_proj", op="k_proj")
        variant = rows.iloc[0]["variant"]
        rows = rows.loc[~(rows["variant"].eq(variant) & rows["output_token_index"].eq(2))]
        with self.assertRaisesRegex(ValueError, "incomplete decode prefix"):
            self.build(pd.concat([rows, other]), output_tokens=(4,))

    def test_duplicate_component_is_rejected(self):
        rows = self.components()
        with self.assertRaisesRegex(ValueError, "duplicate"):
            self.build(pd.concat([rows, rows.iloc[[1]]]), output_tokens=(4,))

    def test_missing_candidate_and_power_are_rejected(self):
        rows = self.components()
        with self.assertRaisesRegex(ValueError, "missing batch-1"):
            self.build(rows.loc[~rows["variant"].eq(rows.iloc[0]["variant"])], output_tokens=(4,))
        rows.loc[0, "power_pcie_avg_w"] = np.nan
        with self.assertRaisesRegex(ValueError, "cycle/clock/power"):
            self.build(rows, output_tokens=(4,))

    def test_missing_clock_does_not_fall_back_to_default(self):
        rows = self.components()
        rows.loc[0, "fpga_period_s"] = np.nan
        with self.assertRaisesRegex(ValueError, "fpga_period_s"):
            self.build(rows, output_tokens=(4,))

    def test_requested_lengths_are_checked(self):
        with self.assertRaisesRegex(ValueError, "source decode-step"):
            self.build(output_tokens=(6,))
        with self.assertRaisesRegex(ValueError, "input length"):
            self.build(input_tokens=(4096,), output_tokens=(4,))
        with self.assertRaisesRegex(ValueError, "positive integers"):
            self.build(output_tokens=(1.5,))

    def test_estimated_components_are_accepted_but_unresolved_are_rejected(self):
        rows = self.components().assign(compose_status="estimated")
        result = self.build(rows, output_tokens=(4,))
        np.testing.assert_allclose(result["e2e_latency_s"], .016)
        rows.loc[0, "compose_status"] = "missing"
        with self.assertRaisesRegex(ValueError, "unresolved"):
            self.build(rows, output_tokens=(4,))

    def test_existing_dequant_policies_and_hadamard_inclusion(self):
        rows = self.components()
        hadamard = rows.assign(name="q_hadamard", op="hadamard", kind="vector", backend="hadamard")
        weight = rows.assign(name="q_weight_dequant", op="dequant", kind="dequantization", backend="dequant")
        kv = rows.assign(name="kv_cache_dequant_k", op="dequant", kind="dequantization", backend="dequant")
        result = self.build(pd.concat([rows, hadamard, weight, kv]), output_tokens=(4,))
        # Latency excludes dequant; energy includes weight in both stages, KV only in decode.
        np.testing.assert_allclose(result["e2e_latency_s"], .032)
        np.testing.assert_allclose(result["prefill_energy_j"], .06)
        np.testing.assert_allclose(result["decode_energy_j"], .048)
        np.testing.assert_allclose(result["energy_per_output_token_j"], .027)

    def test_cli_renders_latency_and_energy_with_only_two_stacks(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "composed.csv"
            components = self.components()
            candidate = components["variant"].map(prepare.plot_label_maps(include_c4_alone=False)["variant"])
            scale = candidate.map({"C1": 1, "C2": 2, "C3": 3, "C4": 4})
            prefill_scale = scale.where(components["stage"].eq("prefill"), 1)
            components["fpga_cycle"] *= prefill_scale
            components["weighted_latency_us"] *= prefill_scale
            components["power_pcie_avg_w"] *= scale
            components.to_csv(source, index=False)
            rendered = []
            save_figure = plot._save_figure

            def verify_and_save(fig, path, knobs):
                ax = fig.axes[0]
                expected_prefill = np.array([.01*i for i in range(1, 5)] * 2)
                expected_decode = np.array([0.0]*4 + [.006]*4)
                if "energy_per_token" in path.name:
                    powers = np.array([2*i for i in range(1, 5)] * 2)
                    outputs = np.array([1]*4 + [4]*4)
                    expected_prefill *= powers / outputs
                    expected_decode *= powers / outputs
                baselines = (expected_prefill + expected_decode)[[3]*4 + [7]*4]
                expected_prefill /= baselines
                expected_decode /= baselines
                np.testing.assert_allclose([bar.get_height() for bar in ax.containers[0]], expected_prefill)
                np.testing.assert_allclose([bar.get_height() for bar in ax.containers[1]], expected_decode)
                totals = expected_prefill + expected_decode
                labels = [text for text in ax.texts if hasattr(text, "_stacked_value_label_total")]
                self.assertEqual([text.get_text() for text in labels], [f"{value:.2f}" for value in totals])
                np.testing.assert_allclose(totals[[3, 7]], 1)
                self.assertEqual(ax.get_yscale(), "linear")
                self.assertIn("C4=1", ax.get_ylabel())
                save_figure(fig, path, knobs)
                self.assertTrue(all(text.get_visible() for text in labels))
                rendered.append(path.name)

            with (
                patch.object(plot, "REQUESTED_LLAMA_MODELS", None),
                patch.object(plot, "REQUESTED_OUT_TOKENS", None),
                patch.object(plot, "REQUESTED_MODEL_DATA", {}),
                patch.object(plot, "REQUESTED_POWER_METRIC", None),
                patch.object(plot, "_save_figure", side_effect=verify_and_save),
            ):
                self.assertEqual(plot.main([
                    "--plot", "llama_input_output_stacked", "--composed-csv", str(source),
                    "--models", "llama2_7b", "--out-tokens", "4", "--sweep-input-tokens", "1024",
                    "--sweep-output-tokens", "1,4", "--power-metric", "power_avg_W",
                    "--formats", "png", "--out-dir", str(root / "figures"),
                ]), 0)
            output = root / "figures" / "llama_input_output_stacked"
            self.assertEqual(len(rendered), 2)
            self.assertEqual(len(list(output.glob("*.png"))), 2)
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertTrue(manifest["relative"])
            self.assertTrue(manifest["value_labels"])
            self.assertEqual(manifest["relative_baseline_candidate"], "C4")
            result = pd.read_csv(output / "input_output_breakdown.csv")
            self.assertEqual(len(result), 8)
            for metric in ("latency", "energy"):
                frame = pd.read_csv(output / "data" / metric / "llama2_7b" / "excel_figure_data.csv")
                self.assertEqual(plot._stack_value_columns(pd, frame), ["Prefill", "Decode"])


if __name__ == "__main__":
    unittest.main()
