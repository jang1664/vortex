from __future__ import annotations

import csv
import importlib.util
import argparse
import sys
import tempfile
import unittest
from pathlib import Path

import yaml


MODULE_PATH = Path(__file__).with_name("measure_power.py")
SPEC = importlib.util.spec_from_file_location("measure_power", MODULE_PATH)
measure_power = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = measure_power
SPEC.loader.exec_module(measure_power)


class MeasurePowerTest(unittest.TestCase):
    def test_build_case_plan_generates_ten_shapes_per_selected_app(self) -> None:
        cases, skipped = measure_power.build_case_plan(
            ["eladd", "sgemm_tcu"],
            app_regex="^(eladd|sgemm_tcu)$",
        )

        self.assertEqual([], skipped)
        self.assertEqual(20, len(cases))
        self.assertEqual(list(range(10)), [case.shape_rank for case in cases if case.app == "eladd"])
        self.assertEqual(list(range(10)), [case.shape_rank for case in cases if case.app == "sgemm_tcu"])
        self.assertEqual("s00", cases[0].shape_id)
        self.assertIn("-n ", cases[0].args)
        self.assertRegex(cases[-1].args, r"-m \d+ -n \d+ -k \d+")

    def test_regex_filters_apps_shapes_and_case_ids(self) -> None:
        cases, skipped = measure_power.build_case_plan(
            ["eladd", "elmul", "softmax"],
            app_regex=r"^el(add|mul)$",
            shape_regex=r"^s0[89]$",
            case_regex=r"el(add|mul)_s0[89]",
        )

        self.assertEqual([], skipped)
        self.assertEqual(["eladd_s08", "eladd_s09", "elmul_s08", "elmul_s09"], [case.case_id for case in cases])

    def test_write_suite_and_build_command(self) -> None:
        cases, _ = measure_power.build_case_plan(["eladd"], shape_regex=r"^s0[01]$")

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            suite_path = tmp_path / "suite.yaml"
            out_dir = tmp_path / "out"
            measure_power.write_suite(
                suite_path=suite_path,
                suite_name="power_sweep_test",
                cases=cases,
                fpga_bin="naive_simd",
                platform="test_platform",
                warmup=0,
                iterations=1,
            )
            suite = yaml.safe_load(suite_path.read_text())

            self.assertEqual("power_sweep_test", suite["name"])
            self.assertEqual("naive_simd", suite["defaults"]["fpga_bin"])
            self.assertNotIn("blackbox_args", suite["defaults"])
            self.assertEqual(["eladd_s00", "eladd_s01"], [case["id"] for case in suite["cases"]])
            self.assertEqual("s00", suite["cases"][0]["shape"]["shape_id"])

            command = measure_power.build_run_command(
                python_bin="python3",
                build_dir=Path("build"),
                suite_path=suite_path,
                out_dir=out_dir,
                fpga_bin="naive_simd",
                run_id="run123",
                warmup=0,
                iterations=1,
                power_auto_duration=False,
                power_measure_latency=True,
                power_min_run_sec=3.0,
                power_max_run_sec=30.0,
                power_target_samples=50,
                power_max_iterations=7,
                power_min_samples=5,
                power_min_interval=0.02,
                power_max_interval=0.5,
                blackbox_timeout="12h",
                retry=True,
                retry_max_rounds=4,
                no_srun=False,
                no_program_fpga=False,
                xrt_device_bdf="",
                configs_extra="",
                extra_run_args=(),
            )

            self.assertIn("--no-latency", command)
            self.assertIn("--power", command)
            self.assertIn("--no-power-auto-duration", command)
            self.assertIn("--power-measure-latency", command)
            self.assertNotIn("--power-auto-duration", command)
            self.assertNotIn("--power-min-run-sec", command)
            self.assertIn("--skip-existing", command)
            self.assertIn("--retry", command)
            self.assertIn("--retry-max-rounds", command)
            self.assertIn("4", command)
            self.assertEqual("1", command[command.index("--iterations") + 1])
            self.assertEqual(str(suite_path), command[command.index("--suite") + 1])
            self.assertEqual(str(out_dir), command[command.index("--out") + 1])
            self.assertEqual("run123", command[command.index("--run-id") + 1])

    def test_build_command_can_enable_auto_duration_and_disable_power_latency(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            command = measure_power.build_run_command(
                python_bin="python3",
                build_dir=Path("build"),
                suite_path=tmp_path / "suite.yaml",
                out_dir=tmp_path / "out",
                fpga_bin="naive_simd",
                run_id=None,
                warmup=0,
                iterations=1,
                power_auto_duration=True,
                power_measure_latency=False,
                power_min_run_sec=3.0,
                power_max_run_sec=30.0,
                power_target_samples=50,
                power_max_iterations=7,
                power_min_samples=5,
                power_min_interval=0.02,
                power_max_interval=0.5,
                blackbox_timeout="12h",
                retry=False,
                retry_max_rounds=4,
                no_srun=False,
                no_program_fpga=False,
                xrt_device_bdf="",
                configs_extra="",
                extra_run_args=(),
            )

            self.assertIn("--power-auto-duration", command)
            self.assertIn("--power-min-run-sec", command)
            self.assertIn("--power-max-iterations", command)
            self.assertIn("--no-power-measure-latency", command)
            self.assertNotIn("--no-power-auto-duration", command)
            self.assertNotIn("--power-measure-latency", command)

    def test_write_suite_leaves_blackbox_args_empty_by_default(self) -> None:
        cases, _ = measure_power.build_case_plan(["eladd"], shape_regex=r"^s00$")

        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            measure_power.write_suite(
                suite_path=suite_path,
                suite_name="power_sweep_test",
                cases=cases,
                fpga_bin="naive_simd",
                platform="test_platform",
                warmup=0,
                iterations=1,
            )
            suite = yaml.safe_load(suite_path.read_text())

            self.assertNotIn("blackbox_args", suite["defaults"])

    def test_normalize_path_args_resolves_user_paths_against_invocation_cwd(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            cwd = Path(tmp)
            args = argparse.Namespace(
                regression_root=Path("tests/regression"),
                generated_root=Path("power_measure_suites_generated"),
                out=Path("outputs_power"),
                build_dir=Path("../../build"),
            )

            measure_power.normalize_path_args(args, cwd=cwd)

            self.assertEqual(cwd / "tests/regression", args.regression_root)
            self.assertEqual(cwd / "power_measure_suites_generated", args.generated_root)
            self.assertEqual(cwd / "outputs_power", args.out)
            self.assertEqual((cwd / "../../build").resolve(), args.build_dir)

    def test_write_power_summary_preserves_low_sample_failures(self) -> None:
        cases, _ = measure_power.build_case_plan(["eladd"], shape_regex=r"^s0[01]$")

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            raw_db = tmp_path / "raw_db.csv"
            summary_csv = tmp_path / "summary.csv"
            with raw_db.open("w", newline="") as fp:
                writer = csv.DictWriter(
                    fp,
                    fieldnames=[
                        "case_id",
                        "app",
                        "args",
                        "status",
                        "failure_reason",
                        "power_samples",
                        "power_avg_w",
                        "power_min_w",
                        "power_max_w",
                    ],
                )
                writer.writeheader()
                writer.writerow(
                    {
                        "case_id": "eladd_s00",
                        "app": "eladd",
                        "args": cases[0].args,
                        "status": "fail",
                        "failure_reason": "power_samples_low",
                        "power_samples": "2",
                        "power_avg_w": "",
                        "power_min_w": "",
                        "power_max_w": "",
                    }
                )
                writer.writerow(
                    {
                        "case_id": "eladd_s01",
                        "app": "eladd",
                        "args": cases[1].args,
                        "status": "pass",
                        "failure_reason": "",
                        "power_samples": "20",
                        "power_avg_w": "35.5",
                        "power_min_w": "34.0",
                        "power_max_w": "37.0",
                    }
                )

            rows = measure_power.write_power_summary(
                raw_db=raw_db,
                summary_csv=summary_csv,
                planned_cases=cases,
            )

            self.assertEqual(2, len(rows))
            self.assertTrue(summary_csv.exists())
            self.assertEqual("power_samples_low", rows[0]["failure_reason"])
            self.assertEqual("pass", rows[1]["status"])
            self.assertEqual("1", rows[1]["shape_rank"])
            self.assertEqual("35.5", rows[1]["power_avg_w"])


if __name__ == "__main__":
    unittest.main()
