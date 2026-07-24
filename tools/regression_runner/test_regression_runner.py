from __future__ import annotations

import contextlib
import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.regression_runner.backends import Backend, BackendContext, HwBackend
from tools.regression_runner.discovery import (
    discover_tests,
    expand_cases,
    filter_tests,
    parse_case_spec,
)
from tools.regression_runner.models import RegressionCase
from tools.regression_runner.models import CaseResult
from tools.regression_runner.reporting import render_table, write_results
from tools.regression_runner.runner import (
    create_manifest,
    parse_duration,
    run_controller,
    run_worker,
)


class FakeBackend(Backend):
    name = "fake"

    def validate(self, context: BackendContext) -> None:
        return None

    def case_command(self, context: BackendContext, case: RegressionCase) -> list[str]:
        if case.args == "pass":
            code = "print('passed')"
        elif case.args == "fail":
            code = "print('failed'); raise SystemExit(7)"
        elif case.args == "sleep":
            code = "import time; time.sleep(2)"
        else:
            code = "raise SystemExit(9)"
        return [sys.executable, "-c", code]

    def allocation_command(self, manifest_path: Path) -> list[str]:
        return ["srun", "fake-worker", str(manifest_path)]


def make_test(repo: Path, name: str, *, main: bool = True) -> None:
    directory = repo / "tests" / "regression" / name
    directory.mkdir(parents=True)
    (directory / "Makefile").write_text("all:\n\t@true\n")
    if main:
        (directory / "main.cpp").write_text("int main() { return 0; }\n")


