import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pandas as pd
import plot
import prepare

from energy_per_token import (
    add_relative_energy_component_values,
    add_relative_energy_values,
    summarize_energy_rows,
)
from plot import (
    E2E_KIND_STACK_GROUPS,
    ENERGY_KIND_STACK_GROUPS,
    EnergyExcelResult,
    _apply_stack_groups,
    _stack_value_columns,
    _validate_energy_csv_schema,
    write_energy_stacked_figure_data_csv,
)


class EnergyBreakdownSummaryTests(unittest.TestCase):
    def _name_backend_energy_rows(self) -> list[dict[str, object]]:
        common = {
            "power_metric": "power_avg_W",
            "energy_stage": "prefill",
            "energy_batch": 1,
            "energy_seq_len": 1024,
            "energy_tokens": 1,
            "power_resolution": "measured",
            "energy_missing_cycle": False,
        }
        components = {
            "C1": [
                ("q_proj", "sgemm_tcu", "gemm", 20.0),
            ],
            "C2": [
                ("q_proj", "sgemm_tcu", "gemm", 15.0),
            ],
            "C3": [
                ("q_proj", "fpint_gemm_naive", "gemm", 10.0),
                ("attn_softmax", "softmax", "vector", 1.0),
                ("q_hadamard", "hadamard", "vector", 2.0),
                ("r4_hadamard", "hadamard", "vector", 7.0),
            ],
            "C4": [
                ("q_proj", "fpint_gemm_improve", "gemm", 4.0),
                (
                    "attn_softmax",
                    "softmax_layout_fused",
                    "vector",
                    3.0,
                ),
                (
                    "q_hadamard",
                    "hadamard_layout_fused",
                    "vector",
                    5.0,
                ),
                ("r4_hadamard", "hadamard", "vector", 9.0),
            ],
        }
        return [
            {
                **common,
                "variant": candidate,
                "name": name,
                "backend": backend,
                "kind": kind,
                "kernel_energy_j": energy,
            }
            for candidate, candidate_components in components.items()
            for name, backend, kind, energy in candidate_components
        ]

    def test_partial_energy_cache_rebuilds_flat_and_stacked_as_one_pair(self) -> None:
        common = {
            "power_metric": "power_avg_W",
            "energy_stage": "prefill",
            "energy_batch": 1,
            "energy_seq_len": 1024,
            "energy_tokens": 1,
            "power_resolution": "measured",
            "energy_missing_cycle": False,
        }
        rows = [
            {**common, "variant": "C1", "kind": "gemm", "kernel_energy_j": 2.0},
            {**common, "variant": "C1", "kind": "softmax", "kernel_energy_j": 1.0},
            {**common, "variant": "C4", "kind": "gemm", "kernel_energy_j": 0.75},
            {**common, "variant": "C4", "kind": "softmax", "kernel_energy_j": 0.25},
        ]

        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir)
            flat_csv = output_root / "flat" / "excel_figure_data.csv"
            flat_csv.parent.mkdir(parents=True)
            flat_csv.write_text("stale\n1\n")
            with (
                patch.object(prepare, "FIGURE_OUTPUT_ROOT", output_root),
                patch.object(prepare, "_energy_composed_rows", return_value=pd.DataFrame([{}])),
                patch.object(prepare, "energy_rows_from_records", return_value=rows),
            ):
                statuses = prepare.export_energy_figure_data_pair(
                    model="llama2_7b",
                    suite_tag="llama2_7b",
                    main_result=None,
                    out_name="flat",
                    stacked_out_name="stacked",
                    power_metric="power_avg_W",
                    force_rebuild=False,
                )

            self.assertEqual(statuses, ("rebuilt", "rebuilt"))
            self.assertIn("C1", pd.read_csv(flat_csv).columns)
            self.assertTrue((output_root / "stacked" / "excel_figure_data.csv").exists())

    def test_name_backend_energy_export_supports_layout_vector_split(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir)
            with (
                patch.object(prepare, "FIGURE_OUTPUT_ROOT", output_root),
                patch.object(
                    prepare,
                    "_energy_composed_rows",
                    return_value=pd.DataFrame([{}]),
                ),
                patch.object(
                    prepare,
                    "energy_rows_from_records",
                    return_value=self._name_backend_energy_rows(),
                ),
            ):
                statuses = prepare.export_energy_figure_data_pair(
                    model="llama2_7b",
                    suite_tag="llama2_7b",
                    main_result=None,
                    out_name="flat",
                    stacked_out_name="stacked",
                    gemm_layout_vector_stacked_out_name="name_backend",
                    power_metric="power_avg_W",
                    force_rebuild=True,
                )

            self.assertEqual(statuses, ("rebuilt", "rebuilt", "rebuilt"))
            exported = plot._read_excel_figure_data(
                output_root / "name_backend" / plot.EXCEL_FIGURE_DATA_CSV
            )
            transformed = plot._build_gemm_layout_vector_stack(
                pd,
                exported.assign(model="Llama 2"),
            ).set_index("candidate")

        baseline = 15.0
        layout_overhead = ((3.0 - 1.0) + (5.0 - 2.0)) / baseline
        self.assertAlmostEqual(transformed.loc["C4", "gemm"], 4.0 / baseline)
        self.assertAlmostEqual(
            transformed.loc["C4", "layout"],
            layout_overhead,
        )
        self.assertAlmostEqual(
            transformed.loc["C4", "vector"],
            (3.0 + 5.0 + 9.0) / baseline - layout_overhead,
        )
        self.assertAlmostEqual(transformed.loc["C4", "total"], 21.0 / baseline)

    def test_gemm_only_energy_export_is_name_stacked(self) -> None:
        rows = [
            row
            for row in self._name_backend_energy_rows()
            if row["kind"] == "gemm"
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            output_root = Path(temp_dir)
            with (
                patch.object(prepare, "FIGURE_OUTPUT_ROOT", output_root),
                patch.object(
                    prepare,
                    "energy_rows_from_records",
                    return_value=rows,
                ),
            ):
                status = prepare.export_gemm_only_energy_figure_data(
                    model="llama2_7b",
                    suite_tag="llama2_7b",
                    gemm_only_result=SimpleNamespace(
                        composed=pd.DataFrame([{}]),
                    ),
                    out_name="gemm_energy",
                    power_metric="power_avg_W",
                    force_rebuild=True,
                )

            exported = pd.read_csv(
                output_root
                / "gemm_energy"
                / plot.EXCEL_FIGURE_DATA_CSV
            )

        self.assertEqual(status, "rebuilt")
        self.assertIn("q_proj", exported.columns)
        self.assertAlmostEqual(
            exported.loc[exported["candidate"].eq("C4"), "total"].iloc[0],
            1.0,
        )

    def test_gemm_only_energy_uses_existing_gemm_legend_groups(self) -> None:
        knobs = plot.PlotKnobs()

        self.assertEqual(
            knobs.llama_gemm_only_energy.stack_groups,
            knobs.llama_gemm_only.stack_groups,
        )
        self.assertEqual(
            knobs.llama_gemm_only_energy.stack_palette,
            knobs.llama_gemm_only.stack_palette,
        )

    def test_gemm_only_energy_data_kind_is_distinct(self) -> None:
        csv_path = (
            Path(
                "llama3_8b_gemm_only_energy_per_token_stacked_by_name_"
                "power_avg_W_prefill_b1_s1024"
            )
            / plot.EXCEL_FIGURE_DATA_CSV
        )

        self.assertTrue(
            plot._candidate_matches_kind(csv_path, "gemm_only_energy")
        )
        self.assertFalse(plot._candidate_matches_kind(csv_path, "gemm_only"))
        self.assertFalse(plot._candidate_matches_kind(csv_path, "energy"))

    def test_cli_accepts_gemm_only_energy_plot_and_input(self) -> None:
        args = plot.parse_args(
            [
                "--plot",
                "llama_gemm_only_energy",
                "--llama3-gemm-energy-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(args.plot, "llama_gemm_only_energy")
        self.assertEqual(args.llama3_gemm_energy_data, "llama3.csv")

    def test_specialized_energy_data_kind_is_distinct(self) -> None:
        csv_path = (
            Path(
                "llama3_8b_energy_per_token_"
                "gemm_layout_vector_stacked_by_name_backend_"
                "power_avg_W_prefill_b1_s1024"
            )
            / plot.EXCEL_FIGURE_DATA_CSV
        )

        self.assertTrue(
            plot._candidate_matches_kind(
                csv_path,
                "energy_gemm_layout_vector_stacked",
            )
        )
        self.assertFalse(plot._candidate_matches_kind(csv_path, "energy"))
        self.assertFalse(
            plot._candidate_matches_kind(csv_path, "energy_stacked")
        )

    def test_cli_accepts_specialized_energy_plot_and_input(self) -> None:
        args = plot.parse_args(
            [
                "--plot",
                "llama_energy_gemm_layout_vector_stacked",
                "--llama3-energy-gemm-layout-vector-stacked-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(
            args.plot,
            "llama_energy_gemm_layout_vector_stacked",
        )
        self.assertEqual(
            args.llama3_energy_gemm_layout_vector_stacked_data,
            "llama3.csv",
        )

    def test_flat_energy_csv_is_rejected_as_stacked_input(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            csv_path = Path(temp_dir) / "excel_figure_data.csv"
            pd.DataFrame(
                [
                    {
                        "power_metric": "power_avg_W",
                        "stage": "Prefill",
                        "batch": 1,
                        "seq": "1k",
                        "C1": 2.0,
                        "C4": 1.0,
                    }
                ]
            ).to_csv(csv_path, index=False)
            with self.assertRaisesRegex(ValueError, "energy_stacked data missing columns"):
                _validate_energy_csv_schema(csv_path, "energy_stacked")

    def test_stacked_csv_and_kind_groups_fold_layout_into_vector(self) -> None:
        rows = [
            {
                "power_metric": "power_avg_W",
                "stage": "prefill",
                "batch": 1,
                "seq_len": 1024,
                "variant": candidate,
                "kind": kind,
                "relative_joules_per_token": value,
            }
            for candidate, components in {
                "C1": {"gemm": 2.0, "softmax": 0.75, "layout": 0.25},
                "C4": {"gemm": 0.5, "softmax": 0.4, "layout": 0.1},
            }.items()
            for kind, value in components.items()
        ]
        label_maps = {
            "stage": {"prefill": "Prefill"},
            "variant": {"C1": "C1", "C4": "C4"},
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            result = EnergyExcelResult(
                summary=pd.DataFrame(rows),
                figure_path=Path(temp_dir) / "energy.png",
            )
            csv_path = write_energy_stacked_figure_data_csv(
                result,
                label_maps=label_maps,
            )
            exported = pd.read_csv(csv_path).ffill()

        stack_columns = _stack_value_columns(pd, exported)
        grouped, labels = _apply_stack_groups(
            exported,
            stack_columns,
            ENERGY_KIND_STACK_GROUPS,
        )
        self.assertEqual(labels, ["gemm", "vector"])

        grouped = grouped.set_index("candidate")
        self.assertEqual(grouped.loc["C1", labels].tolist(), [2.0, 1.0])
        self.assertEqual(grouped.loc["C4", labels].tolist(), [0.5, 0.5])
        for candidate in ("C1", "C4"):
            self.assertAlmostEqual(
                float(grouped.loc[candidate, labels].sum()),
                float(grouped.loc[candidate, "total"]),
            )

    def test_e2e_kind_groups_fold_layout_into_vector(self) -> None:
        exported = pd.DataFrame(
            [
                {"gemm": 2.0, "softmax": 0.75, "layout": 0.25},
                {"gemm": 0.5, "softmax": 0.4, "layout": 0.1},
            ]
        )

        grouped, labels = _apply_stack_groups(
            exported,
            ["gemm", "softmax", "layout"],
            E2E_KIND_STACK_GROUPS,
        )

        self.assertEqual(labels, ["gemm", "vector"])
        self.assertEqual(grouped[labels].values.tolist(), [[2.0, 1.0], [0.5, 0.5]])

    def test_component_group_fields_cannot_overwrite_summary_columns(self) -> None:
        with self.assertRaisesRegex(ValueError, "conflict with summary columns"):
            summarize_energy_rows([], group_by=("stage",))

    def test_component_relative_values_sum_to_candidate_total(self) -> None:
        common = {
            "power_metric": "power_avg_W",
            "energy_stage": "prefill",
            "energy_batch": 1,
            "energy_seq_len": 1024,
            "energy_tokens": 1,
            "power_resolution": "measured",
            "energy_missing_cycle": False,
        }
        rows = [
            {**common, "variant": "C1", "kind": "gemm", "kernel_energy_j": 2.0},
            {**common, "variant": "C1", "kind": "vector", "kernel_energy_j": 1.0},
            {**common, "variant": "C4", "kind": "gemm", "kernel_energy_j": 0.75},
            {**common, "variant": "C4", "kind": "vector", "kernel_energy_j": 0.25},
        ]

        totals = add_relative_energy_values(
            summarize_energy_rows(rows),
            relative_scope="x_tick",
        )
        components = add_relative_energy_component_values(
            summarize_energy_rows(rows, group_by=("kind",)),
            totals,
            relative_scope="x_tick",
        )

        by_variant_kind = {
            (row["variant"], row["kind"]): row["relative_joules_per_token"]
            for row in components
        }
        self.assertEqual(by_variant_kind[("C1", "gemm")], 2.0)
        self.assertEqual(by_variant_kind[("C1", "vector")], 1.0)
        self.assertEqual(by_variant_kind[("C4", "gemm")], 0.75)
        self.assertEqual(by_variant_kind[("C4", "vector")], 0.25)

        total_by_variant = {row["variant"]: row["relative_joules_per_token"] for row in totals}
        component_sum_by_variant = {
            variant: sum(
                value
                for (candidate, _kind), value in by_variant_kind.items()
                if candidate == variant
            )
            for variant in total_by_variant
        }
        self.assertEqual(component_sum_by_variant, total_by_variant)


if __name__ == "__main__":
    unittest.main()
