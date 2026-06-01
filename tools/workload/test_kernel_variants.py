from __future__ import annotations

import unittest
from pathlib import Path

from tools.workload.gen_kernel_cfgs import (
    KERNEL_APP_REGISTRY,
    LAYOUT_ALONE_VARIANT,
    LAYOUT_FUSED_VARIANT,
    WORKLOAD_VARIANTS,
    build_fpint_gemm_args_for_model,
    build_llm_kernels,
)


def _kernel_by_name(payload: dict, name: str) -> dict:
    matches = [kernel for kernel in payload["kernels"] if kernel["name"] == name]
    if not matches:
        raise AssertionError(f"kernel not found: {name}")
    return matches[0]


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


class KernelVariantTest(unittest.TestCase):
    def test_default_variant_emits_improve_fpint_gemm_metadata(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
        )

        q_proj = _kernel_by_name(payload, "q_proj")

        self.assertEqual("all_fpint_gemm_improve", payload["config"]["variant"])
        self.assertEqual("q_proj", q_proj["op"])
        self.assertEqual("gemm", q_proj["kind"])
        self.assertEqual("fpint_gemm_improve", q_proj["backend"])
        self.assertEqual("fpint_gemm_ffn_hw", q_proj["app"])
        self.assertEqual("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", q_proj["args"])

    def test_naive_variant_maps_fpint_gemm_to_naive_app(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_naive",
        )

        q_proj = _kernel_by_name(payload, "q_proj")

        self.assertEqual("fpint_gemm_naive", q_proj["backend"])
        self.assertEqual("fpint_gemm_ffn_hw_naive", q_proj["app"])
        self.assertEqual("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", q_proj["args"])

    def test_attention_sgemm_naive_variant_only_maps_attention_gemms(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="attn_sgemm_tcu_fpint_gemm_naive",
        )

        q_proj = _kernel_by_name(payload, "q_proj")
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")

        self.assertEqual("fpint_gemm_naive", q_proj["backend"])
        self.assertEqual("fpint_gemm_ffn_hw_naive", q_proj["app"])
        self.assertEqual("sgemm_tcu", attn_qk["backend"])
        self.assertEqual("sgemm_tcu", attn_qk["app"])
        self.assertEqual("-m 128 -n 128 -k 128", attn_qk["args"])
        self.assertEqual("sgemm_tcu", attn_pv["backend"])
        self.assertEqual("sgemm_tcu", attn_pv["app"])
        self.assertEqual("-m 128 -n 128 -k 128", attn_pv["args"])

    def test_all_sgemm_variant_maps_generation_and_excludes_lm_head(self) -> None:
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
        names = {kernel["name"] for kernel in payload["kernels"]}

        self.assertEqual("sgemm_tcu", q_proj["backend"])
        self.assertEqual("sgemm_tcu", q_proj["app"])
        self.assertEqual("-m 1 -n 4096 -k 4096", q_proj["args"])
        self.assertNotIn("lm_head", names)

    def test_fpint_regression_args_still_select_only_fpint_backend(self) -> None:
        args = build_fpint_gemm_args_for_model("llama2-7b", [128], qblks=[32])

        self.assertIn("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", args)
        self.assertTrue(all("-q " in arg for arg in args))

    def test_layout_variants_are_registered(self) -> None:
        self.assertIn("all_fpint_gemm_improve_alone_layout", WORKLOAD_VARIANTS)
        self.assertIn("all_fpint_gemm_improve_fused_layout", WORKLOAD_VARIANTS)

    def test_standalone_layout_variant_emits_activation_and_kv_layout_cases(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant=LAYOUT_ALONE_VARIANT,
        )

        q_proj = _kernel_by_name(payload, "q_proj")
        qkv_input = _kernel_by_name(payload, "layout_input_layernorm_to_qkv")
        k_cache = _kernel_by_name(payload, "layout_rope_k_to_attn_qkT")
        v_cache = _kernel_by_name(payload, "layout_v_cache_to_attn_pv")
        concat_detile = _kernel_by_name(payload, "layout_attn_pv_to_head_concat_detile")
        concat = _kernel_by_name(payload, "attn_head_concat")
        concat_tile = _kernel_by_name(payload, "layout_attn_head_concat_to_o_proj")

        self.assertEqual("fpint_gemm_improve", q_proj["backend"])
        self.assertEqual("fpint_gemm_ffn_hw", q_proj["app"])

        self.assertEqual("tile_input_a", qkv_input["backend"])
        self.assertEqual("tile_input_a", qkv_input["app"])
        self.assertEqual("-m 128 -k 4096", qkv_input["args"])
        self.assertEqual(32, qkv_input["calls_per_forward"])
        self.assertEqual("row_major", qkv_input["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", qkv_input["shape"]["layout_to"])

        self.assertEqual("tile_weight_w4a16", k_cache["backend"])
        self.assertEqual("-k 128 -n 128 -t 1", k_cache["args"])
        self.assertEqual(1024, k_cache["calls_per_forward"])
        self.assertEqual({"K": 128, "N": 128, "WTRANS": 1}, {
            "K": k_cache["shape"]["K"],
            "N": k_cache["shape"]["N"],
            "WTRANS": k_cache["shape"]["WTRANS"],
        })

        self.assertEqual("tile_weight_w4a16", v_cache["backend"])
        self.assertEqual("-k 128 -n 128 -t 0", v_cache["args"])
        self.assertEqual(1024, v_cache["calls_per_forward"])

        self.assertEqual("detile_output", concat_detile["backend"])
        self.assertEqual("-m 128 -n 128", concat_detile["args"])
        self.assertEqual(1024, concat_detile["calls_per_forward"])
        self.assertEqual("attn_pv", concat_detile["shape"]["producer"])
        self.assertEqual("attn_head_concat", concat_detile["shape"]["consumer"])
        self.assertEqual("gemm_c_tiled", concat_detile["shape"]["layout_from"])
        self.assertEqual("row_major", concat_detile["shape"]["layout_to"])

        self.assertEqual("head_concat", concat["backend"])
        self.assertEqual("-batch 1 -seq 128 -heads 32 -headdim 128", concat["args"])
        self.assertEqual(32, concat["calls_per_forward"])
        self.assertEqual("row_major", concat["shape"]["layout_from"])
        self.assertEqual("row_major", concat["shape"]["layout_to"])
        self.assertEqual("tile_input_a", concat_tile["backend"])
        self.assertEqual("-m 128 -k 4096", concat_tile["args"])
        self.assertEqual(32, concat_tile["calls_per_forward"])

    def test_generation_kv_layout_is_append_only(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=512,
            qblk=32,
            variant=LAYOUT_ALONE_VARIANT,
        )

        k_cache = _kernel_by_name(payload, "layout_rope_k_to_attn_qkT")
        v_cache = _kernel_by_name(payload, "layout_v_cache_to_attn_pv")

        self.assertEqual("-k 128 -n 32 -t 1", k_cache["args"])
        self.assertEqual(1, k_cache["shape"]["effective_N"])
        self.assertEqual(512, k_cache["shape"]["cache_len"])
        self.assertEqual("append", k_cache["shape"]["cache_update"])
        self.assertEqual("-k 32 -n 128 -t 0", v_cache["args"])
        self.assertEqual(1, v_cache["shape"]["effective_K"])
        self.assertEqual(512, v_cache["shape"]["cache_len"])
        self.assertEqual("append", v_cache["shape"]["cache_update"])

    def test_fused_layout_variant_replaces_vector_layout_but_keeps_gemm_bridges(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant=LAYOUT_FUSED_VARIANT,
        )

        input_norm = _kernel_by_name(payload, "input_layernorm")
        rope_q = _kernel_by_name(payload, "rope_q")
        rope_k = _kernel_by_name(payload, "rope_k")
        softmax = _kernel_by_name(payload, "attn_softmax")
        concat = _kernel_by_name(payload, "attn_head_concat")
        v_cache = _kernel_by_name(payload, "layout_v_cache_to_attn_pv")
        names = {kernel["name"] for kernel in payload["kernels"]}

        self.assertEqual("rms_norm_layout_fused", input_norm["backend"])
        self.assertEqual("rms_norm_layout_fused", input_norm["app"])
        self.assertEqual("-m 128 -k 4096", input_norm["args"])
        self.assertEqual("rope_layout_fused", rope_q["backend"])
        self.assertIn("--layout-to gemm_a_tiled", rope_q["args"])
        self.assertEqual("rope_layout_fused", rope_k["backend"])
        self.assertEqual("gemm_w_tiled", rope_k["shape"]["layout_to"])
        self.assertIn("--layout-to gemm_w_tiled", rope_k["args"])
        self.assertEqual("softmax_layout_fused", softmax["backend"])
        self.assertEqual("gemm_a_tiled", softmax["shape"]["layout_to"])

        self.assertNotIn("layout_input_layernorm_to_qkv", names)
        self.assertNotIn("layout_attn_pv_to_head_concat_detile", names)
        self.assertNotIn("layout_attn_head_concat_to_o_proj", names)
        self.assertEqual("head_concat_layout_fused", concat["backend"])
        self.assertIn("--layout-to gemm_a_tiled", concat["args"])
        self.assertEqual("gemm_c_tiled_per_head", concat["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", concat["shape"]["layout_to"])
        self.assertEqual("tile_weight_w4a16", v_cache["backend"])
        self.assertTrue(all(kernel["backend"] == "fpint_gemm_improve" for kernel in payload["kernels"] if kernel["kind"] == "gemm"))

    def test_fused_layout_variant_apps_exist_in_regression_tree(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant=LAYOUT_FUSED_VARIANT,
        )
        app_names = {
            KERNEL_APP_REGISTRY[kernel["backend"]]
            for kernel in payload["kernels"]
            if KERNEL_APP_REGISTRY.get(kernel["backend"])
        }

        missing = [
            app
            for app in sorted(app_names)
            if not (_repo_root() / "tests" / "regression" / app / "Makefile").exists()
        ]
        self.assertEqual([], missing)

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
