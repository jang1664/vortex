"""C1 engine selection must not redirect C2 attention or drop layout work."""
from dataclasses import replace
from pathlib import Path
import unittest

from tools.workload.gen_kernel_cfgs import build_llm_kernels
from tools.latency_bench.suite import SuiteMatrixOverrides, load_suite, resolve_case_fpga_bin
from tools.latency_bench.canonicalization import canonicalize_args, load_canonicalization_policies
from tools.latency_bench.interpolation import interpolation_group_key

REPO = Path(__file__).resolve().parents[2]


class C1FpfpTest(unittest.TestCase):
    def payload(self, backend, variant="all_sgemm_tcu_spinquant"):
        return build_llm_kernels("llama3-8b", ["prefill", "generation"], 1, 32, 32, 32,
                                 variant=variant, out_tokens=17, decode_measurement="sampled",
                                 c1_gemm_backend=backend)

    def test_only_c1_gemm_changes_and_quantization_is_preserved(self):
        old, new = self.payload("tcu"), self.payload("fpfp")
        self.assertFalse(any(k["backend"] == "sgemm_tcu" for k in new["kernels"]))
        old_vectors = [k for k in old["kernels"] if k["kind"] != "gemm"]
        new_vectors = [k for k in new["kernels"] if k["kind"] not in {"gemm", "reorder"}]
        # Decode K dequant now updates one row; other vectors are unchanged.
        unchanged = lambda k: not (k["stage"] == "generation" and
            k["name"] == "kv_cache_dequant_k_to_attn_qkT")
        old_vectors = list(filter(unchanged, old_vectors))
        new_vectors = list(filter(unchanged, new_vectors))
        key = lambda k: (k["name"], k["args"], k["calls_per_forward"])
        self.assertEqual(list(map(key, old_vectors)), list(map(key, new_vectors)))
        c2 = "attn_sgemm_tcu_fpint_gemm_naive_spinquant"
        self.assertEqual(self.payload("tcu", c2)["kernels"], self.payload("fpfp", c2)["kernels"])

    def test_decode_cache_update_preserves_capacity_and_position(self):
        for model, heads in (("llama2-7b", 32), ("llama3-8b", 8)):
            for variant, backend in (("all_sgemm_tcu_spinquant", "c1_gemm_backend"),
                    ("attn_sgemm_tcu_fpint_gemm_naive_spinquant", "c2_attn_backend")):
                payload = build_llm_kernels(model, ["generation"], 4, 32, 1024, 32,
                    variant=variant, out_tokens=17, max_seq_len=2048,
                    decode_measurement="sampled", **{backend: "fpfp"})
                transposes = [k for k in payload["kernels"] if k["name"] == "attn_k_transpose"]
                self.assertEqual(17, len(transposes))
                for step, kernel in enumerate(transposes):
                    args = f"-batch 1 -seq 1 -heads 1 -headdim 128 -mode 2 -capacity 2048 -offset {1024+step}"
                    self.assertEqual(args, kernel["args"])
                    self.assertEqual(args, kernel["padded_args"])
                    self.assertEqual(32 * 4 * heads, kernel["calls_per_forward"])
                    self.assertEqual(1, kernel["shape"]["source_token_count"])
                dequant = [k for k in payload["kernels"] if k["name"] == "kv_cache_dequant_k_to_attn_qkT"]
                self.assertTrue(all(k["args"].startswith("-k 1 -n 128 ") for k in dequant))
                self.assertEqual(1, sum(k["shape"]["measurement_kind"] == "measured" for k in dequant))

    def test_qkt_transposes_once_per_kv_head_and_uses_row_major_weights(self):
        kernels = build_llm_kernels("llama3-8b", ["prefill"], 1, 32, 32, 32,
                                     variant="all_sgemm_tcu_spinquant", c1_gemm_backend="fpfp")["kernels"]
        prefill = {k["name"]: k for k in kernels if k["stage"] == "prefill"}
        transpose = prefill["attn_k_transpose"]
        self.assertEqual(32 * 8, transpose["calls_per_forward"])
        self.assertEqual("-batch 1 -seq 32 -heads 1 -headdim 128 -mode 2", transpose["args"])
        self.assertEqual(32 * 32, prefill["attn_qkT"]["calls_per_forward"])
        self.assertTrue(any(e["source"] == "attn_k_transpose" for e in prefill["attn_qkT"]["inputs"]))
        for k in kernels:
            if k["kind"] == "gemm":
                self.assertEqual("fpfp_gemm_ffn_hw_naive", k["app"])
                self.assertNotIn("-r", k["args"])
                self.assertNotIn("-q", k["args"])

    def test_decode_sampling_tracks_fp16_tile_boundaries(self):
        kernels = self.payload("fpfp")["kernels"]
        pv = [k for k in kernels if k["name"] == "attn_pv" and k["stage"] == "generation"]
        self.assertEqual({8}, {k["shape"]["decode_length_alignment"] for k in pv})
        measured = [k["shape"]["logical_cache_length"] for k in pv if k["shape"]["measurement_kind"] == "measured"]
        self.assertEqual([33, 41, 49], measured)
        self.assertTrue(all("-r" not in k["padded_args"] for k in pv))
        canonical = canonicalize_args(app="fpfp_gemm_ffn_hw_naive", args="-m 1 -k 33 -n 128",
                                      fpga_bin_label="C1", policies=load_canonicalization_policies(),
                                      preserve_execution_m=True)
        self.assertEqual("-m 1 -k 40 -n 128", canonical.measurement_args)

    def test_generated_c2_keeps_tcu_on_c2_and_transpose_refines(self):
        overrides = SuiteMatrixOverrides(c1_gemm_backend="fpfp", batch_values=(1,),
                    seq_len_values=(32,), generation_out_token_values=(17,),
                    generation_decode_measurement="sampled", generation_decode_sample_interval=8)
        root = REPO / "analysis_workspace/latency_on_hw/suites/llama3_8b"
        for label in ("C1", "C2"):
            suite = load_suite(root / f"llama3_8b_generation_{label}.yaml", matrix_overrides=overrides)
            for case in suite.cases:
                if case.app == "sgemm_tcu":
                    self.assertEqual("C2", resolve_case_fpga_bin(suite, case))
                if case.app == "fpfp_gemm_ffn_hw_naive":
                    self.assertEqual("C1", resolve_case_fpga_bin(suite, case))
            if label == "C1":
                transpose = [c for c in suite.cases if c.op == "attn_k_transpose"]
                self.assertTrue(any(c.measurement_kind == "interpolated" for c in transpose))
                self.assertEqual(1, len({interpolation_group_key(c) for c in transpose}))


if __name__ == "__main__":
    unittest.main()
