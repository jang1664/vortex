#!/usr/bin/env python3
"""
Test: LLaMA Decoder Layer with W4A16 linears + online INT4 KV for attention BMMs.

- Linear projections: same W4A16 as test_llama_layer_w4a16.py.
- Attention BMMs (Q*K^T and P*V): online int4 quantize K and V, then dispatch
  via torch.ops.vortex.mm_w4a16 — the same fp16 x int4 MPGEMM kernel that the
  linears use. Activation (Q, P=softmax_out) stays fp16.

Quantization scheme is naive symmetric MinMax (zp=0, range [-8,7]) — perf only,
not for accuracy. Each (B, head) pair is quantized independently and the BMM is
implemented as a Python loop of mm_w4a16 calls (one per head per batch).

Layouts used (qdir=0, wtrans=0):
  Q*K^T:  weight = K^T  in [Dh, S]   -> packed [Dh, S/2]   (group along K=Dh)
  P*V :   weight = V    in [S,  Dh]  -> packed [S, Dh/2]   (group along K=S)

Usage:
  FPGA_BIN_DIR=... python test/test_llama_layer_w4a16_kv4.py \
    [--seq-len 32] [--bench-iters 1] [--kv-group-size 32]
"""

import argparse
import os
import sys
import time

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.profiler import profile, ProfilerActivity, record_function

# Reuse infrastructure from sibling W4A16 test (sets VORTEX_HOME, imports torch_vortex,
# defines W4A16Linear / replace_linear_with_w4a16 / LlamaConfig / etc).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_llama_layer_w4a16 import (  # noqa: E402
    DEVICE,
    LlamaConfig,
    LlamaRMSNorm,
    LlamaRotaryEmbedding,
    apply_rotary_pos_emb,
    LlamaMLP,
    W4A16Linear,
    replace_linear_with_w4a16,
    make_position_embeddings,
    sync,
    count_params,
    count_w4a16_params,
)


# ============================================================================
#  Online INT4 KV quantization
# ============================================================================

def _fit_group_size(K_dim: int, requested: int) -> int:
    """Largest power-of-2 <= min(K_dim, requested) that divides K_dim."""
    g = min(requested, K_dim)
    # Floor to power of two
    while g > 1 and (g & (g - 1)) != 0:
        g &= g - 1
    while g > 1 and (K_dim % g) != 0:
        g //= 2
    return max(g, 1)


def online_quantize_kv_int4(x_bnsd: torch.Tensor, group_size: int, transpose_kn: bool):
    """
    Symmetric MinMax int4 quantization for K or V along the GEMM K-axis.

    Args:
      x_bnsd:        [B, Nh, S, Dh] fp16
      group_size:    QBLK along the GEMM K dimension (must divide K_dim)
      transpose_kn:  True for K (used in Q*K^T)  -> result laid out as weight [Dh, S]
                     False for V (used in P*V)   -> result laid out as weight [S,  Dh]

    Returns (qdir=0 layout):
      packed: uint8 [B, Nh, K_dim, N_dim/2]
      scales: fp16  [B, Nh, K_dim/group_size, N_dim]
      zeros:  int16 [B, Nh, K_dim/group_size, N_dim]    (all zeros, symmetric)
    """
    B, Nh, S, Dh = x_bnsd.shape
    if transpose_kn:
        # Weight = K^T, so K_dim_of_gemm = Dh and N_dim_of_gemm = S
        x = x_bnsd.transpose(2, 3).contiguous()  # [B, Nh, Dh, S]
        K_dim, N_dim = Dh, S
    else:
        # Weight = V, so K_dim_of_gemm = S and N_dim_of_gemm = Dh
        x = x_bnsd.contiguous()                  # [B, Nh, S, Dh]
        K_dim, N_dim = S, Dh

    assert K_dim % group_size == 0, f"K_dim={K_dim} not divisible by group_size={group_size}"
    assert N_dim % 2 == 0, f"N_dim={N_dim} must be even for int4 packing"
    num_groups = K_dim // group_size

    # Group-wise reduction along K_dim
    x_g = x.view(B, Nh, num_groups, group_size, N_dim)        # [B, Nh, G, qblk, N]
    amax = x_g.abs().amax(dim=3).clamp(min=1e-4)              # [B, Nh, G, N]
    scale = (amax / 7.0)                                      # fp16

    q = torch.clamp(torch.round(x_g / scale.unsqueeze(3)), -8, 7).to(torch.int8)
    q = q.view(B, Nh, K_dim, N_dim)

    # Pack two int4 per uint8 along last dim (N_dim).
    # Use arithmetic instead of bit-shift for backend portability.
    q_lo = (q[..., 0::2].to(torch.int16) & 0x0F)              # [B, Nh, K, N/2]
    q_hi = (q[..., 1::2].to(torch.int16) & 0x0F)
    packed = (q_hi * 16 + q_lo).to(torch.uint8)               # [B, Nh, K, N/2]

    scales = scale.to(torch.float16)                          # [B, Nh, G, N]
    zeros = torch.zeros_like(scales, dtype=torch.int16)
    return packed, scales, zeros