class DiscoveryTest(unittest.TestCase):
    def test_discovers_nested_functional_tests_only(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            make_test(repo, "alpha")
            make_test(repo, "deprecated/beta")
            make_test(repo, "bench_only", main=False)
            (repo / "tests" / "regression" / "Makefile").write_text("all:\n\t@true\n")

            self.assertEqual(["alpha", "deprecated/beta"], discover_tests(repo))

    def test_expands_ordered_pairs_and_deduplicates(self) -> None:
        tests = ["eladd", "elmul", "rope", "rope_layout_fused"]
        specs = [
            parse_case_spec(r"^el::first"),
            parse_case_spec(r"^eladd$::first"),
            parse_case_spec(r"^eladd$::second"),
            parse_case_spec(r"rope::"),
        ]
        cases = expand_cases(tests, specs, [r"layout_fused"])

        self.assertEqual(
            [
                ("eladd", "first"),
                ("elmul", "first"),
                ("eladd", "second"),
                ("rope", ""),
            ],
            [(case.test, case.args) for case in cases],
        )
        self.assertEqual([1, 2, 3, 4], [case.order for case in cases])
        self.assertEqual(4, len({case.case_id for case in cases}))

    def test_reports_invalid_or_empty_selection(self) -> None:
        with self.assertRaisesRegex(ValueError, "expected REGEX::ARGS"):
            parse_case_spec("eladd")
        with self.assertRaisesRegex(ValueError, "matched no tests"):
            expand_cases(["eladd"], [parse_case_spec("rope::")])
        with self.assertRaisesRegex(ValueError, "all selected"):
            expand_cases(["eladd"], [parse_case_spec("eladd::")], ["eladd"])

    def test_filters_list_output(self) -> None:
        tests = ["eladd", "elmul", "rope", "rope_layout_fused"]
        self.assertEqual(
            ["rope"],
            filter_tests(tests, include_patterns=["rope"], exclude_patterns=["layout"]),
        )


class BackendTest(unittest.TestCase):
    def test_hw_command_uses_configured_wrapper(self) -> None:
        backend = HwBackend()
        context = BackendContext(
            repo_root=Path("/repo"),
            build_dir=Path("/repo/build"),
            fpga_alias="C1",
        )
        case = RegressionCase(1, "id", "deprecated/example", "-n 8")
        self.assertEqual(
            [
                "/repo/build/ci/run_black.sh",
                "hw",
                "--no-srun",
                "--fpga-bin",
                "C1",
                "--app",
                "deprecated/example",
                "--args",
                "-n 8",
            ],
            backend.case_command(context, case),
        )

    def test_duration_parser(self) -> None:
        self.assertEqual(30.0, parse_duration("30s"))
        self.assertEqual(120.0, parse_duration("2m"))
        self.assertEqual(3600.0, parse_duration("1h"))
        with self.assertRaises(ValueError):
            parse_duration("0")


class RunnerTest(unittest.TestCase):
    def _manifest(
        self,
        root: Path,
        cases: list[RegressionCase],
        *,
        timeout: float = 1.0,
    ) -> Path:
        run_dir = root / "run"
        run_dir.mkdir()
        (run_dir / "logs").mkdir()
        build_dir = root / "build"
        build_dir.mkdir()
        manifest = create_manifest(
            run_dir=run_dir,
            repo_root=root,
            build_dir=build_dir,
            backend="fake",
            fpga_alias="alias",
            timeout_sec=timeout,
            verbose=False,
            cases=cases,
            argv=["run"],
        )
        path = run_dir / "manifest.json"
        path.write_text(json.dumps(manifest))
        return path

    def test_worker_continues_after_failure_and_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = [
                RegressionCase(1, "pass", "pass_test", "pass"),
                RegressionCase(2, "fail", "fail_test", "fail"),
                RegressionCase(3, "timeout", "timeout_test", "sleep"),
                RegressionCase(4, "after", "after_test", "pass"),
            ]
            manifest = self._manifest(root, cases, timeout=0.1)
            with contextlib.redirect_stdout(io.StringIO()):
                returncode = run_worker(manifest, backend_override=FakeBackend())

            self.assertEqual(1, returncode)
            payload = json.loads((manifest.parent / "results.json").read_text())
            self.assertEqual(
                ["PASS", "FAIL", "TIMEOUT", "PASS"],
                [item["status"] for item in payload["results"]],
            )
            self.assertEqual(7, payload["results"][1]["returncode"])
            self.assertEqual(4, len(list((manifest.parent / "logs").glob("*.log"))))

    def test_controller_uses_one_srun_for_all_cases(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = self._manifest(
                root,
                [
                    RegressionCase(1, "one", "one", "pass"),
                    RegressionCase(2, "two", "two", "pass"),
                ],
            )
            completed = subprocess.CompletedProcess(["srun"], 0)
            with mock.patch(
                "tools.regression_runner.runner.subprocess.run",
                return_value=completed,
            ) as run_mock:
                returncode = run_controller(
                    manifest_path=manifest,
                    backend=FakeBackend(),
                    no_srun=False,
                    env={},
                )

            self.assertEqual(0, returncode)
            run_mock.assert_called_once()
            command = run_mock.call_args.args[0]
            self.assertEqual(["srun", "fake-worker", str(manifest)], command)

    def test_table_handles_unicode_and_long_values(self) -> None:
        table = render_table(
            ["test", "args"],
            [["café", "-n " + "1" * 100]],
            limits={1: 12},
        )
        self.assertIn("café", table)
        self.assertIn("…", table)
        self.assertIn("+======+", table)

    def test_result_artifacts_round_trip_special_arguments(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            manifest = {
                "run_id": "run",
                "backend": "fake",
                "fpga_alias": "alias",
            }
            result = CaseResult(
                order=1,
                case_id="case",
                test="test",
                args='--name "a,b" --label café',
                backend="fake",
                fpga_alias="alias",
                status="PASS",
                returncode=0,
                started_at="start",
                ended_at="end",
                duration_sec=1.25,
                log="case.log",
            )

            write_results(run_dir, manifest, [result])

            with (run_dir / "results.csv").open(newline="") as stream:
                csv_rows = list(csv.DictReader(stream))
            json_rows = json.loads((run_dir / "results.json").read_text())["results"]
            self.assertEqual(result.args, csv_rows[0]["args"])
            self.assertEqual(result.args, json_rows[0]["args"])


if __name__ == "__main__":
    unittest.main()
