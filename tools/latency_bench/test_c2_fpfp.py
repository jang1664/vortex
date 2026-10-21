"""C2 attention engine selection preserves FPINT linear work and source identity."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest import TestCase, mock

from tools.workload.gen_kernel_cfgs import build_llm_kernels
from tools.latency_bench.candidate_map import resolve_c2_attn_backend
from tools.latency_bench.suite import SuiteMatrixOverrides, load_suite, resolve_case_fpga_bin
from tools.latency_bench.interpolation import interpolation_group_key

REPO = Path(__file__).resolve().parents[2]
C2 = "attn_sgemm_tcu_fpint_gemm_naive_spinquant"


class C2FpfpTest(TestCase):
    def payload(self, model="llama3-8b", variant=C2, backend="fpfp"):
        return build_llm_kernels(model, ["prefill", "generation"], 1, 32, 32, 32,
                                 variant=variant, out_tokens=17, decode_measurement="sampled",
                                 c2_attn_backend=backend)

    def test_only_c2_attention_changes(self):
        for model in ("llama2-7b", "llama3-8b"):
            old, new = self.payload(model, backend="tcu"), self.payload(model)
            linear = lambda p: [k for k in p["kernels"] if k["backend"] == "fpint_gemm_naive"]
            self.assertEqual(linear(old), linear(new))
            attention = [k for k in new["kernels"] if k["name"] in {"attn_qkT", "attn_pv"}]
            self.assertTrue(attention)
            self.assertTrue(all(k["app"] == "fpfp_gemm_ffn_hw_naive" for k in attention))
            self.assertFalse(any(k["app"] == "sgemm_tcu" for k in new["kernels"]))
        for variant in ("all_sgemm_tcu_spinquant", "all_fpint_gemm_naive_spinquant",
                        "all_fpint_gemm_improve_spinquant"):
            self.assertEqual(self.payload(variant=variant, backend="tcu")["kernels"],
                             self.payload(variant=variant)["kernels"])

    def test_transpose_and_sampling(self):
        kernels = self.payload()["kernels"]
        prefill = {k["name"]: k for k in build_llm_kernels("llama3-8b", ["prefill"], 1, 32, 32, 32,
                    variant=C2, c2_attn_backend="fpfp")["kernels"]}
        self.assertEqual(32 * 8, prefill["attn_k_transpose"]["calls_per_forward"])
        self.assertEqual("-batch 1 -seq 32 -heads 1 -headdim 128 -mode 2",
                         prefill["attn_k_transpose"]["args"])
        self.assertTrue(any(e["source"] == "attn_k_transpose" for e in prefill["attn_qkT"]["inputs"]))
        pv = [k for k in kernels if k["name"] == "attn_pv" and k["stage"] == "generation"]
        self.assertEqual({8}, {k["shape"]["decode_length_alignment"] for k in pv})
        self.assertEqual([33, 41, 49], [k["shape"]["logical_cache_length"] for k in pv
                                     if k["shape"]["measurement_kind"] == "measured"])
        self.assertTrue(all("-q" not in k["args"] and "-r" not in k["padded_args"] for k in pv))

    def test_all_engine_combinations_route_to_correct_images(self):
        root = REPO / "analysis_workspace/latency_on_hw/suites/llama3_8b"
        for c1 in ("tcu", "fpfp"):
            for c2 in ("tcu", "fpfp"):
                overrides = SuiteMatrixOverrides(c1_gemm_backend=c1, c2_attn_backend=c2,
                    batch_values=(1,), seq_len_values=(32,), generation_out_token_values=(17,),
                    generation_decode_measurement="sampled", generation_decode_sample_interval=8)
                for label in ("C1", "C2"):
                    suite = load_suite(root / f"llama3_8b_generation_{label}.yaml", matrix_overrides=overrides)
                    for case in suite.cases:
                        source = resolve_case_fpga_bin(suite, case)
                        if case.kind == "gemm":
                            expected = "C1"
                            if label == "C2":
                                expected = ("C2" if "fpfp" in (c1, c2) else "C1") if case.op in {"attn_qkT", "attn_pv"} else "C3"
                            self.assertEqual(expected, source, (c1, c2, label, case.op, case.app))
                    if label == "C2" and c2 == "fpfp":
                        transpose = [c for c in suite.cases if c.op == "attn_k_transpose"]
                        self.assertTrue(any(c.measurement_kind == "interpolated" for c in transpose))
                        self.assertEqual(1, len({interpolation_group_key(c) for c in transpose}))

    def test_config_capabilities_and_incompatible_requests(self):
        with TemporaryDirectory() as tmp:
            p = Path(tmp)
            mapping = p / "candidates.yaml"
            mapping.write_text("schema_version: 1\ncandidates:\n  C2: test_c2\n")
            config = p / "config.sh"
            with mock.patch("tools.latency_bench.candidate_map.resolve_fpga_bin_artifacts",
                            return_value=SimpleNamespace(config=config)):
                for flags, expected, rejected in (("-DEXT_TCU_ENABLE", "tcu", "fpfp"),
                        ("-DGEMM_NAIVE_FP16_ENABLE -DGEMM_NAIVE", "fpfp", "tcu")):
                    config.write_text(f'CONFIGS="{flags}"\n')
                    self.assertEqual(expected, resolve_c2_attn_backend(mapping))
                    with self.assertRaisesRegex(ValueError, "C2 alias.*does not support"):
                        resolve_c2_attn_backend(mapping, rejected)
