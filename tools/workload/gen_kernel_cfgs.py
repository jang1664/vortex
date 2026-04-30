#!/usr/bin/env python3
"""Generate kernel configurations for one LLM forward pass.

Emit the full kernel call list for one forward pass of a model in each
requested stage (prefill / generation), including non-GEMM ops
(RMSNorm, RoPE, softmax, SiLU, residual eladd, SwiGLU elmul). Each kernel
is tagged with how many times it is invoked per forward pass and whether
the corresponding regression test app exists ("implemented").

Importable: ci/test_fpint_hw.py reuses build_fpint_gemm_args_for_model to
drive its HW regression sweep — extracting only the fpint_gemm calls out
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

# Map logical kernel kind -> regression test/app name. None means the
# corresponding kernel is not yet implemented as a regression test, so the
# generated entry will have ``"implemented": false`` and an empty ``args``.
KERNEL_APP_REGISTRY: dict[str, str | None] = {
    "fpint_gemm": "fpint_gemm_ffn_hw_improve",
    "rmsnorm":    "rmsnorm",
    "rope":       "rope",
    "softmax":    "softmax",
    "silu":       "silu",
    "eladd":      "eladd",
    "elmul":      "elmul",
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
                shape: dict) -> dict:
    """Wrap a single kernel invocation in the standard JSON shape."""
    app = KERNEL_APP_REGISTRY.get(kind)
    return {
        "stage": stage,
        "name": name,
        "kind": kind,
        "app": app,
        "implemented": app is not None,
        "calls_per_forward": calls_per_forward,
        "shape": shape,
        "args": args if app is not None else "",
    }


def build_decoder_pass_kernels(config: dict,
                               stage: str,
                               batch: int,
                               seq_q: int,
                               seq_kv: int,
                               qblk: int) -> list[dict]:
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
      qblk: QBLK for fpint GEMMs (FFN + QKVO projections + lm_head).

    Counts (calls_per_forward):
      Per-decoder-layer kernels are multiplied by num_layers (L).
      Attention QK^T / PV are per-head per-batch, so multiplied further by
      batch * num_attention_heads. Model-level kernels (embedding,
      final_layernorm, lm_head) fire exactly once per forward pass.
    """
    if stage not in LLM_STAGES:
        raise ValueError(f"unknown stage: {stage!r}. Expected one of {LLM_STAGES}")

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
    ))

    # 2-4. Q / K / V projections (fpint_gemm: M=B*S_q, N=q_dim/kv_dim, K=H)
    out.append(_llm_kernel(
        name="q_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {q_dim} -k {H} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": q_dim, "K": H,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))
    out.append(_llm_kernel(
        name="k_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {kv_dim} -k {H} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": kv_dim, "K": H,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))
    out.append(_llm_kernel(
        name="v_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {kv_dim} -k {H} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": kv_dim, "K": H,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))

    # 5-6. RoPE on Q and K
    out.append(_llm_kernel(
        name="rope_q", kind="rope", stage=stage,
        args=(f"-batch {batch} -seq {seq_q} -heads {H_q} -headdim {D} "
              f"-maxseq {max_seq} -offset {pos_offset}"),
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "heads": H_q, "headdim": D,
               "maxseq": max_seq, "offset": pos_offset},
    ))
    out.append(_llm_kernel(
        name="rope_k", kind="rope", stage=stage,
        args=(f"-batch {batch} -seq {seq_q} -heads {H_kv} -headdim {D} "
              f"-maxseq {max_seq} -offset {pos_offset}"),
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "heads": H_kv, "headdim": D,
               "maxseq": max_seq, "offset": pos_offset},
    ))

    # 7. Attention QK^T (per-head per-batch fpint GEMM)
    out.append(_llm_kernel(
        name="attn_qkT", kind="fpint_gemm", stage=stage,
        args=f"-m {seq_q} -n {seq_kv} -k {D} -q {D} -t 1 -d 0",
        calls_per_forward=L * batch * H_q,
        shape={"M": seq_q, "N": seq_kv, "K": D,
               "QBLK": D, "WTRANS": 1, "QDIR": 0,
               "per_head": True},
    ))

    # 8. Attention softmax over scores [B, H_q, S_q, S_kv]
    out.append(_llm_kernel(
        name="attn_softmax", kind="softmax", stage=stage,
        args=(f"-batch {batch} -heads {H_q} -seqq {seq_q} -seqk {seq_kv} "
              f"-mask {use_mask}"),
        calls_per_forward=L,
        shape={"batch": batch, "heads": H_q,
               "seqq": seq_q, "seqk": seq_kv, "mask": use_mask},
    ))

    # 9. Attention PV (per-head per-batch fpint GEMM)
    out.append(_llm_kernel(
        name="attn_pv", kind="fpint_gemm", stage=stage,
        args=f"-m {seq_q} -n {D} -k {seq_kv} -q {D} -t 0 -d 1",
        calls_per_forward=L * batch * H_q,
        shape={"M": seq_q, "N": D, "K": seq_kv,
               "QBLK": D, "WTRANS": 0, "QDIR": 1,
               "per_head": True},
    ))

    # 10. Output projection (fpint_gemm: M=B*S_q, N=H, K=q_dim)
    out.append(_llm_kernel(
        name="o_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {H} -k {q_dim} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": H, "K": q_dim,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))

    # 11. Residual add (attn): [B, S_q, H]
    out.append(_llm_kernel(
        name="residual_attn", kind="eladd", stage=stage,
        args=f"-n {BS_H}",
        calls_per_forward=L,
        shape={"size": BS_H},
    ))

    # 12. post_attention_layernorm
    out.append(_llm_kernel(
        name="post_attention_layernorm", kind="rmsnorm", stage=stage,
        args=f"-batch {batch} -seq {seq_q} -hidden {H}",
        calls_per_forward=L,
        shape={"batch": batch, "seq": seq_q, "hidden": H},
    ))

    # 13-14. gate / up projections (fpint_gemm: M=B*S_q, N=I, K=H)
    out.append(_llm_kernel(
        name="gate_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {I} -k {H} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": I, "K": H,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))
    out.append(_llm_kernel(
        name="up_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {I} -k {H} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": I, "K": H,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))

    # 15. SiLU on gate output [B, S_q, I]
    out.append(_llm_kernel(
        name="mlp_silu", kind="silu", stage=stage,
        args=f"-n {BS_I}",
        calls_per_forward=L,
        shape={"size": BS_I},
    ))

    # 16. Elementwise multiply (SwiGLU: SiLU(gate) * up) over [B, S_q, I]
    out.append(_llm_kernel(
        name="mlp_elmul", kind="elmul", stage=stage,
        args=f"-n {BS_I}",
        calls_per_forward=L,
        shape={"size": BS_I},
    ))

    # 17. down projection (fpint_gemm: M=B*S_q, N=H, K=I)
    out.append(_llm_kernel(
        name="down_proj", kind="fpint_gemm", stage=stage,
        args=f"-m {M_proj} -n {H} -k {I} -q {qblk} -t 0 -d 0",
        calls_per_forward=L,
        shape={"M": M_proj, "N": H, "K": I,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))

    # 18. Residual add (ffn): [B, S_q, H]
    out.append(_llm_kernel(
        name="residual_ffn", kind="eladd", stage=stage,
        args=f"-n {BS_H}",
        calls_per_forward=L,
        shape={"size": BS_H},
    ))

    # ---------------- Model-level kernels (× 1) ---------------------------

    # 19. final_layernorm (model-level RMSNorm)
    out.append(_llm_kernel(
        name="final_layernorm", kind="rmsnorm", stage=stage,
        args=f"-batch {batch} -seq {seq_q} -hidden {H}",
        calls_per_forward=1,
        shape={"batch": batch, "seq": seq_q, "hidden": H},
    ))

    # 20. lm_head: project the last position's hidden state to logits.
    #     For both stages we project only the final token per batch element,
    #     so M = batch (this matches greedy/sampling decoding).
    out.append(_llm_kernel(
        name="lm_head", kind="fpint_gemm", stage=stage,
        args=f"-m {batch} -n {V} -k {H} -q {qblk} -t 0 -d 0",
        calls_per_forward=1,
        shape={"M": batch, "N": V, "K": H,
               "QBLK": qblk, "WTRANS": 0, "QDIR": 0},
    ))

    return out


def build_llm_kernels(model_name: str,
                      stages: list[str],
                      batch: int,
                      prefill_seq_len: int,
                      gen_kv_len: int,
                      qblk: int) -> dict:
    """Build the JSON payload covering one or more stages."""
    if model_name not in MODELS:
        raise ValueError(
            f"unknown model: {model_name!r}. Available: "
            f"{sorted(MODELS.keys())}"
        )
    config = MODELS[model_name]

    kernels: list[dict] = []
    for stage in stages:
        if stage == "prefill":
            kernels.extend(build_decoder_pass_kernels(
                config, "prefill",
                batch=batch,
                seq_q=prefill_seq_len,
                seq_kv=prefill_seq_len,
                qblk=qblk,
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
        },
        "kernels": kernels,
    }


# ===========================================================================
# Filtering helpers (used by ci/test_fpint_hw.py).
# ===========================================================================
def filter_kind_args(payload: dict, kind: str, *, dedupe: bool = True) -> list[str]:
    """Extract CLI arg strings for a single kernel kind from a payload.

    Skips entries with no app (``implemented == false``) since their
    ``args`` is intentionally empty.
    """
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
    """Cross-product (seq_lens × qblks × stages), filter to fpint_gemm,
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
            for a in filter_kind_args(payload, "fpint_gemm"):
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
    print("Kernel-app registry:")
    for kind in sorted(KERNEL_APP_REGISTRY):
        app = KERNEL_APP_REGISTRY[kind]
        flag = "implemented" if app else "NOT IMPLEMENTED"
        print(f"  {kind:12s} -> {app or '(none)':30s} [{flag}]")


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
            "  --model llama2-7b --filter-kind fpint_gemm   "
            "# only emit GEMM cfgs\n"
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
        "--filter-kind", default=None, metavar="KIND",
        help="If set, drop every kernel whose 'kind' != KIND from the "
             "output (e.g. fpint_gemm).",
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
        )
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    if args.filter_kind:
        payload["kernels"] = [
            k for k in payload["kernels"] if k["kind"] == args.filter_kind
        ]

    text = json.dumps(payload, indent=2) + "\n"
    n = len(payload["kernels"])
    summary = (f"{n} cfgs (stages={','.join(stages)}"
               + (f", filter={args.filter_kind}" if args.filter_kind else "")
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
