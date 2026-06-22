from __future__ import annotations

import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[2] / "analysis_workspace" / "latency_on_hw" / "energy_per_token.py"
SPEC = importlib.util.spec_from_file_location("energy_per_token", SCRIPT)
assert SPEC is not None
energy_per_token = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = energy_per_token
SPEC.loader.exec_module(energy_per_token)


RAW_COLUMNS = [
    "case_id",
    "fpga_bin_label",
    "app",
    "args",
    "stage",
    "shape_json",
    "power_avg_w",
    "power_samples",
]


def _write_raw_db(path: Path, rows: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=RAW_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow({column: row.get(column, "") for column in RAW_COLUMNS})


def _raw_row(**overrides: str) -> dict[str, str]:
    row = {
        "case_id": "power_case",
        "fpga_bin_label": "naive_simd",
        "app": "sgemm_tcu",
        "args": "-m 512 -n 128 -k 512",
        "stage": "prefill",
        "shape_json": '{"M": 512, "N": 128, "K": 512}',
        "power_avg_w": "12.0",
        "power_samples": "7",
    }
    row.update(overrides)
    return row


def _composed_row(**overrides: object) -> dict[str, object]:
    row: dict[str, object] = {
        "case_id": "latency_case_batch2_prefill_seq_len512",
        "expected_fpga_bin_label": "naive_simd",
        "app": "sgemm_tcu",
        "args": "-m 512 -n 128 -k 512",
        "stage": "prefill",
        "variant": "all_sgemm_tcu_spinquant",
        "shape_json": '{"M": 512, "N": 128, "K": 512}',
        "batch": "2",
        "seq_len": "512",
        "weighted_latency_us": "2000000",
    }
    row.update(overrides)
    return row


class EnergyPerTokenTest(unittest.TestCase):
    def test_exact_power_match_uses_idle_subtracted_power(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(raw_db, [_raw_row(power_avg_w="12.0", power_samples="5")])

            rows = energy_per_token.energy_rows_from_records(
                [_composed_row()],
                [raw_db],
                idle_power_w=2.0,
                include_idle_power=False,
            )

            self.assertEqual("measured", rows[0]["power_resolution"])
            self.assertEqual("exact", rows[0]["power_match_scope"])
            self.assertEqual(10.0, rows[0]["effective_power_w"])
            self.assertEqual(20.0, rows[0]["kernel_energy_j"])
            self.assertEqual(1024, rows[0]["energy_tokens"])
            self.assertAlmostEqual(20.0 / 1024.0, rows[0]["joules_per_token_component"])

    def test_nearest_shape_imputes_same_fpga_app_power(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(
                        case_id="near",
                        args="-m 512 -n 128 -k 512",
                        shape_json='{"M": 512, "N": 128, "K": 512}',
                        power_avg_w="11.0",
                        power_samples="6",
                    ),
                    _raw_row(
                        case_id="far",
                        args="-m 4096 -n 128 -k 512",
                        shape_json='{"M": 4096, "N": 128, "K": 512}',
                        power_avg_w="20.0",
                        power_samples="100",
                    ),
                ],
            )

            rows = energy_per_token.energy_rows_from_records(
                [
                    _composed_row(
                        args="-m 1024 -n 128 -k 512",
                        shape_json='{"M": 1024, "N": 128, "K": 512}',
                    )
                ],
                [raw_db],
                idle_power_w=1.0,
                include_idle_power=False,
            )

            self.assertEqual("imputed", rows[0]["power_resolution"])
            self.assertEqual("same_fpga_app", rows[0]["power_match_scope"])
            self.assertEqual("near", rows[0]["power_source_case_id"])
            self.assertEqual(10.0, rows[0]["effective_power_w"])

    def test_invalid_power_candidates_are_ignored_and_generation_tokens_use_batch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(case_id="invalid", power_avg_w="99.0", power_samples="0"),
                    _raw_row(
                        case_id="valid",
                        args="-m 256",
                        shape_json='{"M": 256}',
                        power_avg_w="9.0",
                        power_samples="5",
                    ),
                ],
            )

            rows = energy_per_token.energy_rows_from_records(
                [
                    _composed_row(
                        case_id="latency_case_batch8_gen_kv_len512",
                        args="-m 512",
                        stage="generation",
                        batch="8",
                        seq_len="512",
                        shape_json='{"M": 512}',
                        weighted_latency_us="1000000",
                    )
                ],
                [raw_db],
                idle_power_w=4.0,
                include_idle_power=False,
            )

            self.assertEqual("valid", rows[0]["power_source_case_id"])
            self.assertEqual(8, rows[0]["energy_tokens"])
            self.assertEqual(5.0, rows[0]["kernel_energy_j"])
            self.assertAlmostEqual(5.0 / 8.0, rows[0]["joules_per_token_component"])

    def test_summary_marks_missing_power_group_incomplete(self) -> None:
        summary = energy_per_token.summarize_energy_rows(
            [
                {
                    "energy_stage": "prefill",
                    "energy_batch": 1,
                    "energy_seq_len": 512,
                    "variant": "v1",
                    "energy_tokens": 512,
                    "kernel_energy_j": 10.0,
                    "energy_weighted_latency_us": 1.0,
                    "power_resolution": "measured",
                },
                {
                    "energy_stage": "prefill",
                    "energy_batch": 1,
                    "energy_seq_len": 512,
                    "variant": "v1",
                    "energy_tokens": 512,
                    "kernel_energy_j": None,
                    "energy_weighted_latency_us": 1.0,
                    "power_resolution": "missing",
                },
            ]
        )

        self.assertEqual(1, len(summary))
        self.assertFalse(summary[0]["complete"])
        self.assertEqual(10.0 / 512.0, summary[0]["joules_per_token"])
        self.assertEqual(1, summary[0]["energy_component_count"])
        self.assertEqual(1, summary[0]["measured_power_count"])
        self.assertEqual(1, summary[0]["missing_power_count"])

    def test_relative_energy_values_use_x_tick_baseline(self) -> None:
        summary = energy_per_token.add_relative_energy_values(
            [
                {"stage": "prefill", "batch": 1, "seq_len": 512, "variant": "v1", "joules_per_token": 2.0},
                {"stage": "prefill", "batch": 1, "seq_len": 512, "variant": "v2", "joules_per_token": 4.0},
                {"stage": "prefill", "batch": 1, "seq_len": 1024, "variant": "v1", "joules_per_token": 10.0},
                {"stage": "prefill", "batch": 1, "seq_len": 1024, "variant": "v2", "joules_per_token": 20.0},
            ],
            relative_scope="x_tick",
        )

        by_key = {
            (row["seq_len"], row["variant"]): row
            for row in summary
        }
        self.assertEqual(1.0, by_key[(512, "v1")]["relative_joules_per_token"])
        self.assertEqual(2.0, by_key[(512, "v2")]["relative_joules_per_token"])
        self.assertEqual(1.0, by_key[(1024, "v1")]["relative_joules_per_token"])
        self.assertEqual(2.0, by_key[(1024, "v2")]["relative_joules_per_token"])
        self.assertEqual(2.0, by_key[(512, "v1")]["relative_baseline_joules_per_token"])
        self.assertEqual(10.0, by_key[(1024, "v1")]["relative_baseline_joules_per_token"])

    def test_energy_value_labels_keep_small_relative_differences(self) -> None:
        self.assertEqual("1.002x", energy_per_token._format_plot_value_label(1.00156, True))
        self.assertEqual("13.849", energy_per_token._format_plot_value_label(13.84852, False))

    def test_relative_energy_plot_labels_y_axis_only_on_first_column(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd

        summary = pd.DataFrame(
            [
                {
                    "stage": "prefill",
                    "batch": batch,
                    "seq_len": 512,
                    "variant": "C1",
                    "joules_per_token": float(batch),
                    "relative_joules_per_token": float(batch),
                    "complete": True,
                }
                for batch in (1, 2)
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plt.close("all")
            with patch("matplotlib.pyplot.close"):
                energy_per_token._plot_summary_dataframe(
                    summary,
                    Path(tmp) / "energy.png",
                    title=None,
                    label_maps={},
                    value_orders={},
                    palette=None,
                    legend_title="candidates",
                    include_idle_power=False,
                    relative=True,
                    value_labels=False,
                    value_label_rotation=90.0,
                    value_label_fontsize=7.0,
                    grouped_bar_gap=0.04,
                    bar_edgecolor="white",
                    bar_linewidth=0.25,
                    bar_alpha=1.0,
                    x_tick_label_rotation=0.0,
                    x_tick_label_ha="center",
                )
                axes = plt.gcf().axes
                self.assertEqual(["relative J/token", ""], [ax.get_ylabel() for ax in axes])
            plt.close("all")

    def test_energy_plot_uses_configured_ylim_top_scale(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd

        summary = pd.DataFrame(
            [
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 512,
                    "variant": "C1",
                    "joules_per_token": 4.0,
                    "relative_joules_per_token": 4.0,
                    "complete": True,
                },
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plt.close("all")
            with patch("matplotlib.pyplot.close"):
                energy_per_token._plot_summary_dataframe(
                    summary,
                    Path(tmp) / "energy.png",
                    title=None,
                    label_maps={},
                    value_orders={},
                    palette=None,
                    legend_title="candidates",
                    include_idle_power=False,
                    relative=True,
                    value_labels=True,
                    value_label_rotation=90.0,
                    value_label_fontsize=7.0,
                    grouped_bar_gap=0.04,
                    bar_edgecolor="white",
                    bar_linewidth=0.25,
                    bar_alpha=1.0,
                    x_tick_label_rotation=0.0,
                    x_tick_label_ha="center",
                    ylim_top_scale=1.22,
                )
                self.assertAlmostEqual(4.0 * 1.22, plt.gcf().axes[0].get_ylim()[1])
            plt.close("all")

    def test_energy_plot_can_place_legend_at_bottom(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd
        from matplotlib.legend import Legend

        summary = pd.DataFrame(
            [
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": 512,
                    "variant": variant,
                    "joules_per_token": float(idx + 1),
                    "relative_joules_per_token": float(idx + 1),
                    "complete": True,
                }
                for idx, variant in enumerate(("C1", "C2"))
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plt.close("all")
            with patch("matplotlib.pyplot.close"):
                energy_per_token._plot_summary_dataframe(
                    summary,
                    Path(tmp) / "energy.png",
                    title=None,
                    label_maps={},
                    value_orders={},
                    palette=None,
                    legend_title="candidates",
                    legend_position="bottom",
                    include_idle_power=False,
                    relative=True,
                    value_labels=False,
                    value_label_rotation=90.0,
                    value_label_fontsize=7.0,
                    grouped_bar_gap=0.04,
                    bar_edgecolor="white",
                    bar_linewidth=0.25,
                    bar_alpha=1.0,
                    x_tick_label_rotation=0.0,
                    x_tick_label_ha="center",
                )
                legends = plt.gcf().legends
                self.assertEqual(1, len(legends))
                self.assertEqual(Legend.codes["lower center"], legends[0]._loc)
                self.assertTrue((Path(tmp) / "energy.svg").exists())
            plt.close("all")


if __name__ == "__main__":
    unittest.main()
