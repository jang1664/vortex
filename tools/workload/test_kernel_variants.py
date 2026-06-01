from __future__ import annotations

import unittest

from tools.workload.gen_kernel_cfgs import build_fpint_gemm_args_for_model, build_llm_kernels


def _kernel_by_name(payload: dict, name: str) -> dict:
    matches = [kernel for kernel in payload["kernels"] if kernel["name"] == name]
    if not matches:
        raise AssertionError(f"kernel not found: {name}")
    return matches[0]


class KernelVariantTest(unittest.TestCase):
    def test_default_variant_emits_fpint_gemm_metadata(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
        )

        q_proj = _kernel_by_name(payload, "q_proj")

        self.assertEqual("all_fpint_gemm", payload["config"]["variant"])
        self.assertEqual("q_proj", q_proj["op"])
        self.assertEqual("gemm", q_proj["kind"])
        self.assertEqual("fpint_gemm", q_proj["backend"])
        self.assertEqual("fpint_gemm_ffn_hw", q_proj["app"])
        self.assertEqual("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", q_proj["args"])

    def test_attention_sgemm_variant_only_maps_attention_gemms(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="attn_sgemm_tcu",
        )

        q_proj = _kernel_by_name(payload, "q_proj")
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")

        self.assertEqual("fpint_gemm", q_proj["backend"])
        self.assertEqual("fpint_gemm_ffn_hw", q_proj["app"])
        self.assertEqual("sgemm_tcu", attn_qk["backend"])
        self.assertEqual("sgemm_tcu", attn_qk["app"])
        self.assertEqual("-m 128 -n 128 -k 128", attn_qk["args"])
        self.assertEqual("sgemm_tcu", attn_pv["backend"])
        self.assertEqual("sgemm_tcu", attn_pv["app"])
        self.assertEqual("-m 128 -n 128 -k 128", attn_pv["args"])

    def test_all_sgemm_variant_maps_generation_and_lm_head(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="all_sgemm_tcu",
        )

        q_proj = _kernel_by_name(payload, "q_proj")
        lm_head = _kernel_by_name(payload, "lm_head")

        self.assertEqual("sgemm_tcu", q_proj["backend"])
        self.assertEqual("sgemm_tcu", q_proj["app"])
        self.assertEqual("-m 1 -n 4096 -k 4096", q_proj["args"])
        self.assertEqual("sgemm_tcu", lm_head["backend"])
        self.assertEqual("sgemm_tcu", lm_head["app"])
        self.assertEqual("-m 1 -n 32000 -k 4096", lm_head["args"])

    def test_fpint_regression_args_still_select_only_fpint_backend(self) -> None:
        args = build_fpint_gemm_args_for_model("llama2-7b", [128], qblks=[32])

        self.assertIn("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", args)
        self.assertTrue(all("-q " in arg for arg in args))

    def test_unknown_variant_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "unknown variant"):
            build_llm_kernels(
                model_name="llama2-7b",
                stages=["prefill"],
                batch=1,
                prefill_seq_len=128,
                gen_kv_len=128,
                qblk=32,
                variant="not_a_variant",
            )


if __name__ == "__main__":
    unittest.main()
