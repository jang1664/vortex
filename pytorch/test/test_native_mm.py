#!/usr/bin/env python3
"""
Test: Native aten::mm, aten::bmm, aten::addmm on Vortex device via sgemm_tcu kernel (TCU WMMA).

The sgemm_tcu kernel takes fp16 inputs and produces fp32 outputs using
the Tensor Compute Unit.  The ATen wrapper auto-converts fp32→fp16 before
launch, and the output is always fp32.

Tile sizes: M=8, N=4, K=8.  Dimensions are zero-padded to multiples.

Tests 1-6:   aten::mm   — basic 2D matrix multiply
Tests 7-9:   aten::bmm  — batched matrix multiply (batch loop over mm)
Tests 10-11: aten::addmm — bias + mat1 @ mat2 (mm + scalar add)
Tests 12-13: 4D matmul   — dispatches to bmm (attention Q@K^T, W@V)
Tests 14-15: nn.Linear   — dispatches to mm (no bias) or addmm (with bias)
"""

import os
import sys
import torch
import math

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # registers 'vortex' backend


def _check(name, result, expected, atol=1e-2, rtol=1e-2):
    """Helper: compare result vs expected, print diff, assert close."""
    diff = (result - expected).abs()
    max_diff = diff.max().item()
    mean_diff = diff.mean().item()
    print(f"  max_diff = {max_diff:.6f}, mean_diff = {mean_diff:.6f}")
    ok = torch.allclose(result, expected, atol=atol, rtol=rtol)
    if ok:
        print(f"  ✅ {name} PASSED")
    else:
        print(f"  ❌ {name} FAILED")
        # Show first few mismatches
        mask = diff > atol
        idx = mask.nonzero(as_tuple=False)[:5]
        for i in idx:
            r, c = i[0].item(), i[1].item()
            print(f"    [{r},{c}] result={result[r,c]:.6f}  expected={expected[r,c]:.6f}")
    assert ok, f"{name}: max_diff={max_diff}"
    return ok


def test_mm_square_aligned():
    """Square matrix multiply, dimensions already aligned to tile sizes."""
    print("=" * 60)
    print("Test 1: Square aligned mm (16×16 @ 16×16)")
    print("=" * 60)
    M, K, N = 16, 16, 16
    a_cpu = torch.randn(M, K, dtype=torch.float32)
    b_cpu = torch.randn(K, N, dtype=torch.float32)
    # fp16 reference (to match TCU precision)
    expected = torch.mm(a_cpu.half().float(), b_cpu.half().float())

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = torch.mm(a_dev, b_dev)  # sgemm_tcu kernel
    result = c_dev.cpu()
    _check("mm_square_aligned", result, expected)
    print()


def test_mm_non_square_aligned():
    """Non-square, but all dims multiples of tile sizes."""
    print("=" * 60)
    print("Test 2: Non-square aligned mm (8×24 @ 24×4)")
    print("=" * 60)
    M, K, N = 8, 24, 4
    a_cpu = torch.randn(M, K, dtype=torch.float32)
    b_cpu = torch.randn(K, N, dtype=torch.float32)
    expected = torch.mm(a_cpu.half().float(), b_cpu.half().float())

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = torch.mm(a_dev, b_dev)
    result = c_dev.cpu()
    _check("mm_non_square_aligned", result, expected)
    print()


def test_mm_needs_padding():
    """Dimensions NOT multiples of tile sizes — tests padding logic."""
    print("=" * 60)
    print("Test 3: mm with padding (5×3 @ 3×7)")
    print("=" * 60)
    M, K, N = 5, 3, 7
    a_cpu = torch.randn(M, K, dtype=torch.float32)
    b_cpu = torch.randn(K, N, dtype=torch.float32)
    expected = torch.mm(a_cpu.half().float(), b_cpu.half().float())

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = torch.mm(a_dev, b_dev)
    result = c_dev.cpu()
    assert result.shape == (M, N), f"Shape mismatch: {result.shape} vs ({M},{N})"
    _check("mm_needs_padding", result, expected, atol=5e-2, rtol=5e-2)
    print()


