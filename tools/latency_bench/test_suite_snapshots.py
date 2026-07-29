from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

from tools.latency_bench.runner import RunOptions, run_suite
from tools.latency_bench.suite import apply_case_filters, find_repo_root, load_suite


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
            script = run_dir / "run_fpga_bench.sh"
            self.assertEqual(0, rc)
            subprocess.run(["bash", "-n", str(script)], check=True)
            self.assertEqual(suite_path.read_text(), (run_dir / "suite.yaml").read_text())
            self.assertFalse((out_dir / "raw_db.csv").exists())

            script_text = script.read_text()
            self.assertIn("latency_bench_start_case_progress", script_text)
            self.assertIn("LATENCY_BENCH_CASE_PROGRESS_INTERVAL=10", script_text)
            self.assertIn("LATENCY_BENCH_STREAM_CASE_LOGS=0", script_text)
            self.assertIn("2>&1 | tee -a", script_text)
            self.assertIn(" >/dev/null", script_text)

            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertFalse(manifest["stream_case_logs"])
            self.assertTrue(manifest["case_progress"])
            self.assertEqual(10, manifest["case_progress_interval"])

            expanded = yaml.safe_load((run_dir / "suite.expanded.yaml").read_text())
            self.assertEqual("llama2_7b_prefill_s1024_b8", expanded["name"])
            self.assertNotIn("workloads", expanded)
            self.assertGreater(len(expanded["cases"]), 0)
            self.assertEqual(5, expanded["defaults"]["warmup"])
            self.assertEqual(7, expanded["defaults"]["iterations"])
            self.assertTrue(all("args" in case for case in expanded["cases"]))
            self.assertTrue(all(case["warmup"] == 5 for case in expanded["cases"]))
            self.assertTrue(all(case["iterations"] == 7 for case in expanded["cases"]))

    def test_explicit_suite_snapshot_uses_streaming_override_rewrite(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            suite_path = tmp_path / "explicit.yaml"
            suite_path.write_text(
                """
name: explicit
defaults:
  warmup: 1
  iterations: 3
cases:
- id: add_a
  app: eladd
  args: -n 16
  warmup: 1
  iterations: 3
- id: add_b
  app: eladd
  args: -n 32
  warmup: 1
  iterations: 3
""".lstrip()
            )
            build_dir = tmp_path / "build"
            (build_dir / "ci").mkdir(parents=True)
            (build_dir / "ci" / "blackbox.sh").write_text("#!/usr/bin/env bash\n")
            suite = load_suite(suite_path, warmup_override=0, iterations_override=1)
            self.assertTrue(suite.source_expanded_snapshot_reusable)

            out_dir = tmp_path / "out"
            rc = run_suite(
                suite,
                RunOptions(
                    build_dir=build_dir,
                    fpga_bin_dir=tmp_path / "fpga_bin",
                    out_dir=out_dir,
                    platform=suite.defaults.platform,
                    dry_run=True,
                    run_id="explicit_run",
                ),
            )

            self.assertEqual(0, rc)
            run_dir = out_dir / "runs" / "explicit_run"
            expanded = yaml.safe_load((run_dir / "suite.expanded.yaml").read_text())
            self.assertEqual(0, expanded["defaults"]["warmup"])
            self.assertEqual(1, expanded["defaults"]["iterations"])
            self.assertTrue(all(case["warmup"] == 0 for case in expanded["cases"]))
            self.assertTrue(all(case["iterations"] == 1 for case in expanded["cases"]))
            manifest = json.loads((run_dir / "manifest.json").read_text())
            self.assertEqual("explicit_stream_rewrite", manifest["suite_expanded_snapshot_mode"])

            filtered = apply_case_filters(suite, ("case_id=add_a",))
            self.assertFalse(filtered.source_expanded_snapshot_reusable)


if __name__ == "__main__":
    unittest.main()