# ============================================================================
#  W4A16 BMM helpers (per-head loop, qdir=0, wtrans=0)
# ============================================================================

def bmm_qk_w4a16(query_states, k_packed, k_scales, k_zeros, group_size):
    """
    Q * K^T via mm_w4a16, looping over (B, head).

      query_states: [B, Nh, S, Dh] fp16
      k_packed:     [B, Nh, Dh, S/2] uint8     (weight layout: [K=Dh, N=S])
      k_scales:     [B, Nh, Dh/group_size, S]
      k_zeros:      [B, Nh, Dh/group_size, S]
    Returns:        [B, Nh, S, S] fp16
    """
    B, Nh, S, Dh = query_states.shape
    out = torch.empty(B, Nh, S, S, dtype=torch.float16, device=query_states.device)
    for b in range(B):
        for h in range(Nh):
            q  = query_states[b, h].contiguous()
            kp = k_packed[b, h].contiguous()
            ks = k_scales[b, h].contiguous()
            kz = k_zeros[b, h].contiguous()
            # mm_w4a16: input [M=S, K=Dh] @ dequant(weight [K=Dh, N=S]) -> [M=S, N=S]
            out[b, h] = torch.ops.vortex.mm_w4a16(
                q, kp, ks, kz, group_size, S, 0, 0,
            )
    return out


def bmm_pv_w4a16(p, v_packed, v_scales, v_zeros, group_size):
    """
    P * V via mm_w4a16, looping over (B, head).

      p:        [B, Nh, S, S] fp16
      v_packed: [B, Nh, S, Dh/2] uint8         (weight layout: [K=S, N=Dh])
      v_scales: [B, Nh, S/group_size, Dh]
      v_zeros:  [B, Nh, S/group_size, Dh]
    Returns:    [B, Nh, S, Dh] fp16
    """
    B, Nh, S, _ = p.shape
    Dh = v_packed.shape[-1] * 2
    out = torch.empty(B, Nh, S, Dh, dtype=torch.float16, device=p.device)
    for b in range(B):
        for h in range(Nh):
            pi = p[b, h].contiguous()
            vp = v_packed[b, h].contiguous()
            vs = v_scales[b, h].contiguous()
            vz = v_zeros[b, h].contiguous()
            # mm_w4a16: input [M=S, K=S] @ dequant(weight [K=S, N=Dh]) -> [M=S, N=Dh]
            out[b, h] = torch.ops.vortex.mm_w4a16(
                pi, vp, vs, vz, group_size, Dh, 0, 0,
            )
    return out


# ============================================================================
#  KV4Attention: drop-in replacement for LlamaAttention (online int4 K & V)
# ============================================================================