def test_mm_larger():
    """Larger matrix multiply — 32×64 @ 64×16."""
    print("=" * 60)
    print("Test 4: Larger mm (32×64 @ 64×16)")
    print("=" * 60)
    M, K, N = 32, 64, 16
    a_cpu = torch.randn(M, K, dtype=torch.float32)
    b_cpu = torch.randn(K, N, dtype=torch.float32)
    expected = torch.mm(a_cpu.half().float(), b_cpu.half().float())

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = torch.mm(a_dev, b_dev)
    result = c_dev.cpu()
    _check("mm_larger", result, expected, atol=0.1, rtol=0.05)
    print()


def test_mm_fp16_input():
    """Input already in fp16 — should skip conversion."""
    print("=" * 60)
    print("Test 5: mm with fp16 input (16×8 @ 8×4)")
    print("=" * 60)
    M, K, N = 16, 8, 4
    a_cpu = torch.randn(M, K, dtype=torch.float16)
    b_cpu = torch.randn(K, N, dtype=torch.float16)
    expected = torch.mm(a_cpu.float(), b_cpu.float())

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = torch.mm(a_dev, b_dev)
    result = c_dev.cpu()
    _check("mm_fp16_input", result, expected)
    print()


def test_mm_output_dtype():
    """Output should always be fp32 (TCU accumulates in fp32)."""
    print("=" * 60)
    print("Test 6: mm output is fp32")
    print("=" * 60)
    M, K, N = 8, 8, 4
    a = torch.randn(M, K, dtype=torch.float32).to("vortex")
    b = torch.randn(K, N, dtype=torch.float32).to("vortex")
    c = torch.mm(a, b)
    assert c.dtype == torch.float32, f"Expected float32, got {c.dtype}"
    print(f"  output dtype: {c.dtype}")
    print("  ✅ mm_output_dtype PASSED")
    print()


# ---------- bmm tests ----------

def test_bmm_basic():
    """Basic batched matrix multiply: [B, M, K] @ [B, K, N]."""
    print("=" * 60)
    print("Test 7: bmm basic (2×8×8 @ 2×8×4)")
    print("=" * 60)
    B, M, K, N = 2, 8, 8, 4
    a_cpu = torch.randn(B, M, K)
    b_cpu = torch.randn(B, K, N)
    expected = torch.bmm(a_cpu.half().float(), b_cpu.half().float())
    result = torch.bmm(a_cpu.to("vortex"), b_cpu.to("vortex")).cpu()
    _check("bmm_basic", result.view(-1, N), expected.view(-1, N))
    print()


def test_bmm_larger_batch():
    """bmm with a larger batch size."""
    print("=" * 60)
    print("Test 8: bmm larger batch (4×16×8 @ 4×8×16)")
    print("=" * 60)
    B, M, K, N = 4, 16, 8, 16
    a_cpu = torch.randn(B, M, K)
    b_cpu = torch.randn(B, K, N)
    expected = torch.bmm(a_cpu.half().float(), b_cpu.half().float())
    result = torch.bmm(a_cpu.to("vortex"), b_cpu.to("vortex")).cpu()
    _check("bmm_larger_batch", result.view(-1, N), expected.view(-1, N), atol=0.05)
    print()


def test_bmm_non_contiguous():
    """bmm with non-contiguous input (Q @ K^T pattern)."""
    print("=" * 60)
    print("Test 9: bmm with non-contiguous (transposed) input")
    print("=" * 60)
    B, M, K = 2, 8, 16
    a_cpu = torch.randn(B, M, K)
    # b has same shape [B, M, K], transpose to [B, K, M] for Q @ K^T
    b_cpu = torch.randn(B, M, K)
    expected = torch.bmm(a_cpu.half().float(), b_cpu.half().float().transpose(1, 2))
    result = torch.bmm(
        a_cpu.to("vortex"),
        b_cpu.to("vortex").transpose(1, 2),
    ).cpu()
    _check("bmm_non_contiguous", result.view(-1, M), expected.view(-1, M))
    print()


# ---------- addmm tests ----------

def test_addmm_basic():
    """Basic addmm: bias + mat1 @ mat2."""
    print("=" * 60)
    print("Test 10: addmm basic (8×8 @ 8×4 + bias)")
    print("=" * 60)
    M, K, N = 8, 8, 4
    bias = torch.randn(N)
    m1 = torch.randn(M, K)
    m2 = torch.randn(K, N)
    expected = torch.addmm(bias, m1.half().float(), m2.half().float())
    result = torch.addmm(
        bias.to("vortex"), m1.to("vortex"), m2.to("vortex")
    ).cpu()
    _check("addmm_basic", result, expected, atol=0.05)
    print()


