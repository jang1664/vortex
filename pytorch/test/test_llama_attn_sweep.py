#!/usr/bin/env python3
"""
LLaMA2 attention CORE — perf sweep over seq_len, comparing two variants.

Measures ONLY the per-head attention compute (Q*K^T + softmax + P*V).
Projections (qkv/o_proj), RoPE, and reshape/transpose around them are
intentionally excluded — both variants take the same shape inputs and produce
the same shape outputs:

    inputs : q, k, v  each fp16 [B, Nh, S, Dh]
    output : attn     fp16 [B, Nh, S, Dh]
    mask   : fp16 [B, 1, S, S]

  fpint : online int4 quantize K and V inside the module, then run Q*K^T and
          P*V via torch.ops.vortex.mm_w4a16  (our fp16 x int4 MPGEMM)
  fp16  : plain torch.matmul (sgemm_tcu) for both BMMs

LlamaConfig defaults to LLaMA2-7B (n_heads=32, head_dim=128). hidden_size is
not used here since projections are excluded.

Outputs (next to this script):
  - llama_attn_sweep.csv             (one row per (variant, seq_len))
  - llama_attn_fpint_trace.json      (Perfetto, all seq_lens iterated inside)
  - llama_attn_fp16_trace.json       (Perfetto, all seq_lens iterated inside)

Usage:
  FPGA_BIN_DIR=... python test/test_llama_attn_sweep.py \
      [--seq-lens 64,128,256,512,1024,2048] [--batch 1] [--iters 3] [--warmup 2]
"""

import argparse
import csv
import gc
import os
import sys
import time

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.profiler import profile, ProfilerActivity, record_function

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_llama_layer_w4a16 import (  # noqa: E402
    DEVICE,
    LlamaConfig,
    sync,
)
from test_llama_layer_w4a16_kv4 import (  # noqa: E402
    online_quantize_kv_int4,
    bmm_qk_w4a16,
    bmm_pv_w4a16,
    _fit_group_size,
)


# ============================================================================
#  Two attention variants
# ============================================================================

class FPIntAttentionCore(nn.Module):
    """Q*K^T + softmax + P*V via mm_w4a16 with online int4 K, V.

    Inputs / outputs are fp16 [B, Nh, S, Dh] — identical signature to FP16AttentionCore.
    """

    def __init__(self, config, kv_group_size=128):
        super().__init__()
        self.head_dim  = config.head_dim
        self.num_heads = config.num_attention_heads
        self.scaling   = self.head_dim ** -0.5
        self.kv_group_size_arg = kv_group_size

    def forward(self, q, k, v, attention_mask=None):
        # q, k, v: [B, Nh, S, Dh] fp16
        _, _, seq_len, _ = q.shape

        gs_k = _fit_group_size(self.head_dim, self.kv_group_size_arg)
        gs_v = _fit_group_size(seq_len,        self.kv_group_size_arg)

        with record_function(f"FPINT::quant_k(gs={gs_k})"):
            kp, ks, kz = online_quantize_kv_int4(k, gs_k, transpose_kn=True)
        with record_function(f"FPINT::qk_w4a16(S={seq_len})"):
            attn = bmm_qk_w4a16(q, kp, ks, kz, gs_k)

        attn = attn * self.scaling
        if attention_mask is not None:
            attn = attn + attention_mask[:, :, :, :seq_len]
        with record_function("FPINT::softmax"):
            attn = F.softmax(attn, dim=-1, dtype=torch.float32).to(q.dtype)

        with record_function(f"FPINT::quant_v(gs={gs_v})"):
            vp, vs, vz = online_quantize_kv_int4(v, gs_v, transpose_kn=False)
        with record_function(f"FPINT::pv_w4a16(S={seq_len})"):
            out = bmm_pv_w4a16(attn, vp, vs, vz, gs_v)
        return out  # [B, Nh, S, Dh] fp16


class FP16AttentionCore(nn.Module):
    """Q*K^T + softmax + P*V via plain torch.matmul (fp16 throughout).

    Inputs / outputs match FPIntAttentionCore exactly.
    """

    def __init__(self, config):
        super().__init__()
        self.head_dim  = config.head_dim
        self.num_heads = config.num_attention_heads
        self.scaling   = self.head_dim ** -0.5

    def forward(self, q, k, v, attention_mask=None):
        _, _, seq_len, _ = q.shape

        with record_function(f"FP16::qk(S={seq_len})"):
            attn = torch.matmul(q, k.transpose(2, 3)) * self.scaling
        if attention_mask is not None:
            attn = attn + attention_mask[:, :, :, :seq_len]
        with record_function("FP16::softmax"):
            attn = F.softmax(attn, dim=-1, dtype=torch.float32).to(q.dtype)
        with record_function(f"FP16::pv(S={seq_len})"):
            out = torch.matmul(attn, v)
        return out  # [B, Nh, S, Dh] fp16


