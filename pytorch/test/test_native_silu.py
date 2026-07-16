#!/usr/bin/env python3
"""
Test: Native aten::silu on Vortex device.

SiLU(x) = x * sigmoid(x) = x / (1 + exp(-x))
The Vortex silu kernel operates on float32.
"""

import os
import sys
import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex


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
            print(f"    [{i.item()}] result={result.flatten()[i.item()]:.6f}"
                  f"  expected={expected.flatten()[i.item()]:.6f}")
    assert ok, f"{name}: max_diff={max_diff}"


def test_silu_basic():
    """Basic SiLU on a 1D tensor."""
    print("=" * 60)
    print("Test 1: Basic SiLU (1D, 1024 elements)")
    print("=" * 60)
    x_cpu = torch.randn(1024, dtype=torch.float32)
    expected = torch.nn.functional.silu(x_cpu)

    x_dev = x_cpu.to("vortex")
    y_dev = torch.nn.functional.silu(x_dev)
    result = y_dev.cpu()
    _check("silu_basic", result, expected)
    print()


def test_silu_2d():
    """SiLU on a 2D tensor."""
    print("=" * 60)
    print("Test 2: SiLU 2D (32×64)")
    print("=" * 60)
    x_cpu = torch.randn(32, 64, dtype=torch.float32)
    expected = torch.nn.functional.silu(x_cpu)

    x_dev = x_cpu.to("vortex")
    y_dev = torch.nn.functional.silu(x_dev)
    result = y_dev.cpu()
    _check("silu_2d", result, expected)
    print()


def test_silu_zeros():
    """SiLU(0) = 0."""
    print("=" * 60)
    print("Test 3: SiLU zeros")
    print("=" * 60)
    x_cpu = torch.zeros(256, dtype=torch.float32)
    expected = torch.nn.functional.silu(x_cpu)

    x_dev = x_cpu.to("vortex")
    y_dev = torch.nn.functional.silu(x_dev)
    result = y_dev.cpu()
    _check("silu_zeros", result, expected)
    print()


def test_silu_large_positive():
    """For large positive x, SiLU(x) ≈ x."""
    print("=" * 60)
    print("Test 4: SiLU large positive values")
    print("=" * 60)
    x_cpu = torch.tensor([10.0, 20.0, 50.0, 100.0], dtype=torch.float32)
    expected = torch.nn.functional.silu(x_cpu)

    x_dev = x_cpu.to("vortex")
    y_dev = torch.nn.functional.silu(x_dev)
    result = y_dev.cpu()
    _check("silu_large_positive", result, expected, atol=1e-3, rtol=1e-3)
    print()


def test_silu_negative():
    """For large negative x, SiLU(x) → 0."""
    print("=" * 60)
    print("Test 5: SiLU negative values")
    print("=" * 60)
    x_cpu = torch.tensor([-10.0, -5.0, -1.0, -0.5], dtype=torch.float32)
    expected = torch.nn.functional.silu(x_cpu)

    x_dev = x_cpu.to("vortex")
    y_dev = torch.nn.functional.silu(x_dev)
    result = y_dev.cpu()
    _check("silu_negative", result, expected)
    print()


def test_silu_preserves_shape():
    """SiLU output shape == input shape."""
    print("=" * 60)
    print("Test 6: SiLU preserves shape (4×8×16)")
    print("=" * 60)
    x = torch.randn(4, 8, 16, dtype=torch.float32).to("vortex")
    y = torch.nn.functional.silu(x)
    assert y.shape == x.shape, f"Shape mismatch: {y.shape} vs {x.shape}"
    assert y.device == x.device
    print(f"  shape: {y.shape}, device: {y.device}")
    print("  ✅ silu_preserves_shape PASSED")
    print()


if __name__ == "__main__":
    tests = [
        test_silu_basic,
        test_silu_2d,
        test_silu_zeros,
        test_silu_large_positive,
        test_silu_negative,
        test_silu_preserves_shape,
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