class KV4Attention(nn.Module):
    def __init__(self, config, layer_idx=0, kv_group_size=32):
        super().__init__()
        self.head_dim = config.head_dim
        self.num_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.scaling = self.head_dim ** -0.5
        self.kv_group_size_arg = kv_group_size

        self.q_proj = nn.Linear(config.hidden_size, self.num_heads * self.head_dim, bias=config.attention_bias)
        self.k_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.v_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, config.hidden_size, bias=config.attention_bias)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        bsz, seq_len, _ = hidden_states.shape
        hidden_shape = (bsz, seq_len, -1, self.head_dim)

        with record_function("KV4::attn_qkv_proj"):
            query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            key_states   = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)

        with record_function("KV4::rope"):
            cos, sin = position_embeddings
            query_states, key_states = apply_rotary_pos_emb(query_states, key_states, cos, sin)
            # cos/sin from make_position_embeddings can be fp32 (dummy=torch.empty(1) defaults to fp32),
            # which promotes q/k to fp32. mm_w4a16 strictly requires fp16 input.
            if query_states.dtype != torch.float16:
                query_states = query_states.to(torch.float16)
            if key_states.dtype != torch.float16:
                key_states = key_states.to(torch.float16)

        # Auto-fit group sizes to divide K-axis of each BMM.
        gs_k = _fit_group_size(self.head_dim, self.kv_group_size_arg)  # K-dim = Dh
        gs_v = _fit_group_size(seq_len,       self.kv_group_size_arg)  # K-dim = S

        # ---- online int4 K + Q*K^T via W4A16 mm ----
        with record_function(f"KV4::quant_k_int4(gs={gs_k})"):
            k_packed, k_scales, k_zeros = online_quantize_kv_int4(
                key_states, gs_k, transpose_kn=True
            )
        with record_function(f"KV4::attn_score_w4a16(S={seq_len},Dh={self.head_dim})"):
            attn_weights = bmm_qk_w4a16(
                query_states, k_packed, k_scales, k_zeros, gs_k
            )
        attn_weights = attn_weights * self.scaling
        if attention_mask is not None:
            attn_weights = attn_weights + attention_mask[:, :, :, :seq_len]

        with record_function("KV4::softmax"):
            attn_weights = F.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query_states.dtype)

        # ---- online int4 V + P*V via W4A16 mm ----
        with record_function(f"KV4::quant_v_int4(gs={gs_v})"):
            v_packed, v_scales, v_zeros = online_quantize_kv_int4(
                value_states, gs_v, transpose_kn=False
            )
        with record_function(f"KV4::attn_value_w4a16(S={seq_len},Dh={self.head_dim})"):
            attn_output = bmm_pv_w4a16(
                attn_weights, v_packed, v_scales, v_zeros, gs_v
            )

        with record_function("KV4::attn_reshape"):
            attn_output = attn_output.transpose(1, 2).contiguous()
            attn_output = attn_output.reshape(bsz, seq_len, -1).contiguous()

        with record_function("KV4::attn_o_proj"):
            return self.o_proj(attn_output)


class KV4DecoderLayer(nn.Module):
    def __init__(self, config, layer_idx=0, kv_group_size=32):
        super().__init__()
        self.self_attn = KV4Attention(config, layer_idx, kv_group_size)
        self.mlp = LlamaMLP(config)
        self.input_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        residual = hidden_states
        with record_function("KV4::input_layernorm"):
            hidden_states = self.input_layernorm(hidden_states)
        with record_function("KV4::self_attn"):
            hidden_states = self.self_attn(hidden_states, position_embeddings, attention_mask)
        with record_function("KV4::residual_add_attn"):
            hidden_states = residual + hidden_states

        residual = hidden_states
        with record_function("KV4::post_attn_layernorm"):
            hidden_states = self.post_attention_layernorm(hidden_states)
        with record_function("KV4::mlp"):
            hidden_states = self.mlp(hidden_states)
        with record_function("KV4::residual_add_mlp"):
            hidden_states = residual + hidden_states
        return hidden_states


