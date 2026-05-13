#!/usr/bin/env python3
"""
Test: LLaMA Decoder Layer with W4A16 linears + online INT4 KV  —  OPT variant
that dispatches via torch.ops.vortex.mm_w4a16_opt (uses tile-laid-out DRAM
layout matching tests/regression/fpint_gemm_ffn_hw).

Structurally identical to test_llama_layer_w4a16_kv4.py; the only change is
that every W4A16 GEMM call (3 places: linear projections, Q*K^T, P*V) uses
mm_w4a16_opt instead of mm_w4a16. The wrapper handles all tile/detile
internally — Python code is unchanged from the kv4 reference.

Trace label prefix: KV4_OPT::      output: llama_w4a16_kv4_opt_trace.json

Usage:
  FPGA_BIN_DIR=... python test/test_llama_layer_w4a16_kv4_opt.py \
    [--seq-len 32] [--bench-iters 1] [--kv-group-size 128]
"""

import argparse
import os
import sys
import time

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.profiler import profile, ProfilerActivity, record_function

# Reuse infrastructure from siblings — no model code is forked, only the GEMM op.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_llama_layer_w4a16 import (  # noqa: E402
    DEVICE,
    LlamaConfig,
    LlamaRMSNorm,
    LlamaRotaryEmbedding,
    apply_rotary_pos_emb,
    quantize_weight_to_int4,
    make_position_embeddings,
    sync,
    count_params,
)
from test_llama_layer_w4a16_kv4 import (  # noqa: E402
    online_quantize_kv_int4,
    _fit_group_size,
)


# ============================================================================
#  W4A16 Linear — OPT variant (uses mm_w4a16_opt)
# ============================================================================

class W4A16Linear_opt(nn.Module):
    """nn.Linear replacement that runs via torch.ops.vortex.mm_w4a16_opt."""

    def __init__(self, in_features, out_features, weight_fp16, group_size=32):
        super().__init__()
        self.in_features  = in_features
        self.out_features = out_features
        self.group_size   = group_size
        w_packed, scales, zeros = quantize_weight_to_int4(weight_fp16, group_size)
        self.register_buffer("w_int4", w_packed)
        self.register_buffer("scales", scales)
        self.register_buffer("zeros",  zeros)

    def forward(self, x):
        orig_shape = x.shape
        x_2d = x.reshape(-1, self.in_features)
        if not x_2d.is_contiguous():
            x_2d = x_2d.contiguous()
        if x_2d.dtype != torch.float16:
            x_2d = x_2d.half()
        with record_function(f"KV4_OPT::mm_w4a16_opt({self.in_features}x{self.out_features})"):
            out = torch.ops.vortex.mm_w4a16_opt(
                x_2d, self.w_int4, self.scales, self.zeros,
                self.group_size, self.out_features, 0, 0,
            )
        return out.reshape(*orig_shape[:-1], self.out_features)


def replace_linear_with_w4a16_opt(module, group_size=32):
    for name, child in module.named_children():
        if isinstance(child, nn.Linear):
            w4 = W4A16Linear_opt(
                child.in_features, child.out_features,
                child.weight.data.half(), group_size,
            )
            setattr(module, name, w4)
        else:
            replace_linear_with_w4a16_opt(child, group_size)


def count_w4a16_opt_params(module):
    total = 0
    for m in module.modules():
        if isinstance(m, W4A16Linear_opt):
            total += m.in_features * m.out_features
    return total


# ============================================================================
#  W4A16 BMM helpers — OPT variant (per-head loop of mm_w4a16_opt)
# ============================================================================

def bmm_qk_w4a16_opt(query_states, k_packed, k_scales, k_zeros, group_size):
    """Q * K^T via mm_w4a16_opt, looping over (B, head). See kv4 docs."""
    B, Nh, S, Dh = query_states.shape
    out = torch.empty(B, Nh, S, S, dtype=torch.float16, device=query_states.device)
    for b in range(B):
        for h in range(Nh):
            q  = query_states[b, h].contiguous()
            kp = k_packed[b, h].contiguous()
            ks = k_scales[b, h].contiguous()
            kz = k_zeros[b, h].contiguous()
            out[b, h] = torch.ops.vortex.mm_w4a16_opt(
                q, kp, ks, kz, group_size, S, 0, 0,
            )
    return out


