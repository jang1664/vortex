#!/usr/bin/env python3
"""
LLaMA2 decode-phase attention — perf sweep over past KV-cache length.

Decode step: a single new token is generated.
  - hidden_state [B, 1, H] is projected to q, k, v for the new token
  - k_new, v_new are online int4-quantized (per-step quant cost)
  - past KV cache of length S is GIVEN in 4-bit form (cache build time NOT measured)
  - attention is computed over S past tokens + 1 new token = (S+1) total context

Two variants share IDENTICAL inputs/outputs:
  inputs  : hidden_state fp16 [B, 1, H]
            past K cache (int4 packed + scales + zeros, layout for QK^T)
            past V cache (int4 packed + scales + zeros, layout for PV)
  output  : attention output fp16 [B, Nh, 1, Dh]

  fpint : Q*K_cache via mm_w4a16  (no dequant; native fp16 x int4 MPGEMM)
          P*V_cache via mm_w4a16
          + small fp16 tail for the just-appended new token
  fpfp  : dequantize K_cache to fp16, concat with k_new, then plain torch.matmul
          dequantize V_cache to fp16, concat with v_new, then plain torch.matmul
          (cache stays int4 in storage; compute path is fp16-only)

Sweep default: past_seq_len in {64, 128, 256, 512, 1024, 2048}.

Outputs (next to this script):
  - llama_decode_sweep.csv
  - llama_decode_fpint_trace.json
  - llama_decode_fpfp_trace.json

Usage:
  FPGA_BIN_DIR=... python test/test_llama_decode_sweep.py \
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
    _fit_group_size,
)


# ============================================================================
#  Helpers — int4-cache <-> fp16 round-trip and per-head decode BMMs
# ============================================================================

def quant_new_token_math(x_bnsd: torch.Tensor):
    """
    Simulate the per-step int4-quantization cost for ONE new token (N=1).

    Mirrors the math (amax -> scale -> round -> clamp) of online_quantize_kv_int4
    but SKIPS the bit-packing step, which is undefined for N=1 (you can't pack
    a single int4 into a uint8 without partner). The returned int8 / scale are
    discarded by the caller — we only need the timing.

    x_bnsd: fp16 [B, Nh, 1, Dh]
    """
    x = x_bnsd.contiguous()
    amax  = x.abs().amax(dim=-1).clamp(min=1e-4)                     # [B, Nh, 1]
    scale = (amax / 7.0).to(torch.float16)
    q     = torch.clamp(torch.round(x / scale.unsqueeze(-1)), -8, 7).to(torch.int8)
    return q, scale


def dequantize_kv_cache(packed: torch.Tensor,
                        scales: torch.Tensor,
                        zeros:  torch.Tensor) -> torch.Tensor:
    """
    Inverse of online_quantize_kv_int4.

      packed: uint8 [..., K_dim, N_dim/2]
      scales: fp16  [..., K_dim/G, N_dim]
      zeros:  int16 [..., K_dim/G, N_dim]
    Returns: fp16  [..., K_dim, N_dim]
    """
    p = packed.to(torch.int16)
    hi = p // 16
    lo = p - hi * 16
    lo_s = torch.where(lo < 8, lo, lo - 16)
    hi_s = torch.where(hi < 8, hi, hi - 16)
    interleaved = torch.stack([lo_s, hi_s], dim=-1)
    *batch_shape, K_dim, half_N = packed.shape
    interleaved = interleaved.reshape(*batch_shape, K_dim, half_N * 2)

    num_groups, N_dim = scales.shape[-2], scales.shape[-1]
    group_size = K_dim // num_groups
    iv = interleaved.view(*batch_shape, num_groups, group_size, N_dim).to(torch.float16)
    z  = zeros.unsqueeze(-2).to(torch.float16)   # [..., G, 1, N]
    s  = scales.unsqueeze(-2)                    # [..., G, 1, N]
    out = (iv - z) * s
    return out.view(*batch_shape, K_dim, N_dim)


def bmm_qk_w4a16_decode(q, k_packed, k_scales, k_zeros, group_size):
    """
    Q (single token per head) * K^T_cache via mm_w4a16, looping over (B, head).

      q:        [B, Nh, 1, Dh] fp16
      k_packed: [B, Nh, Dh, S_past/2] uint8
      k_scales: [B, Nh, Dh/G, S_past]
      k_zeros:  [B, Nh, Dh/G, S_past]
    Returns:    [B, Nh, 1, S_past] fp16
    """
    B, Nh, M, _Dh = q.shape  # M = 1
    S_past = k_packed.shape[-1] * 2
    out = torch.empty(B, Nh, M, S_past, dtype=torch.float16, device=q.device)
    for b in range(B):
        for h in range(Nh):
            q_h  = q[b, h].contiguous()         # [1, Dh]
            kp_h = k_packed[b, h].contiguous()  # [Dh, S_past/2]
            ks_h = k_scales[b, h].contiguous()
            kz_h = k_zeros[b, h].contiguous()
            out[b, h] = torch.ops.vortex.mm_w4a16(
                q_h, kp_h, ks_h, kz_h, group_size, S_past, 0, 0,
            )
    return out


def bmm_pv_w4a16_decode(p, v_packed, v_scales, v_zeros, group_size):
    """
    P_cache * V_cache via mm_w4a16, looping over (B, head).

      p:        [B, Nh, 1, S_past] fp16
      v_packed: [B, Nh, S_past, Dh/2] uint8
      v_scales: [B, Nh, S_past/G, Dh]
      v_zeros:  [B, Nh, S_past/G, Dh]
    Returns:    [B, Nh, 1, Dh] fp16
    """
    B, Nh, M, _S = p.shape  # M = 1
    Dh = v_packed.shape[-1] * 2
    out = torch.empty(B, Nh, M, Dh, dtype=torch.float16, device=p.device)
    for b in range(B):
        for h in range(Nh):
            p_h  = p[b, h].contiguous()
            vp_h = v_packed[b, h].contiguous()
            vs_h = v_scales[b, h].contiguous()
            vz_h = v_zeros[b, h].contiguous()
            out[b, h] = torch.ops.vortex.mm_w4a16(
                p_h, vp_h, vs_h, vz_h, group_size, Dh, 0, 0,
            )
    return out


# ============================================================================
#  Decode-phase attention modules
# ============================================================================

class FPIntDecodeAttention(nn.Module):
    """fp16 q/k/v projection + online int4 quant of new k/v + mm_w4a16 over int4 cache.

    Past cache stays in int4 throughout — Q*K_cache and P*V_cache are computed
    natively via the fp16 x int4 MPGEMM kernel. The just-generated new token
    contributes a small fp16 tail (1-token mm) to keep the math simple at the
    int4 packing boundary.
    """

    def __init__(self, config, kv_group_size=128):
        super().__init__()
        self.head_dim  = config.head_dim
        self.num_heads = config.num_attention_heads
        self.scaling   = self.head_dim ** -0.5
        self.kv_group_size_arg = kv_group_size
        H, Nh, Dh = config.hidden_size, self.num_heads, self.head_dim
        self.q_proj = nn.Linear(H, Nh * Dh, bias=False)
        self.k_proj = nn.Linear(H, Nh * Dh, bias=False)
        self.v_proj = nn.Linear(H, Nh * Dh, bias=False)

    def forward(self, hidden_state, k_cache_pack, v_cache_pack):
        B = hidden_state.shape[0]
        Nh, Dh = self.num_heads, self.head_dim

        # ---- 1. project new q, k, v from hidden_state ----
        with record_function("FPINT_DEC::qkv_proj"):
            q     = self.q_proj(hidden_state).view(B, 1, Nh, Dh).transpose(1, 2)  # [B,Nh,1,Dh]
            k_new = self.k_proj(hidden_state).view(B, 1, Nh, Dh).transpose(1, 2)
            v_new = self.v_proj(hidden_state).view(B, 1, Nh, Dh).transpose(1, 2)
            if q.dtype != torch.float16:
                q     = q.to(torch.float16)
                k_new = k_new.to(torch.float16)
                v_new = v_new.to(torch.float16)

        # ---- 2. online int4 quantize new k, v (per-step quant cost) ----
        # The new token has N=1, which can't be int4-packed (packing pairs two
        # values per byte). We run only the math (amax/scale/round/clamp) since
        # the result would just be appended to the cache; packing semantics are
        # a cache-update detail that we don't need to model for the BMM perf.
        gs_k = _fit_group_size(self.head_dim, self.kv_group_size_arg)  # =128 for Dh=128
        S_past = k_cache_pack[0].shape[-1] * 2
        gs_v = _fit_group_size(S_past, self.kv_group_size_arg)
        with record_function("FPINT_DEC::quant_k_new"):
            _ = quant_new_token_math(k_new)
        with record_function("FPINT_DEC::quant_v_new"):
            _ = quant_new_token_math(v_new)

        # ---- 3. Q * K^T  =  [Q*K_cache | Q*k_new]  ----
        kp, ks, kz = k_cache_pack
        with record_function(f"FPINT_DEC::qk_w4a16(S_past={S_past})"):
            attn_cache = bmm_qk_w4a16_decode(q, kp, ks, kz, gs_k)         # [B,Nh,1,S_past]
        with record_function("FPINT_DEC::qk_new_fp16"):
            attn_new = torch.matmul(q, k_new.transpose(2, 3))             # [B,Nh,1,1]
        attn = torch.cat([attn_cache, attn_new], dim=-1) * self.scaling   # [B,Nh,1,S_past+1]

        # ---- 4. softmax (no mask in pure decode — causal is implicit) ----
        with record_function("FPINT_DEC::softmax"):
            attn = F.softmax(attn, dim=-1, dtype=torch.float32).to(q.dtype)

        # ---- 5. P * V  =  P_cache*V_cache  +  P_new*V_new ----
        p_cache = attn[..., :S_past]                                       # [B,Nh,1,S_past]
        p_new   = attn[..., S_past:]                                       # [B,Nh,1,1]
        vp, vs, vz = v_cache_pack
        with record_function(f"FPINT_DEC::pv_w4a16(S_past={S_past})"):
            out_cache = bmm_pv_w4a16_decode(p_cache, vp, vs, vz, gs_v)     # [B,Nh,1,Dh]
        with record_function("FPINT_DEC::pv_new_fp16"):
            out_new = torch.matmul(p_new, v_new)                            # [B,Nh,1,Dh]
        return out_cache + out_new                                          # [B,Nh,1,Dh]


class FPFPDecodeAttention(nn.Module):
    """fp16 projection + on-the-fly cache dequantize + plain fp16 attention.

    Cache is stored as int4 (memory savings) but every decode step dequantizes
    K and V back to fp16, concatenates with the new token, and runs torch.matmul
    (-> sgemm_tcu). Models a 'no fp-int MPGEMM' GPU baseline.
    """

    def __init__(self, config):
        super().__init__()
        self.head_dim  = config.head_dim
        self.num_heads = config.num_attention_heads
        self.scaling   = self.head_dim ** -0.5
        H, Nh, Dh = config.hidden_size, self.num_heads, self.head_dim
        self.q_proj = nn.Linear(H, Nh * Dh, bias=False)
        self.k_proj = nn.Linear(H, Nh * Dh, bias=False)
        self.v_proj = nn.Linear(H, Nh * Dh, bias=False)

    def forward(self, hidden_state, k_cache_pack, v_cache_pack):
        B = hidden_state.shape[0]
        Nh, Dh = self.num_heads, self.head_dim
        kp, ks, kz = k_cache_pack
        vp, vs, vz = v_cache_pack
        S_past = kp.shape[-1] * 2

        # ---- 1. project new q, k, v ----
        with record_function("FPFP_DEC::qkv_proj"):
            q     = self.q_proj(hidden_state).view(B, 1, Nh, Dh).transpose(1, 2)
            k_new = self.k_proj(hidden_state).view(B, 1, Nh, Dh).transpose(1, 2)
            v_new = self.v_proj(hidden_state).view(B, 1, Nh, Dh).transpose(1, 2)
            if q.dtype != torch.float16:
                q     = q.to(torch.float16)
                k_new = k_new.to(torch.float16)
                v_new = v_new.to(torch.float16)

        # ---- 2. dequantize K cache to fp16 [B, Nh, Dh, S_past] ----
        with record_function(f"FPFP_DEC::dequant_k(S_past={S_past})"):
            k_cache_fp16 = dequantize_kv_cache(kp, ks, kz)   # [B,Nh,Dh,S_past]

        # ---- 3. concat new k along S axis, then Q * K^T  ----
        k_new_T = k_new.transpose(2, 3)                       # [B,Nh,Dh,1]
        k_full  = torch.cat([k_cache_fp16, k_new_T], dim=-1)  # [B,Nh,Dh,S_past+1]
        with record_function(f"FPFP_DEC::qk_fp16(S={S_past+1})"):
            attn = torch.matmul(q, k_full) * self.scaling     # [B,Nh,1,S_past+1]

        # ---- 4. softmax ----
        with record_function("FPFP_DEC::softmax"):
            attn = F.softmax(attn, dim=-1, dtype=torch.float32).to(q.dtype)

        # ---- 5. dequantize V cache to fp16 [B, Nh, S_past, Dh] ----
        with record_function(f"FPFP_DEC::dequant_v(S_past={S_past})"):
            v_cache_fp16 = dequantize_kv_cache(vp, vs, vz)    # [B,Nh,S_past,Dh]

        # ---- 6. concat new v along S axis, then P * V ----
        v_full = torch.cat([v_cache_fp16, v_new], dim=2)      # [B,Nh,S_past+1,Dh]
        with record_function(f"FPFP_DEC::pv_fp16(S={S_past+1})"):
            out = torch.matmul(attn, v_full)                  # [B,Nh,1,Dh]
        return out


# ============================================================================
#  Input setup — pre-quantized past KV cache + random hidden state for new token
# ============================================================================

def make_decode_inputs(config, batch, S_past, kv_group_size):
    """
    Build:
      hidden_state: [B, 1, H] fp16   — input for projecting q/k/v of the new token
      k_cache_pack: int4 representation of S_past past keys
      v_cache_pack: int4 representation of S_past past values

    The cache is built on device by quantizing random fp16 tensors. Both the
    fp16 build and the quantize step happen OUTSIDE the timed region — they
    only set up state, simulating "the past cache was already 4-bit".
    """
    H = config.hidden_size
    Nh = config.num_attention_heads
    Dh = config.head_dim

    assert S_past % 2 == 0, f"S_past={S_past} must be even (int4 packing along N)"

    hidden = torch.randn(batch, 1, H, dtype=torch.float16, device=DEVICE)

    k_fp16_cache = torch.randn(batch, Nh, S_past, Dh, dtype=torch.float16, device=DEVICE)
    v_fp16_cache = torch.randn(batch, Nh, S_past, Dh, dtype=torch.float16, device=DEVICE)

    gs_k = _fit_group_size(Dh,     kv_group_size)
    gs_v = _fit_group_size(S_past, kv_group_size)

    k_cache_pack = online_quantize_kv_int4(k_fp16_cache, gs_k, transpose_kn=True)
    v_cache_pack = online_quantize_kv_int4(v_fp16_cache, gs_v, transpose_kn=False)

    # Free the fp16 originals — the cache is "given" in int4 form
    del k_fp16_cache, v_fp16_cache
    return hidden, k_cache_pack, v_cache_pack


# ============================================================================
#  Sweep
# ============================================================================

def time_forward(model, hidden, k_pack, v_pack, iters):
    latencies = []
    for i in range(iters):
        sync()
        t0 = time.perf_counter()
        with record_function(f"iter_{i}"):
            _ = model(hidden, k_pack, v_pack)
        sync()
        latencies.append((time.perf_counter() - t0) * 1000.0)
    return latencies


def sweep_variant(variant_name, build_model, seq_lens, args, config,
                  trace_path, csv_rows):
    Nh = config.num_attention_heads
    Dh = config.head_dim
    H  = config.hidden_size

    print("=" * 70)
    print(f"  Variant: {variant_name}")
    print("=" * 70)

    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for s in seq_lens:
            print(f"\n  -- past_seq_len = {s}  (total ctx = {s+1})")
            try:
                model = build_model().half().to(DEVICE)
                hidden, k_pack, v_pack = make_decode_inputs(
                    config, args.batch, s, args.kv_group_size
                )

                for _ in range(args.warmup):
                    _ = model(hidden, k_pack, v_pack)
                    sync()

                with record_function(f"{variant_name}::S{s}"):
                    lats = time_forward(model, hidden, k_pack, v_pack, args.iters)

                lats_sorted = sorted(lats)
                mean_ms = sum(lats_sorted) / len(lats_sorted)
                p50     = lats_sorted[len(lats_sorted) // 2]
                mn, mx  = lats_sorted[0], lats_sorted[-1]

                # Decode FLOPs:
                #   q/k/v_proj : 3 * 2 * B * 1 * H * H
                #   Q*K^T over (s+1) keys : 2 * B * Nh * 1 * (s+1) * Dh
                #   P*V    over (s+1)    : 2 * B * Nh * 1 * (s+1) * Dh
                proj_flops = 3 * 2 * args.batch * 1 * H * H
                bmm_flops  = 2 * 2 * args.batch * Nh * 1 * (s + 1) * Dh
                total = proj_flops + bmm_flops
                throughput = total / (mean_ms / 1000.0) / 1e9

                csv_rows.append({
                    "variant":      variant_name,
                    "model":        args.model,
                    "batch":        args.batch,
                    "past_seq_len": s,
                    "ctx_len":      s + 1,
                    "n_heads":      Nh,
                    "head_dim":     Dh,
                    "iters":        args.iters,
                    "mean_ms":      f"{mean_ms:.4f}",
                    "p50_ms":       f"{p50:.4f}",
                    "min_ms":       f"{mn:.4f}",
                    "max_ms":       f"{mx:.4f}",
                    "proj_flops":   proj_flops,
                    "bmm_flops":    bmm_flops,
                    "total_flops":  total,
                    "throughput_gflops_s": f"{throughput:.2f}",
                })
                print(f"     mean={mean_ms:.2f}ms  p50={p50:.2f}ms  "
                      f"min={mn:.2f}ms  max={mx:.2f}ms  "
                      f"throughput={throughput:.1f} GFLOP/s")

                del model, hidden, k_pack, v_pack
                gc.collect()
            except Exception as e:
                print(f"     FAILED at past_seq_len={s}: {e}")
                import traceback
                traceback.print_exc()
                csv_rows.append({
                    "variant": variant_name, "model": args.model, "batch": args.batch,
                    "past_seq_len": s, "ctx_len": s + 1,
                    "n_heads": Nh, "head_dim": Dh, "iters": args.iters,
                    "mean_ms": "FAIL", "p50_ms": "FAIL", "min_ms": "FAIL", "max_ms": "FAIL",
                    "proj_flops": "", "bmm_flops": "", "total_flops": "",
                    "throughput_gflops_s": "",
                })
                gc.collect()

    prof.export_chrome_trace(trace_path)
    print(f"\n  Perfetto trace -> {trace_path}")


# ============================================================================
#  Main
# ============================================================================

def parse_args():
    p = argparse.ArgumentParser(description="LLaMA2 decode attention sweep (fpint vs fpfp)")
    p.add_argument("--seq-lens", type=str, default="64,128,256,512,1024,2048",
                   help="comma-separated list of PAST seq_lens (cache size). "
                        "Total context = past+1 due to the new token. Must be even.")
    p.add_argument("--batch",    type=int, default=1)
    p.add_argument("--warmup",   type=int, default=2)
    p.add_argument("--iters",    type=int, default=3)
    p.add_argument("--kv-group-size", type=int, default=128,
                   help="online K/V group_size (auto-clamped per BMM K-dim)")
    p.add_argument("--variants", type=str, default="fpint,fpfp",
                   help="comma-separated subset of {fpint, fpfp}")
    p.add_argument("--model",    type=str, default="llama2-7b",
                   help="label only — config dimensions come from LlamaConfig")
    p.add_argument("--tag",      type=str, default="",
                   help="optional suffix for per-variant trace JSON file names")
    return p.parse_args()


def main():
    args = parse_args()
    config = LlamaConfig()
    seq_lens = [int(s) for s in args.seq_lens.split(",") if s.strip()]
    requested = [v.strip() for v in args.variants.split(",") if v.strip()]

    print("=" * 70)
    print("LLaMA2 Decode Attention Sweep — fpint (mm_w4a16) vs fpfp (dequant + sgemm_tcu)")
    print(f"  hidden={config.hidden_size}  n_heads={config.num_attention_heads}  "
          f"head_dim={config.head_dim}")
    print(f"  batch={args.batch}  past_seq_lens={seq_lens}")
    print(f"  warmup={args.warmup}  iters={args.iters}  "
          f"kv_group_size={args.kv_group_size}")
    print(f"  variants={requested}")
    print("=" * 70)

    here = os.path.dirname(os.path.abspath(__file__))
    suffix = f"_{args.tag}" if args.tag else ""
    csv_rows = []

    if "fpint" in requested:
        sweep_variant(
            "fpint",
            lambda: FPIntDecodeAttention(config, args.kv_group_size),
            seq_lens, args, config,
            os.path.join(here, f"llama_decode_fpint{suffix}_trace.json"),
            csv_rows,
        )
    if "fpfp" in requested:
        sweep_variant(
            "fpfp",
            lambda: FPFPDecodeAttention(config),
            seq_lens, args, config,
            os.path.join(here, f"llama_decode_fpfp{suffix}_trace.json"),
            csv_rows,
        )

    csv_path = os.path.join(here, "llama_decode_sweep.csv")
    if csv_rows:
        fieldnames = list(csv_rows[0].keys())
        merged = {}
        if os.path.exists(csv_path):
            try:
                with open(csv_path, newline="") as f:
                    for row in csv.DictReader(f):
                        key = (row.get("variant"), row.get("model"),
                               row.get("batch"), row.get("past_seq_len"))
                        merged[key] = row
                print(f"\n  Merging into existing CSV ({len(merged)} prior rows)")
            except Exception as e:
                print(f"\n  WARN: could not read existing CSV ({e}); overwriting")
                merged = {}
        for row in csv_rows:
            key = (row.get("variant"), row.get("model"),
                   str(row.get("batch")), str(row.get("past_seq_len")))
            merged[key] = {k: str(v) for k, v in row.items()}

        def _sort_key(r):
            try:
                s = int(r.get("past_seq_len", 0))
            except (TypeError, ValueError):
                s = 0
            return (r.get("variant", ""), int(r.get("batch", 1) or 1), s)

        out_rows = sorted(merged.values(), key=_sort_key)
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
