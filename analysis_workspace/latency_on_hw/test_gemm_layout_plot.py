import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import pandas as pd

import plot
import prepare


class GemmLayoutPlotTests(unittest.TestCase):
    def _backend_rows(self, stage: str = "Prefill") -> pd.DataFrame:
        rows = []
        for candidate in plot.E2E_CANDIDATE_COLUMNS:
            row = {
                "model": "Llama 3",
                "stage": stage,
                "batch": 1,
                "seq": "1k",
                "candidate": candidate,
                "q_proj::sgemm_tcu": 0.0,
                "q_proj::fpint_gemm_naive": 0.0,
                "q_proj::fpint_gemm_improve": 0.0,
                "attn_softmax::softmax": 0.0,
                "attn_softmax::softmax_layout_fused": 0.0,
                "q_hadamard::hadamard": 0.0,
                "q_hadamard::hadamard_layout_fused": 0.0,
                "r4_hadamard::hadamard": 0.0,
            }
            rows.append(row)

        rows[0]["q_proj::sgemm_tcu"] = 20.0
        rows[1]["q_proj::sgemm_tcu"] = 15.0
        rows[2]["q_proj::fpint_gemm_naive"] = 10.0
        rows[2]["attn_softmax::softmax"] = 1.0
        rows[2]["q_hadamard::hadamard"] = 2.0
        rows[2]["r4_hadamard::hadamard"] = 7.0
        rows[3]["q_proj::fpint_gemm_improve"] = 4.0
        rows[3]["attn_softmax::softmax_layout_fused"] = 3.0
        rows[3]["q_hadamard::hadamard_layout_fused"] = 5.0
        rows[3]["r4_hadamard::hadamard"] = 9.0
        return pd.DataFrame(rows)

    def test_layout_stack_is_sum_of_c4_fused_minus_c3_base(self) -> None:
        result = plot._build_gemm_layout_stack(pd, self._backend_rows())
        indexed = result.set_index("candidate")

        self.assertEqual(indexed.loc["C3", "gemm"], 10.0)
        self.assertEqual(indexed.loc["C3", "layout"], 0.0)
        self.assertEqual(indexed.loc["C4", "gemm"], 4.0)
        self.assertEqual(indexed.loc["C4", "layout"], (3.0 - 1.0) + (5.0 - 2.0))
        self.assertEqual(indexed.loc["C4", "total"], 9.0)

    def test_vector_stack_preserves_total_and_removes_layout_overhead(self) -> None:
        result = plot._build_gemm_layout_vector_stack(pd, self._backend_rows())
        indexed = result.set_index("candidate")

        self.assertEqual(indexed.loc["C3", "gemm"], 10.0)
        self.assertEqual(indexed.loc["C3", "layout"], 0.0)
        self.assertEqual(indexed.loc["C3", "vector"], 1.0 + 2.0 + 7.0)
        self.assertEqual(indexed.loc["C3", "total"], 20.0)

        layout_overhead = (3.0 - 1.0) + (5.0 - 2.0)
        self.assertEqual(indexed.loc["C4", "gemm"], 4.0)
        self.assertEqual(indexed.loc["C4", "layout"], layout_overhead)
        self.assertEqual(indexed.loc["C4", "vector"], 3.0 + 5.0 + 9.0 - layout_overhead)
        self.assertEqual(indexed.loc["C4", "total"], 21.0)

    def test_relative_stack_uses_smallest_positive_total_per_x_tick(self) -> None:
        absolute = plot._build_gemm_layout_stack(pd, self._backend_rows())
        stack_columns = plot._stack_value_columns(pd, absolute)
        relative = plot._apply_relative_stack_values(pd, absolute, stack_columns)
        indexed = relative.set_index("candidate")

        baseline = 9.0
        self.assertEqual(indexed.loc["C1", "total"], 20.0 / baseline)
        self.assertEqual(indexed.loc["C2", "total"], 15.0 / baseline)
        self.assertEqual(indexed.loc["C3", "total"], 10.0 / baseline)
        self.assertEqual(indexed.loc["C4", "total"], 1.0)
        self.assertEqual(indexed.loc["C4", "layout"], 5.0 / baseline)

    def test_stacked_knobs_default_to_relative_values(self) -> None:
        knobs = plot.StackedBarKnobs()

        self.assertTrue(knobs.relative)

    def test_layout_backend_suffix_is_preserved_for_c3_correspondence(self) -> None:
        self.assertEqual(
            plot._layout_base_backend("kv_cache_quant_layout_fused_w4a16"),
            "kv_cache_quant_w4a16",
        )

    def test_active_layout_backend_requires_corresponding_c3_backend(self) -> None:
        rows = self._backend_rows().drop(columns=["attn_softmax::softmax"])

        with self.assertRaisesRegex(
            ValueError,
            "expected one active C3 stack column corresponding to "
            "C4 stack column 'attn_softmax::softmax_layout_fused'",
        ):
            plot._build_gemm_layout_stack(pd, rows)

    def test_prepared_data_kind_is_distinct(self) -> None:
        csv_path = (
            Path("llama3_8b_e2e_gemm_layout_stacked_by_name_backend_prefill_b1_s1024")
            / plot.EXCEL_FIGURE_DATA_CSV
        )

        self.assertTrue(
            plot._candidate_matches_kind(csv_path, "e2e_gemm_layout_stacked")
        )
        self.assertFalse(plot._candidate_matches_kind(csv_path, "e2e_stacked"))
        self.assertFalse(plot._candidate_matches_kind(csv_path, "main_all"))

    def test_prepare_output_name_declares_name_backend_stack(self) -> None:
        name = prepare.e2e_gemm_layout_stacked_out_name("llama3_8b")

        self.assertIn("e2e_gemm_layout_stacked_by_name_backend", name)

    def test_latency_prepare_preserves_logical_name_and_backend(self) -> None:
        key = prepare.latency_plot_module._stack_key(
            pd.Series(
                {
                    "name": "attn_softmax",
                    "backend": "softmax_layout_fused",
                }
            ),
            "name_backend",
        )

        self.assertEqual(key, "attn_softmax::softmax_layout_fused")

    def test_cli_accepts_gemm_layout_plot_and_inputs(self) -> None:
        args = plot.parse_args(
            [
                "--plot",
                "llama_e2e_gemm_layout_stacked",
                "--llama3-e2e-gemm-layout-stacked-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(args.plot, "llama_e2e_gemm_layout_stacked")
        self.assertEqual(
            args.llama3_e2e_gemm_layout_stacked_data,
            "llama3.csv",
        )

    def test_cli_accepts_gemm_layout_vector_plot(self) -> None:
        args = plot.parse_args(
            [
                "--plot",
                "llama_e2e_gemm_layout_vector_stacked",
                "--llama3-e2e-gemm-layout-stacked-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(args.plot, "llama_e2e_gemm_layout_vector_stacked")
        self.assertEqual(args.llama3_e2e_gemm_layout_stacked_data, "llama3.csv")

    def test_gemm_layout_plot_writes_png(self) -> None:
        with TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_csvs = []
            for model_key, model_label in plot.LLAMA_E2E_MODELS:
                frames = []
                for stage in plot.STAGE_ORDER:
                    frame = self._backend_rows(stage)
                    frame = frame.drop(columns=["model"])
                    frames.append(frame)
                csv_path = root / f"{model_key}.csv"
                pd.concat(frames, ignore_index=True).to_csv(csv_path, index=False)
                model_csvs.append((model_key, model_label, csv_path))

            knobs = plot.PlotKnobs().llama_e2e_gemm_layout_stacked
            knobs.dpi = 50
            knobs.save_pdf = False
            knobs.save_svg = False
            plot.run_llama_e2e_gemm_layout_stacked_plot(
                model_csvs,
                root,
                knobs=knobs,
            )

            self.assertTrue(
                (
                    root
                    / "llama_e2e_gemm_layout_stacked"
                    / "llama_e2e_gemm_layout_latency_stacked.png"
                ).is_file()
            )

    def test_gemm_layout_vector_plot_writes_png(self) -> None:
        with TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_csvs = []
            for model_key, model_label in plot.LLAMA_E2E_MODELS:
                frames = []
                for stage in plot.STAGE_ORDER:
                    frame = self._backend_rows(stage)
                    frame = frame.drop(columns=["model"])
                    frames.append(frame)
                csv_path = root / f"{model_key}.csv"
                pd.concat(frames, ignore_index=True).to_csv(csv_path, index=False)
                model_csvs.append((model_key, model_label, csv_path))

            knobs = plot.PlotKnobs().llama_e2e_gemm_layout_vector_stacked
            knobs.dpi = 50
            knobs.save_pdf = False
            knobs.save_svg = False
            plot.run_llama_e2e_gemm_layout_vector_stacked_plot(
                model_csvs,
                root,
                knobs=knobs,
            )

            self.assertTrue(
                (
                    root
                    / "llama_e2e_gemm_layout_vector_stacked"
                    / "llama_e2e_gemm_layout_vector_latency_stacked.png"
                ).is_file()
            )


if __name__ == "__main__":
    unittest.main()