def bmm_pv_w4a16_opt(p, v_packed, v_scales, v_zeros, group_size):
    """P * V via mm_w4a16_opt, looping over (B, head). See kv4 docs."""
    B, Nh, S, _ = p.shape
    Dh = v_packed.shape[-1] * 2
    out = torch.empty(B, Nh, S, Dh, dtype=torch.float16, device=p.device)
    for b in range(B):
        for h in range(Nh):
            pi = p[b, h].contiguous()
            vp = v_packed[b, h].contiguous()
            vs = v_scales[b, h].contiguous()
            vz = v_zeros[b, h].contiguous()
            out[b, h] = torch.ops.vortex.mm_w4a16_opt(
                pi, vp, vs, vz, group_size, Dh, 0, 0,
            )
    return out


# ============================================================================
#  KV4 attention / MLP / decoder layer — OPT variants
# ============================================================================

class LlamaMLP_opt(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.gate_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.up_proj   = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=config.mlp_bias)

    def forward(self, x):
        with record_function("KV4_OPT::mlp_gate_proj"):
            gate = self.gate_proj(x)
        with record_function("KV4_OPT::mlp_silu"):
            gate = F.silu(gate.float()).to(x.dtype)
        with record_function("KV4_OPT::mlp_up_proj"):
            up = self.up_proj(x)
        with record_function("KV4_OPT::mlp_down_proj"):
            out = self.down_proj(gate * up)
        return out


class KV4Attention_opt(nn.Module):
    def __init__(self, config, layer_idx=0, kv_group_size=128):
        super().__init__()
        self.head_dim  = config.head_dim
        self.num_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.scaling   = self.head_dim ** -0.5
        self.kv_group_size_arg = kv_group_size

        self.q_proj = nn.Linear(config.hidden_size, self.num_heads * self.head_dim, bias=config.attention_bias)
        self.k_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.v_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, config.hidden_size, bias=config.attention_bias)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        bsz, seq_len, _ = hidden_states.shape
        hidden_shape = (bsz, seq_len, -1, self.head_dim)

        with record_function("KV4_OPT::attn_qkv_proj"):
            query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            key_states   = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)

        with record_function("KV4_OPT::rope"):
            cos, sin = position_embeddings
            query_states, key_states = apply_rotary_pos_emb(query_states, key_states, cos, sin)
            if query_states.dtype != torch.float16:
                query_states = query_states.to(torch.float16)
            if key_states.dtype != torch.float16:
                key_states = key_states.to(torch.float16)

        gs_k = _fit_group_size(self.head_dim, self.kv_group_size_arg)
        gs_v = _fit_group_size(seq_len,        self.kv_group_size_arg)

        with record_function(f"KV4_OPT::quant_k(gs={gs_k})"):
            k_packed, k_scales, k_zeros = online_quantize_kv_int4(
                key_states, gs_k, transpose_kn=True
            )
        with record_function(f"KV4_OPT::qk_w4a16_opt(S={seq_len})"):
            attn_weights = bmm_qk_w4a16_opt(
                query_states, k_packed, k_scales, k_zeros, gs_k
            )
        attn_weights = attn_weights * self.scaling
        if attention_mask is not None:
            attn_weights = attn_weights + attention_mask[:, :, :, :seq_len]

        with record_function("KV4_OPT::softmax"):
            attn_weights = F.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query_states.dtype)

        with record_function(f"KV4_OPT::quant_v(gs={gs_v})"):
            v_packed, v_scales, v_zeros = online_quantize_kv_int4(
                value_states, gs_v, transpose_kn=False
            )
        with record_function(f"KV4_OPT::pv_w4a16_opt(S={seq_len})"):
            attn_output = bmm_pv_w4a16_opt(
                attn_weights, v_packed, v_scales, v_zeros, gs_v
            )

        with record_function("KV4_OPT::attn_reshape"):
            attn_output = attn_output.transpose(1, 2).contiguous()
            attn_output = attn_output.reshape(bsz, seq_len, -1).contiguous()

        with record_function("KV4_OPT::attn_o_proj"):
            return self.o_proj(attn_output)