# ============================================================================
#  Tests
# ============================================================================

def test_kv4_decoder_layer(args):
    """Functional run of a KV4 decoder layer (no NaN/Inf check + shape)."""
    print("=" * 70)
    print(f"Test 1: KV4 Decoder Layer (seq_len={args.seq_len}, kv_group_size={args.kv_group_size})")
    print("=" * 70)

    config = LlamaConfig()
    layer = KV4DecoderLayer(config, layer_idx=0, kv_group_size=args.kv_group_size).half()

    orig_params = count_params(layer)
    replace_linear_with_w4a16(layer, group_size=args.group_size)
    w4_params = count_w4a16_params(layer)
    print(f"  Original params:     {orig_params:,}")
    print(f"  W4A16 weight elems:  {w4_params:,}")
    print(f"  Compression (lin):   ~{orig_params * 16 / max(w4_params * 4, 1):.1f}x (fp16 -> int4)")
    print(f"  KV cache: online int4 quantized per forward (group_size={args.kv_group_size})")

    layer_dev = layer.to(DEVICE)
    cos, sin = make_position_embeddings(config, 1, args.seq_len, DEVICE)
    x = torch.randn(1, args.seq_len, config.hidden_size, dtype=torch.float16)
    x_dev = x.to(DEVICE)

    mask = torch.zeros(1, 1, args.seq_len, args.seq_len, dtype=torch.float16)
    mask.masked_fill_(
        torch.triu(torch.ones(args.seq_len, args.seq_len, dtype=torch.bool), diagonal=1),
        float("-inf"),
    )
    mask_dev = mask.to(DEVICE)

    sync()
    out_dev = layer_dev(x_dev, (cos, sin), attention_mask=mask_dev)
    sync()
    result = out_dev.cpu()

    print(f"  Output shape: {result.shape}, dtype: {result.dtype}")
    print(f"  Output range: [{result.min().item():.4f}, {result.max().item():.4f}]")
    has_nan = result.isnan().any().item()
    has_inf = result.isinf().any().item()
    print(f"  NaN: {has_nan}, Inf: {has_inf}")
    ok = not has_nan and not has_inf
    print(f"  {'PASSED' if ok else 'FAILED'}: KV4 decoder layer forward")
    print()
    return ok


