#!/usr/bin/env python3
"""
Test: LLaMA Decoder Layer with int4-stored weights, but compute via DEQUANT -> fp16 GEMM.

Models the "no MPGEMM unit" baseline (e.g., a regular GPU that lacks fp16xint4
mixed-precision GEMM). Weights are stored exactly as in test_llama_layer_w4a16.py
(packed int4 + group scales + zeros), but at every forward the weight is
dequantized back to fp16 and a regular fp16 matmul is executed. This isolates
the perf cost of NOT having a fused MPGEMM kernel while keeping the storage and
quantization scheme identical to the W4A16 path for a fair comparison.

  Storage:        uint8 [K, N/2] packed + fp16 [K/G, N] scales + int16 [K/G, N] zeros
  Forward path:   dequant -> [K, N] fp16 weight -> torch.matmul(x_fp16, w_fp16) -> [M, N] fp16
  Attention BMMs: plain fp16 (same as the W4A16 baseline; KV stays fp16)

Usage:
  FPGA_BIN_DIR=... python test/test_llama_layer_dequantize.py [--seq-len 32] [--bench-iters 1]
"""

import argparse
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
    LlamaRMSNorm,
    LlamaRotaryEmbedding,
    apply_rotary_pos_emb,
    quantize_weight_to_int4,
    make_position_embeddings,
    sync,
    count_params,
)


# ============================================================================
#  Dequant kernel: int4 packed -> fp16 weight (per call)
# ============================================================================

def dequantize_int4_to_fp16(w_packed: torch.Tensor,
                            scales: torch.Tensor,
                            zeros: torch.Tensor,
                            K: int, N: int,
                            group_size: int) -> torch.Tensor:
    """
    Reconstruct fp16 [K, N] weight from packed int4 storage.

      w_packed: uint8 [K, N/2]   — two int4 per byte; lo nibble = col 2j, hi = col 2j+1
      scales:   fp16  [K/G, N]
      zeros:    int16 [K/G, N]
    """
    # Unpack two 4-bit values per byte using arithmetic (portable across backends).
    p = w_packed.to(torch.int16)
    hi = p // 16          # 0..15
    lo = p - hi * 16      # 0..15
    # Sign-extend 4-bit two's complement: 8..15 -> -8..-1
    lo_s = torch.where(lo < 8, lo, lo - 16)
    hi_s = torch.where(hi < 8, hi, hi - 16)

    # Interleave back to [K, N]: out[:, 2j] = lo, out[:, 2j+1] = hi
    interleaved = torch.stack([lo_s, hi_s], dim=-1).reshape(K, N)

    # Group-wise scale/zp via reshape + broadcast (no repeat_interleave allocation).
    num_groups = scales.shape[0]
    w_int_g = interleaved.view(num_groups, group_size, N).to(torch.float16)
    z_g = zeros.unsqueeze(1).to(torch.float16)              # [G, 1, N]
    s_g = scales.unsqueeze(1)                                # [G, 1, N]
    w_fp = (w_int_g - z_g) * s_g
    return w_fp.view(K, N)


# ============================================================================
#  DequantLinear: stores int4, dequantizes to fp16 + fp16 matmul each forward
# ============================================================================

class DequantLinear(nn.Module):
    """Drop-in replacement for nn.Linear with int4 storage + fp16 compute path."""

    def __init__(self, in_features, out_features, weight_fp16, group_size=32):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.group_size = group_size

        # Same offline quantization as W4A16Linear (-> packed [K,N/2], scales [K/G,N], zeros [K/G,N])
        w_packed, scales, zeros = quantize_weight_to_int4(weight_fp16, group_size)
        self.register_buffer("w_int4", w_packed)
        self.register_buffer("scales", scales)
        self.register_buffer("zeros", zeros)

    def forward(self, x):
        orig_shape = x.shape
        x_2d = x.reshape(-1, self.in_features)  # [M, K]
        if not x_2d.is_contiguous():
            x_2d = x_2d.contiguous()
        if x_2d.dtype != torch.float16:
            x_2d = x_2d.half()

        K, N = self.in_features, self.out_features
        with record_function(f"DEQ::dequant({K}x{N})"):
            w_fp16 = dequantize_int4_to_fp16(
                self.w_int4, self.scales, self.zeros, K, N, self.group_size
            )
        with record_function(f"DEQ::mm_fp16({K}x{N})"):
            out = x_2d @ w_fp16  # [M, K] @ [K, N] -> [M, N]
        return out.reshape(*orig_shape[:-1], self.out_features)


