#!/usr/bin/env python3
"""
Test: LLaMA Decoder Layer forward pass on Vortex device.

Constructs the actual components from modeling_llama.py
(LlamaRMSNorm, LlamaMLP, LlamaAttention, LlamaDecoderLayer)
using tiny dimensions, then runs forward on the Vortex device
and compares against a CPU reference.

This exercises the full LLaMA op chain on Vortex:
  - nn.Linear        → aten::mm / aten::addmm  (native sgemm_tcu)
  - torch.matmul 4D  → aten::bmm               (native sgemm_tcu batched)
  - F.softmax        → aten::_softmax           (native softmax kernel)
  - F.silu           → aten::silu               (native silu kernel)
  - residual add     → aten::add.Tensor         (native eladd or CPU fallback for broadcast)
  - weight * x       → aten::mul.Tensor         (CPU fallback for broadcast)
  - RMSNorm          → CPU fallback (pow, mean, rsqrt, broadcast mul)
  - RoPE             → CPU fallback (rotate_half pattern)
  - view, transpose, reshape, contiguous → CPU fallback (mandatory ops)
"""

import os
import sys
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
#  Minimal LlamaConfig-like object (no HF dependency required)
# ============================================================================
class TinyLlamaConfig:
    """Tiny config for testing — matches LlamaConfig interface used by layers."""
    hidden_size        = 32         # must be multiple of 8 for TCU tile
    intermediate_size  = 64         # MLP intermediate
    num_attention_heads = 4         # must divide hidden_size
    num_key_value_heads = 4         # same as num_attention_heads (MHA, no GQA)
    num_hidden_layers  = 2
    head_dim           = 8          # hidden_size // num_attention_heads
    max_position_embeddings = 64
    rms_norm_eps       = 1e-5
    attention_dropout  = 0.0
    attention_bias     = False
    mlp_bias           = False
    hidden_act         = "silu"
    rope_theta         = 10000.0
    rope_scaling       = None
    _attn_implementation = "eager"

# ============================================================================
#  LLaMA components (copied from modeling_llama.py to avoid HF dependency)
# ============================================================================

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
        # inv_freq: [dim/2] → [1, dim/2, 1]
        inv_freq = self.inv_freq[None, :, None].float().expand(
            position_ids.shape[0], -1, 1
        ).to(x.device)
        # position_ids: [batch, seq] → [batch, 1, seq]
        pos = position_ids[:, None, :].float()
        freqs = (inv_freq @ pos).transpose(1, 2)  # [batch, seq, dim/2]
        emb = torch.cat((freqs, freqs), dim=-1)     # [batch, seq, dim]
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
        with record_function("VORTEX::mlp_gate_silu"):
            gate = F.silu(self.gate_proj(x))
        with record_function("VORTEX::mlp_up_proj"):
            up = self.up_proj(x)
        with record_function("VORTEX::mlp_down_proj"):
            out = self.down_proj(gate * up)
        return out


