#!/usr/bin/env python3
"""
Test: vortex::apply_rotary_pos_emb custom op on Vortex device.

RoPE applies rotary position embeddings to queries/keys.
Input: [batch, seq_len, num_heads, head_dim]
cos/sin: [max_seq_len, head_dim//2]

Uses the "split-half" layout:
  out[..., :D/2] = x[..., :D/2]*cos - x[..., D/2:]*sin
  out[..., D/2:] = x[..., :D/2]*sin + x[..., D/2:]*cos
"""

import os
import sys
import torch
import math

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex


def precompute_freqs(max_seq_len, head_dim, theta_base=10000.0):
    """Precompute cos/sin frequency tables: [max_seq_len, head_dim//2]."""
    half_dim = head_dim // 2
    freqs = torch.zeros(max_seq_len, half_dim, dtype=torch.float32)
    for pos in range(max_seq_len):
        for i in range(half_dim):
            freq = theta_base ** (-2.0 * i / head_dim)
            theta = pos * freq
            freqs[pos, i] = theta
    cos_table = torch.cos(freqs)
    sin_table = torch.sin(freqs)
    return cos_table, sin_table


def rope_ref(x, cos_table, sin_table, pos_offset=0):
    """Reference RoPE implementation matching the Vortex kernel's split-half layout."""
    B, S, H, D = x.shape
    half_d = D // 2
    out = torch.zeros_like(x)
    for b in range(B):
        for s in range(S):
            pos = s + pos_offset
            for h in range(H):
                x0 = x[b, s, h, :half_d]
                x1 = x[b, s, h, half_d:]
                cos_val = cos_table[pos, :]  # [half_d]
                sin_val = sin_table[pos, :]
                out[b, s, h, :half_d] = x0 * cos_val - x1 * sin_val
                out[b, s, h, half_d:] = x0 * sin_val + x1 * cos_val
    return out


def _check(name, result, expected, atol=1e-3, rtol=1e-3):
    diff = (result - expected).abs()
    max_diff = diff.max().item()
    mean_diff = diff.mean().item()
    print(f"  max_diff = {max_diff:.6f}, mean_diff = {mean_diff:.6f}")
    ok = torch.allclose(result, expected, atol=atol, rtol=rtol)
    if ok:
        print(f"  ✅ {name} PASSED")
    else:
        print(f"  ❌ {name} FAILED")
        mask = diff > atol
        idx = mask.nonzero(as_tuple=False)[:5]
        for i in idx:
            coords = tuple(i.tolist())
            print(f"    {coords} result={result[coords]:.6f}"
                  f"  expected={expected[coords]:.6f}")
    assert ok, f"{name}: max_diff={max_diff}"


def test_rope_basic():
    """Basic RoPE on a small input."""
    print("=" * 60)
    print("Test 1: Basic RoPE (1×4×2×8)")
    print("=" * 60)
    B, S, H, D = 1, 4, 2, 8
    max_seq = 16
    x_cpu = torch.randn(B, S, H, D, dtype=torch.float32)
    cos_t, sin_t = precompute_freqs(max_seq, D)
    expected = rope_ref(x_cpu, cos_t, sin_t)

    x_dev = x_cpu.to("vortex")
    cos_dev = cos_t.to("vortex")
    sin_dev = sin_t.to("vortex")
    y_dev = torch.ops.vortex.apply_rotary_pos_emb(x_dev, cos_dev, sin_dev, 0)
    result = y_dev.cpu()
    _check("rope_basic", result, expected)
    print()


def test_rope_with_offset():
    """RoPE with non-zero position offset."""
    print("=" * 60)
    print("Test 2: RoPE with offset=4 (1×4×2×16)")
    print("=" * 60)
    B, S, H, D = 1, 4, 2, 16
    max_seq = 32
    offset = 4
    x_cpu = torch.randn(B, S, H, D, dtype=torch.float32)
    cos_t, sin_t = precompute_freqs(max_seq, D)
    expected = rope_ref(x_cpu, cos_t, sin_t, pos_offset=offset)

    x_dev = x_cpu.to("vortex")
    cos_dev = cos_t.to("vortex")
    sin_dev = sin_t.to("vortex")
    y_dev = torch.ops.vortex.apply_rotary_pos_emb(x_dev, cos_dev, sin_dev, offset)
    result = y_dev.cpu()
    _check("rope_with_offset", result, expected)
    print()


