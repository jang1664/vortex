#!/usr/bin/env python3
"""Generate kernel configurations for one LLM forward pass.

Emit the full kernel call list for one forward pass of a model in each
requested stage (prefill / generation), including non-GEMM ops
(RMSNorm, RoPE, softmax, SiLU, residual eladd, SwiGLU elmul). Each kernel
is tagged with how many times it is invoked per forward pass and whether
the corresponding regression test app exists ("implemented").

Importable: ci/test_fpint_hw.py reuses build_fpint_gemm_args_for_model to
drive its HW regression sweep — extracting only the fpint GEMM calls out
of the full LLM kernel list.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Model registry. Add entries here to extend coverage.
# ---------------------------------------------------------------------------
MODELS: dict[str, dict[str, int]] = {
    "llama2-7b": {
        "hidden_size": 4096,
        "intermediate_size": 11008,
        "num_attention_heads": 32,
        "num_key_value_heads": 32,   # MHA (no GQA)
        "head_dim": 128,
        "num_layers": 32,
        "vocab_size": 32000,
        "max_position_embeddings": 4096,
    },
    # Future models can be added here, e.g.:
    # "llama2-13b":  {"hidden_size": 5120, "intermediate_size": 13824,
    #                 "num_attention_heads": 40, "num_key_value_heads": 40,
    #                 "head_dim": 128, "num_layers": 40, "vocab_size": 32000,
    #                 "max_position_embeddings": 4096},
    # "llama3-8b":   {"hidden_size": 4096, "intermediate_size": 14336,
    #                 "num_attention_heads": 32, "num_key_value_heads": 8,
    #                 "head_dim": 128, "num_layers": 32, "vocab_size": 128256,
    #                 "max_position_embeddings": 8192},
    # "mistral-7b":  {"hidden_size": 4096, "intermediate_size": 14336,
    #                 "num_attention_heads": 32, "num_key_value_heads": 8,
    #                 "head_dim": 128, "num_layers": 32, "vocab_size": 32000,
    #                 "max_position_embeddings": 32768},
}

# Defaults for the LLM-mode CLI.
DEFAULT_LLM_BATCH = 1
DEFAULT_LLM_PREFILL_SEQ = 128
DEFAULT_LLM_GEN_KV = 128
DEFAULT_LLM_QBLK = 32

# Defaults exposed for the HW-regression driver in ci/test_fpint_hw.py.
DEFAULT_QBLKS = [32, 64, 128]
DEFAULT_SEQ_LENS = [32, 128, 512, 1024]

LLM_STAGES = ("prefill", "generation")
FPINT_GEMM_NAIVE_BACKEND = "fpint_gemm_naive"
FPINT_GEMM_IMPROVE_BACKEND = "fpint_gemm_improve"
FPINT_GEMM_BACKENDS = frozenset((
    FPINT_GEMM_NAIVE_BACKEND,
    FPINT_GEMM_IMPROVE_BACKEND,
))
ALL_FPINT_GEMM_NAIVE_VARIANT = "all_fpint_gemm_naive"
ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT = "attn_sgemm_tcu_fpint_gemm_naive"
ALL_FPINT_GEMM_IMPROVE_VARIANT = "all_fpint_gemm_improve"
ATTN_SGEMM_TCU_FPINT_GEMM_IMPROVE_VARIANT = "attn_sgemm_tcu_fpint_gemm_improve"
ALL_SGEMM_TCU_VARIANT = "all_sgemm_tcu"
LAYOUT_ALONE_VARIANT = "all_fpint_gemm_improve_alone_layout"
LAYOUT_FUSED_VARIANT = "all_fpint_gemm_improve_fused_layout"
WORKLOAD_VARIANTS = (
    ALL_FPINT_GEMM_NAIVE_VARIANT,
    ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT,
    ALL_FPINT_GEMM_IMPROVE_VARIANT,
    ATTN_SGEMM_TCU_FPINT_GEMM_IMPROVE_VARIANT,
    ALL_SGEMM_TCU_VARIANT,
    LAYOUT_ALONE_VARIANT,
    LAYOUT_FUSED_VARIANT,
)
DEFAULT_WORKLOAD_VARIANT = ALL_FPINT_GEMM_IMPROVE_VARIANT
ATTENTION_GEMM_OPS = frozenset(("attn_qkT", "attn_pv"))
LAYOUT_MXU_KT = 32
LAYOUT_MXU_NT = 32

# Map backend -> regression test/app name. None means the
# corresponding kernel is not yet implemented as a regression test, so the
# generated entry will have ``"implemented": false`` and an empty ``args``.
KERNEL_APP_REGISTRY: dict[str, str | None] = {
    FPINT_GEMM_NAIVE_BACKEND: "fpint_gemm_ffn_hw_naive",
    FPINT_GEMM_IMPROVE_BACKEND: "fpint_gemm_ffn_hw",
    "sgemm_tcu":  "sgemm_tcu",
    "tile_input_a": "tile_input_a",
    "detile_output": "detile_output",
    "tile_weight_w4a16": "tile_weight_w4a16",
    "rms_norm_layout_fused": "rms_norm_layout_fused",
    "silu_layout_fused": "silu_layout_fused",
    "rope_layout_fused": "rope_layout_fused",
    "softmax_layout_fused": "softmax_layout_fused",
    "eladd_layout_fused": "eladd_layout_fused",
    "elmul_layout_fused": "elmul_layout_fused",
    "head_concat": "head_concat",
    "head_concat_layout_fused": "head_concat_layout_fused",
    "rmsnorm":    "rmsnorm",
    "rope":       "rope",
    "softmax":    "softmax",
    "silu":       "silu",
    "eladd":      "eladd",
    "elmul":      "elmul",
    "kv_cache_quant_w4a16": "kv_cache_quant_w4a16",
    "kv_cache_dequant_w4a16": "kv_cache_dequant_w4a16",
    # No regression test yet:
    "embedding":  None,
}


# ===========================================================================
# Per-decoder-pass kernel emission.
# ===========================================================================
def _llm_kernel(name: str,
                kind: str,
                stage: str,
                args: str,
                calls_per_forward: int,
                shape: dict,
                *,
                backend: str | None = None,
                variant: str = DEFAULT_WORKLOAD_VARIANT) -> dict:
    """Wrap a single kernel invocation in the standard JSON shape."""
    backend = backend or kind
    app = KERNEL_APP_REGISTRY.get(backend)
    return {
        "stage": stage,
        "name": name,
        "op": name,
        "kind": kind,
        "backend": backend,
        "variant": variant,
        "app": app,
        "implemented": app is not None,
        "calls_per_forward": calls_per_forward,
        "shape": shape,
        "args": args if app is not None else "",
    }


def _gemm_backend(op: str, variant: str) -> str:
    if variant == ALL_FPINT_GEMM_NAIVE_VARIANT:
        return FPINT_GEMM_NAIVE_BACKEND
    if variant in (
        ALL_FPINT_GEMM_IMPROVE_VARIANT,
        LAYOUT_ALONE_VARIANT,
        LAYOUT_FUSED_VARIANT,
    ):
        return FPINT_GEMM_IMPROVE_BACKEND
    if variant == ALL_SGEMM_TCU_VARIANT:
        return "sgemm_tcu"
    if variant == ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT:
        return "sgemm_tcu" if op in ATTENTION_GEMM_OPS else FPINT_GEMM_NAIVE_BACKEND
    if variant == ATTN_SGEMM_TCU_FPINT_GEMM_IMPROVE_VARIANT:
        return "sgemm_tcu" if op in ATTENTION_GEMM_OPS else FPINT_GEMM_IMPROVE_BACKEND
    raise ValueError(
        f"unknown variant: {variant!r}. Expected one of {WORKLOAD_VARIANTS}"
    )


def _gemm_args(backend: str, *, M: int, N: int, K: int, qblk: int, wtrans: int, qdir: int) -> str:
    if backend in FPINT_GEMM_BACKENDS:
        return f"-m {M} -n {N} -k {K} -q {qblk} -t {wtrans} -d {qdir}"
    if backend == "sgemm_tcu":
        return f"-m {M} -n {N} -k {K}"
    raise ValueError(f"unknown GEMM backend: {backend!r}")


def _gemm_shape(backend: str, *, M: int, N: int, K: int, qblk: int, wtrans: int, qdir: int, per_head: bool = False) -> dict:
    shape = {"M": M, "N": N, "K": K}
    if backend in FPINT_GEMM_BACKENDS:
        shape.update({"QBLK": qblk, "WTRANS": wtrans, "QDIR": qdir})
    if per_head:
        shape["per_head"] = True
    return shape


def _llm_gemm_kernel(name: str,
                     stage: str,
                     calls_per_forward: int,
                     *,
                     M: int,
                     N: int,
                     K: int,
                     qblk: int,
                     wtrans: int,
                     qdir: int,
                     variant: str,
                     per_head: bool = False) -> dict:
    backend = _gemm_backend(name, variant)
    return _llm_kernel(
        name=name,
        kind="gemm",
        backend=backend,
        stage=stage,
        args=_gemm_args(backend, M=M, N=N, K=K, qblk=qblk, wtrans=wtrans, qdir=qdir),
        calls_per_forward=calls_per_forward,
        shape=_gemm_shape(backend, M=M, N=N, K=K, qblk=qblk, wtrans=wtrans, qdir=qdir, per_head=per_head),
        variant=variant,
    )


def _align_up(value: int, alignment: int) -> int:
    return ((value + alignment - 1) // alignment) * alignment


def _layout_kernel(name: str,
                   stage: str,
                   backend: str,
                   args: str,
                   calls_per_forward: int,
                   shape: dict,
                   *,
                   variant: str) -> dict:
    return _llm_kernel(
        name=name,
        kind="layout",
        backend=backend,
        stage=stage,
        args=args,
        calls_per_forward=calls_per_forward,
        shape=shape,
        variant=variant,
    )


def _tile_input_kernel(name: str,
                       stage: str,
                       *,
                       M: int,
                       K: int,
                       calls_per_forward: int,
                       producer: str,
                       consumer: str,
                       layout_group: str,
                       layout_from: str = "row_major",
                       variant: str) -> dict:
    return _layout_kernel(
        name=name,
        stage=stage,
        backend="tile_input_a",
        args=f"-m {M} -k {K}",
        calls_per_forward=calls_per_forward,
        shape={
            "M": M,
            "K": K,
            "layout_from": layout_from,
            "layout_to": "gemm_a_tiled",
            "producer": producer,
            "consumer": consumer,
            "layout_group": layout_group,
        },
        variant=variant,
    )


def _detile_output_kernel(name: str,
                          stage: str,
                          *,
                          M: int,
                          N: int,
                          calls_per_forward: int,
                          producer: str,
                          consumer: str,
                          layout_group: str,
                          variant: str) -> dict:
    return _layout_kernel(
        name=name,
        stage=stage,
        backend="detile_output",
        args=f"-m {M} -n {N}",
        calls_per_forward=calls_per_forward,
        shape={
            "M": M,
            "N": N,
            "layout_from": "gemm_c_tiled",
            "layout_to": "row_major",
            "producer": producer,
            "consumer": consumer,
            "layout_group": layout_group,
        },
        variant=variant,
    )


def _tile_weight_kernel(name: str,
                        stage: str,
                        *,
                        K: int,
                        N: int,
                        WTRANS: int,
                        calls_per_forward: int,
                        producer: str,
                        consumer: str,
                        layout_group: str,
                        variant: str,
                        effective_K: int | None = None,
                        effective_N: int | None = None,
                        cache_len: int | None = None,
                        cache_update: str = "full") -> dict:
    shape = {
        "K": K,
        "N": N,
        "WTRANS": WTRANS,
        "layout_from": "row_major",
        "layout_to": "gemm_w_tiled",
        "producer": producer,
        "consumer": consumer,
        "layout_group": layout_group,
        "cache_update": cache_update,
    }
    if effective_K is not None:
        shape["effective_K"] = effective_K
    if effective_N is not None:
        shape["effective_N"] = effective_N
    if cache_len is not None:
        shape["cache_len"] = cache_len
    return _layout_kernel(
        name=name,
        stage=stage,
        backend="tile_weight_w4a16",
        args=f"-k {K} -n {N} -t {WTRANS}",
        calls_per_forward=calls_per_forward,
        shape=shape,
        variant=variant,
    )


def _head_concat_kernel(stage: str,
                        *,
                        batch: int,
                        seq: int,
                        heads: int,
                        head_dim: int,
                        calls_per_forward: int,
                        variant: str,
                        backend: str = "head_concat",
                        layout_from: str = "row_major",
                        layout_to: str = "row_major") -> dict:
    args = f"-batch {batch} -seq {seq} -heads {heads} -headdim {head_dim}"
    if backend == "head_concat_layout_fused":
        args = f"{args} --layout-to {layout_to}"
    return _llm_kernel(
        name="attn_head_concat",
        kind="concat",
        backend=backend,
        stage=stage,
        args=args,
        calls_per_forward=calls_per_forward,
        shape={
            "batch": batch,
            "seq": seq,
            "heads": heads,
            "headdim": head_dim,
            "hidden": heads * head_dim,
            "layout_from": layout_from,
            "layout_to": layout_to,
            "producer": "attn_pv",
            "consumer": "o_proj",
            "layout_group": "attn_pv_to_head_concat_to_o_proj",
        },
        variant=variant,
    )


def _with_fused_backend(kernel: dict,
                        backend: str,
                        *,
                        args: str | None = None,
                        shape_update: dict | None = None) -> dict:
    shape = dict(kernel.get("shape") or {})
    if shape_update:
        shape.update(shape_update)
    return _llm_kernel(
        name=str(kernel["name"]),
        kind=str(kernel["kind"]),
        backend=backend,
        stage=str(kernel["stage"]),
        args=str(kernel["args"] if args is None else args),
        calls_per_forward=int(kernel["calls_per_forward"]),
        shape=shape,
        variant=str(kernel["variant"]),
    )


def _kv_tile_weight_k_shape(stage: str, seq_kv: int, head_dim: int) -> tuple[int, int, int, int, str]:
    if stage == "generation":
        effective_n = 1
        return head_dim, _align_up(effective_n, LAYOUT_MXU_NT), head_dim, effective_n, "append"
    return head_dim, _align_up(seq_kv, LAYOUT_MXU_NT), head_dim, seq_kv, "full"


def _kv_tile_weight_v_shape(stage: str, seq_kv: int, head_dim: int) -> tuple[int, int, int, int, str]:
    if stage == "generation":
        effective_k = 1
        return _align_up(effective_k, LAYOUT_MXU_KT), head_dim, effective_k, head_dim, "append"
    return _align_up(seq_kv, LAYOUT_MXU_KT), head_dim, seq_kv, head_dim, "full"


def _apply_standalone_layout_variant(kernels: list[dict],
                                     *,
                                     stage: str,
                                     batch: int,
                                     seq_q: int,
                                     seq_kv: int,
                                     hidden: int,
                                     intermediate: int,
                                     layers: int,
                                     heads_q: int,
                                     heads_kv: int,
                                     head_dim: int,
                                     q_dim: int,
                                     M_proj: int,
                                     variant: str) -> list[dict]:
    by_name = {kernel["name"]: kernel for kernel in kernels}
    per_head_q = layers * batch * heads_q
    per_head_kv = layers * batch * heads_kv
    k_K, k_N, k_eff_K, k_eff_N, k_update = _kv_tile_weight_k_shape(stage, seq_kv, head_dim)
    v_K, v_N, v_eff_K, v_eff_N, v_update = _kv_tile_weight_v_shape(stage, seq_kv, head_dim)

    return [
        by_name["embedding_lookup"],
        by_name["input_layernorm"],
        _tile_input_kernel(
            "layout_input_layernorm_to_qkv", stage,
            M=M_proj, K=hidden, calls_per_forward=layers,
            producer="input_layernorm", consumer="q_proj,k_proj,v_proj",
            layout_group="input_layernorm_to_qkv", variant=variant,
        ),
        by_name["q_proj"],
        by_name["k_proj"],
        by_name["v_proj"],
        _detile_output_kernel(
            "layout_q_proj_to_rope_q_detile", stage,
            M=M_proj, N=q_dim, calls_per_forward=layers,
            producer="q_proj", consumer="rope_q",
            layout_group="q_proj_to_rope_q", variant=variant,
        ),
        by_name["rope_q"],
        _detile_output_kernel(
            "layout_k_proj_to_rope_k_detile", stage,
            M=M_proj, N=q_dim, calls_per_forward=layers,
            producer="k_proj", consumer="rope_k",
            layout_group="k_proj_to_rope_k", variant=variant,
        ),
        by_name["rope_k"],
        _tile_input_kernel(
            "layout_rope_q_to_attn_qkT", stage,
            M=seq_q, K=head_dim, calls_per_forward=per_head_q,
            producer="rope_q", consumer="attn_qkT",
            layout_group="rope_q_to_attn_qkT", variant=variant,
        ),
        _tile_weight_kernel(
            "layout_rope_k_to_attn_qkT", stage,
            K=k_K, N=k_N, WTRANS=1, calls_per_forward=per_head_kv,
            producer="rope_k", consumer="attn_qkT",
            layout_group="rope_k_to_attn_qkT", variant=variant,
            effective_K=k_eff_K, effective_N=k_eff_N,
            cache_len=seq_kv, cache_update=k_update,
        ),
        by_name["attn_qkT"],
        _detile_output_kernel(
            "layout_attn_qkT_to_softmax_detile", stage,
            M=seq_q, N=seq_kv, calls_per_forward=per_head_q,
            producer="attn_qkT", consumer="attn_softmax",
            layout_group="attn_qkT_to_softmax", variant=variant,
        ),
        by_name["attn_softmax"],
        _tile_input_kernel(
            "layout_attn_softmax_to_attn_pv", stage,
            M=seq_q, K=seq_kv, calls_per_forward=per_head_q,
            producer="attn_softmax", consumer="attn_pv",
            layout_group="attn_softmax_to_attn_pv", variant=variant,
        ),
        _detile_output_kernel(
            "layout_v_proj_to_v_cache_detile", stage,
            M=M_proj, N=q_dim, calls_per_forward=layers,
            producer="v_proj", consumer="v_cache",
            layout_group="v_proj_to_attn_pv", variant=variant,
        ),
        _tile_weight_kernel(
            "layout_v_cache_to_attn_pv", stage,
            K=v_K, N=v_N, WTRANS=0, calls_per_forward=per_head_kv,
            producer="v_cache", consumer="attn_pv",
            layout_group="v_cache_to_attn_pv", variant=variant,
            effective_K=v_eff_K, effective_N=v_eff_N,
            cache_len=seq_kv, cache_update=v_update,
        ),
        by_name["attn_pv"],
        _detile_output_kernel(
            "layout_attn_pv_to_head_concat_detile", stage,
            M=seq_q, N=head_dim, calls_per_forward=per_head_q,
            producer="attn_pv", consumer="attn_head_concat",
            layout_group="attn_pv_to_head_concat", variant=variant,
        ),
        _head_concat_kernel(
            stage,
            batch=batch, seq=seq_q, heads=heads_q, head_dim=head_dim,
            calls_per_forward=layers, variant=variant,
            layout_from="row_major", layout_to="row_major",
        ),
        _tile_input_kernel(
            "layout_attn_head_concat_to_o_proj", stage,
            M=M_proj, K=q_dim, calls_per_forward=layers,
            producer="attn_head_concat", consumer="o_proj",
            layout_group="attn_head_concat_to_o_proj", variant=variant,
        ),
        by_name["o_proj"],
        _detile_output_kernel(
            "layout_o_proj_to_residual_attn_detile", stage,
            M=M_proj, N=hidden, calls_per_forward=layers,
            producer="o_proj", consumer="residual_attn",
            layout_group="o_proj_to_residual_attn", variant=variant,
        ),
        by_name["residual_attn"],
        by_name["post_attention_layernorm"],
        _tile_input_kernel(
            "layout_post_attention_layernorm_to_gate_up", stage,
            M=M_proj, K=hidden, calls_per_forward=layers,
            producer="post_attention_layernorm", consumer="gate_proj,up_proj",
            layout_group="post_attention_layernorm_to_gate_up", variant=variant,
        ),
        by_name["gate_proj"],
        by_name["up_proj"],
        _detile_output_kernel(
            "layout_gate_proj_to_mlp_silu_detile", stage,
            M=M_proj, N=intermediate, calls_per_forward=layers,
            producer="gate_proj", consumer="mlp_silu",
            layout_group="gate_proj_to_mlp_silu", variant=variant,
        ),
        by_name["mlp_silu"],
        _detile_output_kernel(
            "layout_up_proj_to_mlp_elmul_detile", stage,
            M=M_proj, N=intermediate, calls_per_forward=layers,
            producer="up_proj", consumer="mlp_elmul",
            layout_group="up_proj_to_mlp_elmul", variant=variant,
        ),
        by_name["mlp_elmul"],
        _tile_input_kernel(
            "layout_mlp_elmul_to_down_proj", stage,
            M=M_proj, K=intermediate, calls_per_forward=layers,
            producer="mlp_elmul", consumer="down_proj",
            layout_group="mlp_elmul_to_down_proj", variant=variant,
        ),
        by_name["down_proj"],
        _detile_output_kernel(
            "layout_down_proj_to_residual_ffn_detile", stage,
            M=M_proj, N=hidden, calls_per_forward=layers,
            producer="down_proj", consumer="residual_ffn",
            layout_group="down_proj_to_residual_ffn", variant=variant,
        ),
        by_name["residual_ffn"],
        by_name["final_layernorm"],
    ]


def _apply_fused_layout_variant(kernels: list[dict],
                                *,
                                stage: str,
                                batch: int,
                                seq_q: int,
                                seq_kv: int,
                                hidden: int,
                                intermediate: int,
                                layers: int,
                                heads_q: int,
                                heads_kv: int,
                                head_dim: int,
                                q_dim: int,
                                M_proj: int,
                                variant: str) -> list[dict]:
    by_name = {kernel["name"]: kernel for kernel in kernels}
    per_head_q = layers * batch * heads_q
    per_head_kv = layers * batch * heads_kv
    v_K, v_N, v_eff_K, v_eff_N, v_update = _kv_tile_weight_v_shape(stage, seq_kv, head_dim)

    return [
        by_name["embedding_lookup"],
        _with_fused_backend(
            by_name["input_layernorm"], "rms_norm_layout_fused",
            args=f"-m {M_proj} -k {hidden}",
            shape_update={
                "M": M_proj, "K": hidden,
                "layout_from": "row_major", "layout_to": "gemm_a_tiled",
                "layout_group": "input_layernorm_to_qkv",
            },
        ),
        by_name["q_proj"],
        by_name["k_proj"],
        by_name["v_proj"],
        _with_fused_backend(
            by_name["rope_q"], "rope_layout_fused",
            args=f"{by_name['rope_q']['args']} --layout-to gemm_a_tiled",
            shape_update={
                "layout_from": "gemm_c_tiled", "layout_to": "gemm_a_tiled",
                "producer": "q_proj", "consumer": "attn_qkT",
                "layout_group": "q_proj_to_rope_q_to_attn_qkT",
            },
        ),
        _with_fused_backend(
            by_name["rope_k"], "rope_layout_fused",
            args=f"{by_name['rope_k']['args']} --layout-to gemm_w_tiled",
            shape_update={
                "layout_from": "gemm_c_tiled", "layout_to": "gemm_w_tiled",
                "producer": "k_proj", "consumer": "attn_qkT",
                "layout_group": "k_proj_to_rope_k_to_attn_qkT",
                "cache_update": "append" if stage == "generation" else "full",
                "cache_len": seq_kv,
            },
        ),
        by_name["attn_qkT"],
        _with_fused_backend(
            by_name["attn_softmax"], "softmax_layout_fused",
            shape_update={
                "layout_from": "gemm_c_tiled", "layout_to": "gemm_a_tiled",
                "producer": "attn_qkT", "consumer": "attn_pv",
                "layout_group": "attn_qkT_to_softmax_to_attn_pv",
            },
        ),
        _detile_output_kernel(
            "layout_v_proj_to_v_cache_detile", stage,
            M=M_proj, N=q_dim, calls_per_forward=layers,
            producer="v_proj", consumer="v_cache",
            layout_group="v_proj_to_attn_pv", variant=variant,
        ),
        _tile_weight_kernel(
            "layout_v_cache_to_attn_pv", stage,
            K=v_K, N=v_N, WTRANS=0, calls_per_forward=per_head_kv,
            producer="v_cache", consumer="attn_pv",
            layout_group="v_cache_to_attn_pv", variant=variant,
            effective_K=v_eff_K, effective_N=v_eff_N,
            cache_len=seq_kv, cache_update=v_update,
        ),
        by_name["attn_pv"],
        _head_concat_kernel(
            stage,
            batch=batch, seq=seq_q, heads=heads_q, head_dim=head_dim,
            calls_per_forward=layers, variant=variant,
            backend="head_concat_layout_fused",
            layout_from="gemm_c_tiled_per_head", layout_to="gemm_a_tiled",
        ),
        by_name["o_proj"],
        _with_fused_backend(
            by_name["residual_attn"], "eladd_layout_fused",
            args=f"-m {M_proj} -k {hidden}",
            shape_update={
                "M": M_proj, "K": hidden,
                "layout_from": "gemm_c_tiled", "layout_to": "row_major",
                "producer": "o_proj", "consumer": "residual_attn",
                "layout_group": "o_proj_to_residual_attn",
            },
        ),
        _with_fused_backend(
            by_name["post_attention_layernorm"], "rms_norm_layout_fused",
            args=f"-m {M_proj} -k {hidden}",
            shape_update={
                "M": M_proj, "K": hidden,
                "layout_from": "row_major", "layout_to": "gemm_a_tiled",
                "layout_group": "post_attention_layernorm_to_gate_up",
            },
        ),
        by_name["gate_proj"],
        by_name["up_proj"],
        _with_fused_backend(
            by_name["mlp_silu"], "silu_layout_fused",
            args=f"-m {M_proj} -k {intermediate}",
            shape_update={
                "M": M_proj, "K": intermediate,
                "layout_from": "gemm_c_tiled", "layout_to": "layout_fused_intermediate",
                "producer": "gate_proj", "consumer": "mlp_elmul",
                "layout_group": "gate_proj_to_mlp_silu_to_mlp_elmul",
            },
        ),
        _with_fused_backend(
            by_name["mlp_elmul"], "elmul_layout_fused",
            args=f"-m {M_proj} -k {intermediate}",
            shape_update={
                "M": M_proj, "K": intermediate,
                "layout_from": "layout_fused_intermediate", "layout_to": "gemm_a_tiled",
                "producer": "mlp_silu,up_proj", "consumer": "down_proj",
                "layout_group": "mlp_elmul_to_down_proj",
            },
        ),
        by_name["down_proj"],
        _with_fused_backend(
            by_name["residual_ffn"], "eladd_layout_fused",
            args=f"-m {M_proj} -k {hidden}",
            shape_update={
                "M": M_proj, "K": hidden,
                "layout_from": "gemm_c_tiled", "layout_to": "row_major",
                "producer": "down_proj", "consumer": "residual_ffn",
                "layout_group": "down_proj_to_residual_ffn",
            },
        ),
        by_name["final_layernorm"],
    ]


def build_decoder_pass_kernels(config: dict,
                               stage: str,
                               batch: int,
                               seq_q: int,
                               seq_kv: int,
                               qblk: int,
                               variant: str = DEFAULT_WORKLOAD_VARIANT) -> list[dict]:
    """Emit every kernel that fires during one forward pass of the model
    in the given stage.

    Args:
      config: row from MODELS (must include num_layers, vocab_size).
      stage: "prefill" or "generation".
      batch: batch size.
      seq_q: query sequence length per forward pass.
        - prefill:    S (prompt length)
        - generation: 1 (one new token)
      seq_kv: key/value sequence length used in attention.
        - prefill:    S
        - generation: past_len + 1 (KV cache size including the new token)
      qblk: QBLK for fpint GEMMs (FFN + QKVO projections).

    Counts (calls_per_forward):
      Per-decoder-layer kernels are multiplied by num_layers (L).
      Attention QK^T / PV are per-head per-batch, so multiplied further by
      batch * num_attention_heads. Model-level kernels (embedding,
      final_layernorm) fire exactly once per forward pass.
    """
    if stage not in LLM_STAGES:
        raise ValueError(f"unknown stage: {stage!r}. Expected one of {LLM_STAGES}")
    if variant not in WORKLOAD_VARIANTS:
        raise ValueError(
            f"unknown variant: {variant!r}. Expected one of {WORKLOAD_VARIANTS}"
        )

    H      = config["hidden_size"]
    I      = config["intermediate_size"]
    L      = config["num_layers"]
    H_q    = config["num_attention_heads"]
    H_kv   = config["num_key_value_heads"]
    D      = config["head_dim"]
    V      = config["vocab_size"]
    max_pe = config.get("max_position_embeddings", max(seq_kv, 4096))
    q_dim  = H_q * D
    kv_dim = H_kv * D

    # Projection GEMMs flatten (batch, seq_q) into M.
    M_proj = batch * seq_q
    BS_H = batch * seq_q * H
    BS_I = batch * seq_q * I

    # Attention masking: causal during prefill; with S_q=1, generation does
    # not need a mask. Position offset places the new token correctly in
    # the rotary-embedding table during generation.
    use_mask   = 1 if stage == "prefill" else 0
    pos_offset = 0 if stage == "prefill" else (seq_kv - seq_q)
    max_seq    = max(seq_kv, max_pe)

    out: list[dict] = []

    # ---------------- Token embedding (model-level, NOT yet implemented) --
    out.append(_llm_kernel(
        name="embedding_lookup",
        kind="embedding",
        stage=stage,
        args="",
        calls_per_forward=1,
        shape={"batch": batch, "seq": seq_q, "hidden": H, "vocab": V},
        variant=variant,
    ))

    # ---------------- Per-decoder-layer kernels (× L) ---------------------

    # 1. input_layernorm (RMSNorm over [B, S_q, H])
    out.append(_llm_kernel(
        name="input_layernorm",
        kind="rmsnorm",
        stage=stage,
        args=f"-batch {batch} -seq {seq_q} -hidden {H}",
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "hidden": H},
        variant=variant,
    ))

    # 2-4. Q / K / V projections (GEMM: M=B*S_q, N=q_dim/kv_dim, K=H)
    out.append(_llm_gemm_kernel(
        name="q_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=q_dim, K=H, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))
    out.append(_llm_gemm_kernel(
        name="k_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=kv_dim, K=H, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))
    out.append(_llm_gemm_kernel(
        name="v_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=kv_dim, K=H, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))

    # 5-6. RoPE on Q and K
    out.append(_llm_kernel(
        name="rope_q", kind="rope", stage=stage,
        args=(f"-batch {batch} -seq {seq_q} -heads {H_q} -headdim {D} "
              f"-maxseq {max_seq} -offset {pos_offset}"),
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "heads": H_q, "headdim": D,
               "maxseq": max_seq, "offset": pos_offset},
        variant=variant,
    ))
    out.append(_llm_kernel(
        name="rope_k", kind="rope", stage=stage,
        args=(f"-batch {batch} -seq {seq_q} -heads {H_kv} -headdim {D} "
              f"-maxseq {max_seq} -offset {pos_offset}"),
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "heads": H_kv, "headdim": D,
               "maxseq": max_seq, "offset": pos_offset},
        variant=variant,
    ))

    # 7. Attention QK^T (per-head per-batch GEMM)
    out.append(_llm_gemm_kernel(
        name="attn_qkT", stage=stage, calls_per_forward=L * batch * H_q,
        M=seq_q, N=seq_kv, K=D, qblk=D, wtrans=1, qdir=0,
        variant=variant, per_head=True,
    ))

    # 8. Attention softmax over scores [B, H_q, S_q, S_kv]
    out.append(_llm_kernel(
        name="attn_softmax", kind="softmax", stage=stage,
        args=(f"-batch {batch} -heads {H_q} -seqq {seq_q} -seqk {seq_kv} "
              f"-mask {use_mask}"),
        calls_per_forward=L,
        shape={"batch": batch, "heads": H_q,
               "seqq": seq_q, "seqk": seq_kv, "mask": use_mask},
        variant=variant,
    ))

    # 9. Attention PV (per-head per-batch GEMM)
    out.append(_llm_gemm_kernel(
        name="attn_pv", stage=stage, calls_per_forward=L * batch * H_q,
        M=seq_q, N=D, K=seq_kv, qblk=D, wtrans=0, qdir=1,
        variant=variant, per_head=True,
    ))

    # 10. Concatenate per-head attention outputs into [B*S_q, H].
    out.append(_head_concat_kernel(
        stage,
        batch=batch, seq=seq_q, heads=H_q, head_dim=D,
        calls_per_forward=L, variant=variant,
    ))

    # 11. Output projection (GEMM: M=B*S_q, N=H, K=q_dim)
    out.append(_llm_gemm_kernel(
        name="o_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=H, K=q_dim, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))

    # 12. Residual add (attn): [B, S_q, H]
    out.append(_llm_kernel(
        name="residual_attn", kind="eladd", stage=stage,
        args=f"-n {BS_H}",
        calls_per_forward=L,
        shape={"size": BS_H},
        variant=variant,
    ))

    # 13. post_attention_layernorm
    out.append(_llm_kernel(
        name="post_attention_layernorm", kind="rmsnorm", stage=stage,
        args=f"-batch {batch} -seq {seq_q} -hidden {H}",
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "hidden": H},
        variant=variant,
    ))

    # 14-15. gate / up projections (GEMM: M=B*S_q, N=I, K=H)
    out.append(_llm_gemm_kernel(
        name="gate_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=I, K=H, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))
    out.append(_llm_gemm_kernel(
        name="up_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=I, K=H, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))

    # 16. SiLU on gate output [B, S_q, I]
    out.append(_llm_kernel(
        name="mlp_silu", kind="silu", stage=stage,
        args=f"-n {BS_I}",
        calls_per_forward=L,
        shape={"size": BS_I},
        variant=variant,
    ))

    # 17. Elementwise multiply (SwiGLU: SiLU(gate) * up) over [B, S_q, I]
    out.append(_llm_kernel(
        name="mlp_elmul", kind="elmul", stage=stage,
        args=f"-n {BS_I}",
        calls_per_forward=L,
        shape={"size": BS_I},
        variant=variant,
    ))

    # 18. down projection (GEMM: M=B*S_q, N=H, K=I)
    out.append(_llm_gemm_kernel(
        name="down_proj", stage=stage, calls_per_forward=L,
        M=M_proj, N=H, K=I, qblk=qblk, wtrans=0, qdir=0,
        variant=variant,
    ))

    # 19. Residual add (ffn): [B, S_q, H]
    out.append(_llm_kernel(
        name="residual_ffn", kind="eladd", stage=stage,
        args=f"-n {BS_H}",
        calls_per_forward=L,
        shape={"size": BS_H},
        variant=variant,
    ))

    # ---------------- Model-level kernels (× 1) ---------------------------

    # 20. final_layernorm (model-level RMSNorm)
    out.append(_llm_kernel(
        name="final_layernorm", kind="rmsnorm", stage=stage,
        args=f"-batch {batch} -seq {seq_q} -hidden {H}",
        calls_per_forward=1,
        shape={"batch": batch, "seq": seq_q, "hidden": H},
        variant=variant,
    ))

    # 21. lm_head intentionally excluded from the LLaMA latency workload.
    #     The logits projection is outside the current accelerator evaluation
    #     target, so do not emit an lm_head GEMM case here.

    if variant == LAYOUT_ALONE_VARIANT:
        return _apply_standalone_layout_variant(
            out,
            stage=stage,
            batch=batch,
            seq_q=seq_q,
            seq_kv=seq_kv,
            hidden=H,
            intermediate=I,
            layers=L,
            heads_q=H_q,
            heads_kv=H_kv,
            head_dim=D,
            q_dim=q_dim,
            M_proj=M_proj,
            variant=variant,
        )
    if variant == LAYOUT_FUSED_VARIANT:
        return _apply_fused_layout_variant(
            out,
            stage=stage,
            batch=batch,
            seq_q=seq_q,
            seq_kv=seq_kv,
            hidden=H,
            intermediate=I,
            layers=L,
            heads_q=H_q,
            heads_kv=H_kv,
            head_dim=D,
            q_dim=q_dim,
            M_proj=M_proj,
            variant=variant,
        )

    return out


def build_llm_kernels(model_name: str,
                      stages: list[str],
                      batch: int,
                      prefill_seq_len: int,
                      gen_kv_len: int,
                      qblk: int,
                      variant: str = DEFAULT_WORKLOAD_VARIANT) -> dict:
    """Build the JSON payload covering one or more stages."""
    if model_name not in MODELS:
        raise ValueError(
            f"unknown model: {model_name!r}. Available: "
            f"{sorted(MODELS.keys())}"
        )
    config = MODELS[model_name]
    if variant not in WORKLOAD_VARIANTS:
        raise ValueError(
            f"unknown variant: {variant!r}. Expected one of {WORKLOAD_VARIANTS}"
        )

    kernels: list[dict] = []
    for stage in stages:
        if stage == "prefill":
            kernels.extend(build_decoder_pass_kernels(
                config, "prefill",
                batch=batch,
                seq_q=prefill_seq_len,
                seq_kv=prefill_seq_len,
                qblk=qblk,
                variant=variant,
            ))
        elif stage == "generation":
            if gen_kv_len < 1:
                raise ValueError(
                    f"gen-kv-len must be >= 1, got {gen_kv_len}"
                )
            kernels.extend(build_decoder_pass_kernels(
                config, "generation",
                batch=batch,
                seq_q=1,
                seq_kv=gen_kv_len,
                qblk=qblk,
                variant=variant,
            ))
        else:
            raise ValueError(
                f"unknown stage: {stage!r}. Expected one of {LLM_STAGES}"
            )

    return {
        "model": model_name,
        "model_config": dict(config),
        "config": {
            "stages": list(stages),
            "batch": batch,
            "prefill_seq_len": prefill_seq_len,
            "gen_kv_len": gen_kv_len,
            "qblk": qblk,
            "variant": variant,
        },
        "kernels": kernels,
    }


# ===========================================================================
# Filtering helpers (used by ci/test_fpint_hw.py).
# ===========================================================================
def filter_backend_args(payload: dict, backend: str, *, dedupe: bool = True) -> list[str]:
    """Extract CLI arg strings for a single kernel backend from a payload.

    Skips entries with no app (``implemented == false``) since their
    ``args`` is intentionally empty.
    """
    seen: set[str] = set()
    out: list[str] = []
    for k in payload["kernels"]:
        if k.get("backend") != backend:
            continue
        if not k["implemented"]:
            continue
        a = k["args"]
        if dedupe and a in seen:
            continue
        seen.add(a)
        out.append(a)
    return out


def filter_kind_args(payload: dict, kind: str, *, dedupe: bool = True) -> list[str]:
    """Extract CLI arg strings for a logical kernel kind from a payload."""
    seen: set[str] = set()
    out: list[str] = []
    for k in payload["kernels"]:
        if k["kind"] != kind:
            continue
        if not k["implemented"]:
            continue
        a = k["args"]
        if dedupe and a in seen:
            continue
        seen.add(a)
        out.append(a)
    return out


def build_fpint_gemm_args_for_model(
    model_name: str,
    seq_lens: list[int],
    qblks: list[int] | None = None,
    *,
    batch: int = DEFAULT_LLM_BATCH,
    stages: tuple[str, ...] = ("prefill",),
) -> list[str]:
    """Cross-product (seq_lens × qblks × stages), filter to fpint GEMM,
    dedupe, and return the unique CLI arg strings.

    Used by ci/test_fpint_hw.py to drive HW regression on the GEMM
    shapes that LLaMA-style models actually exercise. Defaults to
    prefill-only because generation has S_q=1 which violates the M%32
    HW constraint and would just be skipped by check_constraints.
    """
    qblks = list(qblks) if qblks is not None else list(DEFAULT_QBLKS)
    seen: set[str] = set()
    out: list[str] = []
    for S in seq_lens:
        for q in qblks:
            payload = build_llm_kernels(
                model_name=model_name,
                stages=list(stages),
                batch=batch,
                prefill_seq_len=S,
                gen_kv_len=S,
                qblk=q,
            )
            for kernel in payload["kernels"]:
                if kernel.get("backend") not in FPINT_GEMM_BACKENDS:
                    continue
                if not kernel.get("implemented", False):
                    continue
                a = kernel["args"]
                if a in seen:
                    continue
                seen.add(a)
                out.append(a)
    return out


# ===========================================================================
# CSV / registry helpers.
# ===========================================================================
def parse_int_csv(raw: str | None,
                  default: list[int],
                  name: str) -> list[int]:
    if not raw:
        return list(default)
    out: list[int] = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        val = int(tok)
        if val <= 0:
            raise ValueError(f"{name} must be positive: {val}")
        out.append(val)
    if not out:
        raise ValueError(f"empty --{name} list")
    return out


def parse_seq_lens_csv(raw: str | None) -> list[int]:
    return parse_int_csv(raw, DEFAULT_SEQ_LENS, "seq-lens")


def parse_stages_csv(raw: str | None) -> list[str]:
    if not raw or raw == "all":
        return list(LLM_STAGES)
    out: list[str] = []
    for tok in raw.split(","):
        tok = tok.strip()
        if not tok:
            continue
        if tok not in LLM_STAGES:
            raise ValueError(
                f"unknown stage: {tok!r}. Expected one of "
                f"{LLM_STAGES} or 'all'"
            )
        if tok not in out:
            out.append(tok)
    if not out:
        raise ValueError("empty --stage list")
    return out


def print_model_registry() -> None:
    print("Available models:")
    for name in sorted(MODELS.keys()):
        c = MODELS[name]
        D = c["head_dim"]
        print(f"  {name}:")
        print(f"    hidden_size       = {c['hidden_size']}")
        print(f"    intermediate_size = {c['intermediate_size']}")
        print(f"    num_heads         = {c['num_attention_heads']}")
        print(f"    num_kv_heads      = {c['num_key_value_heads']}")
        print(f"    head_dim          = {D}")
        print(f"    num_layers        = {c.get('num_layers', '?')}")
        print(f"    vocab_size        = {c.get('vocab_size', '?')}")
    print()
    print("Kernel backend/app registry:")
    for backend in sorted(KERNEL_APP_REGISTRY):
        app = KERNEL_APP_REGISTRY[backend]
        flag = "implemented" if app else "NOT IMPLEMENTED"
        print(f"  {backend:12s} -> {app or '(none)':30s} [{flag}]")
    print()
    print("Workload variants:")
    for variant in WORKLOAD_VARIANTS:
        print(f"  {variant}")


# ===========================================================================
# CLI.
# ===========================================================================
def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate per-forward-pass kernel cfg JSON for an LLM.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  --model llama2-7b --stage prefill --prefill-seq-len 128\n"
            "  --model llama2-7b --stage all --batch 1 \\\n"
            "      --prefill-seq-len 128 --gen-kv-len 512 -o cfgs.json\n"
            "  --model llama2-7b --variant attn_sgemm_tcu_fpint_gemm_naive --filter-kind gemm\n"
        ),
    )
    parser.add_argument(
        "--model", default=None, metavar="NAME",
        help=f"Model name (available: "
             f"{', '.join(sorted(MODELS.keys())) or 'none'}). "
             "Required unless --list.",
    )
    parser.add_argument(
        "--stage", default="all", metavar="STAGE",
        help="Stage(s) to emit: 'prefill', 'generation', 'all', or a "
             "comma-separated list (default: all).",
    )
    parser.add_argument(
        "--batch", type=int, default=DEFAULT_LLM_BATCH,
        help=f"Batch size (default: {DEFAULT_LLM_BATCH}).",
    )
    parser.add_argument(
        "--prefill-seq-len", type=int, default=DEFAULT_LLM_PREFILL_SEQ,
        metavar="S",
        help="Prompt length for prefill stage (S_q = S_kv = S). "
             f"Default: {DEFAULT_LLM_PREFILL_SEQ}.",
    )
    parser.add_argument(
        "--gen-kv-len", type=int, default=DEFAULT_LLM_GEN_KV, metavar="K",
        help="KV cache length used during generation (S_q = 1, "
             f"S_kv = K). Default: {DEFAULT_LLM_GEN_KV}.",
    )
    parser.add_argument(
        "--qblk", type=int, default=DEFAULT_LLM_QBLK,
        help=f"QBLK for fpint GEMMs (default: {DEFAULT_LLM_QBLK}).",
    )
    parser.add_argument(
        "--variant", default=DEFAULT_WORKLOAD_VARIANT, metavar="VARIANT",
        help=f"Workload variant (available: {', '.join(WORKLOAD_VARIANTS)}). "
             f"Default: {DEFAULT_WORKLOAD_VARIANT}.",
    )
    parser.add_argument(
        "--filter-kind", default=None, metavar="KIND",
        help="If set, drop every kernel whose 'kind' != KIND from the "
             "output (e.g. gemm).",
    )
    parser.add_argument(
        "--filter-backend", default=None, metavar="BACKEND",
        help="If set, drop every kernel whose 'backend' != BACKEND from the "
             "output (e.g. fpint_gemm_naive, fpint_gemm_improve, or sgemm_tcu).",
    )
    parser.add_argument(
        "--outfile", "-o", default=None, metavar="PATH",
        help="Output JSON file path. If omitted, prints to stdout.",
    )
    parser.add_argument(
        "--list", action="store_true",
        help="Print the model registry and kernel-app registry, then exit.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    if args.list:
        print_model_registry()
        return 0

    if not args.model:
        print("ERROR: --model is required (or use --list)", file=sys.stderr)
        return 2

    try:
        stages = parse_stages_csv(args.stage)
        payload = build_llm_kernels(
            model_name=args.model,
            stages=stages,
            batch=args.batch,
            prefill_seq_len=args.prefill_seq_len,
            gen_kv_len=args.gen_kv_len,
            qblk=args.qblk,
            variant=args.variant,
        )
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if args.filter_kind:
        payload["kernels"] = [
            k for k in payload["kernels"] if k["kind"] == args.filter_kind
        ]
    if args.filter_backend:
        payload["kernels"] = [
            k for k in payload["kernels"] if k["backend"] == args.filter_backend
        ]

    text = json.dumps(payload, indent=2) + "\n"
    n = len(payload["kernels"])
    summary = (f"{n} cfgs (stages={','.join(stages)}"
               + (f", filter={args.filter_kind}" if args.filter_kind else "")
               + (f", backend={args.filter_backend}" if args.filter_backend else "")
               + ")")
    if args.outfile:
        path = Path(args.outfile)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {summary} -> {path}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