class LlamaAttention(nn.Module):
    def __init__(self, config, layer_idx=0):
        super().__init__()
        self.head_dim = config.head_dim
        self.num_heads = config.num_attention_heads
        self.num_key_value_heads = config.num_key_value_heads
        self.num_key_value_groups = self.num_heads // self.num_key_value_heads
        self.scaling = self.head_dim ** -0.5
        self.attention_dropout = config.attention_dropout

        self.q_proj = nn.Linear(config.hidden_size, self.num_heads * self.head_dim, bias=config.attention_bias)
        self.k_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.v_proj = nn.Linear(config.hidden_size, self.num_key_value_heads * self.head_dim, bias=config.attention_bias)
        self.o_proj = nn.Linear(self.num_heads * self.head_dim, config.hidden_size, bias=config.attention_bias)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        bsz, seq_len, _ = hidden_states.shape
        hidden_shape = (bsz, seq_len, -1, self.head_dim)

        with record_function("VORTEX::attn_qkv_proj"):
            query_states = self.q_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            key_states   = self.k_proj(hidden_states).view(hidden_shape).transpose(1, 2)
            value_states = self.v_proj(hidden_states).view(hidden_shape).transpose(1, 2)

        with record_function("VORTEX::rope"):
            cos, sin = position_embeddings
            query_states, key_states = apply_rotary_pos_emb(query_states, key_states, cos, sin)

        # Eager attention
        with record_function("VORTEX::attn_score"):
            attn_weights = torch.matmul(query_states, key_states.transpose(2, 3)) * self.scaling
            if attention_mask is not None:
                attn_weights = attn_weights + attention_mask[:, :, :, :seq_len]

        with record_function("VORTEX::softmax"):
            attn_weights = F.softmax(attn_weights, dim=-1, dtype=torch.float32).to(query_states.dtype)

        with record_function("VORTEX::attn_value"):
            attn_output = torch.matmul(attn_weights, value_states)

        with record_function("VORTEX::attn_reshape"):
            attn_output = attn_output.transpose(1, 2).contiguous()
            attn_output = attn_output.reshape(bsz, seq_len, -1).contiguous()

        with record_function("VORTEX::attn_o_proj"):
            attn_output = self.o_proj(attn_output)

        return attn_output


class LlamaDecoderLayer(nn.Module):
    def __init__(self, config, layer_idx=0):
        super().__init__()
        self.self_attn = LlamaAttention(config, layer_idx)
        self.mlp = LlamaMLP(config)
        self.input_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
        self.post_attention_layernorm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    def forward(self, hidden_states, position_embeddings, attention_mask=None):
        # Self-Attention with residual
        residual = hidden_states
        with record_function("VORTEX::input_layernorm"):
            hidden_states = self.input_layernorm(hidden_states)
        with record_function("VORTEX::self_attn"):
            hidden_states = self.self_attn(hidden_states, position_embeddings, attention_mask)
        with record_function("VORTEX::residual_add_attn"):
            hidden_states = residual + hidden_states

        # MLP with residual
        residual = hidden_states
        with record_function("VORTEX::post_attn_layernorm"):
            hidden_states = self.post_attention_layernorm(hidden_states)
        with record_function("VORTEX::mlp"):
            hidden_states = self.mlp(hidden_states)
        with record_function("VORTEX::residual_add_mlp"):
            hidden_states = residual + hidden_states
        return hidden_states


# ============================================================================
#  Test helpers
# ============================================================================

def _check(name, result, expected, atol=0.5, rtol=0.1):
    """Compare Vortex result vs CPU reference."""
    diff = (result.float() - expected.float()).abs()
    max_diff = diff.max().item()
    mean_diff = diff.mean().item()
    rel_err = (diff / (expected.float().abs() + 1e-8)).mean().item()
    print(f"  max_diff={max_diff:.6f}  mean_diff={mean_diff:.6f}  rel_err={rel_err:.6f}")
    ok = (max_diff < atol) and (rel_err < rtol)
    if ok:
        print(f"  ✅ {name} PASSED")
    else:
        reasons = []
        if max_diff >= atol:
            reasons.append(f"max_diff={max_diff:.6f} > atol={atol}")
        if rel_err >= rtol:
            reasons.append(f"rel_err={rel_err:.6f} > rtol={rtol}")
        print(f"  ❌ {name} FAILED ({'; '.join(reasons)})")
    return ok


def make_position_embeddings(config, batch_size, seq_len, device="cpu"):
    """Compute cos/sin position embeddings like LlamaRotaryEmbedding."""
    rotary = LlamaRotaryEmbedding(config)
    position_ids = torch.arange(seq_len, device=device).unsqueeze(0).expand(batch_size, -1)
    dummy = torch.empty(1, device=device)
    cos, sin = rotary.to(device)(dummy, position_ids)
    return cos, sin


# ============================================================================
#  Tests
# ============================================================================

