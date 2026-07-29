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
    "power_avg_W",
    "power_vcc_avg_W",
    "power_dynamic_avg_W",
    "power_avg_w",
    "power_vcc_avg_w",
    "power_dynamic_avg_w",
    "power_samples",
    "fpga_cycle_avg",
    "fpga_bin_dir",
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
        "power_avg_W": "12.0",
        "power_vcc_avg_W": "7.0",
        "power_dynamic_avg_W": "2.0",
        "power_samples": "7",
        "fpga_cycle_avg": "1000",
        "fpga_bin_dir": "/opt/vortex_fpga_bins/fpint/xrt_hw_u55c_c1_f100_fpint/bin",
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
        "calls_per_forward": "2",
        "metric": "fpga_cycle",
        "latency_us": "1000",
        "fpga_cycle_avg": "1000",
    }
    row.update(overrides)
    return row


class EnergyPerTokenTest(unittest.TestCase):
    def test_exact_power_match_uses_fpga_cycle_period_and_selected_power_metric(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(raw_db, [_raw_row(power_avg_W="5.0", power_samples="5")])

            rows = energy_per_token.energy_rows_from_records(
                [_composed_row()],
                [raw_db],
                idle_power_w=2.0,
                include_idle_power=False,
                power_metric="power_avg_W",
                fpga_period_s=10e-9,
            )

            self.assertEqual("measured", rows[0]["power_resolution"])
            self.assertEqual("exact", rows[0]["power_match_scope"])
            self.assertEqual("power_avg_W", rows[0]["power_metric"])
            self.assertEqual(5.0, rows[0]["raw_power_W"])
            self.assertEqual(5.0, rows[0]["effective_power_W"])
            self.assertEqual(2000.0, rows[0]["energy_weighted_fpga_cycles"])
            self.assertEqual(10e-9, rows[0]["fpga_period_s"])
            self.assertEqual(0.00002, rows[0]["energy_time_s"])
            self.assertEqual(0.0001, rows[0]["kernel_energy_j"])
            self.assertEqual(1024, rows[0]["energy_tokens"])
            self.assertAlmostEqual(0.0001 / 1024.0, rows[0]["joules_per_token_component"])

    def test_power_metric_selection_uses_vcc_and_dynamic_columns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(
                        power_avg_W="9.0",
                        power_vcc_avg_W="7.0",
                        power_dynamic_avg_W="1.25",
                        power_samples="5",
                    )
                ],
            )

            vcc_rows = energy_per_token.energy_rows_from_records(
                [_composed_row(calls_per_forward="1", fpga_cycle_avg="4000", latency_us="4000")],
                [raw_db],
                idle_power_w=0.0,
                power_metric="power_vcc_avg_W",
                fpga_period_s=10e-9,
            )
            dynamic_rows = energy_per_token.energy_rows_from_records(
                [_composed_row(calls_per_forward="1", fpga_cycle_avg="4000", latency_us="4000")],
                [raw_db],
                idle_power_w=0.0,
                power_metric="power_dynamic_avg_W",
                fpga_period_s=10e-9,
            )

            self.assertEqual(7.0, vcc_rows[0]["raw_power_W"])
            self.assertAlmostEqual(0.00028, vcc_rows[0]["kernel_energy_j"])
            self.assertEqual(1.25, dynamic_rows[0]["raw_power_W"])
            self.assertEqual(0.00005, dynamic_rows[0]["kernel_energy_j"])

    def test_lowercase_power_columns_fall_back_to_uppercase_metric_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(
                        power_avg_W="",
                        power_avg_w="6.0",
                        power_samples="5",
                    )
                ],
            )

            rows = energy_per_token.energy_rows_from_records(
                [_composed_row(calls_per_forward="1", fpga_cycle_avg="1000", latency_us="1000")],
                [raw_db],
                idle_power_w=0.0,
                power_metric="power_avg_W",
                fpga_period_s=10e-9,
            )

            self.assertEqual("power_avg_W", rows[0]["power_metric"])
            self.assertEqual(6.0, rows[0]["raw_power_W"])
            self.assertAlmostEqual(0.00006, rows[0]["kernel_energy_j"])

    def test_fpga_bin_alias_xclbin_info_sets_cycle_period(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bin_dir = root / "bins" / "xrt_hw_u55c_c1_custom" / "bin"
            bin_dir.mkdir(parents=True)
            (bin_dir / "vortex_xclbin.info").write_text(
                "Clock Information\n"
                "  Name: KERNEL_CLK\n"
                "  Frequency: 100.000000 MHz\n"
                "  Name: DATA_CLK\n"
                "  Frequency: 250 MHz\n"
                "System Clocks\n"
                "  Name: ulp_ucs_aclk_kernel_00\n"
                "  Requested Freq: 100 MHz\n"
                "  Achieved Freq: 92.1 MHz\n",
                encoding="utf-8",
            )
            alias_map = root / "fpga_bin_alias_map.yaml"
            alias_map.write_text(
                "aliases:\n"
                "  custom_alias:\n"
                f"    path: {bin_dir}\n",
                encoding="utf-8",
            )
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(
                        fpga_bin_label="custom_alias",
                        power_avg_W="5.0",
                        fpga_bin_dir="",
                    )
                ],
            )

            with patch.dict("os.environ", {"VORTEX_FPGA_BIN_ALIAS_MAP": str(alias_map)}):
                rows = energy_per_token.energy_rows_from_records(
                    [
                        _composed_row(
                            expected_fpga_bin_label="custom_alias",
                            calls_per_forward="1",
                            fpga_cycle_avg="250",
                            latency_us="250",
                        )
                    ],
                    [raw_db],
                    power_metric="power_avg_W",
                    fpga_period_s=10e-9,
                )

            self.assertAlmostEqual(1.0 / 92.1e6, rows[0]["fpga_period_s"])
            self.assertAlmostEqual(250.0 / 92.1e6 * 5.0, rows[0]["kernel_energy_j"])

    def test_fpga_bin_dir_name_does_not_set_cycle_period_without_xclbin_info(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp) / "xrt_hw_u55c_c1_f200_fpint" / "bin"
            bin_dir.mkdir(parents=True)
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(
                        power_avg_W="5.0",
                        fpga_bin_dir=str(bin_dir),
                    )
                ],
            )

            rows = energy_per_token.energy_rows_from_records(
                [_composed_row(calls_per_forward="1", fpga_cycle_avg="200", latency_us="200")],
                [raw_db],
                power_metric="power_avg_W",
                fpga_period_s=10e-9,
            )

            self.assertAlmostEqual(10e-9, rows[0]["fpga_period_s"])
            self.assertAlmostEqual(0.00001, rows[0]["kernel_energy_j"])

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
                        power_avg_W="11.0",
                        power_samples="6",
                    ),
                    _raw_row(
                        case_id="far",
                        args="-m 4096 -n 128 -k 512",
                        shape_json='{"M": 4096, "N": 128, "K": 512}',
                        power_avg_W="20.0",
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
                power_metric="power_avg_W",
                fpga_period_s=10e-9,
            )

            self.assertEqual("imputed", rows[0]["power_resolution"])
            self.assertEqual("same_fpga_app", rows[0]["power_match_scope"])
            self.assertEqual("near", rows[0]["power_source_case_id"])
            self.assertEqual(11.0, rows[0]["effective_power_W"])

    def test_composed_decode_power_precedes_generic_estimator(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [_raw_row(power_avg_W="99.0", power_samples="5")],
            )
            row = _composed_row(
                power_avg_w="12.0",
                power_resolution_kind="interpolated",
                power_interpolation_upper_ratio="0.25",
            )

            rows = energy_per_token.energy_rows_from_records(
                [row],
                [raw_db],
                power_metric="power_avg_W",
                allow_generic_power_estimate=False,
            )

            self.assertEqual("interpolated", rows[0]["power_resolution"])
            self.assertEqual("composed", rows[0]["power_match_scope"])
            self.assertEqual(12.0, rows[0]["effective_power_W"])

    def test_invalid_power_candidates_are_ignored_and_generation_tokens_use_batch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            raw_db = Path(tmp) / "raw_db.csv"
            _write_raw_db(
                raw_db,
                [
                    _raw_row(case_id="invalid", power_avg_W="99.0", power_samples="0"),
                    _raw_row(
                        case_id="valid",
                        args="-m 256",
                        shape_json='{"M": 256}',
                        power_avg_W="9.0",
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
                        calls_per_forward="2",
                        metric="fpga_cycle",
                        latency_us="1000",
                        fpga_cycle_avg="1000",
                    )
                ],
                [raw_db],
                idle_power_w=4.0,
                include_idle_power=False,
                power_metric="power_avg_W",
                fpga_period_s=10e-9,
            )

            self.assertEqual("valid", rows[0]["power_source_case_id"])
            self.assertEqual(8, rows[0]["energy_tokens"])
            self.assertEqual(0.00018, rows[0]["kernel_energy_j"])
            self.assertAlmostEqual(0.00018 / 8.0, rows[0]["joules_per_token_component"])

    def test_generation_energy_tokens_include_output_length(self) -> None:
        row = {
            "stage": "generation",
            "batch": "8",
            "out_tokens": "3",
            "shape_json": '{"batch": 8, "out_tokens": 3}',
        }

        self.assertEqual(24, energy_per_token._token_count(row))

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

    def test_energy_plot_can_share_y_axis_by_row(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd

        summary = pd.DataFrame(
            [
                {
                    "stage": stage,
                    "batch": batch,
                    "seq_len": 512,
                    "variant": "C1",
                    "joules_per_token": value,
                    "relative_joules_per_token": value,
                    "complete": True,
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
                    legend_position="none",
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
                    ylim_top_scale=1.22,
                    share_y_scope="row",
                )
                axes = plt.gcf().axes
                self.assertEqual(axes[0].get_ylim(), axes[1].get_ylim())
                self.assertEqual(axes[2].get_ylim(), axes[3].get_ylim())
                self.assertNotEqual(axes[0].get_ylim(), axes[2].get_ylim())
                self.assertTrue(any(label.get_visible() for label in axes[0].get_yticklabels()))
                self.assertFalse(any(label.get_visible() for label in axes[1].get_yticklabels()))
            plt.close("all")

    def test_energy_plot_uses_seq_len_label_map_for_x_ticks(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd

        summary = pd.DataFrame(
            [
                {
                    "stage": "prefill",
                    "batch": 1,
                    "seq_len": seq_len,
                    "variant": "C1",
                    "joules_per_token": 1.0,
                    "relative_joules_per_token": 1.0,
                    "complete": True,
                }
                for seq_len in (1024, 2048)
            ]
        )

        with tempfile.TemporaryDirectory() as tmp:
            plt.close("all")
            with patch("matplotlib.pyplot.close"):
                energy_per_token._plot_summary_dataframe(
                    summary,
                    Path(tmp) / "energy.png",
                    title=None,
                    label_maps={"seq_len": {1024: "1k", 2048: "2k"}},
                    value_orders={},
                    palette=None,
                    legend_title="candidates",
                    legend_position="none",
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
                self.assertEqual(["1k", "2k"], [label.get_text() for label in plt.gcf().axes[0].get_xticklabels()])
            plt.close("all")

    def test_energy_plot_can_use_one_shared_x_axis_label(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd

        summary = pd.DataFrame(
            [
                {
                    "stage": stage,
                    "batch": batch,
                    "seq_len": 1024,
                    "variant": "C1",
                    "joules_per_token": 1.0,
                    "relative_joules_per_token": 1.0,
                    "complete": True,
                }
                for stage in ("prefill", "generation")
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
                    legend_position="none",
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
                    shared_x_label=True,
                    shared_x_label_y=0.08,
                )
                fig = plt.gcf()
                self.assertEqual(["", "", "", ""], [ax.get_xlabel() for ax in fig.axes])
                shared_labels = [text for text in fig.texts if text.get_text() == "sequence length"]
                self.assertEqual(1, len(shared_labels))
                self.assertAlmostEqual(0.08, shared_labels[0].get_position()[1])
            plt.close("all")

    def test_energy_plot_can_group_batch_axis_on_x_axis(self) -> None:
        import matplotlib.pyplot as plt
        import pandas as pd

        summary = pd.DataFrame(
            [
                {
                    "stage": stage,
                    "batch": batch,
                    "seq_len": seq_len,
                    "variant": "C1",
                    "joules_per_token": float(batch + seq_len / 1024),
                    "relative_joules_per_token": float(batch + seq_len / 1024),
                    "complete": True,
                }
                for stage in ("prefill", "generation")
                for batch in (1, 2)
                for seq_len in (512, 1024)
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
                    legend_position="none",
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
                    x_group_axis="batch",
                )
                axes = plt.gcf().axes
                self.assertEqual(2, len(axes))
                self.assertEqual(["512", "1024", "512", "1024"], [tick.get_text() for tick in axes[0].get_xticklabels()])
                self.assertEqual(["batch=1", "batch=2"], [text.get_text() for text in axes[0].texts])
                self.assertEqual(1, len(axes[0].lines))
                self.assertAlmostEqual(-0.21, axes[0].get_xlim()[0])
                self.assertAlmostEqual(4.41, axes[0].get_xlim()[1])
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
