"""Advisory consistency check against tools/workload/gen_kernel_cfgs.py.

The generator is intentionally not imported by normal inference.  It is a
planning oracle for physical layouts, while this package remains an executable
and independently versioned accuracy harness.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
from typing import Any


GENERATOR_VARIANTS = {
    "standalone": "all_fpint_gemm_improve_alone_layout_spinquant",
    "fused": "all_fpint_gemm_improve_fused_layout_spinquant",
}


def _load_generator(path: Path):
    spec = importlib.util.spec_from_file_location("vortex_gen_kernel_cfgs", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load workload generator from {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _check_shape(
    mismatches: list[dict[str, Any]],
    by_name: dict[str, dict],
    name: str,
    expected: dict[str, Any],
) -> None:
    kernel = by_name.get(name)
    if kernel is None:
        mismatches.append({"kernel": name, "reason": "missing"})
        return
    shape = dict(kernel.get("shape") or {})
    for key, value in expected.items():
        if shape.get(key) != value:
            mismatches.append(
                {
                    "kernel": name,
                    "field": key,
                    "expected": value,
                    "actual": shape.get(key),
                }
            )


def check_generator_conformance(generator_path: str | Path | None = None) -> dict:
    """Return an advisory report for the executable Llama2/Llama3 contracts."""
    if generator_path is None:
        generator_path = Path(__file__).resolve().parents[4] / "tools/workload/gen_kernel_cfgs.py"
    path = Path(generator_path).resolve()
    generator = _load_generator(path)
    mismatches: list[dict[str, Any]] = []
    standalone_checks = {
        "layout_input_layernorm_to_qkv": {"M": 32, "K": 4096,
                                            "layout_to": "gemm_a_tiled"},
        "layout_q_proj_to_rope_q_detile": {"M": 32, "N": 4096,
                                             "layout_to": "row_major"},
        "spinquant_r3_q_hadamard": {"rows": 1024, "dim": 128,
                                      "spinquant_rotation": "R3"},
        "spinquant_r3_k_hadamard": {"rows": 1024, "dim": 128,
                                      "spinquant_rotation": "R3"},
        "kv_cache_quant_rope_k_to_attn_qkT": {
            "K": 32, "N": 128, "QBLK": 128, "QDIR": 1,
            "gemm_QDIR": 0, "WTRANS": 1, "source_transposed": True,
        },
        "layout_rope_k_to_attn_qkT": {
            "layout_to": "gemm_w_tiled_transposed", "source_transposed": True,
        },
        "attn_qkT": {"M": 32, "N": 32, "K": 128, "WTRANS": 1, "QDIR": 0},
        "kv_cache_quant_v_cache_to_attn_pv": {
            "K": 32, "N": 128, "QBLK": 128, "QDIR": 1,
            "gemm_QDIR": 1, "WTRANS": 0,
        },
        "attn_pv": {"M": 32, "N": 128, "K": 32, "WTRANS": 0, "QDIR": 1},
        "attn_head_concat": {"batch": 1, "seq": 32, "heads": 32,
                               "headdim": 128, "layout_to": "row_major"},
        "spinquant_r4_mlp_hadamard": {"rows": 32, "dim": 11008,
                                        "spinquant_rotation": "R4"},
        "layout_mlp_elmul_to_down_proj": {"M": 32, "K": 11008,
                                            "layout_from": "row_major_fp16",
                                            "layout_to": "gemm_a_tiled"},
    }
    fused_checks = {
        "input_layernorm": {"M": 32, "K": 4096, "layout_to": "gemm_a_tiled"},
        "rope_q": {"layout_from": "gemm_c_tiled", "layout_to": "head_major_row_fp16"},
        "rope_k": {"layout_from": "gemm_c_tiled", "layout_to": "head_major_row_fp16"},
        "spinquant_r3_q_hadamard": {
            "layout_from": "head_major_row_fp16", "layout_to": "gemm_a_tiled",
        },
        "spinquant_r3_k_hadamard": {
            "layout_from": "head_major_row_fp16", "layout_to": "gemm_a_tiled",
        },
        "kv_cache_quant_rope_k_to_attn_qkT": {
            "quant_mode": "spinquant_signed_asymmetric",
            "layout_from": "gemm_a_tiled",
            "gemm_QDIR": 0,
            "WTRANS": 1,
            "source_transposed": True,
        },
        "attn_softmax": {"layout_from": "gemm_c_tiled", "layout_to": "gemm_a_tiled"},
        "kv_cache_quant_v_cache_to_attn_pv": {
            "quant_mode": "spinquant_signed_symmetric",
            "source_total_n": 4096,
            "layout_from": "gemm_c_tiled",
        },
        "attn_head_concat": {
            "layout_from": "gemm_c_tiled_per_head",
            "layout_to": "gemm_a_tiled",
        },
        "residual_attn": {"layout_from": "gemm_c_tiled", "layout_to": "row_major"},
        "spinquant_r4_mlp_hadamard": {
            "layout_from": "row_major_fp16",
            "layout_to": "gemm_a_tiled",
        },
        "residual_ffn": {"layout_from": "gemm_c_tiled", "layout_to": "row_major"},
    }
    checked: dict[str, list[str]] = {}
    for plan, variant in GENERATOR_VARIANTS.items():
        payload = generator.build_llm_kernels(
            model_name="llama2-7b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=32,
            gen_kv_len=32,
            qblk=32,
            variant=variant,
        )
        model = payload["model_config"]
        for field, expected in {
            "hidden_size": 4096,
            "intermediate_size": 11008,
            "num_attention_heads": 32,
            "head_dim": 128,
        }.items():
            if model.get(field) != expected:
                mismatches.append(
                    {"plan": plan, "kernel": "model_config", "field": field,
                     "expected": expected, "actual": model.get(field)}
                )
        by_name = {kernel["name"]: kernel for kernel in payload["kernels"]}
        plan_checks = standalone_checks if plan == "standalone" else fused_checks
        local_mismatches: list[dict[str, Any]] = []
        for name, expected in plan_checks.items():
            _check_shape(local_mismatches, by_name, name, expected)
        mismatches.extend({"plan": plan, **item} for item in local_mismatches)
        checked[plan] = list(plan_checks)

        generation = generator.build_llm_kernels(
            model_name="llama2-7b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=31,
            gen_kv_len=33,
            max_seq_len=64,
            qblk=32,
            variant=variant,
        )
        generation_by_name = {
            kernel["name"]: kernel for kernel in generation["kernels"]
        }
        generation_checks = {
            "kv_cache_quant_rope_k_to_attn_qkT": {
                "K": 1,
                "cache_update": "append",
                "cache_position": 33,
                "logical_cache_length": 34,
                "cache_capacity": 64,
                "persistent_layout": "gemm_w_tiled_transposed",
            },
            "kv_cache_quant_v_cache_to_attn_pv": {
                "K": 1,
                "cache_update": "append",
                "cache_position": 33,
                "logical_cache_length": 34,
                "cache_capacity": 64,
                "persistent_layout": "gemm_w_tiled",
            },
            "attn_qkT": {
                "M": 1,
                "N": 128,
                "K": 128,
                "cache_capacity": 64,
            },
            "attn_softmax": {
                "seqq": 1,
                "seqk": 64,
                "mask": 0,
                "capacity_stride": 64,
            },
            "attn_pv": {
                "M": 1,
                "N": 128,
                "K": 128,
                "cache_capacity": 64,
            },
            "rope_q": {"seq": 1, "offset": 33},
            "rope_k": {"seq": 1, "offset": 33},
        }
        local_mismatches = []
        for name, expected in generation_checks.items():
            _check_shape(local_mismatches, generation_by_name, name, expected)
        mismatches.extend(
            {"plan": plan, "stage": "generation", **item}
            for item in local_mismatches
        )
        checked[f"{plan}_generation"] = list(generation_checks)

        llama3 = generator.build_llm_kernels(
            model_name="llama3-8b",
            stages=["generation"],
            batch=1,
            prefill_seq_len=31,
            gen_kv_len=33,
            max_seq_len=64,
            qblk=32,
            variant=variant,
        )
        llama3_model = llama3["model_config"]
        for field, expected in {
            "hidden_size": 4096,
            "intermediate_size": 14336,
            "num_attention_heads": 32,
            "num_key_value_heads": 8,
            "head_dim": 128,
        }.items():
            if llama3_model.get(field) != expected:
                mismatches.append(
                    {
                        "plan": plan,
                        "stage": "llama3_generation",
                        "kernel": "model_config",
                        "field": field,
                        "expected": expected,
                        "actual": llama3_model.get(field),
                    }
                )
        llama3_by_name = {kernel["name"]: kernel for kernel in llama3["kernels"]}
        llama3_checks = {
            "k_proj": {"N": 1024},
            "v_proj": {"N": 1024},
            "attn_qkT": {
                "M": 4,
                "query_heads": 32,
                "key_value_heads": 8,
                "query_heads_per_kv": 4,
                "grouped_query_attention": True,
            },
            "attn_pv": {
                "M": 4,
                "query_heads_per_kv": 4,
                "grouped_query_attention": True,
            },
        }
        if plan == "fused":
            llama3_checks.update(
                {
                    "spinquant_r3_q_hadamard": {
                        "matrix_count": 8,
                        "rows_per_matrix": 4,
                        "query_heads_per_kv": 4,
                        "m_pad": 8,
                    },
                    "attn_head_concat": {
                        "query_heads_per_kv": 4,
                        "input_matrix_count": 8,
                    },
                    "spinquant_r4_mlp_hadamard": {
                        "dim": 14336,
                        "spinquant_rotation": "R4",
                    },
                }
            )
        local_mismatches = []
        for name, expected in llama3_checks.items():
            _check_shape(local_mismatches, llama3_by_name, name, expected)
        mismatches.extend(
            {"plan": plan, "stage": "llama3_generation", **item}
            for item in local_mismatches
        )
        checked[f"{plan}_llama3_generation"] = list(llama3_checks)

        llama3_prefill = generator.build_llm_kernels(
            model_name="llama3-8b",
            stages=["prefill"],
            batch=1,
            prefill_seq_len=32,
            gen_kv_len=32,
            max_seq_len=32,
            qblk=32,
            variant=variant,
        )
        llama3_prefill_by_name = {
            kernel["name"]: kernel for kernel in llama3_prefill["kernels"]
        }
        llama3_prefill_checks = {
            "k_proj": {"M": 32, "N": 1024, "K": 4096},
            "v_proj": {"M": 32, "N": 1024, "K": 4096},
            "attn_qkT": {"M": 32, "N": 32, "K": 128},
            "attn_pv": {"M": 32, "N": 128, "K": 32},
        }
        if plan == "standalone":
            llama3_prefill_checks.update(
                {
                    "layout_k_proj_to_rope_k_detile": {"M": 32, "N": 1024},
                    "layout_v_proj_to_v_cache_detile": {"M": 32, "N": 1024},
                }
            )
        else:
            llama3_prefill_checks.update(
                {
                    "spinquant_r3_q_hadamard": {
                        "matrix_count": 32,
                        "rows_per_matrix": 32,
                        "query_heads_per_kv": 1,
                    },
                    "spinquant_r3_k_hadamard": {
                        "matrix_count": 8,
                        "rows_per_matrix": 32,
                    },
                    "attn_head_concat": {
                        "query_heads_per_kv": 1,
                        "input_matrix_count": 32,
                    },
                }
            )
        local_mismatches = []
        for name, expected in llama3_prefill_checks.items():
            _check_shape(
                local_mismatches, llama3_prefill_by_name, name, expected
            )
        mismatches.extend(
            {"plan": plan, "stage": "llama3_prefill", **item}
            for item in local_mismatches
        )
        checked[f"{plan}_llama3_prefill"] = list(llama3_prefill_checks)

    return {
        "passed": not mismatches,
        "advisory_only": True,
        "generator": str(path),
        "variant": GENERATOR_VARIANTS["standalone"],
        "variants": GENERATOR_VARIANTS,
        "checked_kernels": checked["standalone"],
        "checked_kernels_by_plan": checked,
        "mismatches": mismatches,
        "intentional_deviations": [
            "The generator models all decoder layers through calls_per_forward; the harness executes one layer.",
            "The harness keeps layout transforms inside VortexBackend instead of semantic graph stages.",
            "R4 uses SpinQuant's exact hadK decomposition, while the generator records the abstract R4 operation.",
            "The generator is advisory; executable tensor descriptors define axis and stride semantics.",
            "Fused V quant CLI args represent head 0; head_col_offset metadata is symbolic and the harness binds each head explicitly.",
            "Llama3 decode groups four query heads per KV head into one M=4 attention matrix.",
            "Llama3 prefill keeps one M=S matrix per query head and shares each KV payload across four launches.",
        ],
    }