def test_rmsnorm():
    """LlamaRMSNorm forward on Vortex."""
    print("=" * 60)
    print("Test 1: LlamaRMSNorm")
    print("=" * 60)
    config = TinyLlamaConfig()
    norm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)
    x = torch.randn(1, 4, config.hidden_size)

    expected = norm(x)
    result = norm.to(DEVICE)(x.to(DEVICE)).cpu()
    return _check("LlamaRMSNorm", result, expected, atol=0.01)


def test_mlp():
    """LlamaMLP forward: gate_proj → silu → * up_proj → down_proj."""
    print("=" * 60)
    print("Test 2: LlamaMLP")
    print("=" * 60)
    config = TinyLlamaConfig()
    mlp = LlamaMLP(config)
    x = torch.randn(1, 4, config.hidden_size)

    expected = mlp(x)
    result = mlp.to(DEVICE)(x.to(DEVICE)).cpu()
    return _check("LlamaMLP", result, expected, atol=0.5)


def test_rotary_embedding():
    """LlamaRotaryEmbedding: cos/sin computation."""
    print("=" * 60)
    print("Test 3: LlamaRotaryEmbedding (cos/sin)")
    print("=" * 60)
    config = TinyLlamaConfig()
    cos_cpu, sin_cpu = make_position_embeddings(config, 1, 4, "cpu")
    cos_dev, sin_dev = make_position_embeddings(config, 1, 4, DEVICE)
    cos_dev = cos_dev.cpu()
    sin_dev = sin_dev.cpu()

    ok1 = _check("cos", cos_dev, cos_cpu, atol=0.01)
    ok2 = _check("sin", sin_dev, sin_cpu, atol=0.01)
    return ok1 and ok2


def test_attention():
    """LlamaAttention: Q/K/V projections + RoPE + matmul attention + O projection."""
    print("=" * 60)
    print("Test 4: LlamaAttention (no mask)")
    print("=" * 60)
    config = TinyLlamaConfig()
    attn = LlamaAttention(config, layer_idx=0)
    x = torch.randn(1, 4, config.hidden_size)

    cos, sin = make_position_embeddings(config, 1, 4, "cpu")
    expected = attn(x, (cos, sin))

    attn_dev = attn.to(DEVICE)
    cos_dev, sin_dev = cos.to(DEVICE), sin.to(DEVICE)
    result = attn_dev(x.to(DEVICE), (cos_dev, sin_dev)).cpu()

    # Attention has multiple matmuls → higher accumulated error
    return _check("LlamaAttention", result, expected, atol=1.0)


def test_decoder_layer():
    """Full LlamaDecoderLayer: input_norm → attention → residual → post_norm → MLP → residual."""
    print("=" * 60)
    print("Test 5: LlamaDecoderLayer (1 layer)")
    print("=" * 60)
    config = TinyLlamaConfig()
    layer = LlamaDecoderLayer(config, layer_idx=0)
    x = torch.randn(1, 4, config.hidden_size)

    cos, sin = make_position_embeddings(config, 1, 4, "cpu")
    expected = layer(x, (cos, sin))

    layer_dev = layer.to(DEVICE)
    cos_dev, sin_dev = cos.to(DEVICE), sin.to(DEVICE)
    result = layer_dev(x.to(DEVICE), (cos_dev, sin_dev)).cpu()

    return _check("LlamaDecoderLayer", result, expected, atol=1.0)