def test_rope_batch():
    """Batched RoPE."""
    print("=" * 60)
    print("Test 3: Batched RoPE (2×8×4×16)")
    print("=" * 60)
    B, S, H, D = 2, 8, 4, 16
    max_seq = 32
    x_cpu = torch.randn(B, S, H, D, dtype=torch.float32)
    cos_t, sin_t = precompute_freqs(max_seq, D)
    expected = rope_ref(x_cpu, cos_t, sin_t)

    x_dev = x_cpu.to("vortex")
    cos_dev = cos_t.to("vortex")
    sin_dev = sin_t.to("vortex")
    y_dev = torch.ops.vortex.apply_rotary_pos_emb(x_dev, cos_dev, sin_dev, 0)
    result = y_dev.cpu()
    _check("rope_batch", result, expected)
    print()


def test_rope_larger_head_dim():
    """RoPE with larger head_dim (64)."""
    print("=" * 60)
    print("Test 4: RoPE larger head_dim (1×4×2×64)")
    print("=" * 60)
    B, S, H, D = 1, 4, 2, 64
    max_seq = 128
    x_cpu = torch.randn(B, S, H, D, dtype=torch.float32)
    cos_t, sin_t = precompute_freqs(max_seq, D)
    expected = rope_ref(x_cpu, cos_t, sin_t)

    x_dev = x_cpu.to("vortex")
    cos_dev = cos_t.to("vortex")
    sin_dev = sin_t.to("vortex")
    y_dev = torch.ops.vortex.apply_rotary_pos_emb(x_dev, cos_dev, sin_dev, 0)
    result = y_dev.cpu()
    _check("rope_larger_head_dim", result, expected)
    print()


def test_rope_preserves_shape():
    """Output shape == input shape."""
    print("=" * 60)
    print("Test 5: RoPE preserves shape")
    print("=" * 60)
    B, S, H, D = 2, 8, 4, 16
    max_seq = 32
    x = torch.randn(B, S, H, D, dtype=torch.float32).to("vortex")
    cos_t, sin_t = precompute_freqs(max_seq, D)
    cos_dev = cos_t.to("vortex")
    sin_dev = sin_t.to("vortex")
    y = torch.ops.vortex.apply_rotary_pos_emb(x, cos_dev, sin_dev, 0)
    assert y.shape == (B, S, H, D), f"Shape mismatch: {y.shape}"
    print(f"  shape: {y.shape}")
    print("  ✅ rope_preserves_shape PASSED")
    print()


def test_rope_zero_input():
    """RoPE on zero input should produce zero output."""
    print("=" * 60)
    print("Test 6: RoPE zero input → zero output")
    print("=" * 60)
    B, S, H, D = 1, 4, 2, 8
    max_seq = 16
    x_cpu = torch.zeros(B, S, H, D, dtype=torch.float32)
    cos_t, sin_t = precompute_freqs(max_seq, D)

    x_dev = x_cpu.to("vortex")
    cos_dev = cos_t.to("vortex")
    sin_dev = sin_t.to("vortex")
    y_dev = torch.ops.vortex.apply_rotary_pos_emb(x_dev, cos_dev, sin_dev, 0)
    result = y_dev.cpu()
    assert torch.allclose(result, torch.zeros_like(result), atol=1e-6)
    print("  ✅ rope_zero_input PASSED")
    print()


if __name__ == "__main__":
    tests = [
        test_rope_basic,
        test_rope_with_offset,
        test_rope_batch,
        test_rope_larger_head_dim,
        test_rope_preserves_shape,
        test_rope_zero_input,
    ]
    passed = 0
    failed = 0
    for t in tests:
        try:
            t()
            passed += 1
        except Exception as e:
            print(f"  ❌ {t.__name__} FAILED: {e}")
            failed += 1
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed out of {len(tests)} tests")
    print("=" * 60)
    sys.exit(0 if failed == 0 else 1)
