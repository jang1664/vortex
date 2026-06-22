from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import yaml

from tools.latency_bench.generate_suites import GenerateSuitesOptions, generate_suites
from tools.latency_bench.suite import load_suite


class GenerateSuitesTest(unittest.TestCase):
    def test_workload_matrix_supports_values_and_pow_alias(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: workload_matrix
workloads:
  - id: rmsnorm
    model: llama2-7b
    stage: prefill
    filter_kind: rmsnorm
    implemented_only: true
    matrix:
      batch: {values: [1, 2]}
      prefill_seq_len: {pow: [128, 256]}
      qblk: 32
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())

            shape_pairs = {
                (case.shape.get("batch"), case.shape.get("seq"))
                for case in suite.cases
                if case.kind == "rmsnorm"
            }
            self.assertEqual({(1, 128), (1, 256), (2, 128), (2, 256)}, shape_pairs)
            self.assertEqual(len(suite.cases), len({case.case_id for case in suite.cases}))

    def test_generate_suites_groups_expanded_cases_by_app_and_fpga_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            suite_path = tmp_path / "base.yaml"
            suite_path.write_text(
                """
name: auto_base
defaults:
  warmup: 1
  iterations: 2
  app: fpint_gemm_ffn_hw
fpga_bins:
  default: default_alias
  by_backend:
    fpint_gemm_improve: backend_alias
  by_kind:
    gemm: kind_alias
  by_app:
    silu: app_alias
case_matrices:
  - id: gemm
    app: fpint_gemm_ffn_hw
    kind: gemm
    backend: fpint_gemm_improve
    stage: sweep
    name: gemm_m{m}
    args: "-m {m} -n 128 -k 128 -q 32 -t 0 -d 0"
    matrix:
      m: {pow: [1, 2]}
cases:
  - id: silu_by_app
    app: silu
    kind: silu
    args: "-n 128"
  - id: silu_explicit
    app: silu
    kind: silu
    fpga_bin: explicit_alias
    args: "-n 256"
  - id: rope_default
    app: rope
    kind: rope
    args: "-batch 1 -seq 128 -offset 0"
""".lstrip()
            )
            out_dir = tmp_path / "generated"

            index = generate_suites(GenerateSuitesOptions(suite=suite_path, out_dir=out_dir))

            self.assertEqual(index, yaml.safe_load((out_dir / "index.yaml").read_text()))
            entries = {(entry["app"], entry["fpga_bin"]): entry for entry in index["generated"]}
            self.assertEqual(
                {
                    ("fpint_gemm_ffn_hw", "backend_alias"),
                    ("silu", "app_alias"),
                    ("silu", "explicit_alias"),
                    ("rope", "default_alias"),
                },
                set(entries),
            )
            self.assertEqual(2, entries[("fpint_gemm_ffn_hw", "backend_alias")]["case_count"])
            self.assertEqual(["gemm"], entries[("fpint_gemm_ffn_hw", "backend_alias")]["kinds"])
            self.assertEqual(["fpint_gemm_improve"], entries[("fpint_gemm_ffn_hw", "backend_alias")]["backends"])

            gemm_suite = yaml.safe_load(Path(entries[("fpint_gemm_ffn_hw", "backend_alias")]["suite"]).read_text())
            self.assertEqual("backend_alias", gemm_suite["defaults"]["fpga_bin"])
            self.assertEqual(["gemm_m1", "gemm_m2"], [case["id"] for case in gemm_suite["cases"]])
            self.assertNotIn("case_matrices", gemm_suite)
            self.assertNotIn("workloads", gemm_suite)

            explicit_suite = yaml.safe_load(Path(entries[("silu", "explicit_alias")]["suite"]).read_text())
            self.assertEqual("explicit_alias", explicit_suite["defaults"]["fpga_bin"])
            self.assertEqual(["silu_explicit"], [case["id"] for case in explicit_suite["cases"]])
            self.assertNotIn("fpga_bin", explicit_suite["cases"][0])


if __name__ == "__main__":
    unittest.main()
