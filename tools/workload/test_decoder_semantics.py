"""Keep standalone workload scalar policies consistent with the connected decoder."""
import math
import shlex
import unittest
from tools.workload import gen_kernel_cfgs as gen
from tools.workload import export_spinquant_hadamard as had


class DecoderSemanticsTest(unittest.TestCase):
    def test_all_candidates_and_stages_match_decoder_parameters(self):
        variants = (gen.ALL_SGEMM_TCU_VARIANT,
                    gen.ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT,
                    gen.ALL_FPINT_GEMM_NAIVE_VARIANT, gen.LAYOUT_FUSED_VARIANT)
        for model, theta in (("llama2-7b", 10000), ("llama3-8b", 500000)):
            for base in variants:
                for stage in ("prefill", "generation"):
                    with self.subTest(model=model, base=base, stage=stage):
                        kernels = gen.build_decoder_pass_kernels(
                            gen.MODELS[model], stage, 1,
                            1024 if stage == "prefill" else 1,
                            1024 if stage == "prefill" else 1025, 32,
                            base + "_spinquant", softmax_k_stride=1152)
                        rows = {row["name"]: row for row in kernels}
                        def arg(name, flag):
                            args = shlex.split(rows[name]["args"])
                            return args[args.index(flag) + 1]
                        for name in ("input_layernorm", "post_attention_layernorm"):
                            self.assertEqual(float(arg(name, "-eps")), 1e-5)
                        for name in ("rope_q", "rope_k"):
                            self.assertEqual(float(arg(name, "-theta")), theta)
                        self.assertAlmostEqual(float(arg("attn_softmax", "-scale")),
                                               1 / math.sqrt(128), places=9)
                        for name in ("kv_cache_quant_rope_k_to_attn_qkT",
                                     "kv_cache_quant_v_cache_to_attn_pv",
                                     "kv_cache_dequant_k_to_attn_qkT",
                                     "kv_cache_dequant_v_to_attn_pv"):
                            if name in rows:
                                self.assertEqual(arg(name, "--quant-mode"),
                                                 "spinquant_signed_asymmetric")
                        self.assertEqual(arg("spinquant_r4_mlp_hadamard", "--matrix"),
                                         "spinquant")

    def test_exported_hadamard_is_exact_and_orthogonal(self):
        self.assertEqual(had.OUTPUT.read_text(), had.render())
        for n, rows in had.bases().items():
            for i, row in enumerate(rows):
                for j in range(i + 1):
                    self.assertEqual(sum(a*b for a,b in zip(row, rows[j])),
                                     n if i == j else 0)


if __name__ == "__main__":
    unittest.main()
