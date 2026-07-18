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
    """Return a machine-readable advisory report for the v1 Llama2 contract."""
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
        "qk_asym_correction_out": {
            "layout_from": "gemm_c_tiled",
            "layout_to": "gemm_c_tiled",
            "query_layout": "gemm_a_tiled",
            "qparams_layout": "logical_row_major_fp16",
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
        ],
    }
