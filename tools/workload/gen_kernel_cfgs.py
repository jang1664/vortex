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
import shlex
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
BASE_WORKLOAD_VARIANTS = (
    ALL_FPINT_GEMM_NAIVE_VARIANT,
    ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT,
    ALL_FPINT_GEMM_IMPROVE_VARIANT,
    ATTN_SGEMM_TCU_FPINT_GEMM_IMPROVE_VARIANT,
    ALL_SGEMM_TCU_VARIANT,
    LAYOUT_ALONE_VARIANT,
    LAYOUT_FUSED_VARIANT,
)
SPINQUANT_VARIANT_SUFFIX = "_spinquant"
SPINQUANT_WORKLOAD_VARIANTS = tuple(
    f"{variant}{SPINQUANT_VARIANT_SUFFIX}" for variant in BASE_WORKLOAD_VARIANTS
)
WORKLOAD_VARIANTS = BASE_WORKLOAD_VARIANTS + SPINQUANT_WORKLOAD_VARIANTS
DEFAULT_WORKLOAD_VARIANT = ALL_FPINT_GEMM_IMPROVE_VARIANT
ATTENTION_GEMM_OPS = frozenset(("attn_qkT", "attn_pv"))
STANDARD_KV_CACHE_QUANT_VARIANTS = frozenset((
    ALL_FPINT_GEMM_NAIVE_VARIANT,
    ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT,
    ALL_SGEMM_TCU_VARIANT,
))
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
    "tile_scale_zp_w4a16": "tile_scale_zp_w4a16",
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
    "hadamard":   "hadamard",
    "kv_cache_quant_w4a16": "kv_cache_quant_w4a16",
    "kv_cache_quant_layout_fused_w4a16": "kv_cache_quant_layout_fused_w4a16",
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


def _base_workload_variant(variant: str) -> str:
    if variant in BASE_WORKLOAD_VARIANTS:
        return variant
    if variant.endswith(SPINQUANT_VARIANT_SUFFIX):
        base = variant[:-len(SPINQUANT_VARIANT_SUFFIX)]
        if base in BASE_WORKLOAD_VARIANTS:
            return base
    return variant


def _is_spinquant_variant(variant: str) -> bool:
    return (
        variant.endswith(SPINQUANT_VARIANT_SUFFIX)
        and _base_workload_variant(variant) in BASE_WORKLOAD_VARIANTS
    )


def _gemm_backend(op: str, variant: str) -> str:
    base_variant = _base_workload_variant(variant)
    if base_variant == ALL_FPINT_GEMM_NAIVE_VARIANT:
        return FPINT_GEMM_NAIVE_BACKEND
    if base_variant in (
        ALL_FPINT_GEMM_IMPROVE_VARIANT,
        LAYOUT_ALONE_VARIANT,
        LAYOUT_FUSED_VARIANT,
    ):
        return FPINT_GEMM_IMPROVE_BACKEND
    if base_variant == ALL_SGEMM_TCU_VARIANT:
        return "sgemm_tcu"
    if base_variant == ATTN_SGEMM_TCU_FPINT_GEMM_NAIVE_VARIANT:
        return "sgemm_tcu" if op in ATTENTION_GEMM_OPS else FPINT_GEMM_NAIVE_BACKEND
    if base_variant == ATTN_SGEMM_TCU_FPINT_GEMM_IMPROVE_VARIANT:
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
                        cache_update: str = "full",
                        source_transposed: bool = False) -> dict:
    layout_to = "gemm_w_tiled_transposed" if WTRANS else "gemm_w_tiled"
    shape = {
        "K": K,
        "N": N,
        "WTRANS": WTRANS,
        "layout_from": "packed_w4a16_row_major",
        "layout_to": layout_to,
        "producer": producer,
        "consumer": consumer,
        "layout_group": layout_group,
        "cache_update": cache_update,
    }
    if source_transposed:
        shape["source_transposed"] = True
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
        args=(
            f"-k {K} -n {N} -t {WTRANS}"
            + (" --source-transposed" if source_transposed else "")
        ),
        calls_per_forward=calls_per_forward,
        shape=shape,
        variant=variant,
    )


def _tile_scale_zp_kernel(name: str,
                          stage: str,
                          *,
                          K: int,
                          N: int,
                          QBLK: int,
                          QDIR: int,
                          calls_per_forward: int,
                          producer: str,
                          consumer: str,
                          layout_group: str,
                          variant: str,
                          effective_K: int | None = None,
                          effective_N: int | None = None,
                          cache_len: int | None = None,
                          cache_update: str = "full",
                          gemm_QDIR: int | None = None,
                          source_transposed: bool = False) -> dict:
    gemm_qdir = QDIR if gemm_QDIR is None else gemm_QDIR
    layout_to = "sz_gemm_tiled_transposed" if source_transposed else "sz_gemm_tiled"
    shape = {
        "K": K,
        "N": N,
        "QBLK": QBLK,
        "QDIR": QDIR,
        "source_QDIR": QDIR,
        "gemm_QDIR": gemm_qdir,
        "layout_from": "qparams_row_major",
        "layout_to": layout_to,
        "producer": producer,
        "consumer": consumer,
        "layout_group": layout_group,
        "cache_update": cache_update,
    }
    if source_transposed:
        shape["source_transposed"] = True
    if effective_K is not None:
        shape["effective_K"] = effective_K
    if effective_N is not None:
        shape["effective_N"] = effective_N
    if cache_len is not None:
        shape["cache_len"] = cache_len
    return _layout_kernel(
        name=name,
        stage=stage,
        backend="tile_scale_zp_w4a16",
        args=(
            f"-k {K} -n {N} -q {QBLK} -d {QDIR} --gemm-qdir {gemm_qdir}"
            + (" --source-transposed" if source_transposed else "")
        ),
        calls_per_forward=calls_per_forward,
        shape=shape,
        variant=variant,
    )


def _kv_cache_quant_kernel(name: str,
                           stage: str,
                           *,
                           K: int,
                           N: int,
                           QBLK: int,
                           QDIR: int,
                           WTRANS: int,
                           calls_per_forward: int,
                           producer: str,
                           consumer: str,
                           layout_group: str,
                           variant: str,
                           effective_K: int | None = None,
                           effective_N: int | None = None,
                           cache_len: int | None = None,
                           cache_update: str = "full",
                           gemm_QDIR: int | None = None,
                           source_transposed: bool = False) -> dict:
    gemm_qdir = QDIR if gemm_QDIR is None else gemm_QDIR
    shape = {
        "K": K,
        "N": N,
        "QBLK": QBLK,
        "QDIR": QDIR,
        "source_QDIR": QDIR,
        "gemm_QDIR": gemm_qdir,
        "WTRANS": WTRANS,
        "layout_from": "row_major_fp16",
        "layout_to": "packed_w4a16_row_major",
        "qparam_layout_to": "qparams_row_major",
        "producer": producer,
        "consumer": consumer,
        "layout_group": layout_group,
        "cache_update": cache_update,
    }
    if source_transposed:
        shape["source_transposed"] = True
    if effective_K is not None:
        shape["effective_K"] = effective_K
    if effective_N is not None:
        shape["effective_N"] = effective_N
    if cache_len is not None:
        shape["cache_len"] = cache_len
    return _llm_kernel(
        name=name,
        kind="quantization",
        backend="kv_cache_quant_w4a16",
        stage=stage,
        args=f"-k {K} -n {N} -q {QBLK} -d {QDIR} -t {WTRANS}",
        calls_per_forward=calls_per_forward,
        shape=shape,
        variant=variant,
    )