def test_two_decoder_layers():
    """Two stacked LlamaDecoderLayers (simulates 2-layer LLaMA model body)."""
    print("=" * 60)
    print("Test 6: 2× LlamaDecoderLayer stacked")
    print("=" * 60)
    config = TinyLlamaConfig()
    layer0 = LlamaDecoderLayer(config, layer_idx=0)
    layer1 = LlamaDecoderLayer(config, layer_idx=1)
    final_norm = LlamaRMSNorm(config.hidden_size, eps=config.rms_norm_eps)

    x = torch.randn(1, 4, config.hidden_size)
    cos, sin = make_position_embeddings(config, 1, 4, "cpu")

    # CPU reference
    h = layer0(x, (cos, sin))
    h = layer1(h, (cos, sin))
    expected = final_norm(h)

    # Vortex
    layer0_dev = layer0.to(DEVICE)
    layer1_dev = layer1.to(DEVICE)
    norm_dev = final_norm.to(DEVICE)
    cos_dev, sin_dev = cos.to(DEVICE), sin.to(DEVICE)

    h_dev = layer0_dev(x.to(DEVICE), (cos_dev, sin_dev))
    h_dev = layer1_dev(h_dev, (cos_dev, sin_dev))
    result = norm_dev(h_dev).cpu()

    return _check("2×DecoderLayer + FinalNorm", result, expected, atol=1.5)


def test_decoder_with_causal_mask():
    """LlamaDecoderLayer with causal attention mask."""
    print("=" * 60)
    print("Test 7: LlamaDecoderLayer with causal mask")
    print("=" * 60)
    config = TinyLlamaConfig()
    layer = LlamaDecoderLayer(config, layer_idx=0)
    seq_len = 4
    x = torch.randn(1, seq_len, config.hidden_size)

    # Causal mask: upper-triangular = -inf
    mask = torch.zeros(1, 1, seq_len, seq_len)
    mask.masked_fill_(torch.triu(torch.ones(seq_len, seq_len, dtype=torch.bool), diagonal=1), float("-inf"))

    cos, sin = make_position_embeddings(config, 1, seq_len, "cpu")
    expected = layer(x, (cos, sin), attention_mask=mask)

    layer_dev = layer.to(DEVICE)
    cos_dev, sin_dev = cos.to(DEVICE), sin.to(DEVICE)
    result = layer_dev(x.to(DEVICE), (cos_dev, sin_dev), attention_mask=mask.to(DEVICE)).cpu()

    return _check("DecoderLayer+CausalMask", result, expected, atol=1.0)


def test_longer_sequence():
    """LlamaDecoderLayer with longer sequence (seq_len=16)."""
    print("=" * 60)
    print("Test 8: LlamaDecoderLayer seq_len=16")
    print("=" * 60)
    config = TinyLlamaConfig()
    layer = LlamaDecoderLayer(config, layer_idx=0)
    seq_len = 16
    x = torch.randn(1, seq_len, config.hidden_size)

    cos, sin = make_position_embeddings(config, 1, seq_len, "cpu")
    expected = layer(x, (cos, sin))

    layer_dev = layer.to(DEVICE)
    cos_dev, sin_dev = cos.to(DEVICE), sin.to(DEVICE)
    result = layer_dev(x.to(DEVICE), (cos_dev, sin_dev)).cpu()

    return _check("DecoderLayer seq=16", result, expected, atol=1.5)


# ============================================================================
#  Main
# ============================================================================

if __name__ == "__main__":
    tests = [
        test_rmsnorm,
        test_mlp,
        test_rotary_embedding,
        test_attention,
        test_decoder_layer,
        test_two_decoder_layers,
        test_decoder_with_causal_mask,
        test_longer_sequence,
    ]

    trace_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "llama_layer_trace.json")

    passed = 0
    failed = 0

    with profile(activities=[ProfilerActivity.CPU]) as prof:
        for t in tests:
            try:
                with record_function(f"VORTEX::{t.__name__}"):
                    ok = t()
                if ok:
                    passed += 1
                else:
                    failed += 1
            except Exception as e:
                print(f"  ❌ {t.__name__} EXCEPTION: {e}")
                import traceback
                traceback.print_exc()
                failed += 1
            print()

    prof.export_chrome_trace(trace_path)
    print(f"\n📊 Chrome trace exported to: {trace_path}")

    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed out of {len(tests)} tests")
    print("=" * 60)
    sys.exit(0 if failed == 0 else 1)
