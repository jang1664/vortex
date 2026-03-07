#!/usr/bin/env python3
"""
Test: vortex::rms_norm custom op on Vortex device.

RMSNorm(x) = x / sqrt(mean(x^2) + eps) * gamma

This is registered as a custom op via TORCH_LIBRARY(vortex, m) and
accessed via torch.ops.vortex.rms_norm(input, weight, eps).
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


def rms_norm_ref(x, weight, eps=1e-6):
    """Reference RMSNorm implementation in pure PyTorch."""
    rms = x.pow(2).mean(-1, keepdim=True).add(eps).sqrt()
    return (x / rms) * weight


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


def test_rmsnorm_basic():
    """Basic RMSNorm on a single token (1×hidden)."""
    print("=" * 60)
    print("Test 1: Basic RMSNorm (1×64)")
    print("=" * 60)
    hidden = 64
    x_cpu = torch.randn(1, hidden, dtype=torch.float32)
    w_cpu = torch.ones(hidden, dtype=torch.float32)
    expected = rms_norm_ref(x_cpu, w_cpu)

    x_dev = x_cpu.to("vortex")
    w_dev = w_cpu.to("vortex")
    y_dev = torch.ops.vortex.rms_norm(x_dev, w_dev, 1e-6)
    result = y_dev.cpu()
    _check("rmsnorm_basic", result, expected)
    print()


def test_rmsnorm_batch():
    """RMSNorm on a batch of tokens (4×128)."""
    print("=" * 60)
    print("Test 2: RMSNorm batch (4×128)")
    print("=" * 60)
    hidden = 128
    batch = 4
    x_cpu = torch.randn(batch, hidden, dtype=torch.float32)
    w_cpu = torch.randn(hidden, dtype=torch.float32).abs() + 0.1
    expected = rms_norm_ref(x_cpu, w_cpu)

    x_dev = x_cpu.to("vortex")
    w_dev = w_cpu.to("vortex")
    y_dev = torch.ops.vortex.rms_norm(x_dev, w_dev, 1e-6)
    result = y_dev.cpu()
    _check("rmsnorm_batch", result, expected)
    print()


def test_rmsnorm_3d():
    """RMSNorm on 3D input [batch, seq, hidden]."""
    print("=" * 60)
    print("Test 3: RMSNorm 3D (2×4×64)")
    print("=" * 60)
    B, S, H = 2, 4, 64
    x_cpu = torch.randn(B, S, H, dtype=torch.float32)
    w_cpu = torch.ones(H, dtype=torch.float32)
    expected = rms_norm_ref(x_cpu, w_cpu)

    x_dev = x_cpu.to("vortex")
    w_dev = w_cpu.to("vortex")
    y_dev = torch.ops.vortex.rms_norm(x_dev, w_dev, 1e-6)
    result = y_dev.cpu()
    _check("rmsnorm_3d", result, expected)
    print()


def test_rmsnorm_unit_norm():
    """After RMSNorm with weight=1, rows should have approximate unit RMS."""
    print("=" * 60)
    print("Test 4: RMSNorm produces ~unit RMS")
    print("=" * 60)
    hidden = 128
    x_cpu = torch.randn(8, hidden, dtype=torch.float32) * 10.0
    w_cpu = torch.ones(hidden, dtype=torch.float32)

    x_dev = x_cpu.to("vortex")
    w_dev = w_cpu.to("vortex")
    y_dev = torch.ops.vortex.rms_norm(x_dev, w_dev, 1e-6)
    result = y_dev.cpu()

    rms = result.pow(2).mean(-1).sqrt()
    print(f"  RMS per row: {rms.tolist()}")
    ok = torch.allclose(rms, torch.ones_like(rms), atol=0.05)
    if ok:
        print("  ✅ rmsnorm_unit_norm PASSED")
    else:
        print("  ❌ rmsnorm_unit_norm FAILED")
    assert ok
    print()


def test_rmsnorm_with_gamma():
    """RMSNorm with non-trivial gamma weights."""
    print("=" * 60)
    print("Test 5: RMSNorm with gamma (4×32)")
    print("=" * 60)
    hidden = 32
    x_cpu = torch.randn(4, hidden, dtype=torch.float32)
    w_cpu = torch.randn(hidden, dtype=torch.float32) * 2.0
    eps = 1e-5
    expected = rms_norm_ref(x_cpu, w_cpu, eps)

    x_dev = x_cpu.to("vortex")
    w_dev = w_cpu.to("vortex")
    y_dev = torch.ops.vortex.rms_norm(x_dev, w_dev, eps)
    result = y_dev.cpu()
    _check("rmsnorm_with_gamma", result, expected)
    print()


def test_rmsnorm_preserves_shape():
    """Output shape == input shape."""
    print("=" * 60)
    print("Test 6: RMSNorm preserves shape")
    print("=" * 60)
    shape = (2, 8, 64)
    x = torch.randn(*shape, dtype=torch.float32).to("vortex")
    w = torch.ones(64, dtype=torch.float32).to("vortex")
    y = torch.ops.vortex.rms_norm(x, w, 1e-6)
    assert y.shape == shape, f"Shape mismatch: {y.shape} vs {shape}"
    print(f"  shape: {y.shape}")
    print("  ✅ rmsnorm_preserves_shape PASSED")
    print()


if __name__ == "__main__":
    tests = [
        test_rmsnorm_basic,
        test_rmsnorm_batch,
        test_rmsnorm_3d,
        test_rmsnorm_unit_norm,
        test_rmsnorm_with_gamma,
        test_rmsnorm_preserves_shape,
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