def _kv_cache_quant_layout_fused_kernel(name: str,
                                        stage: str,
                                        *,
                                        K: int,
                                        N: int,
                                        QBLK: int,
                                        QDIR: int,
                                        WTRANS: int,
                                        calls_per_forward: int,
                                        producer: str,
                                        consumer: str,
                                        layout_group: str,
                                        variant: str,
                                        layout_from: str = "row_major_fp16",
                                        effective_K: int | None = None,
                                        effective_N: int | None = None,
                                        cache_len: int | None = None,
                                        cache_update: str = "full",
                                        gemm_QDIR: int | None = None,
                                        source_transposed: bool = False) -> dict:
    gemm_qdir = QDIR if gemm_QDIR is None else gemm_QDIR
    weight_layout_to = "gemm_w_tiled_transposed" if WTRANS else "gemm_w_tiled"
    scale_zp_layout_to = "sz_gemm_tiled_transposed" if source_transposed else "sz_gemm_tiled"
    shape = {
        "K": K,
        "N": N,
        "QBLK": QBLK,
        "QDIR": QDIR,
        "source_QDIR": QDIR,
        "gemm_QDIR": gemm_qdir,
        "WTRANS": WTRANS,
        "layout_from": layout_from,
        "weight_layout_to": weight_layout_to,
        "scale_zp_layout_to": scale_zp_layout_to,
        "producer": producer,
        "consumer": consumer,
        "layout_group": layout_group,
        "cache_update": cache_update,
    }
    if source_transposed:
        shape["source_transposed"] = True
    if effective_K is not None:
        shape["effective_K"] = effective_K
    if effective_N is not None:
        shape["effective_N"] = effective_N
    if cache_len is not None:
        shape["cache_len"] = cache_len
    return _llm_kernel(
        name=name,
        kind="quantization",
        backend="kv_cache_quant_layout_fused_w4a16",
        stage=stage,
        args=(
            f"-k {K} -n {N} -q {QBLK} -d {QDIR} -t {WTRANS}"
            f" --gemm-qdir {gemm_qdir}"
            + (f" --layout-from {layout_from}" if layout_from != "row_major_fp16" else "")
            + (" --source-transposed" if source_transposed else "")
        ),
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


def _hadamard_kernel(name: str,
                     stage: str,
                     *,
                     rows: int,
                     dim: int,
                     calls_per_forward: int,
                     producer: str,
                     consumer: str,
                     layout_group: str,
                     rotation: str,
                     variant: str) -> dict:
    return _llm_kernel(
        name=name,
        kind="hadamard",
        backend="hadamard",
        stage=stage,
        args=f"-rows {rows} -dim {dim}",
        calls_per_forward=calls_per_forward,
        shape={
            "rows": rows,
            "dim": dim,
            "layout_from": "row_major_fp16",
            "layout_to": "row_major_fp16",
            "producer": producer,
            "consumer": consumer,
            "layout_group": layout_group,
            "spinquant_rotation": rotation,
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


def _with_kernel_updates(kernel: dict,
                         *,
                         backend: str | None = None,
                         args: str | None = None,
                         shape_update: dict | None = None) -> dict:
    shape = dict(kernel.get("shape") or {})
    if shape_update:
        shape.update(shape_update)
    return _llm_kernel(
        name=str(kernel["name"]),
        kind=str(kernel["kind"]),
        backend=backend or str(kernel["backend"]),
        stage=str(kernel["stage"]),
        args=str(kernel["args"] if args is None else args),
        calls_per_forward=int(kernel["calls_per_forward"]),
        shape=shape,
        variant=str(kernel["variant"]),
    )


def _replace_layout_to_arg(args: str, layout_to: str) -> str:
    parts = args.split()
    for i, part in enumerate(parts):
        if part == "--layout-to" and i + 1 < len(parts):
            parts[i + 1] = layout_to
            return " ".join(parts)
        if part.startswith("--layout-to="):
            parts[i] = f"--layout-to={layout_to}"
            return " ".join(parts)
    return " ".join(parts + ["--layout-to", layout_to])


def _kv_cache_row_major_source_shape(stage: str, seq_kv: int, head_dim: int) -> tuple[int, int, str]:
    rows = 1 if stage == "generation" else seq_kv
    update = "append" if stage == "generation" else "full"
    return rows, head_dim, update


def _kv_cache_tiled_source_shape(stage: str, seq_kv: int, head_dim: int) -> tuple[int, int, int | None, int | None, str]:
    rows = 1 if stage == "generation" else seq_kv
    update = "append" if stage == "generation" else "full"
    return rows, head_dim, None, None, update


def _apply_standard_kv_cache_quant_variant(kernels: list[dict],
                                           *,
                                           stage: str,
                                           seq_kv: int,
                                           layers: int,
                                           batch: int,
                                           heads_kv: int,
                                           head_dim: int,
                                           variant: str) -> list[dict]:
    by_name = {kernel["name"]: kernel for kernel in kernels}
    per_head_kv = layers * batch * heads_kv
    k_K, k_N, k_update = _kv_cache_row_major_source_shape(stage, seq_kv, head_dim)
    v_K, v_N, v_update = _kv_cache_row_major_source_shape(stage, seq_kv, head_dim)
    attn_qk_backend = str(by_name["attn_qkT"]["backend"])
    attn_pv_backend = str(by_name["attn_pv"]["backend"])
    k_consumer = "attn_qkT" if attn_qk_backend in FPINT_GEMM_BACKENDS else "kv_cache:k"
    v_consumer = "attn_pv" if attn_pv_backend in FPINT_GEMM_BACKENDS else "kv_cache:v"

    return [
        by_name["input_layernorm"],
        by_name["q_proj"],
        by_name["k_proj"],
        by_name["v_proj"],
        by_name["rope_q"],
        by_name["rope_k"],
        _kv_cache_quant_kernel(
            "kv_cache_quant_rope_k_to_attn_qkT", stage,
            K=k_K, N=k_N, QBLK=head_dim, QDIR=1, WTRANS=1,
            calls_per_forward=per_head_kv,
            producer="rope_k", consumer=k_consumer,
            layout_group="rope_k_to_kv_cache", variant=variant,
            cache_len=seq_kv, cache_update=k_update,
            gemm_QDIR=0, source_transposed=True,
        ),
        by_name["attn_qkT"],
        by_name["attn_softmax"],
        _kv_cache_quant_kernel(
            "kv_cache_quant_v_cache_to_attn_pv", stage,
            K=v_K, N=v_N, QBLK=head_dim, QDIR=1, WTRANS=0,
            calls_per_forward=per_head_kv,
            producer="v_proj", consumer=v_consumer,
            layout_group="v_cache_to_kv_cache", variant=variant,
            cache_len=seq_kv, cache_update=v_update,
            gemm_QDIR=1,
        ),
        by_name["attn_pv"],
        by_name["attn_head_concat"],
        by_name["o_proj"],
        by_name["residual_attn"],
        by_name["post_attention_layernorm"],
        by_name["gate_proj"],
        by_name["up_proj"],
        by_name["mlp_silu"],
        by_name["mlp_elmul"],
        by_name["down_proj"],
        by_name["residual_ffn"],
    ]


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
    k_K, k_N, k_eff_K, k_eff_N, k_update = _kv_cache_tiled_source_shape(stage, seq_kv, head_dim)
    v_K, v_N, v_eff_K, v_eff_N, v_update = _kv_cache_tiled_source_shape(stage, seq_kv, head_dim)

    return [
        # embedding_lookup is intentionally disabled in build_decoder_pass_kernels.
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
        _kv_cache_quant_kernel(
            "kv_cache_quant_rope_k_to_attn_qkT", stage,
            K=k_K, N=k_N, QBLK=head_dim, QDIR=1, WTRANS=1,
            calls_per_forward=per_head_kv,
            producer="rope_k", consumer="layout_rope_k_to_attn_qkT",
            layout_group="rope_k_to_attn_qkT", variant=variant,
            effective_K=k_eff_K, effective_N=k_eff_N,
            cache_len=seq_kv, cache_update=k_update,
            gemm_QDIR=0, source_transposed=True,
        ),
        _tile_scale_zp_kernel(
            "layout_rope_k_qparams_to_attn_qkT", stage,
            K=k_K, N=k_N, QBLK=head_dim, QDIR=1,
            calls_per_forward=per_head_kv,
            producer="kv_cache_quant_rope_k_to_attn_qkT", consumer="attn_qkT",
            layout_group="rope_k_to_attn_qkT", variant=variant,
            effective_K=k_eff_K, effective_N=k_eff_N,
            cache_len=seq_kv, cache_update=k_update,
            gemm_QDIR=0, source_transposed=True,
        ),
        _tile_weight_kernel(
            "layout_rope_k_to_attn_qkT", stage,
            K=k_K, N=k_N, WTRANS=1, calls_per_forward=per_head_kv,
            producer="kv_cache_quant_rope_k_to_attn_qkT", consumer="attn_qkT",
            layout_group="rope_k_to_attn_qkT", variant=variant,
            effective_K=k_eff_K, effective_N=k_eff_N,
            cache_len=seq_kv, cache_update=k_update,
            source_transposed=True,
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
        _kv_cache_quant_kernel(
            "kv_cache_quant_v_cache_to_attn_pv", stage,
            K=v_K, N=v_N, QBLK=head_dim, QDIR=1, WTRANS=0,
            calls_per_forward=per_head_kv,
            producer="v_cache", consumer="layout_v_cache_to_attn_pv",
            layout_group="v_cache_to_attn_pv", variant=variant,
            effective_K=v_eff_K, effective_N=v_eff_N,
            cache_len=seq_kv, cache_update=v_update,
            gemm_QDIR=1,
        ),
        _tile_scale_zp_kernel(
            "layout_v_cache_qparams_to_attn_pv", stage,
            K=v_K, N=v_N, QBLK=head_dim, QDIR=1,
            calls_per_forward=per_head_kv,
            producer="kv_cache_quant_v_cache_to_attn_pv", consumer="attn_pv",
            layout_group="v_cache_to_attn_pv", variant=variant,
            effective_K=v_eff_K, effective_N=v_eff_N,
            cache_len=seq_kv, cache_update=v_update,
            gemm_QDIR=1,
        ),
        _tile_weight_kernel(
            "layout_v_cache_to_attn_pv", stage,
            K=v_K, N=v_N, WTRANS=0, calls_per_forward=per_head_kv,
            producer="kv_cache_quant_v_cache_to_attn_pv", consumer="attn_pv",
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
        # final_layernorm is intentionally disabled in build_decoder_pass_kernels.
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
    k_K, k_N, k_eff_K, k_eff_N, k_update = _kv_cache_tiled_source_shape(stage, seq_kv, head_dim)
    v_K, v_N, v_eff_K, v_eff_N, v_update = _kv_cache_tiled_source_shape(stage, seq_kv, head_dim)

    return [
        # embedding_lookup is intentionally disabled in build_decoder_pass_kernels.
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
            args=f"{by_name['rope_k']['args']} --layout-to row_major",
            shape_update={
                "layout_from": "gemm_c_tiled", "layout_to": "row_major_fp16",
                "producer": "k_proj", "consumer": "kv_cache_quant_rope_k_to_attn_qkT",
                "layout_group": "k_proj_to_rope_k_to_kv_cache_quant",
                "cache_update": "append" if stage == "generation" else "full",
                "cache_len": seq_kv,
            },
        ),
        _kv_cache_quant_layout_fused_kernel(
            "kv_cache_quant_rope_k_to_attn_qkT", stage,
            K=k_K, N=k_N, QBLK=head_dim, QDIR=1, WTRANS=1,
            calls_per_forward=per_head_kv,
            producer="rope_k", consumer="attn_qkT",
            layout_group="rope_k_to_attn_qkT", variant=variant,
            effective_K=k_eff_K, effective_N=k_eff_N,
            cache_len=seq_kv, cache_update=k_update,
            gemm_QDIR=0, source_transposed=True,
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
        _kv_cache_quant_layout_fused_kernel(
            "kv_cache_quant_v_cache_to_attn_pv", stage,
            K=v_K, N=v_N, QBLK=head_dim, QDIR=1, WTRANS=0,
            calls_per_forward=per_head_kv,
            producer="v_proj", consumer="attn_pv",
            layout_group="v_cache_to_attn_pv", variant=variant,
            layout_from="gemm_c_tiled",
            effective_K=v_eff_K, effective_N=v_eff_N,
            cache_len=seq_kv, cache_update=v_update,
            gemm_QDIR=1,
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
                "layout_from": "gemm_c_tiled", "layout_to": "gemm_c_tiled",
                "producer": "gate_proj", "consumer": "mlp_elmul",
                "layout_group": "gate_proj_to_mlp_silu_to_mlp_elmul",
            },
        ),
        _with_fused_backend(
            by_name["mlp_elmul"], "elmul_layout_fused",
            args=f"-m {M_proj} -k {intermediate}",
            shape_update={
                "M": M_proj, "K": intermediate,
                "layout_from": "gemm_c_tiled", "layout_to": "gemm_a_tiled",
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
        # final_layernorm is intentionally disabled in build_decoder_pass_kernels.
    ]


def _apply_spinquant_hadamard_variant(kernels: list[dict],
                                      *,
                                      stage: str,
                                      batch: int,
                                      seq_q: int,
                                      intermediate: int,
                                      layers: int,
                                      heads_q: int,
                                      heads_kv: int,
                                      head_dim: int,
                                      M_proj: int,
                                      base_variant: str,
                                      variant: str) -> list[dict]:
    by_name = {kernel["name"]: kernel for kernel in kernels}
    names = set(by_name)
    per_head_q = layers * batch * heads_q
    q_rows = batch * seq_q * heads_q
    k_rows = batch * seq_q * heads_kv
    r4_rows = M_proj
    mlp_elems = M_proj * intermediate

    q_consumer = "attn_qkT"
    if base_variant in (LAYOUT_ALONE_VARIANT, LAYOUT_FUSED_VARIANT):
        q_consumer = "layout_rope_q_to_attn_qkT"

    k_consumers = []
    if "kv_cache_quant_rope_k_to_attn_qkT" in names:
        k_consumers.append("kv_cache_quant_rope_k_to_attn_qkT")
        if _standard_quant_is_cache_store_only(
            by_name,
            names,
            attn_name="attn_qkT",
            quant_name="kv_cache_quant_rope_k_to_attn_qkT",
            tiled_layout_name="layout_rope_k_to_attn_qkT",
        ):
            k_consumers.append("attn_qkT")
    else:
        k_consumers.append("attn_qkT")

    r4_consumer = (
        "layout_mlp_elmul_to_down_proj"
        if base_variant in (LAYOUT_ALONE_VARIANT, LAYOUT_FUSED_VARIANT)
        else "down_proj"
    )

    q_hadamard = _hadamard_kernel(
        "spinquant_r3_q_hadamard", stage,
        rows=q_rows, dim=head_dim, calls_per_forward=layers,
        producer="rope_q", consumer=q_consumer,
        layout_group="rope_q_to_spinquant_r3_q_to_attn_qkT",
        rotation="R3", variant=variant,
    )
    k_hadamard = _hadamard_kernel(
        "spinquant_r3_k_hadamard", stage,
        rows=k_rows, dim=head_dim, calls_per_forward=layers,
        producer="rope_k", consumer=",".join(k_consumers),
        layout_group="rope_k_to_spinquant_r3_k_to_kv_cache",
        rotation="R3", variant=variant,
    )
    r4_hadamard = _hadamard_kernel(
        "spinquant_r4_mlp_hadamard", stage,
        rows=r4_rows, dim=intermediate, calls_per_forward=layers,
        producer="mlp_elmul", consumer=r4_consumer,
        layout_group="mlp_elmul_to_spinquant_r4_to_down_proj",
        rotation="R4", variant=variant,
    )

    q_tile = _tile_input_kernel(
        "layout_rope_q_to_attn_qkT", stage,
        M=seq_q, K=head_dim, calls_per_forward=per_head_q,
        producer="spinquant_r3_q_hadamard", consumer="attn_qkT",
        layout_group="spinquant_r3_q_hadamard_to_attn_qkT",
        layout_from="row_major_fp16", variant=variant,
    )
    gate_detile = _detile_output_kernel(
        "layout_gate_proj_to_mlp_silu_detile", stage,
        M=M_proj, N=intermediate, calls_per_forward=layers,
        producer="gate_proj", consumer="mlp_silu",
        layout_group="gate_proj_to_mlp_silu", variant=variant,
    )
    up_detile = _detile_output_kernel(
        "layout_up_proj_to_mlp_elmul_detile", stage,
        M=M_proj, N=intermediate, calls_per_forward=layers,
        producer="up_proj", consumer="mlp_elmul",
        layout_group="up_proj_to_mlp_elmul", variant=variant,
    )
    row_major_silu = _llm_kernel(
        name="mlp_silu", kind="silu", backend="silu", stage=stage,
        args=f"-n {mlp_elems}",
        calls_per_forward=layers,
        shape={
            "size": mlp_elems,
            "layout_from": "row_major",
            "layout_to": "row_major",
            "producer": "layout_gate_proj_to_mlp_silu_detile",
            "consumer": "mlp_elmul",
            "layout_group": "gate_proj_to_mlp_silu",
        },
        variant=variant,
    )
    row_major_elmul = _llm_kernel(
        name="mlp_elmul", kind="elmul", backend="elmul", stage=stage,
        args=f"-n {mlp_elems}",
        calls_per_forward=layers,
        shape={
            "size": mlp_elems,
            "layout_from": "row_major",
            "layout_to": "row_major",
            "producer": "mlp_silu,layout_up_proj_to_mlp_elmul_detile",
            "consumer": "spinquant_r4_mlp_hadamard",
            "layout_group": "mlp_elmul_to_spinquant_r4",
        },
        variant=variant,
    )
    r4_tile = _tile_input_kernel(
        "layout_mlp_elmul_to_down_proj", stage,
        M=M_proj, K=intermediate, calls_per_forward=layers,
        producer="spinquant_r4_mlp_hadamard", consumer="down_proj",
        layout_group="spinquant_r4_hadamard_to_down_proj",
        layout_from="row_major_fp16", variant=variant,
    )

    out: list[dict] = []
    for kernel in kernels:
        name = str(kernel["name"])

        if name == "rope_q":
            if base_variant == LAYOUT_FUSED_VARIANT:
                kernel = _with_kernel_updates(
                    kernel,
                    args=_replace_layout_to_arg(str(kernel["args"]), "row_major"),
                    shape_update={
                        "layout_to": "row_major_fp16",
                        "consumer": "spinquant_r3_q_hadamard",
                        "layout_group": "q_proj_to_rope_q_to_spinquant_r3_q",
                    },
                )
            out.append(kernel)
            out.append(q_hadamard)
            if base_variant == LAYOUT_FUSED_VARIANT:
                out.append(q_tile)
            continue

        if name == "rope_k":
            if base_variant == LAYOUT_FUSED_VARIANT:
                kernel = _with_kernel_updates(
                    kernel,
                    shape_update={
                        "consumer": "spinquant_r3_k_hadamard",
                        "layout_group": "k_proj_to_rope_k_to_spinquant_r3_k",
                    },
                )
            out.append(kernel)
            out.append(k_hadamard)
            continue

        if name == "layout_rope_q_to_attn_qkT":
            out.append(_with_kernel_updates(
                kernel,
                shape_update={
                    "layout_from": "row_major_fp16",
                    "producer": "spinquant_r3_q_hadamard",
                    "layout_group": "spinquant_r3_q_hadamard_to_attn_qkT",
                },
            ))
            continue

        if name == "kv_cache_quant_rope_k_to_attn_qkT":
            out.append(_with_kernel_updates(
                kernel,
                shape_update={
                    "producer": "spinquant_r3_k_hadamard",
                    "layout_group": "spinquant_r3_k_hadamard_to_kv_cache",
                },
            ))
            continue

        if base_variant == LAYOUT_FUSED_VARIANT and name == "mlp_silu":
            out.append(gate_detile)
            out.append(row_major_silu)
            continue

        if base_variant == LAYOUT_FUSED_VARIANT and name == "mlp_elmul":
            out.append(up_detile)
            out.append(row_major_elmul)
            out.append(r4_hadamard)
            out.append(r4_tile)
            continue

        if name == "mlp_elmul":
            out.append(kernel)
            out.append(r4_hadamard)
            continue

        if name == "layout_mlp_elmul_to_down_proj":
            out.append(_with_kernel_updates(
                kernel,
                shape_update={
                    "layout_from": "row_major_fp16",
                    "producer": "spinquant_r4_mlp_hadamard",
                    "layout_group": "spinquant_r4_hadamard_to_down_proj",
                },
            ))
            continue

        out.append(kernel)

    return out


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
    base_variant = _base_workload_variant(variant)
    spinquant = _is_spinquant_variant(variant)

    H      = config["hidden_size"]
    I      = config["intermediate_size"]
    L      = config["num_layers"]
    H_q    = config["num_attention_heads"]
    H_kv   = config["num_key_value_heads"]
    D      = config["head_dim"]
    # V is only needed when embedding_lookup is part of the latency workload.
    # embedding_lookup is intentionally disabled below.
    # V      = config["vocab_size"]
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

    # ---------------- Token embedding (model-level) -----------------------
    # Disabled for latency workloads: token embedding is outside the current
    # accelerator evaluation target and has no implemented regression app.
    # out.append(_llm_kernel(
    #     name="embedding_lookup",
    #     kind="embedding",
    #     stage=stage,
    #     args="",
    #     calls_per_forward=1,
    #     shape={"batch": batch, "seq": seq_q, "hidden": H, "vocab": V},
    #     variant=variant,
    # ))

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
    # Prefill uses one-head softmax cases to isolate per-head latency. In
    # generation, S_q=1, so keep all heads in a single call to avoid measuring
    # tiny per-head cases dominated by launch/dispatch overhead.
    softmax_heads = 1 if stage == "prefill" else H_q
    softmax_calls = L * H_q if stage == "prefill" else L
    out.append(_llm_kernel(
        name="attn_softmax", kind="softmax", stage=stage,
        args=(f"-batch {batch} -heads {softmax_heads} -seqq {seq_q} -seqk {seq_kv} "
              f"-mask {use_mask}"),
        calls_per_forward=softmax_calls,
        shape={"batch": batch, "heads": softmax_heads,
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
    # Disabled for latency workloads: this model-level norm is outside the
    # current per-layer accelerator evaluation target.
    # out.append(_llm_kernel(
    #     name="final_layernorm", kind="rmsnorm", stage=stage,
    #     args=f"-batch {batch} -seq {seq_q} -hidden {H}",
    #     calls_per_forward=1,
    #     shape={"batch": batch, "seq": seq_q, "hidden": H},
    #     variant=variant,
    # ))

    # 21. lm_head intentionally excluded from the LLaMA latency workload.
    #     The logits projection is outside the current accelerator evaluation
    #     target, so do not emit an lm_head GEMM case here.

    if base_variant == LAYOUT_ALONE_VARIANT:
        kernels = _apply_standalone_layout_variant(
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
    elif base_variant == LAYOUT_FUSED_VARIANT:
        kernels = _apply_fused_layout_variant(
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
    elif base_variant in STANDARD_KV_CACHE_QUANT_VARIANTS:
        kernels = _apply_standard_kv_cache_quant_variant(
            out,
            stage=stage,
            seq_kv=seq_kv,
            layers=L,
            batch=batch,
            heads_kv=H_kv,
            head_dim=D,
            variant=variant,
        )
    else:
        kernels = out

    if spinquant:
        return _apply_spinquant_hadamard_variant(
            kernels,
            stage=stage,
            batch=batch,
            seq_q=seq_q,
            intermediate=I,
            layers=L,
            heads_q=H_q,
            heads_kv=H_kv,
            head_dim=D,
            M_proj=M_proj,
            base_variant=base_variant,
            variant=variant,
        )

    return kernels


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

    payload = {
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
    annotate_kernel_flow(payload["kernels"])
    return payload


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
# Kernel dataflow metadata.
# ===========================================================================
def _split_flow_nodes(raw: object) -> list[str]:
    if raw is None:
        return []
    return [node.strip() for node in str(raw).split(",") if node.strip()]


def _input_flow(role: str, source: str, layout: str) -> dict:
    return {"role": role, "source": source, "layout": layout}


def _output_flow(role: str, target: str, layout: str) -> dict:
    return {"role": role, "target": target, "layout": layout}


def _input_flows(role: str, sources: list[str], layout: str) -> list[dict]:
    return [_input_flow(role, source, layout) for source in sources]


def _output_flows(role: str, targets: list[str], layout: str) -> list[dict]:
    return [_output_flow(role, target, layout) for target in targets]


def _gemm_a_layout(backend: str) -> str:
    if backend == FPINT_GEMM_IMPROVE_BACKEND:
        return "gemm_a_tiled"
    if backend == "sgemm_tcu":
        return "row_major_fp16"
    return "row_major"


def _gemm_w_layout(backend: str, wtrans: int = 0) -> str:
    if backend == FPINT_GEMM_IMPROVE_BACKEND:
        return "gemm_w_tiled_transposed" if wtrans else "gemm_w_tiled"
    if backend == "sgemm_tcu":
        return "row_major_fp16"
    return "row_major"


def _gemm_qparam_layout(backend: str) -> str | None:
    if backend == FPINT_GEMM_IMPROVE_BACKEND:
        return "gemm_scale_zp_tiled"
    if backend == FPINT_GEMM_NAIVE_BACKEND:
        return "row_major"
    return None


def _gemm_c_layout(backend: str) -> str:
    if backend == FPINT_GEMM_IMPROVE_BACKEND:
        return "gemm_c_tiled"
    if backend == "sgemm_tcu":
        return "row_major_fp16"
    return "row_major"


def _kernel_backend(kernels_by_name: dict[str, dict], name: str) -> str:
    kernel = kernels_by_name.get(name)
    return str(kernel.get("backend", "")) if kernel else ""


def _kernel_layout_to(kernels_by_name: dict[str, dict], name: str, default: str) -> str:
    shape = dict(kernels_by_name.get(name, {}).get("shape") or {})
    return str(shape.get("layout_to", default))


def _kernel_layout_from(kernels_by_name: dict[str, dict], name: str, default: str) -> str:
    shape = dict(kernels_by_name.get(name, {}).get("shape") or {})
    return str(shape.get("layout_from", default))


def _kernel_weight_layout_to(kernels_by_name: dict[str, dict], name: str, default: str) -> str:
    shape = dict(kernels_by_name.get(name, {}).get("shape") or {})
    return str(shape.get("weight_layout_to", shape.get("layout_to", default)))


def _kernel_qparam_layout_to(kernels_by_name: dict[str, dict], name: str, default: str) -> str:
    shape = dict(kernels_by_name.get(name, {}).get("shape") or {})
    return str(shape.get("scale_zp_layout_to", shape.get("layout_to", default)))


def _producer_output_layout(kernels_by_name: dict[str, dict], name: str | None, default: str) -> str:
    if not name:
        return default
    kernel = kernels_by_name.get(name)
    if not kernel:
        return default
    shape = dict(kernel.get("shape") or {})
    if "layout_to" in shape:
        return str(shape["layout_to"])
    if "weight_layout_to" in shape:
        return str(shape["weight_layout_to"])
    if str(kernel.get("kind", "")) == "gemm":
        return _gemm_c_layout(str(kernel.get("backend", "")))
    return default


def _standard_quant_feeds_attention(kernels_by_name: dict[str, dict],
                                    names: set[str],
                                    *,
                                    attn_name: str,
                                    quant_name: str,
                                    tiled_layout_name: str) -> bool:
    quant = kernels_by_name.get(quant_name)
    return (
        quant is not None
        and quant.get("backend") == "kv_cache_quant_w4a16"
        and tiled_layout_name not in names
        and _kernel_backend(kernels_by_name, attn_name) in FPINT_GEMM_BACKENDS
    )


def _standard_quant_is_cache_store_only(kernels_by_name: dict[str, dict],
                                        names: set[str],
                                        *,
                                        attn_name: str,
                                        quant_name: str,
                                        tiled_layout_name: str) -> bool:
    quant = kernels_by_name.get(quant_name)
    return (
        quant is not None
        and quant.get("backend") == "kv_cache_quant_w4a16"
        and tiled_layout_name not in names
        and not _standard_quant_feeds_attention(
            kernels_by_name,
            names,
            attn_name=attn_name,
            quant_name=quant_name,
            tiled_layout_name=tiled_layout_name,
        )
    )


def _first_existing(candidates: list[str], names: set[str]) -> str | None:
    for candidate in candidates:
        if candidate in names:
            return candidate
    return None


def _targets_existing(candidates: list[str], names: set[str]) -> list[str]:
    return [candidate for candidate in candidates if candidate in names]


def _set_flow(kernel: dict,
              inputs: list[dict] | None = None,
              outputs: list[dict] | None = None) -> None:
    kernel["inputs"] = inputs or []
    kernel["outputs"] = outputs or []


def _set_flow_by_name(kernels_by_name: dict[str, dict],
                      name: str,
                      *,
                      inputs: list[dict] | None = None,
                      outputs: list[dict] | None = None) -> None:
    kernel = kernels_by_name.get(name)
    if kernel is not None:
        _set_flow(kernel, inputs, outputs)


def _static_weight_inputs(op: str, backend: str) -> list[dict]:
    if backend == FPINT_GEMM_IMPROVE_BACKEND:
        return [
            _input_flow("W", f"param:{op}.weight", "gemm_w_tiled"),
            _input_flow("scale/zp", f"param:{op}.qparams", "gemm_scale_zp_tiled"),
        ]
    if backend == FPINT_GEMM_NAIVE_BACKEND:
        return [
            _input_flow("W", f"param:{op}.weight", "row_major"),
            _input_flow("scale/zp", f"param:{op}.qparams", "row_major"),
        ]
    if backend == "sgemm_tcu":
        return [_input_flow("B", f"param:{op}.weight", "row_major_fp16")]
    return [_input_flow("B", f"param:{op}.weight", "row_major")]


def _annotate_generic_layout_flows(kernels: list[dict]) -> None:
    for kernel in kernels:
        shape = dict(kernel.get("shape") or {})
        layout_from = shape.get("layout_from")
        layout_to = shape.get("layout_to")
        producers = _split_flow_nodes(shape.get("producer"))
        consumers = _split_flow_nodes(shape.get("consumer"))
        if layout_from and producers:
            kernel["inputs"] = _input_flows("x", producers, str(layout_from))
        if layout_to and consumers:
            kernel["outputs"] = _output_flows("y", consumers, str(layout_to))


def annotate_kernel_flow(kernels: list[dict]) -> None:
    """Add explicit role-level dataflow metadata for layout visualization.

    The generator keeps the older shape.producer/consumer fields for suite
    compatibility. This pass adds structured inputs/outputs so the text layout
    view can show every operand edge without guessing inside the renderer.
    """
    kernels_by_name = {str(kernel["name"]): kernel for kernel in kernels}
    names = set(kernels_by_name)
    for kernel in kernels:
        kernel["inputs"] = []
        kernel["outputs"] = []

    _annotate_generic_layout_flows(kernels)

    has_qkv_tile = "layout_input_layernorm_to_qkv" in names
    input_norm_out_layout = (
        "row_major"
        if has_qkv_tile
        else (
            "gemm_a_tiled"
            if _kernel_backend(kernels_by_name, "input_layernorm") == "rms_norm_layout_fused"
            else "row_major"
        )
    )
    input_norm_target = (
        ["layout_input_layernorm_to_qkv"]
        if has_qkv_tile else _targets_existing(["q_proj", "k_proj", "v_proj"], names)
    )
    _set_flow_by_name(
        kernels_by_name,
        "embedding_lookup",
        inputs=[_input_flow("tokens", "input_ids", "token_ids")],
        outputs=_output_flows("hidden", ["input_layernorm"], "row_major"),
    )
    input_norm_source = "embedding_lookup" if "embedding_lookup" in names else "model_input"
    _set_flow_by_name(
        kernels_by_name,
        "input_layernorm",
        inputs=[_input_flow("x", input_norm_source, "row_major")],
        outputs=_output_flows("hidden", input_norm_target, input_norm_out_layout),
    )

    for proj, target_candidates in (
        ("q_proj", ["layout_q_proj_to_rope_q_detile", "rope_q"]),
        ("k_proj", ["layout_k_proj_to_rope_k_detile", "rope_k"]),
        ("v_proj", ["layout_v_proj_to_v_cache_detile", "kv_cache_quant_v_cache_to_attn_pv", "attn_pv"]),
    ):
        if proj not in names:
            continue
        backend = _kernel_backend(kernels_by_name, proj)
        a_source = "layout_input_layernorm_to_qkv" if has_qkv_tile else "input_layernorm"
        target = _first_existing(target_candidates, names)
        outputs = [_output_flow("C", target, _gemm_c_layout(backend))] if target else []
        if proj == "v_proj" and "kv_cache_quant_v_cache_to_attn_pv" in names:
            outputs = [
                _output_flow(
                    "C",
                    "kv_cache_quant_v_cache_to_attn_pv",
                    _kernel_layout_from(kernels_by_name, "kv_cache_quant_v_cache_to_attn_pv", "row_major_fp16"),
                )
            ]
            if _standard_quant_is_cache_store_only(
                kernels_by_name,
                names,
                attn_name="attn_pv",
                quant_name="kv_cache_quant_v_cache_to_attn_pv",
                tiled_layout_name="layout_v_cache_to_attn_pv",
            ):
                outputs.append(_output_flow("C", "attn_pv", _gemm_c_layout(backend)))
        _set_flow_by_name(
            kernels_by_name,
            proj,
            inputs=[_input_flow("A", a_source, _gemm_a_layout(backend))]
                   + _static_weight_inputs(proj, backend),
            outputs=outputs,
        )

    # Q path into QK^T.
    rope_q = kernels_by_name.get("rope_q")
    if rope_q:
        shape = dict(rope_q.get("shape") or {})
        source = _first_existing(["layout_q_proj_to_rope_q_detile", "q_proj"], names) or "q_proj"
        target = _first_existing(["spinquant_r3_q_hadamard", "layout_rope_q_to_attn_qkT", "attn_qkT"], names)
        input_layout = str(shape.get("layout_from", "row_major"))
        output_layout = str(shape.get("layout_to", "row_major"))
        if target == "spinquant_r3_q_hadamard":
            output_layout = _kernel_layout_from(kernels_by_name, target, "row_major_fp16")
        _set_flow(
            rope_q,
            inputs=[_input_flow("x", source, input_layout)],
            outputs=([_output_flow("q", target, output_layout)] if target else []),
        )

    rope_k = kernels_by_name.get("rope_k")
    if rope_k:
        shape = dict(rope_k.get("shape") or {})
        source = _first_existing(["layout_k_proj_to_rope_k_detile", "k_proj"], names) or "k_proj"
        input_layout = str(shape.get("layout_from", "row_major"))
        output_layout = str(shape.get("layout_to", "row_major"))
        outputs = []
        if "spinquant_r3_k_hadamard" in names:
            outputs.append(_output_flow(
                "k",
                "spinquant_r3_k_hadamard",
                _kernel_layout_from(kernels_by_name, "spinquant_r3_k_hadamard", "row_major_fp16"),
            ))
        elif "kv_cache_quant_rope_k_to_attn_qkT" in names:
            outputs.append(
                _output_flow(
                    "k",
                    "kv_cache_quant_rope_k_to_attn_qkT",
                    _kernel_layout_from(kernels_by_name, "kv_cache_quant_rope_k_to_attn_qkT", "row_major_fp16"),
                )
            )
            if _standard_quant_is_cache_store_only(
                kernels_by_name,
                names,
                attn_name="attn_qkT",
                quant_name="kv_cache_quant_rope_k_to_attn_qkT",
                tiled_layout_name="layout_rope_k_to_attn_qkT",
            ):
                outputs.append(_output_flow("k", "attn_qkT", output_layout))
        else:
            target = _first_existing(["layout_rope_k_to_attn_qkT", "attn_qkT"], names)
            outputs = [_output_flow("k", target, output_layout)] if target else []
        _set_flow(
            rope_k,
            inputs=[_input_flow("x", source, input_layout)],
            outputs=outputs,
        )

    for hadamard_name, output_role in (
        ("spinquant_r3_q_hadamard", "q"),
        ("spinquant_r3_k_hadamard", "k"),
        ("spinquant_r4_mlp_hadamard", "hidden"),
    ):
        hadamard = kernels_by_name.get(hadamard_name)
        if not hadamard:
            continue
        shape = dict(hadamard.get("shape") or {})
        _set_flow(
            hadamard,
            inputs=[
                _input_flow(
                    "x",
                    str(shape.get("producer", "unknown")),
                    str(shape.get("layout_from", "row_major_fp16")),
                )
            ],
            outputs=_output_flows(
                output_role,
                _targets_existing(_split_flow_nodes(shape.get("consumer")), names),
                str(shape.get("layout_to", "row_major_fp16")),
            ),
        )

    k_quant = kernels_by_name.get("kv_cache_quant_rope_k_to_attn_qkT")
    if k_quant:
        shape = dict(k_quant.get("shape") or {})
        if k_quant.get("backend") == "kv_cache_quant_layout_fused_w4a16":
            outputs = [
                _output_flow("W", "attn_qkT", str(shape.get("weight_layout_to", "gemm_w_tiled"))),
                _output_flow("scale/zp", "attn_qkT", str(shape.get("scale_zp_layout_to", "gemm_scale_zp_tiled"))),
            ]
        else:
            outputs = []
            if "layout_rope_k_to_attn_qkT" in names:
                outputs.append(_output_flow("packed", "layout_rope_k_to_attn_qkT", "packed_w4a16_row_major"))
            if "layout_rope_k_qparams_to_attn_qkT" in names:
                outputs.append(_output_flow("scale/zp", "layout_rope_k_qparams_to_attn_qkT", "qparams_row_major"))
            if _standard_quant_feeds_attention(
                kernels_by_name,
                names,
                attn_name="attn_qkT",
                quant_name="kv_cache_quant_rope_k_to_attn_qkT",
                tiled_layout_name="layout_rope_k_to_attn_qkT",
            ):
                attn_backend = _kernel_backend(kernels_by_name, "attn_qkT")
                attn_shape = dict(kernels_by_name.get("attn_qkT", {}).get("shape") or {})
                wtrans = int(attn_shape.get("WTRANS", 0))
                outputs.extend([
                    _output_flow("W", "attn_qkT", _gemm_w_layout(attn_backend, wtrans)),
                    _output_flow("scale/zp", "attn_qkT", _gemm_qparam_layout(attn_backend) or "row_major"),
                ])
            elif not outputs:
                target = str(shape.get("consumer", "kv_cache:k"))
                outputs.extend([
                    _output_flow("packed", target, "packed_w4a16_row_major"),
                    _output_flow("scale/zp", target, "qparams_row_major"),
                ])
        _set_flow(
            k_quant,
            inputs=[
                _input_flow(
                    "x",
                    _first_existing(["spinquant_r3_k_hadamard", "rope_k"], names) or "rope_k",
                    str(shape.get("layout_from", "row_major_fp16")),
                )
            ],
            outputs=outputs,
        )

    # Attention QK^T.
    attn_qk = kernels_by_name.get("attn_qkT")
    if attn_qk:
        backend = _kernel_backend(kernels_by_name, "attn_qkT")
        attn_shape = dict(attn_qk.get("shape") or {})
        default_w_layout = _gemm_w_layout(backend, int(attn_shape.get("WTRANS", 0)))
        default_qparam_layout = _gemm_qparam_layout(backend)
        a_source = _first_existing([
            "layout_rope_q_to_attn_qkT",
            "spinquant_r3_q_hadamard",
            "rope_q",
        ], names) or "rope_q"
        a_layout = _producer_output_layout(kernels_by_name, a_source, _gemm_a_layout(backend))
        if "layout_rope_k_to_attn_qkT" in names:
            w_source = "layout_rope_k_to_attn_qkT"
            scale_source = "layout_rope_k_qparams_to_attn_qkT"
            w_layout = _kernel_weight_layout_to(kernels_by_name, w_source, default_w_layout)
            scale_layout = _kernel_qparam_layout_to(kernels_by_name, scale_source, default_qparam_layout or "row_major")
        elif kernels_by_name.get("kv_cache_quant_rope_k_to_attn_qkT", {}).get("backend") == "kv_cache_quant_layout_fused_w4a16":
            w_source = "kv_cache_quant_rope_k_to_attn_qkT"
            scale_source = "kv_cache_quant_rope_k_to_attn_qkT"
            w_layout = _kernel_weight_layout_to(kernels_by_name, w_source, default_w_layout)
            scale_layout = _kernel_qparam_layout_to(kernels_by_name, scale_source, default_qparam_layout or "row_major")
        elif _standard_quant_feeds_attention(
            kernels_by_name,
            names,
            attn_name="attn_qkT",
            quant_name="kv_cache_quant_rope_k_to_attn_qkT",
            tiled_layout_name="layout_rope_k_to_attn_qkT",
        ):
            w_source = "kv_cache_quant_rope_k_to_attn_qkT"
            scale_source = "kv_cache_quant_rope_k_to_attn_qkT"
            w_layout = default_w_layout
            scale_layout = default_qparam_layout or "row_major"
        else:
            w_source = _first_existing(["spinquant_r3_k_hadamard", "rope_k"], names) or "rope_k"
            scale_source = f"param:{attn_qk['name']}.qparams"
            w_layout = _producer_output_layout(kernels_by_name, w_source, default_w_layout)
            scale_layout = default_qparam_layout or "row_major"
        inputs = [
            _input_flow("A", a_source, a_layout),
            _input_flow("W" if backend in FPINT_GEMM_BACKENDS else "B", w_source, w_layout),
        ]
        if default_qparam_layout:
            inputs.append(_input_flow("scale/zp", scale_source, scale_layout))
        target = _first_existing(["layout_attn_qkT_to_softmax_detile", "attn_softmax"], names)
        _set_flow(
            attn_qk,
            inputs=inputs,
            outputs=([_output_flow("C", target, _gemm_c_layout(backend))] if target else []),
        )

    softmax = kernels_by_name.get("attn_softmax")
    if softmax:
        shape = dict(softmax.get("shape") or {})
        source = _first_existing(["layout_attn_qkT_to_softmax_detile", "attn_qkT"], names) or "attn_qkT"
        target = _first_existing(["layout_attn_softmax_to_attn_pv", "attn_pv"], names)
        _set_flow(
            softmax,
            inputs=[_input_flow("scores", source, str(shape.get("layout_from", "row_major")))],
            outputs=([_output_flow("prob", target, str(shape.get("layout_to", "row_major")))] if target else []),
        )

    v_quant = kernels_by_name.get("kv_cache_quant_v_cache_to_attn_pv")
    if v_quant:
        shape = dict(v_quant.get("shape") or {})
        if v_quant.get("backend") == "kv_cache_quant_layout_fused_w4a16":
            outputs = [
                _output_flow("W", "attn_pv", str(shape.get("weight_layout_to", "gemm_w_tiled"))),
                _output_flow("scale/zp", "attn_pv", str(shape.get("scale_zp_layout_to", "gemm_scale_zp_tiled"))),
            ]
        else:
            outputs = []
            if "layout_v_cache_to_attn_pv" in names:
                outputs.append(_output_flow("packed", "layout_v_cache_to_attn_pv", "packed_w4a16_row_major"))
            if "layout_v_cache_qparams_to_attn_pv" in names:
                outputs.append(_output_flow("scale/zp", "layout_v_cache_qparams_to_attn_pv", "qparams_row_major"))
            if _standard_quant_feeds_attention(
                kernels_by_name,
                names,
                attn_name="attn_pv",
                quant_name="kv_cache_quant_v_cache_to_attn_pv",
                tiled_layout_name="layout_v_cache_to_attn_pv",
            ):
                attn_backend = _kernel_backend(kernels_by_name, "attn_pv")
                attn_shape = dict(kernels_by_name.get("attn_pv", {}).get("shape") or {})
                wtrans = int(attn_shape.get("WTRANS", 0))
                outputs.extend([
                    _output_flow("W", "attn_pv", _gemm_w_layout(attn_backend, wtrans)),
                    _output_flow("scale/zp", "attn_pv", _gemm_qparam_layout(attn_backend) or "row_major"),
                ])
            elif not outputs:
                target = str(shape.get("consumer", "kv_cache:v"))
                outputs.extend([
                    _output_flow("packed", target, "packed_w4a16_row_major"),
                    _output_flow("scale/zp", target, "qparams_row_major"),
                ])
        source = _first_existing(["layout_v_proj_to_v_cache_detile", "v_proj"], names) or "v_proj"
        _set_flow(
            v_quant,
            inputs=[_input_flow("x", source, str(shape.get("layout_from", "row_major_fp16")))],
            outputs=outputs,
        )

    attn_pv = kernels_by_name.get("attn_pv")
    if attn_pv:
        backend = _kernel_backend(kernels_by_name, "attn_pv")
        attn_shape = dict(attn_pv.get("shape") or {})
        default_w_layout = _gemm_w_layout(backend, int(attn_shape.get("WTRANS", 0)))
        default_qparam_layout = _gemm_qparam_layout(backend)
        a_source = _first_existing(["layout_attn_softmax_to_attn_pv", "attn_softmax"], names) or "attn_softmax"
        if "layout_v_cache_to_attn_pv" in names:
            w_source = "layout_v_cache_to_attn_pv"
            scale_source = "layout_v_cache_qparams_to_attn_pv"
            w_layout = _kernel_weight_layout_to(kernels_by_name, w_source, default_w_layout)
            scale_layout = _kernel_qparam_layout_to(kernels_by_name, scale_source, default_qparam_layout or "row_major")
        elif kernels_by_name.get("kv_cache_quant_v_cache_to_attn_pv", {}).get("backend") == "kv_cache_quant_layout_fused_w4a16":
            w_source = "kv_cache_quant_v_cache_to_attn_pv"
            scale_source = "kv_cache_quant_v_cache_to_attn_pv"
            w_layout = _kernel_weight_layout_to(kernels_by_name, w_source, default_w_layout)
            scale_layout = _kernel_qparam_layout_to(kernels_by_name, scale_source, default_qparam_layout or "row_major")
        elif _standard_quant_feeds_attention(
            kernels_by_name,
            names,
            attn_name="attn_pv",
            quant_name="kv_cache_quant_v_cache_to_attn_pv",
            tiled_layout_name="layout_v_cache_to_attn_pv",
        ):
            w_source = "kv_cache_quant_v_cache_to_attn_pv"
            scale_source = "kv_cache_quant_v_cache_to_attn_pv"
            w_layout = default_w_layout
            scale_layout = default_qparam_layout or "row_major"
        else:
            w_source = "v_proj"
            scale_source = f"param:{attn_pv['name']}.qparams"
            w_layout = default_w_layout
            scale_layout = default_qparam_layout or "row_major"
        inputs = [
            _input_flow("A", a_source, _gemm_a_layout(backend)),
            _input_flow("W" if backend in FPINT_GEMM_BACKENDS else "B", w_source, w_layout),
        ]
        if default_qparam_layout:
            inputs.append(_input_flow("scale/zp", scale_source, scale_layout))
        target = _first_existing(["layout_attn_pv_to_head_concat_detile", "attn_head_concat"], names)
        output_layout = _gemm_c_layout(backend)
        concat = kernels_by_name.get("attn_head_concat")
        if target == "attn_head_concat" and concat:
            concat_shape = dict(concat.get("shape") or {})
            output_layout = str(concat_shape.get("layout_from", output_layout))
        _set_flow(
            attn_pv,
            inputs=inputs,
            outputs=([_output_flow("C", target, output_layout)] if target else []),
        )

    concat = kernels_by_name.get("attn_head_concat")
    if concat:
        shape = dict(concat.get("shape") or {})
        source = _first_existing(["layout_attn_pv_to_head_concat_detile", "attn_pv"], names) or "attn_pv"
        target = _first_existing(["layout_attn_head_concat_to_o_proj", "o_proj"], names)
        _set_flow(
            concat,
            inputs=[_input_flow("heads", source, str(shape.get("layout_from", "row_major")))],
            outputs=([_output_flow("hidden", target, str(shape.get("layout_to", "row_major")))] if target else []),
        )

    # Output projection and attention residual.
    if "o_proj" in names:
        backend = _kernel_backend(kernels_by_name, "o_proj")
        a_source = _first_existing(["layout_attn_head_concat_to_o_proj", "attn_head_concat"], names) or "attn_head_concat"
        target = _first_existing(["layout_o_proj_to_residual_attn_detile", "residual_attn"], names)
        _set_flow_by_name(
            kernels_by_name,
            "o_proj",
            inputs=[_input_flow("A", a_source, _gemm_a_layout(backend))]
                   + _static_weight_inputs("o_proj", backend),
            outputs=([_output_flow("C", target, _gemm_c_layout(backend))] if target else []),
        )

    residual_attn = kernels_by_name.get("residual_attn")
    if residual_attn:
        shape = dict(residual_attn.get("shape") or {})
        source = _first_existing(["layout_o_proj_to_residual_attn_detile", "o_proj"], names) or "o_proj"
        _set_flow(
            residual_attn,
            inputs=[
                _input_flow("x", source, str(shape.get("layout_from", "row_major"))),
                _input_flow("residual", "residual_stream:attention_input", "row_major"),
            ],
            outputs=_output_flows("hidden", _targets_existing(["post_attention_layernorm"], names), "row_major"),
        )

    post_norm = kernels_by_name.get("post_attention_layernorm")
    if post_norm:
        shape = dict(post_norm.get("shape") or {})
        target = ["layout_post_attention_layernorm_to_gate_up"] if "layout_post_attention_layernorm_to_gate_up" in names else _targets_existing(["gate_proj", "up_proj"], names)
        output_layout = str(shape.get("layout_to", "row_major"))
        _set_flow(
            post_norm,
            inputs=[_input_flow("x", "residual_attn", str(shape.get("layout_from", "row_major")))],
            outputs=_output_flows("hidden", target, output_layout),
        )

    for proj, role in (("gate_proj", "gate"), ("up_proj", "up")):
        if proj not in names:
            continue
        backend = _kernel_backend(kernels_by_name, proj)
        a_source = "layout_post_attention_layernorm_to_gate_up" if "layout_post_attention_layernorm_to_gate_up" in names else "post_attention_layernorm"
        target = _first_existing([f"layout_{proj.split('_')[0]}_proj_to_mlp_{'silu' if proj == 'gate_proj' else 'elmul'}_detile", "mlp_silu" if proj == "gate_proj" else "mlp_elmul"], names)
        _set_flow_by_name(
            kernels_by_name,
            proj,
            inputs=[_input_flow("A", a_source, _gemm_a_layout(backend))]
                   + _static_weight_inputs(proj, backend),
            outputs=([_output_flow("C", target, _gemm_c_layout(backend))] if target else []),
        )

    silu = kernels_by_name.get("mlp_silu")
    if silu:
        shape = dict(silu.get("shape") or {})
        source = _first_existing(["layout_gate_proj_to_mlp_silu_detile", "gate_proj"], names) or "gate_proj"
        _set_flow(
            silu,
            inputs=[_input_flow("x", source, str(shape.get("layout_from", "row_major")))],
            outputs=[_output_flow("silu", "mlp_elmul", str(shape.get("layout_to", "row_major")))],
        )

    elmul = kernels_by_name.get("mlp_elmul")
    if elmul:
        shape = dict(elmul.get("shape") or {})
        up_source = _first_existing(["layout_up_proj_to_mlp_elmul_detile", "up_proj"], names) or "up_proj"
        inputs = [
            _input_flow("x", "mlp_silu", str(shape.get("layout_from", "row_major"))),
            _input_flow("y", up_source, "gemm_c_tiled" if elmul.get("backend") == "elmul_layout_fused" else "row_major"),
        ]
        target = _first_existing(["spinquant_r4_mlp_hadamard", "layout_mlp_elmul_to_down_proj", "down_proj"], names)
        output_layout = str(shape.get("layout_to", "row_major"))
        if target == "spinquant_r4_mlp_hadamard":
            output_layout = _kernel_layout_from(kernels_by_name, target, "row_major_fp16")
        _set_flow(
            elmul,
            inputs=inputs,
            outputs=([_output_flow("product", target, output_layout)] if target else []),
        )

    if "down_proj" in names:
        backend = _kernel_backend(kernels_by_name, "down_proj")
        a_source = _first_existing([
            "layout_mlp_elmul_to_down_proj",
            "spinquant_r4_mlp_hadamard",
            "mlp_elmul",
        ], names) or "mlp_elmul"
        a_layout = _producer_output_layout(kernels_by_name, a_source, _gemm_a_layout(backend))
        target = _first_existing(["layout_down_proj_to_residual_ffn_detile", "residual_ffn"], names)
        _set_flow_by_name(
            kernels_by_name,
            "down_proj",
            inputs=[_input_flow("A", a_source, a_layout)]
                   + _static_weight_inputs("down_proj", backend),
            outputs=([_output_flow("C", target, _gemm_c_layout(backend))] if target else []),
        )

    residual_ffn = kernels_by_name.get("residual_ffn")
    if residual_ffn:
        shape = dict(residual_ffn.get("shape") or {})
        source = _first_existing(["layout_down_proj_to_residual_ffn_detile", "down_proj"], names) or "down_proj"
        targets = _targets_existing(["final_layernorm", "next_layer"], names)
        if not targets:
            targets = ["model_output"]
        _set_flow(
            residual_ffn,
            inputs=[
                _input_flow("x", source, str(shape.get("layout_from", "row_major"))),
                _input_flow("residual", "residual_attn", "row_major"),
            ],
            outputs=_output_flows("hidden", targets, "row_major"),
        )

    _set_flow_by_name(
        kernels_by_name,
        "final_layernorm",
        inputs=[_input_flow("x", "residual_ffn", "row_major")],
        outputs=[_output_flow("hidden", "model_output", "row_major")],
    )


# ===========================================================================
# Text layout visualization.
# ===========================================================================
def _shape_summary(shape: dict) -> str:
    if "M" in shape:
        keys = ("M", "N", "K", "QBLK", "QDIR", "source_QDIR", "gemm_QDIR", "WTRANS")
    elif "K" in shape or "N" in shape:
        keys = ("K", "N", "QBLK", "QDIR", "source_QDIR", "gemm_QDIR", "WTRANS")
    else:
        keys = ()
    keys += (
        "rows", "dim", "batch", "seq", "hidden", "heads", "headdim", "seqq", "seqk",
        "effective_K", "effective_N", "cache_len", "cache_update",
        "source_transposed", "spinquant_rotation",
    )
    return ", ".join(
        f"{key}={shape[key]}" for key in keys if key in shape
    )


def _args_summary(kernel: dict) -> str:
    args = str(kernel.get("args", "")).strip()
    if not args:
        return "args=<none>"
    return f"args={shlex.quote(args)}"


def _kernel_input_layout(kernel: dict) -> str:
    kind = str(kernel.get("kind", ""))
    backend = str(kernel.get("backend", ""))
    shape = dict(kernel.get("shape") or {})

    if kind == "gemm":
        if backend == FPINT_GEMM_IMPROVE_BACKEND:
            w_layout = "gemm_w_tiled_transposed" if int(shape.get("WTRANS", 0)) else "gemm_w_tiled"
            return f"A:gemm_a_tiled + W:{w_layout} + scale/zp:gemm_scale_zp_tiled"
        if backend == FPINT_GEMM_NAIVE_BACKEND:
            return "A:row_major + W:row_major + scale/zp:row_major"
        if backend == "sgemm_tcu":
            return "A:row_major_fp16 + B:row_major_fp16"
        return "A:row_major + B:row_major"

    if "layout_from" in shape:
        layout_from = str(shape["layout_from"])
        if kind == "eladd" and backend == "eladd_layout_fused":
            return f"{layout_from} + row_major"
        if kind == "elmul" and backend == "elmul_layout_fused":
            return f"{layout_from} + gemm_c_tiled"
        return layout_from

    if kind == "embedding":
        return "token_ids"
    if kind in {"eladd", "elmul"}:
        return "row_major + row_major"
    if kind in {"rmsnorm", "rope", "softmax", "silu", "concat", "quantization", "hadamard"}:
        return "row_major"
    return "unknown"


def _kernel_output_layout(kernel: dict) -> str:
    kind = str(kernel.get("kind", ""))
    backend = str(kernel.get("backend", ""))
    shape = dict(kernel.get("shape") or {})

    if kind == "gemm":
        if backend == FPINT_GEMM_IMPROVE_BACKEND:
            return "C:gemm_c_tiled"
        if backend == "sgemm_tcu":
            return "C:row_major_fp16"
        return "C:row_major"

    if "weight_layout_to" in shape or "scale_zp_layout_to" in shape:
        parts = []
        if "weight_layout_to" in shape:
            parts.append(f"weight:{shape['weight_layout_to']}")
        if "scale_zp_layout_to" in shape:
            parts.append(f"scale/zp:{shape['scale_zp_layout_to']}")
        return " + ".join(parts)

    if "layout_to" in shape:
        return str(shape["layout_to"])
    if kind == "embedding":
        return "row_major"
    if kind in {"rmsnorm", "rope", "softmax", "silu", "eladd", "elmul", "concat", "hadamard"}:
        return "row_major"
    if kind == "quantization":
        return "packed_w4a16_row_major + qparams_row_major"
    return "unknown"


def format_layout_view(payload: dict) -> str:
    """Render a role-level graph view of kernel input/output layouts."""
    cfg = dict(payload.get("config") or {})
    stages = list(cfg.get("stages") or [])
    if not stages:
        stages = []
        for kernel in payload.get("kernels", []):
            stage = str(kernel.get("stage", ""))
            if stage and stage not in stages:
                stages.append(stage)

    lines = [
        (
            f"# model={payload.get('model')} variant={cfg.get('variant')} "
            f"batch={cfg.get('batch')} prefill_seq_len={cfg.get('prefill_seq_len')} "
            f"gen_kv_len={cfg.get('gen_kv_len')} qblk={cfg.get('qblk')}"
        )
    ]

    kernels = list(payload.get("kernels") or [])
    for stage in stages:
        stage_kernels = [kernel for kernel in kernels if kernel.get("stage") == stage]
        lines.append("")
        lines.append(f"[stage: {stage}]")
        for idx, kernel in enumerate(stage_kernels, start=1):
            shape = dict(kernel.get("shape") or {})
            name = str(kernel.get("name", ""))
            kind = str(kernel.get("kind", ""))
            backend = str(kernel.get("backend", ""))
            app = str(kernel.get("app") or "-")
            calls = kernel.get("calls_per_forward", 1)
            implemented = "" if kernel.get("implemented", False) else " NOT_IMPL"
            line = (
                f"{idx:02d}. {name:<36} "
                f"[{kind}/{backend} app={app} x{calls}{implemented}]"
            )
            summary = _shape_summary(shape)
            if summary:
                line += f" | {summary}"
            line += f" | {_args_summary(kernel)}"
            lines.append(line)

            inputs = list(kernel.get("inputs") or [])
            outputs = list(kernel.get("outputs") or [])
            if not inputs:
                inputs = [_input_flow("x", "?", _kernel_input_layout(kernel))]
            if not outputs:
                outputs = [_output_flow("y", "?", _kernel_output_layout(kernel))]
            for item in inputs:
                role = str(item.get("role", "x"))
                source = str(item.get("source", "?"))
                layout = str(item.get("layout", "?"))
                lines.append(f"    in : {role:<9} <- {source:<42} : {layout}")
            for item in outputs:
                role = str(item.get("role", "y"))
                target = str(item.get("target", "?"))
                layout = str(item.get("layout", "?"))
                lines.append(f"    out: {role:<9} -> {target:<42} : {layout}")

    return "\n".join(lines) + "\n"


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
            "  --model llama2-7b --variant all_fpint_gemm_improve_fused_layout --format layout\n"
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
        "--format", choices=("json", "layout", "text"), default="json",
        help="Output format. 'layout'/'text' prints a compact input/output "
             "layout view instead of JSON (default: json).",
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

    if args.format in ("layout", "text"):
        text = format_layout_view(payload)
    else:
        text = json.dumps(payload, indent=2) + "\n"
    n = len(payload["kernels"])
    summary = (f"{n} cfgs (stages={','.join(stages)}"
               + (f", filter={args.filter_kind}" if args.filter_kind else "")
               + (f", backend={args.filter_backend}" if args.filter_backend else "")
               + f", format={args.format})")
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
