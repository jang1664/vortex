import unittest
from tempfile import TemporaryDirectory
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pandas as pd
import plot
import prepare
from plot import EXCEL_FIGURE_DATA_CSV, _candidate_matches_kind, parse_args


class NoAreaNormE2ETests(unittest.TestCase):
    def test_no_area_norm_export_reuses_the_unscaled_in_memory_version(self) -> None:
        base = SimpleNamespace(
            composed=pd.DataFrame([{"version": "base"}]),
            plot_data=pd.DataFrame([{"version": "base"}]),
            stack_data=pd.DataFrame([{"version": "base"}]),
        )
        estimated = SimpleNamespace(
            composed=pd.DataFrame([{"version": "estimated"}]),
            plot_data=pd.DataFrame([{"version": "estimated"}]),
            stack_data=pd.DataFrame([{"version": "estimated"}]),
        )
        options = prepare.SuiteBarPlotOptions(
            raw_dbs=(),
            out_dir=Path("normalized"),
            case_latency_scale_rules=tuple(prepare.CASE_LATENCY_SCALE_RULES),
        )
        source = prepare.PlotRunResult(
            tag="llama2_7b",
            out_dir=Path("normalized"),
            suites=[],
            options=options,
            versions=SimpleNamespace(base=base, estimated=estimated),
            composed=None,
            plot_data=None,
            stack_data=None,
            figure_data=pd.DataFrame(),
        )

        with (
            patch.object(prepare, "_write_latency_figure_data", return_value=Path("figure.csv")),
            patch.object(prepare, "_read_figure_data", return_value=pd.DataFrame()),
            patch.object(prepare, "_write_total_csv"),
        ):
            result = prepare.export_no_area_norm_figure_data(
                source,
                out_name="llama2_7b_e2e_no_area_norm",
            )

        self.assertIs(result.composed, base.composed)
        self.assertIs(result.plot_data, base.plot_data)
        self.assertIs(result.stack_data, base.stack_data)
        self.assertEqual(result.options.case_latency_scale_rules, ())
        self.assertEqual(result.cache_status, "derived")

    def test_no_area_norm_export_falls_back_to_base_without_estimates(self) -> None:
        base = SimpleNamespace(
            composed=pd.DataFrame([{"version": "base"}]),
            plot_data=pd.DataFrame([{"version": "base"}]),
            stack_data=pd.DataFrame([{"version": "base"}]),
        )
        options = prepare.SuiteBarPlotOptions(
            raw_dbs=(),
            out_dir=Path("normalized"),
            case_latency_scale_rules=tuple(prepare.CASE_LATENCY_SCALE_RULES),
        )
        source = prepare.PlotRunResult(
            tag="llama2_7b",
            out_dir=Path("normalized"),
            suites=[],
            options=options,
            versions=SimpleNamespace(base=base, estimated=None),
            composed=None,
            plot_data=None,
            stack_data=None,
            figure_data=pd.DataFrame(),
        )

        with (
            patch.object(prepare, "_write_latency_figure_data", return_value=Path("figure.csv")),
            patch.object(prepare, "_read_figure_data", return_value=pd.DataFrame()),
            patch.object(prepare, "_write_total_csv"),
        ):
            result = prepare.export_no_area_norm_figure_data(
                source,
                out_name="llama2_7b_e2e_no_area_norm",
            )

        self.assertIs(result.composed, base.composed)
        self.assertIs(result.plot_data, base.plot_data)

    def test_prepare_main_derives_no_area_norm_from_rebuilt_main_data(self) -> None:
        main_result = SimpleNamespace(
            versions=SimpleNamespace(base=object(), estimated=object()),
            cache_status="rebuilt",
        )
        stacked_result = SimpleNamespace(
            versions=SimpleNamespace(base=object(), estimated=object()),
            cache_status="rebuilt",
        )
        gemm_result = SimpleNamespace(
            versions=SimpleNamespace(base=object(), estimated=object()),
            cache_status="rebuilt",
        )
        other_result = SimpleNamespace(cache_status="cache")
        derived_result = SimpleNamespace(cache_status="derived")

        with (
            patch.object(prepare, "TARGET_MODELS", ("llama2_7b",)),
            patch.object(prepare, "LATENCY_SCALE_RULES", []),
            patch.object(prepare, "ENERGY_POWER_METRICS", ()),
            patch.object(prepare, "BUILD_LLAMA_COMPARE", False),
            patch.object(Path, "is_file", return_value=True),
            patch.object(prepare.pd, "read_csv", return_value=pd.DataFrame()),
            patch.object(prepare, "_validate_prepare_composed"),
            patch.object(
                prepare,
                "load_or_export_suite_figure_data",
                side_effect=(main_result, stacked_result, other_result, gemm_result),
            ) as load_mock,
            patch.object(
                prepare,
                "export_no_area_norm_figure_data",
                return_value=derived_result,
            ) as derive_mock,
            patch.object(prepare, "figure_data_path", return_value=Path("/tmp")),
            patch.object(prepare, "total_data_path", return_value=Path("/tmp")),
        ):
            self.assertEqual(
                prepare.main(["--composed-csv", "input.csv", "--out-tokens", "128"]),
                0,
            )

        self.assertEqual(
            derive_mock.call_args_list,
            [
                unittest.mock.call(
                    main_result,
                    out_name=prepare.e2e_no_area_norm_out_name("llama2_7b"),
                ),
                unittest.mock.call(
                    stacked_result,
                    out_name=prepare.e2e_no_area_norm_stacked_out_name("llama2_7b"),
                ),
                unittest.mock.call(
                    gemm_result,
                    out_name=prepare.gemm_only_no_area_norm_out_name("llama2_7b"),
                ),
            ],
        )
        loaded_names = [item.kwargs["out_name"] for item in load_mock.call_args_list]
        self.assertNotIn(prepare.e2e_no_area_norm_out_name("llama2_7b"), loaded_names)
        self.assertNotIn(
            prepare.e2e_no_area_norm_stacked_out_name("llama2_7b"),
            loaded_names,
        )

    def test_prepare_main_loads_no_area_norm_when_main_data_is_cached(self) -> None:
        main_result = SimpleNamespace(versions=None, cache_status="cache")
        no_area_norm_result = SimpleNamespace(cache_status="cache")
        stacked_result = SimpleNamespace(versions=None, cache_status="cache")
        other_result = SimpleNamespace(cache_status="cache")

        with (
            patch.object(prepare, "TARGET_MODELS", ("llama2_7b",)),
            patch.object(prepare, "LATENCY_SCALE_RULES", []),
            patch.object(prepare, "ENERGY_POWER_METRICS", ()),
            patch.object(prepare, "BUILD_LLAMA_COMPARE", False),
            patch.object(Path, "is_file", return_value=True),
            patch.object(prepare.pd, "read_csv", return_value=pd.DataFrame()),
            patch.object(prepare, "_validate_prepare_composed"),
            patch.object(
                prepare,
                "load_or_export_suite_figure_data",
                side_effect=(
                    main_result,
                    no_area_norm_result,
                    stacked_result,
                    other_result,
                    no_area_norm_result,
                    other_result,
                    no_area_norm_result,
                ),
            ) as load_mock,
            patch.object(prepare, "export_no_area_norm_figure_data") as derive_mock,
            patch.object(prepare, "figure_data_path", return_value=Path("/tmp")),
            patch.object(prepare, "total_data_path", return_value=Path("/tmp")),
        ):
            self.assertEqual(
                prepare.main(["--composed-csv", "input.csv", "--out-tokens", "128"]),
                0,
            )

        derive_mock.assert_not_called()
        no_area_norm_call = load_mock.call_args_list[1]
        self.assertEqual(
            no_area_norm_call.kwargs["out_name"],
            prepare.e2e_no_area_norm_out_name("llama2_7b"),
        )
        self.assertEqual(no_area_norm_call.kwargs["case_latency_scale_rules"], ())
        no_area_norm_stacked_call = load_mock.call_args_list[4]
        self.assertEqual(
            no_area_norm_stacked_call.kwargs["out_name"],
            prepare.e2e_no_area_norm_stacked_out_name("llama2_7b"),
        )
        self.assertTrue(no_area_norm_stacked_call.kwargs["stacked"])
        self.assertEqual(no_area_norm_stacked_call.kwargs["stack_by"], prepare.E2E_STACK_BY)
        self.assertEqual(no_area_norm_stacked_call.kwargs["case_latency_scale_rules"], ())
        gemm_no_area_norm_call = load_mock.call_args_list[6]
        self.assertEqual(
            gemm_no_area_norm_call.kwargs["out_name"],
            prepare.gemm_only_no_area_norm_out_name("llama2_7b"),
        )
        self.assertEqual(
            gemm_no_area_norm_call.kwargs["row_filters"],
            prepare.GEMM_ONLY_FILTERS,
        )
        self.assertEqual(
            gemm_no_area_norm_call.kwargs["shape_selection"],
            prepare.GEMM_ONLY_SHAPE_SELECTION,
        )
        self.assertEqual(
            gemm_no_area_norm_call.kwargs["case_latency_scale_rules"],
            (),
        )

    def test_prepare_can_disable_case_latency_scaling(self) -> None:
        with (
            patch.object(prepare, "load_suites", return_value=[]),
            patch.object(prepare, "raw_dbs_for_model", return_value=()),
        ):
            _, options = prepare._make_suite_options(
                Path("prepared"),
                model="llama2_7b",
                suite_tag="llama2_7b",
                stacked=False,
                include_c4_alone=False,
                row_filters=None,
                shape_selection=None,
                case_latency_scale_rules=(),
            )

        self.assertEqual(options.case_latency_scale_rules, ())

    def test_raw_scale_rules_force_no_area_norm_rebuild(self) -> None:
        source = SimpleNamespace(versions=SimpleNamespace(base=object()))
        rebuilt = SimpleNamespace(cache_status="rebuilt")

        with (
            patch.object(prepare, "LATENCY_SCALE_RULES", [object()]),
            patch.object(
                prepare,
                "load_or_export_suite_figure_data",
                return_value=rebuilt,
            ) as load_mock,
            patch.object(prepare, "export_no_area_norm_figure_data") as derive_mock,
        ):
            result = prepare.load_or_export_no_area_norm_figure_data(
                source,
                model="llama2_7b",
                suite_tag="llama2_7b",
                out_name="llama2_7b_e2e_no_area_norm",
                stacked=True,
                stack_by="kind",
            )

        self.assertIs(result, rebuilt)
        derive_mock.assert_not_called()
        load_mock.assert_called_once_with(
            model="llama2_7b",
            suite_tag="llama2_7b",
            out_name="llama2_7b_e2e_no_area_norm",
            stacked=True,
            stack_by="kind",
            include_c4_alone=False,
            case_latency_scale_rules=(),
        )

    def test_no_area_norm_data_has_a_distinct_plot_kind(self) -> None:
        csv_path = (
            Path("llama2_7b_e2e_no_area_norm_prefill_b1_s1024")
            / EXCEL_FIGURE_DATA_CSV
        )

        self.assertTrue(_candidate_matches_kind(csv_path, "e2e_no_area_norm"))
        self.assertFalse(_candidate_matches_kind(csv_path, "main_all"))

    def test_no_area_norm_stacked_data_has_a_distinct_plot_kind(self) -> None:
        csv_path = (
            Path("llama2_7b_e2e_no_area_norm_stacked_by_kind_prefill_b1_s1024")
            / EXCEL_FIGURE_DATA_CSV
        )

        self.assertTrue(
            _candidate_matches_kind(csv_path, "e2e_no_area_norm_stacked")
        )
        self.assertFalse(_candidate_matches_kind(csv_path, "e2e_no_area_norm"))
        self.assertFalse(_candidate_matches_kind(csv_path, "e2e_stacked"))
        self.assertFalse(_candidate_matches_kind(csv_path, "main_all"))

    def test_gemm_only_no_area_norm_data_has_a_distinct_plot_kind(self) -> None:
        csv_path = (
            Path("llama2_7b_gemm_only_no_area_norm_prefill_b1_s1024")
            / EXCEL_FIGURE_DATA_CSV
        )

        self.assertTrue(
            _candidate_matches_kind(csv_path, "gemm_only_no_area_norm")
        )
        self.assertFalse(_candidate_matches_kind(csv_path, "gemm_only"))

    def test_gemm_only_no_area_norm_uses_existing_gemm_legend_groups(self) -> None:
        knobs = plot.PlotKnobs()

        self.assertEqual(
            knobs.llama_gemm_only_no_area_norm.stack_groups,
            knobs.llama_gemm_only.stack_groups,
        )
        self.assertEqual(
            knobs.llama_gemm_only_no_area_norm.stack_palette,
            knobs.llama_gemm_only.stack_palette,
        )

    def test_cli_accepts_gemm_only_no_area_norm_plot_and_input(self) -> None:
        args = parse_args(
            [
                "--plot",
                "llama_gemm_only_no_area_norm",
                "--out-tokens",
                "128",
                "--llama3-gemm-no-area-norm-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(args.plot, "llama_gemm_only_no_area_norm")
        self.assertEqual(args.llama3_gemm_no_area_norm_data, "llama3.csv")

    def test_flat_e2e_plots_share_the_compact_stacked_layout(self) -> None:
        knobs = plot.PlotKnobs()

        for flat in (knobs.llama_e2e, knobs.llama_e2e_no_area_norm):
            self.assertIsNone(flat.title)
            self.assertTrue(flat.subplot_title_inside)
            self.assertTrue(flat.x_group_labels_inside)
            self.assertEqual(flat.x_label, "")
            self.assertEqual(flat.figsize, knobs.llama_e2e_stacked.figsize)
            self.assertEqual(flat.row_height, knobs.llama_e2e_stacked.row_height)
            self.assertEqual(flat.tight_layout_rect, knobs.llama_e2e_stacked.tight_layout_rect)
            self.assertEqual(flat.tight_layout_h_pad, knobs.llama_e2e_stacked.tight_layout_h_pad)
            self.assertEqual(
                flat.stage_x_tick_label_rotations,
                knobs.llama_e2e_stacked.stage_x_tick_label_rotations,
            )

    def test_no_area_norm_flat_and_stacked_plots_write_png_outputs(self) -> None:
        with TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            model_csvs = []
            stacked_model_csvs = []
            for model_key, model_label in plot.LLAMA_E2E_MODELS:
                flat_csv = root / f"{model_key}_flat.csv"
                pd.DataFrame(
                    [
                        {"stage": stage, "batch": 1, "seq": "1k", "C1": 4.0, "C2": 3.0, "C3": 2.0, "C4": 1.0}
                        for stage in plot.STAGE_ORDER
                    ]
                ).to_csv(flat_csv, index=False)
                model_csvs.append((model_key, model_label, flat_csv))

                stacked_csv = root / f"{model_key}_stacked.csv"
                pd.DataFrame(
                    [
                        {
                            "stage": stage,
                            "batch": 1,
                            "seq": "1k",
                            "candidate": candidate,
                            "gemm": total * 0.75,
                            "vector": total * 0.25,
                            "total": total,
                        }
                        for stage in plot.STAGE_ORDER
                        for candidate, total in zip(plot.E2E_CANDIDATE_COLUMNS, (4.0, 3.0, 2.0, 1.0))
                    ]
                ).to_csv(stacked_csv, index=False)
                stacked_model_csvs.append((model_key, model_label, stacked_csv))

            knobs = plot.PlotKnobs()
            for plot_knobs in (
                knobs.llama_e2e_no_area_norm,
                knobs.llama_e2e_no_area_norm_stacked,
            ):
                plot_knobs.dpi = 50
                plot_knobs.save_pdf = False
                plot_knobs.save_svg = False

            plot.run_llama_e2e_no_area_norm_plot(
                model_csvs,
                root,
                knobs=knobs.llama_e2e_no_area_norm,
            )
            plot.run_llama_e2e_no_area_norm_stacked_plot(
                stacked_model_csvs,
                root,
                knobs=knobs.llama_e2e_no_area_norm_stacked,
            )

            self.assertTrue(
                (root / "llama_e2e_no_area_norm" / "llama_e2e_latency_no_area_norm.png").is_file()
            )
            self.assertTrue(
                (
                    root
                    / "llama_e2e_no_area_norm_stacked"
                    / "llama_e2e_latency_no_area_norm_stacked.png"
                ).is_file()
            )

    def test_cli_accepts_no_area_norm_llama_inputs(self) -> None:
        args = parse_args(
            [
                "--plot",
                "llama_e2e_no_area_norm",
                "--out-tokens",
                "128",
                "--llama2-no-area-norm-data",
                "llama2.csv",
                "--llama3-no-area-norm-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(args.plot, "llama_e2e_no_area_norm")
        self.assertEqual(args.llama2_no_area_norm_data, "llama2.csv")
        self.assertEqual(args.llama3_no_area_norm_data, "llama3.csv")

    def test_cli_accepts_no_area_norm_stacked_llama_inputs(self) -> None:
        args = parse_args(
            [
                "--plot",
                "llama_e2e_no_area_norm_stacked",
                "--out-tokens",
                "128",
                "--llama2-no-area-norm-stacked-data",
                "llama2.csv",
                "--llama3-no-area-norm-stacked-data",
                "llama3.csv",
            ]
        )

        self.assertEqual(args.plot, "llama_e2e_no_area_norm_stacked")
        self.assertEqual(args.llama2_no_area_norm_stacked_data, "llama2.csv")
        self.assertEqual(args.llama3_no_area_norm_stacked_data, "llama3.csv")

    def test_optional_llama_model_plot_runs_with_collected_data(self) -> None:
        model_csvs = [
            ("llama2_7b", "Llama 2", Path("llama2.csv")),
            ("llama3_8b", "Llama 3", Path("llama3.csv")),
        ]
        knobs = plot.WideBarKnobs()
        runner = unittest.mock.Mock()

        with patch.object(plot, "collect_model_csvs", return_value=model_csvs) as collect_mock:
            plot.run_optional_llama_model_plot(
                selected_plot="llama_e2e_no_area_norm",
                plot_name="llama_e2e_no_area_norm",
                explicit_by_model={"llama2_7b": None, "llama3_8b": None},
                prepared_root=Path("prepared"),
                latency_dir=Path("latency"),
                output_root=Path("output"),
                kind="e2e_no_area_norm",
                label="E2E without area normalization",
                knobs=knobs,
                runner=runner,
            )

        collect_mock.assert_called_once()
        runner.assert_called_once_with(model_csvs, Path("output"), knobs=knobs)

    def test_optional_llama_model_plot_reraises_missing_required_data(self) -> None:
        with (
            patch.object(
                plot,
                "collect_model_csvs",
                side_effect=FileNotFoundError("missing prepared data"),
            ),
            self.assertRaisesRegex(FileNotFoundError, "missing prepared data"),
        ):
            plot.run_optional_llama_model_plot(
                selected_plot="llama_e2e_no_area_norm",
                plot_name="llama_e2e_no_area_norm",
                explicit_by_model={"llama2_7b": None, "llama3_8b": None},
                prepared_root=Path("prepared"),
                latency_dir=Path("latency"),
                output_root=Path("output"),
                kind="e2e_no_area_norm",
                label="E2E without area normalization",
                knobs=plot.WideBarKnobs(),
                runner=unittest.mock.Mock(),
            )

    def test_optional_llama_model_plot_skips_missing_optional_data(self) -> None:
        runner = unittest.mock.Mock()
        with (
            patch.object(
                plot,
                "collect_model_csvs",
                side_effect=FileNotFoundError("missing prepared data"),
            ),
            patch("builtins.print") as print_mock,
        ):
            plot.run_optional_llama_model_plot(
                selected_plot="all",
                plot_name="llama_e2e_no_area_norm",
                explicit_by_model={"llama2_7b": None, "llama3_8b": None},
                prepared_root=Path("prepared"),
                latency_dir=Path("latency"),
                output_root=Path("output"),
                kind="e2e_no_area_norm",
                label="E2E without area normalization",
                knobs=plot.WideBarKnobs(),
                runner=runner,
            )

        runner.assert_not_called()
        print_mock.assert_called_once_with(
            "skip llama_e2e_no_area_norm: missing prepared data"
        )

    def test_selected_no_area_norm_plot_dispatches_to_optional_model_runner(self) -> None:
        args = parse_args(
            [
                "--plot",
                "llama_e2e_no_area_norm",
                "--out-tokens",
                "128",
                "--latency-dir",
                "/latency",
                "--llama2-no-area-norm-data",
                "llama2.csv",
                "--llama3-no-area-norm-data",
                "llama3.csv",
            ]
        )

        with (
            patch.object(Path, "mkdir"),
            patch.object(plot, "run_optional_llama_model_plot") as run_mock,
        ):
            plot.run_selected_plots(args)

        call_args = run_mock.call_args.kwargs
        self.assertEqual(call_args["plot_name"], "llama_e2e_no_area_norm")
        self.assertEqual(call_args["kind"], "e2e_no_area_norm")
        self.assertEqual(
            call_args["explicit_by_model"],
            {"llama2_7b": "llama2.csv", "llama3_8b": "llama3.csv"},
        )
        self.assertIs(call_args["runner"], plot.run_llama_e2e_no_area_norm_plot)

    def test_selected_no_area_norm_stacked_plot_dispatches_to_optional_model_runner(self) -> None:
        args = parse_args(
            [
                "--plot",
                "llama_e2e_no_area_norm_stacked",
                "--out-tokens",
                "128",
                "--latency-dir",
                "/latency",
                "--llama2-no-area-norm-stacked-data",
                "llama2.csv",
                "--llama3-no-area-norm-stacked-data",
                "llama3.csv",
            ]
        )

        with (
            patch.object(Path, "mkdir"),
            patch.object(plot, "run_optional_llama_model_plot") as run_mock,
        ):
            plot.run_selected_plots(args)

        call_args = run_mock.call_args.kwargs
        self.assertEqual(call_args["plot_name"], "llama_e2e_no_area_norm_stacked")
        self.assertEqual(call_args["kind"], "e2e_no_area_norm_stacked")
        self.assertEqual(
            call_args["explicit_by_model"],
            {"llama2_7b": "llama2.csv", "llama3_8b": "llama3.csv"},
        )
        self.assertIs(
            call_args["runner"],
            plot.run_llama_e2e_no_area_norm_stacked_plot,
        )


if __name__ == "__main__":
    unittest.main()