# ============================================================================
#  Sweep
# ============================================================================

def time_forward(model, q, k, v, mask, iters):
    latencies = []
    for i in range(iters):
        sync()
        t0 = time.perf_counter()
        with record_function(f"iter_{i}"):
            _ = model(q, k, v, attention_mask=mask)
        sync()
        latencies.append((time.perf_counter() - t0) * 1000.0)
    return latencies


def make_inputs(config, batch, seq_len):
    """Random Q, K, V tensors fed directly into the attention core."""
    Nh = config.num_attention_heads
    Dh = config.head_dim
    q = torch.randn(batch, Nh, seq_len, Dh, dtype=torch.float16, device=DEVICE)
    k = torch.randn(batch, Nh, seq_len, Dh, dtype=torch.float16, device=DEVICE)
    v = torch.randn(batch, Nh, seq_len, Dh, dtype=torch.float16, device=DEVICE)
    mask = torch.zeros(batch, 1, seq_len, seq_len, dtype=torch.float16)
    mask.masked_fill_(
        torch.triu(torch.ones(seq_len, seq_len, dtype=torch.bool), diagonal=1),
        float("-inf"),
    )
    return q, k, v, mask.to(DEVICE)


def sweep_variant(variant_name: str,
                  build_model,
                  seq_lens, args, config,
                  trace_path: str,
                  csv_rows: list):
    Nh = config.num_attention_heads
    Dh = config.head_dim

    print("=" * 70)
    print(f"  Variant: {variant_name}")
    print("=" * 70)

    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for s in seq_lens:
            print(f"\n  -- seq_len = {s}")
            try:
                model = build_model().half().to(DEVICE)
                q, k, v, mask = make_inputs(config, args.batch, s)

                # warmup
                for _ in range(args.warmup):
                    _ = model(q, k, v, attention_mask=mask)
                    sync()

                with record_function(f"{variant_name}::S{s}"):
                    lats = time_forward(model, q, k, v, mask, args.iters)

                lats_sorted = sorted(lats)
                mean_ms = sum(lats_sorted) / len(lats_sorted)
                p50     = lats_sorted[len(lats_sorted) // 2]
                mn, mx  = lats_sorted[0], lats_sorted[-1]

                # Attention BMM FLOPs only (Q*K^T + P*V):
                #   2 * 2 * B * Nh * S^2 * Dh
                bmm_flops = 4 * args.batch * Nh * s * s * Dh
                throughput = bmm_flops / (mean_ms / 1000.0) / 1e9  # GFLOP/s

                csv_rows.append({
                    "variant":       variant_name,
                    "model":         args.model,
                    "batch":         args.batch,
                    "seq_len":       s,
                    "n_heads":       Nh,
                    "head_dim":      Dh,
                    "iters":         args.iters,
                    "mean_ms":       f"{mean_ms:.4f}",
                    "p50_ms":        f"{p50:.4f}",
                    "min_ms":        f"{mn:.4f}",
                    "max_ms":        f"{mx:.4f}",
                    "bmm_flops":     bmm_flops,
                    "throughput_gflops_s": f"{throughput:.2f}",
                })
                print(f"     mean={mean_ms:.2f}ms  p50={p50:.2f}ms  "
                      f"min={mn:.2f}ms  max={mx:.2f}ms  "
                      f"throughput={throughput:.1f} GFLOP/s")

                del model, q, k, v, mask
                gc.collect()
            except Exception as e:
                print(f"     FAILED at seq_len={s}: {e}")
                import traceback
                traceback.print_exc()
                csv_rows.append({
                    "variant": variant_name, "model": args.model, "batch": args.batch,
                    "seq_len": s, "n_heads": Nh, "head_dim": Dh,
                    "iters": args.iters,
                    "mean_ms": "FAIL", "p50_ms": "FAIL", "min_ms": "FAIL", "max_ms": "FAIL",
                    "bmm_flops": "",
                    "throughput_gflops_s": "",
                })
                gc.collect()

    prof.export_chrome_trace(trace_path)
    print(f"\n  Perfetto trace -> {trace_path}")


# ============================================================================
#  Main
# ============================================================================

def parse_args():
    p = argparse.ArgumentParser(description="LLaMA2 attention sweep (fpint vs fp16)")
    p.add_argument("--seq-lens", type=str, default="64,128,256,512,1024,2048",
                   help="comma-separated list of seq_lens to sweep")
    p.add_argument("--batch",    type=int, default=1)
    p.add_argument("--warmup",   type=int, default=2)
    p.add_argument("--iters",    type=int, default=3)
    p.add_argument("--kv-group-size", type=int, default=128,
                   help="online K/V group_size (auto-clamped per BMM K-dim)")
    p.add_argument("--variants", type=str, default="fpint,fp16",
                   help="which variants to run (comma-separated subset of {fpint,fp16})")
    p.add_argument("--model",    type=str, default="llama2-7b",
                   help="label only — config dimensions are taken from LlamaConfig")
    p.add_argument("--tag",      type=str, default="",
                   help="optional suffix appended to per-variant trace JSON file names "
                        "(e.g. --tag s4096 -> llama_attn_fpint_s4096_trace.json). "
                        "Empty (default) overwrites the base trace file.")
    return p.parse_args()


def main():
    args = parse_args()
    config = LlamaConfig()
    seq_lens = [int(s) for s in args.seq_lens.split(",") if s.strip()]
    requested_variants = [v.strip() for v in args.variants.split(",") if v.strip()]

    print("=" * 70)
    print("LLaMA2 Attention CORE Sweep — fpint (mm_w4a16 KV) vs fp16 (sgemm_tcu)")
    print(f"  n_heads={config.num_attention_heads}  head_dim={config.head_dim}  "
          f"(no projections, no rope)")
    print(f"  batch={args.batch}  seq_lens={seq_lens}")
    print(f"  warmup={args.warmup}  iters={args.iters}  "
          f"kv_group_size={args.kv_group_size}")
    print(f"  variants={requested_variants}")
    print("=" * 70)

    here = os.path.dirname(os.path.abspath(__file__))
    csv_rows = []

    suffix = f"_{args.tag}" if args.tag else ""

    if "fpint" in requested_variants:
        sweep_variant(
            "fpint",
            lambda: FPIntAttentionCore(config, args.kv_group_size),
            seq_lens, args, config,
            os.path.join(here, f"llama_attn_fpint{suffix}_trace.json"),
            csv_rows,
        )
    if "fp16" in requested_variants:
        sweep_variant(
            "fp16",
            lambda: FP16AttentionCore(config),
            seq_lens, args, config,
            os.path.join(here, f"llama_attn_fp16{suffix}_trace.json"),
            csv_rows,
        )

    csv_path = os.path.join(here, "llama_attn_sweep.csv")
    if csv_rows:
        fieldnames = list(csv_rows[0].keys())
        # Merge with existing rows: key = (variant, model, batch, seq_len).
        # New rows overwrite old rows with the same key; rows for other
        # seq_lens / variants are preserved.
        merged = {}
        if os.path.exists(csv_path):
            try:
                with open(csv_path, newline="") as f:
                    for row in csv.DictReader(f):
                        key = (row.get("variant"), row.get("model"),
                               row.get("batch"), row.get("seq_len"))
                        merged[key] = row
                print(f"\n  Merging into existing CSV ({len(merged)} prior rows)")
            except Exception as e:
                print(f"\n  WARN: could not read existing CSV ({e}); overwriting")
                merged = {}
        for row in csv_rows:
            key = (row.get("variant"), row.get("model"),
                   str(row.get("batch")), str(row.get("seq_len")))
            merged[key] = {k: str(v) for k, v in row.items()}

        # Stable order: variant alpha, then numeric seq_len ascending.
        def _sort_key(r):
            try:
                s = int(r.get("seq_len", 0))
            except (TypeError, ValueError):
                s = 0
            return (r.get("variant", ""), int(r.get("batch", 1) or 1), s)

        out_rows = sorted(merged.values(), key=_sort_key)
        # extrasaction='ignore' silently drops legacy columns from older CSVs
        # (e.g. 'hidden', 'proj_flops', 'total_flops' if the schema changed);
        # restval='' fills any new column that older rows lacked.
        with open(csv_path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=fieldnames,
                               extrasaction="ignore", restval="")
            w.writeheader()
            w.writerows(out_rows)
        print(f"  CSV summary -> {csv_path}  ({len(out_rows)} rows total)")
    else:
        print("\nNo rows produced.")

    print("\nDone.")


if __name__ == "__main__":
    main()
