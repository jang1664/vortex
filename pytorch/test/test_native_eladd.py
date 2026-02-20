#!/usr/bin/env python3
"""
Test: Native aten::add and aten::mul on Vortex device — CUDA-like flow.

This test demonstrates the full zero-copy-in-kernel flow:
  1. Create tensors on CPU
  2. .to('vortex')  →  one-time host→device copy
  3. a + b / a * b  →  RISC-V kernel runs entirely on device memory
  4. .cpu()         →  one-time device→host copy
  5. Verify against CPU reference

No CPU fallback is used.  The RISC-V kernel binaries
(eladd.vxbin / elmul.vxbin) execute on the Vortex SimX simulator.
"""

import os
import sys
import torch

# Ensure VORTEX_HOME is set for kernel binary lookup
if "VORTEX_HOME" not in os.environ:
    os.environ["VORTEX_HOME"] = os.path.normpath(
        os.path.join(os.path.dirname(__file__), "..", "..")
    )

import torch_vortex  # registers 'vortex' backend

def test_native_add_basic():
    """Basic element-wise add: a + b on device."""
    print("=" * 60)
    print("Test 1: Basic native add (float32)")
    print("=" * 60)

    N = 1024
    a_cpu = torch.randn(N, dtype=torch.float32)
    b_cpu = torch.randn(N, dtype=torch.float32)

    # CPU reference
    expected = a_cpu + b_cpu

    # CUDA-like flow: to('vortex') → add on device → .cpu()
    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    print(f"  a device: {a_dev.device}")
    print(f"  b device: {b_dev.device}")

    c_dev = a_dev + b_dev  # <-- runs eladd kernel on Vortex!
    print(f"  c device: {c_dev.device}")

    result = c_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")
    print(f"  Expected[:5]:  {expected[:5].tolist()}")
    print(f"  Got[:5]:       {result[:5].tolist()}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


def test_native_add_multidim():
    """Multi-dimensional tensors — they're contiguous in memory."""
    print("=" * 60)
    print("Test 2: Multi-dimensional add (2D matrix)")
    print("=" * 60)

    M, N = 32, 64
    a_cpu = torch.randn(M, N, dtype=torch.float32)
    b_cpu = torch.randn(M, N, dtype=torch.float32)

    expected = a_cpu + b_cpu

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = a_dev + b_dev
    result = c_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")
    print(f"  Expected[0,:5]:  {expected[0,:5].tolist()}")
    print(f"  Got[0,:5]:       {result[0,:5].tolist()}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


def test_native_add_chain():
    """Chain of adds — data stays on device between ops."""
    print("=" * 60)
    print("Test 3: Chained adds (a + b + c, all on device)")
    print("=" * 60)

    N = 512
    a_cpu = torch.randn(N, dtype=torch.float32)
    b_cpu = torch.randn(N, dtype=torch.float32)
    c_cpu = torch.randn(N, dtype=torch.float32)

    expected = a_cpu + b_cpu + c_cpu

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = c_cpu.to("vortex")

    # a + b runs on device, then (a+b) + c runs on device again
    # No intermediate .cpu() calls!
    result_dev = a_dev + b_dev + c_dev
    result = result_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")
    print(f"  Expected[:5]:  {expected[:5].tolist()}")
    print(f"  Got[:5]:       {result[:5].tolist()}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


def test_native_add_3d():
    """3D tensor (batch, seq, hidden) — typical transformer shape."""
    print("=" * 60)
    print("Test 4: 3D add (batch=2, seq=8, hidden=128)")
    print("=" * 60)

    a_cpu = torch.randn(2, 8, 128, dtype=torch.float32)
    b_cpu = torch.randn(2, 8, 128, dtype=torch.float32)

    expected = a_cpu + b_cpu

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = a_dev + b_dev
    result = c_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


###############################################################################
# Element-wise Multiply (elmul) tests
###############################################################################

def test_native_mul_basic():
    """Basic element-wise mul: a * b on device."""
    print("=" * 60)
    print("Test 5: Basic native mul (float32)")
    print("=" * 60)

    N = 1024
    a_cpu = torch.randn(N, dtype=torch.float32)
    b_cpu = torch.randn(N, dtype=torch.float32)

    expected = a_cpu * b_cpu

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = a_dev * b_dev  # <-- runs elmul kernel on Vortex!

    result = c_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")
    print(f"  Expected[:5]:  {expected[:5].tolist()}")
    print(f"  Got[:5]:       {result[:5].tolist()}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


def test_native_mul_multidim():
    """Multi-dimensional mul."""
    print("=" * 60)
    print("Test 6: Multi-dimensional mul (2D matrix)")
    print("=" * 60)

    M, N = 32, 64
    a_cpu = torch.randn(M, N, dtype=torch.float32)
    b_cpu = torch.randn(M, N, dtype=torch.float32)

    expected = a_cpu * b_cpu

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = a_dev * b_dev
    result = c_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


def test_native_add_mul_chain():
    """Chain of add + mul — data stays on device between ops."""
    print("=" * 60)
    print("Test 7: Chained add+mul ((a + b) * c, all on device)")
    print("=" * 60)

    N = 512
    a_cpu = torch.randn(N, dtype=torch.float32)
    b_cpu = torch.randn(N, dtype=torch.float32)
    c_cpu = torch.randn(N, dtype=torch.float32)

    expected = (a_cpu + b_cpu) * c_cpu

    a_dev = a_cpu.to("vortex")
    b_dev = b_cpu.to("vortex")
    c_dev = c_cpu.to("vortex")

    # add on device, then mul on device — no intermediate .cpu()!
    result_dev = (a_dev + b_dev) * c_dev
    result = result_dev.cpu()

    max_diff = (result - expected).abs().max().item()
    print(f"  Shape: {result.shape}")
    print(f"  Max absolute diff: {max_diff:.8f}")
    print(f"  Expected[:5]:  {expected[:5].tolist()}")
    print(f"  Got[:5]:       {result[:5].tolist()}")

    assert max_diff < 1e-5, f"FAILED: max_diff={max_diff}"
    print("  ✓ PASSED\n")


if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("  Vortex Native Add & Mul — CUDA-like Flow Test")
    print("  (No CPU fallback — RISC-V kernel on SimX)")
    print("=" * 60 + "\n")

    torch.manual_seed(42)

    # eladd tests
    test_native_add_basic()
    test_native_add_multidim()
    test_native_add_chain()
    test_native_add_3d()

    # elmul tests
    test_native_mul_basic()
    test_native_mul_multidim()

    # mixed chain test
    test_native_add_mul_chain()

    print("=" * 60)
    print("  ALL TESTS PASSED ✓")
    print("=" * 60)