def test_addmm_beta_alpha():
    """addmm with non-default beta and alpha scalars."""
    print("=" * 60)
    print("Test 11: addmm beta=0.5, alpha=2.0")
    print("=" * 60)
    M, K, N = 8, 8, 4
    bias = torch.randn(N)
    m1 = torch.randn(M, K)
    m2 = torch.randn(K, N)
    expected = torch.addmm(bias, m1.half().float(), m2.half().float(),
                           beta=0.5, alpha=2.0)
    result = torch.addmm(
        bias.to("vortex"), m1.to("vortex"), m2.to("vortex"),
        beta=0.5, alpha=2.0,
    ).cpu()
    _check("addmm_beta_alpha", result, expected, atol=0.1)
    print()


# ---------- 4D matmul (dispatches to bmm) ----------

def test_matmul_4d_qk():
    """4D matmul Q @ K^T — attention score computation."""
    print("=" * 60)
    print("Test 12: 4D matmul Q@K^T (1×4×8×16)")
    print("=" * 60)
    q = torch.randn(1, 4, 8, 16)
    k = torch.randn(1, 4, 8, 16)
    expected = torch.matmul(q.half().float(), k.half().float().transpose(2, 3))
    result = torch.matmul(
        q.to("vortex"), k.to("vortex").transpose(2, 3)
    ).cpu()
    _check("matmul_4d_qk", result.view(-1, 8), expected.view(-1, 8), atol=0.05)
    print()


def test_matmul_4d_wv():
    """4D matmul attn_weights @ V — attention output computation."""
    print("=" * 60)
    print("Test 13: 4D matmul W@V (1×4×8×8 @ 1×4×8×16)")
    print("=" * 60)
    w = torch.randn(1, 4, 8, 8)
    v = torch.randn(1, 4, 8, 16)
    expected = torch.matmul(w.half().float(), v.half().float())
    result = torch.matmul(w.to("vortex"), v.to("vortex")).cpu()
    _check("matmul_4d_wv", result.view(-1, 16), expected.view(-1, 16), atol=0.05)
    print()


# ---------- nn.Linear tests ----------

def test_linear_bias():
    """nn.Linear with bias — dispatches via addmm."""
    print("=" * 60)
    print("Test 14: nn.Linear(bias=True) (2×3×8 -> 2×3×4)")
    print("=" * 60)
    linear = torch.nn.Linear(8, 4, bias=True)
    x = torch.randn(2, 3, 8)
    expected = linear(x)
    result = linear.to("vortex")(x.to("vortex")).cpu()
    diff = (result - expected).abs()
    print(f"  max_diff = {diff.max().item():.6f}, mean_diff = {diff.mean().item():.6f}")
    ok = torch.allclose(result, expected, atol=0.1, rtol=0.05)
    assert ok, f"linear_bias: max_diff={diff.max().item()}"
    print("  ✅ linear_bias PASSED")
    print()


def test_linear_no_bias():
    """nn.Linear without bias — dispatches via mm."""
    print("=" * 60)
    print("Test 15: nn.Linear(bias=False) (2×3×8 -> 2×3×4)")
    print("=" * 60)
    linear = torch.nn.Linear(8, 4, bias=False)
    x = torch.randn(2, 3, 8)
    expected = linear(x)
    result = linear.to("vortex")(x.to("vortex")).cpu()
    diff = (result - expected).abs()
    print(f"  max_diff = {diff.max().item():.6f}, mean_diff = {diff.mean().item():.6f}")
    ok = torch.allclose(result, expected, atol=0.1, rtol=0.05)
    assert ok, f"linear_no_bias: max_diff={diff.max().item()}"
    print("  ✅ linear_no_bias PASSED")
    print()


if __name__ == "__main__":
    tests = [
        test_mm_square_aligned,
        test_mm_non_square_aligned,
        test_mm_needs_padding,
        test_mm_larger,
        test_mm_fp16_input,
        test_mm_output_dtype,
        test_bmm_basic,
        test_bmm_larger_batch,
        test_bmm_non_contiguous,
        test_addmm_basic,
        test_addmm_beta_alpha,
        test_matmul_4d_qk,
        test_matmul_4d_wv,
        test_linear_bias,
        test_linear_no_bias,
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
