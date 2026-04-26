#!/usr/bin/env python3
"""Generate fpint GEMM kernel configurations from a model spec.

Given a model name and seq lengths, emit the (M, N, K, QBLK, WTRANS, QDIR)
configurations that exercise every nn.Linear layer (FFN + QKVO projections)
plus per-head attention QK^T / PV GEMMs.

Outputs a JSON file describing each kernel: a logical name and the CLI
argument string consumed by the fpint_gemm_ffn_hw_improve test app. The
module is also importable: ci/test_fpint_hw.py reuses MODELS,
build_model_args, etc. directly.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Model registry. Add entries here to extend coverage; model_linear_gemms
# handles any LLaMA-style decoder layer (plain MHA or GQA) via num_kv_heads.
# ---------------------------------------------------------------------------
MODELS: dict[str, dict[str, int]] = {
    "llama2-7b": {
        "hidden_size": 4096,
        "intermediate_size": 11008,
        "num_attention_heads": 32,
        "num_key_value_heads": 32,   # MHA (no GQA)
        "head_dim": 128,
    },
    # Future models can be added here, e.g.:
    # "llama2-13b":  {"hidden_size": 5120, "intermediate_size": 13824,
    #                 "num_attention_heads": 40, "num_key_value_heads": 40,
    #                 "head_dim": 128},
    # "llama3-8b":   {"hidden_size": 4096, "intermediate_size": 14336,
    #                 "num_attention_heads": 32, "num_key_value_heads": 8,
    #                 "head_dim": 128},
    # "mistral-7b":  {"hidden_size": 4096, "intermediate_size": 14336,
    #                 "num_attention_heads": 32, "num_key_value_heads": 8,
    #                 "head_dim": 128},
}

DEFAULT_QBLKS = [32, 64, 128]
DEFAULT_SEQ_LENS = [32, 128, 512, 1024]
DEFAULT_KERNEL_APP = "fpint_gemm_ffn_hw_improve"


# ---------------------------------------------------------------------------
# Per-layer shape derivation.
# ---------------------------------------------------------------------------
def model_linear_gemms(config: dict) -> list[tuple[str, int, int]]:
    """Return unique (label, N, K) tuples for nn.Linear layers (FFN +
    attention QKVO projections) in one LLaMA-style decoder layer.
    N = out_features, K = in_features.
    Shapes with the same (N, K) are merged and labels concatenated.
    """
    H = config["hidden_size"]
    I = config["intermediate_size"]
    head_dim = config["head_dim"]
    num_heads = config["num_attention_heads"]
    num_kv = config["num_key_value_heads"]
    q_dim = num_heads * head_dim
    kv_dim = num_kv * head_dim

    raw: list[tuple[str, int, int]] = [
        ("q_proj",    q_dim, H),
        ("k_proj",    kv_dim, H),
        ("v_proj",    kv_dim, H),
        ("o_proj",    H,     q_dim),
        ("gate_proj", I,     H),
        ("up_proj",   I,     H),
        ("down_proj", H,     I),
    ]

    merged: dict[tuple[int, int], str] = {}
    for label, N, K in raw:
        key = (N, K)
        merged[key] = f"{merged[key]}+{label}" if key in merged else label
    return [(lbl, N, K) for (N, K), lbl in merged.items()]


def model_attention_gemms(config: dict,
                          seq_lens: list[int]) -> list[dict]:
    """Return per-head attention GEMM cases for each seq_len.

    HW supports two fpint attention matmuls. Shapes follow per-head MHA and
    QBLK is pinned to head_dim because the quantization block spans a full
    head. WTRANS/QDIR are fixed by the HW contract.
      - QK^T (per head):  M=S, N=S, K=head_dim, QBLK=head_dim, -t 1 -d 0
      - PV   (per head):  M=S, N=head_dim, K=S, QBLK=head_dim, -t 0 -d 1
    """
    D = config["head_dim"]
    out: list[dict] = []
    for S in seq_lens:
        out.append({"label": "qkT", "seq_len": S,
                    "M": S, "N": S, "K": D,
                    "QBLK": D, "WTRANS": 1, "QDIR": 0})
        out.append({"label": "pv",  "seq_len": S,
                    "M": S, "N": D, "K": S,
                    "QBLK": D, "WTRANS": 0, "QDIR": 1})
    return out


# ---------------------------------------------------------------------------
# Top-level case builders.
# ---------------------------------------------------------------------------
def build_model_kernels(model_name: str,
                        seq_lens: list[int],
                        qblks: list[int] | None = None) -> list[dict]:
    """Return rich kernel-config dicts for one model + seq_lens sweep.

    Each entry has: name, label, kind, seq_len, M, N, K, QBLK, WTRANS, QDIR,
    and the formatted CLI `args` string.
    """
    if model_name not in MODELS:
        raise ValueError(
            f"unknown model: {model_name!r}. Available: "
            f"{sorted(MODELS.keys())}"
        )
    config = MODELS[model_name]
    qblks = list(qblks) if qblks is not None else list(DEFAULT_QBLKS)

    kernels: list[dict] = []

    # FFN + QKVO projections: WTRANS=0, QDIR=0 are fixed by the HW contract;
    # only QBLK is swept.
    for S in seq_lens:
        for label, N, K in model_linear_gemms(config):
            for qblk in qblks:
                kernels.append({
                    "name": f"{label}_s{S}_q{qblk}",
                    "label": label,
                    "kind": "linear",
                    "seq_len": S,
                    "M": S, "N": N, "K": K,
                    "QBLK": qblk, "WTRANS": 0, "QDIR": 0,
                    "args": f"-m {S} -n {N} -k {K} -q {qblk} -t 0 -d 0",
                })

    # Attention QK^T and PV: fixed QBLK/WTRANS/QDIR per HW contract.
    for atn in model_attention_gemms(config, seq_lens):
        S = atn["seq_len"]
        kernels.append({
            "name": f"{atn['label']}_s{S}",
            "label": atn["label"],
            "kind": "attention",
            "seq_len": S,
            "M": atn["M"], "N": atn["N"], "K": atn["K"],
            "QBLK": atn["QBLK"],
            "WTRANS": atn["WTRANS"],
            "QDIR": atn["QDIR"],
            "args": (f"-m {atn['M']} -n {atn['N']} -k {atn['K']} "
                     f"-q {atn['QBLK']} -t {atn['WTRANS']} -d {atn['QDIR']}"),
        })

    return kernels


def build_model_args(model_name: str,
                     seq_lens: list[int],
                     qblks: list[int] | None = None) -> list[str]:
    """Return only the CLI arg strings (compat shim for test drivers)."""
    return [k["args"] for k in build_model_kernels(model_name, seq_lens, qblks)]


# ---------------------------------------------------------------------------
# CSV / registry helpers.
# ---------------------------------------------------------------------------
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
        print(f"    FFN / QKVO proj GEMM (sweep QBLK={DEFAULT_QBLKS}, "
              f"WTRANS=0, QDIR=0):")
        for lbl, N, K in model_linear_gemms(c):
            print(f"      [{lbl}] N={N}, K={K}")
        print(f"    Attention GEMM (QBLK=head_dim={D}, per-head):")
        print(f"      [qkT]   M=S, N=S,   K={D}, -t 1 -d 0")
        print(f"      [pv]    M=S, N={D}, K=S,   -t 0 -d 1")


# ---------------------------------------------------------------------------
# CLI.
# ---------------------------------------------------------------------------
def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate fpint GEMM kernel configurations for a model.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--model", default=None, metavar="NAME",
        help=f"Model name (available: "
             f"{', '.join(sorted(MODELS.keys())) or 'none'}). "
             "Required unless --list.",
    )
    parser.add_argument(
        "--seq-lens", default=None, metavar="CSV",
        help="Comma-separated seq lens "
             f"(default: {','.join(map(str, DEFAULT_SEQ_LENS))}).",
    )
    parser.add_argument(
        "--qblks", default=None, metavar="CSV",
        help="Comma-separated QBLK sweep for FFN/QKVO projections "
             f"(default: {','.join(map(str, DEFAULT_QBLKS))}).",
    )
    parser.add_argument(
        "--app", default=DEFAULT_KERNEL_APP,
        help=f"Test/app name to record (default: {DEFAULT_KERNEL_APP}).",
    )
    parser.add_argument(
        "--outfile", "-o", default=None, metavar="PATH",
        help="Output JSON file path. If omitted, prints to stdout.",
    )
    parser.add_argument(
        "--list", action="store_true",
        help="Print the model registry and exit.",
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
        seq_lens = parse_seq_lens_csv(args.seq_lens)
        qblks = parse_int_csv(args.qblks, DEFAULT_QBLKS, "qblks")
        kernels = build_model_kernels(args.model, seq_lens, qblks)
    except ValueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    out = {
        "model": args.model,
        "seq_lens": seq_lens,
        "qblks": qblks,
        "app": args.app,
        "kernels": kernels,
    }

    text = json.dumps(out, indent=2) + "\n"
    if args.outfile:
        path = Path(args.outfile)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {len(kernels)} kernel cfgs -> {path}")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
