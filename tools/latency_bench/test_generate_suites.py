from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import yaml

from tools.latency_bench.cli import main
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
            self.assertFalse((out_dir / "model_structure.json").exists())
            self.assertFalse((out_dir / "model_structure.layout").exists())
            self.assertFalse((out_dir / "model_structure.text").exists())
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

    def test_generate_suites_cli_overrides_workload_batch_and_seq_lists(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            suite_path = tmp_path / "suite.yaml"
            suite_path.write_text(
                """
name: override_workload_matrix
defaults:
  warmup: 1
  iterations: 1
  fpga_bin: test_bin
fpga_bins:
  default: test_bin
workloads:
  - id: softmax
    model: llama2-7b
    stage: all
    filter_kind: softmax
    implemented_only: true
    matrix:
      batch: {values: [1, 2]}
      prefill_seq_len: {values: [32]}
      gen_kv_len: {values: [64]}
      qblk: 32
""".lstrip()
            )
            out_dir = tmp_path / "generated"

            rc = main([
                "generate-suites",
                "--suite", str(suite_path),
                "--out", str(out_dir),
                "--batches", "3",
                "--seq-lens", "128,256",
            ])

            self.assertEqual(0, rc)
            index = yaml.safe_load((out_dir / "index.yaml").read_text())
            self.assertEqual(1, len(index["generated"]))
            generated = yaml.safe_load(Path(index["generated"][0]["suite"]).read_text())
            cases = generated["cases"]
            self.assertEqual({3}, {case["shape"]["batch"] for case in cases})
            self.assertEqual(
                {128, 256},
                {case["shape"]["seqq"] for case in cases if case["stage"] == "prefill"},
            )
            self.assertEqual(
                {128, 256},
                {case["shape"]["seqk"] for case in cases if case["stage"] == "generation"},
            )

    def test_generate_suites_cli_overrides_prefill_and_generation_separately(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            suite_path = tmp_path / "suite.yaml"
            suite_path.write_text(
                """
name: split_override_workload_matrix
defaults:
  warmup: 1
  iterations: 1
  fpga_bin: test_bin
fpga_bins:
  default: test_bin
workloads:
  - id: softmax
    model: llama2-7b
    stage: all
    filter_kind: softmax
    implemented_only: true
    matrix:
      batch: {values: [1]}
      prefill_seq_len: {values: [32]}
      gen_kv_len: {values: [64]}
      qblk: 32
""".lstrip()
            )
            out_dir = tmp_path / "generated"

            rc = main([
                "generate-suites",
                "--suite", str(suite_path),
                "--out", str(out_dir),
                "--prefill-batches", "2",
                "--generation-batches", "4",
                "--prefill-seq-lens", "128",
                "--generation-seq-lens", "512",
            ])

            self.assertEqual(0, rc)
            index = yaml.safe_load((out_dir / "index.yaml").read_text())
            generated = yaml.safe_load(Path(index["generated"][0]["suite"]).read_text())
            cases = generated["cases"]
            self.assertEqual(2, len(cases))
            prefill = [case for case in cases if case["stage"] == "prefill"]
            generation = [case for case in cases if case["stage"] == "generation"]
            self.assertEqual(1, len(prefill))
            self.assertEqual(1, len(generation))
            self.assertEqual(2, prefill[0]["shape"]["batch"])
            self.assertEqual(128, prefill[0]["shape"]["seqq"])
            self.assertEqual(128, prefill[0]["shape"]["seqk"])
            self.assertEqual(4, generation[0]["shape"]["batch"])
            self.assertEqual(1, generation[0]["shape"]["seqq"])
            self.assertEqual(512, generation[0]["shape"]["seqk"])

    def test_generate_suites_dumps_all_workload_model_structures(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            suite_path = tmp_path / "suite.yaml"
            suite_path.write_text(
                """
name: dumped_workload_structures
defaults:
  warmup: 1
  iterations: 1
  fpga_bin: test_bin
fpga_bins:
  default: test_bin
workloads:
  - id: softmax
    model: llama2-7b
    stage: prefill
    variant: all_sgemm_tcu
    implemented_only: false
    matrix:
      batch: {values: [1]}
      prefill_seq_len: {values: [32, 64]}
      qblk: 32
""".lstrip()
            )
            out_dir = tmp_path / "generated"

            rc = main([
                "generate-suites",
                "--suite", str(suite_path),
                "--out", str(out_dir),
                "--dump-model-structures",
            ])
            self.assertEqual(0, rc)

            json_path = out_dir / "model_structure.json"
            layout_path = out_dir / "model_structure.layout"
            text_path = out_dir / "model_structure.text"
            self.assertTrue(json_path.is_file())
            self.assertTrue(layout_path.is_file())
            self.assertTrue(text_path.is_file())

            dump = json.loads(json_path.read_text())
            self.assertEqual("dumped_workload_structures", dump["suite"])
            self.assertEqual(2, len(dump["structures"]))
            self.assertEqual(
                [32, 64],
                [entry["config"]["prefill_seq_len"] for entry in dump["structures"]],
            )
            expected_kernel_order = [
                "input_layernorm", "q_proj", "k_proj", "v_proj", "rope_q", "rope_k",
                "kv_cache_quant_rope_k_to_attn_qkT", "attn_qkT", "attn_softmax",
                "kv_cache_quant_v_cache_to_attn_pv", "attn_pv", "attn_head_concat",
                "o_proj", "residual_attn", "post_attention_layernorm", "gate_proj",
                "up_proj", "mlp_silu", "mlp_elmul", "down_proj", "residual_ffn",
            ]
            self.assertTrue(all(
                [kernel["name"] for kernel in entry["kernels"]] == expected_kernel_order
                for entry in dump["structures"]
            ))
            self.assertIn("[workload: softmax_batch1_prefill_seq_len32_qblk32]", layout_path.read_text())
            self.assertIn("attn_softmax", layout_path.read_text())
            self.assertEqual(layout_path.read_text(), text_path.read_text())
            layout_kernel_order = [
                line.split()[1]
                for line in layout_path.read_text().splitlines()
                if len(line) >= 4 and line[:2].isdigit() and line[2:4] == ". "
            ]
            self.assertEqual(expected_kernel_order * 2, layout_kernel_order)


if __name__ == "__main__":
    unittest.main()