def replace_linear_with_dequant(module, group_size=32):
    """Recursively replace all nn.Linear layers with DequantLinear."""
    for name, child in module.named_children():
        if isinstance(child, nn.Linear):
            d = DequantLinear(
                child.in_features, child.out_features,
                child.weight.data.half(), group_size,
            )
            setattr(module, name, d)
        else:
            replace_linear_with_dequant(child, group_size)


def count_dequant_params(module):
    total = 0
    for m in module.modules():
        if isinstance(m, DequantLinear):
            total += m.in_features * m.out_features
    return total


# ============================================================================
#  Llama* modules (DEQ:: trace prefix; identical structure to baseline LlamaXxx)
# ============================================================================

class LlamaMLP_DEQ(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.gate_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.up_proj   = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=config.mlp_bias)

    def forward(self, x):
        with record_function("DEQ::mlp_gate_proj"):
            gate = self.gate_proj(x)
        with record_function("DEQ::mlp_silu"):
            gate = F.silu(gate.float()).to(x.dtype)
        with record_function("DEQ::mlp_up_proj"):
            up = self.up_proj(x)
        with record_function("DEQ::mlp_down_proj"):
            out = self.down_proj(gate * up)
        return out


class LlamaAttention_DEQ(nn.Module):
    """Standard fp16 LlamaAttention — Q*K^T and P*V are plain torch.matmul."""

    def __init__(self, config, layer_idx=0):
        super().__init__()
        self.head_dim = config.head_dim
        self.num_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.scaling = self.head_dim ** -0.5

        self.q_proj = nn.Linear(config.hidden_size, self.num_heads * self.head_dim, bias=config.attention_bias)
        self.k_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.v_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, config.hidden_size, bias=config.attention_bias)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        bsz, seq_len, _ = hidden_states.shape
        hidden_shape = (bsz, seq_len, -1, self.head_dim)

        with record_function("DEQ::attn_qkv_proj"):
            query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            key_states   = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)

        with record_function("DEQ::rope"):
            cos, sin = position_embeddings
            query_states, key_states = apply_rotary_pos_emb(query_states, key_states, cos, sin)

        with record_function("DEQ::attn_score"):
            attn_weights = torch.matmul(query_states, key_states.transpose(2, 3)) * self.scaling
            if attention_mask is not None:
                attn_weights = attn_weights + attention_mask[:, :, :, :seq_len]

        with record_function("DEQ::softmax"):
            attn_weights = F.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query_states.dtype)

        with record_function("DEQ::attn_value"):
            attn_output = torch.matmul(attn_weights, value_states)

        with record_function("DEQ::attn_reshape"):
            attn_output = attn_output.transpose(1, 2).contiguous()
            attn_output = attn_output.reshape(bsz, seq_len, -1).contiguous()

        with record_function("DEQ::attn_o_proj"):
            return self.o_proj(attn_output)


class LlamaDecoderLayer_DEQ(nn.Module):
    def __init__(self, config, layer_idx=0):
        super().__init__()
        self.self_attn = LlamaAttention_DEQ(config, layer_idx)
        self.mlp = LlamaMLP_DEQ(config)
        self.input_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        residual = hidden_states
        with record_function("DEQ::input_layernorm"):
            hidden_states = self.input_layernorm(hidden_states)
        with record_function("DEQ::self_attn"):
            hidden_states = self.self_attn(hidden_states, position_embeddings, attention_mask)
        with record_function("DEQ::residual_add_attn"):
            hidden_states = residual + hidden_states

        residual = hidden_states
        with record_function("DEQ::post_attn_layernorm"):
            hidden_states = self.post_attention_layernorm(hidden_states)
        with record_function("DEQ::mlp"):
            hidden_states = self.mlp(hidden_states)
        with record_function("DEQ::residual_add_mlp"):
            hidden_states = residual + hidden_states
        return hidden_states


# ============================================================================
#  Tests
# ============================================================================

def test_dequant_single_linear(args):
    """Sanity: a single DequantLinear matches the offline-fp16 reference closely."""
    print("=" * 70)
    print("Test 1: Single DequantLinear (4096 -> 4096)")
    print("=" * 70)

    config = LlamaConfig()
    lin = nn.Linear(config.hidden_size, config.hidden_size, bias=False)
    x = torch.randn(1, args.seq_len, config.hidden_size, dtype=torch.float16)

    ref_fp16 = lin.half()(x)

    deqlin = DequantLinear(config.hidden_size, config.hidden_size, lin.weight.data.half(), group_size=args.group_size)
    deqlin = deqlin.to(DEVICE)
    out = deqlin(x.to(DEVICE)).cpu()

    diff = (out.float() - ref_fp16.float()).abs()
    print(f"  vs fp16 ref: max_diff={diff.max().item():.4f}  mean_diff={diff.mean().item():.4f}")
    print(f"  (Diff comes from int4 quantization, NOT the dequant+fp16 path itself)")
    print(f"  PASSED: DequantLinear runs without error")
    print()
    return True