def test_kv4_bench(args):
    """Benchmark KV4 decoder layer end-to-end + export Perfetto trace."""
    print("=" * 70)
    print(f"Test 2: Benchmark KV4 decoder layer "
          f"(seq_len={args.seq_len}, warmup={args.bench_warmup}, iters={args.bench_iters})")
    print("=" * 70)

    config = LlamaConfig()
    layer = KV4DecoderLayer(config, layer_idx=0, kv_group_size=args.kv_group_size).half()
    replace_linear_with_w4a16(layer, group_size=args.group_size)

    layer_dev = layer.to(DEVICE)
    cos, sin = make_position_embeddings(config, 1, args.seq_len, DEVICE)
    x_dev = torch.randn(1, args.seq_len, config.hidden_size, dtype=torch.float16, device=DEVICE)

    mask = torch.zeros(1, 1, args.seq_len, args.seq_len, dtype=torch.float16)
    mask.masked_fill_(
        torch.triu(torch.ones(args.seq_len, args.seq_len, dtype=torch.bool), diagonal=1),
        float("-inf"),
    )
    mask_dev = mask.to(DEVICE)

    print(f"  Warming up ({args.bench_warmup} iters)...")
    for _ in range(args.bench_warmup):
        _ = layer_dev(x_dev, (cos, sin), attention_mask=mask_dev)
        sync()

    trace_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "llama_w4a16_kv4_trace.json",
    )
    latencies = []
    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for i in range(args.bench_iters):
            sync()
            t0 = time.perf_counter()
            with record_function(f"KV4::bench_iter_{i}"):
                _ = layer_dev(x_dev, (cos, sin), attention_mask=mask_dev)
            sync()
            dt_ms = (time.perf_counter() - t0) * 1000.0
            latencies.append(dt_ms)
            print(f"    iter {i+1}: {dt_ms:.2f} ms")

    prof.export_chrome_trace(trace_path)
    print(f"\n  Perfetto trace: {trace_path}")

    latencies.sort()
    mean_ms = sum(latencies) / len(latencies)
    p50_ms = latencies[len(latencies) // 2]
    min_ms = latencies[0]
    max_ms = latencies[-1]

    M = args.seq_len
    H = config.hidden_size
    I = config.intermediate_size
    Nh = config.num_attention_heads
    Dh = config.head_dim
    # Linear FLOPs (q,k,v,o) + (gate,up,down)
    linear_flops = 2 * M * (4 * H * H + 3 * H * I)
    # Attention BMM FLOPs: (Q*K^T) + (P*V) = 2 * 2 * Nh * S^2 * Dh = 4 * S^2 * H
    attn_flops = 4 * M * M * H
    total_flops = linear_flops + attn_flops

    print(f"\n  Results (KV4 decoder layer, seq_len={args.seq_len}):")
    print(f"    mean:  {mean_ms:.2f} ms")
    print(f"    p50:   {p50_ms:.2f} ms")
    print(f"    min:   {min_ms:.2f} ms")
    print(f"    max:   {max_ms:.2f} ms")
    print(f"    Linear FLOPs:    {linear_flops/1e9:.3f} GFLOP")
    print(f"    Attention FLOPs: {attn_flops/1e9:.3f} GFLOP")
    print(f"    Total FLOPs:     {total_flops/1e9:.3f} GFLOP")
    print(f"    Throughput:      {total_flops / (mean_ms / 1000.0) / 1e9:.2f} GFLOP/s (estimate)")
    print(f"  PASSED: benchmark complete")
    print()
    return True


# ============================================================================
#  Main
# ============================================================================

def parse_args():
    p = argparse.ArgumentParser(description="LLaMA decoder layer W4A16 + online INT4 KV test/bench")
    p.add_argument("--seq-len", type=int, default=32)
    p.add_argument("--group-size", type=int, default=32,
                   help="W4A16 linear weight group_size (offline, fixed)")
    p.add_argument("--kv-group-size", type=int, default=128,
                   help="Online K/V group_size (default 128 = per-head/per-token "
                        "for K; auto-clamped to divide each BMM's K-dim)")
    p.add_argument("--bench-warmup", type=int, default=2)
    p.add_argument("--bench-iters", type=int, default=5)
    p.add_argument("--skip-bench", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()

    print("=" * 70)
    print("LLaMA Decoder Layer — W4A16 linears + online INT4 KV (Q*K^T, P*V via mm_w4a16)")
    print(f"  hidden_size={LlamaConfig.hidden_size}, intermediate_size={LlamaConfig.intermediate_size}")
    print(f"  num_heads={LlamaConfig.num_attention_heads}, head_dim={LlamaConfig.head_dim}")
    print(f"  seq_len={args.seq_len}, lin_group_size={args.group_size}, kv_group_size={args.kv_group_size}")
    print("=" * 70)
    print()

    tests = [
        ("kv4_decoder_layer", lambda: test_kv4_decoder_layer(args)),
    ]
    if not args.skip_bench:
        tests.append(("kv4_bench", lambda: test_kv4_bench(args)))

    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            ok = fn()
            if ok:
                passed += 1
            else:
                failed += 1
        except Exception as e:
            print(f"  FAILED: {name}: {e}")
            import traceback
            traceback.print_exc()
            failed += 1
        print()

    print("=" * 70)
    print(f"Results: {passed} passed, {failed} failed out of {len(tests)} tests")
    print("=" * 70)
    sys.exit(0 if failed == 0 else 1)