class KV4DecoderLayer_opt(nn.Module):
    def __init__(self, config, layer_idx=0, kv_group_size=128):
        super().__init__()
        self.self_attn = KV4Attention_opt(config, layer_idx, kv_group_size)
        self.mlp = LlamaMLP_opt(config)
        self.input_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        residual = hidden_states
        with record_function("KV4_OPT::input_layernorm"):
            hidden_states = self.input_layernorm(hidden_states)
        with record_function("KV4_OPT::self_attn"):
            hidden_states = self.self_attn(hidden_states, position_embeddings, attention_mask)
        with record_function("KV4_OPT::residual_add_attn"):
            hidden_states = residual + hidden_states

        residual = hidden_states
        with record_function("KV4_OPT::post_attn_layernorm"):
            hidden_states = self.post_attention_layernorm(hidden_states)
        with record_function("KV4_OPT::mlp"):
            hidden_states = self.mlp(hidden_states)
        with record_function("KV4_OPT::residual_add_mlp"):
            hidden_states = residual + hidden_states
        return hidden_states


# ============================================================================
#  Tests
# ============================================================================

def test_kv4_opt_decoder_layer(args):
    print("=" * 70)
    print(f"Test 1: KV4_OPT Decoder Layer (seq_len={args.seq_len}, kv_group_size={args.kv_group_size})")
    print("=" * 70)

    config = LlamaConfig()
    layer = KV4DecoderLayer_opt(config, layer_idx=0, kv_group_size=args.kv_group_size).half()

    orig_params = count_params(layer)
    replace_linear_with_w4a16_opt(layer, group_size=args.group_size)
    w4_params = count_w4a16_opt_params(layer)
    print(f"  Original params:     {orig_params:,}")
    print(f"  W4A16 weight elems:  {w4_params:,}")
    print(f"  Compression (lin):   ~{orig_params * 16 / max(w4_params * 4, 1):.1f}x (fp16 -> int4)")
    print(f"  KV cache: online int4 quantized per forward (group_size={args.kv_group_size})")
    print(f"  GEMM op: torch.ops.vortex.mm_w4a16_opt (tile-laid-out DRAM)")

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
    print(f"  {'PASSED' if ok else 'FAILED'}: KV4_OPT decoder layer forward")
    print()
    return ok


def test_kv4_opt_bench(args):
    print("=" * 70)
    print(f"Test 2: Benchmark KV4_OPT decoder layer "
          f"(seq_len={args.seq_len}, warmup={args.bench_warmup}, iters={args.bench_iters})")
    print("=" * 70)

    config = LlamaConfig()
    layer = KV4DecoderLayer_opt(config, layer_idx=0, kv_group_size=args.kv_group_size).half()
    replace_linear_with_w4a16_opt(layer, group_size=args.group_size)

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
        "llama_w4a16_kv4_opt_trace.json",
    )
    latencies = []
    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for i in range(args.bench_iters):
            sync()
            t0 = time.perf_counter()
            with record_function(f"KV4_OPT::bench_iter_{i}"):
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

    M  = args.seq_len
    H  = config.hidden_size
    I  = config.intermediate_size
    linear_flops = 2 * M * (4 * H * H + 3 * H * I)
    attn_flops   = 4 * M * M * H   # Q*K^T + P*V
    total_flops  = linear_flops + attn_flops

    print(f"\n  Results (KV4_OPT decoder layer, seq_len={args.seq_len}):")
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
    p = argparse.ArgumentParser(
        description="LLaMA decoder layer W4A16 + online INT4 KV (OPT variant via mm_w4a16_opt)")
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
    print("LLaMA Decoder Layer — W4A16 linears + online INT4 KV (OPT path: mm_w4a16_opt)")
    print(f"  hidden_size={LlamaConfig.hidden_size}, intermediate_size={LlamaConfig.intermediate_size}")
    print(f"  num_heads={LlamaConfig.num_attention_heads}, head_dim={LlamaConfig.head_dim}")
    print(f"  seq_len={args.seq_len}, lin_group_size={args.group_size}, kv_group_size={args.kv_group_size}")
    print("=" * 70)
    print()

    tests = [
        ("kv4_opt_decoder_layer", lambda: test_kv4_opt_decoder_layer(args)),
    ]
    if not args.skip_bench:
        tests.append(("kv4_opt_bench", lambda: test_kv4_opt_bench(args)))

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