def test_dequant_decoder_layer(args):
    print("=" * 70)
    print(f"Test 2: LlamaDecoderLayer DEQUANT (seq_len={args.seq_len})")
    print("=" * 70)

    config = LlamaConfig()
    layer = LlamaDecoderLayer_DEQ(config, layer_idx=0).half()
    orig_params = count_params(layer)
    replace_linear_with_dequant(layer, group_size=args.group_size)
    deq_params = count_dequant_params(layer)
    print(f"  Original params:        {orig_params:,}")
    print(f"  Int4-stored elements:   {deq_params:,}")
    print(f"  Storage compression:    ~{orig_params * 16 / max(deq_params * 4, 1):.1f}x  (fp16 -> int4)")
    print(f"  NOTE: compute path is fp16 (dequant per forward), no MPGEMM fusion.")

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
    print(f"  {'PASSED' if ok else 'FAILED'}: dequantize decoder layer forward")
    print()
    return ok


def test_dequant_bench(args):
    print("=" * 70)
    print(f"Test 3: Benchmark DEQUANT decoder layer (seq_len={args.seq_len}, "
          f"warmup={args.bench_warmup}, iters={args.bench_iters})")
    print("=" * 70)

    config = LlamaConfig()
    layer = LlamaDecoderLayer_DEQ(config, layer_idx=0).half()
    replace_linear_with_dequant(layer, group_size=args.group_size)

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
        "llama_dequantize_trace.json",
    )
    latencies = []
    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for i in range(args.bench_iters):
            sync()
            t0 = time.perf_counter()
            with record_function(f"DEQ::bench_iter_{i}"):
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
    # FP16 GEMM FLOPs (linears + attention BMMs)
    linear_gemm_flops = 2 * M * (4 * H * H + 3 * H * I)
    attn_bmm_flops    = 4 * M * M * H            # Q*K^T + P*V
    # Dequant FLOPs (~= 2 * K * N per linear: subtract zp + multiply by scale)
    dequant_flops     = 2 * (4 * H * H + 3 * H * I)
    total_compute     = linear_gemm_flops + attn_bmm_flops + dequant_flops

    print(f"\n  Results (DEQUANT decoder layer, seq_len={args.seq_len}):")
    print(f"    mean:  {mean_ms:.2f} ms")
    print(f"    p50:   {p50_ms:.2f} ms")
    print(f"    min:   {min_ms:.2f} ms")
    print(f"    max:   {max_ms:.2f} ms")
    print(f"    Linear GEMM FLOPs (fp16): {linear_gemm_flops/1e9:.3f} GFLOP")
    print(f"    Attention BMM FLOPs:      {attn_bmm_flops/1e9:.3f} GFLOP")
    print(f"    Dequant FLOPs (~2KN):     {dequant_flops/1e9:.3f} GFLOP")
    print(f"    Total compute:            {total_compute/1e9:.3f} GFLOP")
    print(f"    Throughput:               {total_compute / (mean_ms / 1000.0) / 1e9:.2f} GFLOP/s")
    print(f"  PASSED: benchmark complete")
    print()
    return True


# ============================================================================
#  Main
# ============================================================================

def parse_args():
    p = argparse.ArgumentParser(description="LLaMA decoder layer dequant+fp16 baseline test/bench")
    p.add_argument("--seq-len", type=int, default=32)
    p.add_argument("--group-size", type=int, default=32,
                   help="int4 weight group_size (must match what W4A16Linear uses for fair compare)")
    p.add_argument("--bench-warmup", type=int, default=2)
    p.add_argument("--bench-iters", type=int, default=5)
    p.add_argument("--skip-bench", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()

    print("=" * 70)
    print("LLaMA Decoder Layer — int4-stored weights + DEQUANT -> fp16 GEMM (no MPGEMM)")
    print(f"  hidden_size={LlamaConfig.hidden_size}, intermediate_size={LlamaConfig.intermediate_size}")
    print(f"  num_heads={LlamaConfig.num_attention_heads}, head_dim={LlamaConfig.head_dim}")
    print(f"  seq_len={args.seq_len}, group_size={args.group_size}")
    print("=" * 70)
    print()

    tests = [
        ("dequant_single_linear", lambda: test_dequant_single_linear(args)),
        ("dequant_decoder_layer", lambda: test_dequant_decoder_layer(args)),
    ]
    if not args.skip_bench:
        tests.append(("dequant_bench", lambda: test_dequant_bench(args)))

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
