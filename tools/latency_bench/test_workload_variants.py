from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tools.latency_bench.suite import load_suite, suite_to_expanded_yaml, suite_to_rows


class WorkloadVariantExpansionTest(unittest.TestCase):
    def test_workload_variant_propagates_backend_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: variant_suite
defaults:
  warmup: 1
  iterations: 2
workloads:
  - id: llama2_attn_sgemm
    model: llama2-7b
    stage: prefill
    batch: 1
    prefill_seq_len: 128
    qblk: 32
    variant: attn_sgemm_tcu_fpint_gemm_naive
    filter_kind: gemm
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())
            rows = suite_to_rows(suite)
            expanded = suite_to_expanded_yaml(suite)
            by_op = {case.op: case for case in suite.cases}

            self.assertEqual(9, len(suite.cases))
            self.assertEqual("attn_sgemm_tcu_fpint_gemm_naive", by_op["q_proj"].variant)
            self.assertEqual("gemm", by_op["q_proj"].kind)
            self.assertEqual("fpint_gemm_naive", by_op["q_proj"].backend)
            self.assertEqual("fpint_gemm_ffn_hw_naive", by_op["q_proj"].app)
            self.assertEqual("sgemm_tcu", by_op["attn_qkT"].backend)
            self.assertEqual("sgemm_tcu", by_op["attn_qkT"].app)
            self.assertEqual("-m 128 -n 128 -k 128", by_op["attn_qkT"].args)
            self.assertEqual("sgemm_tcu", by_op["attn_pv"].backend)
            self.assertEqual("attn_qkT", by_op["attn_qkT"].name)
            self.assertTrue(all(row["variant"] == "attn_sgemm_tcu_fpint_gemm_naive" for row in rows))
            self.assertIn("backend", expanded["cases"][0])
            self.assertIn("op", expanded["cases"][0])
            self.assertIn("variant", expanded["cases"][0])

    def test_workload_expansion_includes_attention_head_concat_without_gemm_filter(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: concat_suite
defaults:
  warmup: 1
  iterations: 2
workloads:
  - id: llama2_concat
    model: llama2-7b
    stage: prefill
    batch: 1
    prefill_seq_len: 128
    qblk: 32
    variant: attn_sgemm_tcu_fpint_gemm_naive
    filter_backend: head_concat
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())

            self.assertEqual(1, len(suite.cases))
            self.assertEqual("attn_head_concat", suite.cases[0].op)
            self.assertEqual("concat", suite.cases[0].kind)
            self.assertEqual("head_concat", suite.cases[0].backend)
            self.assertEqual("-batch 1 -seq 128 -heads 32 -headdim 128", suite.cases[0].args)

    def test_fused_layout_variant_expands_rope_layout_modes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: fused_layout_suite
defaults:
  warmup: 1
  iterations: 2
workloads:
  - id: llama2_fused_layout
    model: llama2-7b
    stage: prefill
    batch: 1
    prefill_seq_len: 128
    qblk: 32
    variant: all_fpint_gemm_improve_fused_layout
    filter_backend: rope_layout_fused
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())
            by_op = {case.op: case for case in suite.cases}

            self.assertEqual({"rope_q", "rope_k"}, set(by_op))
            self.assertIn("--layout-to gemm_a_tiled", by_op["rope_q"].args)
            self.assertIn("--layout-to row_major", by_op["rope_k"].args)

    def test_generation_workload_forwards_fixed_cache_capacity(self) -> None:
        for capacity_key in ("max_seq_len", "max-seq-len"):
            with self.subTest(capacity_key=capacity_key), tempfile.TemporaryDirectory() as tmp:
                suite_path = Path(tmp) / "suite.yaml"
                suite_path.write_text(
                    f"""
name: fixed_capacity_suite
defaults:
  warmup: 1
  iterations: 2
workloads:
  - id: llama3_decode_b3_kv33
    model: llama3-8b
    stage: generation
    batch: 3
    prefill_seq_len: 3
    gen_kv_len: 33
    {capacity_key}: 64
    qblk: 32
    variant: all_fpint_gemm_improve_fused_layout_spinquant
    filter_backend: softmax_layout_fused
""".lstrip()
                )

                suite = load_suite(suite_path, repo_root=Path.cwd())

                self.assertEqual(1, len(suite.cases))
                softmax = suite.cases[0]
                self.assertEqual("attn_softmax", softmax.op)
                self.assertEqual(33, softmax.shape["logical_cache_length"])
                self.assertEqual(64, softmax.shape["cache_capacity"])
                self.assertEqual(64, softmax.shape["capacity_stride"])
                self.assertIn("-seqk 33 -seqk-stride 64", softmax.args)

    def test_standard_variant_expands_kv_cache_quant_cases(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            suite_path = Path(tmp) / "suite.yaml"
            suite_path.write_text(
                """
name: kv_cache_quant_suite
defaults:
  warmup: 1
  iterations: 2
workloads:
  - id: llama2_kv_quant
    model: llama2-7b
    stage: generation
    batch: 1
    gen_kv_len: 512
    qblk: 32
    variant: attn_sgemm_tcu_fpint_gemm_naive
    filter_backend: kv_cache_quant_w4a16
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())
            by_op = {case.op: case for case in suite.cases}

            self.assertEqual(
                {"kv_cache_quant_rope_k_to_attn_qkT", "kv_cache_quant_v_cache_to_attn_pv"},
                set(by_op),
            )
            self.assertEqual("-k 1 -n 128 -q 128 -d 1 -t 1", by_op["kv_cache_quant_rope_k_to_attn_qkT"].args)
            self.assertEqual("-k 1 -n 128 -q 128 -d 1 -t 0", by_op["kv_cache_quant_v_cache_to_attn_pv"].args)


if __name__ == "__main__":
    unittest.main()
