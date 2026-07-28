from __future__ import annotations

import unittest
from pathlib import Path

from tools.workload.gen_kernel_cfgs import (
    DEFAULT_HADAMARD_VARIANT,
    HADAMARD_VARIANTS,
    KERNEL_APP_REGISTRY,
    LAYOUT_ALONE_VARIANT,
    LAYOUT_FUSED_VARIANT,
    MODELS,
    WORKLOAD_VARIANTS,
    build_fpint_gemm_args_for_model,
    build_llm_kernels,
    format_layout_view,
)


def _kernel_by_name(payload: dict, name: str) -> dict:
    matches = [kernel for kernel in payload["kernels"] if kernel["name"] == name]
    if not matches:
        raise AssertionError(f"kernel not found: {name}")
    return matches[0]


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


class KernelVariantTest(unittest.TestCase):
    def test_generation_exact_preserves_logical_decode_arguments(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=126,
            out_tokens=3,
            max_seq_len=256,
            qblk=32,
            variant="all_fpint_gemm_improve",
        )

        q_proj_cases = [
            kernel for kernel in payload["kernels"]
            if kernel["name"] == "q_proj"
        ]
        qk_cases = [
            kernel for kernel in payload["kernels"]
            if kernel["name"] == "attn_qkT"
        ]

        self.assertEqual(1, len(q_proj_cases))
        self.assertEqual(3.0, q_proj_cases[0]["shape"]["decode_sample_weight"])
        self.assertEqual(129, q_proj_cases[0]["shape"]["logical_kv_end"])
        self.assertEqual(3, len(qk_cases))
        self.assertEqual([127, 128, 129],
                         [kernel["shape"]["N"] for kernel in qk_cases])
        self.assertEqual([128, 128, 160], [
            kernel["shape"]["padded_cache_length"] for kernel in qk_cases
        ])
        self.assertEqual([128, 128, 160], [
            int(kernel["padded_args"].split("-n ", 1)[1].split()[0])
            for kernel in qk_cases
        ])

    def test_generation_sampled_classifies_and_weights_decode_kernels(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=126,
            out_tokens=6,
            max_seq_len=256,
            qblk=32,
            variant="all_fpint_gemm_improve",
            decode_measurement="sampled",
            decode_sample_interval=4,
        )
        q_proj = [k for k in payload["kernels"] if k["name"] == "q_proj"]
        qk = [k for k in payload["kernels"] if k["name"] == "attn_qkT"]
        softmax = [k for k in payload["kernels"] if k["name"] == "attn_softmax"]
        self.assertEqual(1, len(q_proj))
        self.assertEqual(6.0, q_proj[0]["shape"]["decode_sample_weight"])
        self.assertEqual(2, len(qk))
        self.assertEqual(6.0, sum(k["shape"]["decode_sample_weight"] for k in qk))
        self.assertGreater(len(softmax), 1)
        self.assertEqual(6.0, sum(k["shape"]["decode_sample_weight"] for k in softmax))

    def test_prefill_kernels_ignore_out_tokens(self) -> None:
        common = dict(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=32,
            gen_kv_len=32,
            qblk=32,
            variant="all_fpint_gemm_improve",
        )
        baseline = build_llm_kernels(**common, out_tokens=1)
        expanded = build_llm_kernels(**common, out_tokens=17)

        def kernel_view(payload: dict) -> list[tuple]:
            return [
                (
                    kernel["name"],
                    kernel["args"],
                    kernel["calls_per_forward"],
                    kernel["shape"],
                )
                for kernel in payload["kernels"]
            ]

        self.assertEqual(kernel_view(baseline), kernel_view(expanded))

    def test_generation_defaults_to_one_output_token(self) -> None:
        common = dict(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=33,
            max_seq_len=64,
            qblk=32,
            variant="all_fpint_gemm_improve",
        )
        implicit = build_llm_kernels(**common)
        explicit = build_llm_kernels(**common, out_tokens=1)

        self.assertEqual(implicit, explicit)
        self.assertEqual(34, implicit["config"]["gen_kv_len"] + 1)
        self.assertEqual(
            34,
            _kernel_by_name(implicit, "attn_qkT")["shape"]["logical_cache_length"],
        )

    def test_generation_length_validation_uses_final_output_position(self) -> None:
        with self.assertRaisesRegex(ValueError, "out-tokens must be >= 1"):
            build_llm_kernels(
                "llama2-7b", ["generation"], 1, 8, 8, 32, out_tokens=0,
            )
        with self.assertRaisesRegex(ValueError, "gen-kv-len must be >= 0"):
            build_llm_kernels(
                "llama2-7b", ["generation"], 1, 8, -1, 32,
            )
        with self.assertRaisesRegex(ValueError, "gen-kv-len \\+ out-tokens"):
            build_llm_kernels(
                "llama2-7b", ["generation"], 1, 8, 8, 32,
                out_tokens=2, max_seq_len=9,
            )

    def test_generation_records_fixed_capacity_tile_major_append_contract(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=31,
            gen_kv_len=33,
            max_seq_len=64,
            qblk=32,
            variant="all_fpint_gemm_improve_fused_layout_spinquant",
        )
        key = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        value = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        qk = _kernel_by_name(payload, "attn_qkT")
        softmax = _kernel_by_name(payload, "attn_softmax")
        pv = _kernel_by_name(payload, "attn_pv")

        self.assertEqual(payload["config"]["max_seq_len"], 64)
        for kernel in (key, value, qk, softmax, pv):
            self.assertEqual(kernel["shape"]["query_length"], 1)
            self.assertEqual(kernel["shape"]["logical_cache_length"], 34)
            self.assertEqual(kernel["shape"]["cache_capacity"], 64)
        self.assertEqual(key["shape"]["cache_update"], "append")
        self.assertEqual(key["shape"]["cache_position"], 33)
        self.assertEqual(key["shape"]["persistent_layout"], "gemm_w_tiled_transposed")
        self.assertEqual(value["shape"]["persistent_layout"], "gemm_w_tiled")
        self.assertIn(
            "--cache-update append --cache-capacity 64 --cache-position 33",
            key["args"],
        )
        self.assertIn(
            "--cache-update append --cache-capacity 64 --cache-position 33",
            value["args"],
        )
        self.assertEqual(qk["shape"]["N"], 34)
        self.assertEqual(qk["shape"]["persistent_weight_layout"], "gemm_w_tiled_transposed")
        self.assertEqual(softmax["shape"]["mask"], 0)
        self.assertEqual(softmax["shape"]["capacity_stride"], 64)
        self.assertIn("-seqk 34 -seqk-stride 64", softmax["args"])
        self.assertEqual(pv["shape"]["K"], 34)
        self.assertEqual(pv["shape"]["persistent_weight_layout"], "gemm_w_tiled")

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
        self.assertIn(
            {"role": "A", "source": "input_layernorm", "layout": "gemm_a_tiled"},
            q_proj["inputs"],
        )
        self.assertIn(
            {"role": "W", "source": "param:q_proj.weight", "layout": "gemm_w_tiled"},
            q_proj["inputs"],
        )
        self.assertIn(
            {
                "role": "scale/zp",
                "source": "param:q_proj.qparams",
                "layout": "gemm_scale_zp_tiled",
            },
            q_proj["inputs"],
        )
        self.assertIn(
            {"role": "C", "target": "rope_q", "layout": "gemm_c_tiled"},
            q_proj["outputs"],
        )

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

    def test_all_fpint_naive_variant_emits_kv_cache_quant_for_attention_operands(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_naive",
        )

        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")

        self.assertEqual("kv_cache_quant_w4a16", k_quant["backend"])
        self.assertEqual("-k 8 -n 128 -q 128 -d 1 -t 1", k_quant["args"])
        self.assertEqual(8, k_quant["shape"]["K"])
        self.assertEqual(128, k_quant["shape"]["N"])
        self.assertNotIn("effective_K", k_quant["shape"])
        self.assertNotIn("effective_N", k_quant["shape"])
        self.assertEqual(1, k_quant["shape"]["source_QDIR"])
        self.assertEqual(0, k_quant["shape"]["gemm_QDIR"])
        self.assertTrue(k_quant["shape"]["source_transposed"])
        self.assertEqual("full", k_quant["shape"]["cache_update"])
        self.assertIn(
            {"role": "W", "target": "attn_qkT", "layout": "row_major"},
            k_quant["outputs"],
        )
        self.assertIn(
            {"role": "W", "source": "kv_cache_quant_rope_k_to_attn_qkT", "layout": "row_major"},
            attn_qk["inputs"],
        )

        self.assertEqual("kv_cache_quant_w4a16", v_quant["backend"])
        self.assertEqual("-k 8 -n 128 -q 128 -d 1 -t 0", v_quant["args"])
        self.assertEqual(8, v_quant["shape"]["K"])
        self.assertEqual(128, v_quant["shape"]["N"])
        self.assertNotIn("effective_K", v_quant["shape"])
        self.assertNotIn("effective_N", v_quant["shape"])
        self.assertEqual("full", v_quant["shape"]["cache_update"])
        self.assertIn(
            {"role": "W", "target": "attn_pv", "layout": "row_major"},
            v_quant["outputs"],
        )
        self.assertIn(
            {"role": "W", "source": "kv_cache_quant_v_cache_to_attn_pv", "layout": "row_major"},
            attn_pv["inputs"],
        )

    def test_all_sgemm_variant_dequantizes_w4_operands_for_fp_tcu(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=512,
            qblk=32,
            variant="all_sgemm_tcu",
        )

        rope_k = _kernel_by_name(payload, "rope_k")
        v_proj = _kernel_by_name(payload, "v_proj")
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        k_dequant = _kernel_by_name(payload, "kv_cache_dequant_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        v_dequant = _kernel_by_name(payload, "kv_cache_dequant_v_to_attn_pv")
        q_weight_dequant = _kernel_by_name(
            payload, "dequant_q_proj_weight_to_fp16"
        )
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")

        self.assertEqual("-k 1 -n 128 -q 128 -d 1 -t 1", k_quant["args"])
        self.assertEqual(1, k_quant["shape"]["K"])
        self.assertEqual(128, k_quant["shape"]["N"])
        self.assertNotIn("effective_K", k_quant["shape"])
        self.assertNotIn("effective_N", k_quant["shape"])
        self.assertEqual(513, k_quant["shape"]["cache_len"])
        self.assertEqual("append", k_quant["shape"]["cache_update"])
        self.assertIn(
            {
                "role": "packed",
                "target": "kv_cache_dequant_k_to_attn_qkT",
                "layout": "packed_w4a16_row_major",
            },
            k_quant["outputs"],
        )
        self.assertNotIn(
            {"role": "k", "target": "attn_qkT", "layout": "row_major"},
            rope_k["outputs"],
        )
        self.assertEqual("kv_cache_dequant_w4a16", k_dequant["backend"])
        self.assertEqual(
            "-k 513 -n 128 -q 128 -d 1 -t 1 "
            "--quant-mode legacy_uint4_asymmetric",
            k_dequant["args"],
        )
        self.assertEqual(1024, k_dequant["calls_per_forward"])
        self.assertIn(
            {
                "role": "B",
                "source": "kv_cache_dequant_k_to_attn_qkT",
                "layout": "row_major_fp16",
            },
            attn_qk["inputs"],
        )

        self.assertEqual("-k 1 -n 128 -q 128 -d 1 -t 0", v_quant["args"])
        self.assertEqual(1, v_quant["shape"]["K"])
        self.assertEqual(128, v_quant["shape"]["N"])
        self.assertNotIn("effective_K", v_quant["shape"])
        self.assertNotIn("effective_N", v_quant["shape"])
        self.assertEqual(513, v_quant["shape"]["cache_len"])
        self.assertEqual("append", v_quant["shape"]["cache_update"])
        self.assertIn(
            {
                "role": "packed",
                "target": "kv_cache_dequant_v_to_attn_pv",
                "layout": "packed_w4a16_row_major",
            },
            v_quant["outputs"],
        )
        self.assertIn(
            {
                "role": "C",
                "target": "kv_cache_quant_v_cache_to_attn_pv",
                "layout": "row_major_fp16",
            },
            v_proj["outputs"],
        )
        self.assertEqual("kv_cache_dequant_w4a16", v_dequant["backend"])
        self.assertEqual(
            "-k 513 -n 128 -q 128 -d 1 -t 0 "
            "--quant-mode legacy_uint4_asymmetric",
            v_dequant["args"],
        )
        self.assertIn(
            {
                "role": "B",
                "source": "kv_cache_dequant_v_to_attn_pv",
                "layout": "row_major_fp16",
            },
            attn_pv["inputs"],
        )
        self.assertEqual("kv_cache_dequant_w4a16", q_weight_dequant["backend"])
        self.assertEqual(
            "-k 4096 -n 4096 -q 32 -d 0 -t 0 "
            "--quant-mode signed_int4_asymmetric",
            q_weight_dequant["args"],
        )
        q_proj = _kernel_by_name(payload, "q_proj")
        self.assertIn(
            {
                "role": "B",
                "source": "dequant_q_proj_weight_to_fp16",
                "layout": "row_major_fp16",
            },
            q_proj["inputs"],
        )

    def test_naive_fpint_layout_view_marks_row_major_operands(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=128,
            qblk=32,
            variant="attn_sgemm_tcu_fpint_gemm_naive",
        )

        q_proj = _kernel_by_name(payload, "q_proj")
        o_proj = _kernel_by_name(payload, "o_proj")
        text = format_layout_view(payload)

        self.assertIn(
            {"role": "A", "source": "input_layernorm", "layout": "row_major"},
            q_proj["inputs"],
        )
        self.assertIn(
            {"role": "W", "source": "param:q_proj.weight", "layout": "row_major"},
            q_proj["inputs"],
        )
        self.assertIn(
            {"role": "scale/zp", "source": "param:q_proj.qparams", "layout": "row_major"},
            q_proj["inputs"],
        )
        self.assertIn(
            {"role": "C", "target": "rope_q", "layout": "row_major"},
            q_proj["outputs"],
        )
        self.assertIn(
            {"role": "A", "source": "attn_head_concat", "layout": "row_major"},
            o_proj["inputs"],
        )
        self.assertNotIn("gemm_a_tiled", text)
        self.assertNotIn("gemm_w_tiled", text)
        self.assertNotIn("gemm_scale_zp_tiled", text)
        self.assertNotIn("gemm_c_tiled", text)

    def test_w4_dequant_is_emitted_only_for_sgemm_tcu_consumers(self) -> None:
        expected_counts = {
            "all_sgemm_tcu_spinquant": 9,
            "attn_sgemm_tcu_fpint_gemm_naive_spinquant": 2,
            "attn_sgemm_tcu_fpint_gemm_improve_spinquant": 2,
            "all_fpint_gemm_naive_spinquant": 0,
            "all_fpint_gemm_improve_alone_layout_spinquant": 0,
            "all_fpint_gemm_improve_fused_layout_spinquant": 0,
        }
        for variant, expected_count in expected_counts.items():
            with self.subTest(variant=variant):
                payload = build_llm_kernels(
                    model_name="llama2-7b",
                    stages=["generation"],
                    batch=1,
                    prefill_seq_len=8,
                    gen_kv_len=512,
                    qblk=32,
                    variant=variant,
                )
                by_name = {
                    str(kernel["name"]): kernel
                    for kernel in payload["kernels"]
                }
                dequant_kernels = [
                    kernel for kernel in payload["kernels"]
                    if kernel["backend"] == "kv_cache_dequant_w4a16"
                ]
                self.assertEqual(expected_count, len(dequant_kernels))
                for dequant in dequant_kernels:
                    consumer = str(dequant["shape"]["consumer"])
                    self.assertEqual("sgemm_tcu", by_name[consumer]["backend"])

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
        self.assertNotIn("embedding_lookup", names)
        self.assertNotIn("final_layernorm", names)

    def test_fpint_regression_args_still_select_only_fpint_backend(self) -> None:
        args = build_fpint_gemm_args_for_model("llama2-7b", [128], qblks=[32])

        self.assertIn("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", args)
        self.assertTrue(all("-q " in arg for arg in args))

    def test_llama3_8b_registry_uses_gqa_projection_and_kv_counts(self) -> None:
        self.assertIn("llama3-8b", MODELS)

        payload = build_llm_kernels(
            model_name="llama3-8b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_naive",
        )

        q_proj = _kernel_by_name(payload, "q_proj")
        k_proj = _kernel_by_name(payload, "k_proj")
        v_proj = _kernel_by_name(payload, "v_proj")
        o_proj = _kernel_by_name(payload, "o_proj")
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")

        self.assertEqual("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", q_proj["args"])
        self.assertEqual("-m 128 -n 1024 -k 4096 -q 32 -t 0 -d 0", k_proj["args"])
        self.assertEqual("-m 128 -n 1024 -k 4096 -q 32 -t 0 -d 0", v_proj["args"])
        self.assertEqual("-m 128 -n 4096 -k 4096 -q 32 -t 0 -d 0", o_proj["args"])
        self.assertEqual(1024, k_proj["shape"]["N"])
        self.assertEqual(1024, v_proj["shape"]["N"])

        self.assertEqual(32 * 1 * 32, attn_qk["calls_per_forward"])
        self.assertEqual(32 * 1 * 32, attn_pv["calls_per_forward"])
        self.assertEqual(32 * 1 * 8, k_quant["calls_per_forward"])
        self.assertEqual(32 * 1 * 8, v_quant["calls_per_forward"])

    def test_llama3p2_registry_uses_model_specific_gqa_shapes(self) -> None:
        expected = {
            "llama3p2-1b": {
                "hidden": 2048,
                "intermediate": 8192,
                "head_dim": 64,
                "heads": 32,
                "kv_heads": 8,
                "layers": 16,
            },
            "llama3p2-3b": {
                "hidden": 3072,
                "intermediate": 8192,
                "head_dim": 128,
                "heads": 24,
                "kv_heads": 8,
                "layers": 28,
            },
        }

        for model_name, shape in expected.items():
            with self.subTest(model=model_name):
                payload = build_llm_kernels(
                    model_name=model_name,
                    stages=["prefill"],
                    batch=1,
                    prefill_seq_len=128,
                    gen_kv_len=128,
                    qblk=32,
                    variant="all_fpint_gemm_naive",
                )

                q_proj = _kernel_by_name(payload, "q_proj")
                k_proj = _kernel_by_name(payload, "k_proj")
                gate_proj = _kernel_by_name(payload, "gate_proj")
                attn_qk = _kernel_by_name(payload, "attn_qkT")
                k_quant = _kernel_by_name(
                    payload, "kv_cache_quant_rope_k_to_attn_qkT"
                )
                kv_width = shape["kv_heads"] * shape["head_dim"]

                self.assertEqual(shape["hidden"], q_proj["shape"]["N"])
                self.assertEqual(shape["hidden"], q_proj["shape"]["K"])
                self.assertEqual(kv_width, k_proj["shape"]["N"])
                self.assertEqual(shape["intermediate"], gate_proj["shape"]["N"])
                self.assertEqual(
                    shape["layers"] * shape["heads"],
                    attn_qk["calls_per_forward"],
                )
                self.assertEqual(
                    shape["layers"] * shape["kv_heads"],
                    k_quant["calls_per_forward"],
                )

    def test_llama3_prefill_standalone_detiles_narrow_kv_projections(self) -> None:
        payload = build_llm_kernels(
            model_name="llama3-8b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=32,
            gen_kv_len=32,
            qblk=32,
            variant="all_fpint_gemm_improve_alone_layout_spinquant",
        )

        q_detile = _kernel_by_name(payload, "layout_q_proj_to_rope_q_detile")
        k_detile = _kernel_by_name(payload, "layout_k_proj_to_rope_k_detile")
        v_detile = _kernel_by_name(payload, "layout_v_proj_to_v_cache_detile")

        self.assertEqual(4096, q_detile["shape"]["N"])
        self.assertEqual(1024, k_detile["shape"]["N"])
        self.assertEqual(1024, v_detile["shape"]["N"])

    def test_llama3_prefill_fused_gqa_shares_kv_without_grouping_q_rows(self) -> None:
        payload = build_llm_kernels(
            model_name="llama3-8b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=32,
            gen_kv_len=32,
            qblk=32,
            variant="all_fpint_gemm_improve_fused_layout_spinquant",
        )

        q_hadamard = _kernel_by_name(payload, "spinquant_r3_q_hadamard")
        k_hadamard = _kernel_by_name(payload, "spinquant_r3_k_hadamard")
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")
        concat = _kernel_by_name(payload, "attn_head_concat")

        self.assertEqual(32, q_hadamard["shape"]["matrix_count"])
        self.assertEqual(8, k_hadamard["shape"]["matrix_count"])
        self.assertEqual(32, q_hadamard["shape"]["rows_per_matrix"])
        self.assertEqual(32, attn_qk["shape"]["M"])
        self.assertEqual(32, attn_pv["shape"]["M"])
        self.assertEqual(32 * 32, attn_qk["calls_per_forward"])
        self.assertEqual(32 * 32, attn_pv["calls_per_forward"])
        self.assertNotIn("grouped_query_attention", attn_qk["shape"])
        self.assertEqual(1, concat["shape"]["query_heads_per_kv"])
        self.assertEqual(32, concat["shape"]["input_matrix_count"])

    def test_llama3_generation_gqa_groups_attention_gemms(self) -> None:
        payload = build_llm_kernels(
            model_name="llama3-8b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_improve",
        )

        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_pv = _kernel_by_name(payload, "attn_pv")

        self.assertEqual("-m 4 -n 129 -k 128 -q 128 -t 1 -d 0", attn_qk["args"])
        self.assertEqual("-m 4 -n 128 -k 129 -q 128 -t 0 -d 1", attn_pv["args"])
        self.assertEqual(32 * 1 * 8, attn_qk["calls_per_forward"])
        self.assertEqual(32 * 1 * 8, attn_pv["calls_per_forward"])
        self.assertEqual(4, attn_qk["shape"]["M"])
        self.assertEqual(4, attn_pv["shape"]["M"])
        self.assertTrue(attn_qk["shape"]["grouped_query_attention"])
        self.assertTrue(attn_pv["shape"]["grouped_query_attention"])
        self.assertEqual(32, attn_qk["shape"]["query_heads"])
        self.assertEqual(8, attn_qk["shape"]["key_value_heads"])
        self.assertEqual(4, attn_qk["shape"]["query_heads_per_kv"])

    def test_llama3_generation_gqa_groups_fused_spinquant_q_layout(self) -> None:
        payload = build_llm_kernels(
            model_name="llama3-8b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=128,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_improve_fused_layout_spinquant",
        )

        q_hadamard = _kernel_by_name(payload, "spinquant_r3_q_hadamard")
        attn_qk = _kernel_by_name(payload, "attn_qkT")

        self.assertEqual("hadamard_layout_fused", q_hadamard["backend"])
        self.assertEqual("-m 4 -n 8 -k 128", q_hadamard["args"])
        self.assertEqual(8, q_hadamard["shape"]["matrix_count"])
        self.assertEqual(4, q_hadamard["shape"]["rows_per_matrix"])
        self.assertEqual(8, q_hadamard["shape"]["m_pad"])
        self.assertEqual(4, q_hadamard["shape"]["query_heads_per_kv"])
        self.assertEqual("gemm_a_tiled", q_hadamard["shape"]["layout_to"])
        self.assertEqual(4, attn_qk["shape"]["M"])
        concat = _kernel_by_name(payload, "attn_head_concat")
        self.assertEqual(4, concat["shape"]["query_heads_per_kv"])
        self.assertEqual(8, concat["shape"]["input_matrix_count"])

    def test_layout_variants_are_registered(self) -> None:
        self.assertIn("all_fpint_gemm_improve_alone_layout", WORKLOAD_VARIANTS)
        self.assertIn("all_fpint_gemm_improve_fused_layout", WORKLOAD_VARIANTS)

    def test_spinquant_variants_emit_hadamard_kernels(self) -> None:
        self.assertIn("all_sgemm_tcu_spinquant", WORKLOAD_VARIANTS)
        self.assertIn("all_fpint_gemm_improve_fused_layout_spinquant", WORKLOAD_VARIANTS)
        self.assertEqual("hadamard", KERNEL_APP_REGISTRY["hadamard"])

        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=8,
            qblk=32,
            variant="all_sgemm_tcu_spinquant",
        )

        q_had = _kernel_by_name(payload, "spinquant_r3_q_hadamard")
        k_had = _kernel_by_name(payload, "spinquant_r3_k_hadamard")
        r4_had = _kernel_by_name(payload, "spinquant_r4_mlp_hadamard")
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        k_dequant = _kernel_by_name(payload, "kv_cache_dequant_k_to_attn_qkT")
        attn_qk = _kernel_by_name(payload, "attn_qkT")

        self.assertEqual("hadamard", q_had["backend"])
        self.assertEqual("hadamard", q_had["app"])
        self.assertEqual("-rows 256 -dim 128 -K 1", q_had["args"])
        self.assertEqual(32, q_had["calls_per_forward"])
        self.assertEqual({"rows": 256, "dim": 128}, {
            "rows": q_had["shape"]["rows"],
            "dim": q_had["shape"]["dim"],
        })
        self.assertEqual("R3", q_had["shape"]["spinquant_rotation"])
        self.assertEqual("-rows 256 -dim 128 -K 1", k_had["args"])
        self.assertEqual("spinquant_r3_k_hadamard", k_quant["shape"]["producer"])
        self.assertIn(
            {"role": "x", "source": "spinquant_r3_k_hadamard", "layout": "row_major_fp16"},
            k_quant["inputs"],
        )
        self.assertIn(
            {
                "role": "B",
                "source": "kv_cache_dequant_k_to_attn_qkT",
                "layout": "row_major_fp16",
            },
            attn_qk["inputs"],
        )
        self.assertEqual(
            "-k 8 -n 128 -q 128 -d 1 -t 1 "
            "--quant-mode spinquant_signed_asymmetric",
            k_dequant["args"],
        )
        self.assertEqual("-rows 8 -dim 11008 -K 172", r4_had["args"])
        self.assertEqual("hadamard", r4_had["backend"])
        self.assertEqual(
            "butterfly_base_fused", r4_had["shape"]["hadamard_phase"]
        )
        self.assertEqual("R4", r4_had["shape"]["spinquant_rotation"])
        self.assertEqual("factorized", r4_had["shape"]["hadamard_variant"])
        self.assertEqual(DEFAULT_HADAMARD_VARIANT, payload["config"]["hadamard_variant"])

    def test_factorized_spinquant_emits_one_compute_fused_r4_kernel(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=128,
            qblk=32,
            variant="all_sgemm_tcu_spinquant",
            hadamard_variant="factorized",
        )

        q_had = _kernel_by_name(payload, "spinquant_r3_q_hadamard")
        r4_had = _kernel_by_name(payload, "spinquant_r4_mlp_hadamard")

        self.assertIn("factorized", HADAMARD_VARIANTS)
        self.assertEqual("factorized", payload["config"]["hadamard_variant"])
        self.assertEqual("hadamard", q_had["backend"])
        self.assertEqual("-rows 32 -dim 128 -K 1", q_had["args"])
        self.assertEqual("hadamard", r4_had["backend"])
        self.assertEqual("-rows 1 -dim 11008 -K 172", r4_had["args"])
        self.assertEqual(
            "butterfly_base_fused", r4_had["shape"]["hadamard_phase"]
        )
        self.assertEqual("mlp_elmul", r4_had["shape"]["producer"])
        self.assertFalse(any(
            kernel["backend"] == "hadamard_base"
            for kernel in payload["kernels"]
        ))

    def test_factorized_fused_spinquant_selects_exact_kernel_mode(self) -> None:
        payload = build_llm_kernels(
            model_name="llama3-8b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_improve_fused_layout_spinquant",
            hadamard_variant="factorized",
        )

        r4_had = _kernel_by_name(payload, "spinquant_r4_mlp_hadamard")

        self.assertEqual("hadamard_layout_fused", r4_had["backend"])
        self.assertEqual(
            "-m 1 -n 1 -k 14336 --layout-from gemm_a_tiled",
            r4_had["args"],
        )
        self.assertEqual("factorized", r4_had["shape"]["hadamard_variant"])

    def test_spinquant_generation_hadamard_shapes_use_current_token_rows(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=512,
            qblk=32,
            variant="all_sgemm_tcu_spinquant",
        )

        q_had = _kernel_by_name(payload, "spinquant_r3_q_hadamard")
        k_had = _kernel_by_name(payload, "spinquant_r3_k_hadamard")
        r4_had = _kernel_by_name(payload, "spinquant_r4_mlp_hadamard")

        self.assertEqual("-rows 32 -dim 128 -K 1", q_had["args"])
        self.assertEqual("-rows 32 -dim 128 -K 1", k_had["args"])
        self.assertEqual("-rows 1 -dim 11008 -K 172", r4_had["args"])

    def test_zero_padding_remains_explicit_when_not_default(self) -> None:
        standalone = build_llm_kernels(
            model_name="llama3-8b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=128,
            qblk=32,
            variant="all_sgemm_tcu_spinquant",
            hadamard_variant="zero_padding",
        )
        fused = build_llm_kernels(
            model_name="llama3-8b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=128,
            qblk=32,
            variant="all_fpint_gemm_improve_fused_layout_spinquant",
            hadamard_variant="zero_padding",
        )

        standalone_r4 = _kernel_by_name(
            standalone, "spinquant_r4_mlp_hadamard"
        )
        fused_r4 = _kernel_by_name(fused, "spinquant_r4_mlp_hadamard")
        self.assertEqual("-rows 1 -dim 14336 -K 0", standalone_r4["args"])
        self.assertIn("--hadamard-variant zero_padding", fused_r4["args"])

    def test_spinquant_fused_layout_fuses_hadamard_gemm_a_write(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=8,
            qblk=32,
            variant="all_fpint_gemm_improve_fused_layout_spinquant",
        )

        rope_q = _kernel_by_name(payload, "rope_q")
        rope_k = _kernel_by_name(payload, "rope_k")
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        attn_qk = _kernel_by_name(payload, "attn_qkT")
        attn_softmax = _kernel_by_name(payload, "attn_softmax")
        q_hadamard = _kernel_by_name(payload, "spinquant_r3_q_hadamard")
        k_hadamard = _kernel_by_name(payload, "spinquant_r3_k_hadamard")
        mlp_silu = _kernel_by_name(payload, "mlp_silu")
        mlp_elmul = _kernel_by_name(payload, "mlp_elmul")
        r4_hadamard = _kernel_by_name(payload, "spinquant_r4_mlp_hadamard")
        down_proj = _kernel_by_name(payload, "down_proj")
        text = format_layout_view(payload)

        self.assertEqual("rope_layout_fused", rope_q["backend"])
        self.assertIn("--layout-to head_major_row", rope_q["args"])
        self.assertEqual("head_major_row_fp16", rope_q["shape"]["layout_to"])
        self.assertEqual("head_major_row_fp16", rope_k["shape"]["layout_to"])
        self.assertEqual("spinquant_signed_asymmetric", k_quant["shape"]["quant_mode"])
        self.assertNotIn("--emit-correction-qparams", k_quant["args"])
        self.assertNotIn("correction_qparams_layout_to", k_quant["shape"])
        self.assertEqual(128, k_quant["shape"]["source_total_n"])
        self.assertEqual(0, k_quant["shape"]["head_col_offset"])
        self.assertEqual("spinquant_signed_symmetric", v_quant["shape"]["quant_mode"])
        self.assertEqual(4096, v_quant["shape"]["source_total_n"])
        self.assertEqual("call_head_index*128", v_quant["shape"]["head_col_offset"])
        self.assertIn("--head-col-offset 0", v_quant["args"])
        self.assertEqual(0, v_quant["shape"]["representative_args_head_col_offset"])
        self.assertEqual("attn_softmax", attn_qk["shape"]["consumer"])
        self.assertEqual("attn_qkT", attn_softmax["inputs"][0]["source"])
        self.assertEqual("hadamard_layout_fused", q_hadamard["backend"])
        self.assertEqual("-m 8 -n 32 -k 128", q_hadamard["args"])
        self.assertEqual("head_major_row_fp16", q_hadamard["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", q_hadamard["shape"]["layout_to"])
        self.assertEqual("hadamard_layout_fused", k_hadamard["backend"])
        self.assertEqual("-m 8 -n 32 -k 128", k_hadamard["args"])
        self.assertEqual("gemm_a_tiled", k_hadamard["shape"]["layout_to"])
        self.assertEqual("gemm_a_tiled", k_quant["shape"]["layout_from"])
        self.assertEqual("silu_layout_fused", mlp_silu["backend"])
        self.assertEqual("gemm_c_tiled", mlp_silu["shape"]["layout_from"])
        self.assertEqual("gemm_c_tiled", mlp_silu["shape"]["layout_to"])
        self.assertEqual("elmul_layout_fused", mlp_elmul["backend"])
        self.assertEqual("gemm_c_tiled", mlp_elmul["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", mlp_elmul["shape"]["layout_to"])
        self.assertEqual("hadamard_layout_fused", r4_hadamard["backend"])
        self.assertEqual(
            "-m 8 -n 1 -k 11008 --layout-from gemm_a_tiled",
            r4_hadamard["args"],
        )
        self.assertEqual("gemm_a_tiled", r4_hadamard["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", r4_hadamard["shape"]["layout_to"])
        kernel_names = {kernel["name"] for kernel in payload["kernels"]}
        self.assertNotIn("qk_asym_correction_out", kernel_names)
        self.assertNotIn("layout_rope_q_to_attn_qkT", kernel_names)
        self.assertNotIn("layout_gate_proj_to_mlp_silu_detile", kernel_names)
        self.assertNotIn("layout_up_proj_to_mlp_elmul_detile", kernel_names)
        self.assertNotIn("layout_mlp_elmul_to_down_proj", kernel_names)
        self.assertIn(
            {"role": "A", "source": "spinquant_r4_mlp_hadamard", "layout": "gemm_a_tiled"},
            down_proj["inputs"],
        )
        self.assertIn("spinquant_r3_q_hadamard", text)
        self.assertIn("spinquant_r3_k_hadamard", text)
        self.assertIn("spinquant_r4_mlp_hadamard", text)

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
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        k_qparams = _kernel_by_name(payload, "layout_rope_k_qparams_to_attn_qkT")
        k_cache = _kernel_by_name(payload, "layout_rope_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        v_qparams = _kernel_by_name(payload, "layout_v_cache_qparams_to_attn_pv")
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

        self.assertEqual("kv_cache_quant_w4a16", k_quant["backend"])
        self.assertEqual("kv_cache_quant_w4a16", k_quant["app"])
        self.assertEqual("-k 128 -n 128 -q 128 -d 1 -t 1", k_quant["args"])
        self.assertEqual(1024, k_quant["calls_per_forward"])
        self.assertEqual("row_major_fp16", k_quant["shape"]["layout_from"])
        self.assertEqual("packed_w4a16_row_major", k_quant["shape"]["layout_to"])
        self.assertEqual(1, k_quant["shape"]["source_QDIR"])
        self.assertEqual(0, k_quant["shape"]["gemm_QDIR"])
        self.assertTrue(k_quant["shape"]["source_transposed"])

        self.assertEqual("tile_scale_zp_w4a16", k_qparams["backend"])
        self.assertEqual("-k 128 -n 128 -q 128 -d 1 --gemm-qdir 0 --source-transposed", k_qparams["args"])
        self.assertEqual("qparams_row_major", k_qparams["shape"]["layout_from"])
        self.assertEqual("sz_gemm_tiled_transposed", k_qparams["shape"]["layout_to"])

        self.assertEqual("tile_weight_w4a16", k_cache["backend"])
        self.assertEqual("-k 128 -n 128 -t 1 --source-transposed", k_cache["args"])
        self.assertEqual(1024, k_cache["calls_per_forward"])
        self.assertEqual("kv_cache_quant_rope_k_to_attn_qkT", k_cache["shape"]["producer"])
        self.assertEqual("packed_w4a16_row_major", k_cache["shape"]["layout_from"])
        self.assertEqual("gemm_w_tiled_transposed", k_cache["shape"]["layout_to"])
        self.assertEqual({"K": 128, "N": 128, "WTRANS": 1}, {
            "K": k_cache["shape"]["K"],
            "N": k_cache["shape"]["N"],
            "WTRANS": k_cache["shape"]["WTRANS"],
        })

        self.assertEqual("kv_cache_quant_w4a16", v_quant["backend"])
        self.assertEqual("-k 128 -n 128 -q 128 -d 1 -t 0", v_quant["args"])
        self.assertEqual(1024, v_quant["calls_per_forward"])
        self.assertEqual("tile_scale_zp_w4a16", v_qparams["backend"])
        self.assertEqual("-k 128 -n 128 -q 128 -d 1 --gemm-qdir 1", v_qparams["args"])
        self.assertEqual("sz_gemm_tiled", v_qparams["shape"]["layout_to"])
        self.assertEqual("tile_weight_w4a16", v_cache["backend"])
        self.assertEqual("-k 128 -n 128 -t 0", v_cache["args"])
        self.assertEqual(1024, v_cache["calls_per_forward"])
        self.assertEqual("kv_cache_quant_v_cache_to_attn_pv", v_cache["shape"]["producer"])

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
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        k_qparams = _kernel_by_name(payload, "layout_rope_k_qparams_to_attn_qkT")
        v_qparams = _kernel_by_name(payload, "layout_v_cache_qparams_to_attn_pv")

        self.assertEqual("-k 1 -n 128 -t 1 --source-transposed", k_cache["args"])
        self.assertNotIn("effective_K", k_cache["shape"])
        self.assertNotIn("effective_N", k_cache["shape"])
        self.assertEqual(513, k_cache["shape"]["cache_len"])
        self.assertEqual("append", k_cache["shape"]["cache_update"])
        self.assertEqual("-k 1 -n 128 -q 128 -d 1 -t 1", k_quant["args"])
        self.assertNotIn("effective_K", k_quant["shape"])
        self.assertNotIn("effective_N", k_quant["shape"])
        self.assertEqual(513, k_quant["shape"]["cache_len"])
        self.assertEqual("append", k_quant["shape"]["cache_update"])
        self.assertEqual("-k 1 -n 128 -q 128 -d 1 --gemm-qdir 0 --source-transposed", k_qparams["args"])
        self.assertNotIn("effective_K", k_qparams["shape"])
        self.assertNotIn("effective_N", k_qparams["shape"])
        self.assertEqual("append", k_qparams["shape"]["cache_update"])
        self.assertEqual("-k 1 -n 128 -t 0", v_cache["args"])
        self.assertNotIn("effective_K", v_cache["shape"])
        self.assertEqual(513, v_cache["shape"]["cache_len"])
        self.assertEqual("append", v_cache["shape"]["cache_update"])
        self.assertEqual("-k 1 -n 128 -q 128 -d 1 -t 0", v_quant["args"])
        self.assertNotIn("effective_K", v_quant["shape"])
        self.assertEqual(513, v_quant["shape"]["cache_len"])
        self.assertEqual("append", v_quant["shape"]["cache_update"])
        self.assertEqual("-k 1 -n 128 -q 128 -d 1 --gemm-qdir 1", v_qparams["args"])
        self.assertNotIn("effective_K", v_qparams["shape"])
        self.assertEqual("append", v_qparams["shape"]["cache_update"])

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
        k_quant = _kernel_by_name(payload, "kv_cache_quant_rope_k_to_attn_qkT")
        v_quant = _kernel_by_name(payload, "kv_cache_quant_v_cache_to_attn_pv")
        attn_pv = _kernel_by_name(payload, "attn_pv")
        mlp_silu = _kernel_by_name(payload, "mlp_silu")
        mlp_elmul = _kernel_by_name(payload, "mlp_elmul")
        names = {kernel["name"] for kernel in payload["kernels"]}

        self.assertEqual("rms_norm_layout_fused", input_norm["backend"])
        self.assertEqual("rms_norm_layout_fused", input_norm["app"])
        self.assertEqual("-m 128 -k 4096", input_norm["args"])
        self.assertEqual("rope_layout_fused", rope_q["backend"])
        self.assertIn("--layout-to gemm_a_tiled", rope_q["args"])
        self.assertEqual("rope_layout_fused", rope_k["backend"])
        self.assertEqual("row_major_fp16", rope_k["shape"]["layout_to"])
        self.assertIn("--layout-to row_major", rope_k["args"])
        self.assertEqual("kv_cache_quant_rope_k_to_attn_qkT", rope_k["shape"]["consumer"])
        self.assertEqual("softmax_layout_fused", softmax["backend"])
        self.assertEqual("gemm_a_tiled", softmax["shape"]["layout_to"])

        self.assertNotIn("layout_input_layernorm_to_qkv", names)
        self.assertNotIn("layout_attn_pv_to_head_concat_detile", names)
        self.assertNotIn("layout_attn_head_concat_to_o_proj", names)
        self.assertNotIn("layout_rope_k_qparams_to_attn_qkT", names)
        self.assertNotIn("layout_rope_k_to_attn_qkT", names)
        self.assertNotIn("layout_v_cache_qparams_to_attn_pv", names)
        self.assertNotIn("layout_v_cache_to_attn_pv", names)
        self.assertNotIn("layout_v_proj_to_v_cache_detile", names)
        self.assertEqual("head_concat_layout_fused", concat["backend"])
        self.assertIn("--layout-to gemm_a_tiled", concat["args"])
        self.assertEqual("gemm_c_tiled_per_head", concat["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", concat["shape"]["layout_to"])
        self.assertIn(
            {"role": "C", "target": "attn_head_concat", "layout": "gemm_c_tiled_per_head"},
            attn_pv["outputs"],
        )
        self.assertEqual("kv_cache_quant_layout_fused_w4a16", k_quant["backend"])
        self.assertEqual(
            "-k 128 -n 128 -q 128 -d 1 -t 1 --gemm-qdir 0 --source-transposed",
            k_quant["args"],
        )
        self.assertEqual("gemm_w_tiled_transposed", k_quant["shape"]["weight_layout_to"])
        self.assertEqual("sz_gemm_tiled_transposed", k_quant["shape"]["scale_zp_layout_to"])
        self.assertEqual(1, k_quant["shape"]["source_QDIR"])
        self.assertEqual(0, k_quant["shape"]["gemm_QDIR"])
        self.assertTrue(k_quant["shape"]["source_transposed"])
        self.assertEqual("attn_qkT", k_quant["shape"]["consumer"])
        self.assertEqual("kv_cache_quant_layout_fused_w4a16", v_quant["backend"])
        self.assertIn("--gemm-qdir 1", v_quant["args"])
        self.assertIn("--layout-from gemm_c_tiled", v_quant["args"])
        self.assertEqual("gemm_c_tiled", v_quant["shape"]["layout_from"])
        self.assertEqual("v_proj", v_quant["shape"]["producer"])
        self.assertIn(
            {"role": "x", "source": "v_proj", "layout": "gemm_c_tiled"},
            v_quant["inputs"],
        )
        self.assertEqual("gemm_w_tiled", v_quant["shape"]["weight_layout_to"])
        self.assertEqual("sz_gemm_tiled", v_quant["shape"]["scale_zp_layout_to"])
        self.assertEqual("attn_pv", v_quant["shape"]["consumer"])
        self.assertEqual("silu_layout_fused", mlp_silu["backend"])
        self.assertEqual("gemm_c_tiled", mlp_silu["shape"]["layout_from"])
        self.assertEqual("gemm_c_tiled", mlp_silu["shape"]["layout_to"])
        self.assertEqual("elmul_layout_fused", mlp_elmul["backend"])
        self.assertEqual("gemm_c_tiled", mlp_elmul["shape"]["layout_from"])
        self.assertEqual("gemm_a_tiled", mlp_elmul["shape"]["layout_to"])
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

    def test_layout_text_view_marks_gemm_and_fused_quant_layouts(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=8,
            qblk=32,
            variant=LAYOUT_FUSED_VARIANT,
        )

        text = format_layout_view(payload)

        self.assertIn("[stage: prefill]", text)
        self.assertIn("in : x         <- model_input", text)
        self.assertIn("out: hidden    -> model_output", text)
        self.assertIn("q_proj", text)
        self.assertIn(
            "M=8, N=4096, K=4096, QBLK=32, QDIR=0, WTRANS=0 "
            "| args='-m 8 -n 4096 -k 4096 -q 32 -t 0 -d 0'",
            text,
        )
        self.assertIn(
            "in : A         <- input_layernorm                            : gemm_a_tiled",
            text,
        )
        self.assertIn("in : W         <- param:q_proj.weight", text)
        self.assertIn("kv_cache_quant_rope_k_to_attn_qkT", text)
        self.assertIn(
            "out: W         -> attn_qkT                                   : gemm_w_tiled_transposed",
            text,
        )
        self.assertIn(
            "in : scale/zp  <- kv_cache_quant_rope_k_to_attn_qkT",
            text,
        )
        self.assertIn("in : x         <- v_proj", text)
        self.assertIn("in : y         <- up_proj", text)
        self.assertIn("out: silu      -> mlp_elmul", text)
        self.assertIn("in : x         <- mlp_silu", text)
        self.assertIn("out: product   -> down_proj", text)
        self.assertIn(
            "args='-batch 1 -seq 8 -heads 32 -headdim 128 -maxseq 4096 "
            "-offset 0 --layout-to gemm_a_tiled'",
            text,
        )
        self.assertIn(
            "args='-k 8 -n 128 -q 128 -d 1 -t 0 "
            "--gemm-qdir 1 --layout-from gemm_c_tiled'",
            text,
        )
        self.assertIn(": gemm_c_tiled", text)
        self.assertIn(": gemm_a_tiled", text)
        self.assertIn("head_concat_layout_fused", text)
        self.assertNotIn("embedding_lookup", text)
        self.assertNotIn("final_layernorm", text)
        self.assertNotIn("layout_rope_k_to_attn_qkT", text)
        self.assertNotIn("layout_fused_intermediate", text)

        attn_qk = _kernel_by_name(payload, "attn_qkT")
        self.assertIn(
            {
                "role": "W",
                "source": "kv_cache_quant_rope_k_to_attn_qkT",
                "layout": "gemm_w_tiled_transposed",
            },
            attn_qk["inputs"],
        )

    def test_layout_text_view_marks_standalone_kv_tile_edges(self) -> None:
        payload = build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=8,
            gen_kv_len=8,
            qblk=32,
            variant=LAYOUT_ALONE_VARIANT,
        )

        text = format_layout_view(payload)

        self.assertIn(
            "out: packed    -> layout_rope_k_to_attn_qkT                  : packed_w4a16_row_major",
            text,
        )
        self.assertIn(
            "out: scale/zp  -> layout_rope_k_qparams_to_attn_qkT          : qparams_row_major",
            text,
        )
        self.assertIn(
            "in : W         <- layout_rope_k_to_attn_qkT                  : gemm_w_tiled_transposed",
            text,
        )
        self.assertIn(
            "in : scale/zp  <- layout_v_cache_qparams_to_attn_pv          : sz_gemm_tiled",
            text,
        )

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
