#!/usr/bin/env python3
"""
Test: LLaMA Decoder Layer with W4A16 quantized linear layers on Vortex.

Replaces nn.Linear with fake-quantized W4A16 linear layers:
  - Original fp16 weights are quantized to int4 on-the-fly (per-group symmetric)
  - At inference: torch.ops.vortex.mm_w4a16(input, w_int4, scales, zeros, ...)
  - This is NOT for accuracy — it's for performance estimation of W4A16 inference.

Usage:
  FPGA_BIN_DIR=/path/to/bin python test/test_llama_layer_w4a16.py [--seq-len 4] [--bench-iters 5]
"""

import argparse
import os
import sys
import time
import math

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.profiler import profile, ProfilerActivity, record_function

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # registers 'vortex' backend

DEVICE = "vortex"


# ============================================================================
#  Fake quantization: fp16 weight -> int4 packed + scales + zeros
# ============================================================================

def quantize_weight_to_int4(weight_fp16, group_size=32):
    """
    Fake-quantize a fp16 [out_features, in_features] weight to int4.

    Returns:
      w_int4_packed: uint8 [in_features, out_features/2]  (K=in, N=out, packed pairs)
      scales:        fp16  [num_groups, out_features]
      zeros:         int16 [num_groups, out_features]

    Note: The GEMM kernel expects weight laid out as [K, N/2],
          so we transpose from [out, in] to [in, out] before packing.
    """
    out_features, in_features = weight_fp16.shape
    K, N = in_features, out_features

    # Transpose to [K, N] for the kernel layout
    w = weight_fp16.t().float()  # [K, N]

    num_groups = (K + group_size - 1) // group_size
    scales = torch.zeros(num_groups, N, dtype=torch.float16)
    zeros = torch.zeros(num_groups, N, dtype=torch.int16)
    w_int4 = torch.zeros(K, N, dtype=torch.int8)

    for g in range(num_groups):
        k_start = g * group_size
        k_end = min(k_start + group_size, K)
        block = w[k_start:k_end, :]  # [group_size, N]

        # Symmetric quantization to [-8, 7]
        amax = block.abs().amax(dim=0).clamp(min=1e-6)  # [N]
        scale = amax / 7.0
        zp = torch.zeros(N)

        # Quantize
        q = torch.clamp(torch.round(block / scale.unsqueeze(0) + zp.unsqueeze(0)), -8, 7).to(torch.int8)

        w_int4[k_start:k_end, :] = q
        scales[g, :] = scale.half()
        zeros[g, :] = zp.to(torch.int16)

    # Pack int4 pairs into uint8: [K, N] -> [K, N/2]
    assert N % 2 == 0, f"N={N} must be even for int4 packing"
    packed = torch.zeros(K, N // 2, dtype=torch.uint8)
    for n_pair in range(N // 2):
        lo = w_int4[:, n_pair * 2].to(torch.uint8) & 0x0F
        hi = w_int4[:, n_pair * 2 + 1].to(torch.uint8) & 0x0F
        packed[:, n_pair] = (hi << 4) | lo

    return packed, scales, zeros


# ============================================================================
#  W4A16 Linear layer (drop-in replacement for nn.Linear)
# ============================================================================

class W4A16Linear(nn.Module):
    """Linear layer that uses W4A16 GEMM on Vortex device."""

    def __init__(self, in_features, out_features, weight_fp16, group_size=32):
        super().__init__()
        self.in_features = in_features
        self.out_features = out_features
        self.group_size = group_size

        # Quantize weight
        w_packed, scales, zeros = quantize_weight_to_int4(weight_fp16, group_size)

        self.register_buffer("w_int4", w_packed)
        self.register_buffer("scales", scales)
        self.register_buffer("zeros", zeros)

    def forward(self, x):
        # x: [..., in_features] fp16
        orig_shape = x.shape
        x_2d = x.reshape(-1, self.in_features)  # [M, K]

        if not x_2d.is_contiguous():
            x_2d = x_2d.contiguous()

        # Ensure fp16
        if x_2d.dtype != torch.float16:
            x_2d = x_2d.half()

        with record_function(f"W4A16::mm_w4a16({self.in_features}x{self.out_features})"):
            out = torch.ops.vortex.mm_w4a16(
                x_2d, self.w_int4, self.scales, self.zeros,
                self.group_size, self.out_features, 0, 0,
            )
        return out.reshape(*orig_shape[:-1], self.out_features)


def replace_linear_with_w4a16(module, group_size=32):
    """Recursively replace all nn.Linear layers with W4A16Linear."""
    for name, child in module.named_children():
        if isinstance(child, nn.Linear):
            w4 = W4A16Linear(
                child.in_features, child.out_features,
                child.weight.data.half(), group_size,
            )
            setattr(module, name, w4)
        else:
            replace_linear_with_w4a16(child, group_size)


# ============================================================================
#  LLaMA components (same as test_llama_layer.py)
# ============================================================================

class LlamaConfig:
    hidden_size         = 4096
    intermediate_size   = 11008
    num_attention_heads = 32
    num_key_value_heads = 32
    num_hidden_layers   = 1
    head_dim            = 128
    max_position_embeddings = 4096
    rms_norm_eps        = 1e-5
    attention_dropout   = 0.0
    attention_bias      = False
    mlp_bias            = False
    hidden_act          = "silu"
    rope_theta          = 10000.0
    rope_scaling        = None
    _attn_implementation = "eager"


class LlamaRMSNorm(nn.Module):
    def __init__(self, hidden_size, eps=1e-6):
        super().__init__()
        self.weight = nn.Parameter(torch.ones(hidden_size))
        self.variance_epsilon = eps

    def forward(self, hidden_states):
        input_dtype = hidden_states.dtype
        hidden_states = hidden_states.to(torch.float32)
        variance = hidden_states.pow(2).mean(-1, keepdim=True)
        hidden_states = hidden_states * torch.rsqrt(variance + self.variance_epsilon)
        return self.weight * hidden_states.to(input_dtype)


class LlamaRotaryEmbedding(nn.Module):
    def __init__(self, config, device=None):
        super().__init__()
        dim = config.head_dim
        inv_freq = 1.0 / (
            config.rope_theta ** (torch.arange(0, dim, 2, dtype=torch.float32) / dim)
        )
        self.register_buffer("inv_freq", inv_freq, persistent=False)

    @torch.no_grad()
    def forward(self, x, position_ids):
        inv_freq = self.inv_freq[None, :, None].float().expand(
            position_ids.shape[0], -1, 1
        ).to(x.device)
        pos = position_ids[:, None, :].float()
        freqs = (inv_freq @ pos).transpose(1, 2)
        emb = torch.cat((freqs, freqs), dim=-1)
        return emb.cos().to(x.dtype), emb.sin().to(x.dtype)


def rotate_half(x):
    x1 = x[..., : x.shape[-1] // 2]
    x2 = x[..., x.shape[-1] // 2 :]
    return torch.cat((-x2, x1), dim=-1)


def apply_rotary_pos_emb(q, k, cos, sin, unsqueeze_dim=1):
    cos = cos.unsqueeze(unsqueeze_dim)
    sin = sin.unsqueeze(unsqueeze_dim)
    q_embed = (q * cos) + (rotate_half(q) * sin)
    k_embed = (k * cos) + (rotate_half(k) * sin)
    return q_embed, k_embed


class LlamaMLP(nn.Module):
    def __init__(self, config):
        super().__init__()
        self.gate_proj = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.up_proj   = nn.Linear(config.hidden_size, config.intermediate_size, bias=config.mlp_bias)
        self.down_proj = nn.Linear(config.intermediate_size, config.hidden_size, bias=config.mlp_bias)

    def forward(self, x):
        with record_function("W4A16::mlp_gate_proj"):
            gate = self.gate_proj(x)
        with record_function("W4A16::mlp_silu"):
            gate = F.silu(gate.float()).to(x.dtype)
        with record_function("W4A16::mlp_up_proj"):
            up = self.up_proj(x)
        with record_function("W4A16::mlp_down_proj"):
            out = self.down_proj(gate * up)
        return out


class LlamaAttention(nn.Module):
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

        with record_function("W4A16::attn_qkv_proj"):
            query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            key_states   = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)

        with record_function("W4A16::rope"):
            cos, sin = position_embeddings
            query_states, key_states = apply_rotary_pos_emb(query_states, key_states, cos, sin)

        with record_function("W4A16::attn_score"):
            attn_weights = torch.matmul(query_states, key_states.transpose(2, 3)) * self.scaling
            if attention_mask is not None:
                attn_weights = attn_weights + attention_mask[:, :, :, :seq_len]

        with record_function("W4A16::softmax"):
            attn_weights = F.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query_states.dtype)

        with record_function("W4A16::attn_value"):
            attn_output = torch.matmul(attn_weights, value_states)

        with record_function("W4A16::attn_reshape"):
            attn_output = attn_output.transpose(1, 2).contiguous()
            attn_output = attn_output.reshape(bsz, seq_len, -1).contiguous()

        with record_function("W4A16::attn_o_proj"):
            return self.o_proj(attn_output)


class LlamaDecoderLayer(nn.Module):
    def __init__(self, config, layer_idx=0):
        super().__init__()
        self.self_attn = LlamaAttention(config, layer_idx)
        self.mlp = LlamaMLP(config)
        self.input_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        residual = hidden_states
        with record_function("W4A16::input_layernorm"):
            hidden_states = self.input_layernorm(hidden_states)
        with record_function("W4A16::self_attn"):
            hidden_states = self.self_attn(hidden_states, position_embeddings, attention_mask)
        with record_function("W4A16::residual_add_attn"):
            hidden_states = residual + hidden_states

        residual = hidden_states
        with record_function("W4A16::post_attn_layernorm"):
            hidden_states = self.post_attention_layernorm(hidden_states)
        with record_function("W4A16::mlp"):
            hidden_states = self.mlp(hidden_states)
        with record_function("W4A16::residual_add_mlp"):
            hidden_states = residual + hidden_states
        return hidden_states


# ============================================================================
#  Helpers
# ============================================================================

def make_position_embeddings(config, batch_size, seq_len, device="cpu"):
    rotary = LlamaRotaryEmbedding(config)
    position_ids = torch.arange(seq_len, device=device).unsqueeze(0).expand(batch_size, -1)
    dummy = torch.empty(1, device=device)
    cos, sin = rotary.to(device)(dummy, position_ids)
    return cos, sin


def sync():
    try:
        torch.vortex.synchronize()
    except Exception:
        pass


def count_params(module):
    return sum(p.numel() for p in module.parameters())


def count_w4a16_params(module):
    """Count total int4 weight elements (unpacked)."""
    total = 0
    for m in module.modules():
        if isinstance(m, W4A16Linear):
            total += m.in_features * m.out_features
    return total


# ============================================================================
#  Tests
# ============================================================================

def test_w4a16_single_linear(args):
    """Sanity: single W4A16Linear layer on device."""
    print("=" * 70)
    print("Test 1: Single W4A16Linear (4096 -> 4096)")
    print("=" * 70)

    config = LlamaConfig()
    lin = nn.Linear(config.hidden_size, config.hidden_size, bias=False)
    x = torch.randn(1, args.seq_len, config.hidden_size, dtype=torch.float16)

    # CPU fp16 reference
    ref = lin.half()(x)

    # W4A16 on device
    w4lin = W4A16Linear(config.hidden_size, config.hidden_size, lin.weight.data.half(), group_size=32)
    w4lin = w4lin.to(DEVICE)
    out = w4lin(x.to(DEVICE)).cpu()

    diff = (out.float() - ref.float()).abs()
    print(f"  vs fp16 ref: max_diff={diff.max().item():.4f}  mean_diff={diff.mean().item():.4f}")
    print(f"  (Large diff expected — this is fake int4 quantization)")
    print(f"  PASSED: W4A16Linear runs without error")
    print()
    return True


def test_w4a16_decoder_layer(args):
    """Full LLaMA decoder layer with W4A16 quantized linears."""
    print("=" * 70)
    print(f"Test 2: LlamaDecoderLayer W4A16 (seq_len={args.seq_len})")
    print("=" * 70)

    config = LlamaConfig()
    layer = LlamaDecoderLayer(config, layer_idx=0).half()

    # Count original params
    orig_params = count_params(layer)

    # Replace all nn.Linear with W4A16Linear
    replace_linear_with_w4a16(layer, group_size=args.group_size)
    w4_params = count_w4a16_params(layer)

    print(f"  Original params:    {orig_params:,}")
    print(f"  W4A16 weight elems: {w4_params:,}")
    print(f"  Compression ratio:  ~{orig_params * 16 / (w4_params * 4):.1f}x (fp16 -> int4)")

    x = torch.randn(1, args.seq_len, config.hidden_size, dtype=torch.float16)

    # Move to device
    layer_dev = layer.to(DEVICE)
    cos, sin = make_position_embeddings(config, 1, args.seq_len, DEVICE)
    x_dev = x.to(DEVICE)

    # Causal mask
    mask = torch.zeros(1, 1, args.seq_len, args.seq_len, dtype=torch.float16)
    mask.masked_fill_(
        torch.triu(torch.ones(args.seq_len, args.seq_len, dtype=torch.bool), diagonal=1),
        float("-inf"),
    )
    mask_dev = mask.to(DEVICE)

    # Forward
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
    print(f"  {'PASSED' if ok else 'FAILED'}: decoder layer W4A16 forward")
    print()
    return ok


def test_w4a16_bench(args):
    """Benchmark: LLaMA decoder layer W4A16 latency."""
    print("=" * 70)
    print(f"Test 3: Benchmark W4A16 decoder layer (seq_len={args.seq_len}, "
          f"warmup={args.bench_warmup}, iters={args.bench_iters})")
    print("=" * 70)

    config = LlamaConfig()
    layer = LlamaDecoderLayer(config, layer_idx=0).half()
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

    # Warmup
    print(f"  Warming up ({args.bench_warmup} iters)...")
    for _ in range(args.bench_warmup):
        _ = layer_dev(x_dev, (cos, sin), attention_mask=mask_dev)
        sync()

    # Benchmark with profiler
    trace_path = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "llama_w4a16_trace.json",
    )
    latencies = []
    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for i in range(args.bench_iters):
            sync()
            t0 = time.perf_counter()
            with record_function(f"W4A16::bench_iter_{i}"):
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

    # Estimate FLOPS
    # Decoder layer linear ops (dominant):
    #   q/k/v_proj: 3 x [M, 4096] x [4096, 4096] = 3 * 2 * M * 4096^2
    #   o_proj:     [M, 4096] x [4096, 4096]       = 2 * M * 4096^2
    #   gate/up:    2 x [M, 4096] x [4096, 11008]  = 2 * 2 * M * 4096 * 11008
    #   down:       [M, 11008] x [11008, 4096]      = 2 * M * 11008 * 4096
    M = args.seq_len
    H = config.hidden_size
    I = config.intermediate_size
    linear_flops = 2 * M * (4 * H * H + 3 * H * I)
    gflops = linear_flops / 1e9

    print(f"\n  Results (W4A16 decoder layer, seq_len={args.seq_len}):")
    print(f"    mean:  {mean_ms:.2f} ms")
    print(f"    p50:   {p50_ms:.2f} ms")
    print(f"    min:   {min_ms:.2f} ms")
    print(f"    max:   {max_ms:.2f} ms")
    print(f"    Linear FLOPS: {gflops:.2f} GFLOP")
    print(f"    Throughput:   {gflops / (mean_ms / 1000.0):.2f} GFLOP/s (estimate)")
    print(f"  PASSED: benchmark complete")
    print()
    return True


# ============================================================================
#  Main
# ============================================================================

def parse_args():
    p = argparse.ArgumentParser(description="LLaMA decoder layer W4A16 test & benchmark")
    p.add_argument("--seq-len", type=int, default=4)
    p.add_argument("--group-size", type=int, default=32)
    p.add_argument("--bench-warmup", type=int, default=2)
    p.add_argument("--bench-iters", type=int, default=5)
    p.add_argument("--skip-bench", action="store_true")
    return p.parse_args()


if __name__ == "__main__":
    args = parse_args()

    print("=" * 70)
    print("LLaMA Decoder Layer — W4A16 Quantized GEMM on Vortex")
    print(f"  hidden_size={LlamaConfig.hidden_size}, intermediate_size={LlamaConfig.intermediate_size}")
    print(f"  num_heads={LlamaConfig.num_attention_heads}, head_dim={LlamaConfig.head_dim}")
    print(f"  seq_len={args.seq_len}, group_size={args.group_size}")
    print("=" * 70)
    print()

    tests = [
        ("w4a16_single_linear", lambda: test_w4a16_single_linear(args)),
        ("w4a16_decoder_layer", lambda: test_w4a16_decoder_layer(args)),
    ]
    if not args.skip_bench:
        tests.append(("w4a16_bench", lambda: test_w4a16_bench(args)))

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
