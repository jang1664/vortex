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
    variant: attn_sgemm_tcu
    filter_kind: gemm
""".lstrip()
            )

            suite = load_suite(suite_path, repo_root=Path.cwd())
            rows = suite_to_rows(suite)
            expanded = suite_to_expanded_yaml(suite)
            by_op = {case.op: case for case in suite.cases}

            self.assertEqual(10, len(suite.cases))
            self.assertEqual("attn_sgemm_tcu", by_op["q_proj"].variant)
            self.assertEqual("gemm", by_op["q_proj"].kind)
            self.assertEqual("fpint_gemm", by_op["q_proj"].backend)
            self.assertEqual("fpint_gemm_ffn_hw", by_op["q_proj"].app)
            self.assertEqual("sgemm_tcu", by_op["attn_qkT"].backend)
            self.assertEqual("sgemm_tcu", by_op["attn_qkT"].app)
            self.assertEqual("-m 128 -n 128 -k 128", by_op["attn_qkT"].args)
            self.assertEqual("sgemm_tcu", by_op["attn_pv"].backend)
            self.assertEqual("attn_qkT", by_op["attn_qkT"].name)
            self.assertTrue(all(row["variant"] == "attn_sgemm_tcu" for row in rows))
            self.assertIn("backend", expanded["cases"][0])
            self.assertIn("op", expanded["cases"][0])
            self.assertIn("variant", expanded["cases"][0])


if __name__ == "__main__":
    unittest.main()
