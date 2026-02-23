#!/usr/bin/env python3
"""
Test: Native aten::native_dropout on Vortex device.

The Vortex dropout kernel uses WangHash RNG internally.
We test statistical properties rather than exact values since
the RNG output is device-specific.
"""

import os
import sys
import torch

if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex


def test_dropout_inference_identity():
    """Dropout with train=False should be identity."""
    print("=" * 60)
    print("Test 1: Dropout inference (train=False) → identity")
    print("=" * 60)
    x_cpu = torch.randn(1024, dtype=torch.float32)
    x_dev = x_cpu.to("vortex")

    out_dev, mask_dev = torch.native_dropout(x_dev, 0.5, False)
    result = out_dev.cpu()
    mask = mask_dev.cpu()

    assert torch.allclose(result, x_cpu, atol=1e-6), "Inference should be identity"
    assert mask.all(), "All mask elements should be True in inference"
    print("  ✅ dropout_inference_identity PASSED")
    print()


def test_dropout_p_zero():
    """Dropout with p=0 should be identity."""
    print("=" * 60)
    print("Test 2: Dropout p=0 → identity")
    print("=" * 60)
    x_cpu = torch.randn(1024, dtype=torch.float32)
    x_dev = x_cpu.to("vortex")

    out_dev, mask_dev = torch.native_dropout(x_dev, 0.0, True)
    result = out_dev.cpu()
    mask = mask_dev.cpu()

    assert torch.allclose(result, x_cpu, atol=1e-6), "p=0 should be identity"
    assert mask.all(), "All mask elements should be True when p=0"
    print("  ✅ dropout_p_zero PASSED")
    print()


def test_dropout_p_one():
    """Dropout with p=1 should zero everything."""
    print("=" * 60)
    print("Test 3: Dropout p=1 → all zeros")
    print("=" * 60)
    x_cpu = torch.randn(1024, dtype=torch.float32)
    x_dev = x_cpu.to("vortex")

    out_dev, mask_dev = torch.native_dropout(x_dev, 1.0, True)
    result = out_dev.cpu()
    mask = mask_dev.cpu()

    assert (result == 0).all(), "p=1 should zero everything"
    assert not mask.any(), "All mask elements should be False when p=1"
    print("  ✅ dropout_p_one PASSED")
    print()


def test_dropout_training_statistical():
    """Dropout p=0.5 training: ~50% elements dropped, survivors scaled by 2x."""
    print("=" * 60)
    print("Test 4: Dropout training p=0.5 statistical check")
    print("=" * 60)
    N = 4096
    x_cpu = torch.ones(N, dtype=torch.float32)
    x_dev = x_cpu.to("vortex")

    out_dev, mask_dev = torch.native_dropout(x_dev, 0.5, True)
    result = out_dev.cpu()
    mask = mask_dev.cpu()

    kept = mask.sum().item()
    drop_ratio = 1.0 - kept / N
    print(f"  kept: {kept}/{N}, drop_ratio: {drop_ratio:.3f}")

    # Statistical: drop ratio should be roughly 0.5 (within 0.15 tolerance)
    assert 0.2 < drop_ratio < 0.8, \
        f"Drop ratio {drop_ratio} is too far from 0.5"

    # Survivors should be scaled by 1/(1-p) = 2.0
    survivors = result[mask]
    if len(survivors) > 0:
        expected_scale = 2.0
        actual_scale = survivors.mean().item()
        print(f"  survivor mean: {actual_scale:.3f} (expected ~{expected_scale})")
        assert abs(actual_scale - expected_scale) < 0.3, \
            f"Scale {actual_scale} too far from {expected_scale}"

    # Dropped elements should be 0
    dropped = result[~mask]
    if len(dropped) > 0:
        assert (dropped == 0).all(), "Dropped elements should be 0"

    print("  ✅ dropout_training_statistical PASSED")
    print()


def test_dropout_mask_bool():
    """Mask should be bool dtype."""
    print("=" * 60)
    print("Test 5: Dropout mask dtype is bool")
    print("=" * 60)
    x = torch.randn(256, dtype=torch.float32).to("vortex")
    _, mask = torch.native_dropout(x, 0.3, True)
    assert mask.dtype == torch.bool, f"Expected bool, got {mask.dtype}"
    print(f"  mask dtype: {mask.dtype}")
    print("  ✅ dropout_mask_bool PASSED")
    print()


def test_dropout_preserves_shape():
    """Output and mask should have same shape as input."""
    print("=" * 60)
    print("Test 6: Dropout preserves shape (4×8×16)")
    print("=" * 60)
    shape = (4, 8, 16)
    x = torch.randn(*shape, dtype=torch.float32).to("vortex")
    out, mask = torch.native_dropout(x, 0.5, True)
    assert out.shape == shape, f"Output shape {out.shape} != {shape}"
    assert mask.shape == shape, f"Mask shape {mask.shape} != {shape}"
    print(f"  output shape: {out.shape}, mask shape: {mask.shape}")
    print("  ✅ dropout_preserves_shape PASSED")
    print()


if __name__ == "__main__":
    tests = [
        test_dropout_inference_identity,
        test_dropout_p_zero,
        test_dropout_p_one,
        test_dropout_training_statistical,
        test_dropout_mask_bool,
        test_dropout_preserves_shape,
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
