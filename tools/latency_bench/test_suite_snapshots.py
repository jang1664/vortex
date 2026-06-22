from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from tools.latency_bench.runner import RunOptions, run_suite
from tools.latency_bench.suite import find_repo_root, load_suite


class SuiteSnapshotTest(unittest.TestCase):
    def test_cli_overrides_replace_explicit_case_warmup_and_iterations(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: explicit_case_counts
defaults:
  warmup: 1
  iterations: 3
cases:
  - id: explicit_counts
    app: eladd
    args: "-n 128"
    warmup: 11
    iterations: 13
""".lstrip()
            )

            suite = load_suite(
                suite_path,
                repo_root=find_repo_root(),
                warmup_override=0,
                iterations_override=1,
            )

            self.assertEqual(0, suite.defaults.warmup)
            self.assertEqual(1, suite.defaults.iterations)
            self.assertEqual(0, suite.cases[0].warmup)
            self.assertEqual(1, suite.cases[0].iterations)

    def test_dry_run_writes_original_and_expanded_suite_yaml(self) -> None:
        repo_root = find_repo_root()
        suite_path = repo_root / "tools" / "latency_bench" / "suites" / "llama2_7b_prefill_s1024_b8.yaml"

        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            build_dir = tmp_path / "build"
            (build_dir / "ci").mkdir(parents=True)
            (build_dir / "ci" / "blackbox.sh").write_text("#!/usr/bin/env bash\n")

            suite = load_suite(suite_path, repo_root=repo_root, warmup_override=5, iterations_override=7)
            out_dir = tmp_path / "out"
            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=tmp_path / "fpga_bin",
                    out_dir=out_dir,
                    platform=suite.defaults.platform,
                    xrt_device_index=suite.defaults.xrt_device_index,
                    blackbox_args=suite.defaults.blackbox_args,
                    dry_run=True,
                    run_id="dry_run_1",
                ),
            )

            run_dir = out_dir / "runs" / "dry_run_1"
            self.assertEqual(0, rc)
            self.assertEqual(suite_path.read_text(), (run_dir / "suite.yaml").read_text())
            self.assertFalse((out_dir / "raw_db.csv").exists())

            expanded = yaml.safe_load((run_dir / "suite.expanded.yaml").read_text())
            self.assertEqual("llama2_7b_prefill_s1024_b8", expanded["name"])
            self.assertNotIn("workloads", expanded)
            self.assertGreater(len(expanded["cases"]), 0)
            self.assertEqual(5, expanded["defaults"]["warmup"])
            self.assertEqual(7, expanded["defaults"]["iterations"])
            self.assertTrue(all("args" in case for case in expanded["cases"]))
            self.assertTrue(all(case["warmup"] == 5 for case in expanded["cases"]))
            self.assertTrue(all(case["iterations"] == 7 for case in expanded["cases"]))


if __name__ == "__main__":
    unittest.main()
